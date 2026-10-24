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
    checked identity carried as withdrawn for 30 days, then dropped.

Usage:
  advisory_publish.py build --input BUNDLE --out PAYLOAD [--previous PAYLOAD] [--watchlist PATH] [--now ISO]
  advisory_publish.py check PAYLOAD        (validate an existing payload)
Exit: 0 written/valid, 2 refused (nothing to sign).
"""
import argparse
import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from advisory_fetch import DEFAULT_WATCHLIST, load_watchlist  # noqa: E402

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
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{2,63}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9@+._:/-]{0,127}$")
RANGE_TYPES = ("ECOSYSTEM", "SEMVER", "GIT")
EVENTS = ("introduced", "fixed", "last_affected", "limit")


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
    return f"deb:{i['distro']}:{i['release']}:{i['source']}"


# ---------------------------------------------------------------- conversion

def advisory_ids(rec):
    raw = [rec.get("id")] + list(rec.get("aliases") or []) + list(rec.get("upstream") or [])
    out = []
    for i in raw:
        if not isinstance(i, str):
            raise Incomplete("an advisory ID is not a string")
        if not ID_RE.match(i):
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


def convert(rec, source, kev):
    """One OSV record → one advisory dict, or None when it does not apply
    to this package/ecosystem."""
    if not isinstance(rec, dict):
        raise Incomplete("record is not an object")
    aff = rec.get("affected")
    if not isinstance(aff, list):
        raise Incomplete("record without an affected list")
    if not aff:
        return None
    ids = advisory_ids(rec)
    ranges, versions, fixed, purl = [], [], [], None
    for a in aff:
        if not isinstance(a, dict):
            raise Incomplete("affected entry is not an object")
        purl = purl or a.get("purl")
        for r in a.get("ranges") or []:
            if not isinstance(r, dict) or not isinstance(r.get("events"), list):
                raise Incomplete("range without events")
            rtype = r.get("type")
            if not isinstance(rtype, str) or len(rtype) > 32:
                raise Incomplete("range without a type")
            events = []
            for e in r["events"]:
                if not isinstance(e, dict) or len(e) != 1:
                    raise Incomplete("event must have exactly one key")
                (k, v), = e.items()
                v = clean_string(v, "event version")
                if not v:
                    raise Incomplete("empty event version")
                events.append({k: v})
                if k == "fixed":
                    fixed.append(v)
            if len(events) > MAX_EVENTS:
                raise TooLarge("too many events")
            ranges.append({"type": rtype, "events": events})
        for v in a.get("versions") or []:
            versions.append(clean_string(v, "version"))
    if len(ranges) > MAX_RANGES:
        raise TooLarge("too many ranges")
    if ranges:
        affected = {"ranges": ranges}
    elif versions:
        if len(versions) > MAX_VERSIONS:
            raise TooLarge("too many versions")
        affected = {"versions": versions}
    else:
        affected = "unknown"
    kev_hit = [i for i in ids if i in kev]
    adv = {"ids": ids, "kev": bool(kev_hit), "kevAdded": kev.get(kev_hit[0]) if kev_hit else None,
           "severity": "critical" if kev_hit or severity_critical(rec) else "recommended",
           "affected": affected, "withdrawn": bool(rec.get("withdrawn"))}
    if fixed:
        # Several fixed events in one ecosystem: the highest is recorded
        # (conservative); versions dpkg's algorithm cannot order → incomplete.
        best = fixed[0]
        for v in fixed[1:]:
            c = deb_compare(v, best)
            if c is None:
                raise Incomplete("fixed versions cannot be ordered")
            if c > 0:
                best = v
        adv["remediation"] = {"fixed": [{"line": None, "version": best}], "pocket": pocket_of(source, purl)}
        adv["noFixReason"] = None
    else:
        adv["remediation"] = None
        adv["noFixReason"] = "unknown"
    adv["_order"] = (0 if adv["kev"] else 1, 0 if adv["severity"] == "critical" else 1,
                     -(_ts(rec.get("published")) or _ts(rec.get("modified")) or 0))
    return adv


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


def build(watchlist_path, bundle, prev, now):
    ecos, ids = load_watchlist(watchlist_path)
    if not isinstance(bundle, dict) or bundle.get("schema") != 1:
        raise Refuse("bundle schema must be 1")
    results = bundle.get("results")
    if not isinstance(results, list):
        raise Refuse("bundle has no results list")
    kev_src = (bundle.get("sources") or {}).get("cisa-kev") or {}
    kev_ok = kev_src.get("status") == "ok" and isinstance(kev_src.get("cves"), dict)
    kev = {k: v for k, v in (kev_src.get("cves") or {}).items() if isinstance(k, str)} if kev_ok else {}
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
        ikey = identity_key(ident)
        eco = ecos[f"deb:{ident['distro']}:{ident['release']}"]
        advs, statuses, complete = [], {}, True
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
                parse_iso(row.get("checkedAt"))
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
                    converted.append(a)
                advs += converted
                statuses[source] = ("partial" if dropped else "ok", row["checkedAt"])
            except (Incomplete, ValueError) as e:
                statuses[source] = ("failed", None)
                complete = False
        # Withdrawn carry: advisories of the previous list that no source
        # still publishes, for an identity fully checked in this run.
        if complete and all(s[0] in ("ok", "partial") for s in statuses.values()):
            present = {i for a in advs for i in a["ids"]}
            for old in prev_adv.get(ikey, []):
                if set(old.get("ids", [])) & present:
                    continue
                since = old.get("withdrawnAt") or iso(now)
                if now - parse_iso(since) > WITHDRAWN_DAYS * 86400:
                    continue
                w = {k: old[k] for k in ("ids", "severity", "kev", "kevAdded", "affected", "remediation", "noFixReason") if k in old}
                w.update({"withdrawn": True, "withdrawnAt": since, "_order": (2, 2, 0), "_source": None})
                advs.append(w)
        # Trim to the per-identity cap: KEV, critical, newest first.
        advs.sort(key=lambda a: a["_order"])
        if len(advs) > MAX_ADVISORIES:
            for a in advs[MAX_ADVISORIES:]:
                mark_partial(statuses, a["_source"])
            advs = advs[:MAX_ADVISORIES]
        for source in eco["sources"]:
            status, checked = statuses[source]
            if status == "failed":
                old = prev_rows.get((ikey, source))
                checked = old["checkedAt"] if old and old.get("status") in ("ok", "partial", "failed") else iso(0)
            coverage.append({"identity": ikey, "source": source, "status": status, "checkedAt": checked})
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

def check_payload(data):
    """Independent re-check of every bound the client enforces; any
    violation refuses to sign."""
    if len(data) > MAX_PAYLOAD:
        raise Refuse(f"payload is {len(data)} bytes")
    d = json.loads(data)
    if d.get("schema") != 1 or not isinstance(d.get("sequence"), int) or not 0 <= d["sequence"] < 2 ** 53:
        raise Refuse("schema/sequence")
    pub, exp = parse_iso(d["published"]), parse_iso(d["expires"])
    if not 0 < exp - pub <= 72 * 3600:
        raise Refuse("validity must be within 72 h")
    declared = {}
    for x in d["declared"]:
        if x["ecosystem"] in declared or not x["sources"] or len(set(x["sources"])) != len(x["sources"]):
            raise Refuse("declared ecosystems")
        declared[x["ecosystem"]] = x["sources"]
    pairs = set()
    for c in d["coverage"]:
        k = (c["identity"], c["source"])
        if k in pairs:
            raise Refuse(f"duplicate (identity, source) coverage pair {k} — refusing to sign")
        pairs.add(k)
        if c["status"] not in ("ok", "failed", "not-covered", "partial"):
            raise Refuse("coverage status")
        parse_iso(c["checkedAt"])
    if len(d["entries"]) > MAX_IDENTITIES:
        raise Refuse("too many identities")
    seen = set()
    for e in d["entries"]:
        i = e["identity"]
        k = identity_key(i)
        if k in seen:
            raise Refuse("two entries for one identity")
        seen.add(k)
        for f in ("distro", "release", "source"):
            if not NAME_RE.match(i[f]):
                raise Refuse("identity name")
        if len(e["advisories"]) > MAX_ADVISORIES:
            raise Refuse("too many advisories")
        for a in e["advisories"]:
            if not a["ids"] or len(a["ids"]) > MAX_IDS or not all(ID_RE.match(x) for x in a["ids"]):
                raise Refuse("advisory IDs")
            if a["severity"] not in ("recommended", "critical") or not isinstance(a["kev"], bool):
                raise Refuse("severity/kev")
            walk_strings(a)
    return d


def walk_strings(v):
    if isinstance(v, str):
        if len(v.encode()) > MAX_STRING or any(ord(c) < 32 for c in v):
            raise Refuse("string bound")
    elif isinstance(v, dict):
        for x in v.values():
            walk_strings(x)
    elif isinstance(v, list):
        for x in v:
            walk_strings(x)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--input", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--previous")
    b.add_argument("--watchlist", default=DEFAULT_WATCHLIST)
    b.add_argument("--now")
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
        data = build(args.watchlist, bundle, prev, now)
        with open(args.out, "wb") as f:
            f.write(data)
        d = json.loads(data)
        st = {}
        for c in d["coverage"]:
            st[c["status"]] = st.get(c["status"], 0) + 1
        print(f"✔ advisory list payload: sequence {d['sequence']}, {len(d['entries'])} identities, "
              f"{sum(len(e['advisories']) for e in d['entries'])} advisories, {len(data)} bytes, coverage {st}")
        return 0
    except (Refuse, ValueError, KeyError, TypeError, OSError) as e:
        print(f"✖ refused: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
