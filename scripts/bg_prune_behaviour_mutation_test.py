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
import shutil
import subprocess
import tempfile
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cm_split_paths as cmp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# ConversationManager: one file before 0.2.59, a 15-file family after. Every
# mutation anchor must occur exactly once across the family
# (cm_split_paths.replace_once); the whole family is restored after each case.
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
    ("R1: convergence without the post-send engagement check", "round2",
     '''            // A completed OFF during the send await ends all ON work: the
            // original error surfaces exactly as OFF (Codex impl R1).
            guard backgroundPruneEngaged else {
                bgPruneLog("bgprune.converge.disengaged", requestKey)
                throw error
            }
            let ledgerKey''',
     '''            let ledgerKey'''),
    ("R2a: direct inline paths not claiming the shared allowance", "round2",
     '''        guard used & 1 == 0 else {
            bgPruneLog("bgprune.admit.overceiling", key)
            return false
        }
        backgroundPruneRequestLedger[ledgerKey] = used | 1
        return true''',
     '''        if used & 1 != 0, key.hasPrefix("round1") == false { bgPruneLog("bgprune.admit.overceiling", key); return false }
        backgroundPruneRequestLedger[ledgerKey] = used | 1
        return true'''),
    ("R2b: forced final keyed apart from the request M prepared", "round2",
     '''        guard let runId, let next = backgroundPruneNextRound[runId.uuidString] else { return "final" }
        return "round\\(next)"''',
     '''        _ = runId
        return "final"'''),
    ("R2-2: ON bookkeeping after a successful resend despite a completed OFF", "round2",
     [('''            let response = try await resend()
            // A successful resend is returned as is; a completed OFF during
            // the resend (or the identity lookup) skips the ON bookkeeping
            // (Codex impl round 2, R2-2).
            guard backgroundPruneEngaged else {
                bgPruneLog("bgprune.converge.resent-disengaged", requestKey)
                return response
            }
            let identity = await bgPruneIdentity(execution)
            guard backgroundPruneEngaged else {
                bgPruneLog("bgprune.converge.resent-disengaged", requestKey)
                return response
            }''', '''            let response = try await resend()
            let identity = await bgPruneIdentity(execution)''')], None),
    # Codex impl round 3, R3-3: the new release cases must catch these.
    ("apply without its evidence gate", "release3",
     '''        do { try settleJobEvidenceBeforeRemoval(of: job.source.filter { manifest.contains($0.id) }) }
        catch { outcome = .abandoned("evidence"); return (outcome, [:]) }''',
     '''        _ = manifest'''),
    ("forced-final convergence rebuild dropping the refusal suffix", "release3",
     '''                                finalForceInteractions = toolInteractions + Array(finalForceInteractions.dropFirst(bgPruneFinalBase))
                                bgPruneFinalBase = toolInteractions.count
                            }
                            return bgPruneChanged
                        },
                        resend: {
                            prevRoundPromptTokens = nil; self.lastPromptTokens = nil; previousPromptScope = nil
                            return try await bgPruneFinalSend()''',
     '''                                finalForceInteractions = toolInteractions
                                bgPruneFinalBase = toolInteractions.count
                            }
                            return bgPruneChanged
                        },
                        resend: {
                            prevRoundPromptTokens = nil; self.lastPromptTokens = nil; previousPromptScope = nil
                            return try await bgPruneFinalSend()'''),
]


# Codex impl round 4: these breaks must fail their intended invariant
# assertion (the failing "✖" line must match), not merely fail for an
# unrelated reason such as a timing flake elsewhere in the section.
EXPECT = {
    "R2-2: ON bookkeeping after a successful resend despite a completed OFF":
        "R2-2 OFF during the held successful resend",
    "apply without its evidence gate": "§8.3 evidence gate (ON)",
    "forced-final convergence rebuild dropping the refusal suffix":
        "B4b(i) suffix after both rebuilds",
}


def build():
    proc = subprocess.run(["swift", "build", "--build-system", "native"], cwd=ROOT, capture_output=True, text=True)
    return proc.returncode == 0, proc.stdout[-3000:] + proc.stderr[-3000:]


def run_section(section, timeout):
    start = time.time()
    try:
        # Isolated config/data roots (the live Briglia is never touched).
        root = tempfile.mkdtemp(prefix="bgprune-breaks-")
        env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(root, "config"), XDG_DATA_HOME=os.path.join(root, "data"))
        try:
            proc = subprocess.run([BINARY, "__background-prune-selftest", "--only", section],
                                  cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)
        finally:
            shutil.rmtree(root, ignore_errors=True)
        failed = [l for l in proc.stdout.splitlines() if l.startswith("✖")]
        return proc.returncode, failed, time.time() - start
    except subprocess.TimeoutExpired:
        subprocess.run(["pkill", "-f", "__background-prune-selftest"])
        return "timeout", [], time.time() - start


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    args = ap.parse_args()
    originals = {p: open(os.path.join(ROOT, p), encoding="utf-8").read() for p in cmp.cm_paths(ROOT)}
    original = "".join(originals.values())

    def restore():
        for p, text in originals.items():
            with open(os.path.join(ROOT, p), "w", encoding="utf-8") as fh:
                fh.write(text)
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
            restore()
            for o, n in pairs:
                cmp.replace_once(ROOT, o, n)
            ok, log = build()
            if not ok:
                print(f"✖ {label}: mutated build failed\n{log}")
                continue
            code, failed, seconds = run_section(section, 300 if section == "release3" else 150)
            want = EXPECT.get(label)
            if code != 0 and want and not any(want in f for f in failed):
                print(f"✖ break caught for the wrong reason: {label} [{section}] — expected a failed "
                      f"'{want}' assertion, got {failed[:3] or code}")
            elif code != 0:
                caught += 1
                why = "hang past the timeout" if code == "timeout" else (failed[0] if failed else f"exit {code}")
                tag = " (intended assertion)" if want else ""
                print(f"✔ break caught{tag}: {label} [{section}] — {why[:160]} ({seconds:.0f}s)")
            else:
                print(f"✖ break NOT caught: {label} [{section}]")
    finally:
        restore()
        ok, log = build()
        restored = all(open(os.path.join(ROOT, p), encoding="utf-8").read() == text for p, text in originals.items())
        print(f"restored source {'identical' if restored else 'DIFFERS'}; rebuild {'ok' if ok else 'FAILED'}")
    print(f"\n{caught}/{total} deliberate behaviour breaks caught")
    return 0 if caught == total else 1


if __name__ == "__main__":
    sys.exit(main())
