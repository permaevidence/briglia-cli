#!/usr/bin/env python3
"""Tests for lossless pruning of the local-tools advisory list (security
plan §9.5.12): scripts/advisory_publish.py `client_deb_valid`, `prunable`,
`load_floors`, the build integration, and the floor generator
scripts/advisory_floors.py (synthetic archive data, no network). Each rule
has a test; each test has a deliberate break (a one-line mutation of a
temporary copy) that must make it fail. A randomized property check proves
that every advisory `prunable` accepts evaluates to "not affected" under the
client's rules for every sampled version at or above the floor.

Usage: advisory_prune_test.py
"""
import sys as _sys
_sys.dont_write_bytecode = True   # mutated copies must never load a stale .pyc

import importlib.util
import json
import os
import random
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import advisory_publish_test as fx  # noqa: E402

PUB = os.path.join(HERE, "advisory_publish.py")
FLO = os.path.join(HERE, "advisory_floors.py")
NOW = fx.NOW
FLOOR = "7:5.1.2-3"
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


def adv(events=None, versions=None, kev=False, fixed=True, withdrawn=False, rtype="ECOSYSTEM", affected=None):
    a = {"ids": ["DEBIAN-CVE-2099-0001", "CVE-2099-0001"], "kev": kev, "kevAdded": None, "severity": "recommended",
         "withdrawn": withdrawn}
    if affected is not None:
        a["affected"] = affected
    else:
        af = {}
        if events is not None:
            af["ranges"] = [{"type": rtype, "events": events}]
        if versions is not None:
            af["versions"] = versions
        a["affected"] = af
    a["remediation"] = {"fixed": [{"line": None, "version": "1.0"}], "pocket": None} if fixed else None
    a["noFixReason"] = None if fixed else "unknown"
    return a


def client_affected(m, v, a):
    """The client's LocalToolsVersion.isAffected for the deb scheme: a
    listed version equal, or any range true; nil when anything is
    incomparable (an invalid version on either side)."""
    af = a["affected"]
    if af == "unknown":
        return None
    unknown = False
    for x in af.get("versions", []):
        if not (m.client_deb_valid(v) and m.client_deb_valid(x)):
            unknown = True
            continue
        if m.deb_compare(v, x) == 0:
            return True
    for r in af.get("ranges", []):
        if r["type"] != "ECOSYSTEM" or not m.client_deb_valid(v) or \
                any(not m.client_deb_valid(x) for e in r["events"] for x in e.values()):
            unknown = True
            continue
        res = m.deb_in_range(v, r["events"])
        if res is True:
            return True
        if res is None:
            unknown = True
    return None if unknown else False


def run_tests(m, f, tmp, only=None):
    res = {}

    def t(name, ok, detail=""):
        if only is None or name in only:
            res[name] = ok
            if only is None:
                check(name, ok, detail)

    V = m.client_deb_valid
    # ---- client parse mirror
    t("client parse: ordinary, epoch, tilde, colon in upstream and several dashes are valid",
      all(V(x) for x in ("1.0", "7:5.1.2-3", "1.0~rc1-1", "1:2:3-4", "1.0-a-b", "0", "2.12.7+dfsg+really2.9.14-0.4")))
    t("client parse: empty revision, non-digit start, bad epoch, whitespace, non-ASCII, >256 bytes are invalid",
      not any(V(x) for x in ("1.0-", "a1.0", "x:1.0", ":1.0", "1.0 ", " 1.0", "1.0\t", "١:1.0", "1.é0",
                             "1" * 257, "1000000:1.0", "", "1.0-1_2", "1.0-a:b")))
    t("client parse: epoch just under the client bound is valid", V("999999:1.0"))
    t("client parse: Python-only shapes ('1:x', '1.0-') are not client-valid", not V("1:x") and not V("1.0-"))
    # ---- ordering edge cases the floor relies on
    t("dpkg order: epoch dominates, tilde sorts before release",
      m.deb_compare("5.9.9", FLOOR) < 0 and m.deb_compare("8:0.1", FLOOR) > 0
      and m.deb_compare("7:5.1.2~rc1-1", FLOOR) < 0 and m.deb_compare("7:5.1.2-3~deb12u1", FLOOR) < 0
      and m.deb_compare("7:5.1.2-3+deb12u1", FLOOR) > 0)
    P = lambda a, fl=FLOOR: m.prunable(a, fl)
    z = {"introduced": "0"}
    # ---- prunable: rules
    t("prune: fixed strictly below the floor", P(adv([z, {"fixed": "7:5.1.1-1"}])))
    t("prune: epoch-less fixed version below an epoch floor", P(adv([z, {"fixed": "5.9.9-1"}])))
    t("prune: tilde pre-release fixed below the floor", P(adv([z, {"fixed": "7:5.1.2~rc1-1"}])))
    t("prune: last_affected strictly below the floor", P(adv([z, {"last_affected": "7:5.1.1-1"}])))
    t("prune: limit strictly below the floor", P(adv([z, {"limit": "7:5.0-1"}])))
    t("prune: several closed windows all below the floor",
      P(adv([z, {"fixed": "7:4.0-1"}, {"introduced": "7:4.1-1"}, {"fixed": "7:5.0-1"}])))
    t("prune: listed versions only, all below the floor", P(adv(versions=["7:5.1.1-1", "7:5.0-2"])))
    t("keep: fixed exactly at the floor", not P(adv([z, {"fixed": FLOOR}])))
    t("keep: fixed above the floor", not P(adv([z, {"fixed": "7:5.1.2-3+deb12u1"}])))
    t("keep: higher epoch fixed version", not P(adv([z, {"fixed": "8:1.0-1"}])))
    t("keep: last_affected at the floor (the floor itself is affected)", not P(adv([z, {"last_affected": FLOOR}])))
    t("keep: introduced 0 alone (always affected)", not P(adv([z])))
    t("keep: re-opened window below the floor (introduced after the last fix)",
      not P(adv([z, {"fixed": "7:4.0-1"}, {"introduced": "7:5.0-1"}])))
    t("keep: introduced and fixed tie at the top version", not P(adv([z, {"introduced": "7:5.0-1"}, {"fixed": "7:5.0-1"}])))
    t("keep: introduced at or above the floor", not P(adv([{"introduced": FLOOR}, {"fixed": "7:9.0-1"}])))
    t("keep: a listed version at the floor", not P(adv(versions=[FLOOR])))
    t("keep: ranges below but one listed version at/above the floor",
      not P(adv([z, {"fixed": "7:5.0-1"}], versions=["7:5.1.2-3"])))
    t("keep: KEV even when fixed below the floor", not P(adv([z, {"fixed": "7:5.0-1"}], kev=True)))
    t("keep: no fix", not P(adv([z, {"last_affected": "7:5.0-1"}], fixed=False)))
    t("keep: withdrawn", not P(adv([z, {"fixed": "7:5.0-1"}], withdrawn=True)))
    t("keep: affected unknown", not P(adv(affected="unknown")))
    t("keep: SEMVER or GIT range", not P(adv([z, {"fixed": "7:5.0-1"}], rtype="SEMVER"))
      and not P(adv([z, {"fixed": "7:5.0-1"}], rtype="GIT")))
    t("keep: an event version the client cannot parse", not P(adv([z, {"fixed": "1:x"}])) and not P(adv([z, {"fixed": "5.0-"}])))
    t("keep: an unknown event kind", not P(adv([z, {"closed": "7:5.0-1"}])))
    t("keep: a listed version the client cannot parse", not P(adv(versions=["1:x"])))
    t("keep: no floor or an invalid floor", not P(adv([z, {"fixed": "7:5.0-1"}]), None)
      and not P(adv([z, {"fixed": "7:5.0-1"}]), "9:9.0-") and not P(adv([z, {"fixed": "7:5.0-1"}]), "9:x"))
    t("keep: vendor-only fields (kind, unknownOutside)",
      not P(dict(adv([z, {"fixed": "7:5.0-1"}]), kind="release")) and not P(dict(adv([z, {"fixed": "7:5.0-1"}]), unknownOutside=True)))
    t("keep: an empty affected object or empty range", not P(adv(affected={})) and not P(adv([])))
    # ---- property: every prunable advisory is "not affected" for v >= floor
    rnd = random.Random(20261024)
    pool = ["0", "1.0", "1.0-1", "1.0~rc1", "1:0.5", "1:1.0-1", "1:1.0-1+b1", "1:1.0-1~bpo1", "2.0", "2:0.1",
            "1.0+dfsg-1", "1.0+dfsg-1.1", "1.0-1ubuntu1", "1.0-1ubuntu1.2", "1.0-1+deb12u1", "0.9", "1.0a", "1.0~~"]
    bad, tried, pruned = [], 0, 0
    for _ in range(6000):
        floor = rnd.choice(pool[1:])
        evs = [{"introduced": "0"}] if rnd.random() < 0.6 else []
        for _ in range(rnd.randint(0, 4)):
            evs.append({rnd.choice(("introduced", "fixed", "last_affected", "limit")): rnd.choice(pool)})
        vs = rnd.sample(pool, rnd.randint(1, 2)) if rnd.random() < 0.2 else None
        a = adv(evs if evs or not vs else None, vs)
        if not (a["affected"].get("ranges") or a["affected"].get("versions")):
            continue
        tried += 1
        if not m.prunable(a, floor):
            continue
        pruned += 1
        for v in pool + [floor + "+x1", floor + "1", "9:9"]:
            if m.client_deb_valid(v) and m.deb_compare(v, floor) >= 0 and client_affected(m, v, a) is not False:
                bad.append((floor, evs, vs, v))
    t("property: every pruned advisory is definitely not affected at or above its floor (6000 random cases)",
      not bad and pruned > 300, (bad[:3], tried, pruned))

    # ---- build integration
    w = fx.watchlist(tmp)
    wu = fx.watchlist(tmp, identities=(("debian", "12", "ffmpeg"), ("ubuntu", "24.04", "ffmpeg")), ubuntu=True)
    floors = {"deb:debian:12:ffmpeg": FLOOR, "deb:ubuntu:24.04:ffmpeg": "7:6.0-6ubuntu1",
              "vendor:nodejs.org:node:linux:official": "1.0"}
    old, new = fx.rec(1, fixed="7:4.4.1-1"), fx.rec(2)

    def build(b, prev=None, wl=w, fl=floors, report=None):
        return json.loads(m.build(wl, b, prev, NOW, floors=fl, report=report))

    rep = {}
    d = build(fx.bundle([fx.row([old, new])]), report=rep)
    ids = [x["ids"][1] for x in d["entries"][0]["advisories"]]
    t("build: an advisory fixed below the floor is not published, the others are", ids == ["CVE-2099-0002"], ids)
    t("build: lossless pruning never marks a source partial (F3 unchanged)", fx.cov(d) == ["ok"], d["coverage"])
    t("build: the report counts pruned advisories per identity and source",
      rep.get("pruned") == {"deb:debian:12:ffmpeg osv:Debian:12": 1}, rep)
    d = build(fx.bundle([fx.row([old, new])]), fl=None)
    t("build: no floors → nothing pruned", len(d["entries"][0]["advisories"]) == 2)
    d = build(fx.bundle([fx.row([old, new])]), fl={"deb:debian:12:zip": FLOOR})
    t("build: an identity without a floor → nothing pruned", len(d["entries"][0]["advisories"]) == 2)
    prev = build(fx.bundle([fx.row([old, new])]), fl=None)
    d = build(fx.bundle([fx.row([old, new])]), prev)
    t("build: a pruned advisory is not carried as withdrawn from the previous list",
      not any(x["withdrawn"] for x in d["entries"][0]["advisories"]), d["entries"][0]["advisories"])
    prev2 = build(fx.bundle([fx.row([new, fx.rec(3)])]), fl=None)
    d = build(fx.bundle([fx.row([old, new])]), prev2)
    t("build: control — a genuinely vanished advisory is still carried as withdrawn",
      [x["ids"][1] for x in d["entries"][0]["advisories"] if x["withdrawn"]] == ["CVE-2099-0003"])
    rep = {}
    d = build(fx.bundle([fx.row([old, fx.rec(4, fixed="7:4.0-1", published="2026-02-01T00:00:00Z")])]), report=rep)
    kept = d["entries"][0]["advisories"]
    t("build: when every advisory would be pruned, one sentinel stays (first by priority)",
      len(kept) == 1 and kept[0]["ids"][1] == "CVE-2099-0004" and sum(rep["pruned"].values()) == 1, (kept, rep))
    d = build(fx.bundle([fx.row([old, fx.rec(5, fixed=None)])]))
    t("build: no sentinel when a live advisory remains", [x["ids"][1] for x in d["entries"][0]["advisories"]] == ["CVE-2099-0005"])
    rows = [fx.row([old, new]),
            fx.row([fx.rec(6, fixed="7:6.0-5ubuntu1", eco="Ubuntu:24.04:LTS"), fx.rec(7, fixed="7:6.1.1-3ubuntu5.1")],
                   source="osv:Ubuntu:24.04:LTS", ident=("ubuntu", "24.04", "ffmpeg")),
            fx.row([fx.rec(8, fixed="7:6.0-5ubuntu1+esm1")], source="osv:Ubuntu:Pro:24.04:LTS", ident=("ubuntu", "24.04", "ffmpeg"))]
    rep = {}
    d = build(fx.bundle(rows), wl=wu, report=rep)
    u = [e for e in d["entries"] if e["identity"]["distro"] == "ubuntu"][0]
    t("build: Ubuntu archive and Pro sources are pruned against the same identity floor",
      [x["ids"][1] for x in u["advisories"]] == ["CVE-2099-0007"]
      and rep["pruned"].get("deb:ubuntu:24.04:ffmpeg osv:Ubuntu:24.04:LTS") == 1
      and rep["pruned"].get("deb:ubuntu:24.04:ffmpeg osv:Ubuntu:Pro:24.04:LTS") == 1, (u["advisories"], rep))
    t("build: Ubuntu coverage stays ok", fx.cov(d, "osv:Ubuntu:24.04:LTS", "deb:ubuntu:24.04:ffmpeg") == ["ok"]
      and fx.cov(d, "osv:Ubuntu:Pro:24.04:LTS", "deb:ubuntu:24.04:ffmpeg") == ["ok"])
    many = [fx.rec(100 + i, fixed="7:4.0-1") for i in range(70)] + [fx.rec(200 + i, published=f"2026-0{1 + i % 9}-01T00:00:00Z") for i in range(10)]
    d = build(fx.bundle([fx.row(many)]))
    t("build: 70 pruned + 10 live → 10 published and the source stays ok (pruning is not a size cut)",
      len(d["entries"][0]["advisories"]) == 10 and fx.cov(d) == ["ok"])
    dn = build(fx.bundle([fx.row(many)]), fl=None)
    t("build: control — without floors the same input is cut to 64 and partial",
      len(dn["entries"][0]["advisories"]) == 64 and fx.cov(dn) == ["partial"])
    d = build(fx.bundle([fx.row([old, new])]))
    t("build: the entry carries its floor (the client gate) whenever a floor is in force", d["entries"][0].get("floor") == FLOOR)
    d = build(fx.bundle([fx.row([new])]))
    t("build: the floor is written even when nothing was pruned", d["entries"][0].get("floor") == FLOOR)
    t("build: no floor in force → no floor field", "floor" not in build(fx.bundle([fx.row([old, new])]), fl=None)["entries"][0])
    good = json.loads(m.build(w, fx.bundle([fx.row([new])]), None, NOW, floors=floors))
    def refuses(mut):
        x = json.loads(json.dumps(good)); mut(x)
        try:
            m.check_payload(m.encode(x)); return False
        except m.Refuse:
            return True
    t("check: a floor the client cannot parse, a non-string floor, or a floor on a non-deb entry refuses to sign",
      refuses(lambda x: x["entries"][0].update(floor="1:x")) and refuses(lambda x: x["entries"][0].update(floor=5))
      and refuses(lambda x: x["entries"][0].update(scheme="semver")) and not refuses(lambda x: None))
    # ---- floors file
    p = os.path.join(tmp, "floors.json")
    json.dump({"schema": 1, "floors": {"deb:debian:12:ffmpeg": {"floor": FLOOR}, "deb:debian:12:zip": {"floor": None},
                                       "deb:debian:12:tar": {"floor": "1.0-"}}}, open(p, "w"))
    fl, why = m.load_floors(p)
    t("floors: valid entries load; null and client-invalid floors are absent", fl == {"deb:debian:12:ffmpeg": FLOOR} and why is None, fl)
    open(p, "w").write("{")
    t("floors: a malformed file disables pruning", m.load_floors(p)[0] is None)
    json.dump({"schema": 2, "floors": {}}, open(p, "w"))
    t("floors: a wrong schema disables pruning", m.load_floors(p)[0] is None)
    t("floors: a missing file disables pruning", m.load_floors(os.path.join(tmp, "nope.json"))[0] is None)
    repo, _ = m.load_floors(m.DEFAULT_FLOORS)
    wl = json.load(open(os.path.join(ROOT, "security", "local-tools.json")))
    debs = {f"deb:{i['distro']}:{i['release']}:{i['source']}" for i in wl["identities"] if i["kind"] == "deb"}
    t("floors: the committed file gives every watchlist deb identity a client-valid floor", repo is not None and debs <= set(repo),
      sorted(debs - set(repo or {})))
    # main() uses the committed floors by default
    bpath, out, rpath = os.path.join(tmp, "b.json"), os.path.join(tmp, "o.json"), os.path.join(tmp, "r.json")
    json.dump(fx.bundle([fx.row([fx.rec(9, fixed="1:0.5-1"), new])]), open(bpath, "w"))
    rc = m.main(["build", "--input", bpath, "--out", out, "--watchlist", w, "--now", "2026-10-24T00:00:00Z", "--report", rpath])
    r = json.load(open(rpath)) if rc == 0 else {}
    t("main: prunes with the committed floors by default and writes the report", rc == 0 and r.get("floorsLoaded")
      and sum(r.get("pruned", {}).values()) == 1, r)
    rc = m.main(["build", "--input", bpath, "--out", out, "--watchlist", w, "--now", "2026-10-24T00:00:00Z", "--no-prune", "--report", rpath])
    r = json.load(open(rpath)) if rc == 0 else {}
    t("main: --no-prune publishes everything", rc == 0 and not r.get("floorsLoaded") and not r.get("pruned"), r)

    # ---- generator (synthetic archive data)
    s1 = {"ffmpeg": ["7:5.1.2-3"], "zip": ["3.0-12"]}
    s2 = {"ffmpeg": ["7:5.1.3-1", "7:5.1.2-9"], "zip": ["3.0-11"]}
    s3 = {"ffmpeg": ["7:5.1.3-1"], "zip": ["3.0-13"]}
    cur = [{"ffmpeg": ["7:5.1.6-0+deb12u1"]}, {}]
    t("generator: the floor is the lowest version over every sample and today's pockets",
      f.debian_one("ffmpeg", [s1, s2, s3], cur) == {"floor": "7:5.1.2-3", "observations": 5}
      and f.debian_one("ffmpeg", [s1, s3], [{"ffmpeg": ["7:5.1.1-1"]}])["floor"] == "7:5.1.1-1")
    t("generator: a decrease between samples lowers the floor (never disqualifies)", f.debian_one("zip", [s1, s2, s3], cur)["floor"] == "3.0-11")
    t("generator: a source absent from some samples still gets the minimum of the others",
      f.debian_one("ffmpeg", [{}, s2, s3], cur)["floor"] == "7:5.1.2-9")
    t("generator: a source absent from the release-day sample has no floor", f.debian_one("ffmpeg", [s1, s2, {}], cur)["floor"] is None)
    t("generator: an unparsable version (sample or today's pockets) leaves no floor",
      f.debian_one("ffmpeg", [{"ffmpeg": ["1:x"]}, s3], cur)["floor"] is None
      and f.debian_one("ffmpeg", [s1, s3], [{"ffmpeg": ["6.0-"]}])["floor"] is None)
    t("generator: Debian sampling runs monthly from the codename's first testing day to the day after release",
      f.DEBIAN["12"]["samples"][0] == "20210815T120000Z" and f.DEBIAN["12"]["samples"][-1] == "20230611T120000Z"
      and f.DEBIAN["13"]["samples"][0] == "20230611T120000Z" and f.DEBIAN["13"]["samples"][-1] == "20250810T120000Z"
      and len(f.DEBIAN["12"]["samples"]) == 24 and "20220101T000000Z" in f.DEBIAN["12"]["samples"])
    t("generator: Sources stanzas parse (several versions per source)",
      f.parse_sources("Package: a\nVersion: 1.0-1\nBinary: a\n\nPackage: a\nVersion: 0.9-1\n\nPackage: b\nVersion: 2\n")
      == {"a": ["1.0-1", "0.9-1"], "b": ["2"]})
    rel = "Codename: bookworm\nSHA256:\n abc 10 main/source/Sources.gz\n def 12 main/source/Sources.xz\nOther: x\n"
    t("generator: the Release SHA256 for Sources.xz is found", f.release_sha256(rel, "main/source/Sources.xz") == "def"
      and f.release_sha256(rel, "main/binary-all/Packages") is None)

    def fake_lp(pages):
        def get(url, limit=0):
            i = 0 if "page2" not in url else 1
            return json.dumps(pages[i]).encode(), url
        return get
    saved, err = f.get, sys.stderr
    sys.stderr = open(os.devnull, "w")     # the generator's progress lines
    try:
        P1 = {"source_package_name": "ffmpeg", "source_package_version": "7:6.1.1-3ubuntu5", "pocket": "Release"}
        f.get = fake_lp([{"total_size": 4, "entries": [P1,
                                      {"source_package_name": "ffmpeg", "source_package_version": "7:6.0-6ubuntu1", "pocket": "Proposed"}],
                          "next_collection_link": "https://x/page2"},
                         {"entries": [{"source_package_name": "ffmpeg", "source_package_version": "7:6.0-5ubuntu1", "pocket": "Release"},
                                      {"source_package_name": "ffmpeg-other", "source_package_version": "1:0", "pocket": "Release"}]}])
        out, _ = f.ubuntu_floors("24.04", ["ffmpeg"])
        t("generator: Ubuntu floor = lowest over every page, pocket and status of the series", out["ffmpeg"]["floor"] == "7:6.0-5ubuntu1", out)
        f.get = fake_lp([{"total_size": 1, "entries": [{"source_package_name": "ffmpeg", "source_package_version": "7:6.0-6ubuntu1", "pocket": "Proposed"}]}])
        out, _ = f.ubuntu_floors("24.04", ["ffmpeg"])
        t("generator: a source never in the Ubuntu release pocket has no floor", out["ffmpeg"]["floor"] is None, out)
        f.get = fake_lp([{"total_size": 2, "entries": [{"source_package_name": "ffmpeg", "source_package_version": "7:6.0-6ubuntu1", "pocket": "Release"},
                                      {"source_package_name": "ffmpeg", "source_package_version": "6.0-", "pocket": "Updates"}]}])
        out, _ = f.ubuntu_floors("24.04", ["ffmpeg"])
        t("generator: an unparsable Ubuntu version leaves no floor", out["ffmpeg"]["floor"] is None, out)
        # Codex round 1 R2: incomplete or malformed collection evidence.
        def lp(pages):
            f.get = fake_lp(pages)
            return f.ubuntu_floors("24.04", ["ffmpeg"])[0]["ffmpeg"]["floor"]
        first = {"total_size": 2, "next_collection_link": "https://x/page2", "entries": [P1]}
        t("generator: a malformed later Launchpad page ({}) leaves no floor", lp([first, {}]) is None)
        t("generator: a later page with a non-list entries leaves no floor", lp([first, {"entries": {}}]) is None)
        t("generator: fewer publications than total_size leaves no floor",
          lp([{"total_size": 3, "entries": [P1, dict(P1, source_package_version="7:6.0-1")]}]) is None)
        t("generator: more publications than total_size leaves no floor",
          lp([{"total_size": 1, "entries": [P1, dict(P1, source_package_version="7:6.0-1")]}]) is None)
        t("generator: a first page without total_size leaves no floor", lp([{"entries": [P1]}]) is None)
        t("generator: a malformed publication (missing pocket or version) leaves no floor",
          lp([{"total_size": 1, "entries": [{"source_package_name": "ffmpeg", "source_package_version": "7:6.0-1"}]}]) is None
          and lp([{"total_size": 1, "entries": [{"source_package_name": "ffmpeg", "pocket": "Release"}]}]) is None)
        t("generator: a non-string next link leaves no floor", lp([{"total_size": 1, "entries": [P1], "next_collection_link": 5}]) is None)
        t("generator: control — a complete two-page collection gives the floor",
          lp([first, {"entries": [dict(P1, source_package_version="7:6.0-1")]}]) == "7:6.0-1")
    finally:
        f.get = saved
        sys.stderr.close()
        sys.stderr = err
    return res


BREAKS = [
    # (test name, anchor, replacement, target)
    ("client parse: empty revision, non-digit start, bad epoch, whitespace, non-ASCII, >256 bytes are invalid",
     "        if not rev:\n            return False", "        pass"),
    ("client parse: empty revision, non-digit start, bad epoch, whitespace, non-ASCII, >256 bytes are invalid",
     '    if type(v) is not str or not v or len(v.encode("utf-8")) > 256 or not v.isascii():',
     '    if type(v) is not str or not v:'),
    ("client parse: Python-only shapes ('1:x', '1.0-') are not client-valid",
     '    if not up or up[0] not in "0123456789":', '    if not up:'),
    ("keep: fixed exactly at the floor", "            if deb_compare(x, floor) >= 0:\n                return False          # every event",
     "            if deb_compare(x, floor) > 0:\n                return False          # every event"),
    ("keep: introduced and fixed tie at the top version",
     '        if any(k == "introduced" for k, x in evs if deb_compare(x, top) == 0):\n            return False',
     '        if False:\n            return False'),
    ("keep: introduced 0 alone (always affected)", "        if not evs:\n            return False", "        if False:\n            return False"),
    ("keep: a listed version at the floor", "        if not client_deb_valid(v) or deb_compare(v, floor) >= 0:",
     "        if not client_deb_valid(v) or deb_compare(v, floor) > 0:"),
    ("keep: KEV even when fixed below the floor",
     '    if adv.get("withdrawn") or adv.get("kev") or adv.get("remediation") is None',
     '    if adv.get("withdrawn") or adv.get("remediation") is None'),
    ("keep: no fix", ' or adv.get("remediation") is None or adv.get("noFixReason") is not None:', ':'),
    ("keep: withdrawn", '    if adv.get("withdrawn") or adv.get("kev")', '    if adv.get("kev")'),
    ("keep: SEMVER or GIT range", '        if r.get("type") != "ECOSYSTEM" or not r.get("events"):', '        if not r.get("events"):'),
    ("keep: an event version the client cannot parse", "            if k not in EVENTS or not client_deb_valid(x):",
     "            if k not in EVENTS or deb_compare(x, x) is None:"),
    # The mirror check alone also rejects an unknown kind, so the break removes both guards.
    ("keep: an unknown event kind", "            if k not in EVENTS or not client_deb_valid(x):", "            if not client_deb_valid(x):",
     "publish", ("        if deb_in_range(floor, r[\"events\"]) is not False:\n            return False", "        pass")),
    ("keep: vendor-only fields (kind, unknownOutside)", '    if adv.get("kind") is not None or adv.get("unknownOutside"):\n        return False',
     '    if False:\n        return False'),
    ("keep: no floor or an invalid floor", "    if not client_deb_valid(floor):\n        return False", "    if floor is None:\n        return False"),
    ("property: every pruned advisory is definitely not affected at or above its floor (6000 random cases)",
     '        if any(k == "introduced" for k, x in evs if deb_compare(x, top) == 0):\n            return False\n        if deb_in_range(floor, r["events"]) is not False:\n            return False', "        pass"),
    ("keep: re-opened window below the floor (introduced after the last fix)",
     '        if any(k == "introduced" for k, x in evs if deb_compare(x, top) == 0):\n            return False\n        if deb_in_range(floor, r["events"]) is not False:\n            return False', "        pass"),
    ("build: a pruned advisory is not carried as withdrawn from the previous list",
     '            present = {i for a in advs for i in a["ids"]} | pruned_ids', '            present = {i for a in advs for i in a["ids"]}'),
    ("build: when every advisory would be pruned, one sentinel stays (first by priority)",
     "            advs.append(pruned.pop(0))", "            pass"),
    ("build: when every advisory would be pruned, one sentinel stays (first by priority)",
     '            pruned.sort(key=lambda a: a["_order"])', "            pass"),
    ("build: no sentinel when a live advisory remains", '        if pruned and not any(not a.get("withdrawn") for a in advs):',
     "        if pruned:"),
    ("build: the report counts pruned advisories per identity and source",
     '                report["pruned"][key] = report["pruned"].get(key, 0) + 1', "                pass"),
    ("floors: valid entries load; null and client-invalid floors are absent",
     '        if type(k) is str and type(v) is dict and client_deb_valid(v.get("floor")):',
     '        if type(k) is str and type(v) is dict and v.get("floor"):'),
    ("floors: a wrong schema disables pruning", '    if type(d) is not dict or d.get("schema") != 1 or type(d.get("floors")) is not dict:',
     '    if type(d) is not dict or type(d.get("floors")) is not dict:'),
    ("main: prunes with the committed floors by default and writes the report",
     '    b.add_argument("--floors", default=DEFAULT_FLOORS)', '    b.add_argument("--floors", default="/nonexistent")'),
    ("build: an advisory fixed below the floor is not published, the others are",
     "        floor = (floors or {}).get(ikey)", "        floor = None"),
    ("generator: the floor is the lowest version over every sample and today's pockets",
     "    for idx in list(series) + list(current):", "    for idx in list(series):", "floors"),
    ("generator: a source absent from the release-day sample has no floor",
     "    if not series or not series[-1].get(src):", "    if not series:", "floors"),
    ("generator: an unparsable version (sample or today's pockets) leaves no floor",
     "            if not client_deb_valid(v) or deb_compare(v, v) is None:\n                return {\"floor\": None, \"reason\": f\"unparsable version {v!r}\"}",
     "            if deb_compare(v, v) is None:\n                return {\"floor\": None, \"reason\": f\"unparsable version {v!r}\"}", "floors"),
    ("generator: a malformed later Launchpad page ({}) leaves no floor",
     "            if type(entries) is not list or (link is not None and type(link) is not str):",
     "            entries = entries or []\n            if False:", "floors"),
    ("generator: fewer publications than total_size leaves no floor",
     "        if problem is None and count != total:", "        if problem is None and count > total:", "floors"),
    ("generator: more publications than total_size leaves no floor",
     "        if problem is None and count != total:", "        if problem is None and count < total:", "floors"),
    ("generator: a first page without total_size leaves no floor",
     "                if type(total) is not int or total < 0:", "                if False:", "floors",
     ("        if problem is None and count != total:", "        if problem is None and total is not None and count != total:")),
    ("generator: a malformed publication (missing pocket or version) leaves no floor",
     '                        or type(e.get("source_package_version")) is not str or type(e.get("pocket")) is not str:',
     '                        or False:', "floors"),
    ("build: the entry carries its floor (the client gate) whenever a floor is in force",
     '            entry["floor"] = floor', "            pass"),
    ("check: a floor the client cannot parse, a non-string floor, or a floor on a non-deb entry refuses to sign",
     '            if sc != "deb" or e["identity"].get("kind") != "deb" or not client_deb_valid(_cstr(e["floor"], "floor")):',
     '            if not _cstr(e["floor"], "floor"):'),
    ("generator: Ubuntu floor = lowest over every page, pocket and status of the series",
     "            url = link\n", "            url = None\n", "floors"),
    ("generator: a source never in the Ubuntu release pocket has no floor", '        elif "Release" not in pockets:', "        elif False:", "floors"),
    ("generator: an unparsable Ubuntu version leaves no floor",
     "        elif any(not client_deb_valid(v) or deb_compare(v, v) is None for v in versions):",
     "        elif any(deb_compare(v, v) is None for v in versions):", "floors"),
]


def main():
    tmp = tempfile.mkdtemp(prefix="advprune-")
    try:
        m = load(PUB, "advisory_publish_prune_under_test")
        f = load(FLO, "advisory_floors_under_test")
        run_tests(m, f, tmp)
        caught = 0
        for n, (name, old, new, *rest) in enumerate(BREAKS):
            target = rest[0] if rest else "publish"
            pairs = [(old, new)] + ([rest[1]] if len(rest) > 1 else [])
            path = PUB if target == "publish" else FLO
            src = open(path).read()
            missing = [o for o, _ in pairs if o not in src]
            if missing:
                check(f"break anchor present: {name}", False, missing[0])
                continue
            try:
                p = os.path.join(tmp, f"broken_{n}.py")
                for o, nw in pairs:
                    src = src.replace(o, nw, 1)
                open(p, "w").write(src)
                if target == "publish":
                    mm, ff = load(p, f"broken_pub_{n}"), f
                else:
                    mm, ff = m, load(p, f"broken_floors_{n}")
                res = run_tests(mm, ff, tmp, only={name})
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
