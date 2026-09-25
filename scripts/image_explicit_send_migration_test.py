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
from image_explicit_send_migration import (RULE, WIRE_NAMES, LIFECYCLE_NAMES, BEFORE, AFTER, swap, unswap,
    migrate_wire_fixtures, reverse_candidate)

SOURCE = Path(__file__).resolve().parent.parent / 'TelegramConcierge'


class ImageExplicitSendMigrationTests(unittest.TestCase):
    def fixtures(self, name='local-darwin-arm64-r2.json', os_name='Mac'):
        original = json.loads((Path(__file__).parent / 'fixtures/chat-wire' / name).read_text())['fixtures']
        return agents_md(identity(web(chronology(reasoning(read_file(original)))), os_name))

    def test_rule_is_one_sentence_swap(self):
        self.assertEqual(len(WIRE_NAMES), 35)
        self.assertEqual(len(LIFECYCLE_NAMES), 16)
        self.assertEqual(RULE['sentence_before'], 'The generated image will be sent to the user in the chat.')
        self.assertTrue(RULE['sentence_after'].startswith('The image is saved and shown to you;'))
        self.assertNotIn('\n', RULE['sentence_after'])
        # Foundation writes non-ASCII raw: the em dash is UTF-8 bytes, not —.
        self.assertIn('—'.encode(), AFTER)
        self.assertNotIn(b'\\u2014', AFTER)

    def test_rule_matches_every_source_variant(self):
        # The two Gemini variants replace the sentence; the OpenAI variant
        # (never in a frozen capture) gains it. No variant keeps the old one.
        models = (SOURCE / 'Models/ToolModels.swift').read_text()
        openrouter = (SOURCE / 'Services/OpenRouterImageService.swift').read_text()
        self.assertEqual(models.count(RULE['sentence_after']), 2)
        self.assertEqual(openrouter.count(RULE['sentence_after']), 1)
        for text in (models, openrouter):
            self.assertNotIn(RULE['sentence_before'], text)

    def test_frozen_bodies_change_only_by_the_sentence(self):
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
                    self.assertEqual(unswap(after), before)
                    self.assertEqual(after.replace(AFTER, BEFORE), before)
                    tools = [t for t in json.loads(after)['tools'] if t['function']['name'] == 'generate_image']
                    self.assertEqual(len(tools), 1)
                    self.assertIn(RULE['sentence_after'], tools[0]['function']['description'])
                    self.assertIn('using Gemini', tools[0]['function']['description'])
                self.assertEqual(new[key] | {'body_base64': old[key]['body_base64']}, old[key])
            self.assertEqual(changed, WIRE_NAMES)
            compare(new, copy.deepcopy(new))
            with self.assertRaises(RuntimeError): compare(new, old)
            with self.assertRaises(RuntimeError): migrate_wire_fixtures(new)

    def test_bodies_without_generate_image_stay_identical(self):
        old = self.fixtures()
        new = migrate_wire_fixtures(old)
        untouched = [k for k in old if k not in WIRE_NAMES]
        self.assertEqual(len(untouched), 56)
        for key in untouched:
            self.assertNotIn(b'generate_image', base64.b64decode(old[key]['body_base64']))
            self.assertEqual(new[key], old[key])

    def test_exact_sentence_is_required(self):
        fixtures = self.fixtures()
        before = base64.b64decode(fixtures[sorted(WIRE_NAMES)[0]]['body_base64'])
        after = swap(before)
        for mutant in [before,
                       after.replace(b'not sent to the user automatically', b'sent to the user automatically'),
                       after.replace(b'use send_document_to_chat', b'use mid_turn_message_user'),
                       after.replace(AFTER, AFTER + AFTER),
                       after.replace(AFTER, AFTER[:-1]),
                       after.replace(AFTER + b' Provide', AFTER + b' Also provide')]:
            with self.subTest(mutant=mutant[:80]), self.assertRaises(RuntimeError):
                unswap(mutant)
        with self.assertRaises(RuntimeError): swap(after)
        # The sentence must sit in the generate_image description, nowhere else.
        moved = before.replace(BEFORE, b'', 1).replace(b'"model":', b'"model":"' + BEFORE + b'","x":', 1)
        with self.assertRaises(RuntimeError): swap(moved)

    def test_inventory_changes_fail(self):
        fixtures = self.fixtures()
        fixtures.pop(sorted(WIRE_NAMES)[0])
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)
        fixtures = self.fixtures()
        outside = next(k for k in fixtures if k not in WIRE_NAMES)
        fixtures[outside] = copy.deepcopy(fixtures[sorted(WIRE_NAMES)[0]])
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(fixtures)

    def test_unrelated_mutations_are_not_hidden(self):
        expected = migrate_wire_fixtures(self.fixtures())
        mutant = copy.deepcopy(expected)
        key = sorted(WIRE_NAMES)[0]
        obj = json.loads(base64.b64decode(mutant[key]['body_base64']))
        obj['model'] = 'unreviewed-model'
        mutant[key]['body_base64'] = base64.b64encode(swift_bytes(obj)).decode()
        with self.assertRaises(RuntimeError): compare(expected, mutant)

    def test_lifecycle_reverse(self):
        body = swap(base64.b64decode(self.fixtures()[sorted(WIRE_NAMES)[0]]['body_base64']))
        plain = base64.b64decode(self.fixtures()[next(k for k in self.fixtures() if k not in WIRE_NAMES)]['body_base64'])
        captures = [{'fixture': n, 'body': base64.b64encode(body).decode(), 'headers': {'x': 'y'}}
                    for n in sorted(LIFECYCLE_NAMES)]
        captures.append({'fixture': 'archive', 'body': base64.b64encode(plain).decode()})
        actual = {'captures': captures, 'observations': {'kept': True}}
        restored = reverse_candidate(actual)
        self.assertEqual(restored['observations'], {'kept': True})
        for c in restored['captures']:
            b = base64.b64decode(c['body'])
            self.assertNotIn(AFTER, b)
            if c['fixture'] in LIFECYCLE_NAMES:
                self.assertEqual(c['headers'], {'x': 'y'})
                self.assertIn(BEFORE, b)
        missing = copy.deepcopy(actual); missing['captures'].pop(0)
        with self.assertRaises(RuntimeError): reverse_candidate(missing)
        stray = copy.deepcopy(actual); stray['captures'][-1]['body'] = base64.b64encode(body).decode()
        with self.assertRaises(RuntimeError): reverse_candidate(stray)
        unmigrated = copy.deepcopy(actual); unmigrated['captures'][0]['body'] = base64.b64encode(unswap(body)).decode()
        with self.assertRaises(RuntimeError): reverse_candidate(unmigrated)

    def test_lifecycle_inventory_is_the_frozen_generate_image_set(self):
        for name in ['local-darwin-arm64-r2.json', 'ci-darwin-arm64-r2.json', 'ci-linux-x86_64-r2.json']:
            data = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle' / name).read_text())['fixtures']
            names = {c['fixture'] for c in data['captures'] if BEFORE in base64.b64decode(c['body'])}
            # The pinned SOURCE's second loop-exhausted request is gone from
            # the candidate since r4; every other generate_image capture remains.
            self.assertEqual(names - LIFECYCLE_NAMES, {'loop-exhausted-1'}, name)
            self.assertTrue(LIFECYCLE_NAMES <= names, name)


if __name__ == '__main__':
    unittest.main()
