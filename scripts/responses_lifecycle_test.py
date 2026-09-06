#!/usr/bin/env python3
"""Exercise Responses through real owners in an isolated, instrumented build.

Only UserDefaults storage and private test entrypoints are instrumented. The
request/render/parser/manager/subagent implementations come from the candidate.
No live credential is read by this runner. --keep-tree retains the binary for a
separately authorized, bounded live run with credentials supplied over stdin.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import chat_wire_baseline as wire

ROOT = wire.ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch-root', type=Path)
    parser.add_argument('--keep-tree', action='store_true')
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='briglia-responses-lifecycle-'))
    tree = root / 'candidate'
    wire.command(['git', 'worktree', 'add', '--detach', str(tree), 'HEAD'])
    try:
        diff = subprocess.check_output(['git', 'diff', 'HEAD', '--binary'], cwd=ROOT)
        if diff:
            wire.command(['git', 'apply', '--binary', '-'], cwd=tree, input=diff)
        untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z', '--', 'TelegramConcierge'], cwd=ROOT)
        for raw in untracked.split(b'\0'):
            if raw:
                name = os.fsdecode(raw)
                (tree / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, tree / name, follow_symlinks=False)
        # P3's standard session_id header contains an underscore. Extend only
        # this disposable parser; the frozen P0 capture/parser files stay intact.
        capture_parser = tree / 'TelegramConcierge/CLI/CaptureRequestParser.swift'
        capture_text = capture_parser.read_text()
        header_anchor = '(48...57).contains($0) || $0 == 45'
        assert capture_text.count(header_anchor) == 1
        capture_parser.write_text(capture_text.replace(header_anchor, header_anchor + ' || $0 == 95'))
        fixture = ROOT / 'scripts/fixtures/responses'
        shutil.copyfile(fixture / 'Driver.swift', tree / 'TelegramConcierge/CLI/ResponsesLifecycleSelftest.swift')
        manager = tree / 'TelegramConcierge/Services/ConversationManager.swift'
        text = manager.read_text()
        anchor = '    private func persistResponsesSalvage(_ interactions: [ToolInteraction]) throws {'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '\n        try P2Life.beforeSalvage(turnSalvageFileURL)')
        anchor = '    private func saveConversation() -> Bool {'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '\n        P2Life.beforeConversationSave(conversationFileURL, messages: messages)')
        anchor = '    private func sendText(_ text: String, to address: ChannelAddress? = nil) async throws {'
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor + '\n        if P2Life.captureDelivery { P2Life.deliveries.append(text); return }')
        manager.write_text(text + (fixture / 'ManagerSeam.swift').read_text())
        archive = tree / 'TelegramConcierge/Services/ConversationArchiveService.swift'
        archive.write_text(archive.read_text() + (fixture / 'ArchiveSeam.swift').read_text())
        main = tree / 'TelegramConcierge/CLI/AdaMain.swift'
        text = main.read_text()
        anchor = 'ResponsesSelftest.self,'
        if text.count(anchor) != 1:
            raise RuntimeError('test registration anchor moved')
        main.write_text(text.replace(anchor, anchor + ' ResponsesLifecycleSelftest.self,'))
        for source in (tree / 'TelegramConcierge').rglob('*.swift'):
            if 'selftest' in source.name.lower(): continue
            text = source.read_text().replace('UserDefaults.standard', 'P2Life.defaults')
            text = text.replace('UserDefaults = .standard', 'UserDefaults = P2Life.defaults')
            source.write_text(text)
        # Live mode adds only mechanical test budgets and a read-only tool
        # allowlist. Offline lifecycle exercises the full unchanged send path.
        adapter = tree / 'TelegramConcierge/Services/ResponsesAdapter.swift'
        text = adapter.read_text()
        anchor = '        var request = try request(input: input, tools: tools, maxOutputTokens: maxOutputTokens)'
        assert text.count(anchor) == 1
        text = text.replace(anchor, '        let maxOutputTokens = P2Life.liveMode ? 1024 : maxOutputTokens\n' + anchor)
        anchor = '                let bytes = try await ResponsesHTTPTransport().send('
        assert text.count(anchor) == 1
        text = text.replace(anchor, '                try P2Life.claimLiveRequest()\n' + anchor)
        text = text.replace('.send(request, overallTimeout: request.timeoutInterval, subscription: context.subscriptionGeneration != nil)', '.send(P2Life.route(request), overallTimeout: request.timeoutInterval, subscription: context.subscriptionGeneration != nil)')
        anchor = '        if let error = context.configurationError { throw ResponsesFailure.malformed(error) }'
        assert text.count(anchor) == 1
        text = text.replace(anchor, '        P2Life.recordContext(context)\n' + anchor)
        adapter.write_text(text)
        renderer = tree / 'TelegramConcierge/Services/OpenRouterService+Responses.swift'
        text = renderer.read_text()
        anchor = 'tools: conversation.tools, receipt: receipt'
        assert text.count(anchor) == 1
        renderer.write_text(text.replace(anchor, 'tools: P2Life.liveMode ? conversation.tools?.filter { $0.function.name == "read_file" } : conversation.tools, receipt: receipt'))
        scratch = args.scratch_root or root / 'build'
        # Large batches of legacy diagnostics can stall macOS SwiftPM's output
        # regex. Production/CI builds still report warnings; this disposable
        # instrumented build suppresses warnings only, never compiler errors.
        wire.command(['swift', 'build', '-Xswiftc', '-suppress-warnings', '--scratch-path', str(scratch)], cwd=tree)
        binarydir = subprocess.check_output(['swift', 'build', '--scratch-path', str(scratch), '--show-bin-path'], cwd=tree, text=True).strip()
        binary = Path(binarydir) / 'briglia'
        print('Instrumented binary: ' + str(binary), flush=True)
        wire.command([str(binary), '__responses-lifecycle-selftest', '--output', str(root / 'fixtures')], cwd=tree, timeout=180)
        print('Responses real-owner lifecycle PASS', flush=True)
    finally:
        if args.keep_tree:
            print('Retained test tree: ' + str(tree), flush=True)
        else:
            subprocess.run(['git', 'worktree', 'remove', '--force', str(tree)], cwd=ROOT, check=False)
            shutil.rmtree(root, ignore_errors=True)


if __name__ == '__main__':
    main()
