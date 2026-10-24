#!/usr/bin/env python3
"""Fetch the raw advisory data for the local-tools advisory list (security
plan v16 §9.5.3). Runs inside the daily Security watch job, which holds no
secrets (issues: write, contents: read): it only reads public feeds and
writes one bounded JSON bundle that the separate publishing workflow
validates, builds and signs. It never signs, publishes or executes anything
from the feeds.

For every (identity, declared OSV ecosystem) of security/local-tools.json it
queries OSV `/v1/query` by package (all advisories of that source package,
pagination followed to the end) and keeps, per record, only the `affected`
entries for exactly that package and ecosystem. CISA KEV is fetched once.
A source is `ok` only when every page arrived and parsed; anything else is
`failed` for that row (never "no advisories").

Usage: advisory_fetch.py --out DIR [--watchlist PATH] [--osv-api URL] [--kev-url URL]
Exit: 0 bundle written (some rows may be failed), 2 configuration error.
"""
import argparse
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_WATCHLIST = os.path.join(ROOT, "security", "local-tools.json")
OSV_API = "https://api.osv.dev"
KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
MAX_RESPONSE = 32 * 1024 * 1024
MAX_PAGES = 20
MAX_RECORDS = 2000
MAX_BUNDLE = 64 * 1024 * 1024
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9@+._:/-]{0,127}$")
UA = "briglia-security-watch (advisory-list fetch)"


class FeedError(Exception):
    pass


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def http_json(url, body=None, timeout=60, retries=2, backoff=2.0):
    data = json.dumps(body).encode() if body is not None else None
    last = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=data, method="POST" if data else "GET",
                                     headers={"User-Agent": UA, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read(MAX_RESPONSE + 1)
                if len(raw) > MAX_RESPONSE:
                    raise FeedError(f"{url}: response larger than {MAX_RESPONSE} bytes")
                return json.loads(raw)
        except (urllib.error.URLError, TimeoutError, ValueError, OSError) as e:
            last = e
            if attempt < retries:
                time.sleep(backoff * (attempt + 1))
    raise FeedError(f"{url}: {last}")


def load_watchlist(path):
    with open(path) as f:
        w = json.load(f)
    if w.get("schema") != 1:
        raise ValueError("watchlist schema must be 1")
    ecos = {}
    for e in w["ecosystems"]:
        key = e["ecosystem"]
        if key in ecos or not e.get("sources") or len(set(e["sources"])) != len(e["sources"]):
            raise ValueError(f"bad ecosystem declaration {key}")
        for o in e.get("osv", []):
            if f"osv:{o}" not in e["sources"]:
                raise ValueError(f"{key}: OSV ecosystem {o} is not a declared source")
        ecos[key] = e
    ids = w["identities"]
    if len(ids) > 64:
        raise ValueError("more than 64 identities")
    seen = set()
    for i in ids:
        if i.get("kind") != "deb":
            raise ValueError("only deb identities are supported by this fetcher")
        for f in ("distro", "release", "source"):
            if not isinstance(i.get(f), str) or not NAME_RE.match(i[f]):
                raise ValueError(f"identity field {f} invalid: {i}")
        key = f"deb:{i['distro']}:{i['release']}:{i['source']}"
        eco = f"deb:{i['distro']}:{i['release']}"
        if key in seen or eco not in ecos:
            raise ValueError(f"duplicate or undeclared identity {key}")
        seen.add(key)
    return ecos, ids


RFC3339_RE = re.compile(
    r"([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,9})?"
    r"(?:([Zz])|([+-])([0-9]{2}):([0-9]{2}))", re.ASCII)


def withdrawn_valid(v):
    """True for absent/null or a complete, real RFC 3339 date-time (§5.6):
    ASCII digits only, a real calendar date and clock time, and an offset
    of Z or ±HH:MM with HH ≤ 23 and MM ≤ 59. Everything else is not
    withdrawal evidence (R3-R2, R4-R2)."""
    if v is None:
        return True
    if type(v) is not str:
        return False
    m = RFC3339_RE.fullmatch(v)
    if not m:
        return False
    y, mo, d, h, mi, sec = (int(m.group(i)) for i in range(1, 7))
    try:
        datetime.datetime(y, mo, d, h, mi, sec)
    except ValueError:
        return False
    if m.group(8) is None and (int(m.group(10)) > 23 or int(m.group(11)) > 59):
        return False
    return True


def slim(record, package, ecosystem):
    """Only what the publisher needs; affected entries for exactly this
    package and ecosystem. A record OSV returned for this package that is
    malformed or does not name it is an incomplete source (R2), never an
    empty result; a withdrawn one may name nothing."""
    # R3-R2: `withdrawn` is an RFC 3339 timestamp or absent (OSV schema);
    # anything else is not withdrawal evidence and fails the source.
    if not withdrawn_valid(record.get("withdrawn")):
        raise FeedError(f"{record.get('id')}: withdrawn is not an RFC 3339 timestamp")
    aff = record.get("affected")
    if not isinstance(aff, list):
        raise FeedError(f"{record.get('id')}: affected is missing or not a list")
    kept = []
    for a in aff:
        if not isinstance(a, dict):
            raise FeedError(f"{record.get('id')}: affected entry is not an object")
        p = a.get("package")
        if not isinstance(p, dict) or not isinstance(p.get("name"), str) or not isinstance(p.get("ecosystem"), str):
            raise FeedError(f"{record.get('id')}: affected package is malformed")
        if p["name"] == package and p["ecosystem"] == ecosystem:
            kept.append({k: a.get(k) for k in ("ranges", "versions", "ecosystem_specific", "database_specific") if k in a}
                        | {"purl": p.get("purl")})
    if not kept and record.get("withdrawn") is None:
        raise FeedError(f"{record.get('id')}: returned for {package} ({ecosystem}) but names no such affected entry")
    out = {k: record.get(k) for k in ("id", "aliases", "upstream", "withdrawn", "modified", "published", "severity",
                                       "database_specific") if k in record}
    out["affected"] = kept
    return out


def osv_package(api, package, ecosystem):
    records, token, pages = [], None, 0
    while True:
        body = {"package": {"name": package, "ecosystem": ecosystem}}
        if token:
            body["page_token"] = token
        resp = http_json(f"{api}/v1/query", body)
        if not isinstance(resp, dict):
            raise FeedError("OSV response is not an object")
        vulns = resp.get("vulns", [])
        if not isinstance(vulns, list):
            raise FeedError("OSV vulns is not a list")
        for v in vulns:
            if not isinstance(v, dict) or not isinstance(v.get("id"), str):
                raise FeedError("OSV record without an id")
            records.append(slim(v, package, ecosystem))
        token = resp.get("next_page_token")
        pages += 1
        if not token:
            return records
        if pages >= MAX_PAGES or len(records) > MAX_RECORDS:
            raise FeedError(f"more than {MAX_PAGES} pages / {MAX_RECORDS} records (incomplete)")


def kev(url):
    data = http_json(url)
    vulns = data.get("vulnerabilities") if isinstance(data, dict) else None
    if not isinstance(vulns, list) or not vulns:
        raise FeedError("KEV feed has no vulnerabilities list")
    out = {}
    for v in vulns:
        cve, added = v.get("cveID"), v.get("dateAdded")
        if isinstance(cve, str) and re.match(r"^CVE-\d{4}-\d{4,}$", cve):
            out[cve] = added if isinstance(added, str) and len(added) <= 32 else None
    return out


def run(args):
    ecos, ids = load_watchlist(args.watchlist)
    bundle = {"schema": 1, "fetchedAt": now_iso(), "sources": {}, "results": []}
    try:
        k = kev(args.kev_url)
        bundle["sources"]["cisa-kev"] = {"status": "ok", "checkedAt": now_iso(), "cves": k}
    except FeedError as e:
        bundle["sources"]["cisa-kev"] = {"status": "failed", "problem": str(e)[:300]}
    for i in ids:
        eco = ecos[f"deb:{i['distro']}:{i['release']}"]
        for o in eco.get("osv", []):
            row = {"identity": i, "source": f"osv:{o}"}
            try:
                row["records"] = osv_package(args.osv_api, i["source"], o)
                row["status"] = "ok"
                row["checkedAt"] = now_iso()
            except FeedError as e:
                row["status"] = "failed"
                row["problem"] = str(e)[:300]
            bundle["results"].append(row)
            print(f"  {row['source']} {i['source']}: {row['status']} ({len(row.get('records', []))} records)")
    data = json.dumps(bundle, separators=(",", ":"), sort_keys=True)
    if len(data) > MAX_BUNDLE:
        raise ValueError(f"bundle is {len(data)} bytes (limit {MAX_BUNDLE})")
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "advisory-input.json"), "w") as f:
        f.write(data)
    failed = sum(1 for r in bundle["results"] if r["status"] != "ok")
    print(f"advisory fetch: {len(bundle['results'])} rows, {failed} failed, KEV {bundle['sources']['cisa-kev']['status']}")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--out", required=True)
    p.add_argument("--watchlist", default=DEFAULT_WATCHLIST)
    p.add_argument("--osv-api", default=OSV_API)
    p.add_argument("--kev-url", default=KEV_URL)
    args = p.parse_args(argv)
    try:
        return run(args)
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"✖ {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
