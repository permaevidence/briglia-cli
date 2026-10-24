#!/usr/bin/env python3
"""Build and validate the local-tools advisory list (security plan v16
§9.5.3) from the watch job's fetched bundle. Parsers only: nothing from the
feeds is executed, evaluated or passed to a shell. Signing is a separate
step (.github/scripts/sign-advisory.sh) that runs only on the payload this
script wrote and validated.

Rules implemented here (the client re-checks every bound):
  * document {schema, sequence, published, expires, declared, coverage,
    entries}; expires = published + 72 h - 60 s; sequence =
    max(previous + 1, minutes since 1970);
  * ≤ 256 KiB, ≤ 64 identities, ≤ 64 advisories per identity, strings ≤ 512
    bytes, IDs ^[A-Za-z0-9][A-Za-z0-9._:-]{2,63}$, ≤ 16 IDs per advisory;
  * coverage: one row per (identity, declared source); `ok` only for a
    source fetched and parsed completely in this run; `failed` otherwise
    (with the last good checkedAt from the previous list, never "now");
    `partial` (owner decision F3) only when the fetch and parse were complete
    and size bounds alone dropped advisories (trim order: KEV, critical,
    newest first). A duplicate (identity, source) pair refuses to sign;
  * advisories carried separately with their affected ranges (OSV events),
    remediation (fixed version, Ubuntu pocket) or null + noFixReason, KEV
    flag and date; withdrawn or no-longer-published advisories of a fully
    checked identity carried as withdrawn for 30 days, then dropped;
  * lossless pruning (§9.5.12): a deb advisory whose every affected range
    closes strictly below the identity's release floor
    (security/deb-floors.json, the lowest version a client of that release
    could have installed from an accepted origin) is not published. It can
    never match on a client, so it changes no verdict and is never "cut for
    size" (F3 is untouched). Never pruned: KEV, no fix, withdrawn,
    `affected: unknown`, a non-ECOSYSTEM range, any version the client could
    not parse, any identity without a floor, vendor identities.

Usage:
  advisory_publish.py build --input BUNDLE --out PAYLOAD [--previous PAYLOAD] [--watchlist PATH] [--now ISO]
                           [--floors PATH | --no-prune] [--report PATH]
  advisory_publish.py check PAYLOAD        (validate an existing payload)
Exit: 0 written/valid, 2 refused (nothing to sign).
"""
import argparse
import datetime
import json
import os
import re
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from advisory_fetch import DEFAULT_WATCHLIST, load_watchlist, withdrawn_valid  # noqa: E402
import advisory_node  # noqa: E402
import advisory_libreoffice  # noqa: E402

MAX_PAYLOAD = 256 * 1024
MAX_IDENTITIES = 64
MAX_ADVISORIES = 64
MAX_STRING = 512
MAX_IDS = 16
MAX_RANGES = 16
MAX_EVENTS = 64
MAX_VERSIONS = 256
VALIDITY = 72 * 3600 - 60
WITHDRAWN_DAYS = 30
FRESH = 48 * 3600
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{2,63}")
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9@+._:/-]{0,127}")
RANGE_TYPES = ("ECOSYSTEM", "SEMVER", "GIT")
EVENTS = ("introduced", "fixed", "last_affected", "limit")
DEFAULT_FLOORS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "security", "deb-floors.json")


class Refuse(Exception):
    """The list must not be signed."""


class Incomplete(Exception):
    """This source row cannot be published as checked (→ failed)."""


class TooLarge(Exception):
    """This advisory exceeds a size bound (→ dropped, identity partial)."""


def iso(t):
    return datetime.datetime.fromtimestamp(int(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    if not isinstance(s, str) or len(s) > 40:
        raise ValueError("not a timestamp")
    s = s.replace("Z", "+00:00")
    if "." in s:
        head, rest = s.split(".", 1)
        tz = rest[rest.find("+"):] if "+" in rest else ""
        s = head + tz
    return datetime.datetime.fromisoformat(s).timestamp()


def clean_string(s, what):
    if not isinstance(s, str) or len(s.encode()) > MAX_STRING or any(ord(c) < 32 or ord(c) == 127 for c in s):
        raise Incomplete(f"{what}: not a bounded plain string")
    return s


def identity_key(i):
    if i.get("kind") == "vendor":
        return f"vendor:{i['vendor']}:{i['product']}:{i['platform']}:{i['flavour']}"
    return f"deb:{i['distro']}:{i['release']}:{i['source']}"


# ---------------------------------------------------------------- conversion

def advisory_ids(rec):
    raw = [rec.get("id")] + list(rec.get("aliases") or []) + list(rec.get("upstream") or [])
    out = []
    for k in ("aliases", "upstream"):
        if rec.get(k) is not None and not isinstance(rec.get(k), list):
            raise Incomplete(f"{k} is not a list")
    for i in raw:
        if not isinstance(i, str):
            raise Incomplete("an advisory ID is not a string")
        if not ID_RE.fullmatch(i):
            continue          # foreign ID shapes are not ours to publish
        u = i.upper()
        if u not in out:
            out.append(u)
    if not out:
        raise Incomplete("advisory without a valid ID")
    # The record's own ID first, then CVEs, then the rest (stable).
    first, rest = out[0], out[1:]
    rest.sort(key=lambda x: (not x.startswith("CVE-"), x))
    out = [first] + rest
    if len(out) > MAX_IDS:
        raise TooLarge(f"{len(out)} IDs")
    return out


def pocket_of(source, purl):
    if not source.startswith("osv:Ubuntu"):
        return None
    if isinstance(purl, str) and "esm-apps" in purl:
        return "esm-apps"
    if isinstance(purl, str) and "esm-infra" in purl:
        return "esm-infra"
    if source.startswith("osv:Ubuntu:Pro:"):
        return "esm-apps" if isinstance(purl, str) and "apps" in purl else "esm-infra"
    return "archive"


RANGE_TYPE_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,31}$")


def convert(rec, source, kev):
    """One OSV record → one advisory dict, or None for a withdrawn record
    that names no affected entry. The WHOLE record is validated first (R2):
    only a fully interpreted record may be dropped for size (TooLarge →
    partial); anything uninterpretable is Incomplete (→ the row is failed)."""
    if not isinstance(rec, dict) or not isinstance(rec.get("id"), str):
        raise Incomplete("record is not an object with an id")
    # R3-R2: withdrawal evidence is validated before it can omit, filter or
    # mark anything (and before any size exit).
    if not withdrawn_valid(rec.get("withdrawn")):
        raise Incomplete("withdrawn is not an RFC 3339 timestamp")
    aff = rec.get("affected")
    if not isinstance(aff, list):
        raise Incomplete("record without an affected list")
    if not aff:
        if rec.get("withdrawn") is not None:
            return None
        raise Incomplete("a record returned for this package names no affected entry")
    ranges, versions, fixed, purl = [], [], [], None
    for a in aff:
        if not isinstance(a, dict):
            raise Incomplete("affected entry is not an object")
        if a.get("purl") is not None and not isinstance(a.get("purl"), str):
            raise Incomplete("purl is not a string")
        purl = purl or a.get("purl")
        # R2-R2: a PRESENT field must have its type; only absence (or JSON
        # null) means "none". `{}` or "" are malformed, never empty.
        rl = a.get("ranges")
        vl = a.get("versions")
        rl = [] if rl is None else rl
        vl = [] if vl is None else vl
        if type(rl) is not list or type(vl) is not list:
            raise Incomplete("ranges/versions are not lists")
        for opt in ("ecosystem_specific", "database_specific"):
            if a.get(opt) is not None and type(a.get(opt)) is not dict:
                raise Incomplete(f"{opt} is not an object")
        for r in rl:
            if not isinstance(r, dict) or not isinstance(r.get("events"), list):
                raise Incomplete("range without events")
            rtype = r.get("type")
            if not isinstance(rtype, str) or not RANGE_TYPE_RE.match(rtype):
                raise Incomplete("range type is not a plain OSV type")
            events = []
            for e in r["events"]:
                if not isinstance(e, dict) or len(e) != 1:
                    raise Incomplete("event must have exactly one key")
                (k, v), = e.items()
                if not isinstance(k, str) or len(k.encode()) > 32:
                    raise Incomplete("event key")
                v = clean_string(v, "event version")
                if not v:
                    raise Incomplete("empty event version")
                events.append({k: v})
                if k == "fixed":
                    fixed.append(v)
            if not events:
                raise Incomplete("range without events")
            ranges.append({"type": rtype, "events": events})
        for v in vl:
            v = clean_string(v, "version")
            if not v:
                raise Incomplete("empty version")
            versions.append(v)
    # Every semantic interpretation BEFORE any size bound (R2-R2): the
    # fixed versions must be orderable, severity well-formed.
    best = None
    for v in fixed:
        if best is None:
            best = v
            if deb_compare(v, v) is None:
                raise Incomplete("a fixed version cannot be ordered")
            continue
        c = deb_compare(v, best)
        if c is None:
            raise Incomplete("fixed versions cannot be ordered")
        if c > 0:
            best = v
    sev = rec.get("severity")
    if sev is not None and (type(sev) is not list or any(type(x) is not dict for x in sev)):
        raise Incomplete("severity is malformed")
    if rec.get("database_specific") is not None and type(rec.get("database_specific")) is not dict:
        raise Incomplete("database_specific is not an object")
    for k in ("published", "modified"):
        if rec.get(k) is not None and type(rec.get(k)) is not str:
            raise Incomplete(f"{k} is not a string")
    ids = advisory_ids(rec)          # may raise TooLarge, only after full validation
    # R1: the union of ranges and explicitly listed versions. A listed
    # version already inside a range adds nothing and is omitted (only when
    # that is PROVEN with dpkg ordering); everything else is kept.
    if ranges and versions and source.startswith(("osv:Debian", "osv:Ubuntu")):
        versions = [v for v in versions if not any(deb_in_range(v, r["events"]) is True for r in ranges if r["type"] == "ECOSYSTEM")]
    seen = set()
    versions = [v for v in versions if not (v in seen or seen.add(v))]
    if len(ranges) > MAX_RANGES or any(len(r["events"]) > MAX_EVENTS for r in ranges):
        raise TooLarge("too many ranges/events")
    if len(versions) > MAX_VERSIONS:
        raise TooLarge("too many versions")
    if ranges or versions:
        affected = {}
        if ranges:
            affected["ranges"] = ranges
        if versions:
            affected["versions"] = versions
    else:
        affected = "unknown"
    kev_hit = [i for i in ids if i in kev]
    adv = {"ids": ids, "kev": bool(kev_hit), "kevAdded": kev.get(kev_hit[0]) if kev_hit else None,
           "severity": "critical" if kev_hit or severity_critical(rec) else "recommended",
           "affected": affected, "withdrawn": rec.get("withdrawn") is not None}
    if fixed:
        adv["remediation"] = {"fixed": [{"line": None, "version": best}], "pocket": pocket_of(source, purl)}
        adv["noFixReason"] = None
    else:
        adv["remediation"] = None
        adv["noFixReason"] = "unknown"
    adv["_order"] = (0 if adv["kev"] else 1, 0 if adv["severity"] == "critical" else 1,
                     -(_ts(rec.get("published")) or _ts(rec.get("modified")) or 0))
    return adv


def deb_in_range(v, events):
    """OSV evaluation with dpkg ordering (mirrors the client); None when a
    comparison is impossible."""
    def key(e):
        (k, x), = e.items()
        return k, x
    evs = [key(e) for e in events]
    if any(k not in EVENTS for k, _ in evs):
        return None
    # insertion sort with "introduced: 0" first, introduced before others on ties
    out = []
    for k, x in evs:
        i = len(out)
        for j, (k2, x2) in enumerate(out):
            if k == "introduced" and x == "0":
                c = 0 if (k2 == "introduced" and x2 == "0") else -1
            elif k2 == "introduced" and x2 == "0":
                c = 1
            else:
                c = deb_compare(x, x2)
                if c is None:
                    return None
                if c == 0 and k != k2:
                    c = -1 if k == "introduced" else (1 if k2 == "introduced" else 0)
            if c < 0:
                i = j
                break
        out.insert(i, (k, x))
    affected = False
    for k, x in out:
        if k == "introduced":
            if x == "0":
                affected = True
                continue
            c = deb_compare(v, x)
            if c is None:
                return None
            if c >= 0:
                affected = True
        elif k == "fixed":
            c = deb_compare(v, x)
            if c is None:
                return None
            if c >= 0:
                affected = False
        elif k == "last_affected":
            c = deb_compare(v, x)
            if c is None:
                return None
            if c > 0:
                affected = False
        elif k == "limit":
            c = deb_compare(v, x)
            if c is None:
                return None
            if c >= 0:
                return False
    return affected


def _ts(s):
    try:
        return parse_iso(s)
    except (ValueError, TypeError):
        return None


def severity_critical(rec):
    for s in rec.get("severity") or []:
        if isinstance(s, dict) and str(s.get("score", "")).lower() == "critical":
            return True
    ds = rec.get("database_specific")
    return isinstance(ds, dict) and str(ds.get("severity", "")).upper() == "CRITICAL"


# ---------------------------------------------------------------- Debian versions

def _order(c):
    if c is None:
        return 0
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    if c == "~":
        return -1
    return ord(c) + 256


def _verrevcmp(a, b):
    i = j = 0
    while i < len(a) or j < len(b):
        first_diff = 0
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac = _order(a[i] if i < len(a) else None)
            bc = _order(b[j] if j < len(b) else None)
            if ac != bc:
                return ac - bc
            i += 1
            j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        while i < len(a) and a[i].isdigit() and j < len(b) and b[j].isdigit():
            if not first_diff:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < len(a) and a[i].isdigit():
            return 1
        if j < len(b) and b[j].isdigit():
            return -1
        if first_diff:
            return first_diff
    return 0


DEB_RE = re.compile(r"^(?:(\d+):)?([0-9][A-Za-z0-9.+~:-]*?)(?:-([A-Za-z0-9.+~]+))?$")


def deb_compare(a, b):
    """dpkg's ordering (deb-version(7)); None for an invalid version."""
    out = []
    for v in (a, b):
        m = DEB_RE.match(v or "")
        if not m:
            return None
        out.append((int(m.group(1) or 0), m.group(2), m.group(3) or ""))
    (ea, ua, ra), (eb, ub, rb) = out
    if ea != eb:
        return -1 if ea < eb else 1
    c = _verrevcmp(ua, ub) or _verrevcmp(ra, rb)
    return 0 if c == 0 else (-1 if c < 0 else 1)


_DEB_UP = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+~-:")
_DEB_REV = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+~")


def client_deb_valid(v):
    """True only for a version the CLIENT parses (LocalToolsVersion.parseDeb)
    AND this module parses, written without surrounding whitespace. Pruning
    compares only such versions, so a pruned advisory is one the client would
    have evaluated to a definite "not affected", never to "cannot compare"."""
    if type(v) is not str or not v or len(v.encode("utf-8")) > 256 or not v.isascii():
        return False
    if any(c.isspace() for c in v):
        return False
    rest = v
    if ":" in rest:
        e, rest = rest.split(":", 1)
        if not e or not all(c in "0123456789" for c in e) or int(e) >= 1_000_000:
            return False
    up, rev = rest, None
    if "-" in rest:
        up, rev = rest.rsplit("-", 1)
        if not rev:
            return False
    if not up or up[0] not in "0123456789":
        return False
    if not all(c in _DEB_UP for c in up) or (rev is not None and not all(c in _DEB_REV for c in rev)):
        return False
    return deb_compare(v, v) == 0


def load_floors(path):
    """identity key → floor version, from security/deb-floors.json. A missing
    or malformed file disables pruning entirely (lossless by default); an
    entry whose floor is null or not a client-parsable version has no floor."""
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        return None, f"floors unavailable ({e.__class__.__name__}): pruning disabled"
    if type(d) is not dict or d.get("schema") != 1 or type(d.get("floors")) is not dict:
        return None, "floors file malformed: pruning disabled"
    out = {}
    for k, v in d["floors"].items():
        if type(k) is str and type(v) is dict and client_deb_valid(v.get("floor")):
            out[k] = v["floor"]
    return out, None


def prunable(adv, floor):
    """True only when `adv` provably matches no client version >= `floor`
    (the client's isAffected would return a definite false for every one of
    them), and it is not one of the advisories kept for other reasons."""
    if not client_deb_valid(floor):
        return False
    if adv.get("withdrawn") or adv.get("kev") or adv.get("remediation") is None or adv.get("noFixReason") is not None:
        return False
    if adv.get("kind") is not None or adv.get("unknownOutside"):
        return False
    af = adv.get("affected")
    if type(af) is not dict or not (af.get("ranges") or af.get("versions")):
        return False
    for v in af.get("versions") or []:
        if not client_deb_valid(v) or deb_compare(v, floor) >= 0:
            return False
    for r in af.get("ranges") or []:
        if r.get("type") != "ECOSYSTEM" or not r.get("events"):
            return False
        evs = []
        for e in r["events"]:
            if type(e) is not dict or len(e) != 1:
                return False
            (k, x), = e.items()
            if k not in EVENTS or not client_deb_valid(x):
                return False
            if k == "introduced" and x == "0":
                continue
            if deb_compare(x, floor) >= 0:
                return False          # every event strictly below the floor
            evs.append((k, x))
        if not evs:
            return False              # "introduced 0" alone: always affected
        # The highest event(s) must all close the range (fixed, last_affected
        # or limit), whatever the tie order: every event applies to any
        # v >= floor, so the last one decides and it is "not affected".
        top = evs[0][1]
        for _, x in evs[1:]:
            if deb_compare(x, top) > 0:
                top = x
        if any(k == "introduced" for k, x in evs if deb_compare(x, top) == 0):
            return False
        if deb_in_range(floor, r["events"]) is not False:
            return False              # belt and braces: the mirror agrees
    return True


# ---------------------------------------------------------------- build

def previous_rows(prev):
    rows, advisories = {}, {}
    if not prev:
        return rows, advisories
    for c in prev.get("coverage", []):
        rows[(c["identity"], c["source"])] = c
    for e in prev.get("entries", []):
        advisories[identity_key(e["identity"])] = e.get("advisories", [])
    return rows, advisories


def build(watchlist_path, bundle, prev, now, platforms_path=None, floors=None, report=None):
    """floors: identity key → floor (load_floors); None prunes nothing.
    report: a dict filled with per-source pruned counts (builder report only;
    nothing about pruning is written into the payload)."""
    if report is not None:
        report.setdefault("pruned", {})
    platforms_path = platforms_path or advisory_libreoffice.DEFAULT_PLATFORMS
    ecos, ids = load_watchlist(watchlist_path)
    if not isinstance(bundle, dict) or bundle.get("schema") != 1:
        raise Refuse("bundle schema must be 1")
    results = bundle.get("results")
    if not isinstance(results, list):
        raise Refuse("bundle has no results list")
    kev_src = (bundle.get("sources") or {}).get("cisa-kev") or {}
    # The KEV map counts only when it is complete and well-formed: CVE keys,
    # dateAdded strings (or null); anything else makes KEV coverage failed.
    cves = kev_src.get("cves")
    kev_ok = (kev_src.get("status") == "ok" and type(cves) is dict and bool(cves)
              and all(type(k) is str and re.fullmatch(r"CVE-[0-9]{4}-[0-9]{4,}", k, re.ASCII)
                      and (v is None or (type(v) is str and len(v.encode()) <= 32 and v.isprintable())) for k, v in cves.items()))
    if kev_ok and not wire_time(kev_src.get("checkedAt")):
        kev_ok = False            # N5-1: one wire-compatible rule, never a refusal
    kev = dict(cves) if kev_ok else {}
    prev_rows, prev_adv = previous_rows(prev)
    by_row = {}
    for r in results:
        if not isinstance(r, dict) or not isinstance(r.get("identity"), dict) or not isinstance(r.get("source"), str):
            raise Refuse("malformed bundle row")
        key = (identity_key(r["identity"]), r["source"])
        if key in by_row:
            raise Refuse(f"duplicate bundle row {key}")
        by_row[key] = r

    coverage, entries = [], []
    for ident in ids:
        if ident.get("kind") == "vendor":
            ikey = identity_key(ident)
            eco_key = f"vendor:{ident['vendor']}:{ident['product']}"
            if ident["vendor"] == "nodejs.org":
                advs, statuses, lines = advisory_node.node_identity(ident["platform"], bundle.get("sources") or {}, kev, now)
            else:
                advs, statuses = advisory_libreoffice.libreoffice_identity(bundle.get("sources") or {}, kev,
                                                                          advisory_libreoffice.load_platforms(platforms_path))
                lines = None
            statuses["cisa-kev"] = ("ok", kev_src.get("checkedAt")) if kev_ok else ("failed", None)
            for source, (status, checked) in list(statuses.items()):
                if status != "failed" and not wire_time(checked):
                    statuses[source] = ("failed", None)
            advs = cap_advisories(advs, statuses)
            coverage += coverage_rows(ikey, ecos[eco_key]["sources"], statuses, prev_rows)
            entry = {"identity": {k: ident[k] for k in ("kind", "vendor", "product", "platform", "flavour")},
                     "scheme": "semver" if ident["vendor"] == "nodejs.org" else "dotted", "advisories": advs}
            if lines is not None:
                entry["maintainedLines"] = lines
            entries.append(entry)
            continue
        ikey = identity_key(ident)
        eco = ecos[f"deb:{ident['distro']}:{ident['release']}"]
        advs, statuses, complete = [], {}, True
        floor = (floors or {}).get(ikey)
        pruned, pruned_ids = [], set()
        for source in eco["sources"]:
            if source == "cisa-kev":
                statuses[source] = ("ok", kev_src.get("checkedAt")) if kev_ok else ("failed", None)
                continue
            row = by_row.get((ikey, source))
            if not row or row.get("status") != "ok" or not isinstance(row.get("records"), list):
                statuses[source] = ("failed", None)
                complete = False
                continue
            try:
                if not wire_time(row.get("checkedAt")):
                    raise Incomplete("checkedAt is not a wire timestamp")
                converted, dropped = [], False
                for rec in row["records"]:
                    try:
                        a = convert(rec, source, kev)
                    except TooLarge:
                        dropped = True
                        continue
                    if a is None:
                        continue
                    if a["withdrawn"]:
                        since = withdrawn_since(prev_adv.get(ikey, []), a["ids"], now)
                        if now - parse_iso(since) > WITHDRAWN_DAYS * 86400:
                            continue
                        a["withdrawnAt"] = since
                        a["_order"] = (2, 2, 0)
                    a["_source"] = source
                    if floor is not None and prunable(a, floor):
                        pruned.append(a)          # lossless: never "cut for size"
                        pruned_ids.update(a["ids"])
                        continue
                    converted.append(a)
                advs += converted
                statuses[source] = ("partial" if dropped else "ok", row["checkedAt"])
            except (Incomplete, ValueError) as e:
                statuses[source] = ("failed", None)
                complete = False
        # Withdrawn carry: advisories of the previous list that no source
        # still publishes, for an identity fully checked in this run.
        if complete and all(s[0] in ("ok", "partial") for s in statuses.values()):
            # A pruned advisory is still published by its source: it must not
            # be carried as withdrawn.
            present = {i for a in advs for i in a["ids"]} | pruned_ids
            for old in prev_adv.get(ikey, []):
                if set(old.get("ids", [])) & present:
                    continue
                since = old.get("withdrawnAt") or iso(now)
                if now - parse_iso(since) > WITHDRAWN_DAYS * 86400:
                    continue
                w = {k: old[k] for k in ("ids", "severity", "kev", "kevAdded", "affected", "remediation", "noFixReason") if k in old}
                w.update({"withdrawn": True, "withdrawnAt": since, "_order": (2, 2, 0), "_source": None})
                advs.append(w)
        # Sentinel: when pruning would leave no live advisory at all, keep the
        # first pruned one, so a client version it cannot parse still reads
        # "cannot be evaluated" exactly as before (never "no known issue").
        if pruned and not any(not a.get("withdrawn") for a in advs):
            pruned.sort(key=lambda a: a["_order"])
            advs.append(pruned.pop(0))
        if report is not None:
            for a in pruned:
                key = f"{ikey} {a['_source']}"
                report["pruned"][key] = report["pruned"].get(key, 0) + 1
        # Trim to the per-identity cap: KEV, critical, newest first.
        advs = cap_advisories(advs, statuses)
        coverage += coverage_rows(ikey, eco["sources"], statuses, prev_rows)
        entries.append({"identity": dict(ident, kind="deb"), "scheme": "deb", "advisories": advs})

    payload = {"schema": 1, "published": iso(now), "expires": iso(now + VALIDITY),
               "sequence": max(int((prev or {}).get("sequence", -1)) + 1, int(now // 60)),
               "declared": [{"ecosystem": k, "sources": v["sources"]} for k, v in sorted(ecos.items())],
               "coverage": coverage, "entries": entries}
    trim_to_size(payload)
    for e in payload["entries"]:
        for a in e["advisories"]:
            a.pop("_order", None)
            a.pop("_source", None)
    data = encode(payload)
    check_payload(data)
    return data


def cap_advisories(advs, statuses):
    """Trim to the per-identity cap: KEV, critical, newest first; the source
    of every dropped advisory becomes partial (F3)."""
    advs.sort(key=lambda a: a["_order"])
    if len(advs) > MAX_ADVISORIES:
        for a in advs[MAX_ADVISORIES:]:
            mark_partial(statuses, a["_source"])
        advs = advs[:MAX_ADVISORIES]
    return advs


def coverage_rows(ikey, sources, statuses, prev_rows):
    """One row per declared source; a failed source keeps the previous
    list's last good checkedAt (never "now")."""
    rows = []
    for source in sources:
        status, checked = statuses[source]
        if status == "failed":
            old = prev_rows.get((ikey, source))
            checked = old["checkedAt"] if old and old.get("status") in ("ok", "partial", "failed") else iso(0)
        rows.append({"identity": ikey, "source": source, "status": status, "checkedAt": checked})
    return rows


def withdrawn_since(previous, ids, now):
    for old in previous:
        if old.get("withdrawn") and set(old.get("ids", [])) & set(ids) and old.get("withdrawnAt"):
            return old["withdrawnAt"]
    return iso(now)


def mark_partial(statuses, source):
    if source and statuses.get(source, ("failed",))[0] == "ok":
        statuses[source] = ("partial", statuses[source][1])


def encode(payload):
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()


def trim_to_size(payload):
    """Drop the lowest-priority advisory of the identity with the most
    advisories until the document fits; mark its source partial. Sizes are
    tracked incrementally (one full encode per pass, not per drop)."""
    def adv_size(a):
        return len(encode({k: v for k, v in a.items() if not k.startswith("_")})) + 1
    total = len(encode(strip(payload)))
    while total > MAX_PAYLOAD:
        while total > MAX_PAYLOAD:
            e = max((e for e in payload["entries"] if e["advisories"]), key=lambda e: len(e["advisories"]), default=None)
            if e is None:
                raise Refuse("document too large even without advisories")
            victim = e["advisories"].pop()
            total -= adv_size(victim)
            ikey = identity_key(e["identity"])
            for c in payload["coverage"]:
                if c["identity"] == ikey and c["source"] == victim.get("_source") and c["status"] == "ok":
                    c["status"] = "partial"
        total = len(encode(strip(payload)))


def strip(payload):
    return {**payload, "entries": [{**e, "advisories": [{k: v for k, v in a.items() if not k.startswith("_")}
                                                        for a in e["advisories"]]} for e in payload["entries"]]}


# ---------------------------------------------------------------- validation

def _is_int(v):
    return type(v) is int


def _cstr(v, what):
    """The client's `string()`: a JSON string of ≤ 512 UTF-8 bytes with no
    Unicode control or format character (CharacterSet.controlCharacters)."""
    if type(v) is not str:
        raise Refuse(f"{what} is not a string")
    if len(v.encode("utf-8")) > MAX_STRING:
        raise Refuse(f"{what} is longer than {MAX_STRING} bytes")
    if any(unicodedata.category(c) in ("Cc", "Cf") for c in v):
        raise Refuse(f"{what} contains control characters")
    return v


def _cname(v, what):
    s = _cstr(v, what)
    if not NAME_RE.fullmatch(s):
        raise Refuse(f"{what} is not a valid name")
    return s


def _clist(v, what, mx):
    if type(v) is not list:
        raise Refuse(f"{what} is not a list")
    if len(v) > mx:
        raise Refuse(f"{what} has more than {mx} entries")
    return v


WIRE_TIME_RE = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:(Z)|[+-]([0-9]{2}):([0-9]{2}))",
                          re.ASCII)


def wire_time(v):
    """The one timestamp form the publisher writes and the client parses
    (ISO8601DateFormatter .withInternetDateTime): ASCII digits, a real date
    and time, no fraction, Z or ±HH:MM with HH ≤ 23 and MM ≤ 59 (N5-1)."""
    if type(v) is not str:
        return False
    m = WIRE_TIME_RE.fullmatch(v)
    if not m:
        return False
    try:
        datetime.datetime(*(int(m.group(i)) for i in range(1, 7)))
    except ValueError:
        return False
    return m.group(7) is not None or (int(m.group(8)) <= 23 and int(m.group(9)) <= 59)


def _cdate(v, what):
    if not wire_time(v):
        raise Refuse(f"{what} is not an ISO 8601 timestamp")
    return parse_iso(v)


def check_payload(data):
    """The client's structural parse (LocalAdvisoryParse.swift), mirrored
    rule for rule, plus the verifier's validity/sequence bounds; any
    violation refuses to sign. Signing something the client rejects would
    turn every state unknown (N1)."""
    if len(data) > MAX_PAYLOAD:
        raise Refuse(f"payload is {len(data)} bytes")
    try:
        d = json.loads(data)
    except ValueError:
        raise Refuse("payload is not JSON")
    if type(d) is not dict:
        raise Refuse("payload is not a JSON object")
    if d.get("schema") != 1 or not _is_int(d.get("schema")):
        raise Refuse("unsupported schema")
    if not _is_int(d.get("sequence")) or not 0 <= d["sequence"] < 2 ** 53:
        raise Refuse("sequence")
    pub, exp = _cdate(d.get("published"), "published"), _cdate(d.get("expires"), "expires")
    if not 0 < exp - pub <= 72 * 3600:
        raise Refuse("validity must be within 72 h")
    declared = {}
    for x in _clist(d.get("declared"), "declared", 64):
        if type(x) is not dict:
            raise Refuse("declared entry is not an object")
        eco = _cname(x.get("ecosystem"), "declared.ecosystem")
        if eco in declared:
            raise Refuse("ecosystem declared twice")
        srcs = [_cname(v, "source") for v in _clist(x.get("sources"), "declared.sources", 8)]
        if not srcs or len(set(srcs)) != len(srcs):
            raise Refuse("declared sources empty or repeated")
        declared[eco] = srcs
    pairs = set()
    for c in _clist(d.get("coverage"), "coverage", 512):
        if type(c) is not dict:
            raise Refuse("coverage row is not an object")
        st = c.get("status")
        if type(st) is not str or len(st.encode()) > 32:
            raise Refuse("coverage status missing")
        if st not in ("ok", "failed", "not-covered", "partial"):
            raise Refuse("coverage status not in the enum (publisher never writes others)")
        k = (_cstr(c.get("identity"), "coverage.identity"), _cname(c.get("source"), "coverage.source"))
        if k in pairs:
            raise Refuse(f"duplicate (identity, source) coverage pair {k} — refusing to sign")
        pairs.add(k)
        _cdate(c.get("checkedAt"), "coverage.checkedAt")
    seen = set()
    for e in _clist(d.get("entries"), "entries", MAX_IDENTITIES):
        if type(e) is not dict:
            raise Refuse("entry is not an object")
        k = _check_identity(e.get("identity"))
        if k in seen:
            raise Refuse("two entries for one identity")
        seen.add(k)
        sc = e.get("scheme")
        if type(sc) is not str or len(sc.encode()) > 32:
            raise Refuse("entry scheme missing")
        for a in _clist(e.get("advisories"), "advisories", MAX_ADVISORIES):
            _check_advisory(a)
        if "maintainedLines" in e:
            ml = _clist(e["maintainedLines"], "maintainedLines", 32)
            if not ml or any(type(x) is not str or not re.fullmatch(r"[1-9][0-9]{0,3}", x) for x in ml) or len(set(ml)) != len(ml):
                raise Refuse("maintainedLines must be distinct line numbers")
    return d


def _check_identity(i):
    if type(i) is not dict or i.get("kind") not in ("deb", "brew", "cask", "vendor"):
        raise Refuse("identity kind missing or unknown")
    need = {"deb": ("distro", "release", "source"), "brew": ("tap", "formula"), "cask": ("token",),
            "vendor": ("vendor", "product", "platform", "flavour")}[i["kind"]]
    vals = [_cname(i.get(f), f"identity.{f}") for f in need]
    if i["kind"] == "deb" and vals[0] not in ("debian", "ubuntu"):
        raise Refuse("deb distro not debian|ubuntu")
    if i["kind"] == "brew" and not (_is_int(i.get("versionScheme")) and 0 <= i["versionScheme"] < 1000):
        raise Refuse("brew versionScheme missing")
    return i["kind"] + ":" + ":".join(vals)


def _check_advisory(a):
    if type(a) is not dict:
        raise Refuse("advisory is not an object")
    ids = []
    for v in _clist(a.get("ids"), "ids", MAX_IDS):
        if type(v) is not str or not ID_RE.fullmatch(v):
            raise Refuse("advisory ID does not match the ID pattern")
        if v.upper() not in ids:
            ids.append(v.upper())
    if not ids:
        raise Refuse("advisory without IDs")
    if a.get("severity") not in ("recommended", "critical") or type(a.get("severity")) is not str:
        raise Refuse("severity")
    if type(a.get("kev")) is not bool:
        raise Refuse("kev is not a bool")
    if a.get("kevAdded") is not None:
        _cstr(a["kevAdded"], "kevAdded")
    af = a.get("affected")
    if af != "unknown":
        if type(af) is not dict:
            raise Refuse("affected missing")
        rs = [_check_range(r) for r in _clist(af["ranges"], "ranges", MAX_RANGES)] if "ranges" in af else []
        vs = [_cstr(v, "version") for v in _clist(af["versions"], "versions", MAX_VERSIONS)] if "versions" in af else []
        if not rs and not vs:
            raise Refuse("affected has neither ranges nor versions")
    rem = a.get("remediation")
    if rem is not None:
        if type(rem) is not dict:
            raise Refuse("remediation is not an object")
        fx = _clist(rem.get("fixed"), "remediation.fixed", 16)
        if not fx:
            raise Refuse("remediation without a fixed version")
        for f in fx:
            if type(f) is not dict:
                raise Refuse("fixed entry is not an object")
            if f.get("line") is not None:
                _cstr(f["line"], "fixed.line")
            if not _cstr(f.get("version"), "fixed.version"):
                raise Refuse("empty fixed version")
        if rem.get("pocket") is not None and rem.get("pocket") not in ("archive", "esm-infra", "esm-apps"):
            raise Refuse("unknown pocket")
    if a.get("noFixReason") is not None and type(a.get("noFixReason")) is not str:
        raise Refuse("noFixReason is not a string")
    if a.get("binaries") is not None:
        for b in _clist(a["binaries"], "binaries", 64):
            _cname(b, "binary")
    if "withdrawn" in a and type(a["withdrawn"]) is not bool:
        raise Refuse("withdrawn is not a bool")
    # v17-v19 additive fields (the client parses them strictly too).
    if a.get("kind") is not None and a.get("kind") != "release":
        raise Refuse("advisory kind must be absent or 'release'")
    if a.get("unknownOutside") is not None and type(a.get("unknownOutside")) is not bool:
        raise Refuse("unknownOutside is not a bool")


def _check_range(r):
    if type(r) is not dict:
        raise Refuse("range is not an object")
    t = r.get("type")
    if type(t) is not str or len(t.encode()) > 32:
        raise Refuse("range type missing")
    for e in _clist(r.get("events"), "events", MAX_EVENTS):
        if type(e) is not dict or len(e) != 1:
            raise Refuse("an event must have exactly one key")
        (k, v), = e.items()
        if not _cstr(v, "event version"):
            raise Refuse("empty event version")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--input", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--previous")
    b.add_argument("--watchlist", default=DEFAULT_WATCHLIST)
    b.add_argument("--now")
    b.add_argument("--floors", default=DEFAULT_FLOORS)
    b.add_argument("--no-prune", action="store_true")
    b.add_argument("--report")
    c = sub.add_parser("check")
    c.add_argument("payload")
    args = p.parse_args(argv)
    try:
        if args.cmd == "check":
            check_payload(open(args.payload, "rb").read())
            print("✔ payload valid")
            return 0
        with open(args.input) as f:
            bundle = json.load(f)
        prev = None
        if args.previous:
            with open(args.previous, "rb") as f:
                raw = f.read()
            prev = check_payload(raw)   # the previous list must itself be valid
        now = parse_iso(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc).timestamp()
        floors, why = (None, "pruning disabled (--no-prune)") if args.no_prune else load_floors(args.floors)
        if why:
            print(f"⚠ {why}", file=sys.stderr)
        report = {}
        data = build(args.watchlist, bundle, prev, now, floors=floors, report=report)
        with open(args.out, "wb") as f:
            f.write(data)
        d = json.loads(data)
        st = {}
        for c in d["coverage"]:
            st[c["status"]] = st.get(c["status"], 0) + 1
        print(f"✔ advisory list payload: sequence {d['sequence']}, {len(d['entries'])} identities, "
              f"{sum(len(e['advisories']) for e in d['entries'])} advisories, {len(data)} bytes, coverage {st}")
        pr = report.get("pruned", {})
        print(f"  lossless pruning: {sum(pr.values())} advisories below their release floor not published"
              + ("" if floors is not None else " (disabled)")
              + "".join(f"\n    {k}: {v}" for k, v in sorted(pr.items())))
        if args.report:
            with open(args.report, "w") as f:
                json.dump({"bytes": len(data), "coverage": st, "pruned": pr,
                           "floorsLoaded": floors is not None, "floorIdentities": len(floors or {})}, f, indent=1, sort_keys=True)
        return 0
    except (Refuse, ValueError, KeyError, TypeError, OSError) as e:
        print(f"✖ refused: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
