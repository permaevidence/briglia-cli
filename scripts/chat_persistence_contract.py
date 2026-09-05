#!/usr/bin/env python3
"""P0/P1 source guard for persisted models, including absent optional fields.

Deliberately conservative: changes to these declarations (even comments or an
extraction) require independent review of the contract manifest. Raw persisted
fixtures separately cover writer behavior; this is not a universal Swift parser.
"""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/persistence-contract.json'
P2_MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/responses-persistence-contract.json'
FILES = ['TelegramConcierge/Models/Message.swift', 'TelegramConcierge/Models/ToolModels.swift',
         'TelegramConcierge/Services/HarnessAnnotations.swift']
REGIONS = {
    'TelegramConcierge/Services/ConversationManager.swift':
        ('    private struct ContextUsageSnapshot: Codable {', '    private struct ToolAwareResponse {'),
    'TelegramConcierge/Services/SubagentSessionRegistry.swift':
        ('    struct Session: Codable {', '    private var sessions: [String: Session] = [:]'),
    'TelegramConcierge/Services/OpenRouterService.swift':
        ('struct ToolInteraction: Codable {', '// MARK: - Request Models'),
}

def digest(read):
    result = {}
    for path in FILES:
        result[path] = hashlib.sha256(read(path)).hexdigest()
    for path, (start, end) in REGIONS.items():
        text = read(path).decode()
        if text.count(start) != 1 or text.count(end) != 1:
            raise RuntimeError('Persisted declaration anchor changed: ' + path)
        segment = text[text.index(start):text.index(end)]
        if not segment: raise RuntimeError('Reordered persisted declaration: ' + path)
        result[path + '#declaration'] = hashlib.sha256(segment.encode()).hexdigest()
    return result

def verify(root=ROOT):
    from chat_wire_baseline import SOURCE
    frozen = json.loads(MANIFEST.read_text())
    if frozen['source'] != SOURCE:
        raise RuntimeError('Persistence contract SOURCE changed: independent rebaseline required')
    current = digest(lambda path: (root / path).read_bytes())
    # P0 remains immutable. P2's additive optional fields have a separate exact
    # candidate manifest, reviewed with the P2 implementation, never a rewritten
    # baseline. Raw no-Responses fixture bytes must still match the old binary.
    if current != frozen['sha256'] and P2_MANIFEST.exists():
        additive = json.loads(P2_MANIFEST.read_text())
        if additive.get('source') == SOURCE and current == additive.get('sha256'):
            return
    if current != frozen['sha256']:
        changed = [k for k in current if current[k] != frozen['sha256'].get(k)]
        raise RuntimeError('Persisted model contract changed (nil fields count): ' + ', '.join(changed))

if __name__ == '__main__':
    verify()
    print('Persisted model source contract PASS')
