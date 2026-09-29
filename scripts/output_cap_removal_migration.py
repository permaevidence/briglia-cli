"""Single reviewed wire change (r12): no output-token caps, 2026-09-29.

The only frozen request that carried a cap is the lifecycle setup probe
(probe-0, `"max_tokens":10`). Applied to the pinned-SOURCE lifecycle
captures before comparison (outermost, after r3-r11): that capture loses
exactly the one byte sequence; every other capture must carry no cap field
at all and passes through unchanged, still compared byte for byte. No
re-serialisation. The chat-wire fixtures carry no cap and need no rule.
"""
import base64
import copy
import json
import re
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/output-cap-removal-r1.json').read_text())
REMOVED = RULE['removed'].encode()
CAPTURES = set(RULE['lifecycle_captures'])
CAP_FIELD = re.compile(rb'"(max_tokens|max_completion_tokens|max_output_tokens)"\s*:')


def migrate_body(body, carrier):
    json.loads(body)  # the body must be a JSON request; no re-serialisation
    if carrier:
        if body.count(REMOVED) != RULE['max_occurrences_per_request']:
            raise RuntimeError('Expected the setup probe cap exactly once in the pinned request')
        body = body.replace(REMOVED, b'')
    if CAP_FIELD.search(body):
        raise RuntimeError('Output-token cap field on an unreviewed or already-migrated capture')
    return body


def migrate_lifecycle(fixtures):
    result = copy.deepcopy(fixtures)
    names = [c['fixture'] for c in result['captures']]
    if len(names) != len(set(names)) or not CAPTURES.issubset(names):
        raise RuntimeError('Output-cap removal lifecycle inventory changed')
    for item in result['captures']:
        body = base64.b64decode(item['body'], validate=True)
        item['body'] = base64.b64encode(migrate_body(body, item['fixture'] in CAPTURES)).decode()
    return result


def verify_candidate(actual):
    """The candidate never sends a cap, on any capture."""
    for item in actual['captures']:
        if CAP_FIELD.search(base64.b64decode(item['body'], validate=True)):
            raise RuntimeError(f"{item['fixture']}: candidate sent an output-token cap")
    return actual
