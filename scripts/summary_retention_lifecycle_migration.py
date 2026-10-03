"""r13: past-turn summary retention, Part B (2026-10-02).

Applied to the CANDIDATE before every earlier rule. A prune that appends a
summary now records `prunedContextSummaryCoverage` on its anchor: persisted
bookkeeping only, never rendered and never sent. The frozen driver keeps at
most three summary anchors, so no anchor is demoted. For each reviewed
scenario (fixtures/chat-lifecycle/summary-retention-r13.json) exactly one
valid coverage object is removed from the durable and snapshot views and,
by exact byte removal of the key and its value, from rawConversation; the
three copies must be equal and sit on the message holding the summary.
Nothing else may carry the new keys: no capture (request) carries a
coverage or demotion key, and no observation carries demotedPruneSummaries.
"""
import base64
import copy
import json
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle/summary-retention-r13.json').read_text())
KEY = RULE['key']
RAW_KEY = ('"' + KEY + '":').encode()
REQUEST_KEYS = [b'prunedContextSummaryCoverage', b'demotedPruneSummaries', b'startOffsetSeconds', b'endOffsetSeconds']
FIELDS = {'version', 'start', 'startOffsetSeconds', 'end', 'endOffsetSeconds', 'complete', 'files'}


def valid(coverage, what):
    if not isinstance(coverage, dict) or set(coverage) != FIELDS or coverage['version'] != 1:
        raise RuntimeError(f'r13: {what}: malformed coverage {coverage!r}')
    if not isinstance(coverage['complete'], bool) or not isinstance(coverage['files'], list) or len(coverage['files']) > 20 \
            or not all(isinstance(f, str) for f in coverage['files']) or coverage['start'] > coverage['end'] \
            or abs(coverage['startOffsetSeconds']) > 50400 or abs(coverage['endOffsetSeconds']) > 50400:
        raise RuntimeError(f'r13: {what}: invalid coverage {coverage!r}')
    return coverage


def strip_view(messages, what):
    holders = [m for m in messages if isinstance(m, dict) and KEY in m]
    if len(holders) != RULE['per_view']:
        raise RuntimeError(f'r13: {what}: expected {RULE["per_view"]} coverage object(s), found {len(holders)}')
    holder = holders[0]
    if not holder.get('prunedContextSummary'):
        raise RuntimeError(f'r13: {what}: coverage on a message without a prune summary')
    coverage = valid(holder.pop(KEY), what)
    return coverage


def strip_raw(raw, what):
    if raw.count(RAW_KEY) != 1:
        raise RuntimeError(f'r13: {what}: expected the coverage key exactly once in the saved file')
    i = raw.index(RAW_KEY)
    text = raw.decode()
    start = len(raw[:i + len(RAW_KEY)].decode())
    value, end_char = json.JSONDecoder().raw_decode(text, start)
    end = len(text[:end_char].encode())
    if raw[end:end + 1] == b',':
        stripped = raw[:i] + raw[end + 1:]
    elif raw[i - 1:i] == b',':
        stripped = raw[:i - 1] + raw[end:]
    else:
        raise RuntimeError(f'r13: {what}: unexpected layout around the coverage key')
    json.loads(stripped)
    return stripped, valid(value, what)


def contains_new_keys(value):
    if isinstance(value, dict):
        return 'demotedPruneSummaries' in value or any(contains_new_keys(v) for v in value.values())
    if isinstance(value, list):
        return any(contains_new_keys(v) for v in value)
    return False


def migrate_candidate(actual):
    """Remove exactly the reviewed coverage objects from the candidate."""
    result = copy.deepcopy(actual)
    for capture in result['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        if any(k in body for k in REQUEST_KEYS):
            raise RuntimeError(f"r13: {capture['fixture']}: a request carries a coverage or demotion field")
    observations = result['observations']
    for name, item in observations.items():
        if contains_new_keys(item):
            raise RuntimeError(f'r13: {name}: an anchor was demoted in a frozen scenario')
        raw = item.get('rawConversation') if isinstance(item, dict) else None
        if isinstance(raw, str) and b'demotedPruneSummaries' in base64.b64decode(raw, validate=True):
            raise RuntimeError(f'r13: {name}.rawConversation: an anchor was demoted in a frozen scenario')
    for name in RULE['scenarios']:
        item = observations[name]
        copies = [strip_view(item[view], f'{name}.{view}') for view in RULE['views']]
        stripped, raw_coverage = strip_raw(base64.b64decode(item['rawConversation'], validate=True), f'{name}.rawConversation')
        if any(c != raw_coverage for c in copies):
            raise RuntimeError(f'r13: {name}: the coverage copies differ')
        item['rawConversation'] = base64.b64encode(stripped).decode()
    for name, item in observations.items():
        if name in RULE['scenarios']:
            continue
        for view in RULE['views']:
            if isinstance(item, dict) and isinstance(item.get(view), list) and any(isinstance(m, dict) and KEY in m for m in item[view]):
                raise RuntimeError(f'r13: {name}.{view}: coverage in an unreviewed scenario')
        raw = item.get('rawConversation') if isinstance(item, dict) else None
        if isinstance(raw, str) and RAW_KEY in base64.b64decode(raw, validate=True):
            raise RuntimeError(f'r13: {name}.rawConversation: coverage in an unreviewed scenario')
    return result
