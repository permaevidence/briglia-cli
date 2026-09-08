import copy
import json
import unittest
from pathlib import Path
from chat_wire_baseline import compare
from read_file_description_migration import migrate_wire_fixtures, RULE
class Tests(unittest.TestCase):
    def test_precise_wire_addition_and_negative(self):
        root=Path(__file__).parent/'fixtures/chat-wire'
        fixtures=json.loads((root/'ci-darwin-arm64-r2.json').read_text())['fixtures']
        migrated=migrate_wire_fixtures(fixtures)
        self.assertEqual(len(fixtures),91)
        changed=[k for k in fixtures if fixtures[k]!=migrated[k]]
        self.assertTrue(changed)
        self.assertTrue(RULE['before'] in RULE['after'].replace('- Without an explicit limit, reads exceeding approximately 25,000 estimated tokens are rejected rather than truncated to that size.\n',''))
        compare(migrated,migrate_wire_fixtures(fixtures))
        bad=copy.deepcopy(migrated);bad[changed[0]]['target']='/changed'
        with self.assertRaises(RuntimeError): compare(migrated,bad)
        with self.assertRaises(RuntimeError): compare(migrated,fixtures)
if __name__=='__main__': unittest.main()
