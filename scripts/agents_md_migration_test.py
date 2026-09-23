import base64
import copy
import json
import unittest
from pathlib import Path
from chat_wire_baseline import compare
from read_file_description_migration import migrate_wire_fixtures as read_file
from reasoning_history_removal_migration import migrate_wire_fixtures as reasoning
from chronology_wire_migration import migrate_wire_fixtures as chronology
from web_subagent_r2_wire_migration import migrate_wire_fixtures as web, swift_bytes
from harness_identity_migration import migrate_wire_fixtures as identity
from agents_md_migration import (RULE, WIRE_NAMES, LIFECYCLE_NAMES, BEFORE, AFTER, swap, unswap,
    migrate_wire_fixtures, reverse_candidate)


class AgentsMdMigrationTests(unittest.TestCase):
    def fixtures(self, name='local-darwin-arm64-r2.json', os_name='Mac'):
        original = json.loads((Path(__file__).parent / 'fixtures/chat-wire' / name).read_text())['fixtures']
        return identity(web(chronology(reasoning(read_file(original)))), os_name)

    def test_rule_is_one_bullet_swap(self):
        self.assertEqual(len(WIRE_NAMES), 35)
        self.assertEqual(len(LIFECYCLE_NAMES), 21)
        self.assertTrue(RULE['bullet_before'].startswith('- Project instruction files (AGENTS.md/CLAUDE.md)'))
        self.assertTrue(RULE['bullet_after'].startswith('- Project instruction files (AGENTS.md/CLAUDE.md)'))
        self.assertNotIn('\n', RULE['bullet_after'])

    def test_frozen_bodies_change_only_by_the_bullet(self):
        for filename, os_name in [('local-darwin-arm64-r2.json', 'Mac'),
                                  ('ci-darwin-arm64-r2.json', 'Mac'),
                                  ('ci-linux-x86_64-r2.json', 'Linux')]:
            old = self.fixtures(filename, os_name)
            snapshot = copy.deepcopy(old)
            new = migrate_wire_fixtures(old)
            self.assertEqual(old, snapshot)
            self.assertEqual(len(new), 91)
            changed = set()
            for key in old:
                before = base64.b64decode(old[key]['body_base64'])
                after = base64.b64decode(new[key]['body_base64'])
                if before != after:
                    changed.add(key)
                    self.assertEqual(unswap(after), before)
                    self.assertEqual(after.replace(AFTER, BEFORE), before)
                self.assertEqual(new[key] | {'body_base64': old[key]['body_base64']}, old[key])
            self.assertEqual(changed, WIRE_NAMES)
            compare(new, copy.deepcopy(new))
            with self.assertRaises(RuntimeError): compare(new, old)
            with self.assertRaises(RuntimeError): migrate_wire_fixtures(new)

    def test_exact_bullet_is_required(self):
        fixtures = self.fixtures()
        before = base64.b64decode(fixtures[sorted(WIRE_NAMES)[0]]['body_base64'])
        after = swap(before)
        for mutant in [before,
                       after.replace(b'nearer your work wins', b'nearer your work loses'),
                       after.replace(b'offer to create one', b'create one'),
                       after + b'',
                       after.replace(AFTER, AFTER + AFTER),
                       after.replace(AFTER, AFTER[:-1])]:
            if mutant == after:
                continue
            with self.subTest(mutant=mutant[:80]), self.assertRaises(RuntimeError):
                unswap(mutant)
        with self.assertRaises(RuntimeError): swap(after)

    def test_inventory_changes_fail(self):
        fixtures = self.fixtures()
        fixtures.pop(sorted(WIRE_NAMES)[0])
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)
        fixtures = self.fixtures()
        outside = next(k for k in fixtures if k not in WIRE_NAMES)
        fixtures[outside] = copy.deepcopy(fixtures[sorted(WIRE_NAMES)[0]])
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)

    def test_unrelated_mutations_are_not_hidden(self):
        expected = migrate_wire_fixtures(self.fixtures())
        mutant = copy.deepcopy(expected)
        key = sorted(WIRE_NAMES)[0]
        obj = json.loads(base64.b64decode(mutant[key]['body_base64']))
        obj['model'] = 'unreviewed-model'
        mutant[key]['body_base64'] = base64.b64encode(swift_bytes(obj)).decode()
        with self.assertRaises(RuntimeError): compare(expected, mutant)

    def test_lifecycle_reverse(self):
        body = swap(base64.b64decode(self.fixtures()[sorted(WIRE_NAMES)[0]]['body_base64']))
        plain = base64.b64decode(self.fixtures()[next(k for k in self.fixtures() if k not in WIRE_NAMES)]['body_base64'])
        captures = [{'fixture': n, 'body': base64.b64encode(body).decode(), 'headers': {'x': 'y'}}
                    for n in sorted(LIFECYCLE_NAMES)]
        captures.append({'fixture': 'archive', 'body': base64.b64encode(plain).decode()})
        actual = {'captures': captures, 'observations': {'kept': True}}
        restored = reverse_candidate(actual)
        self.assertEqual(restored['observations'], {'kept': True})
        for c in restored['captures']:
            b = base64.b64decode(c['body'])
            self.assertNotIn(AFTER, b)
            if c['fixture'] in LIFECYCLE_NAMES:
                self.assertEqual(c['headers'], {'x': 'y'})
                self.assertIn(BEFORE, b)
        missing = copy.deepcopy(actual); missing['captures'].pop(0)
        with self.assertRaises(RuntimeError): reverse_candidate(missing)
        stray = copy.deepcopy(actual); stray['captures'][-1]['body'] = base64.b64encode(body).decode()
        with self.assertRaises(RuntimeError): reverse_candidate(stray)
        unmigrated = copy.deepcopy(actual); unmigrated['captures'][0]['body'] = base64.b64encode(unswap(body)).decode()
        with self.assertRaises(RuntimeError): reverse_candidate(unmigrated)


if __name__ == '__main__':
    unittest.main()
