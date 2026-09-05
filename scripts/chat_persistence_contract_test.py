#!/usr/bin/env python3
import unittest
import tempfile
from pathlib import Path
from chat_persistence_contract import ROOT, digest, FILES, REGIONS, verify

class ContractTests(unittest.TestCase):
    def test_current(self):
        verify()

    def test_nil_fields_are_visible(self):
        sources = {p: (ROOT / p).read_bytes() for p in FILES + list(REGIONS)}
        original = digest(sources.__getitem__)
        for path in REGIONS:
            mutated = dict(sources)
            opener = REGIONS[path][0].encode()
            mutated[path] = mutated[path].replace(opener, opener + b'\n    var newField: String? = nil', 1)
            self.assertNotEqual(original, digest(mutated.__getitem__), path)
        for path in FILES:
            mutated = dict(sources)
            mutated[path] += b'\n// New persisted field or encoder extension requires review.\n'
            self.assertNotEqual(original, digest(mutated.__getitem__), path)

    def test_guard_refuses_optional_field_without_serialized_value(self):
        # An absent optional would be invisible in every raw fixture; exercise
        # the actual manifest verifier, not just the digest comparison helper.
        with tempfile.TemporaryDirectory() as folder:
            tree = Path(folder)
            for name in FILES + list(REGIONS):
                dest = tree / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes((ROOT / name).read_bytes())
            verify(tree)
            path = tree / 'TelegramConcierge/Models/Message.swift'
            text = path.read_text()
            anchor = 'struct Message: Identifiable, Codable, Equatable {'
            self.assertEqual(text.count(anchor), 1)
            path.write_text(text.replace(anchor, anchor + '\n    var silentOptional: String? = nil'))
            with self.assertRaisesRegex(RuntimeError, 'nil fields count'):
                verify(tree)

if __name__ == '__main__': unittest.main()
