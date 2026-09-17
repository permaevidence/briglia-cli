"""r8: the one reply-policy line of the main prompt (Web subagent R2,
WEB_SUBAGENT_PLAN §16.1, 2026-09-17).

Applied to the CANDIDATE before r7 (the same shape as r7 and r5: the candidate
is restored to the earlier form, never the reference edited). Every capture
whose main prompt carries the reply-style section gains the line in R2 — the
main-agent turns, the messaging-style subagent runs AND the requests that the
r5 rule pins as body templates (`automatic-protected-0`,
`exhausted-protected-0`, … recorded before R2 and therefore without the line),
so a forward edit of the reference could never reach those templates; the
reversal removes the line from the candidate instead and everything downstream
(r7 → r5 → r4 → r3) compares as before.

Rule (fixtures/chat-lifecycle/web-subagent-r2.json): the exact capture names
that carry the line in the candidate. A named capture must carry the line
exactly once, on its own line right after the Markdown line, and loses it as a
raw byte edit of the Foundation-escaped JSON string (never a re-serialization);
an unnamed capture must not carry the reply-style section at all (the 3
summarizer captures) and comes back untouched. Observations (persisted
conversation, session files) carry no system prompt and are not touched. The
lifecycle driver has no web search key, so no tool schema and no web bullet
changes here (§4.9).
"""
import base64
import copy
import json
from pathlib import Path
from chronology_lifecycle_migration import verify_migration as verify_r7

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle/web-subagent-r2.json').read_text())
MARKDOWN_LINE = RULE['markdown_line']
REPLY_LINE = RULE['reply_policy_line']
CAPTURES = set(RULE['captures'])


def _escaped(text):
    # Foundation encodes literal slash as \/; the edit is a byte replace inside the JSON string.
    return json.dumps(text, ensure_ascii=False).replace('/', '\\/')[1:-1].encode()


WITH_LINE = _escaped(MARKDOWN_LINE + '\n' + REPLY_LINE + '\n')
WITHOUT_LINE = _escaped(MARKDOWN_LINE + '\n')
LINE = _escaped(REPLY_LINE)
MARKDOWN = _escaped(MARKDOWN_LINE)


def reverse_capture_body(name, body):
    """The pre-R2 bytes of one candidate capture."""
    if name in CAPTURES:
        if body.count(WITH_LINE) != 1 or body.count(LINE) != 1:
            raise RuntimeError(f'r8: {name}: expected the reply-policy line exactly once, right after the Markdown line')
        return body.replace(WITH_LINE, WITHOUT_LINE, 1)
    if LINE in body:
        raise RuntimeError(f'r8: {name}: carries the reply-policy line but the reviewed rule does not name it')
    if MARKDOWN in body:
        raise RuntimeError(f'r8: {name}: carries the reply-style section without the line; the reviewed rule does not name it')
    return body


def reverse_candidate(actual):
    restored = copy.deepcopy(actual)
    names = [c['fixture'] for c in restored['captures']]
    for name in CAPTURES:
        if names.count(name) != 1:
            raise RuntimeError(f'r8: {name} must appear exactly once in the candidate captures')
    for capture in restored['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        capture['body'] = base64.b64encode(reverse_capture_body(capture['fixture'], body)).decode()
    return restored


def verify_migration(expected, actual, compare):
    verify_r7(expected, reverse_candidate(actual), compare)
