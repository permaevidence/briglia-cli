#!/usr/bin/env python3
"""Daily dependency vulnerability watch (security auto-update plan, Phase 0).

Reads security/dependencies.json (scripts/security_inventory.py) and checks
  * every exact-version entry with watch=osv against OSV (querybatch, with
    pagination, then the full record of every hit); watch=osv-package entries
    (ecosystems OSV does not version-match, e.g. GitHub Actions) fetch every
    advisory of the package and evaluate the affected ranges locally,
  * every watch=github-repo-advisories entry against the upstream repository's
    published GitHub security advisories,
  * CISA KEV, to flag known-exploited CVEs,
then opens or updates GitHub issues in THIS repository. It never changes code,
never opens pull requests, never builds or releases, and holds no secret
beyond the workflow's own issues-scoped token.

Issues (all labelled `security-watch`, each carrying a machine marker):
  finding  one per advisory group (OSV id + its CVE/GHSA aliases, merged).
           New -> created. Changed severity/KEV/affected components/fixed
           versions -> body updated + ONE comment; a closed issue is reopened
           only when it got worse (new component, higher severity, newly KEV).
           No longer matched by a complete run -> one comment, never closed
           automatically (closing is the owner's call once the fix ships).
  gaps     one issue listing the components the watch cannot check
           (unpinned, ranges, OS-owned); updated only when the list changes.
  health   opened (or reopened) when a feed fails or returns incomplete data,
           closed with a comment on the next fully successful run. A failed
           feed never counts as "no advisories".
  node     the newest Node.js security release of every supported LTS line
           (nodejs.org/dist/index.json), informational (users' own Node lines).
           Body updated + one comment when it changes.
  pin      (plan v21 §3.5.1, owner requirement P) one per exactly pinned Node
           in the inventory: open while the pin is BEHIND the newest
           `security: true` release of its own major, or its major is past
           end of life in the Node release schedule. Closed with a comment by
           the first complete run that finds neither (the bump shipped). A
           failed index or schedule fetch leaves it exactly as it is.
  heartbeat one issue whose BODY is rewritten at the end of every run (time,
           run link, per-feed status). A body edit notifies nobody; the owner's
           independent release watcher alerts when it is older than 36 h, so a
           job that stops running is a state change, not silence. A gap of
           more than 36 h since the previous run gets one comment.
Triage: an open finding with no reachability label (`reachable` /
`not-reachable`) gets the `triage-overdue` label and one comment after 7 days
(HIGH/CRITICAL or KEV) or 30 days (otherwise); the label goes away once the
owner labels it.
Nothing else is posted when nothing changed: no daily "all clear".

Untrusted feed text is bounded and neutralised (no @-mentions, no HTML
comments that could forge a marker, no control characters).

Usage:
  security_watch.py [--dry-run] [--inventory PATH]
                    [--osv-api URL] [--github-api URL] [--kev-url URL] [--node-index URL]
                    [--node-schedule URL] [--node-wg URL]
                    [--repo OWNER/NAME]
Environment: GITHUB_TOKEN (required unless --dry-run), GITHUB_REPOSITORY.
Exit: 0 healthy run, 1 a feed failed or was incomplete (health issue raised),
      2 configuration/usage error or a GitHub write failed.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_INVENTORY = os.path.join(ROOT, "security", "dependencies.json")
OSV_API = "https://api.osv.dev"
GITHUB_API = "https://api.github.com"
KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
NODE_INDEX = "https://nodejs.org/dist/index.json"
NODE_SCHEDULE = "https://raw.githubusercontent.com/nodejs/Release/main/schedule.json"
NODE_WG = "https://raw.githubusercontent.com/nodejs/security-wg/main/vuln/core/index.json"
NODE_MIN_MAJOR = 20          # ManagedPlaywright.minimumNodeMajor
HEARTBEAT_GAP_HOURS = 36
REACHABILITY = ("reachable", "not-reachable")
OVERDUE = "triage-overdue"
TRIAGE_DAYS_URGENT, TRIAGE_DAYS = 7, 30

LABEL = "security-watch"
MARKER_RE = re.compile(r"<!-- briglia-security-watch v1 kind=(finding|gaps|health|node|heartbeat|curation|pin) ids=([A-Za-z0-9:._,-]*) fp=([0-9a-f]{16}) -->")
MAX_BYTES = 32 * 1024 * 1024
MAX_PAGES = 25
MAX_VULNS = 400
MAX_FINDINGS = 200
BATCH = 500
SEVERITY_ORDER = {"UNKNOWN": 0, "LOW": 1, "MODERATE": 2, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}
BACKOFF = float(os.environ.get("SECURITY_WATCH_BACKOFF", "2"))


class FeedError(Exception):
    pass


class WriteError(Exception):
    pass


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def http(method, url, body=None, headers=None, timeout=30, retries=2):
    """(status, parsed JSON or None, response headers). Retries 5xx/network errors."""
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Accept": "application/json", "User-Agent": "briglia-security-watch"}
    if data is not None:
        hdrs["Content-Type"] = "application/json"
    hdrs.update(headers or {})
    last = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES:
                    raise FeedError(f"{method} {url}: response larger than {MAX_BYTES} bytes")
                parsed = json.loads(raw) if raw.strip() else None
                return resp.status, parsed, dict(resp.headers)
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
            if e.code < 500 and e.code != 429:
                raw = e.read(65536)
                try:
                    parsed = json.loads(raw) if raw.strip() else None
                except ValueError:
                    parsed = None
                return e.code, parsed, dict(e.headers or {})
        except (urllib.error.URLError, OSError, ValueError) as e:
            last = f"{type(e).__name__}: {e}"
        if attempt < retries:
            time.sleep(BACKOFF * (attempt + 1))
    raise FeedError(f"{method} {url}: {last}")


def next_link(headers):
    link = headers.get("Link") or headers.get("link") or ""
    for part in link.split(","):
        m = re.match(r'\s*<([^>]+)>;\s*rel="next"', part)
        if m:
            return m.group(1)
    return None


# ---------------------------------------------------------------------------
# Text hygiene for untrusted feed content
# ---------------------------------------------------------------------------

def clean(text, limit=300):
    text = "" if text is None else str(text)
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", " ", text)
    text = text.replace("<!--", "&lt;!--").replace("-->", "--&gt;")
    text = text.replace("@", "@​")
    text = re.sub(r"\s+", " ", text).strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{1,79}$")


def valid_id(i):
    return isinstance(i, str) and bool(ID_RE.match(i))


# ---------------------------------------------------------------------------
# Version ranges (GitHub repository advisories)
# ---------------------------------------------------------------------------

def parse_semver(v):
    v = v.strip().lstrip("vV")
    m = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$", v)
    if not m:
        return None
    nums = tuple(int(x or 0) for x in m.group(1, 2, 3))
    pre = m.group(4)
    pre_key = (1,) if pre is None else (0,) + tuple((0, int(p)) if p.isdigit() else (1, p) for p in pre.split("."))
    return nums + (pre_key,)


def in_range(version, rng):
    """True/False when `rng` (e.g. ">= 1.0.0, < 1.3.1") can be evaluated, else None."""
    v = parse_semver(version or "")
    if v is None or not isinstance(rng, str) or not rng.strip():
        return None
    for clause in rng.split(","):
        m = re.match(r"^\s*(>=|<=|>|<|=)?\s*(\S+)\s*$", clause)
        if not m:
            return None
        op, bound = m.group(1) or "=", parse_semver(m.group(2))
        if bound is None:
            return None
        ok = {">=": v >= bound, "<=": v <= bound, ">": v > bound, "<": v < bound, "=": v == bound}[op]
        if not ok:
            return False
    return True


# ---------------------------------------------------------------------------
# Feeds
# ---------------------------------------------------------------------------

def osv_query(components, api):
    """{vuln_id: set(component ids)} for every OSV-watched component."""
    watched = [c for c in components if c["watch"] in ("osv", "osv-package")]
    hits = {}
    for start in range(0, len(watched), BATCH):
        chunk = watched[start:start + BATCH]
        pending = [(i, None) for i in range(len(chunk))]
        pages = 0
        while pending:
            pages += 1
            if pages > MAX_PAGES:
                raise FeedError("OSV querybatch: too many pages (results incomplete)")
            queries = []
            for i, token in pending:
                c = chunk[i]
                q = {"package": {"ecosystem": c["ecosystem"], "name": c["name"]}}
                if c["watch"] == "osv":
                    q["version"] = c["version"]  # osv-package: every advisory of the package, ranges checked locally
                if token:
                    q["page_token"] = token
                queries.append(q)
            status, data, _ = http("POST", f"{api}/v1/querybatch", {"queries": queries})
            if status != 200 or not isinstance(data, dict) or not isinstance(data.get("results"), list) \
                    or len(data["results"]) != len(queries):
                raise FeedError(f"OSV querybatch: unexpected response (HTTP {status})")
            nxt = []
            for (i, _), res in zip(pending, data["results"]):
                if not isinstance(res, dict):
                    raise FeedError("OSV querybatch: malformed result")
                vulns = res.get("vulns", [])   # omitted = no advisories; present must be a list
                token = res.get("next_page_token")
                if not isinstance(vulns, list) or (token is not None and not isinstance(token, str)):
                    raise FeedError("OSV querybatch: malformed result")
                for v in vulns:
                    vid = v.get("id") if isinstance(v, dict) else None
                    if not valid_id(vid):
                        raise FeedError("OSV querybatch: malformed vulnerability id")
                    hits.setdefault(vid, set()).add(chunk[i]["id"])
                token = res.get("next_page_token")
                if token:
                    nxt.append((i, token))
            pending = nxt
    if len(hits) > MAX_VULNS:
        raise FeedError(f"OSV: {len(hits)} vulnerabilities exceed the per-run bound {MAX_VULNS}")
    return hits


def osv_record(vid, api):
    status, data, _ = http("GET", f"{api}/v1/vulns/{urllib.parse.quote(vid)}")
    if status != 200 or not isinstance(data, dict) or data.get("id") != vid:
        raise FeedError(f"OSV vulns/{vid}: unexpected response (HTTP {status})")
    problem = osv_record_problem(data)
    if problem:
        raise FeedError(f"OSV vulns/{vid}: malformed record ({problem})")
    return data


EVENT_KINDS = ("introduced", "fixed", "last_affected", "limit")


def osv_record_problem(rec):
    """None when every structure the watch consumes has the schema's type;
    else what is wrong. Omitted optional fields are fine; a present field of
    the wrong type is not (it would otherwise be read as 'nothing there')."""
    def opt(obj, key, typ):
        return key not in obj or isinstance(obj[key], typ)
    if not opt(rec, "aliases", list) or not all(isinstance(a, str) for a in rec.get("aliases", [])):
        return "aliases"
    for key, typ in (("affected", list), ("references", list), ("database_specific", dict), ("summary", str),
                     ("details", str), ("withdrawn", str)):
        if not opt(rec, key, typ):
            return key
    if not all(isinstance(r, dict) for r in rec.get("references", [])):
        return "references"
    for aff in rec.get("affected", []):
        if not isinstance(aff, dict) or not opt(aff, "package", dict) or not opt(aff, "versions", list) \
                or not opt(aff, "ranges", list):
            return "affected entry"
        if not all(isinstance(v, str) for v in aff.get("versions", [])):
            return "affected versions"
        pkg = aff.get("package", {})
        if not opt(pkg, "name", str) or not opt(pkg, "ecosystem", str):
            return "affected package"
        for r in aff.get("ranges", []):
            if not isinstance(r, dict) or not isinstance(r.get("type"), str) or not isinstance(r.get("events"), list):
                return "range"
            for ev in r["events"]:
                if not isinstance(ev, dict) or len(ev) != 1 or next(iter(ev)) not in EVENT_KINDS \
                        or not isinstance(next(iter(ev.values())), str):
                    return "range event"
    return None


def severity_of(record):
    ds = record.get("database_specific") or {}
    sev = str(ds.get("severity") or "").upper()
    return sev if sev in SEVERITY_ORDER else "UNKNOWN"


def fixed_versions(record, component):
    out = set()
    for aff in record.get("affected") or []:
        pkg = aff.get("package") or {}
        if pkg.get("name") != component["name"] or pkg.get("ecosystem") != component["ecosystem"]:
            continue
        for r in aff.get("ranges") or []:
            for ev in r.get("events") or []:
                if isinstance(ev, dict) and isinstance(ev.get("fixed"), str):
                    out.add(clean(ev["fixed"], 60))
    return out


# Ecosystems whose version order is SemVer-like enough to evaluate locally
# (osv-package is only used for these). Anything else stays "unknown".
LOCAL_RANGE_ECOSYSTEMS = ("GitHub Actions",)
ZERO, INF = "0", "*"


def _range_verdict(v, events):
    """OSV schema evaluation (BeforeLimits + sorted events) of one range for
    parsed version `v`: True/False, or None when the range is malformed or
    ambiguous (two events at the same version)."""
    limits, ordered = [], []
    for ev in events:
        if not isinstance(ev, dict) or len(ev) != 1:
            return None
        (kind, ver), = ev.items()
        if kind not in ("introduced", "fixed", "last_affected", "limit") or not isinstance(ver, str):
            return None
        if kind == "limit":
            if ver == INF:
                limits.append(None)
                continue
            b = parse_semver(ver)
            if b is None:
                return None
            limits.append(b)
            continue
        if kind == "introduced" and ver == ZERO:
            b = (-1,)                       # sorts before every version
        else:
            b = parse_semver(ver)
            if b is None:
                return None
        ordered.append((b, kind))
    if not ordered or not any(k == "introduced" for _, k in ordered):
        return None
    keys = [b for b, _ in ordered]
    if len(set(keys)) != len(keys):
        return None                         # ties have no defined order: stay unknown
    if limits and not any(l is None or v < l for l in limits):
        return False                        # at or above every limit
    vulnerable = False
    for b, kind in sorted(ordered):
        if kind == "introduced" and (b == (-1,) or v >= b):
            vulnerable = True
        elif kind == "fixed" and v >= b:
            vulnerable = False
        elif kind == "last_affected" and v > b:
            vulnerable = False
    return vulnerable


def osv_affects(record, component):
    """Local evaluation of an OSV record's ranges for `component`'s version:
    True/False, or None when no range of the package can be evaluated."""
    v = parse_semver(component.get("version") or "")
    verdicts = []
    for aff in record.get("affected") or []:
        if not isinstance(aff, dict):
            verdicts.append(None)
            continue
        pkg = aff.get("package") or {}
        if pkg.get("name") != component["name"] or pkg.get("ecosystem") != component["ecosystem"]:
            continue
        if component.get("version") in (aff.get("versions") or []):
            return True
        for r in aff.get("ranges") or []:
            if not isinstance(r, dict) or r.get("type") not in ("ECOSYSTEM", "SEMVER") or v is None \
                    or component["ecosystem"] not in LOCAL_RANGE_ECOSYSTEMS or not isinstance(r.get("events"), list):
                verdicts.append(None)
                continue
            verdicts.append(_range_verdict(v, r["events"]))
    if any(x is True for x in verdicts):
        return True
    if verdicts and all(x is False for x in verdicts):
        return False
    return None


def repo_advisories(component, api, token):
    """Published advisories of the upstream repo that (may) affect the component."""
    url = f"{api}/repos/{component['name']}/security-advisories?state=published&per_page=100"
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    out, pages = [], 0
    while url:
        pages += 1
        if pages > MAX_PAGES:
            raise FeedError(f"advisories of {component['name']}: too many pages")
        status, data, hdrs = http("GET", url, headers=headers)
        if status != 200 or not isinstance(data, list):
            raise FeedError(f"advisories of {component['name']}: HTTP {status}")
        for adv in data:
            gid = adv.get("ghsa_id") if isinstance(adv, dict) else None
            if not valid_id(gid) or not isinstance(adv.get("vulnerabilities"), list):
                raise FeedError(f"advisories of {component['name']}: malformed advisory record")
            if not all(isinstance(v, dict) and isinstance(v.get("vulnerable_version_range"), (str, type(None)))
                       for v in adv["vulnerabilities"]):
                raise FeedError(f"advisories of {component['name']}: malformed vulnerability entry")
            if adv.get("withdrawn_at"):
                continue
            ranges = [v.get("vulnerable_version_range") for v in adv["vulnerabilities"] if isinstance(v, dict)]
            verdicts = [in_range(component.get("version"), r) for r in ranges] or [None]
            if any(v is True for v in verdicts):
                applies = "affected"
            elif all(v is False for v in verdicts):
                continue
            else:
                applies = "applicability unknown (version not pinned or range not evaluable)"
            ids = [gid] + ([adv["cve_id"]] if valid_id(adv.get("cve_id")) else [])
            fixed = {clean(v.get("patched_versions"), 60) for v in adv.get("vulnerabilities") or []
                     if isinstance(v, dict) and v.get("patched_versions")}
            sev = str(adv.get("severity") or "").upper()
            out.append({"ids": ids, "summary": adv.get("summary"), "severity": sev if sev in SEVERITY_ORDER else "UNKNOWN",
                        "fixed": fixed, "applies": applies, "url": adv.get("html_url")})
        url = next_link(hdrs)
    return out


def kev_set(url):
    status, data, _ = http("GET", url)
    if status != 200 or not isinstance(data, dict) or not isinstance(data.get("vulnerabilities"), list):
        raise FeedError(f"CISA KEV: unexpected response (HTTP {status})")
    if not all(isinstance(v, dict) and valid_id(v.get("cveID")) for v in data["vulnerabilities"]):
        raise FeedError("CISA KEV: malformed catalogue entry")
    out = {v["cveID"] for v in data["vulnerabilities"]}
    if not out:
        raise FeedError("CISA KEV: empty catalogue (the real one lists over a thousand CVEs)")
    return out


def node_index(url):
    """The validated release rows of nodejs.org/dist/index.json."""
    status, data, _ = http("GET", url)
    if status != 200 or not isinstance(data, list) or not data:
        raise FeedError(f"Node release index: unexpected response (HTTP {status})")
    for rel in data:
        v = parse_semver(str(rel.get("version") or "")) if isinstance(rel, dict) else None
        if v is None or not isinstance(rel.get("security"), bool) or not isinstance(rel.get("lts"), (str, bool)):
            raise FeedError("Node release index: malformed release row")
    return data


def node_security_releases(url, rows=None):
    """{major: newest security release "vX.Y.Z"} for every LTS line >= NODE_MIN_MAJOR."""
    data = node_index(url) if rows is None else rows
    out, lts_seen = {}, False
    for rel in data:
        v = parse_semver(str(rel.get("version") or ""))
        if not rel["lts"]:
            continue
        lts_seen = True
        major = v[0]
        if major < NODE_MIN_MAJOR or rel["security"] is not True:
            continue
        if major not in out or v > parse_semver(out[major]):
            out[major] = clean(rel["version"], 20)
    if not lts_seen:
        raise FeedError("Node release index: no LTS releases listed")
    if not out:
        raise FeedError(f"Node release index: no security release on any LTS line >= {NODE_MIN_MAJOR}")
    return out


def node_newest_security(rows, major):
    """Newest `security: true` release of `major` ("vX.Y.Z"), or None when that major has none."""
    best = None
    for rel in rows:
        v = parse_semver(str(rel.get("version") or ""))
        if v is None or v[0] != major or rel.get("security") is not True:
            continue
        if best is None or v > parse_semver(best):
            best = clean(rel["version"], 20)
    return best


DATE_RE = re.compile(r"^\d{4}-\d\d-\d\d$")


def node_schedule(url):
    """{major: end-of-life date "YYYY-MM-DD"} from the Node release schedule."""
    status, data, _ = http("GET", url)
    if status != 200 or not isinstance(data, dict) or not data:
        raise FeedError(f"Node release schedule: unexpected response (HTTP {status})")
    out = {}
    for key, val in data.items():
        m = re.match(r"^v(\d+)$", key) if isinstance(key, str) else None
        if not m:
            continue   # "v0.10"-style historic keys
        if not isinstance(val, dict) or not isinstance(val.get("end"), str) or not DATE_RE.match(val["end"]):
            raise FeedError(f"Node release schedule: {clean(key, 20)} has no valid end date")
        out[int(m.group(1))] = val["end"]
    if not out:
        raise FeedError("Node release schedule: no release lines")
    return out


def node_pin_blockers(version, rows, schedule, today):
    """Blocker tokens for an exactly pinned Node `version` (plan v21 §3.5.1).
    Raises FeedError when the pin cannot be evaluated (never "fine" on missing data)."""
    v = parse_semver(version) if isinstance(version, str) and re.match(r"^\d+\.\d+\.\d+$", version) else None
    if v is None:
        raise FeedError(f"pinned Node version {clean(version, 30)!r} is not X.Y.Z")
    major = v[0]
    if not any(str(r.get("version")) == "v" + version for r in rows):
        raise FeedError(f"Node release index does not list the pinned release v{version} (truncated index?)")
    out = []
    newest = node_newest_security(rows, major)
    if newest is not None and parse_semver(newest) > v:
        out.append(f"node-behind:{newest}")
    end = schedule.get(major)
    if end is None:
        raise FeedError(f"Node release schedule does not list the pinned major v{major}")
    if end <= today:
        out.append(f"node-eol:{major}")
    return out


def node_wg(url):
    """The Node Security WG core index, shaped and bounded by advisory_node.py."""
    import advisory_node
    status, data, _ = http("GET", url)
    if status != 200:
        raise FeedError(f"Node Security WG index: HTTP {status}")
    try:
        return advisory_node._shape_wg(data)
    except advisory_node.NodeFeedError as e:
        raise FeedError(f"Node Security WG index: {e}")


def _in_ranges(ver, ranges):
    for r in ranges:
        ev = r.get("events") or []
        lo = next((e["introduced"] for e in ev if "introduced" in e), None)
        hi = next((e.get("fixed") or e.get("limit") for e in ev if "fixed" in e or "limit" in e), None)
        if lo is None or hi is None:
            return None
        import advisory_node
        a, b = advisory_node.parse_version(lo), advisory_node.parse_version(hi)
        if a is None or b is None:
            return None
        if a <= ver < b:
            return True
    return False


def node_pin_findings(component, wg, rows):
    """Raw findings (merge_findings shape) for the exactly pinned Node: every
    WG core entry that affects the pin on either target platform, or whose
    applicability is unknown, with or without a fix (plan v22 §3.5.1, R21-1)."""
    import advisory_node
    ver = advisory_node.parse_version(component["version"])
    if ver is None:
        raise FeedError(f"pinned Node version {clean(component['version'], 30)!r} is not X.Y.Z")
    released = {str(r.get("version", "")).lstrip("v") for r in rows}
    out = []
    for key in sorted(wg, key=int):
        entry = wg[key]
        verdicts, fixed = [], set()
        for platform in ("darwin", "linux"):
            a = advisory_node.wg_advisory(key, entry, platform, released)
            if a is None:
                continue
            if a["affected"] == "unknown":
                if a.get("_unknownLines") or ver[0] in a.get("_lines", []) or not a.get("_lines"):
                    verdicts.append(None)
                continue
            hit = _in_ranges(ver, a["affected"]["ranges"])
            verdicts.append(hit)
            if hit and a.get("_patched", {}).get(ver[0]):
                fixed.add(a["_patched"][ver[0]])
        if not verdicts or all(v is False for v in verdicts):
            continue
        applies = "affected (Node Security WG range)" if any(v is True for v in verdicts) else \
            "applicability unknown (WG entry not evaluable)"
        ids = sorted({c for c in (entry.get("cve") or []) if isinstance(c, str) and valid_id(c)}) or [f"NSWG-CORE-{key}"]
        sev = str(entry.get("severity") or "").upper()
        out.append({"ids": ids, "summary": f"Node.js core advisory {ids[0]} (Security WG entry {key})",
                    "severity": sev if sev in SEVERITY_ORDER else "UNKNOWN", "components": {component["id"]},
                    "fixed": fixed, "applies": applies,
                    "url": f"https://github.com/nodejs/security-wg/blob/main/vuln/core/{key}.json"})
    return out


def pin_doc(component, blockers, newest, end):
    """One `pin` issue per exactly pinned Node (plan v21 §3.5.1)."""
    fp = fingerprint(component["id"], component.get("version"), sorted(blockers))
    lines = [f"Briglia's pinned **{component['name']} {component.get('version')}** is stale (owner requirement P, plan v21 §3.5):", ""]
    for b in sorted(blockers):
        if b.startswith("node-behind:"):
            lines.append(f"- behind: Node published security release {b.split(':', 1)[1]} on the pinned line (blocker `{b}`)")
        elif b.startswith("node-eol:"):
            lines.append(f"- end of life: the Node release schedule ends line v{b.split(':', 1)[1]} on {end} (blocker `{b}`)")
    lines += ["", "Affected inventory components:",
              f"- `{component['id']}` — {component['name']} {component.get('version')} · owner {component['owner']} · {component['source'].split(':')[0]}",
              "", f"Newest security release on the pinned line: {newest or 'none listed'} · line end of life: {end}",
              "", "The release gate (scripts/pin_gate.py) refuses to tag or sign until the pin is bumped in an ordinary "
              "reviewed, phone-signed release or the owner commits an expiring override. Closed automatically by the "
              "first complete run after the bump.",
              "", f"<!-- briglia-security-watch v1 kind=pin ids={component['id']} fp={fp} -->"]
    return {"kind": "pin", "ids": [component["id"]], "fp": fp,
            "title": clean(f"[security-watch] pinned {component['name']} {component.get('version')} is stale: " + ", ".join(sorted(blockers)), 200),
            "body": "\n".join(lines), "components": [component["id"]]}


def pinned_nodes(components):
    return [c for c in components if c.get("watch") == "node-releases" and c.get("pin_kind") == "exact" and c.get("version")]


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------

def primary_id(ids):
    for prefix in ("GHSA-", "CVE-"):
        pick = sorted(i for i in ids if i.startswith(prefix))
        if pick:
            return pick[0]
    return sorted(ids)[0]


def merge_findings(raw):
    """raw: list of {ids, summary, severity, kev?, components, fixed, applies, url}. Union by shared id."""
    groups = []
    for item in raw:
        ids = set(item["ids"])
        merged = [g for g in groups if g["ids"] & ids]
        target = {"ids": ids, "summaries": [], "severity": "UNKNOWN", "components": set(), "fixed": set(),
                  "applies": set(), "urls": set()}
        for g in merged:
            groups.remove(g)
            for k in ("ids", "components", "fixed", "applies", "urls"):
                target[k] |= g[k]
            target["summaries"] += g["summaries"]
            target["severity"] = max(target["severity"], g["severity"], key=SEVERITY_ORDER.get)
        target["components"] |= set(item["components"])
        target["fixed"] |= set(item.get("fixed") or ())
        target["applies"].add(item.get("applies") or "affected")
        if item.get("url"):
            target["urls"].add(clean(item["url"], 200))
        if item.get("summary"):
            target["summaries"].append(clean(item["summary"]))
        target["severity"] = max(target["severity"], item["severity"], key=SEVERITY_ORDER.get)
        groups.append(target)
    return groups


def fingerprint(*parts):
    return hashlib.sha256(json.dumps(parts, sort_keys=True, default=sorted).encode()).hexdigest()[:16]


def finding_doc(g, kev, by_id):
    ids = sorted(g["ids"])
    is_kev = any(i in kev for i in ids)
    comps = sorted(g["components"])
    fp = fingerprint(ids, g["severity"], is_kev, [[c, by_id[c].get("version")] for c in comps], sorted(g["fixed"]), sorted(g["applies"]))
    pid = primary_id(ids)
    names = ", ".join(f"{by_id[c]['name']} {by_id[c].get('version') or '(unpinned)'}" for c in comps)
    title = clean(f"[security] {pid} {g['severity']}{' KEV' if is_kev else ''} — {names}", 200)
    summary = next((s for s in g["summaries"] if s), "(no summary)")
    lines = [
        f"**{pid}** · severity **{g['severity']}**" + (" · **listed in CISA KEV (exploited in the wild)**" if is_kev else ""),
        "",
        f"Summary (from the feed, untrusted): {summary}",
        "",
        f"Aliases: {', '.join(ids)}",
        "",
        "Affected inventory components:",
    ]
    for c in comps:
        comp = by_id[c]
        lines.append(f"- `{c}` — {comp['name']} {comp.get('version') or '(unpinned)'} · owner {comp['owner']} · {comp['source'].split(':')[0]}")
    lines += ["", f"Fixed versions in the feed: {', '.join(sorted(g['fixed'])) or 'none listed'}",
              f"Applicability: {'; '.join(sorted(g['applies']))}"]
    if g["urls"]:
        lines.append("Advisory: " + " ".join(sorted(g["urls"])))
    lines += ["", "Next step (manual): triage reachability; if a fix is needed, bump the pin after the 72 h "
              "upstream cooldown in an ordinary reviewed, phone-signed release. This job never changes code.",
              "", f"<!-- briglia-security-watch v1 kind=finding ids={','.join(ids)} fp={fp} -->"]
    return {"kind": "finding", "ids": ids, "fp": fp, "title": title, "body": "\n".join(lines),
            "severity": g["severity"], "kev": is_kev, "components": comps}


def gaps_doc(components):
    gaps = sorted((c["id"], c.get("gap") or "") for c in components if c["watch"] not in ("osv", "osv-package") and c.get("gap"))
    fp = fingerprint(gaps)
    lines = ["Components the daily watch cannot check automatically (no exact version, no OSV coverage, or OS-owned).",
             "This issue changes only when the list changes.", ""]
    lines += [f"- `{i}` — {clean(r, 400)}" for i, r in gaps]
    lines += ["", f"<!-- briglia-security-watch v1 kind=gaps ids=gaps fp={fp} -->"]
    return {"kind": "gaps", "ids": ["gaps"], "fp": fp, "title": f"[security-watch] coverage gaps ({len(gaps)} components)",
            "body": "\n".join(lines)}


def health_doc(failures):
    fp = fingerprint(sorted(failures))
    lines = ["The security watch could not complete a full check. Missing data is NOT treated as \"no advisories\".", ""]
    lines += [f"- {clean(f, 400)}" for f in sorted(failures)]
    lines += ["", "Closed automatically by the next fully successful run.",
              "", f"<!-- briglia-security-watch v1 kind=health ids=health fp={fp} -->"]
    return {"kind": "health", "ids": ["health"], "fp": fp, "title": "[security-watch] watch run failing", "body": "\n".join(lines)}


def node_doc(latest):
    rows = sorted(latest.items())
    fp = fingerprint([[m, v] for m, v in rows])
    lines = ["Informational: the newest Node.js security release of every supported LTS line. Briglia's own Node is an "
             "exact pin tracked by the `pin` issue (plan v21 §3.5.1); this list is about the Node lines users run "
             "themselves (nvm, nodejs.org, distribution packages), which the local-tools check covers on the client.",
             "", "Newest security release per LTS line (nodejs.org/dist/index.json):", ""]
    lines += [f"- Node {m}: {v}" for m, v in rows] or ["- (none listed)"]
    lines += ["", "No action needed for Briglia itself unless the `pin` issue is open.",
              "", f"<!-- briglia-security-watch v1 kind=node ids=node-security fp={fp} -->"]
    return {"kind": "node", "ids": ["node-security"], "fp": fp, "title": "[security-watch] Node.js security releases",
            "body": "\n".join(lines)}


def curation_doc(findings):
    """R6 (plan v20 §9.5.10.2): the LibreOffice platform curation needs a
    review. Changes only when the list of findings changes."""
    rows = sorted((f["id"], f["problem"]) for f in findings)
    fp = fingerprint(rows)
    lines = ["The reviewed LibreOffice platform curation (security/libreoffice-platforms.json) needs a review: until it is "
             "updated, these CVEs stay 'unknown' for the macOS website build (never a guess).", ""]
    what = {"missing": "no curation entry", "changed": "its CNA description changed since review",
            "platform-label": "the CNA record uses a platform label Briglia does not recognise"}
    lines += [f"- `{i}` — {what[p]}" for i, p in rows]
    lines += ["" if rows else "- (nothing to review)", "",
              f"<!-- briglia-security-watch v1 kind=curation ids=libreoffice-curation fp={fp} -->"]
    return {"kind": "curation", "ids": ["libreoffice-curation"], "fp": fp,
            "title": f"[security-watch] LibreOffice platform curation needs review ({len(rows)})", "body": "\n".join(lines)}


def load_curation(path):
    """The fetch step's curation findings; None when absent or not complete."""
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    if type(d) is not dict or d.get("schema") != 1 or d.get("complete") is not True or type(d.get("findings")) is not list:
        return None
    out = []
    for x in d["findings"]:
        if type(x) is not dict or not valid_id(str(x.get("id"))) or x.get("problem") not in ("missing", "changed", "platform-label"):
            return None
        out.append({"id": x["id"], "problem": x["problem"]})
    return out[:200]


def heartbeat_doc(now, feeds, run_url, previous_at):
    stamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    fp = fingerprint(sorted(feeds.items()))
    lines = ["The security watch rewrites this description at the end of every run. A description older than "
             f"{HEARTBEAT_GAP_HOURS} h means the job stopped running (the owner's release watcher alerts on that).", "",
             f"last-run: {stamp}", ""]
    if run_url:
        lines += [f"Run: {run_url}", ""]
    lines += ["Feeds:"] + [f"- {name}: {state}" for name, state in sorted(feeds.items())]
    if previous_at:
        lines += ["", f"Previous run: {previous_at}"]
    lines += ["", f"<!-- briglia-security-watch v1 kind=heartbeat ids=heartbeat fp={fp} -->"]
    return {"kind": "heartbeat", "ids": ["heartbeat"], "fp": fp, "title": "[security-watch] heartbeat",
            "body": "\n".join(lines), "stamp": stamp}


LAST_RUN_RE = re.compile(r"^last-run: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$", re.M)


# ---------------------------------------------------------------------------
# GitHub issues
# ---------------------------------------------------------------------------

class Issues:
    def __init__(self, api, repo, token, dry_run):
        self.api, self.repo, self.token, self.dry = api, repo, token, dry_run
        self.actions = []

    def _h(self):
        return {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json"} if self.token else {}

    def load(self):
        url = f"{self.api}/repos/{self.repo}/issues?labels={LABEL}&state=all&per_page=100"
        out, pages = [], 0
        while url:
            pages += 1
            if pages > MAX_PAGES:
                raise WriteError("issue list: too many pages")
            try:
                status, data, hdrs = http("GET", url, headers=self._h())
            except FeedError as e:
                raise WriteError(f"issue list: {e}")
            if status != 200 or not isinstance(data, list):
                raise WriteError(f"issue list: HTTP {status}")
            for it in data:
                if not isinstance(it, dict) or "pull_request" in it:
                    continue
                m = MARKER_RE.search(it.get("body") or "")
                if not m:
                    continue
                out.append({"number": it["number"], "state": it.get("state"), "kind": m.group(1),
                            "ids": [i for i in m.group(2).split(",") if i], "fp": m.group(3),
                            "labels": sorted(l.get("name") for l in it.get("labels") or [] if isinstance(l, dict)),
                            "body": it.get("body") or "", "created_at": it.get("created_at") or ""})
            url = next_link(hdrs)
        out.sort(key=lambda i: i["number"])
        return out

    def _write(self, method, path, body, what):
        self.actions.append((method, path, what))
        if self.dry:
            print(f"  [dry-run] {method} {path}: {what}")
            return {"number": 0}
        try:
            status, data, _ = http(method, f"{self.api}/repos/{self.repo}{path}", body, headers=self._h(), retries=1)
        except FeedError as e:
            raise WriteError(f"{method} {path}: {e}")
        if status not in (200, 201):
            raise WriteError(f"{method} {path}: HTTP {status}")
        return data or {}

    def create(self, doc, labels):
        return self._write("POST", "/issues", {"title": doc["title"], "body": doc["body"], "labels": labels},
                           f"create {doc['kind']} {primary_id(doc['ids'])}")

    def update(self, number, doc, labels, state=None):
        body = {"title": doc["title"], "body": doc["body"], "labels": labels}
        if state:
            body["state"] = state
        return self._write("PATCH", f"/issues/{number}", body, f"update #{number}" + (f" -> {state}" if state else ""))

    def comment(self, number, text):
        return self._write("POST", f"/issues/{number}/comments", {"body": text}, f"comment #{number}")

    def close(self, number):
        return self._write("PATCH", f"/issues/{number}", {"state": "closed"}, f"close #{number}")

    def set_labels(self, number, labels):
        return self._write("PATCH", f"/issues/{number}", {"labels": labels}, f"labels #{number}")


def labels_for(doc):
    out = [LABEL]
    if doc["kind"] == "finding":
        out.append(f"severity:{doc['severity'].lower()}")
        if doc["kev"]:
            out.append("kev")
    return out


UNMATCHED_NOTE = "No longer matched by the current inventory"


def merged_labels(it, doc):
    """Keep labels the owner added; replace only the watch's own severity/KEV labels."""
    own = [l for l in it.get("labels") or [] if l and not l.startswith("severity:") and l not in ("kev", LABEL)]
    return labels_for(doc) + sorted(own)


def parse_time(text):
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return None


def triage_labels(labels, created_at, now):
    """The finding's labels after the reachability-triage rule, or None when unchanged."""
    labels = list(labels)
    if any(l in REACHABILITY for l in labels):
        return [l for l in labels if l != OVERDUE] if OVERDUE in labels else None
    created = parse_time(created_at)
    if created is None or OVERDUE in labels:
        return None
    urgent = "kev" in labels or "severity:high" in labels or "severity:critical" in labels
    days = TRIAGE_DAYS_URGENT if urgent else TRIAGE_DAYS
    return labels + [OVERDUE] if (now - created).total_seconds() > days * 86400 else None


def got_worse(old_body, doc):
    """A closed finding is reopened only when it got worse."""
    old_sev = re.search(r"severity \*\*([A-Z]+)\*\*", old_body)
    old_sev = old_sev.group(1) if old_sev else "UNKNOWN"
    old_kev = "listed in CISA KEV" in old_body
    old_comps = set(re.findall(r"^- `([^`]+)`", old_body, re.M))
    return (SEVERITY_ORDER.get(doc["severity"], 0) > SEVERITY_ORDER.get(old_sev, 0)
            or (doc["kev"] and not old_kev) or bool(set(doc["components"]) - old_comps))


def reconcile(issues, docs, complete, failures, now=None, feeds=None, run_url=None, pin_clear=()):
    """`complete`: every finding source (OSV, repository advisories, KEV) succeeded.
    When it is False, existing findings are left exactly as they are (a failed
    feed is unknown, not "no longer KEV" or "fewer components"); new findings
    are still created and the health issue reports the failure."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    existing = issues.load()
    used = set()
    labels_now = {it["number"]: list(it["labels"]) for it in existing}

    def match(doc):
        for it in existing:
            if it["kind"] == doc["kind"] and set(it["ids"]) & set(doc["ids"]):
                return it
        return None

    for doc in docs:
        it = match(doc)
        if it is None:
            issues.create(doc, labels_for(doc))
            continue
        used.add(it["number"])
        if doc["kind"] == "finding" and not complete:
            continue
        if it["fp"] == doc["fp"] and UNMATCHED_NOTE not in it["body"]:
            continue
        labels = merged_labels(it, doc)
        labels_now[it["number"]] = labels
        if it["state"] == "closed":
            if doc["kind"] == "pin":
                it["state"] = "open"
                issues.update(it["number"], doc, labels, state="open")
                issues.comment(it["number"], "Reopened by the security watch: the pinned version is stale again. "
                                             "See the updated description.")
            elif doc["kind"] != "finding" or got_worse(it["body"], doc):
                it["state"] = "open"
                issues.update(it["number"], doc, labels, state="open")
                issues.comment(it["number"], "Reopened by the security watch: the advisory now affects more, is more "
                                             "severe or is known-exploited. See the updated description.")
            else:
                issues.update(it["number"], doc, labels)  # silent refresh of a closed issue
        else:
            issues.update(it["number"], doc, labels)
            issues.comment(it["number"], "Updated by the security watch: the stale-pin blockers changed. See the updated description."
                           if doc["kind"] == "pin" else
                           "Updated by the security watch: severity, KEV status, affected components "
                           "or fixed versions changed. See the updated description.")

    # Stale-pin issues whose pin was evaluated completely this run and found
    # clear (the bump shipped): one comment, closed. Pins not evaluated
    # (feed failure) are not in `pin_clear` and stay exactly as they are.
    for it in existing:
        if it["kind"] == "pin" and it["state"] == "open" and it["number"] not in used and set(it["ids"]) & set(pin_clear):
            issues.comment(it["number"], "The security watch finds the pinned version current and supported again "
                                         "(newest security release reached, line not past end of life); closing.")
            issues.close(it["number"])

    # Findings no longer matched: only meaningful after a COMPLETE run.
    if complete:
        for it in existing:
            if it["kind"] != "finding" or it["number"] in used or it["state"] != "open":
                continue
            if UNMATCHED_NOTE in it["body"]:
                continue
            note = f"\n\n_{UNMATCHED_NOTE} (pin bumped or advisory withdrawn). Close when the release ships._"
            body = MARKER_RE.sub("", it["body"]).rstrip() + note + "\n\n" + \
                f"<!-- briglia-security-watch v1 kind=finding ids={','.join(it['ids'])} fp={it['fp']} -->"
            issues._write("PATCH", f"/issues/{it['number']}", {"body": body}, f"mark #{it['number']} unmatched")
            issues.comment(it["number"], "The security watch no longer matches this advisory against the current "
                                         "inventory. Close it once the release carrying the fix ships.")

    # Reachability triage: unlabelled open findings past their review deadline.
    # Like every other finding change, only after a complete run.
    for it in existing:
        if not complete or it["kind"] != "finding" or it["state"] != "open":
            continue
        new = triage_labels(labels_now[it["number"]], it["created_at"], now)
        if new is None:
            continue
        issues.set_labels(it["number"], new)
        if OVERDUE in new:
            issues.comment(it["number"], "Reachability triage is overdue: label this `reachable` or `not-reachable` "
                                         f"(review within {TRIAGE_DAYS_URGENT} days for HIGH/CRITICAL or KEV, "
                                         f"{TRIAGE_DAYS} days otherwise).")

    health = [it for it in existing if it["kind"] == "health"]
    if failures:
        doc = health_doc(failures)
        if not health:
            issues.create(doc, labels_for(doc))
        else:
            it = health[0]
            if it["state"] == "closed" or it["fp"] != doc["fp"]:
                issues.update(it["number"], doc, labels_for(doc), state="open" if it["state"] == "closed" else None)
                issues.comment(it["number"], "The security watch is failing again or failing differently.")
    else:
        for it in health:
            if it["state"] == "open":
                issues.comment(it["number"], "The security watch completed a full check again; closing.")
                issues.close(it["number"])

    # Heartbeat LAST: a run that failed before this point leaves it stale.
    if feeds is not None:
        beats = [it for it in existing if it["kind"] == "heartbeat"]
        previous = None
        if beats:
            m = LAST_RUN_RE.search(beats[0]["body"])
            previous = m.group(1) if m else None
        doc = heartbeat_doc(now, feeds, run_url, previous)
        if not beats:
            issues.create(doc, [LABEL])
        else:
            it = beats[0]
            issues.update(it["number"], doc, [LABEL] + [l for l in it["labels"] if l != LABEL],
                          state="open" if it["state"] == "closed" else None)
            prev = parse_time(previous)
            if prev is not None and (now - prev).total_seconds() > HEARTBEAT_GAP_HOURS * 3600:
                issues.comment(it["number"], f"Gap: the previous run was {(now - prev).total_seconds() / 3600:.0f} h ago "
                                             f"(more than {HEARTBEAT_GAP_HOURS} h). Scheduled runs were missed.")


# ---------------------------------------------------------------------------

def load_inventory(path):
    with open(path, encoding="utf-8") as f:
        inv = json.load(f)
    if inv.get("schema") != 1 or not isinstance(inv.get("components"), list):
        raise ValueError("inventory: expected schema 1 with a components list")
    for c in inv["components"]:
        for k in ("id", "name", "watch", "owner", "source"):
            if not isinstance(c.get(k), str) or not c[k]:
                raise ValueError(f"inventory: component lacks {k}: {c!r}"[:200])
    return inv["components"]


def run(args):
    components = load_inventory(args.inventory)
    by_id = {c["id"]: c for c in components}
    failures, raw, complete = [], [], True
    feeds = {}

    osv_raw = []
    try:
        hits = osv_query(components, args.osv_api)
        for vid in sorted(hits):
            rec = osv_record(vid, args.osv_api)
            if rec.get("withdrawn"):
                continue
            ids = [vid] + [a for a in rec.get("aliases") or [] if valid_id(a)]
            comps, applies = set(), "affected (OSV matched the exact version)"
            for cid in hits[vid]:
                if by_id[cid]["watch"] == "osv-package":
                    verdict = osv_affects(rec, by_id[cid])
                    if verdict is False:
                        continue
                    if verdict is None:
                        applies = "applicability unknown (affected range not evaluable)"
                comps.add(cid)
            if not comps:
                continue
            fixed = set()
            for cid in comps:
                fixed |= fixed_versions(rec, by_id[cid])
            urls = [r.get("url") for r in rec.get("references") or [] if isinstance(r, dict)
                    and r.get("type") == "ADVISORY" and isinstance(r.get("url"), str)][:2]
            osv_raw.append({"ids": ids, "summary": rec.get("summary") or rec.get("details", "")[:300],
                        "severity": severity_of(rec), "components": comps, "fixed": fixed,
                        "applies": applies, "url": urls[0] if urls else None})
        raw += osv_raw   # only a complete OSV pass contributes (no partial alias groups)
        feeds["OSV"] = f"ok ({len(hits)} advisory record(s))"
    except FeedError as e:
        failures.append(f"OSV: {e}")
        feeds["OSV"] = "FAILED"
        complete = False

    for c in components:
        if c["watch"] != "github-repo-advisories":
            continue
        try:
            advs = repo_advisories(c, args.github_api, args.token)
            for adv in advs:
                adv["components"] = {c["id"]}
                raw.append(adv)
            feeds[f"GitHub advisories {c['name']}"] = f"ok ({len(advs)} relevant)"
        except FeedError as e:
            failures.append(f"GitHub advisories ({c['name']}): {e}")
            feeds[f"GitHub advisories {c['name']}"] = "FAILED"
            complete = False

    try:
        kev = kev_set(args.kev_url)
        feeds["CISA KEV"] = f"ok ({len(kev)} CVEs)"
    except FeedError as e:
        failures.append(f"KEV: {e}")
        feeds["CISA KEV"] = "FAILED"
        kev = set()  # NEW findings are still posted (KEV unknown); existing ones are left as they are
        complete = False

    node, node_rows = None, None
    try:
        node_rows = node_index(args.node_index)
        node = node_security_releases(args.node_index, rows=node_rows)
        feeds["Node.js releases"] = "ok (" + ", ".join(f"{m}: {v}" for m, v in sorted(node.items())) + ")"
    except FeedError as e:
        failures.append(f"Node releases: {e}")
        feeds["Node.js releases"] = "FAILED"

    # Owner requirement P (plan v21 §3.5.1): every exactly pinned Node is
    # checked against its own line. Evaluated only on a complete index AND
    # schedule; otherwise existing `pin` issues are left exactly as they are.
    pin_docs, pin_clear = [], set()
    pins = pinned_nodes(components)
    if pins:
        try:
            wg = node_wg(args.node_wg)
            if node_rows is None:
                raise FeedError("Node release index unavailable (needed to cross-check WG patched versions)")
            wg_raw = []
            for c in pins:
                wg_raw += node_pin_findings(c, wg, node_rows)
            raw += wg_raw   # only a complete WG pass contributes
            feeds["Node.js Security WG"] = f"ok ({len(wg)} entries, {len(wg_raw)} affecting the pin)"
        except FeedError as e:
            failures.append(f"Node Security WG: {e}")
            feeds["Node.js Security WG"] = "FAILED"
            complete = False
        schedule = None
        try:
            schedule = node_schedule(args.node_schedule)
            feeds["Node.js schedule"] = f"ok ({len(schedule)} lines)"
        except FeedError as e:
            failures.append(f"Node schedule: {e}")
            feeds["Node.js schedule"] = "FAILED"
        if node_rows is not None and schedule is not None:
            today = (getattr(args, "today", None) or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
            for c in pins:
                try:
                    blockers = node_pin_blockers(c["version"], node_rows, schedule, today)
                except FeedError as e:
                    failures.append(f"Node pin {c['id']}: {e}")
                    feeds[f"Node pin {c['id']}"] = "FAILED"
                    continue
                major = parse_semver(c["version"])[0]
                feeds[f"Node pin {c['id']}"] = ("stale: " + ", ".join(blockers)) if blockers else f"ok ({c['version']})"
                if blockers:
                    pin_docs.append(pin_doc(c, blockers, node_newest_security(node_rows, major), schedule.get(major)))
                else:
                    pin_clear.add(c["id"])

    groups = merge_findings(raw)
    if len(groups) > MAX_FINDINGS:
        failures.append(f"{len(groups)} findings exceed the per-run bound {MAX_FINDINGS}; only the first {MAX_FINDINGS} posted")
        complete = False
        groups = sorted(groups, key=lambda g: (-SEVERITY_ORDER.get(g["severity"], 0), primary_id(g["ids"])))[:MAX_FINDINGS]
    docs = [finding_doc(g, kev, by_id) for g in groups] + [gaps_doc(components)]
    if node is not None:
        docs.append(node_doc(node))
    docs += pin_docs
    if getattr(args, "curation", None):
        cur = load_curation(args.curation)
        if cur is None:
            feeds["LibreOffice curation"] = "not checked (no complete fetch this run)"
        else:
            docs.append(curation_doc(cur))
            feeds["LibreOffice curation"] = f"ok ({len(cur)} to review)"

    print(f"security watch: {len(components)} components, {sum(1 for c in components if c['watch'] in ('osv', 'osv-package'))} OSV-checked, "
          f"{len(groups)} advisory group(s), {len(failures)} feed problem(s)")
    for d in docs:
        if d["kind"] == "finding":
            print(f"  · {d['title']}")
    for f in failures:
        print(f"  ✖ {f}")

    issues = Issues(args.github_api, args.repo, args.token, args.dry_run)
    run_url = None
    if os.environ.get("GITHUB_RUN_ID", "").isdigit() and args.repo:
        run_url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{args.repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    reconcile(issues, docs, complete, failures, feeds=feeds, run_url=run_url, pin_clear=pin_clear)
    print(f"github writes: {len(issues.actions)}{' (dry run, none sent)' if args.dry_run else ''}")
    return 1 if failures else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--inventory", default=DEFAULT_INVENTORY)
    p.add_argument("--osv-api", default=OSV_API)
    p.add_argument("--github-api", default=GITHUB_API)
    p.add_argument("--kev-url", default=KEV_URL)
    p.add_argument("--node-index", default=NODE_INDEX)
    p.add_argument("--node-schedule", default=NODE_SCHEDULE)
    p.add_argument("--node-wg", default=NODE_WG)
    p.add_argument("--curation", help="curation.json from advisory_fetch.py (plan v20 §9.5.10.2)")
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    args = p.parse_args(argv)
    args.token = os.environ.get("GITHUB_TOKEN", "")
    if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", args.repo or ""):
        print("✖ --repo / GITHUB_REPOSITORY must be OWNER/NAME", file=sys.stderr)
        return 2
    if not args.token and not args.dry_run:
        print("✖ GITHUB_TOKEN is required (or use --dry-run)", file=sys.stderr)
        return 2
    try:
        return run(args)
    except WriteError as e:
        print(f"✖ GitHub: {e}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as e:
        print(f"✖ {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
