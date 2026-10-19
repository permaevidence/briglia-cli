#!/usr/bin/env python3
"""Deliberate behaviour breaks for background pruning (BACKGROUND_PRUNE_PLAN
v4.1 §16.9): each one is applied to the ON code, the binary is rebuilt, and
the named `__background-prune-selftest` section must FAIL (a non-zero exit
or a hang past the section timeout both count as caught). The original
source is restored after every case and verified byte-identical at the end.

Local, slow (one incremental build per break). Not run in CI.

Usage: bg_prune_behaviour_mutation_test.py [--only NAME]
"""
import argparse
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CM = os.path.join(ROOT, "TelegramConcierge/Services/ConversationManager.swift")
BINARY = os.path.join(ROOT, ".build/debug/briglia")

BREAKS = [
    ("guard by id only (no bytes)", "freeze",
     '''            guard let liveBytes = try? encoder.encode(live), let frozenBytes = try? encoder.encode(frozen[index]),
                  liveBytes == frozenBytes else { return "bytes" }''',
     '''            _ = live'''),
    ("guard without order check", "freeze",
     '''        guard Array(liveIDs.prefix(frozen.count)) == frozen.map(\\.id) else { return "order" }''',
     '''        _ = liveIDs'''),
    ("worker saving descriptions", "descriptions",
     '''                record.generated = descriptions
                overlay.merge(descriptions) { current, _ in current }''',
     '''                record.generated = descriptions
                await FileDescriptionService.shared.saveMultiple(descriptions)
                overlay.merge(descriptions) { current, _ in current }'''),
    ("worker without the overlay (two requests for a repeated file)", "descriptions",
     '''                guard seen.insert(file.filename).inserted, overlay[file.filename] == nil else { continue }''',
     '''                guard seen.insert(file.filename).inserted else { continue }'''),
    ("cancelled/retired worker treated as ready", "lifecycle",
     '''        if job.isRunning, !job.revoked, backgroundPruneGeneration == generation, result.summary != .cancelled {''',
     '''        if !job.revoked, backgroundPruneGeneration == generation {'''),
    ("no deadline (watchdog never fires)", "ceiling",
     '''            self?.bgPruneDeadlineFired(jobId: jobId)''',
     '''            _ = jobId'''),
    ("R returns without its inline block", "converge",
     '''        let changed = try await inline()
        return .inlineHandled(changed: changed || applied)''',
     '''        let changed = false
        return .inlineHandled(changed: changed || applied)'''),
    ("failure not falling back (no owed decision)", "ceiling",
     '''            backgroundPruneFallbackDue = true
            bgPruneLog("bgprune.fallback-owed.\\(reason.rawValue)")''',
     '''            bgPruneLog("bgprune.fallback-owed.\\(reason.rawValue)")'''),
    ("OFF without the drain wait (phase change taken as termination)", "lifecycle",
     '''        let released = await bgPruneAwaitSlotReleased(job, timeout: Self.bgPruneDrainSecondsForTesting ?? 5)''',
     '''        let released = true'''),
    ("convergence out of band", "converge",
     '''            guard let runId, admittedEstimate > admittedMaximum, !(error is CancellationError),''',
     '''            guard let runId, !(error is CancellationError),'''),
    ("freeze allowed at or over the ceiling", "ceiling",
     '''        guard totalTokens < limits.ceiling else { return ineligible("at-ceiling") }''',
     '''        _ = limits.ceiling'''),
    ("T0 apply without token resets (apply and T0 resets both removed)", "freeze",
     [('''        lastPromptTokens = nil
        lastCompletionTokens = nil
        bgPruneLog("bgprune.applied", "\\(replacements.count) message(s) rewritten")''',
       '''        bgPruneLog("bgprune.applied", "\\(replacements.count) message(s) rewritten")'''),
      ('''        if result.outcome == .applied {
            lastPromptTokens = nil
            lastCompletionTokens = nil
            backgroundPruneT0AppliedRun = runId''',
       '''        if result.outcome == .applied {
            backgroundPruneT0AppliedRun = runId''')], None),
    ("worker activity ended at OFF instead of at termination", "lifecycle",
     '''        if job.isRunning {
            job.phase = .retiring(.off)
            job.worker?.cancel()''',
     '''        if job.isRunning {
            job.phase = .retiring(.off)
            if let activity = job.activityId { endMaintenance(activity); job.activityId = nil }
            job.worker?.cancel()'''),
    ("restart allowed with a live worker", "freeze",
     '''        backgroundPruneJob?.isBusy == true''',
     '''        backgroundPruneJob?.isBusy == nil'''),
    ("/stop not cancelling the worker", "lifecycle",
     '''            job.phase = .retiring(.stop)
            job.worker?.cancel()''',
     '''            _ = job.worker'''),
    ("apply not re-checking revocation after the lookup", "lifecycle",
     '''                guard stillAuthorized() else { outcome = refusal(); return (outcome, [:]) }
                guard !fill.isEmpty else { continue }''',
     '''                guard !fill.isEmpty else { continue }'''),
    ("inline archive starting while a job runs", "archive",
     '''        return "background prune running"''',
     '''        _ = "background prune running"'''),
]


def build():
    proc = subprocess.run(["swift", "build", "--build-system", "native"], cwd=ROOT, capture_output=True, text=True)
    return proc.returncode == 0, proc.stdout[-3000:] + proc.stderr[-3000:]


def run_section(section, timeout):
    start = time.time()
    try:
        proc = subprocess.run([BINARY, "__background-prune-selftest", "--only", section],
                              cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        failed = [l for l in proc.stdout.splitlines() if l.startswith("✖")]
        return proc.returncode, failed, time.time() - start
    except subprocess.TimeoutExpired:
        subprocess.run(["pkill", "-f", "__background-prune-selftest"])
        return "timeout", [], time.time() - start


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    args = ap.parse_args()
    with open(CM, encoding="utf-8") as fh:
        original = fh.read()
    caught = 0
    total = 0
    try:
        for label, section, old, new in BREAKS:
            if args.only and args.only not in label:
                continue
            total += 1
            pairs = old if isinstance(old, list) else [(old, new)]
            if any(original.count(o) != 1 for o, _ in pairs):
                print(f"✖ {label}: mutation anchor not found exactly once")
                continue
            mutated = original
            for o, n in pairs:
                mutated = mutated.replace(o, n)
            with open(CM, "w", encoding="utf-8") as fh:
                fh.write(mutated)
            ok, log = build()
            if not ok:
                print(f"✖ {label}: mutated build failed\n{log}")
                continue
            code, failed, seconds = run_section(section, 150)
            if code != 0:
                caught += 1
                why = "hang past the timeout" if code == "timeout" else (failed[0] if failed else f"exit {code}")
                print(f"✔ break caught: {label} [{section}] — {why[:160]} ({seconds:.0f}s)")
            else:
                print(f"✖ break NOT caught: {label} [{section}]")
    finally:
        with open(CM, "w", encoding="utf-8") as fh:
            fh.write(original)
        ok, log = build()
        with open(CM, encoding="utf-8") as fh:
            restored = fh.read() == original
        print(f"restored source {'identical' if restored else 'DIFFERS'}; rebuild {'ok' if ok else 'FAILED'}")
    print(f"\n{caught}/{total} deliberate behaviour breaks caught")
    return 0 if caught == total else 1


if __name__ == "__main__":
    sys.exit(main())
