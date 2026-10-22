#!/usr/bin/env python3
import unittest
import tempfile
import json
import subprocess
from unittest.mock import patch
import chat_persistence_contract as contract
from pathlib import Path
from chat_persistence_contract import ROOT, digest, FILES, REGIONS, verify
import cm_split_paths as cmp

class ContractTests(unittest.TestCase):
    def test_current(self):
        verify()

    def test_additive_manifest_is_exact_and_optional(self):
        # Exercise the current additive fallback, without editing either frozen manifest.
        with tempfile.TemporaryDirectory() as folder:
            alternate = Path(folder) / 'responses.json'
            actual = json.loads(contract.ORPROVIDER_MANIFEST.read_text())
            with patch.object(contract, 'ORPROVIDER_MANIFEST', alternate):
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
                    verify() # An additive change cannot silently bypass P0 when its manifest is absent.
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
            openers = [REGIONS[path][0].encode()]
            if path == cmp.MAIN:  # either spelling (0.2.59 split may promote it)
                openers.append(openers[0].replace(b'private ', b'', 1))
            hits = [o for o in openers if o in mutated[path]]
            self.assertEqual(len(hits), 1, path)
            mutated[path] = mutated[path].replace(hits[0], hits[0] + b'\n    var newField: String? = nil', 1)
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


START_P = '    private struct ContextUsageSnapshot: Codable {'
START_I = '    struct ContextUsageSnapshot: Codable {'
END_P = '    private struct ToolAwareResponse {'
END_I = '    struct ToolAwareResponse {'


class SplitSpellingTests(unittest.TestCase):
    """0.2.59 ConversationManager split (plan v3 §6.1, D5): restore the original
    `private ` spelling of the start anchor before hashing, accept either spelling
    of each anchor independently, never normalise any other byte."""

    @classmethod
    def setUpClass(cls):
        from chat_wire_baseline import SOURCE
        cls.snapshots = {
            # historical (P0 / 7e8328c6 manifests) and current (orprovider / 53b709e5)
            'historical': subprocess.check_output(['git', 'show', SOURCE + ':' + cmp.MAIN], cwd=ROOT).decode(),
            'current': subprocess.check_output(['git', 'show', '59860aa:' + cmp.MAIN], cwd=ROOT).decode(),
        }
        cls.expected = {k: contract.cm_segment(lambda p, t=t: t.encode() if p == cmp.MAIN else (_ for _ in ()).throw(FileNotFoundError(p)))
                        for k, t in cls.snapshots.items()}
        cls.hashes = {k: __import__('hashlib').sha256(v.encode()).hexdigest()[:8] for k, v in cls.expected.items()}

    def seg(self, files):
        def read(p):
            if p not in files: raise FileNotFoundError(p)
            return files[p].encode()
        return contract.cm_segment(read)

    def spelled(self, text, start, end):
        return text.replace(START_P, start, 1).replace(END_P, end, 1)

    def test_reference_hashes(self):
        self.assertEqual(self.hashes, {'historical': '7e8328c6', 'current': '53b709e5'})

    def test_all_spelling_combinations_hash_identically(self):
        n = 0
        for name, text in self.snapshots.items():
            for start in (START_P, START_I):
                for end in (END_P, END_I):
                    self.assertEqual(self.seg({cmp.MAIN: self.spelled(text, start, end)}), self.expected[name], (name, start, end))
                    n += 1
        self.assertEqual(n, 8)

    def assertRefused(self, files, msg=None):
        with self.assertRaises(RuntimeError, msg=msg):
            self.seg(files)

    def assertChanged(self, files, name, msg=None):
        try:
            got = self.seg(files)
        except RuntimeError:
            return
        self.assertNotEqual(got, self.expected[name], msg)

    def test_failures(self):
        for name, text in self.snapshots.items():
            region = self.expected[name]
            promoted = self.spelled(text, START_I, END_I)
            for t in (text, promoted):
                # changed field, type, CodingKey, encoder body, interior whitespace
                for old, new in (('let ', 'var '), ('Int', 'Int64'), ('case ', 'case renamed, '), ('encode(', 'encodeIfPresent(')):
                    if old in region[60:]:
                        i = t.index(region[60:]) if region[60:] in t else None
                        if i is None:
                            continue
                        body = region[60:]
                        self.assertChanged({cmp.MAIN: t.replace(body, body.replace(old, new, 1), 1)}, name, (name, old))
                body = region[60:]
                self.assertChanged({cmp.MAIN: t.replace(body, body.replace('\n', '\n ', 1), 1)}, name, 'interior whitespace')
            # a promoted spelling of any other line inside the region (synthetic: the real ones have none)
            synth = text.replace(START_P, START_P + '\n        private var synthetic = 0', 1)
            synth_promoted = text.replace(START_P, START_I + '\n        var synthetic = 0', 1)
            self.assertNotEqual(self.seg({cmp.MAIN: synth}), self.seg({cmp.MAIN: synth_promoted}), 'interior promotion must change the hash')
            # duplicated anchor; duplicate variants of one anchor; reversed anchors
            self.assertRefused({cmp.MAIN: text + START_P + '\n'}, 'duplicated start')
            self.assertRefused({cmp.MAIN: text + END_I + '\n'}, 'duplicate end variants')
            self.assertRefused({cmp.MAIN: promoted + START_P + '\n'}, 'duplicate start variants')
            i, j = text.index(START_P), text.index(END_P)
            seg_text, end_line = text[i:j], END_P + '\n'
            reversed_text = text[:i] + text[j:j + len(end_line)] + seg_text + text[j + len(end_line):]
            self.assertRefused({cmp.MAIN: reversed_text}, 'reversed anchors')
            # region moved to another (split) file, or removed from main
            other = cmp.split_path('Persistence', 'conventional')
            rest = text[:i] + text[j:]
            self.assertRefused({cmp.MAIN: rest, other: seg_text}, 'moved to a split file')
            self.assertRefused({cmp.MAIN: text, other: START_I + '\n'}, 'anchor copy in a split file')
            self.assertRefused({cmp.MAIN: text.replace(seg_text, '', 1)}, 'removed from main')
            # anchor not at a line start
            self.assertRefused({cmp.MAIN: text.replace(START_P, '//' + START_P, 1)}, 'commented anchor')

if __name__ == '__main__': unittest.main()
