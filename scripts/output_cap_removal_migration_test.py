import base64
import copy
import json
import unittest
from pathlib import Path
from output_cap_removal_migration import migrate_lifecycle, migrate_body, verify_candidate, REMOVED


class Tests(unittest.TestCase):
    def test_lifecycle_only_the_probe_loses_its_cap(self):
        root = Path(__file__).parent / 'fixtures/chat-lifecycle'
        for name in ('ci-darwin-arm64-r2.json', 'ci-darwin-arm64-r2-image20260907.json', 'ci-linux-x86_64-r2.json', 'local-darwin-arm64-r2.json'):
            fixtures = json.loads((root / name).read_text())['fixtures']
            migrated = migrate_lifecycle(fixtures)
            self.assertEqual(len(fixtures['captures']), 48)
            self.assertEqual(migrated['observations'], fixtures['observations'])
            changed = []
            for old_item, new_item in zip(fixtures['captures'], migrated['captures']):
                for field in ('fixture', 'headers', 'method', 'scratch_substitutions', 'target'):
                    self.assertEqual(old_item[field], new_item[field])
                old = base64.b64decode(old_item['body']); new = base64.b64decode(new_item['body'])
                self.assertNotIn(b'max_tokens', new)
                if old != new:
                    changed.append(old_item['fixture'])
                    self.assertEqual(old.count(REMOVED), 1)
                    self.assertEqual(old.replace(REMOVED, b''), new)
                    self.assertEqual(new, b'{"model":"glm-5.3","messages":[{"role":"user","content":"Reply with OK"}]}')
            self.assertEqual(changed, ['probe-0'])
            verify_candidate(migrated)
            with self.assertRaises(RuntimeError): migrate_lifecycle(migrated)  # not idempotent by design: the cap must be there once
            with self.assertRaises(RuntimeError): verify_candidate(fixtures)

    def test_body_rules(self):
        self.assertEqual(migrate_body(b'{"max_tokens":10,"model":"m"}', True), b'{"model":"m"}')
        with self.assertRaises(RuntimeError): migrate_body(b'{"model":"m"}', True)
        with self.assertRaises(RuntimeError): migrate_body(b'{"max_tokens":10,"a":1,"max_tokens":10,"model":"m"}', True)
        with self.assertRaises(RuntimeError): migrate_body(b'{"model":"m","max_completion_tokens":5}', False)
        with self.assertRaises(RuntimeError): migrate_body(b'{"model":"m","max_output_tokens":5}', False)
        self.assertEqual(migrate_body(b'{"model":"m","x":1}', False), b'{"model":"m","x":1}')
        with self.assertRaises(ValueError): migrate_body(b'not json', False)

    def test_inventory(self):
        fixtures = {'observations': [], 'captures': [{'fixture': 'other-0', 'body': base64.b64encode(b'{}').decode()}]}
        with self.assertRaises(RuntimeError): migrate_lifecycle(fixtures)
        bad = {'observations': [], 'captures': [{'fixture': 'x', 'body': base64.b64encode(b'{"max_tokens":3}').decode()}]}
        with self.assertRaises(RuntimeError): verify_candidate(bad)


if __name__ == '__main__': unittest.main()
