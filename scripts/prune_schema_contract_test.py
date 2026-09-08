"""Guard additive snapshot schema declarations, including absent optional fields."""
import hashlib
import json
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'scripts/fixtures/prune-archives/schema-contract.json'
REGIONS = {
 'TelegramConcierge/Services/PruneArchiveStore.swift#reference': ('struct PruneArchiveReference:', '/// Immutable,'),
 'TelegramConcierge/Services/PruneArchiveStore.swift#header': ('    struct Header: Codable {', '    struct Entry {'),
 'TelegramConcierge/Models/ConversationArchiveModels.swift#all': ('import Foundation', None),
}
def fingerprints(read):
    result = {}
    for key, (start, end) in REGIONS.items():
        data = read(key.split('#')[0])
        assert data.count(start) == 1
        fragment = data[data.index(start):]
        if end:
            assert fragment.count(end) == 1
            fragment = fragment[:fragment.index(end)]
        result[key] = hashlib.sha256(fragment.encode()).hexdigest()
    return result
class Tests(unittest.TestCase):
    def test_exact_schema(self):
        self.assertEqual(json.loads(MANIFEST.read_text()), fingerprints(lambda p: (ROOT/p).read_text()))
    def test_absent_field_change_detected(self):
        old = fingerprints(lambda p: (ROOT/p).read_text())
        changed = fingerprints(lambda p: (ROOT/p).read_text().replace('struct PruneArchiveReference: Codable, Equatable {', 'struct PruneArchiveReference: Codable, Equatable {\n var silent: String? = nil'))
        self.assertNotEqual(old, changed)
if __name__ == '__main__': unittest.main()
