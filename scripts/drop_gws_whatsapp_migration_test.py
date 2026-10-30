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
from harness_identity_migration import migrate_wire_fixtures as identity
from agents_md_migration import migrate_wire_fixtures as agents_md
from image_explicit_send_migration import migrate_wire_fixtures as image
from drop_gws_whatsapp_migration import (RULE, EDITS, BEFORE, AFTER, OLD_MARKER, forward, reverse,
    migrate_wire_fixtures, reverse_candidate)

SOURCE = Path(__file__).resolve().parent.parent / 'TelegramConcierge'
WIRE = {k: set(RULE['wire_fixtures'][k]) for k in EDITS}
LIFE = {k: set(RULE['lifecycle_captures'][k]) for k in EDITS}
BULLET_ONLY = {'subagent-forced-retry-0', 'subagent-forced-retry-1', 'subagent-forced-retry-2',
               'subagent-midrun-0', 'subagent-midrun-2'}


class DropGwsWhatsAppMigrationTests(unittest.TestCase):
    def fixtures(self, name='local-darwin-arm64-r2.json', os_name='Mac'):
        original = json.loads((Path(__file__).parent / 'fixtures/chat-wire' / name).read_text())['fixtures']
        return image(agents_md(identity(web(chronology(reasoning(read_file(original)))), os_name)))

    def test_rule_is_three_exact_edits(self):
        self.assertEqual({k: len(v) for k, v in WIRE.items()}, {'bullet': 35, 'reminder_auth': 35, 'document_channel': 35})
        self.assertEqual({k: len(v) for k, v in LIFE.items()}, {'bullet': 21, 'reminder_auth': 16, 'document_channel': 16})
        self.assertEqual(LIFE['bullet'] - LIFE['reminder_auth'], BULLET_ONLY)
        self.assertEqual(LIFE['reminder_auth'], LIFE['document_channel'])
        for edit in EDITS:
            b, a = RULE['edits'][edit]['before'], RULE['edits'][edit]['after']
            self.assertNotEqual(b, a)
            self.assertNotIn(b, a)

    def test_rule_matches_the_source(self):
        models = (SOURCE / 'Models/ToolModels.swift').read_text()
        provider = (SOURCE / 'Services/EmailCalendarProvider.swift').read_text()
        self.assertIn('(gh auth, config files)', models)
        self.assertNotIn('gws login', models)
        self.assertIn('currently messaging from.', models)
        self.assertNotIn('(Telegram or WhatsApp)', models)
        self.assertNotIn('Use `gws` for Google Workspace actions.', provider)
        self.assertNotIn('case gws', provider)

    def test_frozen_bodies_change_only_by_the_three_edits(self):
        for filename, os_name in [('local-darwin-arm64-r2.json', 'Mac'),
                                  ('ci-darwin-arm64-r2.json', 'Mac'),
                                  ('ci-linux-x86_64-r2.json', 'Linux')]:
            old = self.fixtures(filename, os_name)
            snapshot = copy.deepcopy(old)
            new = migrate_wire_fixtures(old)
            self.assertEqual(old, snapshot)
            self.assertEqual(len(new), 91)
            changed = set()
            for key in old:
                before = base64.b64decode(old[key]['body_base64'])
                after = base64.b64decode(new[key]['body_base64'])
                if before != after:
                    changed.add(key)
                    restored = after
                    for edit in reversed(EDITS):
                        restored = reverse(restored, edit)
                    self.assertEqual(restored, before)
                    obj = json.loads(after)
                    text = json.dumps(obj)
                    self.assertNotIn('gws', text)
                    self.assertNotIn('WhatsApp', text)
                    self.assertEqual(len(before) - len(after),
                                     sum(len(BEFORE[e]) - len(AFTER[e]) for e in EDITS))
                self.assertEqual(new[key] | {'body_base64': old[key]['body_base64']}, old[key])
            self.assertEqual(changed, WIRE['bullet'])
            untouched = [k for k in old if k not in changed]
            self.assertEqual(len(untouched), 56)
            compare(new, copy.deepcopy(new))
            with self.assertRaises(RuntimeError): compare(new, old)
            with self.assertRaises(RuntimeError): migrate_wire_fixtures(new)

    def test_each_edit_alone_and_in_context(self):
        body = base64.b64decode(self.fixtures()[sorted(WIRE['bullet'])[0]]['body_base64'])
        for edit in EDITS:
            once = forward(body, edit)
            self.assertEqual(reverse(once, edit), body)
            with self.subTest(edit=edit):
                with self.assertRaises(RuntimeError): forward(once, edit)          # already applied
                with self.assertRaises(RuntimeError): reverse(body, edit)          # not applied
                doubled = body.replace(BEFORE[edit], BEFORE[edit] + BEFORE[edit], 1)
                with self.assertRaises(RuntimeError): forward(doubled, edit)       # duplicate
                moved = body.replace(BEFORE[edit], b'', 1).replace(b'"model":', b'"model":"' + OLD_MARKER[edit] + b'","x":', 1)
                with self.assertRaises(RuntimeError): forward(moved, edit)         # wrong context

    def test_inventory_changes_fail(self):
        fixtures = self.fixtures()
        fixtures.pop(sorted(WIRE['bullet'])[0])
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)
        fixtures = self.fixtures()
        outside = next(k for k in fixtures if k not in WIRE['bullet'])
        fixtures[outside] = copy.deepcopy(fixtures[sorted(WIRE['bullet'])[0]])
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)

    def test_an_extra_edit_on_an_unaffected_capture_fails(self):
        fixtures = self.fixtures()
        outside = next(k for k in fixtures if k not in WIRE['bullet'])
        body = base64.b64decode(fixtures[outside]['body_base64'])
        fixtures[outside]['body_base64'] = base64.b64encode(body + b' ' + OLD_MARKER['document_channel']).decode()
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)

    def test_unrelated_mutations_are_not_hidden(self):
        expected = migrate_wire_fixtures(self.fixtures())
        mutant = copy.deepcopy(expected)
        key = sorted(WIRE['bullet'])[0]
        obj = json.loads(base64.b64decode(mutant[key]['body_base64']))
        obj['model'] = 'unreviewed-model'
        mutant[key]['body_base64'] = base64.b64encode(swift_bytes(obj)).decode()
        with self.assertRaises(RuntimeError): compare(expected, mutant)

    def test_lifecycle_reverse_over_the_frozen_captures(self):
        for name in ['ci-darwin-arm64-r2.json', 'ci-linux-x86_64-r2.json', 'ci-darwin-arm64-r2-image20260907.json', 'ci-darwin-arm64-r2-image20261028.json']:
            data = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle' / name).read_text())['fixtures']
            reference = {c['fixture']: base64.b64decode(c['body']) for c in data['captures']}
            # The frozen evidence: the bullet in 22 reference captures (21 +
            # loop-exhausted-1, which the candidate no longer sends), the two
            # tool texts in 17 (16 + loop-exhausted-1).
            for edit in EDITS:
                names = {n for n, b in reference.items() if OLD_MARKER[edit] in b}
                self.assertEqual(names - {'loop-exhausted-1'}, LIFE[edit], (name, edit))
            # A synthetic candidate: the reference captures (minus the one the
            # candidate no longer sends) with the r12 edits applied.
            captures = []
            for n, b in sorted(reference.items()):
                if n == 'loop-exhausted-1':
                    continue
                cand = b
                for edit in EDITS:
                    if n in LIFE[edit]:
                        cand = forward(cand, edit)
                captures.append({'fixture': n, 'body': base64.b64encode(cand).decode(), 'headers': {'x': n}})
            actual = {'captures': captures, 'observations': {'kept': True}}
            restored = reverse_candidate(actual)
            self.assertEqual(restored['observations'], {'kept': True})
            for c in restored['captures']:
                self.assertEqual(base64.b64decode(c['body']), reference[c['fixture']], c['fixture'])
                self.assertEqual(c['headers'], {'x': c['fixture']})
            for n in sorted(BULLET_ONLY):
                only = next(c for c in restored['captures'] if c['fixture'] == n)
                self.assertNotIn(OLD_MARKER['reminder_auth'], base64.b64decode(only['body']))
            missing = copy.deepcopy(actual); missing['captures'] = [c for c in missing['captures'] if c['fixture'] != 'subagent-midrun-0']
            with self.assertRaises(RuntimeError): reverse_candidate(missing)
            unmigrated = copy.deepcopy(actual)
            first = next(c for c in unmigrated['captures'] if c['fixture'] == 'manual-0')
            first['body'] = base64.b64encode(reference['manual-0']).decode()
            with self.assertRaises(RuntimeError): reverse_candidate(unmigrated)
            stray = copy.deepcopy(actual)
            plain = next(c for c in stray['captures'] if c['fixture'] not in LIFE['bullet'])
            plain['body'] = base64.b64encode(base64.b64decode(plain['body']) + OLD_MARKER['bullet']).decode()
            with self.assertRaises(RuntimeError): reverse_candidate(stray)


if __name__ == '__main__':
    unittest.main()
