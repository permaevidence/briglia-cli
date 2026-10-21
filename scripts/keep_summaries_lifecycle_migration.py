"""r14: /keepsummaries (2026-10-21, KEEP_SUMMARIES_PLAN v5).

Applied to the CANDIDATE before r13. Every prune commit now prepares a
pointer ("stub") for each summary anchor that lacks a usable one:
`prunedContextSummaryStub` on the anchor (persisted bookkeeping, never
rendered and never sent; a request shows the pointer only when the anchor
is outside the newest N, and the frozen driver never holds more than three
anchors). For every message of the durable and snapshot views and of the raw
saved file: a message carrying a live `prunedContextSummary` must carry
exactly one valid stub whose digest is the SHA-256 of that summary; a message
without one must carry none. The stubs are removed (rawConversation by exact
byte removal of the key and its value) and everything else is compared by
the earlier rules unchanged (a Mind export's listing loses the stub
snapshot files). No capture (request) may carry a stub key, and
no observation may carry a demotion record.

Each stub snapshot draws one value from the driver's deterministic snapshot
serial (00000000-0000-4000-9000-NNNNNNNNNNNN). Those serials are identified
from the stubs themselves; after the stubs are removed they must appear
nowhere else, and every later serial in the candidate (views, saved files,
request bodies) is renumbered down by the number of stub serials drawn
before it, which is exactly the sequence the pinned release drew. The usage
snapshot's new `lastPromptRenderKey` must be the empty-set key (nothing is
ever composed as a pointer in a frozen scenario) and is removed by exact byte
removal.
"""
import base64
import bisect
import copy
import hashlib
import json
import re

KEY = 'prunedContextSummaryStub'
RAW_KEY = ('"' + KEY + '":').encode()
REQUEST_KEYS = [KEY.encode(), b'summaryDigest']
VIEWS = ('durable', 'snapshot')
SERIAL_UUID = re.compile(rb'00000000-0000-4000-9000-(\d{12})')
SERIAL_COMPACT = re.compile(rb'00000000000040009000(\d{12})')
EMPTY_KEY = 'keepsummaries:none'
USAGE_KEY = b'"lastPromptRenderKey":'

RECORD_FIELDS = {'version', 'line', 'snapshot'}


def valid_stub(stub, summary, what):
    if not isinstance(stub, dict) or set(stub) != {'version', 'summaryDigest', 'record'} or stub['version'] != 1:
        raise RuntimeError(f'r14: {what}: malformed stub {stub!r}')
    if stub['summaryDigest'] != hashlib.sha256(summary.encode()).hexdigest():
        raise RuntimeError(f'r14: {what}: stub digest does not match the live summary')
    record = stub['record']
    if not isinstance(record, dict) or not RECORD_FIELDS.issubset(record) or set(record) - RECORD_FIELDS - {'coverage'} \
            or record['version'] != 1 or not isinstance(record['line'], str) or not record['line'] \
            or not isinstance(record['snapshot'], dict) or not str(record['snapshot'].get('basename', '')).endswith('.txt'):
        raise RuntimeError(f'r14: {what}: malformed stub record {record!r}')
    return stub


def strip_message(message, what):
    """Pops and validates the stub of one decoded message; returns it or None."""
    if not isinstance(message, dict):
        return None
    summary = message.get('prunedContextSummary')
    if isinstance(summary, str) and summary:
        if KEY not in message:
            raise RuntimeError(f'r14: {what}: an anchor without its pointer')
        return valid_stub(message.pop(KEY), summary, what)
    if KEY in message:
        raise RuntimeError(f'r14: {what}: a pointer on a message without a live summary')
    return None


def strip_raw(raw, what):
    """Removes every stub key and value by exact byte removal; returns the
    stripped bytes and the decoded stubs in file order."""
    stubs = []
    while RAW_KEY in raw:
        i = raw.index(RAW_KEY)
        text = raw.decode()
        start = len(raw[:i + len(RAW_KEY)].decode())
        value, end_char = json.JSONDecoder().raw_decode(text, start)
        end = len(text[:end_char].encode())
        if raw[end:end + 1] == b',':
            raw = raw[:i] + raw[end + 1:]
        elif raw[i - 1:i] == b',':
            raw = raw[:i - 1] + raw[end:]
        else:
            raise RuntimeError(f'r14: {what}: unexpected layout around the stub key')
        stubs.append(value)
    decoded = json.loads(raw)
    return raw, stubs, decoded


def contains_demotion(value):
    if isinstance(value, dict):
        return 'demotedPruneSummaries' in value or any(contains_demotion(v) for v in value.values())
    if isinstance(value, list):
        return any(contains_demotion(v) for v in value)
    return False


def serial_of(snapshot, what):
    match = SERIAL_UUID.fullmatch(str(snapshot.get('id', '')).encode())
    if not match:
        raise RuntimeError(f'r14: {what}: stub snapshot id outside the driver serial')
    return int(match.group(1))


def renumber_bytes(data, stub_serials):
    def shift(match, width_prefix):
        n = int(match.group(1))
        if n in stub_serials:
            raise RuntimeError(f'r14: stub snapshot serial {n} still referenced after its stub was removed')
        return width_prefix + b'%012d' % (n - bisect.bisect_left(stub_serials, n))
    data = SERIAL_UUID.sub(lambda m: shift(m, b'00000000-0000-4000-9000-'), data)
    return SERIAL_COMPACT.sub(lambda m: shift(m, b'00000000000040009000'), data)


def renumber(value, stub_serials, raw=False):
    if isinstance(value, dict):
        return {k: renumber(v, stub_serials, raw=k.startswith('raw') or k in ('body', 'usage', 'conversation', 'pending')) for k, v in value.items()}
    if isinstance(value, list):
        return [renumber(v, stub_serials) for v in value]
    if isinstance(value, str):
        if raw:
            try:
                data = base64.b64decode(value, validate=True)
            except Exception:
                return renumber_bytes(value.encode(), stub_serials).decode()
            return base64.b64encode(renumber_bytes(data, stub_serials)).decode()
        return renumber_bytes(value.encode(), stub_serials).decode()
    return value


def strip_usage(raw, what):
    if USAGE_KEY not in raw:
        return raw
    if raw.count(USAGE_KEY) != 1:
        raise RuntimeError(f'r14: {what}: more than one render key')
    i = raw.index(USAGE_KEY)
    text = raw.decode()
    start = len(raw[:i + len(USAGE_KEY)].decode())
    value, end_char = json.JSONDecoder().raw_decode(text, start)
    if value != EMPTY_KEY:
        raise RuntimeError(f'r14: {what}: a usage measurement under a pointer composition ({value!r})')
    end = len(text[:end_char].encode())
    if raw[end:end + 1] == b',':
        return raw[:i] + raw[end + 1:]
    if raw[i - 1:i] == b',':
        return raw[:i - 1] + raw[end:]
    raise RuntimeError(f'r14: {what}: unexpected layout around the render key')


def migrate_candidate(actual):
    """Remove exactly the validated stubs from the candidate, then undo the
    stub snapshots' serial draws."""
    result = copy.deepcopy(actual)
    stub_serials = set()
    for capture in result['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        if any(k in body for k in REQUEST_KEYS):
            raise RuntimeError(f"r14: {capture['fixture']}: a request carries a stub field")
    for name, item in result['observations'].items():
        if not isinstance(item, dict):
            continue
        if contains_demotion(item):
            raise RuntimeError(f'r14: {name}: a demotion record in a frozen scenario')
        for view in VIEWS:
            if isinstance(item.get(view), list):
                for index, message in enumerate(item[view]):
                    stub = strip_message(message, f'{name}.{view}[{index}]')
                    if stub is not None:
                        stub_serials.add(serial_of(stub['record']['snapshot'], f'{name}.{view}[{index}]'))
        for usage_key in ('rawUsage', 'usage'):
            usage = item.get(usage_key)
            if isinstance(usage, str):
                item[usage_key] = base64.b64encode(strip_usage(base64.b64decode(usage, validate=True), f'{name}.{usage_key}')).decode()
        for conversation_key in ('rawConversation', 'conversation'):
            raw = item.get(conversation_key)
            if not isinstance(raw, str):
                continue
            where = f'{name}.{conversation_key}'
            data = base64.b64decode(raw, validate=True)
            if RAW_KEY in data:
                stripped, stubs, decoded = strip_raw(data, where)
                anchors = [m for m in decoded if isinstance(m, dict) and isinstance(m.get('prunedContextSummary'), str) and m['prunedContextSummary']]
                if len(anchors) != len(stubs):
                    raise RuntimeError(f'r14: {where}: {len(stubs)} stub(s) for {len(anchors)} anchor(s)')
                for k, (anchor, stub) in enumerate(zip(anchors, stubs)):
                    valid_stub(stub, anchor['prunedContextSummary'], f'{where}[{k}]')
                    stub_serials.add(serial_of(stub['record']['snapshot'], f'{where}[{k}]'))
                item[conversation_key] = base64.b64encode(stripped).decode()
            elif b'"prunedContextSummary":' in data:
                decoded = json.loads(data)
                if any(isinstance(m, dict) and m.get('prunedContextSummary') for m in decoded):
                    raise RuntimeError(f'r14: {where}: an anchor without its pointer')
    # A Mind export lists every snapshot file: the stub snapshots' entries go
    # with their stubs (the serials are known; the files hold nothing else).
    stub_entries = {'prune-archives/2023-11-14_221320Z_00000000000040009000%012d.txt' % n for n in stub_serials}
    persistence = result['observations'].get('persistence')
    if isinstance(persistence, dict) and isinstance(persistence.get('mindEntries'), list):
        persistence['mindEntries'] = [e for e in persistence['mindEntries'] if e not in stub_entries]
    return renumber(result, sorted(stub_serials))
