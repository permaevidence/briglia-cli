"""Reviewed r2 -> r3 snapshot additions; the original r2 evidence stays immutable.

Every request byte still compares exactly. Only 11 prune results (22 visible
arrays plus their saved JSON) gain the specified typed reference and token cost.
The Mind inventory gains exactly those 11 files and their folder. For saved
arrays whose schema changed, Foundation may reorder object keys; compare the
entire decoded value to the exact expected additive value. Unchanged saved
files remain byte-compared by the ordinary comparator.
"""
import base64
import copy
import json

SCENARIOS = ['over-prunable', 'exhausted-after-prune', 'unsent-delta', 'estimated',
             'automatic-prune', 'manual', 'reasoning-only', 'media-prune',
             'synthetic-prune', 'large-reasoning', 'summary-tools-refused']
ROOT = '/tmp/briglia-chat-lifecycle-v1/data/briglia/'


def reference(serial):
    identity = f'00000000-0000-4000-9000-{serial:012d}'
    name = '2023-11-14_221320Z_' + identity.replace('-', '') + '.txt'
    return {'id': identity, 'basename': name, 'version': 1}


def text(ref):
    return (f'Full context before this pruning: `{ROOT}prune-archives/{ref["basename"]}`\n'
            'This folder contains up to the latest 300 conversation snapshots, with filenames sortable chronologically.')


def verify_migration(expected, actual, compare):
    """Refuse every difference except the enumerated r3 additions."""
    restored = copy.deepcopy(actual)
    files = []
    for serial, name in enumerate(SCENARIOS, 1):
        ref = reference(serial)
        files.append('prune-archives/' + ref['basename'])
        old = expected['observations'][name]
        new = actual['observations'][name]
        target = restored['observations'][name]
        for key in ['snapshot', 'durable']:
            candidate = copy.deepcopy(old[key])
            anchors = [i for i, m in enumerate(candidate) if m.get('prunedContextSummary')]
            if len(anchors) != 1:
                raise RuntimeError(f'r3 {name}: expected one pre-existing summary anchor')
            anchor = candidate[anchors[0]]
            anchor['pruneArchiveReferences'] = [ref]
            if 'measuredTokens' in anchor:
                anchor['measuredTokens'] += len(text(ref)) // 4
            compare(candidate, new[key], f'r3.{name}.{key}')
            target[key] = old[key]
        old_raw = json.loads(base64.b64decode(old['rawConversation'], validate=True))
        new_raw = json.loads(base64.b64decode(new['rawConversation'], validate=True))
        # Same complete array value as the verified durable message observation.
        compare(old['durable'], old_raw, f'r3.{name}.oldRaw')
        compare(new['durable'], new_raw, f'r3.{name}.newRaw')
        target['rawConversation'] = old['rawConversation']
    expected_entries = sorted(expected['observations']['persistence']['mindEntries'] + ['prune-archives/'] + files)
    compare(expected_entries, actual['observations']['persistence']['mindEntries'], 'r3.mindEntries')
    restored['observations']['persistence']['mindEntries'] = expected['observations']['persistence']['mindEntries']
    compare(expected, restored)
