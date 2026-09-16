"""r7: chronology for every agent on both transports (WEB_SUBAGENT_PLAN §12, R0, 2026-09-16).

Applied to the CANDIDATE before the r5 → r4 → r3 verification (the same shape as
r5: the candidate is restored to the earlier form, never the reference edited).
Every R0 addition is removed from the candidate's captures and observations, and
each removal is asserted against the exact value the pinned lifecycle clock
produces (1 700 000 000 = 2023-11-14 22:13:20 UTC), so whatever remains must
still equal the pinned-SOURCE fixtures byte for byte. Nothing else is
normalized; a capture the rule does not name must come back unchanged.

Reversed here (rule: fixtures/chat-lifecycle/chronology-r7.json):
1. The "[Turn metadata]\\nAssistant reply time: HH:mm" system message after
   every assistant history message (the note is that single line in every
   pinned capture; a multi-line note is an error here, not silently trimmed).
2. The tool time note on results that carried none at SOURCE: subagent results
   (executed, blocked and refused) and the main agent's maintenance-pass
   refusals. Main-agent executed batches produced the same bytes at SOURCE
   (the note was baked into the persisted content) and are untouched.
3. The compaction summary, now rendered without the epoch day header/time
   prefix and with its chronology line; restored to the SOURCE rendering.
4. The summarizer transcript's dialogue stamps "[MAIN AGENT yyyy-MM-dd HH:mm UTC+00:00] ".
5. The "[System Note: The following tool calls were issued at HH:mm:ss]" system
   message before every round that recorded its receipt time (Codex R3).
6. The run-clock tail of every subagent run request (Codex R2): the whole
   system message when the run clock was its only content, otherwise the
   run-clock prefix of a combined tail (force-finish / round-limit requests).
7. Persisted records: ToolResultMessage.completedAt (main-agent results: the
   field removed and the note re-baked into content, exactly as SOURCE
   persisted it; subagent results: the field removed),
   AssistantToolCallMessage.issuedAt (removed) and Session.lastAssistantAt
   (removed).

Request bodies are sorted compact JSON that Foundation re-serializes byte for
byte; the reversal parses, edits and re-serializes, and refuses any body that
does not round-trip exactly before it is touched. The pretty-printed session
file does not round-trip through this serializer, so it is compared as parsed
JSON and the reference bytes then stand in (r5's substitution pattern).
"""
import base64
import copy
import json
from pathlib import Path
from newest_turn_protection_lifecycle_migration import verify_migration as verify_r5

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle/chronology-r7.json').read_text())
REPLY_TIME = RULE['reply_time_message']
TOOL_NOTE = RULE['tool_note']
SUMMARY_HEADER = RULE['summary_header']
SUMMARY_LINE = RULE['summary_chronology_line']
SUMMARY_SOURCE_PREFIX = RULE['summary_source_prefix']
ISSUED_NOTE = RULE['issued_note']
RUN_CLOCK = RULE['run_clock_note']
STAMPS = RULE['dialogue_stamps']          # {"[MAIN AGENT 2023-11-14 22:13] ": "[MAIN AGENT] ", ...}
COMPLETED_AT_CONVERSATION = RULE['completed_at_conversation']   # Foundation seconds since 2001 for the pinned instant
COMPLETED_AT_SESSION = RULE['completed_at_session']             # ISO 8601 for the pinned instant
COUNTS = RULE['captures']


def swift_bytes(obj, sort_keys=True):
    """Foundation's compact JSON (sorted keys for request bodies, declaration
    order for the persisted conversation): no spaces, UTF-8, `/` escaped."""
    return json.dumps(obj, separators=(',', ':'), ensure_ascii=False, sort_keys=sort_keys).replace('/', '\\/').encode()


def parse_exact(body, sort_keys, what):
    obj = json.loads(body)
    if swift_bytes(obj, sort_keys) != body:
        raise RuntimeError(f'r7: {what} does not re-serialize byte for byte; refusing to edit it')
    return obj


def reverse_body(name, body):
    """The pre-R0 bytes of one candidate request, with every removal counted
    against the rule for that capture (absent = nothing may be removed)."""
    counts = COUNTS.get(name)
    if counts is None:
        # Not named by the rule: must carry no R0 addition (the tool note
        # cannot be tested here — main-agent executed batches carried it at
        # SOURCE) and is returned untouched, never re-serialized.
        for marker in (json.dumps(REPLY_TIME)[1:-1], json.dumps(SUMMARY_LINE)[1:-1], json.dumps(ISSUED_NOTE)[1:-1],
                       json.dumps(RUN_CLOCK)[1:-1], *(json.dumps(s)[1:-1] for s in STAMPS)):
            if marker.encode() in body:
                raise RuntimeError(f'r7: {name}: carries an R0 addition but the reviewed rule does not name it')
        return body
    obj = parse_exact(body, True, f'{name} body')
    kept, reply_notes, issued_notes, run_clocks = [], 0, 0, 0
    for message in obj['messages']:
        content = message.get('content')
        if message.get('role') == 'system' and isinstance(content, str):
            if content.startswith(REPLY_TIME):
                if content != REPLY_TIME or set(message) != {'role', 'content'}:
                    raise RuntimeError(f'r7: {name}: unexpected reply-time note shape')
                reply_notes += 1
                continue
            if content.startswith(ISSUED_NOTE):
                if content != ISSUED_NOTE or set(message) != {'role', 'content'}:
                    raise RuntimeError(f'r7: {name}: unexpected issued-round note shape')
                issued_notes += 1
                continue
            if content.startswith(RUN_CLOCK):
                run_clocks += 1
                if content == RUN_CLOCK:
                    continue          # the run clock was the whole tail
                if not content.startswith(RUN_CLOCK + '\n\n'):
                    raise RuntimeError(f'r7: {name}: unexpected run-clock tail shape')
                message['content'] = content[len(RUN_CLOCK) + 2:]
        kept.append(message)
    obj['messages'] = kept
    tool_notes = summaries = stamps = 0
    for message in kept:
        content = message.get('content')
        if not isinstance(content, str):
            continue
        if message.get('role') == 'tool' and content.endswith(TOOL_NOTE) and counts.get('new_tool_notes'):
            message['content'] = content[:-len(TOOL_NOTE)]
            tool_notes += 1
        elif message.get('role') == 'user' and content.startswith(SUMMARY_HEADER + '\n' + SUMMARY_LINE + '\n\n'):
            message['content'] = SUMMARY_SOURCE_PREFIX + SUMMARY_HEADER + '\n\n' + content[len(SUMMARY_HEADER) + 1 + len(SUMMARY_LINE) + 2:]
            summaries += 1
        elif message.get('role') == 'user' and any(stamp in content for stamp in STAMPS):
            for stamp, plain in STAMPS.items():
                stamps += content.count(stamp)
                content = content.replace(stamp, plain)
            message['content'] = content
    found = {k: v for k, v in (('reply_time_messages', reply_notes), ('new_tool_notes', tool_notes),
                               ('summaries', summaries), ('dialogue_stamps', stamps),
                               ('issued_notes', issued_notes), ('run_clocks', run_clocks)) if v}
    if found != counts:
        raise RuntimeError(f'r7: {name}: removals {found} differ from the reviewed rule {counts}')
    restored = swift_bytes(obj)
    if not found and restored != body:
        raise RuntimeError(f'r7: {name}: an unlisted capture changed under re-serialization')
    return restored


def strip_result(result, what, rebake):
    """Remove the typed delivery time from one persisted tool result; re-bake
    the note into content where SOURCE (the main agent) persisted it there."""
    expected = COMPLETED_AT_CONVERSATION if rebake else COMPLETED_AT_SESSION
    if result.get('completedAt') != expected:
        raise RuntimeError(f'r7: {what}: expected completedAt {expected!r}, found {result.get("completedAt")!r}')
    del result['completedAt']
    if rebake:
        result['content'] = result['content'] + TOOL_NOTE
    return 1


def strip_round(round_, what, rebake):
    """Remove the typed receipt time from one persisted round and the
    delivery time from each of its results."""
    removed = 0
    expected = COMPLETED_AT_CONVERSATION if rebake else COMPLETED_AT_SESSION
    if 'issuedAt' in round_['assistantMessage']:
        if round_['assistantMessage']['issuedAt'] != expected:
            raise RuntimeError(f'{what}.assistantMessage: expected issuedAt {expected!r}')
        del round_['assistantMessage']['issuedAt']
        removed += 1
    for k, result in enumerate(round_['results']):
        if 'completedAt' in result:
            removed += strip_result(result, f'{what}.results[{k}]', rebake)
    return removed


def strip_messages(messages, what, rebake):
    removed = 0
    for i, message in enumerate(messages):
        for j, round_ in enumerate(message.get('toolInteractions') or []):
            removed += strip_round(round_, f'{what}[{i}].toolInteractions[{j}]', rebake)
    return removed


def reverse_observations(observations):
    """Restore the candidate's observations in place; returns the reference
    substitutions still required (session raw bytes), keyed by observation."""
    counts = RULE['observations']
    found = {}
    for scenario, spec in counts.items():
        item = observations[scenario]
        removed = 0
        for key in spec.get('interaction_lists', []):
            for j, round_ in enumerate(item[key]):
                removed += strip_round(round_, f'{scenario}.{key}[{j}]', True)
        for key in spec.get('message_lists', []):
            removed += strip_messages(item[key], f'{scenario}.{key}', True)
        if 'rawConversation' in spec:
            raw = base64.b64decode(item['rawConversation'], validate=True)
            messages = parse_exact(raw, False, f'{scenario}.rawConversation')
            removed += strip_messages(messages, f'{scenario}.rawConversation', True)
            item['rawConversation'] = base64.b64encode(swift_bytes(messages, False)).decode()
        if 'rawSession' in spec:
            if not isinstance(item['rawSession'], str):
                raise RuntimeError(f'r7: {scenario}.rawSession already restored; refusing a second application')
            session = json.loads(base64.b64decode(item['rawSession'], validate=True))
            if session.get('lastAssistantAt') != COMPLETED_AT_SESSION:
                raise RuntimeError(f'r7: {scenario}.rawSession: expected lastAssistantAt {COMPLETED_AT_SESSION!r}')
            del session['lastAssistantAt']
            removed += 1
            for j, round_ in enumerate(session['toolInteractions']):
                removed += strip_round(round_, f'{scenario}.rawSession.toolInteractions[{j}]', False)
            removed += strip_messages(session['messages'], f'{scenario}.rawSession.messages', False)
            item['rawSession'] = session   # parsed; compared and substituted by verify_migration
        found[scenario] = removed
    expected = {scenario: spec['removed'] for scenario, spec in counts.items()}
    if found != expected:
        raise RuntimeError(f'r7: observation removals {found} differ from the reviewed rule {expected}')


def verify_migration(expected, actual, compare):
    restored = copy.deepcopy(actual)
    names = [c['fixture'] for c in restored['captures']]
    for name in COUNTS:
        if names.count(name) != 1:
            raise RuntimeError(f'r7: {name} must appear exactly once in the candidate captures')
    for capture in restored['captures']:
        body = base64.b64decode(capture['body'], validate=True)
        capture['body'] = base64.b64encode(reverse_body(capture['fixture'], body)).decode()
    reverse_observations(restored['observations'])
    for scenario, spec in RULE['observations'].items():
        if 'rawSession' in spec:
            reference = json.loads(base64.b64decode(expected['observations'][scenario]['rawSession'], validate=True))
            compare(reference, restored['observations'][scenario]['rawSession'], f'r7.{scenario}.rawSession')
            # Pretty-printed by Foundation (blank lines inside empty arrays); the
            # parsed forms are equal, so the reference bytes stand in.
            restored['observations'][scenario]['rawSession'] = expected['observations'][scenario]['rawSession']
    verify_r5(expected, restored, compare)
