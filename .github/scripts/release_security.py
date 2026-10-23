#!/usr/bin/env python3
"""Signed security metadata for a release (security plan v8 §4, Phase 2).

The reviewed `RELEASE_SECURITY.json` at the repository root describes, for
ONE release sequence, the manifest's `security` block and optional
`componentAdvisories`. This tool

  fetch-history  downloads and verifies every PUBLISHED release manifest of
                 the channel (enumerating releases, never trusting `latest`),
  authorize      runs the authorize-job checks of §4.2/§4.4 against that
                 history (fail closed: any doubt refuses the release),
  emit           writes the JSON fragment build-manifest.sh merges into the
                 signed manifest.

Standard library only. Exit 0 = allowed; any refusal prints every reason.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

MAX_LIST = 64
MAX_STRING = 512
MAX_SUMMARY = 200
MAX_IDS = 16
MAX_SEQ = 1 << 53
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{2,63}$")
NAMED_RE = re.compile(r"^(CVE-\d{4}-\d{4,}|GHSA(-[0-9A-Z]{4}){3}|OSV-|PYSEC-|RUSTSEC-|GO-|USN-|DSA-|DLA-|DEBIAN-|UBUNTU-)", re.I)
LEVELS = ("recommended", "critical")
ECOSYSTEMS = {
    "deb": ["distro", "release", "arch"],
    "brew": ["tap", "formula", "versionScheme"],
    "npm": ["package"],
    "pypi": ["distribution"],
    "binary": ["vendor", "product", "platform"],
}
SECURITY_KEYS = {"introduces", "cumulative", "securityFloor", "summary"}
FILE_KEYS = SECURITY_KEYS | {"schema", "forSequence", "componentAdvisories", "aliasLookup"}
# Releases before the Briglia rename (v0.2.0) were signed on the old channel
# (`ada-cli`), another trust domain: they carry no security metadata and are
# skipped by tag, never by anything the envelope claims. Every release from
# v0.2.0 on must verify on this channel.
FIRST_CHANNEL_VERSION = (0, 2, 0)


class Refused(Exception):
    pass


# ---------------------------------------------------------------- validation

def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _seq(v, name, problems):
    if not _is_int(v) or v < 0 or v >= MAX_SEQ:
        problems.append(f"{name} is not an integer in [0, 2^53)")
        return 0
    return v


def _identity(entry, problems, what):
    """Mirrors ReleaseSecurity.identity: aliases a list of ≤ 64 raw IDs, every
    ID matching the pattern, the de-duplicated set ≤ 16."""
    ids = []
    aliases = entry.get("aliases", [])
    if not isinstance(aliases, list):
        problems.append(f"{what}: aliases is not a list")
        aliases = []
    elif len(aliases) > MAX_LIST:
        problems.append(f"{what}: aliases has more than {MAX_LIST} entries")
    raw = [entry.get("id")] + list(aliases)
    for x in raw:
        if not isinstance(x, str) or not ID_RE.match(x):
            problems.append(f"{what}: advisory ID {x!r} does not match the ID pattern")
            continue
        u = x.upper()
        if u not in ids:
            ids.append(u)
    if len(ids) > MAX_IDS:
        problems.append(f"{what}: identity set has {len(ids)} IDs (limit {MAX_IDS})")
    return ids


def merge_transitively(entries):
    """§4.2 union-find over identity sets; highest level, widest range."""
    parent = list(range(len(entries)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    owner = {}
    for i, e in enumerate(entries):
        for x in e["ids"]:
            if x in owner:
                a, b = find(i), find(owner[x])
                if a != b:
                    parent[max(a, b)] = min(a, b)
            else:
                owner[x] = i
    groups, order = {}, []
    for i, e in enumerate(entries):
        r = find(i)
        if r in groups:
            g = groups[r]
            g["ids"] += [x for x in e["ids"] if x not in g["ids"]]
            g["level"] = "critical" if "critical" in (g["level"], e["level"]) else "recommended"
            g["from"] = min(g["from"], e["from"])
            g["fixed"] = max(g["fixed"], e["fixed"])
        else:
            groups[r] = dict(e, ids=list(e["ids"]))
            order.append(r)
    return [groups[r] for r in order]


def parse_security(sec, sequence):
    """Returns (merged cumulative, merged introduces, floorR, floorC, problems)."""
    problems = []
    if not isinstance(sec, dict):
        return [], [], 0, 0, ["security is not an object"]
    extra = set(sec) - SECURITY_KEYS
    if extra:
        problems.append(f"security has unknown fields {sorted(extra)}")
    cumulative, introduces = [], []
    for key, out in (("cumulative", cumulative), ("introduces", introduces)):
        items = sec.get(key, [])
        if not isinstance(items, list):
            problems.append(f"{key} is not a list")
            continue
        if len(items) > MAX_LIST:
            problems.append(f"{key} has more than {MAX_LIST} entries")
        for n, e in enumerate(items):
            what = f"{key}[{n}]"
            if not isinstance(e, dict):
                problems.append(f"{what} is not an object")
                continue
            allowed = {"id", "aliases", "level", "fixedInSequence", "affectsFromSequence"} if key == "cumulative" \
                else {"id", "aliases", "level", "component"}
            if set(e) - allowed:
                problems.append(f"{what} has unknown fields {sorted(set(e) - allowed)}")
            ids = _identity(e, problems, what)
            level = e.get("level")
            if level not in LEVELS:
                problems.append(f"{what}: level must be recommended|critical")
                level = "recommended"
            if key == "cumulative":
                fixed = _seq(e.get("fixedInSequence"), f"{what}.fixedInSequence", problems)
                frm = _seq(e.get("affectsFromSequence"), f"{what}.affectsFromSequence", problems)
                if not (frm < fixed <= sequence):
                    problems.append(f"{what}: range [{frm}, {fixed}) violates affectsFrom < fixedIn ≤ {sequence}")
            else:
                fixed, frm = sequence, 0
                comp = e.get("component")
                if comp is not None and (not isinstance(comp, str) or len(comp.encode()) > MAX_STRING):
                    problems.append(f"{what}.component is not a string ≤ {MAX_STRING} bytes")
            out.append({"ids": ids, "level": level, "from": frm, "fixed": fixed})
    floors = sec.get("securityFloor")
    if not isinstance(floors, dict) or set(floors) - {"recommended", "critical"}:
        problems.append("securityFloor missing, not an object, or with unknown fields")
        floors = {}
    fr = _seq(floors.get("recommended", 0), "securityFloor.recommended", problems)
    fc = _seq(floors.get("critical", 0), "securityFloor.critical", problems)
    if fr > sequence or fc > sequence:
        problems.append("a security floor is above the release's own sequence")
    summary = sec.get("summary")
    if summary is not None:
        if not isinstance(summary, str) or len(summary.encode()) > MAX_SUMMARY:
            problems.append(f"summary is not a string ≤ {MAX_SUMMARY} bytes")
        elif any(ord(c) < 32 or ord(c) == 127 for c in summary):
            problems.append("summary contains control characters")
    merged = merge_transitively(cumulative)
    merged_intro = merge_transitively(introduces)
    # The client applies the cap after the merge to BOTH lists (round-1 R2).
    for key, groups in (("cumulative", merged), ("introduces", merged_intro)):
        for g in groups:
            if len(g["ids"]) > MAX_IDS:
                problems.append(f"merged {key} identity {g['ids'][0]} has {len(g['ids'])} IDs after the transitive merge (limit {MAX_IDS})")
    return merged, merged_intro, fr, fc, problems


# ------------------------------------------------------- version comparison

def _deb_split(v):
    epoch, rest = (v.split(":", 1) if ":" in v else ("0", v))
    if not epoch.isdigit():
        return None
    up, rev = (rest.rsplit("-", 1) if "-" in rest else (rest, "0"))
    if not up or not re.match(r"^[0-9][A-Za-z0-9.+~:-]*$", up) or not re.match(r"^[A-Za-z0-9.+~]*$", rev):
        return None
    return int(epoch), up, rev


def _deb_order(c):
    if c == "~":
        return -1
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    return ord(c) + 256


def _deb_part(a, b):
    while a or b:
        na = re.match(r"^[^0-9]*", a).group(0)
        nb = re.match(r"^[^0-9]*", b).group(0)
        for i in range(max(len(na), len(nb))):
            ca = _deb_order(na[i]) if i < len(na) else 0
            cb = _deb_order(nb[i]) if i < len(nb) else 0
            if ca != cb:
                return -1 if ca < cb else 1
        a, b = a[len(na):], b[len(nb):]
        da = re.match(r"^[0-9]*", a).group(0)
        db = re.match(r"^[0-9]*", b).group(0)
        ia, ib = int(da or 0), int(db or 0)
        if ia != ib:
            return -1 if ia < ib else 1
        a, b = a[len(da):], b[len(db):]
    return 0


def compare_versions(ecosystem, a, b):
    """-1/0/1, or None when either version cannot be compared positively."""
    if ecosystem == "deb":
        pa, pb = _deb_split(a), _deb_split(b)
        if pa is None or pb is None:
            return None
        if pa[0] != pb[0]:
            return -1 if pa[0] < pb[0] else 1
        return _deb_part(pa[1], pb[1]) or _deb_part(pa[2], pb[2])

    def parts(v):
        m = re.match(r"^v?(\d+(?:\.\d+)*)(?:_(\d+))?$", v)
        if not m:
            return None
        return [int(x) for x in m.group(1).split(".")], int(m.group(2) or 0)
    pa, pb = parts(a), parts(b)
    if pa is None or pb is None:
        return None
    na, nb = pa[0], pb[0]
    n = max(len(na), len(nb))
    na, nb = na + [0] * (n - len(na)), nb + [0] * (n - len(nb))
    if na != nb:
        return -1 if na < nb else 1
    return (pa[1] > pb[1]) - (pa[1] < pb[1])


def parse_components(items, problems):
    if items is None:
        return {}
    if not isinstance(items, list):
        problems.append("componentAdvisories is not a list")
        return {}
    if len(items) > MAX_LIST:
        problems.append(f"componentAdvisories has more than {MAX_LIST} identities — the owner decides")
    out = {}
    for n, e in enumerate(items):
        what = f"componentAdvisories[{n}]"
        if not isinstance(e, dict) or set(e) - {"ecosystem", "identity", "minimumSafe", "advisories", "level"}:
            problems.append(f"{what} is not an object of known fields")
            continue
        eco = e.get("ecosystem")
        ident = e.get("identity")
        if eco not in ECOSYSTEMS or not isinstance(ident, dict):
            problems.append(f"{what}: unknown ecosystem or identity missing")
            continue
        # Identity values as the client reads them: strings ≤ 512 bytes;
        # brew's versionScheme may also be an integer 0–999.
        bad_value = False
        for k, val in ident.items():
            if k == "versionScheme" and isinstance(val, int) and not isinstance(val, bool) and 0 <= val < 1000:
                continue
            if not isinstance(val, str) or len(val.encode()) > MAX_STRING:
                bad_value = True
        if bad_value:
            problems.append(f"{what}: identity values must be strings ≤ {MAX_STRING} bytes")
            continue
        need = set(ECOSYSTEMS[eco])
        if eco == "deb":
            named = [k for k in ("sourcePackage", "binaryPackage") if k in ident]
            if len(named) != 1:
                problems.append(f"{what}: deb identity needs exactly one of sourcePackage/binaryPackage")
                continue
            need.add(named[0])
        if set(ident) != need:
            problems.append(f"{what}: identity fields do not match the ecosystem")
            continue
        adv = e.get("advisories")
        if not isinstance(adv, list) or not 1 <= len(adv) <= MAX_IDS or not all(isinstance(x, str) and ID_RE.match(x) for x in adv):
            problems.append(f"{what}: advisories must be 1–16 valid IDs")
            continue
        if not isinstance(e.get("minimumSafe"), str) or len(e["minimumSafe"].encode()) > 128 or e.get("level") not in LEVELS:
            problems.append(f"{what}: minimumSafe (string ≤ 128 bytes) or level invalid")
            continue
        key = json.dumps([eco, ident], sort_keys=True)
        if key in out:
            problems.append(f"{what}: more than one entry for the same identity")
        out[key] = {"ecosystem": eco, "minimumSafe": e["minimumSafe"], "advisories": {x.upper() for x in adv}}
    return out


# --------------------------------------------------------------- authorize

def covered(level, fixed, floor_r, floor_c):
    """A fix is covered by floors when every client it affects is below a floor
    that classifies it at least at its level."""
    return fixed <= (floor_c if level == "critical" else max(floor_r, floor_c))


def _block(payload):
    sec = payload.get("security")
    if sec is None:
        return [], 0, 0
    merged, _, fr, fc, problems = parse_security(sec, payload["sequence"])
    if problems:
        raise Refused(f"published release {payload['sequence']} has invalid security metadata: {problems[0]}")
    return merged, fr, fc


def osv_aliases(ids, base):
    out = set()
    for x in ids:
        req = urllib.request.Request(f"{base.rstrip('/')}/v1/vulns/{x}", headers={"User-Agent": "briglia-release-security"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                data = json.loads(r.read(1 << 20))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue
            raise
        for a in data.get("aliases") or []:
            if isinstance(a, str):
                out.add(a.upper())
        if isinstance(data.get("id"), str):
            out.add(data["id"].upper())
    return out


def authorize(spec, sequence, history, osv_base=None, alias_lookup=osv_aliases):
    """`history`: verified payloads of every PUBLISHED release (any order).
    Returns the list of refusal reasons (empty = allowed)."""
    reasons = []
    published = sorted((p for p in history if p["sequence"] < sequence), key=lambda p: p["sequence"])
    if not published:
        return ["no previous published release could be determined and verified — refusing (fail closed)"]
    prev = published[-1]
    try:
        p_cum, p_fr, p_fc = _block(prev)
    except Refused as e:
        return [str(e)]
    p_comp_problems = []
    p_comp = parse_components(prev.get("componentAdvisories"), p_comp_problems)

    if spec is None:
        # No security block: counts as floors 0, empty cumulative, no components.
        if p_fr or p_fc:
            reasons.append("decreasing security floor (this release has no security block)")
        for e in p_cum:
            reasons.append(f"still-open entry {e['ids'][0]} dropped (this release has no security block)")
        if p_comp:
            reasons.append("componentAdvisories entries dropped (this release has none)")
        return reasons

    extra = set(spec) - FILE_KEYS
    if extra:
        reasons.append(f"RELEASE_SECURITY.json has unknown fields {sorted(extra)}")
    if spec.get("forSequence") != sequence:
        reasons.append(f"RELEASE_SECURITY.json is for sequence {spec.get('forSequence')!r}, not {sequence} — review it for this release")
    sec = {k: spec[k] for k in SECURITY_KEYS if k in spec}
    cum, intro, fr, fc, problems = parse_security(sec, sequence)
    reasons += problems
    comp = parse_components(spec.get("componentAdvisories"), reasons)

    for e in cum:
        if e["level"] == "critical" and not any(NAMED_RE.match(x) for x in e["ids"]):
            reasons.append(f"critical entry {e['ids'][0]} has no named advisory (CVE/GHSA/…)")
    for i in intro:
        if not any(set(i["ids"]) & set(e["ids"]) for e in cum):
            reasons.append(f"introduces entry {i['ids'][0]} is not in cumulative")
    if fr < p_fr or fc < p_fc:
        reasons.append(f"decreasing security floor (previous {p_fr}/{p_fc}, now {fr}/{fc})")

    for pe in p_cum:
        match = [e for e in cum if set(e["ids"]) & set(pe["ids"])]
        if not match:
            if not covered(pe["level"], pe["fixed"], fr, fc):
                reasons.append(f"still-open entry {pe['ids'][0]} dropped without a covering {pe['level']} floor")
        else:
            lost = [x for x in pe["ids"] if not any(x in e["ids"] for e in match)]
            if lost:
                reasons.append(f"entry {pe['ids'][0]} lost or replaced published IDs {lost} (identity sets only grow)")

    # R6-1: no reintroduction under the floor P published.
    entering = [e for e in cum if not any(set(e["ids"]) & set(pe["ids"]) for pe in p_cum)]
    for e in entering:
        if covered(e["level"], e["fixed"], p_fr, p_fc):
            reasons.append(f"entering entry {e['ids'][0]}: fix already covered by a published floor "
                           f"(fixedIn {e['fixed']} ≤ floor {p_fc if e['level'] == 'critical' else max(p_fr, p_fc)})")

    # Identity completeness against every published manifest (defence in depth).
    groups = []   # [(set of all ids ever, latest published ids)]
    for p in published:
        try:
            entries = _block(p)[0]
        except Refused as ex:
            reasons.append(str(ex))
            continue
        for e in entries:
            hit = [g for g in groups if g[0] & set(e["ids"])]
            if hit:
                union = set().union(*[g[0] for g in hit]) | set(e["ids"])
                groups = [g for g in groups if g not in hit] + [(union, list(e["ids"]))]
            else:
                groups.append((set(e["ids"]), list(e["ids"])))
    historical = set().union(*[g[0] for g in groups]) if groups else set()
    for e in entering:
        for allids, latest in groups:
            if allids & set(e["ids"]):
                missing = [x for x in latest[:MAX_IDS] if x not in e["ids"]]
                if missing:
                    reasons.append(f"entering entry {e['ids'][0]} omits historical IDs {missing} of the same advisory")
    if entering:
        skip = spec.get("aliasLookup")
        if isinstance(skip, str) and skip.startswith("skipped: ") and len(skip) > 9:
            pass
        else:
            try:
                for e in entering:
                    aliases = alias_lookup(e["ids"], osv_base or "https://api.osv.dev")
                    omitted = sorted((aliases & historical) - set(e["ids"]))
                    if omitted:
                        reasons.append(f"entering entry {e['ids'][0]}: OSV aliases {omitted} are published IDs it omits")
            except Exception as ex:   # noqa: BLE001 — any lookup failure refuses
                reasons.append(f"alias lookup unavailable ({ex}) — record aliasLookup: \"skipped: <reason>\" to proceed (never bypasses the floor rule)")

    # componentAdvisories: never dropped, only superseded forward.
    ever = set()
    for p in published:
        ever |= set(parse_components(p.get("componentAdvisories"), []))
    for key, pe in p_comp.items():
        e = comp.get(key)
        if e is None:
            reasons.append(f"componentAdvisories entry {key} dropped")
            continue
        c = compare_versions(e["ecosystem"], e["minimumSafe"], pe["minimumSafe"])
        if c is None or c < 0:
            reasons.append(f"componentAdvisories entry {key}: minimumSafe {e['minimumSafe']!r} is not positively ≥ {pe['minimumSafe']!r}")
        if not pe["advisories"] <= e["advisories"]:
            reasons.append(f"componentAdvisories entry {key}: advisory set shrank")
    for key in comp:
        if key not in p_comp and key in ever:
            reasons.append(f"componentAdvisories entry {key} reappears after an absence")
    return reasons


def emit(spec):
    if spec is None:
        return {}
    out = {"security": {k: spec[k] for k in ("introduces", "cumulative", "securityFloor", "summary") if k in spec}}
    if "componentAdvisories" in spec:
        out["componentAdvisories"] = spec["componentAdvisories"]
    return out


# ----------------------------------------------------------------- history

ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def validate_payload(payload, repo, channel, tag):
    """The client's manifest validation (ReleaseSigning.validateManifest)
    with the expiry exempt — this is a historical read — plus the tag/version
    binding (round-1 note on fetch-history: envelope authentication alone is
    not the client's complete check)."""
    problems = []
    if not isinstance(payload, dict):
        return ["payload is not a JSON object"]
    if payload.get("schema") != 1:
        problems.append("schema is not 1")
    if payload.get("channel") != channel:
        problems.append(f"channel {payload.get('channel')!r} is not {channel!r}")
    seq = payload.get("sequence")
    if not _is_int(seq) or seq < 1:
        problems.append("sequence is not a positive integer")
    version = payload.get("version")
    if not isinstance(version, str) or not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", version):
        problems.append("version is not exact SemVer")
    elif tag is not None and version != tag[1:]:
        problems.append(f"version {version!r} does not match the release tag {tag!r}")
    for field in ("published", "expires"):
        if not isinstance(payload.get(field), str) or not ISO_RE.match(payload[field]):
            problems.append(f"{field} is not an ISO 8601 timestamp")
    platforms = payload.get("platforms")
    if not isinstance(platforms, dict) or not platforms:
        problems.append("no platforms")
        return problems
    prefix = f"https://github.com/{repo}/releases/download/v{version}/"
    for name, e in platforms.items():
        if not isinstance(e, dict):
            problems.append(f"platform {name}: not an object")
            continue
        url = e.get("url")
        if not isinstance(url, str) or not url.startswith(prefix) or not re.match(r"^[A-Za-z0-9._-]+$", url[len(prefix):]) or ".." in url:
            problems.append(f"platform {name}: url outside the pinned release location")
        if not isinstance(e.get("sha256"), str) or not re.match(r"^[0-9a-f]{64}$", e["sha256"]):
            problems.append(f"platform {name}: sha256 is not 64 lowercase hex characters")
        size = e.get("size")
        if not _is_int(size) or not 0 < size <= 2 * 1024 ** 3:
            problems.append(f"platform {name}: size out of range")
    return problems


def fetch_history(repo, pubkey, channel, out_dir, api_base, verify_script):
    """Every published (non-draft, non-prerelease) release with a signed
    manifest, verified with the committed key. Never `latest` alone."""
    token = os.environ.get("GITHUB_TOKEN")
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "briglia-release-security"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    page, payloads = 1, []
    while True:
        req = urllib.request.Request(f"{api_base.rstrip('/')}/repos/{repo}/releases?per_page=100&page={page}", headers=headers)
        with urllib.request.urlopen(req, timeout=30) as r:
            releases = json.loads(r.read())
        if not releases:
            break
        for rel in releases:
            if rel.get("draft") or rel.get("prerelease") or not re.match(r"^v\d+\.\d+\.\d+$", rel.get("tag_name", "")):
                continue
            if tuple(int(x) for x in rel["tag_name"][1:].split(".")) < FIRST_CHANNEL_VERSION:
                continue   # pre-rename releases: another channel, no security metadata
            asset = next((a for a in rel.get("assets", []) if a.get("name") == "manifest.sig.json"), None)
            if asset is None:
                raise Refused(f"published release {rel['tag_name']} has no signed manifest — refusing (fail closed)")
            with tempfile.TemporaryDirectory() as tmp:
                env_path, payload_path = os.path.join(tmp, "e.json"), os.path.join(tmp, "p.json")
                req = urllib.request.Request(asset["browser_download_url"], headers={"User-Agent": "briglia-release-security"})
                with urllib.request.urlopen(req, timeout=30) as r, open(env_path, "wb") as f:
                    f.write(r.read(131073))
                res = subprocess.run([verify_script, env_path, pubkey, channel, payload_path], capture_output=True, text=True)
                if res.returncode != 0:
                    raise Refused(f"published release {rel['tag_name']} does not verify: {res.stdout.strip()} {res.stderr.strip()}")
                payload = json.load(open(payload_path))
            problems = validate_payload(payload, repo, channel, rel["tag_name"])
            if problems:
                raise Refused(f"published release {rel['tag_name']} fails the client's manifest validation: {problems[0]}")
            payloads.append(payload)
            with open(os.path.join(out_dir, f"{payload['sequence']}.json"), "w") as f:
                json.dump(payload, f, sort_keys=True)
        page += 1
    if not payloads:
        raise Refused("no published, verified release found — refusing (fail closed)")
    return payloads


def load_history(directory):
    return [json.load(open(os.path.join(directory, n))) for n in sorted(os.listdir(directory)) if n.endswith(".json")]


def load_spec(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch-history")
    f.add_argument("--repo", required=True)
    f.add_argument("--pubkey", required=True)
    f.add_argument("--channel", default="briglia-cli")
    f.add_argument("--out", required=True)
    f.add_argument("--api-base", default=os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    f.add_argument("--verify-script", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify-envelope.sh"))
    a = sub.add_parser("authorize")
    a.add_argument("--file", default="RELEASE_SECURITY.json")
    a.add_argument("--sequence", type=int, required=True)
    a.add_argument("--history", required=True, help="directory of verified published payloads")
    a.add_argument("--osv-base", default=os.environ.get("OSV_API_BASE"))
    e = sub.add_parser("emit")
    e.add_argument("--file", default="RELEASE_SECURITY.json")
    e.add_argument("--sequence", type=int, required=True)
    e.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "fetch-history":
            os.makedirs(args.out, exist_ok=True)
            got = fetch_history(args.repo, args.pubkey, args.channel, args.out, args.api_base, args.verify_script)
            print(f"✔ {len(got)} published releases verified (highest sequence {max(p['sequence'] for p in got)})")
            return 0
        spec = load_spec(args.file)
        if args.cmd == "authorize":
            reasons = authorize(spec, args.sequence, load_history(args.history), args.osv_base)
            if reasons:
                for r in reasons:
                    print(f"✖ {r}")
                return 1
            print("✔ security metadata authorized" + ("" if spec else " (no security block)"))
            return 0
        if args.cmd == "emit":
            if spec is not None:
                if spec.get("forSequence") != args.sequence:
                    print(f"✖ RELEASE_SECURITY.json is for sequence {spec.get('forSequence')!r}, not {args.sequence}")
                    return 1
                sec = {k: spec[k] for k in SECURITY_KEYS if k in spec}
                problems = parse_security(sec, args.sequence)[4]
                parse_components(spec.get("componentAdvisories"), problems)
                if problems:
                    for p in problems:
                        print(f"✖ {p}")
                    return 1
            with open(args.out, "w") as fh:
                json.dump(emit(spec), fh, sort_keys=True, separators=(",", ":"))
            print("✔ security fragment written" + ("" if spec else " (empty: no security block)"))
            return 0
    except (Refused, urllib.error.URLError, OSError, ValueError) as ex:
        print(f"✖ {ex}")
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
