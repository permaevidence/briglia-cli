#!/usr/bin/env python3
"""Deliberate breaks for security plan v8 Phase 2 (§15: every item has a
counterpart that must fail). Each mutation edits ONE source line in this
checkout, rebuilds incrementally (Swift) or reruns directly (Python
tooling), requires the named test to FAIL, and restores the file — also on
error or Ctrl-C. Local review tool (it rebuilds the debug binary per Swift
break), not a CI step.

Usage: security_phase2_mutation_test.py [--only N] [--swift-build-args ...]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug/briglia"
E = "TelegramConcierge/Services/UpdateNoticeEngine.swift"
SVC = "TelegramConcierge/Services/UpdateNoticeService.swift"
STORE = "TelegramConcierge/Services/UpdateNoticeStore.swift"
TG = "TelegramConcierge/Services/TelegramBotService.swift"
UPG = "TelegramConcierge/CLI/UpgradeService.swift"
RS = ".github/scripts/release_security.py"

SELF = ["selftest"]
E2E = ["e2e"]
TOOL = ["tooling"]

MUTATIONS = [
    ("M1 a lower observation overwrites the observed record (replay erases 135)", E,
     "                if d.lowerSince == nil { d.lowerSince = env.now }\n                d.lastLowerSequence = o.sequence\n                effect = .lower",
     "                if d.lowerSince == nil { d.lowerSince = env.now }\n                d.lastLowerSequence = o.sequence\n                d.observed = fresh\n                effect = .lower", SELF),
    ("M2 v7 rule: floor:critical news only if no class is open (R7-1 reopened)", E,
     "!s.classes.contains(where: { $0.floor == .critical }), notified != .critical {",
     "!s.classes.contains(where: { $0.floor == .critical }), s.classes.isEmpty {", SELF),
    ("M3 critical floor does not supersede the pending recommended reminder", E,
     "                    s.classes[i].reminderAttempted = true\n                    s.classes[i].supersededBy = key",
     "                    s.classes[i].supersededBy = key", SELF),
    ("M4 retries re-apply the first-send predicates (announcedThrough)", E,
     "        guard let after = r.retryAfter, env.now >= after else { return .notYet }",
     "        guard let after = r.retryAfter, env.now >= after else { return .notYet }\n        if kind == .release, s.announcedThrough >= r.sequence { return .drop(r) }", SELF),
    ("M5 an ambiguous outcome is retried like a refusal", E,
     "        case .ambiguous: state = .ambiguous",
     "        case .ambiguous: state = .refused; s.attempts[i].retryAfter = env.now", SELF),
    ("M6 the 2 MiB writer cap is removed", STORE,
     "        guard data.count <= UpdateNotice.maxStateBytes else {",
     "        guard data.count <= UpdateNotice.maxStateBytes || true else {", SELF),
    ("M7 a merge does not repoint a pending reminder retry (round-8 note 1)", E,
     "                    let mapped = losers.contains(id) ? survivor.classId : id",
     "                    let mapped = id", SELF),
    ("M8 the notice check persists the anti-rollback sequence", UPG,
     "        return try ReleaseSigning.verifyEnvelope(raw, policy: policy)\n    }",
     "        let m = try ReleaseSigning.verifyEnvelope(raw, policy: policy)\n        try? ReleaseTrustStore.store(m.sequence, domain: policy.trustDomain)\n        return m\n    }", E2E),
    ("M9 a 5xx with an ok:false body is treated as a refusal (retryable)", TG,
     "        if (400...499).contains(status), ok == false {",
     "        if (400...599).contains(status), ok == false {", SELF),
    ("M10 retries ignore the stored contentId", E,
     "o.sequence == r.sequence, o.contentId == r.observedContentId,",
     "o.sequence == r.sequence,", SELF),
    ("M11 the check runs although /upgradecheck is off", SVC,
     "                guard setting.enabled else { return (false, nil) }\n                UpdateNotice.scheduleNextCheck",
     "                UpdateNotice.scheduleNextCheck", SELF),
    ("M12 resolved classes are not removed after an upgrade", E,
     "            s.classes.removeAll { $0.fixedIn <= env.installed }\n",
     "\n", SELF),
    ("M13 a merge keeps a pending duplicate reminder of an attempted class", E,
     "            if c.reminderAttempted {\n                survivor.reminderAttempted = true",
     "            if c.reminderAttempted {\n                _ = 0", SELF),
    ("M14 saturation is not entered (the 257th advisory would repeat)", E,
     "                if a.newEntries.count > 0, s.classes.count + incoming > maxClasses {",
     "                if a.newEntries.count > 0, s.classes.count + incoming > maxClasses * 1000 {", SELF),
    ("M15 the notice transport follows redirects (a second POST)", "TelegramConcierge/Services/NoticeHTTPTransport.swift",
     "                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {\n        completionHandler(nil)",
     "                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {\n        completionHandler(request)", E2E),
    ("M16 the service is not retained by its owner (round-1 R1)", SVC,
     "        current = service\n        service.start(tickNanoseconds: tickNanoseconds)",
     "        service.start(tickNanoseconds: tickNanoseconds)", SELF),
    ("M17 below-floor equality renews the record (round-1 R4)", SVC,
     "                if manifest.sequence < floor {",
     "                if manifest.sequence < floor, (s.domain(domain)?.observed?.sequence ?? 0) < manifest.sequence {", SELF),
    ("M18 a floor-only notice ignores the 256-row cap (round-1 N1)", E,
     "                if incoming > 0, s.classes.count + incoming > maxClasses {",
     "                if a.newEntries.count > 0, s.classes.count + incoming > maxClasses {", SELF),
    ("T7 tooling: the post-merge cap skips introduces (round-1 R2)", RS,
     "    for key, groups in ((\"cumulative\", merged), (\"introduces\", merged_intro)):",
     "    for key, groups in ((\"cumulative\", merged),):", TOOL),
    ("T8 tooling: component identity values are not type-checked (round-1 R2)", RS,
     "        if bad_value:\n", "        if False:\n", TOOL),
    ("T9 tooling: a present-but-null summary is treated as absent (round-2 R2)", RS,
     "    if \"summary\" in sec:\n", "    if sec.get(\"summary\") is not None:\n", TOOL),
    ("T10 tooling: componentAdvisories: null is treated as absent (round-2 R2)", RS,
     "    if items is None and not present:", "    if items is None:", TOOL),
    ("T1 tooling: no reintroduction rule (R6-1 reopened)", RS,
     "        if covered(e[\"level\"], e[\"fixed\"], p_fr, p_fc):\n            reasons.append(f\"entering entry",
     "        if False:\n            reasons.append(f\"entering entry", TOOL),
    ("T2 tooling: predecessor = the oldest published release, not the highest", RS,
     "    prev = published[-1]", "    prev = published[0]", TOOL),
    ("T3 tooling: identity sets may shrink", RS,
     "            if lost:\n", "            if False:\n", TOOL),
    ("T4 tooling: the 16-ID cap is checked before the merge only", RS,
     "        if len(g[\"ids\"]) > MAX_IDS:\n            problems.append(f\"merged identity",
     "        if False:\n            problems.append(f\"merged identity", TOOL),
    ("T5 tooling: an unavailable alias lookup passes", RS,
     "                reasons.append(f\"alias lookup unavailable", "                pass  # (f\"alias lookup unavailable", TOOL),
    ("T6 tooling: componentAdvisories may move backwards", RS,
     "        if c is None or c < 0:", "        if c is None:", TOOL),
]


def build(extra):
    r = subprocess.run(["swift", "build", "--build-system", "native"] + extra, cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, r.stdout[-3000:] + r.stderr[-3000:]


def run_test(kind):
    with tempfile.TemporaryDirectory() as tmp:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "SM_"))}
        env.update(HOME=tmp, XDG_CONFIG_HOME=f"{tmp}/c", XDG_DATA_HOME=f"{tmp}/d", TMPDIR=tmp)
        if kind == SELF:
            r = subprocess.run([str(BIN), "__update-notice-selftest"], env=env, capture_output=True, text=True, timeout=900)
        elif kind == E2E:
            r = subprocess.run([sys.executable, str(ROOT / "scripts/security_phase2_test.py"), str(BIN)], env=env,
                               capture_output=True, text=True, timeout=1800)
        else:
            r = subprocess.run([sys.executable, str(ROOT / "scripts/release_security_test.py")], env=env,
                               capture_output=True, text=True, timeout=600)
        fails = [l for l in r.stdout.splitlines() if l.startswith("✖")]
        return r.returncode != 0, fails[:2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--swift-build-args", nargs="*", default=[])
    args = ap.parse_args()
    caught = total = 0
    swift_dirty = False
    for label, rel, old, new, kind in MUTATIONS:
        if args.only and not any(label.startswith(x) for x in args.only.split(",")):
            continue
        total += 1
        path = ROOT / rel
        original = path.read_text()
        if original.count(old) != 1:
            print(f"✖ {label}: anchor not found exactly once — mutation not applied")
            continue
        backup = path.with_suffix(path.suffix + ".mutation-backup")
        shutil.copy2(path, backup)
        try:
            path.write_text(original.replace(old, new))
            if rel.endswith(".swift"):
                swift_dirty = True
                ok, log = build(args.swift_build_args)
                if not ok:
                    print(f"✖ {label}: mutated build failed (not a valid break)\n{log[-800:]}")
                    continue
            failed, fails = run_test(kind)
            if failed:
                caught += 1
                print(f"✔ BREAK {label}: caught — {fails[0] if fails else 'nonzero exit'}")
            else:
                print(f"✖ BREAK {label}: NOT caught")
        finally:
            shutil.copy2(backup, path)
            backup.unlink()
    if swift_dirty:
        ok, log = build(args.swift_build_args)
        print("restored build: " + ("ok" if ok else "FAILED\n" + log))
    print(f"\ndeliberate breaks caught: {caught}/{total}")
    return 0 if caught == total else 1


if __name__ == "__main__":
    sys.exit(main())
