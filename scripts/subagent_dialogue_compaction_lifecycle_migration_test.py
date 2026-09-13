import base64
import copy
import json
import unittest
from pathlib import Path
from chat_lifecycle_baseline import compare
from subagent_dialogue_compaction_lifecycle_migration import (
    RULE, migrate_lifecycle, migrate_body, INTRO_OLD, INTRO_NEW, SECTION_ZERO, DIALOGUE_HEADER, MARKER, ROLES, WORK)

FILES = ('ci-darwin-arm64-r2.json', 'ci-darwin-arm64-r2-image20260907.json', 'ci-linux-x86_64-r2.json', 'local-darwin-arm64-r2.json')


class SubagentDialogueMigrationTests(unittest.TestCase):
    def fixtures(self, name):
        return json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle' / name).read_text())['fixtures']

    def test_exactly_the_three_summarizer_requests_change(self):
        for name in FILES:
            fixtures = self.fixtures(name)
            migrated = migrate_lifecycle(fixtures)
            self.assertEqual(migrated['observations'], fixtures['observations'])
            changed = []
            for old_item, new_item in zip(fixtures['captures'], migrated['captures']):
                for field in ('fixture', 'headers', 'method', 'target'):
                    self.assertEqual(old_item[field], new_item[field])
                old = base64.b64decode(old_item['body']); new = base64.b64decode(new_item['body'])
                if old == new:
                    continue
                changed.append(old_item['fixture'])
                self.assertEqual(old.count(INTRO_OLD), 1); self.assertEqual(new.count(INTRO_NEW), 1); self.assertNotIn(INTRO_OLD, new)
                self.assertEqual(new.count(SECTION_ZERO), 1); self.assertNotIn(SECTION_ZERO, old)
                self.assertEqual(new.count(MARKER + DIALOGUE_HEADER), 1)
                transcript = new.split(MARKER)[1]
                for role_old in ROLES:
                    self.assertNotIn(role_old, transcript)
                self.assertEqual(sum(transcript.count(r) for r in ROLES.values()), RULE['expected_role_counts'][old_item['fixture']])
                self.assertEqual(len(new) - len(old),
                                 len(INTRO_NEW) - len(INTRO_OLD) + len(SECTION_ZERO) + len(DIALOGUE_HEADER)
                                 + sum((len(ROLES[r]) - len(r)) * old.split(MARKER)[1].count(r) for r in ROLES))
                json.loads(new)
            self.assertEqual(sorted(changed), sorted(RULE['captures']))
            compare(migrated, migrate_lifecycle(fixtures))
            with self.assertRaises(RuntimeError): compare(migrated, fixtures)
            with self.assertRaises(RuntimeError): migrate_lifecycle(migrated)  # already migrated bodies are refused, never double-applied

    def test_body_rules(self):
        fixtures = self.fixtures(FILES[0])
        item = next(c for c in fixtures['captures'] if c['fixture'] == 'subagent-midrun-1')
        body = base64.b64decode(item['body'])
        head, transcript = body.split(MARKER)
        with self.assertRaises(RuntimeError): migrate_body(body, 5)
        with self.assertRaises(RuntimeError): migrate_body(head + MARKER + WORK[0] + transcript, 4)
        with self.assertRaises(RuntimeError): migrate_body(body.replace(INTRO_OLD, INTRO_OLD + b' ' + INTRO_OLD, 1), 4)
        with self.assertRaises(RuntimeError): migrate_body(body.replace(INTRO_OLD, b'other'), 4)
        with self.assertRaises(Exception): migrate_body(b'not json', 4)
        missing = copy.deepcopy(fixtures); missing['captures'] = [c for c in missing['captures'] if c['fixture'] != 'subagent-eager-1']
        with self.assertRaises(RuntimeError): migrate_lifecycle(missing)


if __name__ == '__main__': unittest.main()
