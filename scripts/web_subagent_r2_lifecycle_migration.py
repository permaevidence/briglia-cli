"""Reviewed lifecycle change of R2 (WEB_SUBAGENT_PLAN §16.1, 2026-09-17): the
one reply-policy line of the main prompt.

Applied FORWARD to the pinned-SOURCE lifecycle reference after the read_file
description addition, the reasoning_history removal and the r6
subagent-dialogue migration (r7 chronology restores the candidate separately,
as before). Exactly the 45 captures named by the rule — main-agent turns and
messaging-style subagent runs, every request that carries the main prompt's
reply-style section — gain the line once, on its own line immediately after
the Markdown line; the 3 summarizer captures carry no reply-style section and
stay byte-identical. The lifecycle driver has no web search key, so no tool
schema and no web bullet changes here (§4.9): the line is a raw byte edit of
the Foundation-escaped JSON string, never a re-serialization. Observations
(persisted conversation, session files) carry no system prompt and are not
touched. A capture that already carries the line is refused.
"""
import base64
import copy
import json
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle/web-subagent-r2.json').read_text())
MARKDOWN_LINE = RULE['markdown_line']
REPLY_LINE = RULE['reply_policy_line']
CAPTURES = set(RULE['captures'])


def _escaped(text):
    # Foundation encodes literal slash as \/; the edit is a byte replace inside the JSON string.
    return json.dumps(text, ensure_ascii=False).replace('/', '\\/')[1:-1].encode()


OLD = _escaped(MARKDOWN_LINE + '\n')
NEW = _escaped(MARKDOWN_LINE + '\n' + REPLY_LINE + '\n')
LINE = _escaped(REPLY_LINE)


def migrate_capture_body(name, body):
    if LINE in body:
        raise RuntimeError(f'r8: {name} already carries the reply-policy line; refusing a second application')
    count = body.count(OLD)
    if name in CAPTURES:
        if count != 1:
            raise RuntimeError(f'r8: {name}: expected exactly one reply-style Markdown line, found {count}')
        return body.replace(OLD, NEW, 1)
    if count:
        raise RuntimeError(f'r8: {name}: carries a reply-style section but the reviewed rule does not name it')
    return body


def migrate_lifecycle(fixtures):
    result = copy.deepcopy(fixtures)
    names = [c['fixture'] for c in result['captures']]
    for name in CAPTURES:
        if names.count(name) != 1:
            raise RuntimeError(f'r8: {name} must appear exactly once in the reference captures')
    for capture in result['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        capture['body'] = base64.b64encode(migrate_capture_body(capture['fixture'], body)).decode()
    return result
