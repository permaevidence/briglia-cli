#!/usr/bin/env python3
import unittest
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

if __name__ == '__main__': unittest.main()
