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
from harness_identity_migration import (RULE, LIFECYCLE_NAMES, identity, escaped,
    system_text, add_header, remove_header, migrate_wire_fixtures, reverse_candidate)


class HarnessIdentityMigrationTests(unittest.TestCase):
    def fixtures(self, name='local-darwin-arm64-r2.json'):
        original = json.loads((Path(__file__).parent / 'fixtures/chat-wire' / name).read_text())['fixtures']
        return web(chronology(reasoning(read_file(original))))

    def test_all_frozen_bodies_change_only_by_exact_prefix(self):
        for filename, os_name in [('local-darwin-arm64-r2.json', 'Mac'),
                                  ('ci-darwin-arm64-r2.json', 'Mac'),
                                  ('ci-linux-x86_64-r2.json', 'Linux')]:
            old = self.fixtures(filename)
            snapshot = copy.deepcopy(old)
            new = migrate_wire_fixtures(old, os_name)
            self.assertEqual(len(new), 91)
            self.assertEqual(old, snapshot)
            for key in old:
                before = base64.b64decode(old[key]['body_base64'])
                after = base64.b64decode(new[key]['body_base64'])
                self.assertEqual(remove_header(after, os_name), before)
                self.assertEqual(system_text(after), identity(os_name) + '\n\n' + system_text(before))
                self.assertEqual(new[key] | {'body_base64': old[key]['body_base64']}, old[key])
            compare(new, copy.deepcopy(new))
            with self.assertRaises(RuntimeError): compare(new, old)
            with self.assertRaises(RuntimeError): migrate_wire_fixtures(new, os_name)

    def test_exact_header_and_placement_are_required(self):
        before = base64.b64decode(next(iter(self.fixtures().values()))['body_base64'])
        after = add_header(before, 'Mac')
        for mutant in [before,
                       after.replace(escaped(identity('Mac')), escaped(identity('Linux'))),
                       after.replace(b'briglia-cli.', b'briglia-wrong.'),
                       after.replace(b'0.1.0-dev', b'9.9.9'),
                       after.replace(escaped(identity('Mac')), escaped('extra ' + identity('Mac'))),
                       after.replace(escaped(identity('Mac')), escaped(identity('Mac') * 2)),
                       after.replace(b'Fixture Assistant', b'Changed Assistant')]:
            with self.subTest(mutant=mutant[:100]), self.assertRaises(RuntimeError):
                remove_header(mutant, 'Mac')
        with self.assertRaises(RuntimeError): add_header(after, 'Mac')
        with self.assertRaises(RuntimeError): add_header(before.replace(b'Fixture Assistant', b'Changed Assistant'), 'Mac')
        with self.assertRaises(RuntimeError): identity('Other')

    def test_inventory_changes_fail(self):
        fixtures = self.fixtures()
        fixtures.pop(next(iter(fixtures)))
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)
        fixtures = self.fixtures()
        fixtures['unreviewed'] = copy.deepcopy(next(iter(fixtures.values())))
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)

    def test_unrelated_mutations_are_not_hidden(self):
        before = self.fixtures()
        expected = migrate_wire_fixtures(before)
        mutant = copy.deepcopy(expected)
        key = next(iter(mutant))
        body = base64.b64decode(mutant[key]['body_base64'])
        obj = json.loads(body)
        obj['model'] = 'unreviewed-model'
        mutant[key]['body_base64'] = base64.b64encode(swift_bytes(obj)).decode()
        with self.assertRaises(RuntimeError): compare(expected, mutant)
        self.assertIn(b'unreviewed-model', remove_header(base64.b64decode(mutant[key]['body_base64'])))

    def test_lifecycle_reverse_preserves_all_other_bytes_and_observations(self):
        for os_name in ['Mac', 'Linux']:
            bodies = [base64.b64decode(v['body_base64']) for v in self.fixtures().values()]
            captures = [{'fixture': name, 'body': base64.b64encode(bodies[i % len(bodies)]).decode(),
                         'headers': {'unchanged': 'yes'}} for i, name in enumerate(sorted(LIFECYCLE_NAMES))]
            captures.append({'fixture': 'archive', 'body': base64.b64encode(b'{"model":"summary"}').decode()})
            old = {'captures': captures, 'observations': {'persisted_bytes': 'untouched'}}
            candidate = copy.deepcopy(old)
            for c in candidate['captures'][:-1]:
                c['body'] = base64.b64encode(add_header(base64.b64decode(c['body']), os_name)).decode()
            snapshot = copy.deepcopy(candidate)
            self.assertEqual(reverse_candidate(candidate, os_name), old)
            self.assertEqual(candidate, snapshot)
            for change in ['missing', 'duplicate', 'wrong_header', 'unexpected_header']:
                mutant = copy.deepcopy(candidate)
                if change == 'missing': mutant['captures'].pop(0)
                elif change == 'duplicate': mutant['captures'].append(copy.deepcopy(mutant['captures'][0]))
                elif change == 'wrong_header': mutant['captures'][0]['body'] = old['captures'][0]['body']
                else: mutant['captures'][-1]['body'] = mutant['captures'][0]['body']
                with self.subTest(change=change), self.assertRaises(RuntimeError): reverse_candidate(mutant, os_name)


if __name__ == '__main__':
    unittest.main()
