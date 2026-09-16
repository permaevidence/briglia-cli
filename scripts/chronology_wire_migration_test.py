import base64
import copy
import json
import unittest
from pathlib import Path
from chat_wire_baseline import compare
from read_file_description_migration import migrate_wire_fixtures as migrate_read_file
from reasoning_history_removal_migration import migrate_wire_fixtures as migrate_reasoning_history
from chronology_wire_migration import migrate_wire_fixtures, migrate_body, swift_bytes, REPLY_TIME, RULE

MODELS = ('glm-5.3', 'kimi-k3', 'kimi-k2.7-code', 'qwen3.8-max', 'custom-model', 'local-model', 'anthropic_claude-sonnet-4')
REPLY_INDICES = (1, 2, 3, 10, 11)
NOTE = {'content': REPLY_TIME, 'role': 'system'}


class ChronologyWireMigrationTests(unittest.TestCase):
    def fixtures(self, name):
        return json.loads((Path(__file__).parent / 'fixtures/chat-wire' / name).read_text())['fixtures']

    def test_exactly_the_35_replies_gain_one_note(self):
        for name in ('ci-darwin-arm64-r2.json', 'ci-linux-x86_64-r2.json', 'local-darwin-arm64-r2.json'):
            fixtures = migrate_reasoning_history(migrate_read_file(self.fixtures(name)))
            migrated = migrate_wire_fixtures(fixtures)
            self.assertEqual(len(fixtures), 91)
            changed = sorted(k for k in fixtures if fixtures[k] != migrated[k])
            self.assertEqual(changed, sorted(f'{m}-{i}' for m in MODELS for i in REPLY_INDICES))
            self.assertEqual(sorted(RULE['fixtures']), changed)
            for key in fixtures:
                for field in ('target', 'headers', 'scratch_path_substitutions'):
                    self.assertEqual(fixtures[key][field], migrated[key][field])
                old = json.loads(base64.b64decode(fixtures[key]['body_base64']))
                new_bytes = base64.b64decode(migrated[key]['body_base64'])
                new = json.loads(new_bytes)
                self.assertEqual(swift_bytes(new), new_bytes)
                if key not in changed:
                    self.assertEqual(old, new)
                    self.assertFalse(any(m.get('role') == 'assistant' and not m.get('tool_calls') for m in old['messages']))
                    continue
                self.assertEqual(len(new['messages']), len(old['messages']) + 1)
                reply = next(i for i, m in enumerate(old['messages']) if m.get('role') == 'assistant' and not m.get('tool_calls'))
                inserted = new['messages'][reply + 1]
                anthropic = key.startswith('anthropic_')
                old_reply = old['messages'][reply]
                if isinstance(old_reply['content'], list):
                    # Last history message of an Anthropic request: the breakpoint moved onto the note.
                    self.assertTrue(anthropic)
                    self.assertEqual(new['messages'][reply]['content'], old_reply['content'][0]['text'])
                    self.assertEqual(inserted, {'content': [{'cache_control': {'type': 'ephemeral'}, 'text': REPLY_TIME, 'type': 'text'}], 'role': 'system'})
                else:
                    self.assertEqual(inserted, NOTE)
                    self.assertEqual(new['messages'][reply], old_reply)
                # Every other message is untouched, in order.
                self.assertEqual(old['messages'][:reply] + old['messages'][reply + 1:], new['messages'][:reply] + new['messages'][reply + 2:])
                for field in old:
                    if field != 'messages':
                        self.assertEqual(old[field], new[field])
                self.assertEqual(sum(1 for m in new['messages'] if m.get('role') == 'system' and (m.get('content') == REPLY_TIME
                                     or (isinstance(m.get('content'), list) and m['content'][0].get('text') == REPLY_TIME))), 1)
            compare(migrated, migrate_wire_fixtures(fixtures))
            with self.assertRaises(RuntimeError): compare(migrated, fixtures)
            with self.assertRaises(RuntimeError): migrate_wire_fixtures(migrated)   # a second note is refused, never inserted

    def test_body_rules(self):
        body = swift_bytes({'messages': [{'content': 'sys', 'role': 'system'}, {'content': 'hi', 'role': 'user'},
                                          {'content': 'reply', 'role': 'assistant'}, {'content': 'tail', 'role': 'system'}], 'model': 'm'})
        migrated, inserted = migrate_body(body)
        self.assertEqual(inserted, 1)
        self.assertEqual(json.loads(migrated)['messages'][3], NOTE)
        self.assertEqual(json.loads(migrated)['messages'][4], {'content': 'tail', 'role': 'system'})
        no_reply = swift_bytes({'messages': [{'content': 'hi', 'role': 'user'}, {'content': None, 'role': 'assistant', 'tool_calls': [{}]}], 'model': 'm'})
        self.assertEqual(migrate_body(no_reply), (no_reply, 0))
        with self.assertRaises(RuntimeError):
            migrate_body(b'{"messages": [{"role":"assistant","content":"x"}]}')   # not byte-stable Foundation JSON
        with self.assertRaises(RuntimeError):
            migrate_body(swift_bytes({'messages': [{'content': 'a', 'role': 'assistant'}, {'content': 'b', 'role': 'assistant'}]}))
        with self.assertRaises(ValueError): migrate_body(b'not json')
        wrong = copy.deepcopy(self.fixtures('local-darwin-arm64-r2.json'))
        del wrong['glm-5.3-1']
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(migrate_reasoning_history(migrate_read_file(wrong)))


if __name__ == '__main__': unittest.main()
