#!/usr/bin/env python3
"""LibreOffice (macOS website build) advisories for the local-tools list
(security plan v18 §9.5.10.2). Parsers only, nothing from a feed executes.

* fetch (watch job, no secrets): the vendor advisory page — only CVE IDs and,
  per ID, the "Fixed in" line's N.N.N versions — and the CVE JSON 5 record of
  every listed ID from cvelistV5;
* convert (publisher): only records assigned by The Document Foundation
  (the LibreOffice CNA), product LibreOffice, through a strict adapter:
  each affected item `status: affected`, `version` N.N, `lessThan` "< N.N.P"
  or "N.N.P" with the same N.N, `versionType` exactly "N.N series" or
  "custom", and every `lessThan` version present in the vendor page's
  "Fixed in" versions for that CVE. Anything else → `affected: unknown`.
  `defaultStatus: unknown` (or absent) → `unknownOutside: true` (an unlisted
  series is unknown for that advisory, never "not affected").
"""
import hashlib
import html
import json
import os
import re
import urllib.error
import urllib.request

PAGE_URL = "https://www.libreoffice.org/about-us/security/advisories/"
RECORD_URL = "https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/{year}/{bucket}/{id}.json"
SOURCES = ("tdf-advisories", "cve-cna")
MAX_PAGE = 4 * 1024 * 1024
MAX_RECORD = 1024 * 1024
MAX_IDS = 400
CVE_RE = re.compile(r"CVE-(\d{4})-(\d{4,7})", re.ASCII)
TDF = "Document Fdn."
DEFAULT_PLATFORMS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "security", "libreoffice-platforms.json")
MAC_SPELLINGS = ("macos", "mac os", "os x", "osx")
NON_MAC = ("windows", "linux")
ARCH_ONLY = ("x86", "x64", "arm", "arm64", "x86_64", "aarch64")
MAX_CURATION = 256


def description(cna):
    """The record's English CNA description, joined exactly as hashed."""
    out = []
    for d in (cna or {}).get("descriptions") or []:
        if type(d) is dict and type(d.get("lang")) is str and d["lang"].lower().startswith("en") and type(d.get("value")) is str:
            out.append(d["value"])
    return "\n".join(out)


def description_sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_platforms(path=DEFAULT_PLATFORMS):
    """The reviewed platform curation (§9.5.10.2 "Platform disposition")."""
    with open(path) as f:
        d = json.load(f)
    if d.get("schema") != 1 or type(d.get("entries")) is not dict or type(d.get("absentRecords")) is not list:
        raise ValueError("libreoffice-platforms.json: schema 1 with entries and absentRecords required")
    if len(d["entries"]) > MAX_CURATION or len(d["absentRecords"]) > 32:
        raise ValueError("libreoffice-platforms.json: too many entries")
    if len({a.get("id") for a in d["absentRecords"] if type(a) is dict}) != len(d["absentRecords"]):
        raise ValueError("absentRecords IDs must be unique")
    for cve, e in d["entries"].items():
        if not CVE_RE.fullmatch(cve) or type(e) is not dict:
            raise ValueError(f"bad curation entry {cve}")
        pl = e.get("platforms")
        if type(pl) is not list or not pl or any(type(x) is not str or x not in ("all", "macos", "windows", "linux") for x in pl):
            raise ValueError(f"{cve}: platforms must be a non-empty subset of all|macos|windows|linux")
        if type(e.get("descriptionSha256")) is not str or not re.fullmatch(r"[0-9a-f]{64}", e["descriptionSha256"]):
            raise ValueError(f"{cve}: descriptionSha256")
        for k in ("evidence", "reviewedBy", "reviewedAt"):
            if type(e.get(k)) is not str or not e[k]:
                raise ValueError(f"{cve}: {k} required")
    for a in d["absentRecords"]:
        if type(a) is not dict or not CVE_RE.fullmatch(str(a.get("id"))) or not a.get("evidence"):
            raise ValueError("absentRecords entries need id and evidence")
    return d


def structured_platforms(entry):
    """One affected entry's structured platforms → True (admits macOS),
    False (positively excludes it), None (absent: no structured evidence),
    or "unknown" (empty, wildcard, unfamiliar or malformed labels)."""
    if "platforms" not in entry or entry["platforms"] is None:
        return None
    pl = entry["platforms"]
    if type(pl) is not list or not pl or any(type(x) is not str for x in pl):
        return "unknown"
    labels = [x.strip().lower() for x in pl]
    kinds = ["mac" if x in MAC_SPELLINGS else "non" if x in NON_MAC else "arch" if x in ARCH_ONLY else "unknown" for x in labels]
    if "unknown" in kinds:
        return "unknown"                     # one unfamiliar label taints the whole entry
    if "mac" in kinds:
        return True
    if "non" in kinds:
        return False
    return None                              # architecture only: no platform evidence


def curated_disposition(cve, rec, curation):
    entry = (curation or {}).get("entries", {}).get(cve)
    desc = rec.get("description") or ""
    if not entry or not desc or entry["descriptionSha256"] != description_sha(desc):
        return None                          # missing, or the reviewed text changed: unresolved
    return "all" in entry["platforms"] or "macos" in entry["platforms"]


def mac_disposition(cve, rec, curation, entry=None):
    """For one affected entry (or the whole record): True = macOS applies;
    False = positively not macOS; None = unresolved. Conflicts override."""
    structured = structured_platforms(entry) if entry is not None else None
    curated = curated_disposition(cve, rec, curation)
    if structured == "unknown":
        return None
    if structured is not None and curated is not None and structured != curated:
        return None                          # structured and curated evidence disagree
    return structured if structured is not None else curated


def _get(url, limit, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "briglia-security-watch (libreoffice advisories)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read(limit + 1)
    if len(raw) > limit:
        raise LOFeedError(f"{url}: larger than {limit} bytes")
    return raw


def record_url(cve):
    m = CVE_RE.fullmatch(cve)
    if not m:
        raise LOFeedError(f"not a CVE ID: {cve!r}")
    num = m.group(2)
    return RECORD_URL.format(year=m.group(1), bucket=num[:-3] + "xxx", id=cve)


def parse_page(raw):
    """→ {cve: [fixed N.N.N, …]} for every CVE heading with a "Fixed in"
    line, and the set of every CVE ID on the page."""
    text = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
    text = html.unescape(re.sub(r"<[^>]+>", "\n", text))
    text = re.sub(r"[ \t\xa0]+", " ", text)
    every = set(m.group(0) for m in CVE_RE.finditer(text))
    if not every:
        raise LOFeedError("the advisory page lists no CVE")
    fixed = {}
    for block in re.split(r"\n\s*(?=CVE-\d{4}-\d{4,7}\b)", text)[1:]:
        m = CVE_RE.match(block)
        f = re.search(r"Fixed in\s*\n?\s*:\s*([^\n]+)", block)
        if m and f and m.group(0) not in fixed:
            fixed[m.group(0)] = sorted(set(re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\b", f.group(1))))
    return fixed, every


def fetch_all(now_iso, get=_get, platforms_path=DEFAULT_PLATFORMS):
    out = {}
    try:
        fixed, every = parse_page(get(PAGE_URL, MAX_PAGE))
        if len(every) > MAX_IDS:
            raise LOFeedError("too many CVE IDs on the page")
        out["tdf-advisories"] = {"status": "ok", "checkedAt": now_iso, "data": {"fixed": fixed, "ids": sorted(every)}}
    except Exception as e:      # noqa: BLE001
        out["tdf-advisories"] = {"status": "failed", "problem": str(e)[:300]}
        out["cve-cna"] = {"status": "failed", "problem": "advisory page unavailable"}
        return out
    records = {}
    try:
        absent = {a["id"] for a in load_platforms(platforms_path)["absentRecords"]}
        for cve in out["tdf-advisories"]["data"]["ids"]:
            try:
                raw = get(record_url(cve), MAX_RECORD)
            except urllib.error.HTTPError as e:
                if e.code == 404 and cve in absent:
                    continue                 # reviewed: named on the page, no CVE record exists
                raise
            d = json.loads(raw)
            if type(d) is not dict or d.get("dataType") != "CVE_RECORD" or type(d.get("containers")) is not dict:
                raise LOFeedError(f"{cve}: not a CVE JSON 5 record")
            meta = d.get("cveMetadata") or {}
            cna = d["containers"].get("cna") or {}
            if meta.get("cveId") != cve:
                raise LOFeedError(f"{cve}: the record is for {meta.get('cveId')!r}")
            records[cve] = {"assigner": meta.get("assignerShortName"), "state": meta.get("state"),
                            "affected": cna.get("affected"), "description": description(cna)}
        out["cve-cna"] = {"status": "ok", "checkedAt": now_iso, "data": records}
    except Exception as e:      # noqa: BLE001 — one missing record makes the source incomplete
        out["cve-cna"] = {"status": "failed", "problem": str(e)[:300]}
    return out


SERIES_RE = re.compile(r"(\d{1,3})\.(\d{1,3})", re.ASCII)
BOUND_RE = re.compile(r"(?:<\s*)?(\d{1,3})\.(\d{1,3})\.(\d{1,3})", re.ASCII)


def convert(cve, rec, fixed_on_page, curation=None):
    """→ advisory dict, or None when the record is not a TDF LibreOffice
    record (other CNAs, other products, rejected records)."""
    if type(rec) is not dict or rec.get("assigner") != TDF or rec.get("state") != "PUBLISHED":
        return None
    entries = [a for a in (rec.get("affected") or []) if type(a) is dict and a.get("product") == "LibreOffice"]
    if not entries:
        return None
    adv = {"ids": [cve], "severity": "recommended", "kev": False, "kevAdded": None, "withdrawn": False}
    dispositions = [mac_disposition(cve, rec, curation, a) for a in entries]
    if all(d is False for d in dispositions):
        return None                          # positively not macOS: not published for darwin
    mac = None if any(d is None for d in dispositions) else True
    ranges, fixed, unknown_outside, ok = [], [], False, True
    page = set(fixed_on_page or [])
    for a, disp in zip(entries, dispositions):
        if disp is False:
            continue                         # this entry's ranges are for another platform
        ds = a.get("defaultStatus")
        if ds in (None, "unknown"):
            unknown_outside = True
        elif ds != "unaffected":
            ok = False
        versions = a.get("versions")
        if type(versions) is not list or not versions:
            ok = False
            continue
        for v in versions:
            if type(v) is not dict or v.get("status") != "affected" or set(v) - {"status", "version", "lessThan", "versionType"} \
                    or "lessThan" not in v:
                ok = False; continue
            sm = SERIES_RE.fullmatch(str(v.get("version", "")))
            bm = BOUND_RE.fullmatch(str(v.get("lessThan", "")).strip())
            vt = v.get("versionType")
            if not sm or not bm or (bm.group(1), bm.group(2)) != sm.groups():
                ok = False; continue
            series = f"{sm.group(1)}.{sm.group(2)}"
            if vt not in (f"{series} series", "custom"):
                ok = False; continue
            bound = f"{bm.group(1)}.{bm.group(2)}.{bm.group(3)}"
            if bound not in page:
                ok = False; continue          # vendor page disagrees: never guess
            ranges.append({"type": "ECOSYSTEM", "events": [{"introduced": f"{series}.0"}, {"fixed": bound}]})
            fixed.append({"line": series, "version": bound})
    if mac is None or not ok or not ranges or len(ranges) > 16:
        adv.update({"affected": "unknown", "remediation": None, "noFixReason": "unknown"})
        return adv
    adv["affected"] = {"ranges": ranges}
    adv["remediation"] = {"fixed": fixed, "pocket": None}
    adv["noFixReason"] = None
    if unknown_outside:
        adv["unknownOutside"] = True
    return adv


def libreoffice_identity(sources, kev, curation=None):
    """→ (advisories, statuses {source: (status, checkedAt)})."""
    statuses = {}
    for s in SOURCES:
        src = sources.get(s) or {}
        statuses[s] = ("ok", src.get("checkedAt")) if src.get("status") == "ok" else ("failed", None)
    if any(st[0] != "ok" for st in statuses.values()):
        return [], statuses
    try:
        page = sources["tdf-advisories"]["data"]
        recs = sources["cve-cna"]["data"]
        absent = {a["id"] for a in (curation or {}).get("absentRecords", [])}
        if set(recs) | (absent & set(page["ids"])) != set(page["ids"]) or not set(recs) <= set(page["ids"]):
            raise LOFeedError("records do not match the page's IDs")
        advs = []
        # A reviewed absent record (named by the vendor, no CVE record) is
        # never dropped: it stays an unknown advisory, so it can never be read
        # as "not affected".
        for cve in sorted(absent & set(page["ids"])):
            y, n = CVE_RE.fullmatch(cve).groups()
            advs.append({"ids": [cve], "severity": "recommended", "kev": cve in kev, "kevAdded": kev.get(cve),
                         "withdrawn": False, "affected": "unknown", "remediation": None, "noFixReason": "unknown",
                         "_order": (0 if cve in kev else 1, 1, -(int(y) * 10 ** 7 + int(n))), "_source": "cve-cna"})
        for cve in sorted(recs):
            a = convert(cve, recs[cve], page["fixed"].get(cve), curation)
            if a is None:
                continue
            if cve in kev:
                a["kev"], a["kevAdded"], a["severity"] = True, kev.get(cve), "critical"
            y, n = CVE_RE.fullmatch(cve).groups()
            a["_order"] = (0 if a["kev"] else 1, 1, -(int(y) * 10 ** 7 + int(n)))
            a["_source"] = "cve-cna"
            advs.append(a)
        return advs, statuses
    except (LOFeedError, KeyError, TypeError, AttributeError):
        return [], {s: ("failed", None) for s in SOURCES}
