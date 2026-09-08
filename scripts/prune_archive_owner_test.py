#!/usr/bin/env python3
"""Private-owner snapshot transactions in a disposable build; no live state."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import chat_wire_baseline as wire

ROOT = wire.ROOT
root = Path(tempfile.mkdtemp(prefix='briglia-snapshot-owner-build-'))
tree = root / 'candidate'
wire.command(['git', 'worktree', 'add', '--detach', str(tree), 'HEAD'])
try:
    patch = subprocess.check_output(['git', 'diff', 'HEAD', '--binary'], cwd=ROOT)
    if patch: wire.command(['git', 'apply', '--binary', '-'], cwd=tree, input=patch)
    for raw in subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z', '--', 'TelegramConcierge'], cwd=ROOT).split(b'\0'):
        if raw:
            name = os.fsdecode(raw); (tree / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, tree / name, follow_symlinks=False)
    fixture = ROOT / 'scripts/fixtures/prune-archives'
    shutil.copyfile(fixture / 'Driver.swift', tree / 'TelegramConcierge/CLI/SnapshotOwnerSelftest.swift')
    for source, seam in [('ConversationManager.swift', 'ManagerSeam.swift'), ('ConversationArchiveService.swift', 'ArchiveSeam.swift')]:
        path = tree / 'TelegramConcierge/Services' / source
        path.write_text(path.read_text() + (fixture / seam).read_text())
    main = tree / 'TelegramConcierge/CLI/AdaMain.swift'
    source = main.read_text(); assert source.count('PruneArchiveSelftest.self,') == 1
    main.write_text(source.replace('PruneArchiveSelftest.self,', 'PruneArchiveSelftest.self, SnapshotOwnerSelftest.self,'))
    for path in (tree / 'TelegramConcierge').rglob('*.swift'):
        if 'selftest' in path.name.lower(): continue
        s = path.read_text().replace('UserDefaults.standard', 'SnapshotOwnerInputs.defaults').replace('UserDefaults = .standard', 'UserDefaults = SnapshotOwnerInputs.defaults')
        path.write_text(s)
    build = Path('/tmp/briglia-snapshot-owner-scratch')
    wire.command(['swift', 'build', '--scratch-path', str(build)], cwd=tree)
    binary = Path(subprocess.check_output(['swift', 'build', '--scratch-path', str(build), '--show-bin-path'], cwd=tree, text=True).strip()) / 'briglia'
    output = root / 'exports'
    wire.command([str(binary), '__snapshot-owner-selftest', '--output', str(output)], cwd=tree, timeout=180)
    count = (output / 'count.txt').read_text().strip()
    for scope in ['full', 'lite']:
        wire.command([str(binary), '__snapshot-owner-selftest', '--import-archive', str(output / (scope + '.mind')), '--expected-count', count], cwd=tree, timeout=180)
finally:
    print('Snapshot owner evidence:', root, flush=True)
    # Keep the isolated source/binary for failure diagnosis. No live credentials.
