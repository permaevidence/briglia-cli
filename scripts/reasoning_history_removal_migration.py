"""Single reviewed wire change: requests no longer carry reasoning_history.

Applied to the pinned-SOURCE fixtures before comparison, after the read_file
description migration. A request that carried the field loses exactly that one
byte sequence; a request that never carried it passes through unchanged and is
still compared byte for byte (the candidate never adds the field). More than
one occurrence is an error. Every other body byte stays exact.
"""
import base64
import copy
import json
from pathlib import Path
RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/reasoning-history-removal-r1.json').read_text())
REMOVED = RULE['removed'].encode()

def migrate_body(body):
    json.loads(body)  # the body must be a JSON request; no re-serialisation
    count = body.count(REMOVED)
    if count > RULE['max_occurrences_per_request']:
        raise RuntimeError('Unexpected reasoning_history occurrence count in a pinned request')
    return body.replace(REMOVED, b'') if count else body

def migrate_wire_fixtures(fixtures):
    result = copy.deepcopy(fixtures)
    for item in result.values():
        item['body_base64'] = base64.b64encode(migrate_body(base64.b64decode(item['body_base64'], validate=True))).decode()
    return result

def migrate_lifecycle(fixtures):
    result = copy.deepcopy(fixtures)
    for item in result['captures']:
        item['body'] = base64.b64encode(migrate_body(base64.b64decode(item['body'], validate=True))).decode()
    return result
