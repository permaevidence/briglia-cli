"""Single reviewed read_file description addition; all other wire bytes stay exact."""
import base64
import copy
import json
from pathlib import Path
RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/read-file-description-r1.json').read_text())

def migrate_body(body):
    parsed = json.loads(body)
    matches = [tool for tool in (parsed.get('tools') or [])
               if tool.get('function', {}).get('name') == 'read_file'
               and tool['function'].get('description') == RULE['before']]
    if not matches: return body
    # Foundation encodes literal slash as \/; no JSON reserialization of the request.
    old = json.dumps(RULE['before'], ensure_ascii=False).replace('/', '\\/').encode()
    new = json.dumps(RULE['after'], ensure_ascii=False).replace('/', '\\/').encode()
    if body.count(old) != len(matches):
        raise RuntimeError('Unexpected read_file description occurrence count')
    return body.replace(old, new)

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
