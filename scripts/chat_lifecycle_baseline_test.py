#!/usr/bin/env python3
"""Negative tests for the P0 lifecycle comparator (no compiled binary needed)."""
import base64
import copy
import unittest
import tempfile
from pathlib import Path
from chat_lifecycle_baseline import compare, expected_affinity, freeze_fallback_prompt_day

class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.fixture = {'observations': {'prune': {'decision': 'pruned', 'saved': 90},
                        'loop': {'prompt': 1200, 'completion': 80, 'tools': ['read_file']},
                        'persistence': {'rawConversation': 'e30=', 'mindEntries': ['conversation.json']}},
                        'captures': [{'fixture': 'loop-0', 'body': base64.b64encode(b'{"role":"tool","content":"x"}').decode(),
                                      'headers': {'x-opencode-session': 'fixed'}, 'target': '/v1/chat/completions'}]}

    def test_equal(self):
        compare(self.fixture, copy.deepcopy(self.fixture))

    def test_mutations_fail(self):
        changes = [lambda f: f['observations']['prune'].update(decision='underBudget'),
                   lambda f: f['observations']['prune'].update(saved=89),
                   lambda f: f['observations']['loop'].update(prompt=1199),
                   lambda f: f['observations']['loop'].update(completion=None),
                   lambda f: f['observations']['loop'].update(tools=[]),
                   lambda f: f['captures'][0].update(body=base64.b64encode(b'{"role":"user","content":"x"}').decode()),
                   lambda f: f['captures'][0].update(body=base64.b64encode(b'{ "role":"tool","content":"x"}').decode()),
                   lambda f: f['captures'][0]['headers'].update(extra='header'),
                   lambda f: f['captures'][0].update(target='/responses'),
                   lambda f: f['captures'].clear(),
                   lambda f: f['observations'].pop('loop'),
                   lambda f: f['observations']['persistence'].update(rawConversation='eyB9'),
                   lambda f: f['observations']['persistence']['mindEntries'].append('responses.json')]
        for mutate in changes:
            fixture = copy.deepcopy(self.fixture)
            mutate(fixture)
            with self.assertRaises(RuntimeError): compare(self.fixture, fixture)

    def test_affinity_domains(self):
        main = expected_affinity('main:33333333-3333-4333-8333-333333333333')
        self.assertEqual(main, '4440c3e8db11ffab777002117787fc6e')
        self.assertNotEqual(main, expected_affinity('subagent:p0001'))
        self.assertNotEqual(main, expected_affinity('archive'))

    def test_calendar_date_bytes_remain_compared(self):
        expected = copy.deepcopy(self.fixture)
        actual = copy.deepcopy(self.fixture)
        expected['captures'][0]['body'] = base64.b64encode(b'Saturday, September 5, 2026 (GMT)').decode()
        actual['captures'][0]['body'] = base64.b64encode(b'Sunday, September 6, 2026 (GMT)').decode()
        with self.assertRaises(RuntimeError):
            compare(expected, actual)

    def test_fallback_clock_targets_actual_builder_before_and_after_p1(self):
        for owner in ('OpenRouterService.swift', 'OpenRouterService+Preparation.swift'):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                service = root / 'TelegramConcierge/Services'
                service.mkdir(parents=True)
                snapshot = 'let currentDate = dateFormatter.string(from: Date())'
                (service / 'OpenRouterService.swift').write_text(snapshot)
                target = service / owner
                target.write_text(target.read_text() + '\n' if target.exists() else '')
                with target.open('a') as f:
                    f.write('let currentDate = dateFormatter.string(from: turnStartDate ?? Date())')
                freeze_fallback_prompt_day(root)
                self.assertIn('turnStartDate ?? Date(timeIntervalSince1970: 1788609600)', target.read_text())
                self.assertIn(snapshot, (service / 'OpenRouterService.swift').read_text())
                with self.assertRaises(RuntimeError): freeze_fallback_prompt_day(root)

    def test_two_fallback_clock_owners_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            service = root / 'TelegramConcierge/Services'
            service.mkdir(parents=True)
            for name in ('OpenRouterService.swift', 'OpenRouterService+Preparation.swift'):
                (service / name).write_text('turnStartDate ?? Date()')
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                freeze_fallback_prompt_day(root)
            self.assertTrue(all(p.read_text() == 'turnStartDate ?? Date()' for p in service.iterdir()))

if __name__ == '__main__': unittest.main()
