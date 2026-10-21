#!/usr/bin/env python3
"""K14R: /keepsummaries downgrade round trip through a REAL 0.2.57 build.

candidate  (`__keep-summaries-selftest --only downgrade-export`)
  a real candidate prune commit leaves six full anchors with usable stubs;
  history + usage are exported, the stub snapshots are NOT (a 0.2.57 home
  never had them).
0.2.57     (pinned tree, default c515b81, plus a test-only driver added to
  its `__prune-retention-selftest`) loads that history with its own decoder,
  adds a seventh anchor through its real prune commit (which demotes four
  and keeps three), and exports history, usage and snapshots.
candidate  (`--only downgrade-import`) restarts on that state and runs the
  idle pass: the four shortened summaries come back byte-for-byte, every
  pointer is rebuilt, all → 7 / default → 3 in full, usage cleared.

Every phase runs in its binary's own isolated scratch home (temporary
XDG_CONFIG_HOME / XDG_DATA_HOME, private preference domain); only the
transfer directory (scratch) is shared. Local and slow (one pinned-tree
build); not run in CI. The permanent in-binary K14 row (smoke, CI) emulates
the 0.2.57 side instead.

Usage: keep_summaries_downgrade_real_test.py [--pinned SHA] [--keep]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANDIDATE = os.path.join(ROOT, ".build/debug/briglia")

DRIVER = r'''import Foundation

/// Test-only driver added by keep_summaries_downgrade_real_test.py (never committed to this tree).
extension RetentionHarness {
    func ksDowngradeOld() async throws {
        guard let transfer = ProcessInfo.processInfo.environment["KS_DOWNGRADE_TRANSFER"].map({ URL(fileURLWithPath: $0) }) else {
            check("K14R old side: transfer directory", false); return
        }
        let fm = FileManager.default
        _ = await freshManager()
        for name in ["conversation.json", "context_usage.json"] {
            let src = transfer.appendingPathComponent("candidate").appendingPathComponent(name)
            let dst = StoragePaths.dataRoot.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dst) }
        }
        let manager = await restart()
        var history = manager._testMessages
        let anchorsIn = history.filter(PruneSummaryRetention.isFullAnchor).count
        check("K14R 0.2.57 decoder loads the candidate history (six full anchors)", anchorsIn == 6, "\(anchorsIn)")
        history.append(user("U_OLD7", at: at(2026, 9, 25, 9, 0)))
        history.append(toolTurn("OLD7", at: at(2026, 9, 25, 10, 0), issued: [at(2026, 9, 25, 9, 30)], edited: ["src/old7.swift"]))
        manager._testSeedHistory(history)
        try await pruneLast(manager, trigger: "automatic", summary: "FULL_SUMMARY_OLD7")
        let after = manager._testMessages
        check("K14R 0.2.57 prune commit: four anchors demoted, three in full",
              records(after).count == 4 && after.filter(PruneSummaryRetention.isFullAnchor).count == 3,
              "records \(records(after).count) full \(after.filter(PruneSummaryRetention.isFullAnchor).count)")
        let raw = (try? String(contentsOf: historyURL, encoding: .utf8)) ?? ""
        check("K14R 0.2.57 re-encode drops the unknown stub field", !raw.isEmpty && !raw.contains("prunedContextSummaryStub"))
        let out = transfer.appendingPathComponent("old")
        try fm.createDirectory(at: out.appendingPathComponent("prune-archives"), withIntermediateDirectories: true)
        for name in ["conversation.json", "context_usage.json"] where fm.fileExists(atPath: StoragePaths.dataRoot.appendingPathComponent(name).path) {
            try fm.copyItem(at: StoragePaths.dataRoot.appendingPathComponent(name), to: out.appendingPathComponent(name))
        }
        let archives = StoragePaths.dataRoot.appendingPathComponent("prune-archives")
        for name in (try? fm.contentsOfDirectory(atPath: archives.path)) ?? [] where name.hasSuffix(".txt") {
            try fm.copyItem(at: archives.appendingPathComponent(name), to: out.appendingPathComponent("prune-archives").appendingPathComponent(name))
        }
    }
}
'''

RUNALL_ANCHOR = '        if section("extremes") { try await extremesSection() }\n'
RUNALL_HOOK = RUNALL_ANCHOR + '        if only == "ks-downgrade-old" { try await ksDowngradeOld() }\n'


def run(cmd, cwd, env=None, label=""):
    proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    rows = [l for l in proc.stdout.splitlines() if l.startswith(("✔", "✖"))]
    for row in rows:
        print("  " + row[:300])
    if proc.returncode != 0:
        print(f"✖ {label} exited {proc.returncode}")
        print(proc.stdout[-2000:] + proc.stderr[-2000:])
    return proc.returncode == 0, rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pinned", default="c515b81")
    parser.add_argument("--keep", action="store_true", help="keep the scratch tree")
    args = parser.parse_args()
    scratch = tempfile.mkdtemp(prefix="ks-downgrade-real-")
    old = os.path.join(scratch, "old")
    transfer = os.path.join(scratch, "transfer")
    os.makedirs(old)
    os.makedirs(transfer)
    env = dict(os.environ, KS_DOWNGRADE_TRANSFER=transfer)
    ok = True
    try:
        print(f"── pinned {args.pinned}: export + build")
        archive = subprocess.run(["git", "archive", args.pinned], cwd=ROOT, capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", old], input=archive, check=True)
        # Reuse only the dependency sources (APFS clone where available), never
        # compiled modules: their module-cache paths are absolute.
        os.makedirs(os.path.join(old, ".build"), exist_ok=True)
        for sub in ("checkouts", "repositories", "workspace-state.json"):
            path = os.path.join(ROOT, ".build", sub)
            if os.path.exists(path):
                subprocess.run(["cp", "-cR", path, os.path.join(old, ".build", sub)], check=False)
        with open(os.path.join(old, "TelegramConcierge/CLI/PruneRetentionSelftest+KSDowngrade.swift"), "w") as f:
            f.write(DRIVER)
        harness = os.path.join(old, "TelegramConcierge/CLI/PruneRetentionSelftest.swift")
        src = open(harness).read()
        if src.count(RUNALL_ANCHOR) != 1:
            raise SystemExit("pinned tree: runAll anchor not found exactly once")
        open(harness, "w").write(src.replace(RUNALL_ANCHOR, RUNALL_HOOK))
        build = subprocess.run(["swift", "build", "--build-system", "native", "-j", "4"], cwd=old, capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout[-3000:] + build.stderr[-3000:])
            raise SystemExit("pinned build failed")
        old_binary = os.path.join(old, ".build/debug/briglia")

        print("── candidate: export")
        good, _ = run([CANDIDATE, "__keep-summaries-selftest", "--only", "downgrade-export"], ROOT, env, "candidate export")
        ok &= good
        stubs = os.path.join(transfer, "candidate", "prune-archives")
        ok &= not os.path.exists(stubs)
        print("── 0.2.57: load, prune, export")
        good, rows = run([old_binary, "__prune-retention-selftest", "--only", "ks-downgrade-old", "--fuzz-cases", "0"], ROOT, env, "0.2.57 side")
        ok &= good and len(rows) == 3
        print("── candidate: import + idle pass")
        good, rows = run([CANDIDATE, "__keep-summaries-selftest", "--only", "downgrade-import"], ROOT, env, "candidate import")
        ok &= good and len(rows) == 6
    finally:
        if not args.keep:
            shutil.rmtree(scratch, ignore_errors=True)
    print(f"\nK14R real 0.2.57 round trip: {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
