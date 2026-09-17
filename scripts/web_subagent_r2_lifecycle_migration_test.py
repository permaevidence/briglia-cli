import base64
import copy
import json
import unittest
from pathlib import Path
from chat_lifecycle_baseline import compare
from read_file_description_migration import migrate_lifecycle as migrate_read_file
from reasoning_history_removal_migration import migrate_lifecycle as migrate_reasoning_history
from subagent_dialogue_compaction_lifecycle_migration import migrate_lifecycle as migrate_subagent_dialogue
from web_subagent_r2_lifecycle_migration import migrate_lifecycle, migrate_capture_body, RULE, CAPTURES, OLD, NEW, LINE

FIXTURES = ('local-darwin-arm64-r2.json', 'ci-darwin-arm64-r2.json', 'ci-darwin-arm64-r2-image20260907.json', 'ci-linux-x86_64-r2.json')


class WebSubagentR2LifecycleMigrationTests(unittest.TestCase):
    def fixtures(self, name):
        return json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle' / name).read_text())['fixtures']

    def test_exactly_the_45_prompt_captures_gain_one_line(self):
        self.assertEqual(len(CAPTURES), 45)
        for name in FIXTURES:
            reference = migrate_subagent_dialogue(migrate_reasoning_history(migrate_read_file(self.fixtures(name))))
            migrated = migrate_lifecycle(reference)
            self.assertEqual(len(reference['captures']), 48)
            self.assertEqual(migrated['observations'], reference['observations'])
            changed = []
            for old, new in zip(reference['captures'], migrated['captures']):
                self.assertEqual(old['fixture'], new['fixture'])
                for field in old:
                    if field != 'body':
                        self.assertEqual(old[field], new[field])
                old_body, new_body = base64.b64decode(old['body']), base64.b64decode(new['body'])
                if old['fixture'] in CAPTURES:
                    changed.append(old['fixture'])
                    self.assertEqual(old_body.count(OLD), 1)
                    self.assertEqual(new_body, old_body.replace(OLD, NEW, 1))
                    self.assertEqual(new_body.count(LINE), 1)
                    self.assertEqual(json.loads(new_body)['messages'][0]['role'], 'system')   # the line landed in the prompt
                    parsed_old, parsed_new = json.loads(old_body), json.loads(new_body)
                    self.assertEqual(parsed_old['messages'][1:], parsed_new['messages'][1:])
                    self.assertEqual({k: v for k, v in parsed_old.items() if k != 'messages'}, {k: v for k, v in parsed_new.items() if k != 'messages'})
                else:
                    self.assertEqual(old_body, new_body)
                    self.assertNotIn(OLD, old_body)
            self.assertEqual(sorted(changed), sorted(CAPTURES))
            compare(migrated, migrate_lifecycle(reference))
            with self.assertRaises(RuntimeError): compare(migrated, reference)
            with self.assertRaises(RuntimeError): migrate_lifecycle(migrated)          # a second line is refused

    def test_capture_rules(self):
        body = b'{"messages":[{"content":"intro\\n' + OLD + b'\\nrest","role":"system"}]}'
        self.assertEqual(migrate_capture_body('manual-0', body), b'{"messages":[{"content":"intro\\n' + NEW + b'\\nrest","role":"system"}]}')
        with self.assertRaises(RuntimeError): migrate_capture_body('manual-0', migrate_capture_body('manual-0', body))
        with self.assertRaises(RuntimeError): migrate_capture_body('manual-0', b'{"messages":[]}')          # named, no Markdown line
        with self.assertRaises(RuntimeError): migrate_capture_body('summarizer-x', body)                  # unnamed but carries the section
        self.assertEqual(migrate_capture_body('summarizer-x', b'{"messages":[]}'), b'{"messages":[]}')
        wrong = copy.deepcopy(self.fixtures('local-darwin-arm64-r2.json'))
        wrong['captures'] = [c for c in wrong['captures'] if c['fixture'] != 'manual-0']
        with self.assertRaises(RuntimeError): migrate_lifecycle(migrate_subagent_dialogue(migrate_reasoning_history(migrate_read_file(wrong))))
        self.assertEqual(RULE['revision'], 1)


if __name__ == '__main__':
    unittest.main()
