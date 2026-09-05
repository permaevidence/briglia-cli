#!/usr/bin/env python3
"""Negative tests for the P0 lifecycle comparator (no compiled binary needed)."""
import base64
import copy
import unittest
from chat_lifecycle_baseline import compare, expected_affinity

class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.fixture = {'observations': {'prune': {'decision': 'pruned', 'saved': 90},
                        'loop': {'prompt': 1200, 'completion': 80, 'tools': ['read_file']}},
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
                   lambda f: f['observations'].pop('loop')]
        for mutate in changes:
            fixture = copy.deepcopy(self.fixture)
            mutate(fixture)
            with self.assertRaises(RuntimeError): compare(self.fixture, fixture)

    def test_affinity_domains(self):
        main = expected_affinity('main:33333333-3333-4333-8333-333333333333')
        self.assertEqual(main, '4440c3e8db11ffab777002117787fc6e')
        self.assertNotEqual(main, expected_affinity('subagent:p0001'))
        self.assertNotEqual(main, expected_affinity('archive'))

if __name__ == '__main__': unittest.main()
