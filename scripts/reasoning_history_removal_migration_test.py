import base64
import copy
import json
import unittest
from pathlib import Path
from chat_wire_baseline import compare
from read_file_description_migration import migrate_wire_fixtures as migrate_read_file
from reasoning_history_removal_migration import migrate_wire_fixtures, migrate_lifecycle, migrate_body, REMOVED
CARRIERS = ('glm-5.3', 'kimi-k2.7-code', 'qwen3.8-max')
NON_CARRIERS = ('kimi-k3', 'custom-model', 'local-model', 'anthropic_claude-sonnet-4')
class Tests(unittest.TestCase):
    def fixtures(self, name):
        return json.loads((Path(__file__).parent / 'fixtures/chat-wire' / name).read_text())['fixtures']
    def test_wire_exactly_the_carriers_lose_one_field(self):
        for name in ('ci-darwin-arm64-r2.json', 'ci-linux-x86_64-r2.json', 'local-darwin-arm64-r2.json'):
            fixtures = migrate_read_file(self.fixtures(name))
            migrated = migrate_wire_fixtures(fixtures)
            self.assertEqual(len(fixtures), 91)
            changed = sorted(k for k in fixtures if fixtures[k] != migrated[k])
            self.assertEqual(changed, sorted(f'{m}-{i}' for m in CARRIERS for i in range(13)))
            for key in fixtures:
                old = base64.b64decode(fixtures[key]['body_base64'])
                new = base64.b64decode(migrated[key]['body_base64'])
                for field in ('target', 'headers', 'scratch_path_substitutions'):
                    self.assertEqual(fixtures[key][field], migrated[key][field])
                self.assertNotIn(b'reasoning_history', new)
                if key in changed:
                    self.assertEqual(old.count(REMOVED), 1)
                    self.assertEqual(old.replace(REMOVED, b''), new)
                    self.assertEqual(len(old) - len(new), len(REMOVED))
                else:
                    self.assertTrue(key.rsplit('-', 1)[0] in NON_CARRIERS)
                    self.assertEqual(old, new)
            compare(migrated, migrate_wire_fixtures(fixtures))
            compare(migrated, migrate_wire_fixtures(migrated))  # idempotent
            with self.assertRaises(RuntimeError): compare(migrated, fixtures)
            bad = copy.deepcopy(migrated); bad['qwen3.8-max-3']['target'] = '/changed'
            with self.assertRaises(RuntimeError): compare(migrated, bad)
    def test_lifecycle_exactly_the_carriers_lose_one_field(self):
        root = Path(__file__).parent / 'fixtures/chat-lifecycle'
        for name in ('ci-darwin-arm64-r2.json', 'ci-darwin-arm64-r2-image20260907.json', 'ci-linux-x86_64-r2.json', 'local-darwin-arm64-r2.json'):
            fixtures = json.loads((root / name).read_text())['fixtures']
            migrated = migrate_lifecycle(fixtures)
            self.assertEqual(len(fixtures['captures']), 48)
            self.assertEqual(migrated['observations'], fixtures['observations'])
            unchanged = []
            for old_item, new_item in zip(fixtures['captures'], migrated['captures']):
                for field in ('fixture', 'headers', 'method', 'scratch_substitutions', 'target'):
                    self.assertEqual(old_item[field], new_item[field])
                old = base64.b64decode(old_item['body']); new = base64.b64decode(new_item['body'])
                self.assertNotIn(b'reasoning_history', new)
                if old == new:
                    unchanged.append(old_item['fixture'])
                else:
                    self.assertEqual(old.count(REMOVED), 1)
                    self.assertEqual(old.replace(REMOVED, b''), new)
            # The setup probe and the effort-less user-context call never carried the field at SOURCE.
            self.assertEqual(sorted(unchanged), ['probe-0', 'user-context-0'])
            self.assertEqual(migrate_lifecycle(migrated), migrated)
    def test_body_rules(self):
        with self.assertRaises(RuntimeError):
            migrate_body(b'{"model":"glm-5.3","reasoning_history":"preserved","x":1,"reasoning_history":"preserved"}')
        self.assertEqual(migrate_body(b'{"model":"kimi-k3","x":1}'), b'{"model":"kimi-k3","x":1}')
        self.assertEqual(migrate_body(b'{"model":"kimi-k2.7-code","x":1,"reasoning_history":"preserved"}'), b'{"model":"kimi-k2.7-code","x":1}')
        with self.assertRaises(ValueError): migrate_body(b'not json')
if __name__ == '__main__': unittest.main()
