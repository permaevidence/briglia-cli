#!/usr/bin/env python3
"""Node.js vendor advisories for the local-tools list (security plan v17
§9.5.10.1). Two halves, both parsers only (nothing from a feed is executed):

* fetch (watch job, no secrets): the Security WG core index, nodejs.org's
  dist index (slimmed to version/date/security) and the Release WG schedule;
* convert (publisher): per platform identity, the WG entries as SEMVER
  ranges ("vulnerable" minus "patched", per release line), one per-line
  "security release" record from the dist index (permanent, `kind:
  release`: only "older than the latest security release"), and the
  maintained lines from the schedule.

Strict grammar for the WG ranges; anything it does not understand makes
that advisory `affected: unknown` (the client reports unknown, never "not
affected").
"""
import datetime
import json
import re
import urllib.request

WG_URL = "https://raw.githubusercontent.com/nodejs/security-wg/main/vuln/core/index.json"
DIST_URL = "https://nodejs.org/dist/index.json"
SCHEDULE_URL = "https://raw.githubusercontent.com/nodejs/Release/main/schedule.json"
SOURCES = ("nodejs-security-wg", "nodejs-dist", "nodejs-schedule")
MAX_RESPONSE = 8 * 1024 * 1024
MAX_WG = 2000
MAX_DIST = 5000
INF = (10 ** 6, 0, 0)
CVE_RE = re.compile(r"CVE-[0-9]{4}-[0-9]{4,}", re.ASCII)
VER_RE = re.compile(r"(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})", re.ASCII)
LINE_RE = re.compile(r"[1-9][0-9]{0,3}", re.ASCII)
# affectedEnvironments tokens: targets and known non-targets.
TARGETS = {"darwin", "linux"}
NON_TARGETS = {"win32", "aix", "freebsd", "openbsd", "sunos", "android"}


class NodeFeedError(Exception):
    pass


# ---------------------------------------------------------------- fetch

def _get_json(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "briglia-security-watch (node advisories)",
                                               "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read(MAX_RESPONSE + 1)
    if len(raw) > MAX_RESPONSE:
        raise NodeFeedError(f"{url}: response larger than {MAX_RESPONSE} bytes")
    return json.loads(raw)


def fetch_all(now_iso, get=_get_json):
    """→ {source: {"status": "ok", "checkedAt", "data"} | {"status": "failed", "problem"}}."""
    out = {}
    for source, url, shape in (("nodejs-security-wg", WG_URL, _shape_wg), ("nodejs-dist", DIST_URL, _shape_dist),
                               ("nodejs-schedule", SCHEDULE_URL, _shape_schedule)):
        try:
            out[source] = {"status": "ok", "checkedAt": now_iso, "data": shape(get(url))}
        except Exception as e:   # noqa: BLE001 — any failure is a failed source, never "no advisories"
            out[source] = {"status": "failed", "problem": str(e)[:300]}
    return out


def _shape_wg(d):
    if type(d) is not dict or not d or len(d) > MAX_WG:
        raise NodeFeedError("WG index is not a non-empty object of bounded size")
    out = {}
    for k, v in d.items():
        if type(k) is not str or not re.fullmatch(r"[0-9]{1,6}", k) or type(v) is not dict:
            raise NodeFeedError(f"WG entry {k!r} is malformed")
        out[k] = {f: v.get(f) for f in ("cve", "vulnerable", "patched", "severity", "affectedEnvironments")}
    return out


def _shape_dist(d):
    if type(d) is not list or not d or len(d) > MAX_DIST:
        raise NodeFeedError("dist index is not a non-empty bounded list")
    out = []
    for r in d:
        if type(r) is not dict or type(r.get("version")) is not str or type(r.get("date")) is not str:
            raise NodeFeedError("dist release without version/date")
        if r.get("security") is not None and type(r.get("security")) is not bool:
            raise NodeFeedError("dist security flag is not a bool")
        out.append({"version": r["version"], "date": r["date"], "security": bool(r.get("security"))})
    return out


def _shape_schedule(d):
    if type(d) is not dict or not d:
        raise NodeFeedError("schedule is not a non-empty object")
    out = {}
    for k, v in d.items():
        if type(k) is not str or type(v) is not dict:
            raise NodeFeedError("schedule entry malformed")
        out[k] = {"start": v.get("start"), "end": v.get("end")}
    return out


# ---------------------------------------------------------------- convert

def parse_version(s):
    m = VER_RE.fullmatch(s.strip()) if type(s) is str else None
    return tuple(int(x) for x in m.groups()) if m else None


def vstr(t):
    return "%d.%d.%d" % t


class Unsupported(Exception):
    pass


def parse_ranges(expr):
    """A WG range expression → a sorted list of half-open intervals
    [(lo, hi)]. Grammar: `N.x`, `N.N.x`, `^N.N.N`, `N.N.N`, `>= N.N.N`,
    `>=N.N.N <N.N.N`, `<= N`, joined by `||`. Anything else → Unsupported."""
    if type(expr) is not str or not expr.strip() or len(expr) > 512:
        raise Unsupported("empty range")
    out = []
    for part in expr.split("||"):
        p = part.strip()
        m = re.fullmatch(r"([1-9][0-9]{0,3}|0)\.x", p)
        if m:
            n = int(m.group(1)); out.append(((n, 0, 0), (n + 1, 0, 0))); continue
        m = re.fullmatch(r"([0-9]{1,4})\.([0-9]{1,4})\.x", p)
        if m:
            a, b = int(m.group(1)), int(m.group(2)); out.append(((a, b, 0), (a, b + 1, 0))); continue
        m = re.fullmatch(r"\^\s*([0-9.]+)", p)
        if m:
            v = parse_version(m.group(1))
            if not v or (v[0] == 0 and v[1] == 0):
                raise Unsupported(f"caret {p!r}")
            # semver: ^0.M.P stays inside 0.M; ^N.M.P inside N.
            out.append((v, (0, v[1] + 1, 0) if v[0] == 0 else (v[0] + 1, 0, 0))); continue
        m = re.fullmatch(r">=\s*([0-9.]+)\s*<\s*([0-9.]+)", p)
        if m:
            a, b = parse_version(m.group(1)), parse_version(m.group(2))
            if not a or not b or not a < b:
                raise Unsupported(f"interval {p!r}")
            out.append((a, b)); continue
        m = re.fullmatch(r">=\s*([0-9.]+)", p)
        if m:
            a = parse_version(m.group(1))
            if not a:
                raise Unsupported(p)
            out.append((a, INF)); continue
        m = re.fullmatch(r"<=\s*([1-9][0-9]{0,3})", p)
        if m:
            out.append(((0, 0, 0), (int(m.group(1)) + 1, 0, 0))); continue
        v = parse_version(p)
        if v:
            out.append((v, (v[0], v[1], v[2] + 1))); continue
        raise Unsupported(f"range part {p!r}")
    return merge(out)


def merge(iv):
    iv = sorted(iv)
    out = []
    for lo, hi in iv:
        if out and lo <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def subtract(a, b):
    out = []
    for lo, hi in a:
        cur = [(lo, hi)]
        for blo, bhi in b:
            nxt = []
            for x, y in cur:
                if bhi <= x or blo >= y:
                    nxt.append((x, y)); continue
                if x < blo:
                    nxt.append((x, blo))
                if bhi < y:
                    nxt.append((bhi, y))
            cur = nxt
        out += cur
    return merge(out)


def by_line(iv):
    """Split intervals at major boundaries → {major: [(lo, hi)]}."""
    out = {}
    for lo, hi in iv:
        n = lo[0]
        while (n, 0, 0) < hi and n < INF[0]:
            s, e = max(lo, (n, 0, 0)), min(hi, (n + 1, 0, 0))
            if s < e:
                out.setdefault(n, []).append((s, e))
            n += 1
            if n > 10000:
                break
    return out


def wg_advisory(key, v, platform, released):
    """One WG entry → (advisory dict | None when it does not concern this
    platform). `released`: the set of dist versions (cross-check)."""
    env = v.get("affectedEnvironments")
    unknown = False
    if type(env) is not list or not env or any(type(x) is not str for x in env):
        unknown = True
    else:
        toks = set(env)
        if "all" not in toks and platform not in toks:
            if toks <= NON_TARGETS | TARGETS:
                return None              # another platform only
            unknown = True               # an unknown token: keep, unknown
    cves = [c for c in (v.get("cve") or []) if type(c) is str and CVE_RE.fullmatch(c)] if type(v.get("cve")) is list else []
    ids = sorted(set(cves))[:16] or [f"NSWG-CORE-{key}"]
    sev = "critical" if v.get("severity") == "critical" else "recommended"
    adv = {"ids": ids, "severity": sev, "kev": False, "kevAdded": None, "withdrawn": False,
           "_wg": True, "_key": int(key)}
    try:
        if unknown:
            raise Unsupported("environments")
        vuln = parse_ranges(v.get("vulnerable"))
        patched = parse_ranges(v.get("patched"))
        for lo, _ in patched:
            if lo != (0, 0, 0) and vstr(lo) not in released:
                raise Unsupported(f"patched version {vstr(lo)} is not a Node.js release")
        affected = subtract(vuln, patched)
        lines = by_line(affected)
        if not lines:
            return None                  # nothing affected (fully patched entry)
        ranges, fixed = [], []
        for n in sorted(lines):
            for lo, hi in lines[n]:
                end = "limit" if hi == (n + 1, 0, 0) or hi == INF else "fixed"
                ranges.append({"type": "SEMVER", "events": [{"introduced": vstr(lo)}, {end: vstr(min(hi, (n + 1, 0, 0)))}]})
            # A fix for line n: the end of its LAST affected interval, when a
            # patched interval starts exactly there and covers the rest of
            # the line (every later version of the line is patched).
            last = lines[n][-1][1]
            if any(plo == last and phi >= (n + 1, 0, 0) for plo, phi in patched) and last[0] == n:
                fixed.append({"line": str(n), "version": vstr(last)})
        if len(ranges) > 16:
            raise Unsupported("too many ranges")
        adv["affected"] = {"ranges": ranges}
        adv["_lines"] = sorted(lines)
        adv["_patched"] = {int(f["line"]): f["version"] for f in fixed}
        if fixed:
            adv["remediation"] = {"fixed": fixed, "pocket": None}
            adv["noFixReason"] = None
        else:
            adv["remediation"] = None
            adv["noFixReason"] = "will-not-fix"
    except Unsupported:
        adv["affected"] = "unknown"
        adv["remediation"] = None
        adv["noFixReason"] = "unknown"
        # The lines it concerns, when at least `vulnerable` is readable (an
        # unreadable entry that only concerns end-of-life lines is dropped by
        # the caller like any other end-of-life entry).
        try:
            adv["_lines"] = sorted(by_line(parse_ranges(v.get("vulnerable")))) if not unknown else []
            adv["_unknownLines"] = unknown
        except Unsupported:
            adv["_lines"] = []
            adv["_unknownLines"] = True
        adv["_patched"] = {}
    return adv


def maintained(schedule, now):
    today = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date()
    out = []
    for k, v in schedule.items():
        m = re.fullmatch(r"v([1-9][0-9]{0,3})", k)
        if not m:
            continue
        try:
            start = datetime.date.fromisoformat(v["start"])
            end = datetime.date.fromisoformat(v["end"])
        except (TypeError, ValueError, KeyError):
            raise NodeFeedError(f"schedule {k} has no valid start/end")
        if start <= today < end:
            out.append(m.group(1))
    if not out:
        raise NodeFeedError("schedule names no maintained line")
    return sorted(out, key=int)


def security_releases(dist):
    """major → highest version with security: true."""
    best = {}
    for r in dist:
        v = parse_version(r["version"].lstrip("v")) if r["version"].startswith("v") else None
        if v and r["security"] and (v[0] not in best or v > best[v[0]]):
            best[v[0]] = v
    return best


def node_identity(platform, sources, kev, now):
    """→ (advisories, statuses {source: (status, checkedAt)}, maintainedLines | None).
    `sources`: the bundle's node sources; `kev`: CVE → dateAdded (may be {})."""
    statuses = {}
    for s in SOURCES:
        src = sources.get(s) or {}
        statuses[s] = ("ok", src.get("checkedAt")) if src.get("status") == "ok" else ("failed", None)
    if any(st[0] != "ok" for st in statuses.values()):
        # Any missing source: the identity is unknown on the client; no
        # half-built advisories are published.
        return [], statuses, None
    try:
        lines = maintained(sources["nodejs-schedule"]["data"], now)
        dist = sources["nodejs-dist"]["data"]
        released = {r["version"].lstrip("v") for r in dist}
        sec = security_releases(dist)
        advs = []
        for key, v in sources["nodejs-security-wg"]["data"].items():
            a = wg_advisory(key, v, platform, released)
            if a is None:
                continue
            if not a.get("_unknownLines") and not set(map(str, a["_lines"])) & set(lines):
                continue                 # affects only end-of-life lines
            kev_hit = [i for i in a["ids"] if i in kev]
            if kev_hit:
                a["kev"], a["kevAdded"], a["severity"] = True, kev.get(kev_hit[0]), "critical"
            a["_order"] = (0 if a["kev"] else 1, 0 if a["severity"] == "critical" else 1, -a["_key"])
            a["_source"] = "nodejs-security-wg"
            advs.append(a)
        for n in sorted(int(x) for x in lines):
            s = sec.get(n)
            if not s:
                continue
            # v18 (R17-3): permanent, typed. It states only "older than the
            # latest security release for this line", never a known
            # vulnerability, and is never retired by WG arrivals.
            advs.append({"ids": [f"NODEJS-SR-{n}-{vstr(s)}"], "kind": "release", "severity": "recommended", "kev": False,
                         "kevAdded": None, "withdrawn": False,
                         "affected": {"ranges": [{"type": "SEMVER", "events": [{"introduced": f"{n}.0.0"}, {"fixed": vstr(s)}]}]},
                         "remediation": {"fixed": [{"line": str(n), "version": vstr(s)}], "pocket": None},
                         "noFixReason": None, "_order": (1, 1, -10 ** 9), "_source": "nodejs-dist"})
        for a in advs:
            for k in ("_wg", "_key", "_lines", "_patched", "_unknownLines"):
                a.pop(k, None)
        return advs, statuses, lines
    except (NodeFeedError, KeyError, TypeError, ValueError, AttributeError):
        return [], {s: ("failed", None) for s in SOURCES}, None
