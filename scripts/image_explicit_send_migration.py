"""Explicit r11 description-only migration: generated images are sent explicitly, 2026-09-25.

generate_image no longer sends its image to the user after the turn; the model
shares it with send_document_to_chat. The Gemini generate_image description
(the only variant present in any frozen capture) swaps its auto-send sentence
for the explicit-send sentence. One exact sentence swap, nothing else.

Never rewrites a frozen reference or normalizes prompt text. Wire replaces the
exact old sentence on the reviewed captures (after r10); lifecycle restores the
old sentence on the candidate before the existing r10→r3 comparisons. Both
inventories are asserted against fixtures/chat-wire/image-explicit-send-r1.json.
"""
import base64
import copy
import json
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/image-explicit-send-r1.json').read_text())
WIRE_NAMES = set(RULE['wire_fixtures'])
LIFECYCLE_NAMES = set(RULE['lifecycle_captures'])


def escaped(text):
    # Foundation encodes literal slash as \/; edits are byte replaces inside the JSON string.
    return json.dumps(text, ensure_ascii=False).replace('/', '\\/')[1:-1].encode()


BEFORE = escaped(RULE['sentence_before'])
AFTER = escaped(RULE['sentence_after'])
# Distinctive to each sentence; neither sentence contains the other's marker.
NEW_MARKER = escaped('it is not sent to the user automatically')
OLD_MARKER = escaped('will be sent to the user in the chat')
# The swap must land inside the Gemini generate_image description, between
# its fixed neighbours, never anywhere else in the body.
CONTEXT_BEFORE = escaped('restyle, or use an image as inspiration. ')
CONTEXT_AFTER = escaped(' Provide source_image when the user refers to a specific prior image;')


def swap(body):
    if (body.count(BEFORE) != 1 or NEW_MARKER in body
            or body.count(CONTEXT_BEFORE + BEFORE + CONTEXT_AFTER) != 1):
        raise RuntimeError('Expected the pre-r11 generate_image sentence exactly once, in place, and no r11 sentence')
    return body.replace(BEFORE, AFTER, 1)


def unswap(body):
    if (body.count(AFTER) != 1 or body.count(NEW_MARKER) != 1 or OLD_MARKER in body
            or body.count(CONTEXT_BEFORE + AFTER + CONTEXT_AFTER) != 1):
        raise RuntimeError('Expected the r11 generate_image sentence exactly once, in place, and no pre-r11 sentence')
    return body.replace(AFTER, BEFORE, 1)


def migrate_wire_fixtures(fixtures):
    if not WIRE_NAMES.issubset(fixtures):
        raise RuntimeError('Image explicit-send wire inventory changed')
    result = copy.deepcopy(fixtures)
    for name, item in result.items():
        body = base64.b64decode(item['body_base64'], validate=True)
        if name in WIRE_NAMES:
            body = swap(body)
        elif OLD_MARKER in body or NEW_MARKER in body:
            raise RuntimeError(f'{name}: generate_image sentence on an unreviewed wire capture')
        item['body_base64'] = base64.b64encode(body).decode()
    return result


def reverse_candidate(actual):
    result = copy.deepcopy(actual)
    names = [c['fixture'] for c in result['captures']]
    if len(names) != len(set(names)) or not LIFECYCLE_NAMES.issubset(names):
        raise RuntimeError('Image explicit-send lifecycle inventory changed')
    for capture in result['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        if capture['fixture'] in LIFECYCLE_NAMES:
            body = unswap(body)
        elif NEW_MARKER in body or OLD_MARKER in body:
            raise RuntimeError(f"{capture['fixture']}: generate_image sentence on an unreviewed lifecycle capture")
        capture['body'] = base64.b64encode(body).decode()
    return result


def verify_migration(expected, actual, compare):
    from agents_md_migration import verify_migration as verify_r10
    verify_r10(expected, reverse_candidate(actual), compare)
