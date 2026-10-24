#!/usr/bin/env python3
"""Tests for the LibreOffice advisories (scripts/advisory_libreoffice.py,
security plan v19 §9.5.10.2, §15 item 20a): the strict CNA adapter, the
vendor-page cross-check, the platform disposition (R18-1) and the frozen
2026-10-24 census. No network. Deliberate breaks must each fail a test.

Usage: advisory_libreoffice_test.py
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import urllib.error

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "advisory_libreoffice.py")
FIX = os.path.join(HERE, "fixtures", "libreoffice-advisories")
PLATFORMS = os.path.join(os.path.dirname(HERE), "security", "libreoffice-platforms.json")
passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"✔ {label}")
    else:
        failed += 1
        print(f"✖ {label}" + (f" — {str(detail)[:300]}" if detail else ""))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


def rec(versions, default="unknown", assigner="Document Fdn.", desc="A heap buffer overflow existed.", platforms=None):
    a = {"vendor": "The Document Foundation", "product": "LibreOffice", "defaultStatus": default, "versions": versions}
    if platforms is not None:
        a["platforms"] = platforms
    return {"assigner": assigner, "state": "PUBLISHED", "affected": [a], "description": desc}


def v(series, bound, vt=None):
    return {"status": "affected", "version": series, "lessThan": bound, "versionType": vt or f"{series} series"}


def cur(m, cve, desc, platforms=("all",)):
    return {"schema": 1, "absentRecords": [], "entries": {cve: {"platforms": list(platforms), "evidence": "x",
            "descriptionSha256": m.description_sha(desc), "reviewedBy": "test", "reviewedAt": "2026-10-24"}}}


def run_tests(m, only=None):
    res = {}

    def t(name, fn):
        if only and name not in only:
            return
        try:
            ok, detail = fn()
        except Exception as e:      # noqa: BLE001
            ok, detail = False, repr(e)
        res[name] = bool(ok)
        if not only:
            check(name, ok, detail)

    D = "A heap buffer overflow existed."

    def series_record():
        a = m.convert("CVE-2099-0001", rec([v("26.2", "< 26.2.5")]), ["26.2.5", "26.8.0"], cur(m, "CVE-2099-0001", D))
        return (a["affected"] == {"ranges": [{"type": "ECOSYSTEM", "events": [{"introduced": "26.2.0"}, {"fixed": "26.2.5"}]}]}
                and a["remediation"]["fixed"] == [{"line": "26.2", "version": "26.2.5"}] and a.get("unknownOutside") is True), a
    t("adapter: a 26.2 series record → range, N.N remediation line, unknownOutside", series_record)

    def unaffected_default():
        a = m.convert("CVE-2099-0002", rec([v("24.8", "24.8.4", "custom")], default="unaffected"), ["24.8.4"], cur(m, "CVE-2099-0002", D))
        return a["affected"] != "unknown" and "unknownOutside" not in a, a
    t("adapter: defaultStatus unaffected → no unknownOutside; old 'custom' form accepted", unaffected_default)

    def strict_forms():
        bad = [rec([v("26.2", "<= 26.2.5")]), rec([v("26.2", "< 26.3.1")]), rec([v("26.2", "< 26.2.5", "26 series")]),
               rec([{"status": "affected", "version": "26.2", "lessThan": "< 26.2.5", "versionType": "26.2 series", "changes": []}]),
               rec([{"status": "affected", "version": "26.2", "lessThanOrEqual": "26.2.5", "versionType": "26.2 series"}]),
               rec([v("26.2", "< 26.2.5")], default="affected"), rec([]), rec([{"status": "unaffected", "version": "26.2", "lessThan": "< 26.2.5", "versionType": "26.2 series"}]),
               rec([v("unspecified", "6.2.5", "custom")])]
        got = [m.convert("CVE-2099-0003", r, ["26.2.5", "6.2.5"], cur(m, "CVE-2099-0003", D))["affected"] for r in bad]
        return all(x == "unknown" for x in got), got
    t("adapter: changed bound syntax, series mismatch, extra fields, other defaults, empty → unknown", strict_forms)

    def page_disagrees():
        a = m.convert("CVE-2099-0004", rec([v("25.8", "< 25.8.7"), v("26.2", "< 26.2.4")]), ["26.2.4"], cur(m, "CVE-2099-0004", D))
        return a["affected"] == "unknown", a
    t("adapter: a bound absent from the vendor page's Fixed-in versions → unknown (never another branch's fix)", page_disagrees)

    def non_tdf():
        return m.convert("CVE-2099-0005", rec([v("26.2", "< 26.2.5")], assigner="mitre"), ["26.2.5"], cur(m, "CVE-2099-0005", D)) is None, None
    t("adapter: non-TDF records are ignored", non_tdf)

    def platform_windows():
        r = rec([v("24.8", "< 24.8.5")], default="unaffected", desc="Windows only.")
        a = m.convert("CVE-2099-0006", r, ["24.8.5"], cur(m, "CVE-2099-0006", "Windows only.", ("windows",)))
        s = m.convert("CVE-2099-0007", rec([v("24.8", "< 24.8.5")], platforms=["Windows"]), ["24.8.5"], None)
        return a is None and s is None, (a, s)
    t("platform: curated windows-only and structured Windows records are not published for macOS", platform_windows)

    def platform_mac():
        s = m.convert("CVE-2099-0008", rec([v("25.2", "< 25.2.4")], platforms=["MacOS"]), ["25.2.4"], None)
        c = m.convert("CVE-2099-0009", rec([v("26.2", "< 26.2.5")]), ["26.2.5"], cur(m, "CVE-2099-0009", D, ("windows", "macos")))
        return s and s["affected"] != "unknown" and c and c["affected"] != "unknown", (s, c)
    t("platform: structured MacOS and curated macos records are macOS positives", platform_mac)

    def platform_unresolved():
        none = m.convert("CVE-2099-0010", rec([v("26.2", "< 26.2.5")]), ["26.2.5"], {"schema": 1, "entries": {}, "absentRecords": []})
        changed = m.convert("CVE-2099-0011", rec([v("26.2", "< 26.2.5")], desc="Edited text."), ["26.2.5"], cur(m, "CVE-2099-0011", D))
        conflict = m.convert("CVE-2099-0012", rec([v("26.2", "< 26.2.5")], platforms=["Linux"]), ["26.2.5"], cur(m, "CVE-2099-0012", D, ("all",)))
        return none["affected"] == "unknown" and changed["affected"] == "unknown" and conflict["affected"] == "unknown", (none, changed, conflict)
    t("platform: no entry, a changed description, structured vs curated conflict → unknown", platform_unresolved)

    def platform_labels():
        out = []
        for labels in ([], ["*"], ["BeOS"], [1], ["x64"], ["Unix"], ["macOS", "BeOS"], ["Windows", "*"]):
            r = rec([v("26.2", "< 26.2.5")], platforms=labels)
            out.append(m.convert("CVE-2099-0016", r, ["26.2.5"], {"schema": 1, "entries": {}, "absentRecords": []})["affected"])
        archonly = m.convert("CVE-2099-0017", rec([v("26.2", "< 26.2.5")], platforms=["x64"]), ["26.2.5"], cur(m, "CVE-2099-0017", D))
        # x64 alone is no evidence and there is no curation entry → unknown too.
        return out == ["unknown"] * 8 and archonly["affected"] != "unknown", (out, archonly)
    t("platform: empty, wildcard, unfamiliar, malformed labels → unknown; arch-only labels are no evidence", platform_labels)

    def per_entry():
        r = {"assigner": "Document Fdn.", "state": "PUBLISHED", "description": D, "affected": [
            {"product": "LibreOffice", "defaultStatus": "unaffected", "platforms": ["Windows"], "versions": [v("25.8", "< 25.8.7")]},
            {"product": "LibreOffice", "defaultStatus": "unaffected", "platforms": ["macOS"], "versions": [v("26.2", "< 26.2.4")]}]}
        a = m.convert("CVE-2099-0018", r, ["25.8.7", "26.2.4"], None)
        return a and a["affected"] == {"ranges": [{"type": "ECOSYSTEM", "events": [{"introduced": "26.2.0"}, {"fixed": "26.2.4"}]}]}, a
    t("platform: per affected entry — a Windows entry's range is never applied to macOS", per_entry)

    def frozen_census():
        recs = json.load(open(os.path.join(FIX, "records.json")))
        page = open(os.path.join(FIX, "page.html"), "rb").read()

        def get(url, limit):
            if "libreoffice.org" in url:
                return page
            cve = url.rsplit("/", 1)[1][:-5]
            if cve not in recs:
                raise urllib.error.HTTPError(url, 404, "not found", None, None)
            return json.dumps(recs[cve]).encode()
        src = m.fetch_all("2026-10-24T00:00:00Z", get=get, platforms_path=PLATFORMS)
        advs, st = m.libreoffice_identity(src, {}, m.load_platforms(PLATFORMS))
        ids = {a["ids"][0]: a for a in advs}
        ok = (len(src["tdf-advisories"]["data"]["ids"]) == 110 and len(src["cve-cna"]["data"]) == 109
              and st == {"tdf-advisories": ("ok", "2026-10-24T00:00:00Z"), "cve-cna": ("ok", "2026-10-24T00:00:00Z")}
              and "CVE-2025-0514" not in ids and "CVE-2026-63269" not in ids and "CVE-2021-25631" not in ids
              and ids["CVE-2025-14714"]["affected"] != "unknown" and ids["CVE-2026-63279"]["affected"] != "unknown"
              and ids["CVE-2023-6185"]["affected"] == "unknown" and ids["CVE-2024-5261"]["affected"] == "unknown"
              and ids["CVE-2026-4430"]["affected"] == "unknown" and ids["CVE-2026-8358"]["affected"] == "unknown"
              and ids["CVE-2021-25632"]["affected"] == "unknown")
        return ok, (len(advs), st)
    t("census (frozen 2026-10-24): 110 IDs, 109 records, Windows/Linux-only excluded, unresolved unknown", frozen_census)

    def missing_record():
        recs = json.load(open(os.path.join(FIX, "records.json")))
        page = open(os.path.join(FIX, "page.html"), "rb").read()

        def get(url, limit):
            if "libreoffice.org" in url:
                return page
            cve = url.rsplit("/", 1)[1][:-5]
            if cve in ("CVE-2021-25632", "CVE-2026-63279"):
                raise urllib.error.HTTPError(url, 404, "not found", None, None)
            return json.dumps(recs[cve]).encode()
        src = m.fetch_all("2026-10-24T00:00:00Z", get=get, platforms_path=PLATFORMS)
        return src["cve-cna"]["status"] == "failed", src["cve-cna"]
    t("fetch: a missing record outside absentRecords fails cve-cna", missing_record)

    def wrong_identity():
        def get(url, limit):
            if "libreoffice.org" in url:
                return b"<h3>CVE-2099-0013 x</h3> Fixed in : LibreOffice 26.2.5"
            return json.dumps({"dataType": "CVE_RECORD", "cveMetadata": {"cveId": "CVE-2099-9999"}, "containers": {"cna": {}}}).encode()
        src = m.fetch_all("x", get=get, platforms_path=PLATFORMS)
        return src["cve-cna"]["status"] == "failed", src["cve-cna"]
    t("fetch: a record for another CVE ID fails cve-cna", wrong_identity)

    def empty_page():
        src = m.fetch_all("x", get=lambda url, limit: b"<html>maintenance</html>", platforms_path=PLATFORMS)
        return src["tdf-advisories"]["status"] == "failed" and src["cve-cna"]["status"] == "failed", src
    t("fetch: a page with no recognisable CVE is a failure, not 'no advisories'", empty_page)

    def kev_mark():
        a, _ = m.libreoffice_identity({"tdf-advisories": {"status": "ok", "checkedAt": "t", "data": {"ids": ["CVE-2099-0014"], "fixed": {"CVE-2099-0014": ["26.2.5"]}}},
                                       "cve-cna": {"status": "ok", "checkedAt": "t", "data": {"CVE-2099-0014": rec([v("26.2", "< 26.2.5")])}}},
                                      {"CVE-2099-0014": "2026-10-01"}, cur(m, "CVE-2099-0014", D))
        return a and a[0]["kev"] and a[0]["severity"] == "critical", a
    t("convert: KEV marks the advisory critical", kev_mark)

    def curation_validation():
        bad = 0
        for d in ({"schema": 2, "entries": {}, "absentRecords": []},
                  {"schema": 1, "entries": {"CVE-2099-1": {"platforms": ["mac"], "evidence": "x", "descriptionSha256": "0" * 64, "reviewedBy": "a", "reviewedAt": "b"}}, "absentRecords": []},
                  {"schema": 1, "entries": {"CVE-2099-0015": {"platforms": ["all"], "evidence": "", "descriptionSha256": "0" * 64, "reviewedBy": "a", "reviewedAt": "b"}}, "absentRecords": []}):
            p = tempfile.mktemp(suffix=".json")
            json.dump(d, open(p, "w"))
            try:
                m.load_platforms(p)
            except ValueError:
                bad += 1
            os.unlink(p)
        return bad == 3, bad
    t("curation: malformed files are refused", curation_validation)
    return res


BREAKS = [
    ("adapter: a 26.2 series record → range, N.N remediation line, unknownOutside", '            unknown_outside = True', '            pass'),
    ("adapter: changed bound syntax, series mismatch, extra fields, other defaults, empty → unknown", '            if vt not in (f"{series} series", "custom"):', '            if False:'),
    ("adapter: changed bound syntax, series mismatch, extra fields, other defaults, empty → unknown", '        elif ds != "unaffected":', '        elif False:'),
    ("adapter: a bound absent from the vendor page's Fixed-in versions → unknown (never another branch's fix)", "            if bound not in page:", "            if False:"),
    ("adapter: non-TDF records are ignored", 'rec.get("assigner") != TDF or ', ''),
    ("platform: curated windows-only and structured Windows records are not published for macOS", "    if all(d is False for d in dispositions):", "    if False:"),
    ("platform: no entry, a changed description, structured vs curated conflict → unknown", '    if not entry or not desc or entry["descriptionSha256"] != description_sha(desc):', '    if not entry:'),
    ("platform: empty, wildcard, unfamiliar, malformed labels → unknown; arch-only labels are no evidence", '    if "unknown" in kinds:', '    if False:'),
    ("platform: per affected entry — a Windows entry's range is never applied to macOS", "        if disp is False:\n            continue", "        if False:\n            continue"),
    ("platform: no entry, a changed description, structured vs curated conflict → unknown", "        return None                          # structured and curated evidence disagree", "        pass"),
    ("fetch: a missing record outside absentRecords fails cve-cna", "                if e.code == 404 and cve in absent:", "                if e.code == 404:"),
    ("fetch: a record for another CVE ID fails cve-cna", '            if meta.get("cveId") != cve:', '            if False:'),
    ("fetch: a page with no recognisable CVE is a failure, not 'no advisories'", '        raise LOFeedError("the advisory page lists no CVE")', '        pass'),
    ("census (frozen 2026-10-24): 110 IDs, 109 records, Windows/Linux-only excluded, unresolved unknown", "        for cve in sorted(absent & set(page[\"ids\"])):", "        for cve in []:"),
    ("convert: KEV marks the advisory critical", '                a["kev"], a["kevAdded"], a["severity"] = True, kev.get(cve), "critical"', '                pass'),
    ("curation: malformed files are refused", '            raise ValueError(f"{cve}: {k} required")', '            pass'),
]


def main():
    run_tests(load(SRC, "advisory_libreoffice_real"))
    tmp = tempfile.mkdtemp(prefix="advisory-lo-test-")
    caught = 0
    try:
        src = open(SRC).read()
        for i, (name, old, new) in enumerate(BREAKS):
            if old not in src:
                check(f"break anchor present: {name}", False, old)
                continue
            p = os.path.join(tmp, f"advisory_libreoffice_b{i}.py")
            open(p, "w").write(src.replace(old, new, 1))
            try:
                ok = run_tests(load(p, f"advisory_libreoffice_b{i}"), only={name}).get(name) is False
            except Exception:       # noqa: BLE001
                ok = True
            caught += ok
            check(f"deliberate break caught: {name}", ok)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{passed} passed, {failed} failed ({caught}/{len(BREAKS)} deliberate breaks caught)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
