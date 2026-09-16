import base64
import copy
import json
import unittest
from pathlib import Path
from chat_lifecycle_baseline import compare
from chronology_lifecycle_migration import (
    RULE, COUNTS, REPLY_TIME, TOOL_NOTE, SUMMARY_HEADER, SUMMARY_LINE, SUMMARY_SOURCE_PREFIX, STAMPS,
    COMPLETED_AT_CONVERSATION, COMPLETED_AT_SESSION, reverse_body, reverse_observations, swift_bytes)

FILES = ('ci-darwin-arm64-r2.json', 'ci-darwin-arm64-r2-image20260907.json', 'ci-linux-x86_64-r2.json', 'local-darwin-arm64-r2.json')


def body(messages, **extra):
    return swift_bytes({'messages': messages, 'model': 'fixture-model', **extra})


class ChronologyLifecycleMigrationTests(unittest.TestCase):
    def fixtures(self, name):
        return json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle' / name).read_text())['fixtures']

    def test_pinned_fixtures_carry_no_r0_addition_and_reverse_to_themselves(self):
        # The reviewed reference has no R0 addition anywhere: reversing it is
        # the identity for unlisted captures and an error for listed ones
        # (their removals are mandatory), so the rule can never pass vacuously.
        for name in FILES:
            fixtures = self.fixtures(name)
            for capture in fixtures['captures']:
                raw = base64.b64decode(capture['body'])
                if capture['fixture'] in COUNTS:
                    with self.assertRaises(RuntimeError): reverse_body(capture['fixture'], raw)
                else:
                    self.assertEqual(reverse_body(capture['fixture'], raw), raw)
            observations = copy.deepcopy(fixtures['observations'])
            with self.assertRaises(RuntimeError): reverse_observations(observations)

    def test_listed_captures_exist_and_reference_rendering_is_the_source_shape(self):
        # Sanity for the rule: the listed captures exist in every pinned file
        # (except the two candidate-only ones r5 pins) and the two summary
        # captures render the SOURCE epoch prefix that the reversal restores.
        for name in FILES:
            names = {c['fixture'] for c in self.fixtures(name)['captures']}
            for listed in COUNTS:
                if listed in ('automatic-protected-0', 'exhausted-protected-0'):
                    continue
                self.assertIn(listed, names)
            by_name = {c['fixture']: c for c in self.fixtures(name)['captures']}
            for summary in ('subagent-eager-2', 'subagent-midrun-2'):
                text = base64.b64decode(by_name[summary]['body']).decode()
                self.assertIn(json.dumps(SUMMARY_SOURCE_PREFIX + SUMMARY_HEADER + '\n\n', ensure_ascii=False)[1:-1], text)

    def test_reverse_body_removes_exactly_the_listed_additions(self):
        reply = {'content': REPLY_TIME, 'role': 'system'}
        tool = {'content': '{"error":"refused"}' + TOOL_NOTE, 'role': 'tool', 'tool_call_id': 'c1'}
        summary = {'content': SUMMARY_HEADER + '\n' + SUMMARY_LINE + '\n\nevicted history summary', 'role': 'user'}
        stamped = {'content': 'prompt\n=== DIALOGUE ===\n[MAIN AGENT 2023-11-14 22:13] hi\n\n[SUBAGENT 2023-11-14 22:13] yo\n\n', 'role': 'user'}
        candidate = body([{'content': 'sys', 'role': 'system'}, summary, {'content': 'a', 'role': 'assistant'}, reply, tool, stamped])
        # subagent-midrun-2 expects 2 reply notes, 1 tool note, 1 summary: build exactly that.
        candidate = body([{'content': 'sys', 'role': 'system'}, summary, {'content': 'a', 'role': 'assistant'}, reply,
                          {'content': 'b', 'role': 'assistant'}, reply, tool])
        restored = json.loads(reverse_body('subagent-midrun-2', candidate))['messages']
        self.assertEqual(restored, [{'content': 'sys', 'role': 'system'},
                                    {'content': SUMMARY_SOURCE_PREFIX + SUMMARY_HEADER + '\n\nevicted history summary', 'role': 'user'},
                                    {'content': 'a', 'role': 'assistant'}, {'content': 'b', 'role': 'assistant'},
                                    {'content': '{"error":"refused"}', 'role': 'tool', 'tool_call_id': 'c1'}])
        # Counts are exact: one note too many or too few is refused.
        with self.assertRaises(RuntimeError): reverse_body('subagent-midrun-2', body([summary, reply, tool]))
        with self.assertRaises(RuntimeError): reverse_body('subagent-midrun-2', body([summary, reply, reply, tool, tool]))
        # An unlisted capture may not carry a note; a listed one may not carry a multi-line note.
        with self.assertRaises(RuntimeError): reverse_body('loop-tools-1', body([reply]))
        with self.assertRaises(RuntimeError): reverse_body('subagent-resume-0', body([{'content': REPLY_TIME + '\nmore', 'role': 'system'}]))
        # Stamps: subagent-midrun-1 expects four; every other byte stays.
        four = body([{'content': stamped['content'] + '[MAIN AGENT 2023-11-14 22:13] x\n\n[SUBAGENT 2023-11-14 22:13] y', 'role': 'user'}])
        back = json.loads(reverse_body('subagent-midrun-1', four))['messages'][0]['content']
        self.assertEqual(back, 'prompt\n=== DIALOGUE ===\n[MAIN AGENT] hi\n\n[SUBAGENT] yo\n\n[MAIN AGENT] x\n\n[SUBAGENT] y')
        for stamp in STAMPS: self.assertNotIn(stamp, back)
        # A tool note on a main-agent executed batch (unlisted capture) is untouched and not re-serialized.
        legacy = b'{"messages":[{"content":"x' + TOOL_NOTE.replace('\n', '\\n').encode() + b'","role":"tool","tool_call_id":"c"}],"model":"m"}'
        self.assertEqual(reverse_body('loop-tools-1', legacy), legacy)
        with self.assertRaises(ValueError): reverse_body('subagent-resume-0', b'not json')

    def test_reverse_observations_restores_persisted_records(self):
        result = {'role': 'tool', 'tool_call_id': 'c', 'content': 'obs', 'fileAttachmentReferences': [], 'completedAt': COMPLETED_AT_CONVERSATION}
        round_ = {'assistantMessage': {'role': 'assistant', 'tool_calls': []}, 'results': [result]}
        message = {'id': 'm', 'role': 'assistant', 'content': 'a', 'toolInteractions': [copy.deepcopy(round_)]}
        raw = swift_bytes([copy.deepcopy(message)], sort_keys=False)
        session_result = dict(result, completedAt=COMPLETED_AT_SESSION)
        session = {'id': 'p0001', 'lastAssistantAt': COMPLETED_AT_SESSION, 'lastAssistantText': 'forced answer', 'messages': [],
                   'toolInteractions': [{'assistantMessage': {}, 'results': [session_result]}]}
        observations = {
            'loop-tools': {'interactions': [copy.deepcopy(round_)]},
            'midturn-carry': {'history': [copy.deepcopy(message)], 'rawConversation': base64.b64encode(raw).decode()},
            'midturn-abort': {'history': [copy.deepcopy(message)], 'rawConversation': base64.b64encode(raw).decode()},
            'subagents': {'rawSession': base64.b64encode(json.dumps(session, indent=2).encode()).decode()},
        }
        reverse_observations(observations)
        baked = {'role': 'tool', 'tool_call_id': 'c', 'content': 'obs' + TOOL_NOTE, 'fileAttachmentReferences': []}
        self.assertEqual(observations['loop-tools']['interactions'][0]['results'][0], baked)
        for scenario in ('midturn-carry', 'midturn-abort'):
            self.assertEqual(observations[scenario]['history'][0]['toolInteractions'][0]['results'][0], baked)
            self.assertEqual(json.loads(base64.b64decode(observations[scenario]['rawConversation']))[0]['toolInteractions'][0]['results'][0], baked)
        restored_session = observations['subagents']['rawSession']
        self.assertNotIn('lastAssistantAt', restored_session)
        self.assertEqual(restored_session['toolInteractions'][0]['results'][0], {k: v for k, v in result.items() if k != 'completedAt'})
        # Wrong value, missing field or a second application is refused.
        wrong = copy.deepcopy(observations); wrong['loop-tools']['interactions'][0]['results'][0]['completedAt'] = 1
        with self.assertRaises(RuntimeError): reverse_observations(wrong)
        with self.assertRaises(RuntimeError): reverse_observations(copy.deepcopy(observations))

    def test_rule_is_consistent(self):
        self.assertEqual(sum(v.get('reply_time_messages', 0) for v in COUNTS.values()), 61)
        self.assertEqual(sum(v.get('new_tool_notes', 0) for v in COUNTS.values()), 15)
        self.assertEqual(sum(v.get('summaries', 0) for v in COUNTS.values()), 2)
        self.assertEqual(sum(v.get('dialogue_stamps', 0) for v in COUNTS.values()), 16)
        self.assertEqual({k: v['removed'] for k, v in RULE['observations'].items()},
                         {'loop-tools': 1, 'midturn-carry': 2, 'midturn-abort': 2, 'subagents': 2})


if __name__ == '__main__': unittest.main()
