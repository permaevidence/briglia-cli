#!/usr/bin/env python3
"""Tests for the Node.js vendor advisories (scripts/advisory_node.py,
security plan v17 §9.5.10.1, §15 item 20). Synthetic feeds plus the real
feeds saved on 2026-10-24 (scripts/fixtures/node-advisories/), no network.
Each rule has a test; deliberate breaks (one-line mutations of a temporary
copy) must each make a test fail.

Usage: advisory_node_test.py
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "advisory_node.py")
FIX = os.path.join(HERE, "fixtures", "node-advisories")
NOW = 1_792_800_000.0          # 2026-10-24
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


SCHED = {"v20": {"start": "2023-04-18", "end": "2026-04-30"}, "v22": {"start": "2024-04-24", "end": "2027-04-30"},
         "v24": {"start": "2025-05-06", "end": "2028-04-30"}, "v26": {"start": "2026-04-22", "end": "2029-04-30"},
         "v28": {"start": "2027-04-20", "end": "2030-04-30"}}
DIST = [{"version": v, "date": "2026-10-20", "security": s} for v, s in
        [("v26.12.1", True), ("v26.5.1", True), ("v24.22.1", True), ("v24.21.0", False), ("v24.18.1", True),
         ("v24.18.0", False), ("v22.23.4", True), ("v22.23.2", True), ("v20.19.5", True), ("v24.5.0", False)]]


def wg(**entries):
    return {k: dict({"cve": [], "severity": "high", "affectedEnvironments": ["all"]}, **v) for k, v in entries.items()}


def sources(m, w=None, dist=None, sched=None, failed=()):
    out = {}
    for name, data in (("nodejs-security-wg", w if w is not None else wg()), ("nodejs-dist", dist or DIST),
                       ("nodejs-schedule", sched or SCHED)):
        out[name] = {"status": "failed", "problem": "x"} if name in failed else {"status": "ok", "checkedAt": "2026-10-24T00:00:00Z", "data": data}
    return out


def ids(advs):
    return [a["ids"][0] for a in advs]


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

    # Grammar.
    def grammar():
        P, U = m.parse_ranges, m.Unsupported
        ok = (P("24.x") == [((24, 0, 0), (25, 0, 0))] and P("24.5.x") == [((24, 5, 0), (24, 6, 0))]
              and P("^24.18.1") == [((24, 18, 1), (25, 0, 0))] and P("^0.10.48") == [((0, 10, 48), (0, 11, 0))]
              and P("24.1.2") == [((24, 1, 2), (24, 1, 3))] and P(">= 4.8.4") == [((4, 8, 4), m.INF)]
              and P(">=6.0.0 <6.2.0") == [((6, 0, 0), (6, 2, 0))] and P("<= 4") == [((0, 0, 0), (5, 0, 0))]
              and P("4.x || 6.x") == [((4, 0, 0), (5, 0, 0)), ((6, 0, 0), (7, 0, 0))])
        bad = 0
        for e in ("", "*", "~24.1.0", ">24.0.0", "24.x.x", "^0.0.1", "v24.1.0", "24", "24.x ||", "<24.0.0", "24.1.0-rc.1"):
            try:
                P(e)
            except U:
                bad += 1
        return ok and bad == 11, bad
    t("grammar: every real form parses, everything else is unsupported", grammar)

    def real_grammar():
        p = os.path.join(FIX, "core-index.json")
        d = json.load(open(p))
        fails = []
        for k, v in d.items():
            for f in ("vulnerable", "patched"):
                try:
                    m.parse_ranges(v[f])
                except m.Unsupported as e:
                    fails.append((k, f, str(e)))
        return not fails, fails
    t("grammar: every vulnerable/patched string of the real 2026-10-24 index parses", real_grammar)

    def subtract_lines():
        w = wg(**{"1": {"cve": ["CVE-2099-0001"], "vulnerable": "22.x || 24.x || 26.x", "patched": "^22.23.2 || ^24.18.1 || ^26.5.1"}})
        advs, st, lines = m.node_identity("darwin", sources(m, w), {}, NOW)
        a = next(a for a in advs if a["ids"] == ["CVE-2099-0001"])
        r = a["affected"]["ranges"]
        want = [{"type": "SEMVER", "events": [{"introduced": "22.0.0"}, {"fixed": "22.23.2"}]},
                {"type": "SEMVER", "events": [{"introduced": "24.0.0"}, {"fixed": "24.18.1"}]},
                {"type": "SEMVER", "events": [{"introduced": "26.0.0"}, {"fixed": "26.5.1"}]}]
        fx = a["remediation"]["fixed"]
        return (r == want and fx == [{"line": "22", "version": "22.23.2"}, {"line": "24", "version": "24.18.1"},
                                     {"line": "26", "version": "26.5.1"}] and lines == ["22", "24", "26"]), (r, fx, lines)
    t("convert: vulnerable minus patched per line, fixed per line, maintained lines", subtract_lines)

    def unpatched_line():
        w = wg(**{"2": {"cve": ["CVE-2099-0002"], "vulnerable": "22.x || 24.x", "patched": "^24.18.1"}})
        a = next(a for a in m.node_identity("linux", sources(m, w), {}, NOW)[0] if a["ids"] == ["CVE-2099-0002"])
        r = a["affected"]["ranges"]
        return (r[0]["events"] == [{"introduced": "22.0.0"}, {"limit": "23.0.0"}]
                and a["remediation"]["fixed"] == [{"line": "24", "version": "24.18.1"}]), a
    t("convert: a line without a patch is affected to its end with no fix for that line", unpatched_line)

    def exact_patch_gap():
        # Patched only one exact version: the later versions of the line stay
        # affected, so the line gets NO fix (never "update to 24.5.0").
        w = wg(**{"3": {"cve": ["CVE-2099-0003"], "vulnerable": "24.x", "patched": "24.5.0"}})
        a = next(a for a in m.node_identity("linux", sources(m, w), {}, NOW)[0] if a["ids"] == ["CVE-2099-0003"])
        return a["remediation"] is None and len(a["affected"]["ranges"]) == 2, a
    t("convert: an exact patched version that leaves later versions affected gives no fix", exact_patch_gap)

    def environments():
        w = wg(**{"4": {"cve": ["CVE-2099-0004"], "vulnerable": "24.x", "patched": "^24.18.1", "affectedEnvironments": ["win32"]},
                  "5": {"cve": ["CVE-2099-0005"], "vulnerable": "24.x", "patched": "^24.18.1", "affectedEnvironments": ["linux"]},
                  "6": {"cve": ["CVE-2099-0006"], "vulnerable": "24.x", "patched": "^24.18.1", "affectedEnvironments": ["plan9"]}})
        d = m.node_identity("darwin", sources(m, w), {}, NOW)[0]
        l = m.node_identity("linux", sources(m, w), {}, NOW)[0]
        unk = [a for a in d if a["ids"] == ["CVE-2099-0006"]]
        return ("CVE-2099-0004" not in ids(d) + ids(l) and "CVE-2099-0005" in ids(l) and "CVE-2099-0005" not in ids(d)
                and unk and unk[0]["affected"] == "unknown"), (ids(d), ids(l))
    t("convert: win32-only dropped, linux-only on linux, unknown token kept as unknown", environments)

    def no_cve_id():
        w = wg(**{"7": {"cve": [], "vulnerable": "24.x", "patched": "^24.18.1"}})
        return "NSWG-CORE-7" in ids(m.node_identity("linux", sources(m, w), {}, NOW)[0]), None
    t("convert: an entry without a CVE gets NSWG-CORE-<key>", no_cve_id)

    def patched_not_released():
        w = wg(**{"8": {"cve": ["CVE-2099-0008"], "vulnerable": "24.x", "patched": "^24.99.0"}})
        a = next(a for a in m.node_identity("linux", sources(m, w), {}, NOW)[0] if a["ids"] == ["CVE-2099-0008"])
        return a["affected"] == "unknown", a
    t("convert: a patched version that is not a Node.js release makes the advisory unknown", patched_not_released)

    def eol_only_dropped():
        w = wg(**{"9": {"cve": ["CVE-2099-0009"], "vulnerable": "18.x || 20.x", "patched": "^20.19.5"},
                  "10": {"cve": ["CVE-2099-0010"], "vulnerable": "0.10.x || 4.x", "patched": "^0.10.99 || ~4"}})
        got = ids(m.node_identity("linux", sources(m, w), {}, NOW)[0])
        return "CVE-2099-0009" not in got and "CVE-2099-0010" not in got, got
    t("convert: entries for end-of-life lines only are dropped (also unreadable ones)", eol_only_dropped)

    def security_release():
        advs = m.node_identity("darwin", sources(m), {}, NOW)[0]
        sr = [a for a in advs if a["ids"][0].startswith("NODEJS-SR-")]
        want = {"NODEJS-SR-22-22.23.4", "NODEJS-SR-24-24.22.1", "NODEJS-SR-26-26.12.1"}
        a24 = next(a for a in sr if a["ids"] == ["NODEJS-SR-24-24.22.1"])
        return ({a["ids"][0] for a in sr} == want
                and a24["affected"]["ranges"][0]["events"] == [{"introduced": "24.0.0"}, {"fixed": "24.22.1"}]
                and a24["remediation"]["fixed"] == [{"line": "24", "version": "24.22.1"}]), sr
    t("convert: one per-line security-release advisory per maintained line (20 is EOL: none)", security_release)

    def release_permanent():
        # Staggered WG arrival: a record naming the release's version has
        # arrived; the release record stays (R17-3) and is typed.
        w = wg(**{"11": {"cve": ["CVE-2099-0011"], "vulnerable": "24.x", "patched": "^24.22.1", "affectedEnvironments": ["win32"]},
                  "15": {"cve": ["CVE-2099-0015"], "vulnerable": ">=24.20.0 <24.22.1", "patched": "^24.22.1"}})
        advs = m.node_identity("darwin", sources(m, w), {}, NOW)[0]
        sr = [a for a in advs if a["ids"] == ["NODEJS-SR-24-24.22.1"]]
        wgs = [a for a in advs if a["ids"] == ["CVE-2099-0015"]]
        return (sr and sr[0].get("kind") == "release" and wgs and "kind" not in wgs[0]), ids(advs)
    t("convert: the release record is permanent and typed kind=release (WG records untyped)", release_permanent)

    def failed_source():
        for f in ("nodejs-security-wg", "nodejs-dist", "nodejs-schedule"):
            advs, st, lines = m.node_identity("linux", sources(m, failed=(f,)), {}, NOW)
            others = [st[o][0] for o in st if o != f]
            if advs or lines is not None or st[f][0] != "failed" or others != ["ok", "ok"]:
                return False, (f, st)
        return True, None
    t("coverage: any failed Node source publishes no advisories and marks it failed", failed_source)

    def malformed_schedule():
        advs, st, lines = m.node_identity("linux", sources(m, sched={"v24": {"start": "2025-05-06", "end": "2028-04-30"}, "v26": {"start": "x", "end": "y"}}), {}, NOW)
        return not advs and lines is None and all(s[0] == "failed" for s in st.values()), st
    t("coverage: a malformed schedule fails every Node source (never a half list)", malformed_schedule)

    def kev_flag():
        w = wg(**{"12": {"cve": ["CVE-2099-0012"], "vulnerable": "24.x", "patched": "^24.18.1", "severity": "medium"}})
        a = next(a for a in m.node_identity("linux", sources(m, w), {"CVE-2099-0012": "2026-10-01"}, NOW)[0]
                 if a["ids"] == ["CVE-2099-0012"])
        return a["kev"] is True and a["kevAdded"] == "2026-10-01" and a["severity"] == "critical", a
    t("convert: KEV marks the advisory and makes it critical", kev_flag)

    def severity():
        w = wg(**{"13": {"cve": ["CVE-2099-0013"], "vulnerable": "24.x", "patched": "^24.18.1", "severity": "critical"},
                  "14": {"cve": ["CVE-2099-0014"], "vulnerable": "24.x", "patched": "^24.18.1", "severity": "high"}})
        a = {x["ids"][0]: x["severity"] for x in m.node_identity("linux", sources(m, w), {}, NOW)[0]}
        return a["CVE-2099-0013"] == "critical" and a["CVE-2099-0014"] == "recommended", a
    t("convert: only WG 'critical' is critical", severity)

    def shapes():
        bad = 0
        for f, v in ((m._shape_wg, []), (m._shape_wg, {"x": {}}), (m._shape_dist, {}), (m._shape_dist, [{"version": 1}]),
                     (m._shape_dist, [{"version": "v1.0.0", "date": "d", "security": "yes"}]), (m._shape_schedule, [])):
            try:
                f(v)
            except m.NodeFeedError:
                bad += 1
        return bad == 6, bad
    t("fetch: malformed feeds are failures, never empty results", shapes)

    def fetch_failure():
        def get(url):
            if "dist" in url:
                raise OSError("boom")
            return {"v24": {"start": "2025-05-06", "end": "2028-04-30"}} if "schedule" in url else {"1": {"cve": []}}
        out = m.fetch_all("2026-10-24T00:00:00Z", get=get)
        return out["nodejs-dist"]["status"] == "failed" and out["nodejs-schedule"]["status"] == "ok", out
    t("fetch: one failing feed is failed, the others still ok", fetch_failure)

    def real_end_to_end():
        w = json.load(open(os.path.join(FIX, "core-index.json")))
        d = json.load(open(os.path.join(FIX, "dist-index.json")))
        s = json.load(open(os.path.join(FIX, "schedule.json")))
        src = sources(m, m._shape_wg(w), m._shape_dist(d), m._shape_schedule(s))
        advs, st, lines = m.node_identity("darwin", src, {}, NOW)
        unknown = [a for a in advs if a["affected"] == "unknown"]
        return (len(advs) <= 64 and not unknown and lines == ["22", "24", "26"]
                and "NODEJS-SR-24-24.22.1" in ids(advs) and "CVE-2026-58041" in ids(advs)), (len(advs), len(unknown), lines)
    t("real feeds 2026-10-24: ≤ 64 advisories, none unknown, the October release flagged", real_end_to_end)
    return res


BREAKS = [
    ("grammar: every real form parses, everything else is unsupported", "            out.append(((0, 0, 0), (int(m.group(1)) + 1, 0, 0))); continue", "            out.append(((0, 0, 0), (int(m.group(1)), 0, 0))); continue"),
    ("convert: vulnerable minus patched per line, fixed per line, maintained lines", "        affected = subtract(vuln, patched)", "        affected = vuln"),
    ("convert: a line without a patch is affected to its end with no fix for that line", 'end = "limit" if hi == (n + 1, 0, 0) or hi == INF else "fixed"', 'end = "fixed"'),
    ("convert: win32-only dropped, linux-only on linux, unknown token kept as unknown", "                return None              # another platform only", "                pass"),
    ("convert: win32-only dropped, linux-only on linux, unknown token kept as unknown", "            unknown = True               # an unknown token: keep, unknown", "            return None"),
    ("convert: an entry without a CVE gets NSWG-CORE-<key>", 'or [f"NSWG-CORE-{key}"]', 'or ["NSWG-CORE"]'),
    ("convert: a patched version that is not a Node.js release makes the advisory unknown", "            if lo != (0, 0, 0) and vstr(lo) not in released:", "            if False:"),
    ("convert: entries for end-of-life lines only are dropped (also unreadable ones)", 'if not a.get("_unknownLines") and not set(map(str, a["_lines"])) & set(lines):', "if False:"),
    ("convert: one per-line security-release advisory per maintained line (20 is EOL: none)", "        for n in sorted(int(x) for x in lines):", "        for n in sorted(sec):"),
    ("convert: the release record is permanent and typed kind=release (WG records untyped)", '"kind": "release", ', ""),
    ("coverage: any failed Node source publishes no advisories and marks it failed", '    if any(st[0] != "ok" for st in statuses.values()):', "    if False:"),
    ("coverage: a malformed schedule fails every Node source (never a half list)", '            raise NodeFeedError(f"schedule {k} has no valid start/end")', "            continue"),
    ("convert: KEV marks the advisory and makes it critical", '                a["kev"], a["kevAdded"], a["severity"] = True, kev.get(kev_hit[0]), "critical"', "                pass"),
    ("convert: only WG 'critical' is critical", 'sev = "critical" if v.get("severity") == "critical" else "recommended"', 'sev = "critical" if v.get("severity") in ("critical", "high") else "recommended"'),
    ("fetch: malformed feeds are failures, never empty results", '        if r.get("security") is not None and type(r.get("security")) is not bool:', "        if False:"),
]


def main():
    run_tests(load(SRC, "advisory_node_real"))
    tmp = tempfile.mkdtemp(prefix="advisory-node-test-")
    caught = 0
    try:
        src = open(SRC).read()
        for name, old, new in BREAKS:
            if old not in src:
                check(f"break anchor present: {name}", False, old)
                continue
            p = os.path.join(tmp, f"advisory_node_b{caught}_{abs(hash(old)) % 10**8}.py")
            open(p, "w").write(src.replace(old, new, 1))
            try:
                ok = run_tests(load(p, os.path.basename(p)[:-3]), only={name}).get(name) is False
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
