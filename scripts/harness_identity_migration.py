"""Explicit r9 prompt-only migration: permanent runtime identity, 2026-09-22.

Never rewrites a frozen reference, normalizes arbitrary prompt text, or edits
observations. Wire adds the exact header to reviewed captures; lifecycle
removes that same header before the existing r8→r3 comparisons.
"""
import base64
import copy
import json
import platform
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/harness-identity-r1.json').read_text())
WIRE_NAMES = set(RULE['wire_fixtures'])
LIFECYCLE_NAMES = set(RULE['lifecycle_captures'])
IDENTITY_MARKER = 'Your configured assistant name is Fixture Assistant. You run inside the Briglia CLI agent harness'


def escaped(text):
    return json.dumps(text, ensure_ascii=False).replace('/', '\\/')[1:-1].encode()


def identity(os_name=None):
    os_name = os_name or ('Mac' if platform.system() == 'Darwin' else 'Linux')
    if os_name not in RULE['platforms']:
        raise RuntimeError('Unsupported fixture platform')
    return RULE['header_template'].replace('{platform}', os_name)


def system_text(body):
    obj = json.loads(body)
    messages = obj.get('messages', [])
    systems = [m for m in messages if m.get('role') == 'system']
    if not systems:
        raise RuntimeError('Expected system prompt')
    value = systems[0]['content']
    if isinstance(value, str):
        return value
    if isinstance(value, list) and len(value) == 1 and value[0].get('type') == 'text':
        return value[0]['text']
    raise RuntimeError('Unexpected system prompt encoding')


def add_header(body, os_name=None):
    prompt = system_text(body)
    if 'You run inside the Briglia CLI agent harness' in prompt:
        raise RuntimeError('Identity already present')
    starts = [p for p in RULE['prior_prefixes'] if prompt.startswith(p)]
    if len(starts) != 1:
        raise RuntimeError('Unreviewed persona prefix')
    old = escaped(starts[0])
    if body.count(old) != 1:
        raise RuntimeError('Persona prefix is ambiguous in body')
    return body.replace(old, escaped(identity(os_name) + '\n\n') + old, 1)


def remove_header(body, os_name=None):
    header = identity(os_name) + '\n\n'
    prompt = system_text(body)
    encoded = escaped(header)
    if not prompt.startswith(header) or body.count(encoded) != 1 or prompt.count(IDENTITY_MARKER) != 1:
        raise RuntimeError('Missing, changed, misplaced or duplicated runtime identity')
    if not any(prompt[len(header):].startswith(p) for p in RULE['prior_prefixes']):
        raise RuntimeError('Unreviewed persona prefix after identity')
    return body.replace(encoded, b'', 1)


def migrate_wire_fixtures(fixtures, os_name=None):
    if set(fixtures) != WIRE_NAMES:
        raise RuntimeError('Runtime identity wire inventory changed')
    result = copy.deepcopy(fixtures)
    for item in result.values():
        body = base64.b64decode(item['body_base64'], validate=True)
        item['body_base64'] = base64.b64encode(add_header(body, os_name)).decode()
    return result


def reverse_candidate(actual, os_name=None):
    result = copy.deepcopy(actual)
    names = [c['fixture'] for c in result['captures']]
    if len(names) != len(set(names)) or not LIFECYCLE_NAMES.issubset(names):
        raise RuntimeError('Runtime identity lifecycle inventory changed')
    for capture in result['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        if capture['fixture'] in LIFECYCLE_NAMES:
            body = remove_header(body, os_name)
        elif escaped('You run inside the Briglia CLI agent harness') in body:
            raise RuntimeError('Runtime identity on an unreviewed lifecycle capture')
        capture['body'] = base64.b64encode(body).decode()
    return result


def verify_migration(expected, actual, compare):
    from web_subagent_r2_lifecycle_migration import verify_migration as verify_r8
    verify_r8(expected, reverse_candidate(actual), compare)
