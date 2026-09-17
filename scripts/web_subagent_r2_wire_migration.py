"""Reviewed wire change of R2 (WEB_SUBAGENT_PLAN §4.9 + §16.1, 2026-09-17):
the Web researcher switch defaults ON with the legacy implementation retained,
and the main prompt gains one reply-policy line for "find" requests.

Applied to the pinned-SOURCE wire fixtures after the read_file description
addition, the reasoning_history removal and the chronology reply-time notes.
In the reviewed 91-case inventory:

* every request gains the reply-policy line exactly once, on its own line
  immediately after the Markdown line of the reply-style section (the line is
  unconditional in the prompt builder: it is about the reply, not about which
  tool did the research);
* the 28 tool-carrying requests with subagents on (indices 6, 8, 9, 10 of every
  model) additionally lose `web_search` and `web_research_sweep` at the head of
  the tools array, get the switch-on `web_fetch`, `Agent` and `subagent_manage`
  function objects (asserted against the exact pre-R2 objects before they are
  replaced), and swap the legacy web bullet of the system prompt for the
  delegation bullet;
* the 7 requests at index 7 (subagents off, O5: the switch cannot be active
  while subagents are off) keep the legacy tools and the legacy bullet byte for
  byte and gain only the line.

Bodies are Foundation's sorted compact JSON and are re-serialized byte for byte
(refused otherwise). A request that already carries the line is refused (no
second application). Inventories are asserted against the rule file.
"""
import base64
import copy
import json
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-wire/web-subagent-r2.json').read_text())
MARKDOWN_LINE = RULE['markdown_line']
REPLY_LINE = RULE['reply_policy_line']
BULLET_BEFORE = RULE['web_bullet_before']
BULLET_AFTER = RULE['web_bullet_after']
REMOVED = RULE['removed_tools']
REPLACED = RULE['replaced_tools']
LINE_FIXTURES = set(RULE['line_fixtures'])
TOOL_FIXTURES = set(RULE['tool_fixtures'])


def swift_bytes(obj):
    return json.dumps(obj, separators=(',', ':'), ensure_ascii=False, sort_keys=True).replace('/', '\\/').encode()


def _system_text(message):
    content = message.get('content')
    if isinstance(content, str):
        return content
    if isinstance(content, list) and len(content) == 1 and content[0].get('type') == 'text':
        return content[0]['text']
    raise RuntimeError('Unexpected system message shape')


def _set_system_text(message, text):
    if isinstance(message['content'], str):
        message['content'] = text
    else:
        message['content'][0]['text'] = text


def migrate_body(body):
    """Returns (body, line_inserted, tools_migrated) with both flags in {0, 1}."""
    obj = json.loads(body)
    if swift_bytes(obj) != body:
        raise RuntimeError('Body does not re-serialize byte for byte; refusing to edit it')
    messages = obj['messages']
    systems = [m for m in messages if m.get('role') == 'system']
    if not systems:
        return body, 0, 0
    # The main prompt is the first system message; later system messages are
    # tails/notes that never carry the reply-style section.
    prompt = _system_text(systems[0])
    if REPLY_LINE in prompt or any(REPLY_LINE in _system_text(m) for m in systems[1:]):
        raise RuntimeError('Request already carries the reply-policy line; refusing a second application')
    if prompt.count(MARKDOWN_LINE + '\n') != 1:
        raise RuntimeError('Expected exactly one reply-style Markdown line in the main prompt')
    prompt = prompt.replace(MARKDOWN_LINE + '\n', MARKDOWN_LINE + '\n' + REPLY_LINE + '\n', 1)

    tools = obj.get('tools') or []
    names = [t.get('function', {}).get('name') for t in tools]
    tools_migrated = 0
    if names[:2] == REMOVED and 'Agent' in names:
        # Subagents on: the switch is active. Remove the two legacy research
        # tools and replace the three switch-dependent schemas, asserting the
        # exact pre-R2 objects first.
        del tools[:2]
        for tool in tools:
            name = tool['function']['name']
            if name in REPLACED:
                if tool != REPLACED[name]['before']:
                    raise RuntimeError(f'Pinned {name} schema differs from the reviewed pre-R2 object')
                tool.clear()
                tool.update(copy.deepcopy(REPLACED[name]['after']))
        if [t['function']['name'] for t in tools if t['function']['name'] in REPLACED] != ['web_fetch', 'Agent', 'subagent_manage']:
            raise RuntimeError('Expected exactly one web_fetch, Agent and subagent_manage schema, in that order')
        if prompt.count(BULLET_BEFORE + '\n') != 1:
            raise RuntimeError('Expected exactly one legacy web bullet in a tool-carrying prompt with subagents on')
        prompt = prompt.replace(BULLET_BEFORE + '\n', BULLET_AFTER + '\n', 1)
        obj['tools'] = tools
        tools_migrated = 1
    elif names[:2] == REMOVED:
        # Subagents off (O5): legacy tools and bullet stay; the line is the only change.
        if BULLET_BEFORE not in prompt or BULLET_AFTER in prompt:
            raise RuntimeError('Subagents-off request expected to keep the legacy web bullet')
    elif any(n in REMOVED for n in names):
        raise RuntimeError('Legacy research tools not at the head of the tools array')
    if BULLET_AFTER in prompt and not tools_migrated:
        raise RuntimeError('Delegation bullet present in a request the rule does not migrate')
    _set_system_text(systems[0], prompt)
    return swift_bytes(obj), 1, tools_migrated


def migrate_wire_fixtures(fixtures):
    result = copy.deepcopy(fixtures)
    lines, tools = set(), set()
    for name, item in result.items():
        body, line, tool = migrate_body(base64.b64decode(item['body_base64'], validate=True))
        if line:
            lines.add(name)
        if tool:
            tools.add(name)
        item['body_base64'] = base64.b64encode(body).decode()
    if lines != LINE_FIXTURES:
        raise RuntimeError('Reply-policy line inventory differs from the reviewed rule: missing=%s extra=%s'
                           % (sorted(LINE_FIXTURES - lines), sorted(lines - LINE_FIXTURES)))
    if tools != TOOL_FIXTURES:
        raise RuntimeError('Tool-schema inventory differs from the reviewed rule: missing=%s extra=%s'
                           % (sorted(TOOL_FIXTURES - tools), sorted(tools - TOOL_FIXTURES)))
    return result
