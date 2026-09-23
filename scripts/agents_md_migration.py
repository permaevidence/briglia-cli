"""Explicit r10 prompt-only migration: the AGENTS.md bullet, 2026-09-23.

The tools prompt's project-instruction bullet now describes the root-to-nearest
chain (nearer file wins) and asks the agent to keep AGENTS.md current and to
offer one where a project has none. One exact bullet swap, nothing else.

Never rewrites a frozen reference or normalizes prompt text. Wire replaces the
exact old bullet on the reviewed captures (after r9); lifecycle restores the
old bullet on the candidate before the existing r9→r3 comparisons. Both
inventories are asserted against fixtures/chat-wire/agents-md-r1.json.
"""
import base64
import copy
import json
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/agents-md-r1.json').read_text())
WIRE_NAMES = set(RULE['wire_fixtures'])
LIFECYCLE_NAMES = set(RULE['lifecycle_captures'])


def escaped(text):
    # Foundation encodes literal slash as \/; edits are byte replaces inside the JSON string.
    return json.dumps(text, ensure_ascii=False).replace('/', '\\/')[1:-1].encode()


BEFORE = escaped(RULE['bullet_before'])
AFTER = escaped(RULE['bullet_after'])
# Distinctive to the new bullet only; the old bullet never contains it.
NEW_MARKER = escaped('the one nearer your work wins')
OLD_MARKER = escaped('the first time you touch a project; follow them for all work in that project.')


def swap(body):
    if body.count(BEFORE) != 1 or AFTER in body or NEW_MARKER in body:
        raise RuntimeError('Expected the pre-r10 AGENTS.md bullet exactly once and no r10 bullet')
    return body.replace(BEFORE, AFTER, 1)


def unswap(body):
    if body.count(AFTER) != 1 or body.count(NEW_MARKER) != 1 or OLD_MARKER in body:
        raise RuntimeError('Expected the r10 AGENTS.md bullet exactly once and no pre-r10 bullet')
    return body.replace(AFTER, BEFORE, 1)


def migrate_wire_fixtures(fixtures):
    if not WIRE_NAMES.issubset(fixtures):
        raise RuntimeError('AGENTS.md wire inventory changed')
    result = copy.deepcopy(fixtures)
    for name, item in result.items():
        body = base64.b64decode(item['body_base64'], validate=True)
        if name in WIRE_NAMES:
            body = swap(body)
        elif OLD_MARKER in body or NEW_MARKER in body:
            raise RuntimeError(f'{name}: AGENTS.md bullet on an unreviewed wire capture')
        item['body_base64'] = base64.b64encode(body).decode()
    return result


def reverse_candidate(actual):
    result = copy.deepcopy(actual)
    names = [c['fixture'] for c in result['captures']]
    if len(names) != len(set(names)) or not LIFECYCLE_NAMES.issubset(names):
        raise RuntimeError('AGENTS.md lifecycle inventory changed')
    for capture in result['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        if capture['fixture'] in LIFECYCLE_NAMES:
            body = unswap(body)
        elif NEW_MARKER in body or OLD_MARKER in body:
            raise RuntimeError(f"{capture['fixture']}: AGENTS.md bullet on an unreviewed lifecycle capture")
        capture['body'] = base64.b64encode(body).decode()
    return result


def verify_migration(expected, actual, compare):
    from harness_identity_migration import verify_migration as verify_r9
    verify_r9(expected, reverse_candidate(actual), compare)
