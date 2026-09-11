"""r5: the newest historical tool turn is no longer protected from pruning (v0.2.19).

Applied to the candidate before the r4/r3 checks. In the frozen driver the
'recent' turn is now pruned wherever the budget needs it, so five prune
scenarios change and five summary requests appear or change. Their exact
expected values are pinned in fixtures/chat-lifecycle/newest-turn-protection-r5.json
(observations platform-neutral; request bodies templated on the one formatted
manifest date, taken from the same run's over-prunable-0 request). Two new
snapshots shift the deterministic serials of the later r3 scenarios; the shift
is verified exactly and reversed. Everything else stays byte-compared.
"""
import base64
import copy
import json
import re
from pathlib import Path
from active_compaction_lifecycle_migration import verify_migration as verify_r4
from prune_lifecycle_migration import SCENARIOS as R3_SCENARIOS, reference, text

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle/newest-turn-protection-r5.json').read_text())
PINNED = RULE['observations']
SHIFT = {int(k): v for k, v in RULE['serial_shift'].items()}
PLACEHOLDER = RULE['date_placeholder'].encode()
DATE_RE = re.compile(RULE['date_pattern'])


def manifest_date(captures):
    body = base64.b64decode(next(c for c in captures if c['fixture'] == 'over-prunable-0')['body']).decode()
    found = DATE_RE.findall(body)
    if len(found) != 1:
        raise RuntimeError('r5: over-prunable-0 manifest date not found exactly once')
    return found[0]


def r3_shape(item, serial):
    """The additive r3 form of a pinned-source prune result (what r3 verifies)."""
    ref = reference(serial)
    result = copy.deepcopy(item)
    for key in ['snapshot', 'durable']:
        anchors = [m for m in result[key] if m.get('prunedContextSummary')]
        if len(anchors) != 1:
            raise RuntimeError('r5: expected one summary anchor in the pinned-source result')
        anchors[0]['pruneArchiveReferences'] = [ref]
        if 'measuredTokens' in anchors[0]:
            anchors[0]['measuredTokens'] += len(text(ref)) // 4
    result['rawConversation'] = base64.b64encode(json.dumps(result['durable']).encode()).decode()
    return result


def unshift(value, old_serial):
    new_ref, old_ref = reference(SHIFT[old_serial]), reference(old_serial)
    if value == new_ref:
        return old_ref
    raise RuntimeError(f'r5: expected snapshot serial {SHIFT[old_serial]}, found {value}')


def verify_migration(expected, actual, compare):
    restored = copy.deepcopy(actual)
    date = manifest_date(actual['captures'])
    if date != manifest_date(expected['captures']):
        raise RuntimeError('r5: candidate and reference format the manifest date differently')
    headers = next(c for c in actual['captures'] if c['fixture'] == 'over-prunable-0')['headers']
    expected_captures = {c['fixture']: c for c in expected['captures']}
    actual_names = [c['fixture'] for c in actual['captures']]
    restored['captures'] = []
    for capture in actual['captures']:
        name = capture['fixture']
        pinned = RULE['captures'].get(name)
        if pinned is None:
            restored['captures'].append(capture)
            continue
        template = base64.b64decode(pinned['body_template_base64'])
        if template.count(PLACEHOLDER) != pinned['date_occurrences']:
            raise RuntimeError(f'r5: {name} template corrupted')
        body = template.replace(PLACEHOLDER, date.encode())
        compare({'body': base64.b64encode(body).decode(), 'headers': headers, 'method': pinned['method'], 'target': pinned['target']},
                {k: capture[k] for k in ('body', 'headers', 'method', 'target')}, f'r5.{name}')
        if name in expected_captures:
            restored['captures'].append(expected_captures[name])  # changed body: the pinned-source request stands in
        # a new request (no pinned-source counterpart) is dropped from the comparison
    for name in RULE['captures']:
        if name not in actual_names:
            raise RuntimeError(f'r5: {name} request missing')
    for name, pinned in PINNED.items():
        compare(pinned, actual['observations'][name], f'r5.{name}')
        if name in R3_SCENARIOS:
            restored['observations'][name] = r3_shape(expected['observations'][name], R3_SCENARIOS.index(name) + 1)
        else:
            restored['observations'][name] = expected['observations'][name]
    for old_serial, name in enumerate(R3_SCENARIOS, 1):
        if name in PINNED or old_serial not in SHIFT:
            continue
        item = restored['observations'][name]
        for key in ['snapshot', 'durable']:
            refs = [m for m in item[key] if m.get('pruneArchiveReferences')]
            if len(refs) != 1 or len(refs[0]['pruneArchiveReferences']) != 1:
                raise RuntimeError(f'r5: {name}.{key} expected exactly one snapshot reference')
            refs[0]['pruneArchiveReferences'] = [unshift(refs[0]['pruneArchiveReferences'][0], old_serial)]
        raw = json.loads(base64.b64decode(item['rawConversation'], validate=True))
        refs = [m for m in raw if m.get('pruneArchiveReferences')]
        if len(refs) != 1 or len(refs[0]['pruneArchiveReferences']) != 1:
            raise RuntimeError(f'r5: {name}.rawConversation expected exactly one snapshot reference')
        refs[0]['pruneArchiveReferences'] = [unshift(refs[0]['pruneArchiveReferences'][0], old_serial)]
        item['rawConversation'] = base64.b64encode(json.dumps(raw).encode()).decode()
    old_entries = expected['observations']['persistence']['mindEntries']
    files = ['prune-archives/' + reference(s)['basename'] for s in range(1, 14)]
    compare(sorted(old_entries + ['prune-archives/'] + files), actual['observations']['persistence']['mindEntries'], 'r5.mindEntries')
    restored['observations']['persistence']['mindEntries'] = sorted(
        old_entries + ['prune-archives/'] + ['prune-archives/' + reference(s)['basename'] for s in range(1, 12)])
    verify_r4(expected, restored, compare)
