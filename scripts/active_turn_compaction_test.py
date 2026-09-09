#!/usr/bin/env python3
"""Real main-loop compaction checks in disposable roots, with negative controls."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import chat_wire_baseline as wire

ROOT = wire.ROOT
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
key = 'TelegramConcierge/Services/ConversationManager.swift'
s = sources[key] + (fixture / 'ManagerSeam.swift').read_text()
anchor = '        let activity = beginMaintenance(.pruning)\n        defer { endMaintenance(activity) }\n        let budget = ActiveTurnBudget'
assert s.count(anchor) == 1
sources[key] = s.replace(anchor, '        if CompactionTestInputs.disableCompaction { throw PruneArchiveStore.Failure("negative control: old exhaustion") }\n' + anchor)
sources[key] = sources[key].replace('        activeTurnCheckpoints[runID] = candidate\n        pendingCompactionCalibration',
    '        CompactionTestInputs.noteCompaction()\n        activeTurnCheckpoints[runID] = candidate\n        pendingCompactionCalibration')
sources[key] = sources[key].replace('        let contextIDs = Set([original.taskMessageID] + original.deliveredUserMessageIDs)',
    '        if let hook = CompactionTestInputs.maintenanceHook { CompactionTestInputs.maintenanceHook = nil; await hook(self) }\n        let contextIDs = Set([original.taskMessageID] + original.deliveredUserMessageIDs)')
sources[key] = sources[key].replace('               estimate.fixedTextTokens > configuredMaxContextTokens() {',
    '               (CompactionTestInputs.conservativeStartGate ? estimate.tokens : estimate.fixedTextTokens) > configuredMaxContextTokens() {')
sources[key] = sources[key].replace('            totalTokens += noteTokens(committed) - noteTokens(plannedSource)',
    '            if !CompactionTestInputs.omitPruneNotes { totalTokens += noteTokens(committed) - noteTokens(plannedSource) }')
anchor = '                    messages: finalHistory,'
assert sources[key].count(anchor) == 1
sources[key] = sources[key].replace(anchor, '                    messages: CompactionTestInputs.unprojectedFinal ? messagesForLLM : finalHistory,')
key = 'TelegramConcierge/CLI/AffinitySelftest.swift'
sources[key] = sources[key].replace('        let body = scripted ?? (status == 200',
    '        let body = CompactionTestInputs.dynamicReply(completeRequests.last!) ?? scripted ?? (status == 200')
key = 'TelegramConcierge/Services/ActiveTurnCompaction.swift'
sources[key] = sources[key].replace('        for id in carriedDeliveredUserMessageIDs where !existing.contains(id) {',
    '        for id in carriedDeliveredUserMessageIDs where !existing.contains(id) && !CompactionTestInputs.omitCarried {')
key = 'TelegramConcierge/Utilities/PrivateStorage.swift'
s = sources[key]
for anchor, phase, cleanup in [
    ('        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in', 'write', 'close(fd); unlink(tmp.path); '),
    ('        if failure == nil, fsync(fd) != 0 {', 'fsync', 'close(fd); unlink(tmp.path); '),
    ('        guard rename(tmp.path, target) == 0 else {', 'rename', 'unlink(tmp.path); '),
    ('        try fsyncDirectory(dir.path)', 'directory-fsync', '')]:
    assert s.count(anchor) == 1
    s = s.replace(anchor, '        do { try CompactionTestInputs.checkpointFault(target, phase: "' + phase + '") } catch { ' + cleanup + 'throw error }\n' + anchor)
sources[key] = s
key = 'TelegramConcierge/CLI/AdaMain.swift'
s = sources[key]; assert s.count('PruneArchiveSelftest.self,') == 1
sources[key] = s.replace('PruneArchiveSelftest.self,', 'PruneArchiveSelftest.self, ActiveCompactionOwnerSelftest.self,')
for name, s in sources.items():
    if 'selftest' not in Path(name).name.lower():
        s = s.replace('UserDefaults.standard', 'CompactionTestInputs.defaults').replace('UserDefaults = .standard', 'UserDefaults = CompactionTestInputs.defaults')
    p = tree / name; p.parent.mkdir(parents=True, exist_ok=True)
    if not p.exists() or p.read_text() != s: p.write_text(s)
print('Active compaction evidence:', root, flush=True)
build = Path('/tmp/briglia-active-owner-scratch')
wire.command(['swift', 'build', '--scratch-path', str(build)], cwd=tree)
binary = Path(subprocess.check_output(['swift', 'build', '--scratch-path', str(build), '--show-bin-path'], cwd=tree, text=True).strip()) / 'briglia'
wire.command([str(binary), '__active-compaction-owner-selftest'], cwd=tree, timeout=240)
for control in ['--disable-compaction', '--omit-carried', '--conservative-start-gate', '--omit-prune-notes', '--unprojected-final']:
    result = subprocess.run([str(binary), '__active-compaction-owner-selftest', control], cwd=tree, capture_output=True, text=True, timeout=240)
    (root / (control[2:] + '.log')).write_text(result.stdout + result.stderr)
    if result.returncode == 0: raise RuntimeError('Negative control unexpectedly passed: ' + control)
    expected = {'--disable-compaction': 'same turn completes three compactions', '--omit-carried': 'verbatim user role after compaction', '--conservative-start-gate': 'media-heavy history runs without a measurement', '--omit-prune-notes': 'manual prune report includes committed summary and reference delta', '--unprojected-final': 'forced final answer keeps compaction summary and verbatim correction'}[control]
    if expected not in result.stdout + result.stderr: raise RuntimeError('Negative control failed for unrelated reason: ' + control)
    print('PASS negative control', control, flush=True)
