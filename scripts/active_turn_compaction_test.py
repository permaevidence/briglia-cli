#!/usr/bin/env python3
"""Real main-loop compaction checks in disposable roots, with negative controls."""
import argparse
import sys
import os
from pathlib import Path
import subprocess
import tempfile
import chat_wire_baseline as wire
import cm_split_paths as cmp

# Pinned-tree builds on Linux compile with 2 jobs: 4 parallel frontends of the
# large ConversationManager were OOM-killed (exit 137) on the 16 GB runner.
LINUX_JOBS = ["-j", "2"] if sys.platform.startswith("linux") else []

ROOT = wire.ROOT
CM_DEFAULTS = 13  # UserDefaults.standard accesses across the ConversationManager family
parser = argparse.ArgumentParser()
parser.add_argument('--reuse', type=Path)
args = parser.parse_args()
root = args.reuse or Path(tempfile.mkdtemp(prefix='briglia-active-owner-'))
tree = root / 'candidate'
if not tree.exists():
    wire.command(['git', 'worktree', 'add', '--detach', str(tree), 'HEAD'])
assert 'briglia-active-owner-' in str(root)
# Construct complete desired source before writing, so a diagnostic rerun only
# recompiles changed files. All instrumentation stays in this disposable tree.
sources = {str(p.relative_to(ROOT)): p.read_text() for p in (ROOT / 'TelegramConcierge').rglob('*.swift')}
fixture = ROOT / 'scripts/fixtures/active-compaction'
sources['TelegramConcierge/CLI/ActiveCompactionOwnerSelftest.swift'] = (fixture / 'Driver.swift').read_text()
# ConversationManager: one file on pinned releases, the 15-file family from
# 0.2.59. Seams are appended to the main file; each of the 8 CM anchors must
# occur exactly once across the family (cm_split_paths.replace_once_in).
cm_main = cmp.main_key()
sources[cm_main] = sources[cm_main] + (fixture / 'ManagerSeam.swift').read_text() + (fixture / 'SummaryBoundsSeam.swift').read_text()
anchor = '        let activity = beginMaintenance(.pruning)\n        defer { endMaintenance(activity) }\n        let budget = ActiveTurnBudget'
cmp.replace_once_in(sources, anchor, '        if CompactionTestInputs.disableCompaction { throw PruneArchiveStore.Failure("negative control: old exhaustion") }\n' + anchor)
cmp.replace_once_in(sources, '        activeTurnCheckpoints[runID] = candidate\n        pendingCompactionCalibration',
    '        CompactionTestInputs.noteCompaction()\n        activeTurnCheckpoints[runID] = candidate\n        pendingCompactionCalibration')
cmp.replace_once_in(sources, '        let contextIDs = Set([original.taskMessageID] + original.deliveredUserMessageIDs)',
    '        if let hook = CompactionTestInputs.maintenanceHook { CompactionTestInputs.maintenanceHook = nil; await hook(self) }\n        let contextIDs = Set([original.taskMessageID] + original.deliveredUserMessageIDs)')
cmp.replace_once_in(sources, '               estimate.fixedTextTokens > configuredMaxContextTokens() {',
    '               (CompactionTestInputs.conservativeStartGate ? estimate.tokens : estimate.fixedTextTokens) > configuredMaxContextTokens() {')
cmp.replace_once_in(sources, '            totalTokens += noteTokens(committed) - noteTokens(plannedSource)',
    '            if !CompactionTestInputs.omitPruneNotes { totalTokens += noteTokens(committed) - noteTokens(plannedSource) }')
cmp.replace_once_in(sources, '        guard after < before, after <= budget.maximum else {',
    '        guard after < before, after <= (CompactionTestInputs.oldCeilingGate ? budget.inputCeiling : budget.maximum) else {')
anchor = '        for message in messagesForLLM {\n            if message.role == .assistant'
cmp.replace_once_in(sources, anchor, '        for (i, message) in messagesForLLM.enumerated() {\n            if (!CompactionTestInputs.protectNewestTurn || i != lastAssistantIndexWithTools(in: messagesForLLM, mandatoryTokens: mandatoryEstimate.tokens)) && message.role == .assistant')
anchor = '                    messages: finalHistory,'
cmp.replace_once_in(sources, anchor, '                    messages: CompactionTestInputs.unprojectedFinal ? messagesForLLM : finalHistory,')
key = 'TelegramConcierge/CLI/AffinitySelftest.swift'
sources[key] = sources[key].replace('        let body = scripted ?? (status == 200',
    '        let body = CompactionTestInputs.dynamicReply(completeRequests.last!) ?? scripted ?? (status == 200')
key = 'TelegramConcierge/Services/ActiveTurnCompaction.swift'
sources[key] = sources[key].replace('        for id in carriedDeliveredUserMessageIDs where !existing.contains(id) {',
    '        for id in carriedDeliveredUserMessageIDs where !existing.contains(id) && !CompactionTestInputs.omitCarried {')
key = 'TelegramConcierge/Utilities/PrivateStorage.swift'
# Instrument only replaceContents (the atomic replace); writeExclusive shares
# some lines but has no temp file. The phased post-rename path repeats the
# directory barrier, so that anchor is seamed on both paths.
full = sources[key]
lo = full.index('    private static func replaceContents(')
hi = full.index('\n    }\n', lo) + len('\n    }\n')
s = full[lo:hi]
for anchor, phase, cleanup, n in [
    ('        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in', 'write', 'close(fd); unlink(tmp.path); ', 1),
    ('        if failure == nil, fsync(fd) != 0 {', 'fsync', 'close(fd); unlink(tmp.path); ', 1),
    ('        guard rename(tmp.path, target) == 0 else {', 'rename', 'unlink(tmp.path); ', 1),
    ('        try fsyncDirectory(dir.path)', 'directory-fsync', '', 2)]:
    assert s.count(anchor) == n, (anchor, s.count(anchor))
    s = s.replace(anchor, '        do { try CompactionTestInputs.checkpointFault(target, phase: "' + phase + '") } catch { ' + cleanup + 'throw error }\n' + anchor)
sources[key] = full[:lo] + s + full[hi:]
key = 'TelegramConcierge/CLI/AdaMain.swift'
s = sources[key]; assert s.count('PruneArchiveSelftest.self,') == 1
sources[key] = s.replace('PruneArchiveSelftest.self,', 'PruneArchiveSelftest.self, ActiveCompactionOwnerSelftest.self,')
family = set(cmp.cm_keys(sources))
cmp.replace_all_counted_in(sources, 'UserDefaults.standard', 'CompactionTestInputs.defaults', CM_DEFAULTS)
cmp.replace_all_counted_in(sources, 'UserDefaults = .standard', 'UserDefaults = CompactionTestInputs.defaults', 0)
for name, s in sources.items():
    if 'selftest' not in Path(name).name.lower() and name not in family:
        s = s.replace('UserDefaults.standard', 'CompactionTestInputs.defaults').replace('UserDefaults = .standard', 'UserDefaults = CompactionTestInputs.defaults')
    p = tree / name; p.parent.mkdir(parents=True, exist_ok=True)
    if not p.exists() or p.read_text() != s: p.write_text(s)
print('Active compaction evidence:', root, flush=True)
build = Path('/tmp/briglia-active-owner-scratch')
wire.command(['swift', 'build', *LINUX_JOBS, '--scratch-path', str(build)], cwd=tree)
binary = Path(subprocess.check_output(['swift', 'build', '--scratch-path', str(build), '--show-bin-path'], cwd=tree, text=True).strip()) / 'briglia'
wire.command([str(binary), '__active-compaction-owner-selftest'], cwd=tree, timeout=480)
for control in ['--disable-compaction', '--omit-carried', '--conservative-start-gate', '--omit-prune-notes', '--unprojected-final', '--old-ceiling-gate', '--protect-newest-turn']:
    result = subprocess.run([str(binary), '__active-compaction-owner-selftest', control], cwd=tree, capture_output=True, text=True, timeout=240)
    (root / (control[2:] + '.log')).write_text(result.stdout + result.stderr)
    if result.returncode == 0: raise RuntimeError('Negative control unexpectedly passed: ' + control)
    expected = {'--disable-compaction': 'same turn completes three compactions', '--omit-carried': 'verbatim user role after compaction', '--conservative-start-gate': 'media-heavy history runs without a measurement', '--omit-prune-notes': 'manual prune report includes committed summary and reference delta', '--unprojected-final': 'forced final answer keeps compaction summary and verbatim correction', '--old-ceiling-gate': 'irreducible context above the ceiling continues after compaction', '--protect-newest-turn': 'previous turn is pruned before the current turn is compacted'}[control]
    if expected not in result.stdout + result.stderr: raise RuntimeError('Negative control failed for unrelated reason: ' + control)
    print('PASS negative control', control, flush=True)
