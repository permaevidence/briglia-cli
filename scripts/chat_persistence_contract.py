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
import cm_split_paths as cmp

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/persistence-contract.json'
SNAPSHOT_MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/prune-persistence-contract.json'
ACTIVE_MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/active-compaction-persistence-contract.json'
IMAGE_MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/image-schema-persistence-contract.json'
P2_MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/responses-persistence-contract.json'
CHRONOLOGY_MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/chronology-persistence-contract.json'
WEB_SUBAGENT_MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/web-subagent-persistence-contract.json'
ORPROVIDER_MANIFEST = ROOT / 'scripts/fixtures/chat-lifecycle/orprovider-persistence-contract.json'
FILES = ['TelegramConcierge/Models/Message.swift', 'TelegramConcierge/Models/ToolModels.swift',
         'TelegramConcierge/Services/HarnessAnnotations.swift']
REGIONS = {
    cmp.MAIN:
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
        if path == cmp.MAIN:
            result[path + '#declaration'] = hashlib.sha256(cm_segment(read).encode()).hexdigest()
            continue
        text = read(path).decode()
        if text.count(start) != 1 or text.count(end) != 1:
            raise RuntimeError('Persisted declaration anchor changed: ' + path)
        segment = text[text.index(start):text.index(end)]
        if not segment: raise RuntimeError('Reordered persisted declaration: ' + path)
        result[path + '#declaration'] = hashlib.sha256(segment.encode()).hexdigest()
    return result


def _present(read, path):
    try:
        read(path)
        return True
    except (FileNotFoundError, KeyError):
        return False


def cm_segment(read):
    """The ContextUsageSnapshot..ToolAwareResponse region of the main ConversationManager file.

    0.2.59 split (plan v3 §6.1, D5): both declarations stay in the main file and
    may be promoted (`private ` deleted). Each anchor is accepted in its base or
    promoted spelling, independently; duplicate variants of one anchor, a second
    occurrence, reversed anchors or the region outside the main file fail. When
    the start anchor is promoted, `    private ` is restored at the segment's first
    line before hashing. No other byte is normalised."""
    start_variants = ('    private struct ContextUsageSnapshot: Codable {', '    struct ContextUsageSnapshot: Codable {')
    end_variants = ('    private struct ToolAwareResponse {', '    struct ToolAwareResponse {')
    others = [p for p in cmp.ALL_SPLIT_PATHS if _present(read, p)]
    for p in others:
        text = read(p).decode()
        for v in start_variants + end_variants:
            if _count(text, v):
                raise RuntimeError('Persisted declaration anchor outside the main ConversationManager file: ' + p)
    text = read(cmp.MAIN).decode()
    found = []
    for variants, label in ((start_variants, 'start'), (end_variants, 'end')):
        hits = [(v, i) for v in variants for i in _positions(text, v)]
        if len(hits) != 1:
            raise RuntimeError(f'Persisted declaration anchor changed ({label}: {len(hits)} occurrences across both spellings): ' + cmp.MAIN)
        found.append(hits[0])
    (sv, si), (ev, ei) = found
    if ei <= si:
        raise RuntimeError('Reordered persisted declaration: ' + cmp.MAIN)
    segment = text[si:ei]
    if sv == start_variants[1]:
        segment = start_variants[0] + segment[len(sv):]
    return segment


def _positions(text, needle):
    """Every occurrence (anywhere, as before the split); each must also start a line."""
    out, i = [], text.find(needle)
    while i >= 0:
        if i and text[i - 1] != '\n':
            raise RuntimeError('Persisted declaration anchor not at a line start: ' + needle.strip())
        out.append(i)
        i = text.find(needle, i + 1)
    return out


def _count(text, needle):
    return text.count(needle)

def verify(root=ROOT):
    from chat_wire_baseline import SOURCE
    frozen = json.loads(MANIFEST.read_text())
    if frozen['source'] != SOURCE:
        raise RuntimeError('Persistence contract SOURCE changed: independent rebaseline required')
    current = digest(lambda path: (root / path).read_bytes())
    # P0 remains immutable. P2's additive optional fields have a separate exact
    # candidate manifest, reviewed with the P2 implementation, never a rewritten
    # baseline. Raw no-Responses fixture bytes must still match the old binary.
    for manifest in (P2_MANIFEST, SNAPSHOT_MANIFEST, ACTIVE_MANIFEST, IMAGE_MANIFEST, CHRONOLOGY_MANIFEST, WEB_SUBAGENT_MANIFEST, ORPROVIDER_MANIFEST):
        if current != frozen['sha256'] and manifest.exists():
            additive = json.loads(manifest.read_text())
            if additive.get('source') == SOURCE and current == additive.get('sha256'):
                return
    if current != frozen['sha256']:
        changed = [k for k in current if current[k] != frozen['sha256'].get(k)]
        raise RuntimeError('Persisted model contract changed (nil fields count): ' + ', '.join(changed))

if __name__ == '__main__':
    verify()
    print('Persisted model source contract PASS')
