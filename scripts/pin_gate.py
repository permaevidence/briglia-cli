#!/usr/bin/env python3
"""Release gate: client-delivered pins must not be stale (plan v22 §3.5.2,
owner requirement P).

Refuses (exit 1) while a pin Briglia ships to clients has a known advisory, is
behind the newest security release of its own line (Node), or is past end of
life — unless the CANDIDATE commit carries an explicit, expiring owner override
for exactly that (component, blocker) pair. Deterministic and fail closed: a
feed that cannot be read is exit 2 (no override exists for "could not check").
It never edits anything and never bumps a pin.

Client-delivered pin: an inventory entry (security/dependencies.json) with
owner briglia-private, pin_kind exact and converges startup|bundle.

Checks
  C1 direct (both modes; public feeds): OSV (exact npm/PyPI/SwiftURL pins,
     withdrawn records ignored), the upstream repository's GitHub security
     advisories for github-repo-advisories pins (an unevaluable range blocks),
     and for node-releases pins the Node index + release schedule (behind /
     end of life) and the Node Security WG core advisories (affected or
     unknown, with or without a fix). The feed code is the daily watch's own
     (scripts/security_watch.py, scripts/advisory_node.py).
  C2 watch issues (both modes; the private repository's issues): every
     OPEN security-watch `finding`/`pin` issue listing a client pin AT THE
     CANDIDATE'S VERSION; an open `health` issue (watch-health); a missing,
     malformed, future or > 36 h old heartbeat (watch-stale); an open
     finding/pin issue whose component lines cannot be read
     (watch-unreadable:#N).

Inputs come from the candidate, never a working tree:
  --source git:<sha>   `git show <sha>:<path>` (promoter)
  --source dir:<path>  a checked-out tag tree (signed workflow)

Signed path (plan v23 R22-1): the `sign` job (release-sign environment,
after the owner's approval, before the key is decoded) runs --mode signed with
BOTH C1 and C2, reading the private issues with its own read-only token. The
promoter's `briglia-pin-gate v1` record (--record-out, carried in the annotated
release tag) is a disclosure list only: signed mode requires it to name the
tagged commit and the blob SHAs of the gate code and inputs, and refuses when
an override it applies was not quoted in it.

Usage:
  pin_gate.py --mode promoter --source git:<sha> --issues-repo OWNER/NAME [--record-out FILE]
  pin_gate.py --mode signed   --source dir:<tree> --commit <sha> --tag-record FILE --issues-repo OWNER/NAME
Environment: the issues token (read-only use) in the variable named by
--issues-token-env (default GITHUB_TOKEN; the signed workflow passes
BRIGLIA_PIN_GATE_ISSUES_TOKEN); GITHUB_TOKEN also raises the advisory API
rate limit.
Exit: 0 clear, 1 blockers or a refused tag record, 2 configuration error or a
feed failure.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import security_watch as watch  # noqa: E402

INVENTORY_PATH = "security/dependencies.json"
OVERRIDES_PATH = "security/pin-gate-overrides.json"
BOUND_PATHS = ("scripts/pin_gate.py", "scripts/security_watch.py", "scripts/advisory_node.py",
               INVENTORY_PATH, OVERRIDES_PATH)
CLIENT_CONVERGES = ("startup", "bundle")
CLIENT_WATCHES = ("osv", "github-repo-advisories", "node-releases")
GLOBAL_COMPONENT = "watch"
MAX_OVERRIDES = 64
MAX_OVERRIDE_DAYS = 30
FUTURE_SKEW_S = 600
OVERRIDE_KEYS = {"component", "blocker", "reason", "approvedBy", "approvedOn", "expires"}
TOKEN_RE = re.compile(r"^(node-behind:v\d+\.\d+\.\d+|node-eol:\d+|watch-health|watch-stale|watch-unreadable:#\d+)$")
DATE_RE = re.compile(r"^\d{4}-\d\d-\d\d$")
TS_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


class ConfigError(Exception):
    pass


class RecordError(Exception):
    pass


# ---------------------------------------------------------------- inputs

def read_source(source, rel):
    """(raw bytes or None when absent) of `rel` in the candidate."""
    kind, _, where = source.partition(":")
    if kind == "git":
        if not re.match(r"^[0-9a-f]{40}$", where):
            raise ConfigError(f"--source git:<sha> needs a full 40-hex commit SHA, got {where!r}")
        p = subprocess.run(["git", "cat-file", "-e", f"{where}:{rel}"], capture_output=True, text=True)
        if p.returncode != 0:
            q = subprocess.run(["git", "cat-file", "-e", f"{where}^{{commit}}"], capture_output=True, text=True)
            if q.returncode != 0:
                raise ConfigError(f"commit {where} not found")
            return None
        p = subprocess.run(["git", "cat-file", "blob", f"{where}:{rel}"], capture_output=True)
        if p.returncode != 0:
            raise ConfigError(f"git cat-file {where}:{rel} failed: {p.stderr.decode(errors='replace').strip()[:200]}")
        return p.stdout
    if kind == "dir":
        path = os.path.join(where, rel)
        if not os.path.exists(path):
            return None
        with open(path, "rb") as f:
            return f.read()
    raise ConfigError("--source must be git:<sha> or dir:<path>")


def blob_sha(data):
    """git's blob id of the raw bytes (what `git rev-parse <sha>:<path>` prints)."""
    if data is None:
        return "absent"
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def client_pins(inventory_raw):
    try:
        inv = json.loads(inventory_raw.decode("utf-8"))
    except ValueError as e:
        raise ConfigError(f"inventory is not JSON: {e}")
    if not isinstance(inv, dict) or inv.get("schema") != 1 or not isinstance(inv.get("components"), list):
        raise ConfigError("inventory: expected schema 1 with a components list")
    pins, seen = [], set()
    for c in inv["components"]:
        if not isinstance(c, dict) or not isinstance(c.get("id"), str) or not c["id"]:
            raise ConfigError("inventory: malformed component")
        if c["id"] in seen or c["id"] == GLOBAL_COMPONENT:
            raise ConfigError(f"inventory: duplicate or reserved id {c['id']!r}")
        seen.add(c["id"])
        if c.get("owner") != "briglia-private" or c.get("pin_kind") != "exact":
            continue
        conv = c.get("converges")
        if conv not in ("startup", "bundle", "user-started", "never"):
            raise ConfigError(f"inventory: exact private pin {c['id']} has no valid `converges` (inventory predates plan v21?)")
        if conv not in CLIENT_CONVERGES:
            continue
        if c.get("watch") not in CLIENT_WATCHES:
            raise ConfigError(f"inventory: client pin {c['id']} has watch {c.get('watch')!r}; the gate covers only {CLIENT_WATCHES}")
        if not isinstance(c.get("version"), str) or not c["version"]:
            raise ConfigError(f"inventory: client pin {c['id']} has no exact version")
        pins.append(c)
    if not pins:
        raise ConfigError("inventory lists no client-delivered pins (refusing an empty check)")
    return pins


def parse_date(text, what):
    if not isinstance(text, str) or not DATE_RE.match(text):
        raise ConfigError(f"overrides: {what} must be YYYY-MM-DD")
    try:
        return datetime.date.fromisoformat(text)
    except ValueError:
        raise ConfigError(f"overrides: {what} is not a real date")


def load_overrides(raw, owner_name, today):
    if raw is None:
        return []
    try:
        doc = json.loads(raw.decode("utf-8"))
    except ValueError as e:
        raise ConfigError(f"overrides file is not JSON: {e}")
    if not isinstance(doc, dict) or set(doc) != {"schema", "overrides"} or doc["schema"] != 1 or not isinstance(doc["overrides"], list):
        raise ConfigError('overrides: expected exactly {"schema": 1, "overrides": [...]}')
    if len(doc["overrides"]) > MAX_OVERRIDES:
        raise ConfigError(f"overrides: more than {MAX_OVERRIDES} entries")
    out, pairs = [], set()
    for o in doc["overrides"]:
        if not isinstance(o, dict) or set(o) != OVERRIDE_KEYS:
            raise ConfigError(f"overrides: each entry needs exactly the keys {sorted(OVERRIDE_KEYS)}")
        for k in OVERRIDE_KEYS:
            if not isinstance(o[k], str) or not o[k].strip() or len(o[k]) > 500 or re.search(r"[\x00-\x1f\x7f]", o[k]):
                raise ConfigError(f"overrides: {k} must be a non-empty single-line string of at most 500 characters")
        if o["approvedBy"] != owner_name:
            raise ConfigError(f"overrides: approvedBy must be the owner ({owner_name}), got {o['approvedBy']!r}")
        approved, expires = parse_date(o["approvedOn"], "approvedOn"), parse_date(o["expires"], "expires")
        if approved > today:
            raise ConfigError(f"overrides: approvedOn {o['approvedOn']} is in the future ({o['component']} {o['blocker']})")
        if not (approved < expires <= approved + datetime.timedelta(days=MAX_OVERRIDE_DAYS)):
            raise ConfigError(f"overrides: expires must be after approvedOn and at most {MAX_OVERRIDE_DAYS} days later ({o['component']} {o['blocker']})")
        token_like = o["blocker"].startswith(("node-", "watch-"))
        if not (TOKEN_RE.match(o["blocker"]) if token_like else watch.valid_id(o["blocker"])):
            raise ConfigError(f"overrides: blocker {o['blocker']!r} is neither an advisory id nor a gate token")
        if (o["component"], o["blocker"]) in pairs:
            raise ConfigError(f"overrides: duplicate entry for {o['component']} {o['blocker']}")
        pairs.add((o["component"], o["blocker"]))
        out.append(dict(o, _expires=expires))
    return out


def override_line(o):
    return (f"{o['component']} {o['blocker']} — {o['reason']} "
            f"(approved by {o['approvedBy']} on {o['approvedOn']}, expires {o['expires']})")


# ---------------------------------------------------------------- checks

def direct_blockers(pins, args):
    """C1: {component id: [blocker {"ids": set, "why": str}]}. FeedError propagates (exit 2)."""
    out = {c["id"]: [] for c in pins}
    osv = [c for c in pins if c["watch"] == "osv"]
    if osv:
        hits = watch.osv_query(osv, args.osv_api)
        for vid in sorted(hits):
            rec = watch.osv_record(vid, args.osv_api)
            if rec.get("withdrawn"):
                continue
            ids = {vid} | {a for a in rec.get("aliases") or [] if watch.valid_id(a)}
            for cid in hits[vid]:
                comp = next(c for c in osv if c["id"] == cid)
                out[cid].append({"ids": ids, "why": f"OSV {vid} affects {comp['name']} {comp['version']}"})
    for c in pins:
        if c["watch"] == "github-repo-advisories":
            for adv in watch.repo_advisories(c, args.github_api, args.token):
                out[c["id"]].append({"ids": set(adv["ids"]), "why": f"GitHub advisory {adv['ids'][0]} ({adv['applies']}) for {c['name']} {c['version']}"})
    nodes = [c for c in pins if c["watch"] == "node-releases"]
    if nodes:
        rows = watch.node_index(args.node_index)
        schedule = watch.node_schedule(args.node_schedule)
        wg = watch.node_wg(args.node_wg)
        for c in nodes:
            for b in watch.node_pin_blockers(c["version"], rows, schedule, args.today):
                out[c["id"]].append({"ids": {b}, "why": f"pinned {c['name']} {c['version']}: {b}"})
            for f in watch.node_pin_findings(c, wg, rows):
                out[c["id"]].append({"ids": set(f["ids"]), "why": f"Node Security WG {f['ids'][0]} ({f['applies']}) for node {c['version']}"})
    return out


ANY_MARKER_RE = re.compile(r"<!-- briglia-security-watch v1 [^>]*-->")
SECTION_HEAD = "Affected inventory components:"
RECORD_RE = re.compile(r"^- `([^`\s]+)` — (\S(?:.*\S)?) (\S+) · owner \S+ · \S(?:.*\S)?$")
NEXT_SECTION = {"finding": "Fixed versions in the feed:", "pin": "Newest security release on the pinned line:"}


def load_issues(args):
    """Every `security-watch`-labelled issue, classified by THIS gate (plan v23
    R22-3): exactly one valid marker, else `kind` None. Never skips evidence."""
    url = f"{args.github_api}/repos/{args.issues_repo}/issues?labels={watch.LABEL}&state=all&per_page=100"
    headers = {"Authorization": f"Bearer {args.issues_token}", "Accept": "application/vnd.github+json"}
    out, pages = [], 0
    while url:
        pages += 1
        if pages > watch.MAX_PAGES:
            raise watch.FeedError("issue list: more pages than the watch's bound")
        status, data, hdrs = watch.http("GET", url, headers=headers)
        if status != 200 or not isinstance(data, list):
            raise watch.FeedError(f"issue list: HTTP {status}")
        for it in data:
            if not isinstance(it, dict) or not isinstance(it.get("number"), int):
                raise watch.FeedError("issue list: malformed issue row")
            if "pull_request" in it:
                continue
            body = it.get("body") or ""
            if not isinstance(body, str):
                raise watch.FeedError("issue list: malformed issue body")
            markers = ANY_MARKER_RE.findall(body)
            valid = watch.MARKER_RE.findall(body)
            kind, ids = None, []
            if len(markers) == 1 and len(valid) == 1:
                kind, ids = valid[0][0], [i for i in valid[0][1].split(",") if i]
            out.append({"number": it["number"], "state": it.get("state"), "kind": kind, "ids": ids, "body": body})
        url = watch.next_link(hdrs)
    return out


def component_section(body, kind):
    """{id: version} from the strict component section (plan v24 R23-1), or
    None when the section violates the generated format in ANY way."""
    lines = body.split("\n")
    heads = [i for i, l in enumerate(lines) if l == SECTION_HEAD]
    if len(heads) != 1:
        return None
    parsed, i = {}, heads[0] + 1
    while i < len(lines) and lines[i] != "":
        m = RECORD_RE.match(lines[i])
        if not m:
            return None
        cid, version = m.group(1), m.group(3)
        if cid in parsed and parsed[cid] != version:
            return None
        parsed[cid] = version
        i += 1
    if not parsed or i >= len(lines) or i + 1 >= len(lines) or not lines[i + 1].startswith(NEXT_SECTION[kind]):
        return None
    return parsed


def issue_blockers(pins, args, now):
    """C2: blockers from the private repository's security-watch issues. Fail closed."""
    by_id = {c["id"]: c for c in pins}
    existing = load_issues(args)
    out = {c["id"]: [] for c in pins}
    general = []
    beat, beat_seen = None, False
    if sum(1 for it in existing if it["kind"] == "heartbeat") > 1:
        general.append({"ids": {"watch-stale"}, "why": "more than one heartbeat issue (ambiguous watch state)"})
    for it in existing:
        if it["kind"] is None:
            if it["state"] == "open":
                general.append({"ids": {f"watch-unreadable:#{it['number']}"},
                                "why": f"open security-watch issue #{it['number']} has no single valid marker"})
            continue
        if it["kind"] == "heartbeat":
            beat_seen = True
            runs = watch.LAST_RUN_RE.findall(it["body"])
            m = watch.LAST_RUN_RE.search(it["body"]) if len(runs) == 1 else None
            t = watch.parse_time(m.group(1)) if m else None
            if t is None:
                general.append({"ids": {"watch-stale"}, "why": f"the heartbeat issue #{it['number']} has no readable last-run time"})
            elif (t - now).total_seconds() > FUTURE_SKEW_S:
                general.append({"ids": {"watch-stale"}, "why": f"the heartbeat issue #{it['number']} is dated in the future ({m.group(1)})"})
            elif beat is None or t > beat:
                beat = t
            continue
        if it["state"] != "open":
            continue
        if it["kind"] == "health":
            general.append({"ids": {"watch-health"}, "why": f"the security watch reports incomplete data (issue #{it['number']})"})
            continue
        if it["kind"] not in ("finding", "pin"):
            continue
        parsed = component_section(it["body"], it["kind"])
        if parsed is None:
            general.append({"ids": {f"watch-unreadable:#{it['number']}"},
                            "why": f"open security-watch {it['kind']} issue #{it['number']} has unreadable or conflicting component lines"})
            continue
        for cid, version in parsed.items():
            comp = by_id.get(cid)
            if comp is not None and version == comp["version"]:
                out[cid].append({"ids": set(it["ids"]), "why": f"open security-watch {it['kind']} issue #{it['number']} lists {cid} at {version}"})
    if beat is None:
        if not beat_seen or not any("watch-stale" in g["ids"] for g in general):
            general.append({"ids": {"watch-stale"}, "why": "the security watch heartbeat issue is missing"})
    elif (now - beat).total_seconds() > watch.HEARTBEAT_GAP_HOURS * 3600:
        general.append({"ids": {"watch-stale"}, "why": f"the security watch heartbeat is older than {watch.HEARTBEAT_GAP_HOURS} h "
                        f"(last run {beat.strftime('%Y-%m-%dT%H:%M:%SZ')})"})
    return out, general, {"issues": len(existing), "heartbeat": beat.strftime("%Y-%m-%dT%H:%M:%SZ") if beat else "none"}


def evaluate(blockers, general, overrides, today):
    """(unresolved [(component, blocker)], applied [override], expired [override], unused [override])."""
    live = [o for o in overrides if today < o["_expires"]]
    expired = [o for o in overrides if not today < o["_expires"]]
    used, unresolved = set(), []
    items = [(cid, b) for cid, bs in blockers.items() for b in bs] + [(GLOBAL_COMPONENT, b) for b in general]
    for cid, b in items:
        match = next((i for i, o in enumerate(live) if o["component"] == cid and o["blocker"] in b["ids"]), None)
        if match is None:
            unresolved.append((cid, b))
        else:
            used.add(match)
    applied = [o for i, o in enumerate(live) if i in used]
    unused = [o for i, o in enumerate(live) if i not in used]
    return unresolved, applied, expired, unused


# ---------------------------------------------------------------- record

def record_text(commit, blobs, checked_at, c2, applied):
    lines = ["briglia-pin-gate v1", f"commit: {commit}"]
    lines += [f"blob {p}: {blobs[p]}" for p in BOUND_PATHS]
    lines += ["mode: promoter", "result: clear", f"checkedAt: {checked_at}",
              f"issues: {c2['issues']} read; heartbeat {c2['heartbeat']}"]
    lines += [f"override: {override_line(o)}" for o in applied]
    lines.append("end briglia-pin-gate")
    return "\n".join(lines) + "\n"


def parse_record(text):
    """→ dict. Exactly one block; every line in the fixed order. RecordError otherwise."""
    if text is None:
        raise RecordError("the release tag carries no pin-gate record (not an annotated tag from promote-release.sh?)")
    starts = [i for i, l in enumerate(text.splitlines()) if l == "briglia-pin-gate v1"]
    if len(starts) != 1:
        raise RecordError(f"expected exactly one 'briglia-pin-gate v1' block, found {len(starts)}")
    lines = text.splitlines()[starts[0]:]
    try:
        end = lines.index("end briglia-pin-gate")
    except ValueError:
        raise RecordError("the pin-gate record is not terminated")
    body = lines[1:end]
    rec, i = {"overrides": []}, 0

    def take(prefix):
        nonlocal i
        if i >= len(body) or not body[i].startswith(prefix):
            raise RecordError(f"pin-gate record: expected {prefix!r} at line {i + 2}")
        i += 1
        return body[i - 1][len(prefix):]
    rec["commit"] = take("commit: ")
    rec["blobs"] = {p: take(f"blob {p}: ") for p in BOUND_PATHS}
    if take("mode: ") != "promoter" or take("result: ") != "clear":
        raise RecordError("pin-gate record: not a clear promoter result")
    rec["checkedAt"] = take("checkedAt: ")
    rec["issues"] = take("issues: ")
    while i < len(body):
        rec["overrides"].append(take("override: "))
    if not re.match(r"^[0-9a-f]{40}$", rec["commit"]) or not TS_RE.match(rec["checkedAt"]):
        raise RecordError("pin-gate record: malformed commit or checkedAt")
    for p, v in rec["blobs"].items():
        if v != "absent" and not re.match(r"^[0-9a-f]{40}$", v):
            raise RecordError(f"pin-gate record: malformed blob id for {p}")
    return rec


def verify_record(rec, commit, blobs, now, overrides):
    if rec["commit"] != commit:
        raise RecordError(f"pin-gate record names commit {rec['commit']}, the tag is {commit}")
    for p in BOUND_PATHS:
        if rec["blobs"][p] != blobs[p]:
            raise RecordError(f"pin-gate record: {p} differs from the tagged tree (record {rec['blobs'][p]}, tree {blobs[p]})")
    known = {override_line(o) for o in overrides}
    for line in rec["overrides"]:
        if line not in known:
            raise RecordError(f"pin-gate record quotes an override the tagged tree does not contain: {line}")


# ---------------------------------------------------------------- main

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--mode", choices=("promoter", "signed"), required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--issues-repo", default="")
    p.add_argument("--owner-name", default="Matteo")
    p.add_argument("--record-out", default=None)
    p.add_argument("--commit", default=None)
    p.add_argument("--tag-record", default=None)
    p.add_argument("--osv-api", default=watch.OSV_API)
    p.add_argument("--github-api", default=watch.GITHUB_API)
    p.add_argument("--node-index", default=watch.NODE_INDEX)
    p.add_argument("--node-schedule", default=watch.NODE_SCHEDULE)
    p.add_argument("--node-wg", default=watch.NODE_WG)
    p.add_argument("--issues-token-env", default="GITHUB_TOKEN")
    p.add_argument("--now", default=None, help=argparse.SUPPRESS)
    args = p.parse_args(argv)
    args.token = os.environ.get("GITHUB_TOKEN", "")
    args.issues_token = os.environ.get(args.issues_token_env, "")
    now = watch.parse_time(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    if now is None:
        print("✖ pin gate: --now must be YYYY-MM-DDTHH:MM:SSZ", file=sys.stderr)
        return 2
    args.today = now.strftime("%Y-%m-%d")
    today = now.date()
    try:
        if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", args.issues_repo):
            raise ConfigError("--issues-repo OWNER/NAME (the private repository) is required in both modes (C2)")
        if not args.issues_token:
            raise ConfigError(f"the issues token ({args.issues_token_env}) is not set: C2 cannot run, refusing (never C1-only)")
        if args.mode == "promoter":
            if not args.source.startswith("git:"):
                raise ConfigError("--mode promoter reads the candidate commit: --source git:<sha>")
            commit = args.source[4:]
        else:
            if not args.commit or not re.match(r"^[0-9a-f]{40}$", args.commit):
                raise ConfigError("--mode signed needs --commit <full sha of the tagged commit>")
            if not args.tag_record:
                raise ConfigError("--mode signed needs --tag-record FILE (the release tag's message)")
            commit = args.commit
        texts = {path: read_source(args.source, path) for path in BOUND_PATHS}
        if texts[INVENTORY_PATH] is None:
            raise ConfigError(f"{INVENTORY_PATH} missing in the candidate")
        pins = client_pins(texts[INVENTORY_PATH])
        overrides = load_overrides(texts[OVERRIDES_PATH], args.owner_name, today)
        blobs = {path: blob_sha(texts[path]) for path in BOUND_PATHS}
    except (ConfigError, ValueError, OSError) as e:
        print(f"✖ pin gate: {e}", file=sys.stderr)
        return 2

    rec = None
    if args.mode == "signed":
        try:
            try:
                with open(args.tag_record, encoding="utf-8") as f:
                    tag_text = f.read()
            except OSError:
                tag_text = None
            rec = parse_record(tag_text)
            verify_record(rec, commit, blobs, now, overrides)
        except RecordError as e:
            print(f"✖ pin gate: release tag refused — {e}", file=sys.stderr)
            return 1

    try:
        blockers = direct_blockers(pins, args)
        extra, general, c2 = issue_blockers(pins, args, now)
        for cid, bs in extra.items():
            blockers[cid].extend(bs)
    except watch.FeedError as e:
        print(f"✖ pin gate: cannot verify the pins ({e}); nothing can override this — retry", file=sys.stderr)
        return 2

    unresolved, applied, expired, unused = evaluate(blockers, general, overrides, today)
    print(f"pin gate ({args.mode}): {len(pins)} client-delivered pins checked "
          f"({sum(1 for c in pins if c['watch'] == 'osv')} OSV, "
          f"{sum(1 for c in pins if c['watch'] == 'github-repo-advisories')} GitHub advisories, "
          f"{sum(1 for c in pins if c['watch'] == 'node-releases')} Node)"
          + f"; {c2['issues']} watch issues read, heartbeat {c2['heartbeat']}")
    for o in applied:
        print(f"OVERRIDE APPLIED: {override_line(o)}")
    for o in expired:
        print(f"  note: override EXPIRED and ignored: {o['component']} {o['blocker']} (expires {o['expires']})")
    for o in unused:
        print(f"  note: override unused (no matching blocker): {o['component']} {o['blocker']}")
    if unresolved:
        print(f"✖ pin gate: {len(unresolved)} blocker(s) — the release is refused:")
        for cid, b in unresolved:
            print(f"  - {cid}: {b['why']}")
            print(f'    override (owner only): {{"component": "{cid}", "blocker": "{watch.primary_id(sorted(b["ids"]))}", '
                  f'"reason": "…", "approvedBy": "{args.owner_name}", "approvedOn": "{args.today}", "expires": "…"}}')
        return 1
    if rec is not None:
        undisclosed = [override_line(o) for o in applied if override_line(o) not in rec["overrides"]]
        if undisclosed:
            print("✖ pin gate: release tag refused — an override the gate record did not disclose is now needed: "
                  + "; ".join(undisclosed) + " (re-run promote-release.sh --tag-only so the approval request quotes it)", file=sys.stderr)
            return 1
    if args.mode == "promoter" and args.record_out:
        with open(args.record_out, "w", encoding="utf-8") as f:
            f.write(record_text(commit, blobs, now.strftime("%Y-%m-%dT%H:%M:%SZ"), c2, applied))
    print("✔ pin gate: no stale client-delivered pin" + (f" ({len(applied)} override(s) applied — quote them in the approval request)" if applied else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
