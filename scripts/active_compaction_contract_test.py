"""Guard checkpoint/summary persistence, including absent optional fields."""
import hashlib
import json
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parent.parent
PATH = ROOT / 'TelegramConcierge/Services/ActiveTurnCompaction.swift'
def fingerprint(text):
    return hashlib.sha256(text[:text.index('/// Conservative local policy')].encode()).hexdigest()
class Tests(unittest.TestCase):
    def test_exact(self):
        expected = json.loads((ROOT / 'scripts/fixtures/active-compaction/schema-contract.json').read_text())
        self.assertEqual(expected['sha256'], fingerprint(PATH.read_text()))
    def test_new_absent_field_rejected(self):
        text = PATH.read_text()
        for anchor in ['struct ActiveTurnCompaction: Codable, Equatable {', 'struct TurnCheckpoint: Codable {']:
            self.assertNotEqual(fingerprint(text), fingerprint(text.replace(anchor, anchor + '\n var unreviewedField: String? = nil', 1)))
if __name__ == '__main__': unittest.main()
