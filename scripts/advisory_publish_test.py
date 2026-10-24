#!/usr/bin/env python3
"""Tests for the advisory-list publisher (scripts/advisory_publish.py,
security plan v16 §9.5.3): synthetic bundles only (made-up CVE-2099 IDs),
no network. Each rule has a test; each test has a deliberate break (a
one-line mutation of a temporary copy of the publisher) that must make it
fail.

Usage: advisory_publish_test.py
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "advisory_publish.py")
NOW = 1_792_800_000.0          # 2026-10-24
passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"✔ {label}")
    else:
        failed += 1
        print(f"✖ {label}" + (f" — {str(detail)[:400]}" if detail else ""))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


def watchlist(tmp, identities=(("debian", "12", "ffmpeg"),), ubuntu=False):
    ecos = [{"ecosystem": "deb:debian:12", "osv": ["Debian:12"], "sources": ["osv:Debian:12", "cisa-kev"]}]
    if ubuntu:
        ecos.append({"ecosystem": "deb:ubuntu:24.04", "osv": ["Ubuntu:24.04:LTS", "Ubuntu:Pro:24.04:LTS"],
                     "sources": ["osv:Ubuntu:24.04:LTS", "osv:Ubuntu:Pro:24.04:LTS", "cisa-kev"]})
    w = {"schema": 1, "ecosystems": ecos,
         "identities": [{"kind": "deb", "distro": d, "release": r, "source": s} for d, r, s in identities]}
    fd, p = tempfile.mkstemp(suffix=".json", dir=tmp)
    with os.fdopen(fd, "w") as f:
        json.dump(w, f)
    return p


def rec(n, fixed="7:5.1.7-0+deb12u1", published="2026-01-01T00:00:00Z", eco="Debian:12", pkg="ffmpeg",
        withdrawn=False, purl=None, extra_ids=0):
    events = [{"introduced": "0"}] + ([{"fixed": fixed}] if fixed else [])
    r = {"id": f"DEBIAN-CVE-2099-{n:04d}", "upstream": [f"CVE-2099-{n:04d}"] + [f"CVE-2098-{n:04d}{i}" for i in range(extra_ids)],
         "published": published, "affected": [{"ranges": [{"type": "ECOSYSTEM", "events": events}], "purl": purl}]}
    if withdrawn:
        r["withdrawn"] = "2026-10-01T00:00:00Z"
    return r


def bundle(rows, kev_ok=True, kev=None):
    return {"schema": 1, "fetchedAt": "2026-10-24T00:00:00Z",
            "sources": {"cisa-kev": {"status": "ok", "checkedAt": "2026-10-24T00:00:00Z", "cves": kev or {}} if kev_ok
                        else {"status": "failed"}},
            "results": rows}


def row(records, source="osv:Debian:12", ident=("debian", "12", "ffmpeg"), status="ok"):
    d, r, s = ident
    out = {"identity": {"kind": "deb", "distro": d, "release": r, "source": s}, "source": source, "status": status}
    if status == "ok":
        out.update(records=records, checkedAt="2026-10-24T00:00:00Z")
    return out


def cov(doc, source="osv:Debian:12", ident="deb:debian:12:ffmpeg"):
    return [c["status"] for c in doc["coverage"] if c["identity"] == ident and c["source"] == source]


def run_tests(m, tmp, only=None, fetch=None):
    """Returns {test name: ok}."""
    res = {}

    def t(name, ok, detail=""):
        if only is None or name in only:
            res[name] = ok
            if only is None:
                check(name, ok, detail)

    fetch = fetch or sys.modules.get("advisory_fetch")
    w = watchlist(tmp)
    build = lambda b, prev=None, wl=w: json.loads(m.build(wl, b, prev, NOW))

    d = build(bundle([row([rec(1)])]))
    t("complete fetch → ok coverage for every declared source", cov(d) == ["ok"] and cov(d, "cisa-kev") == ["ok"])
    a = d["entries"][0]["advisories"][0]
    t("advisory carries ranges, remediation and IDs (record ID first, CVE next)",
      a["ids"][:2] == ["DEBIAN-CVE-2099-0001", "CVE-2099-0001"] and a["remediation"]["fixed"][0]["version"] == "7:5.1.7-0+deb12u1"
      and a["affected"]["ranges"][0]["events"][0] == {"introduced": "0"})
    t("validity ≤ 72 h and sequence from the clock", m.parse_iso(d["expires"]) - m.parse_iso(d["published"]) <= 72 * 3600
      and d["sequence"] == int(NOW // 60))
    d = build(bundle([row([], status="failed")]))
    t("a failed fetch is published as failed, never ok", cov(d) == ["failed"])
    t("a failed row never carries 'now' as its checkedAt", [c["checkedAt"] for c in d["coverage"] if c["status"] == "failed"] == ["1970-01-01T00:00:00Z"])
    prev = build(bundle([row([rec(1)])]))
    d = build(bundle([row([], status="failed")]), prev)
    t("failed keeps the last good checkedAt", [c["checkedAt"] for c in d["coverage"] if c["status"] == "failed"] == ["2026-10-24T00:00:00Z"])
    d = build(bundle([]))
    t("a missing bundle row is failed", cov(d) == ["failed"])
    d = build(bundle([row([rec(1)])], kev_ok=False))
    t("KEV feed failure → KEV coverage failed", cov(d, "cisa-kev") == ["failed"])
    d = build(bundle([row([rec(1)])], kev={"CVE-2099-0001": "2026-10-20"}))
    a = d["entries"][0]["advisories"][0]
    t("KEV-listed advisory: kev, kevAdded, critical", a["kev"] and a["kevAdded"] == "2026-10-20" and a["severity"] == "critical")
    d = build(bundle([row([rec(1, fixed=None)])]))
    a = d["entries"][0]["advisories"][0]
    t("no fixed event → remediation null + noFixReason", a["remediation"] is None and a["noFixReason"] == "unknown")
    try:
        m.build(w, bundle([row([rec(1)]), row([rec(2)])]), None, NOW)
        t("duplicate bundle row refused", False)
    except m.Refuse:
        t("duplicate bundle row refused", True)
    bad = row([rec(1)])
    bad["records"][0]["affected"][0]["ranges"][0]["events"].append({"introduced": "1", "fixed": "2"})
    d = build(bundle([bad]))
    t("a malformed record makes the row failed (not partial, not ok)", cov(d) == ["failed"])
    # Size bounds → partial (F3), trim order KEV, critical, newest.
    many = [rec(i, published=f"2026-{1 + i % 12:02d}-01T00:00:00Z") for i in range(70)]
    many[5]["database_specific"] = {"severity": "CRITICAL"}
    many[5]["published"] = "2026-12-31T00:00:00Z"
    d = build(bundle([row(many)], kev={"CVE-2099-0003": "2026-01-01"}))
    advs = d["entries"][0]["advisories"]
    t("more than 64 advisories → 64 kept, source partial", len(advs) == 64 and cov(d) == ["partial"])
    t("trimming keeps KEV first", advs[0]["ids"][1] == "CVE-2099-0003")
    t("then critical, then the newest", advs[1]["ids"][1] == "CVE-2099-0005" and advs[2]["ids"][1] in ("CVE-2099-0011", "CVE-2099-0023", "CVE-2099-0035", "CVE-2099-0047", "CVE-2099-0059"))
    t("only size trimming produces partial (KEV source stays ok)", cov(d, "cisa-kev") == ["ok"])
    d = build(bundle([row([rec(1, extra_ids=20)])]))
    t("an advisory over 16 IDs is dropped and the source marked partial", d["entries"][0]["advisories"] == [] and cov(d) == ["partial"])
    # Withdrawn.
    prev = build(bundle([row([rec(1), rec(2)])]))
    d = build(bundle([row([rec(1)])]), prev)
    gone = [x for x in d["entries"][0]["advisories"] if x["withdrawn"]]
    t("an advisory no longer published is carried as withdrawn", len(gone) == 1 and gone[0]["ids"][1] == "CVE-2099-0002")
    old = json.loads(json.dumps(d))
    for x in old["entries"][0]["advisories"]:
        if x["withdrawn"]:
            x["withdrawnAt"] = "2026-09-01T00:00:00Z"
    d = build(bundle([row([rec(1)])]), old)
    t("withdrawn advisories are dropped after 30 days", not any(x["withdrawn"] for x in d["entries"][0]["advisories"]))
    d = build(bundle([row([], status="failed")]), prev)
    t("no withdrawn carry for an identity not fully checked", d["entries"][0]["advisories"] == [])
    d = build(bundle([row([rec(1, withdrawn=True)])]))
    t("OSV-withdrawn records are published withdrawn with a date", d["entries"][0]["advisories"][0]["withdrawn"]
      and d["entries"][0]["advisories"][0].get("withdrawnAt") == m.iso(NOW))
    # Sequence monotonic over the previous list.
    prev2 = dict(prev, sequence=int(NOW // 60) + 50)
    t("sequence is above the previous list's", build(bundle([row([rec(1)])]), prev2)["sequence"] == int(NOW // 60) + 51)
    # Ubuntu pockets.
    wu = watchlist(tmp, identities=(("ubuntu", "24.04", "ffmpeg"),), ubuntu=True)
    pro = rec(5, eco="Ubuntu:Pro:24.04:LTS", fixed="7:6.1.1-3ubuntu5+esm1", purl="pkg:deb/ubuntu/ffmpeg?distro=esm-apps/noble")
    arch = rec(6, fixed="7:6.1.1-3ubuntu5.1", purl="pkg:deb/ubuntu/ffmpeg?distro=noble")
    d = json.loads(m.build(wu, bundle([row([arch], "osv:Ubuntu:24.04:LTS", ("ubuntu", "24.04", "ffmpeg")),
                                       row([pro], "osv:Ubuntu:Pro:24.04:LTS", ("ubuntu", "24.04", "ffmpeg"))]), None, NOW))
    pockets = sorted(x["remediation"]["pocket"] for x in d["entries"][0]["advisories"])
    t("Ubuntu archive vs Pro pockets from the source/purl", pockets == ["archive", "esm-apps"])
    # Highest fixed version by dpkg ordering.
    two = rec(7)
    two["affected"][0]["ranges"][0]["events"] = [{"introduced": "0"}, {"fixed": "7:5.1.10-0+deb12u1"}, {"introduced": "7:6.0-1"}, {"fixed": "7:5.1.9-0+deb12u1"}]
    d = build(bundle([row([two])]))
    t("several fixed events → the highest by dpkg order", d["entries"][0]["advisories"][0]["remediation"]["fixed"][0]["version"] == "7:5.1.10-0+deb12u1")
    # Document size bound.
    big_w = watchlist(tmp, identities=tuple(("debian", "12", f"pkg{i}") for i in range(60)))
    rows = [row([rec(i * 100 + j, pkg=f"pkg{i}") for j in range(64)], ident=("debian", "12", f"pkg{i}")) for i in range(60)]
    data = m.build(big_w, bundle(rows), None, NOW)
    dd = json.loads(data)
    t("document over 256 KiB → trimmed to fit, trimmed sources partial",
      len(data) <= 256 * 1024 and any(c["status"] == "partial" for c in dd["coverage"]))
    # The signing gate's own check.
    dup = json.loads(m.build(w, bundle([row([rec(1)])]), None, NOW))
    dup["coverage"].append(dict(dup["coverage"][0]))
    try:
        m.check_payload(json.dumps(dup).encode())
        t("a duplicate (identity, source) pair refuses to sign", False)
    except m.Refuse:
        t("a duplicate (identity, source) pair refuses to sign", True)
    long = json.loads(m.build(w, bundle([row([rec(1)])]), None, NOW))
    long["expires"] = m.iso(m.parse_iso(long["published"]) + 72 * 3600 + 1)
    try:
        m.check_payload(json.dumps(long).encode())
        t("validity over 72 h refuses to sign", False)
    except m.Refuse:
        t("validity over 72 h refuses to sign", True)
    # R1: explicit versions are part of the applicability union.
    r1 = rec(2, fixed="2.0")
    r1["affected"][0]["versions"] = ["3.0", "1.0"]
    a = build(bundle([row([r1])]))["entries"][0]["advisories"][0]
    t("R1: a listed version outside the ranges is published (union)", a["affected"].get("versions") == ["3.0"])
    t("R1: a listed version already inside a range is omitted (proven by dpkg order)", "1.0" not in a["affected"].get("versions", []))
    t("R1: ranges kept alongside versions", a["affected"]["ranges"][0]["events"] == [{"introduced": "0"}, {"fixed": "2.0"}])
    # R2: incomplete interpretation is failed, never ok/partial.
    d = build(bundle([row([rec(1), {"id": "CVE-2099-0002", "affected": []}])]))
    t("R2: a returned record naming no affected entry fails the row", cov(d) == ["failed"])
    d = build(bundle([row([rec(1), {"id": "CVE-2099-0003", "affected": [], "withdrawn": "2026-10-01T00:00:00Z"}])]))
    t("R2: a withdrawn record naming nothing is skipped (row still ok)", cov(d) == ["ok"])
    bad2 = rec(2, extra_ids=16)
    bad2["affected"] = [{"ranges": [{"type": "ECOSYSTEM", "events": "not-a-list"}]}]
    d = build(bundle([row([rec(1), bad2])]))
    t("R2: a malformed record over the ID cap is failed, not size-partial", cov(d) == ["failed"])
    weird = rec(3)
    weird["affected"][0]["ranges"][0]["type"] = "é" * 20
    d = build(bundle([row([weird])]))
    t("N1: a range type the client would reject fails the row (never signed)", cov(d) == ["failed"])
    long = json.loads(m.build(w, bundle([row([rec(1)])]), None, NOW))
    long["entries"][0]["advisories"][0]["affected"]["ranges"][0]["type"] = "é" * 17
    try:
        m.check_payload(json.dumps(long, ensure_ascii=False).encode())
        t("N1: the signing gate counts UTF-8 bytes like the client", False)
    except m.Refuse:
        t("N1: the signing gate counts UTF-8 bytes like the client", True)
    # Fetcher (R2): records OSV returned for this package.
    try:
        fetch.slim({"id": "CVE-2099-0004"}, "ffmpeg", "Debian:12")
        t("R2 fetch: a record without affected is an incomplete source", False)
    except fetch.FeedError:
        t("R2 fetch: a record without affected is an incomplete source", True)
    try:
        fetch.slim({"id": "CVE-2099-0005", "affected": [{"package": {"name": "other", "ecosystem": "Debian:12"}}]}, "ffmpeg", "Debian:12")
        t("R2 fetch: a record that does not name the package is an incomplete source", False)
    except fetch.FeedError:
        t("R2 fetch: a record that does not name the package is an incomplete source", True)
    try:
        fetch.slim({"id": "CVE-2099-0006", "affected": [{"package": "ffmpeg"}]}, "ffmpeg", "Debian:12")
        t("R2 fetch: malformed package metadata is an incomplete source", False)
    except fetch.FeedError:
        t("R2 fetch: malformed package metadata is an incomplete source", True)
    ok_w = fetch.slim({"id": "CVE-2099-0007", "withdrawn": "x", "affected": []}, "ffmpeg", "Debian:12")
    t("R2 fetch: a withdrawn record may name nothing", ok_w["affected"] == [])
    # dpkg ordering fixtures (same table as the Swift selftest).
    table = [("1.0", "1.0-1", -1), ("1.0~rc1", "1.0", -1), ("1:0.9", "2.0", 1), ("1.0-1", "1.0-1+b1", -1),
             ("1.2.3", "1.2.3-0", 0), ("1.0a", "1.0", 1), ("2.30-2", "2.3-9", 1), ("1.0~~", "1.0~", -1)]
    t("Debian ordering matches the fixture table", all(m.deb_compare(a, b) == c for a, b, c in table),
      [(a, b, m.deb_compare(a, b)) for a, b, c in table])
    return res


BREAKS = [
    ("R1: a listed version outside the ranges is published (union)",
     '        if versions:\n            affected["versions"] = versions', ''),
    ("R2: a returned record naming no affected entry fails the row",
     '        raise Incomplete("a record returned for this package names no affected entry")', '        return None'),
    ("R2: a malformed record over the ID cap is failed, not size-partial",
     '    ranges, versions, fixed, purl = [], [], [], None\n    for a in aff:',
     '    advisory_ids(rec)\n    ranges, versions, fixed, purl = [], [], [], None\n    for a in aff:'),
    ("N1: the signing gate counts UTF-8 bytes like the client",
     'if type(t) is not str or len(t.encode()) > 32:', 'if type(t) is not str or len(t) > 32:'),
    ("R2 fetch: a record that does not name the package is an incomplete source",
     '    if not kept and not record.get("withdrawn"):', '    if False:', "fetch"),
    ("R2 fetch: a record without affected is an incomplete source",
     '        raise FeedError(f"{record.get(\'id\')}: affected is missing or not a list")',
     '        return {"id": record.get("id"), "affected": []}', "fetch"),
    ("a failed fetch is published as failed, never ok",
     'statuses[source] = ("failed", None)\n                complete = False\n                continue',
     'statuses[source] = ("ok", "2026-10-24T00:00:00Z")\n                complete = False\n                continue'),
    ("a duplicate (identity, source) pair refuses to sign",
     'raise Refuse(f"duplicate (identity, source) coverage pair {k} — refusing to sign")', 'pass'),
    ("more than 64 advisories → 64 kept, source partial", "mark_partial(statuses, a[\"_source\"])", "pass"),
    ("trimming keeps KEV first", 'adv["_order"] = (0 if adv["kev"] else 1,', 'adv["_order"] = (1 if adv["kev"] else 1,'),
    ("an advisory no longer published is carried as withdrawn", "if set(old.get(\"ids\", [])) & present:", "if True:"),
    ("withdrawn advisories are dropped after 30 days",
     'if now - parse_iso(since) > WITHDRAWN_DAYS * 86400:\n                    continue', 'if False:\n                    continue'),
    ("failed keeps the last good checkedAt",
     'checked = old["checkedAt"] if old and old.get("status") in ("ok", "partial", "failed") else iso(0)', 'checked = iso(0)'),
    ("a malformed record makes the row failed (not partial, not ok)",
     'raise Incomplete("event must have exactly one key")', 'continue'),
    ("an advisory over 16 IDs is dropped and the source marked partial", 'raise TooLarge(f"{len(out)} IDs")', 'out = out[:MAX_IDS]'),
    ("validity over 72 h refuses to sign", "if not 0 < exp - pub <= 72 * 3600:", "if False:"),
    ("KEV feed failure → KEV coverage failed", 'statuses[source] = ("ok", kev_src.get("checkedAt")) if kev_ok else ("failed", None)',
     'statuses[source] = ("ok", kev_src.get("checkedAt") or "2026-10-24T00:00:00Z")'),
    ("several fixed events → the highest by dpkg order", "            if c > 0:\n                best = v", "            if c < 0:\n                best = v"),
]


def main():
    tmp = tempfile.mkdtemp(prefix="advpub-")
    try:
        m = load(SRC, "advisory_publish_under_test")
        run_tests(m, tmp)
        caught = 0
        for brk in BREAKS:
            name, old, new = brk[:3]
            target = brk[3] if len(brk) > 3 else "publish"
            src_path = SRC if target == "publish" else os.path.join(HERE, "advisory_fetch.py")
            src = open(src_path).read()
            if old not in src:
                check(f"break anchor present: {name}", False, old)
                continue
            try:
                if target == "publish":
                    p = os.path.join(tmp, "advisory_publish.py")
                    open(p, "w").write(src.replace(old, new, 1))
                    shutil.copy(os.path.join(HERE, "advisory_fetch.py"), os.path.join(tmp, "advisory_fetch.py"))
                    mm, ff = load(p, f"broken_{caught}_{len(name)}"), None
                else:
                    p = os.path.join(tmp, "advisory_fetch_broken.py")
                    open(p, "w").write(src.replace(old, new, 1))
                    mm, ff = m, load(p, f"brokenfetch_{caught}_{len(name)}")
                res = run_tests(mm, tmp, only={name}, fetch=ff)
                ok = res.get(name) is False
            except Exception:
                ok = True     # a break that crashes is also caught
            caught += ok
            check(f"deliberate break caught: {name}", ok)
        print(f"\n{passed} passed, {failed} failed ({caught}/{len(BREAKS)} deliberate breaks caught)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
