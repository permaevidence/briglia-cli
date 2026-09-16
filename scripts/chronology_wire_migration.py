"""Single reviewed wire change (R0 chronology, WEB_SUBAGENT_PLAN §12, 2026-09-16):
every assistant history message is followed by a system note that exposes the
reply's original time — "[Turn metadata]\\nAssistant reply time: HH:mm".

Applied to the pinned-SOURCE wire fixtures after the read_file description
addition and the reasoning_history removal. In the reviewed 91-case inventory
the history reply exists in exactly 35 requests (five url-form indices per
model); each gains exactly one note, placed immediately after the reply
(before any later history message or tail). Every other request passes through
unchanged and is still compared byte for byte (a request without an assistant
reply never gains a note). When the reply was the last history message of an
Anthropic-routed request, the second prompt-cache breakpoint moves onto the
note: the reply's content returns to a plain string and the note carries the
cache_control block. Bodies are Foundation's sorted compact JSON and are
re-serialized byte for byte (refused otherwise).
"""
import base64
import copy
import json
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/chronology-r1.json').read_text())
REPLY_TIME = RULE['reply_time_message']
CHANGED = set(RULE['fixtures'])


def swift_bytes(obj):
    return json.dumps(obj, separators=(',', ':'), ensure_ascii=False, sort_keys=True).replace('/', '\\/').encode()


def migrate_body(body):
    """Returns (body, inserted) with inserted ∈ {0, 1}."""
    obj = json.loads(body)
    if swift_bytes(obj) != body:
        raise RuntimeError('Body does not re-serialize byte for byte; refusing to edit it')
    messages = obj['messages']
    for m in messages:
        c = m.get('content')
        if c == REPLY_TIME or (isinstance(c, list) and any(p.get('text') == REPLY_TIME for p in c)):
            raise RuntimeError('Request already carries the reply-time note; refusing a second application')
    replies = [i for i, m in enumerate(messages) if m.get('role') == 'assistant' and not m.get('tool_calls')]
    if not replies:
        return body, 0
    if len(replies) != 1:
        raise RuntimeError('Unexpected number of assistant replies in a pinned request')
    reply = replies[0]
    index = reply + 1
    note = {'content': REPLY_TIME, 'role': 'system'}
    content = messages[reply].get('content')
    if isinstance(content, list):
        # The reply was the last history message (it carries the second
        # Anthropic cache breakpoint): the breakpoint moves onto the note.
        if len(content) != 1 or content[0].get('type') != 'text' or 'cache_control' not in content[0]:
            raise RuntimeError('Unexpected cache-control shape on the pinned reply')
        messages[reply]['content'] = content[0]['text']
        note['content'] = [{'cache_control': content[0]['cache_control'], 'text': REPLY_TIME, 'type': 'text'}]
    messages.insert(index, note)
    return swift_bytes(obj), 1


def migrate_wire_fixtures(fixtures):
    result = copy.deepcopy(fixtures)
    changed = set()
    for name, item in result.items():
        body, inserted = migrate_body(base64.b64decode(item['body_base64'], validate=True))
        if inserted:
            changed.add(name)
            item['body_base64'] = base64.b64encode(body).decode()
    if changed != CHANGED:
        raise RuntimeError('Reply-time note inventory differs from the reviewed rule: missing=%s extra=%s'
                           % (sorted(CHANGED - changed), sorted(changed - CHANGED)))
    return result
