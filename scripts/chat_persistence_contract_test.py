#!/usr/bin/env python3
import unittest
import tempfile
import json
import subprocess
from unittest.mock import patch
import chat_persistence_contract as contract
from pathlib import Path
from chat_persistence_contract import ROOT, digest, FILES, REGIONS, verify

class ContractTests(unittest.TestCase):
    def test_current(self):
        verify()

    def test_additive_manifest_is_exact_and_optional(self):
        # Exercise the actual P2 fallback, without editing either frozen manifest.
        with tempfile.TemporaryDirectory() as folder:
            alternate = Path(folder) / 'responses.json'
            actual = json.loads(contract.SNAPSHOT_MANIFEST.read_text())
            with patch.object(contract, 'SNAPSHOT_MANIFEST', alternate):
                alternate.write_text(json.dumps(actual))
                verify()
                for field in ['source', 'sha256']:
                    wrong = json.loads(json.dumps(actual))
                    if field == 'source': wrong[field] = 'wrong-source'
                    else: wrong[field][FILES[0]] = '0' * 64
                    alternate.write_text(json.dumps(wrong))
                    with self.assertRaisesRegex(RuntimeError, 'nil fields count'):
                        verify()
                alternate.unlink()
                with self.assertRaisesRegex(RuntimeError, 'nil fields count'):
                    verify() # P2 cannot silently bypass P0 when its manifest is absent.
                tree = Path(folder) / 'pinned'
                from chat_wire_baseline import SOURCE
                for name in FILES + list(REGIONS):
                    dest = tree / name
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(subprocess.check_output(['git', 'show', SOURCE + ':' + name], cwd=ROOT))
                verify(tree) # The original contract is still sufficient for P0.
                path = tree / FILES[0]
                path.write_bytes(path.read_bytes() + b'\n// unreviewed field\n')
                with self.assertRaisesRegex(RuntimeError, 'nil fields count'):
                    verify(tree)

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
