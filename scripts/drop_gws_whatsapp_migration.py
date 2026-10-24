"""Explicit wire r12 / lifecycle drop-gws-wa migration: gws and the WhatsApp bridge removed, 2026-10-24.

Three exact byte edits, each with its own fail-closed inventory
(fixtures/chat-wire/drop-gws-whatsapp-r1.json):

1. bullet            the gws guidance bullet line disappears with the provider
                     (the shared drivers store provider "gws", which reads as
                     none on a build without gws);
2. reminder_auth     manage_reminders' check-script text drops "gws login";
3. document_channel  send_document_to_chat drops " (Telegram or WhatsApp)".

Never rewrites a frozen reference or normalizes prompt text. Wire applies the
edits forward on the reviewed captures (after r11); lifecycle reverses them on
the CANDIDATE before the existing r14→r3 chain. Every listed capture must hold
the edit's text exactly once (in its fixed neighbour context); every unlisted
capture must hold neither the old nor the new marker.
"""
import base64
import copy
import json
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/drop-gws-whatsapp-r1.json').read_text())
EDITS = ('bullet', 'reminder_auth', 'document_channel')


def escaped(text):
    # Foundation encodes literal slash as \/; edits are byte replaces inside the JSON string.
    return json.dumps(text, ensure_ascii=False).replace('/', '\\/')[1:-1].encode()


BEFORE = {k: escaped(RULE['edits'][k]['before']) for k in EDITS}
AFTER = {k: escaped(RULE['edits'][k]['after']) for k in EDITS}
# Markers that identify each form; neither form contains the other's marker.
OLD_MARKER = {'bullet': escaped('Use `gws` for Google Workspace actions.'),
              'reminder_auth': escaped('gws login'),
              'document_channel': escaped('(Telegram or WhatsApp)')}
NEW_MARKER = {'bullet': None,   # "should know about.\n" is not distinctive on its own
              'reminder_auth': escaped('(gh auth, config files)'),
              'document_channel': escaped('currently messaging from. Use when')}


def forward(body, edit):
    if body.count(BEFORE[edit]) != 1 or body.count(OLD_MARKER[edit]) != 1 or (
            NEW_MARKER[edit] is not None and NEW_MARKER[edit] in body):
        raise RuntimeError(f'Expected the pre-r12 {edit} text exactly once, in place, and no r12 text')
    return body.replace(BEFORE[edit], AFTER[edit], 1)


def reverse(body, edit):
    if body.count(AFTER[edit]) != 1 or OLD_MARKER[edit] in body or (
            NEW_MARKER[edit] is not None and body.count(NEW_MARKER[edit]) != 1):
        raise RuntimeError(f'Expected the r12 {edit} text exactly once, in place, and no pre-r12 text')
    return body.replace(AFTER[edit], BEFORE[edit], 1)


def _unlisted_clean(name, body, edit):
    if OLD_MARKER[edit] in body or (NEW_MARKER[edit] is not None and NEW_MARKER[edit] in body):
        raise RuntimeError(f'{name}: {edit} text on an unreviewed capture')


def migrate_wire_fixtures(fixtures):
    names = {k: set(RULE['wire_fixtures'][k]) for k in EDITS}
    if not all(n.issubset(fixtures) for n in names.values()):
        raise RuntimeError('drop-gws-wa wire inventory changed')
    result = copy.deepcopy(fixtures)
    for name, item in result.items():
        body = base64.b64decode(item['body_base64'], validate=True)
        for edit in EDITS:
            if name in names[edit]:
                body = forward(body, edit)
            else:
                _unlisted_clean(name, body, edit)
        item['body_base64'] = base64.b64encode(body).decode()
    return result


def reverse_candidate(actual):
    result = copy.deepcopy(actual)
    captures = [c['fixture'] for c in result['captures']]
    names = {k: set(RULE['lifecycle_captures'][k]) for k in EDITS}
    if len(captures) != len(set(captures)) or not all(n.issubset(captures) for n in names.values()):
        raise RuntimeError('drop-gws-wa lifecycle inventory changed')
    for capture in result['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        # Reverse in the opposite order of the forward edits (independent texts).
        for edit in reversed(EDITS):
            if capture['fixture'] in names[edit]:
                body = reverse(body, edit)
            else:
                if OLD_MARKER[edit] in body or (NEW_MARKER[edit] is not None and NEW_MARKER[edit] in body):
                    raise RuntimeError(f"{capture['fixture']}: {edit} text on an unreviewed lifecycle capture")
        capture['body'] = base64.b64encode(body).decode()
    return result
