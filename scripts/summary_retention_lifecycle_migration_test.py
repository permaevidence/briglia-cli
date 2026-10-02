import base64
import copy
import json
import unittest
from summary_retention_lifecycle_migration import migrate_candidate, RULE

COVERAGE = {"complete": False, "end": 721692800, "endOffsetSeconds": 0, "files": ["a.swift"], "start": 721692700,
            "startOffsetSeconds": 0, "version": 1}


def raw_bytes(with_coverage, coverage=COVERAGE, at_end=False):
    """Foundation-like compact unsorted bytes; the key in the middle or last."""
    cov = '"prunedContextSummaryCoverage":' + json.dumps(coverage, separators=(',', ':'))
    head = '[{"id":"u","role":"user","content":"q"},{"id":"a","role":"assistant"'
    tail = ',"prunedContextSummary":"S","content":"reply"}]'
    if not with_coverage:
        return (head + tail).encode()
    if at_end:
        return (head + tail[:-2] + ',' + cov + '}]').encode()
    return (head + ',' + cov + tail).encode()


def fixture(at_end=False):
    observations = {}
    for name in RULE['scenarios']:
        anchor = {"id": "a", "role": "assistant", "prunedContextSummary": "S", "content": "reply", RULE['key']: copy.deepcopy(COVERAGE)}
        user = {"id": "u", "role": "user", "content": "q"}
        observations[name] = {"durable": [user, copy.deepcopy(anchor)], "snapshot": [user, copy.deepcopy(anchor)],
                              "rawConversation": base64.b64encode(raw_bytes(True, at_end=at_end)).decode()}
    observations["persistence"] = {"rawConversation": base64.b64encode(b'[]').decode()}
    captures = [{"fixture": "manual-0", "body": base64.b64encode(b'{"model":"m","messages":[]}').decode()}]
    return {"observations": observations, "captures": captures}


class Tests(unittest.TestCase):
    def test_exact_removal(self):
        for at_end in (False, True):
            migrated = migrate_candidate(fixture(at_end))
            for name in RULE['scenarios']:
                item = migrated['observations'][name]
                self.assertNotIn(RULE['key'], item['durable'][1])
                self.assertNotIn(RULE['key'], item['snapshot'][1])
                self.assertEqual(base64.b64decode(item['rawConversation']), raw_bytes(False))
            with self.assertRaises(RuntimeError): migrate_candidate(migrated)  # exactly once, never twice

    def test_refusals(self):
        def broken(mutate):
            f = fixture(); mutate(f); return f
        first = RULE['scenarios'][0]
        cases = [
            lambda f: f['observations'][first]['durable'][1].pop(RULE['key']),
            lambda f: f['observations'][first]['durable'][0].update({RULE['key']: COVERAGE}),
            lambda f: f['observations']['persistence'].update(durable=[{"prunedContextSummary": "S", RULE['key']: COVERAGE}]),
            lambda f: f['observations']['persistence'].update(rawConversation=base64.b64encode(raw_bytes(True)).decode()),
            lambda f: f['observations'][first]['durable'][1].update(demotedPruneSummaries=[{"line": "x"}]),
            lambda f: f['observations']['persistence'].update(rawConversation=base64.b64encode(b'[{"demotedPruneSummaries":[]}]').decode()),
            lambda f: f['captures'].append({"fixture": "x-0", "body": base64.b64encode(b'{"startOffsetSeconds":0}').decode()}),
            lambda f: f['captures'].append({"fixture": "x-1", "body": base64.b64encode(b'{"prunedContextSummaryCoverage":{}}').decode()}),
            lambda f: f['observations'][first]['durable'][1][RULE['key']].update(version=2),
            lambda f: f['observations'][first]['durable'][1][RULE['key']].update(files=[str(i) for i in range(21)]),
            lambda f: f['observations'][first]['durable'][1][RULE['key']].update(start=721692900),
            lambda f: f['observations'][first]['snapshot'][1][RULE['key']].update(complete=True),
            lambda f: f['observations'][first]['durable'][1].pop('prunedContextSummary'),
            lambda f: f['observations'][first].update(rawConversation=base64.b64encode(raw_bytes(False)).decode()),
        ]
        for i, mutate in enumerate(cases):
            with self.subTest(case=i), self.assertRaises(RuntimeError):
                migrate_candidate(broken(mutate))

    def test_rule_inventory(self):
        self.assertEqual(len(RULE['scenarios']), 13)
        self.assertEqual(RULE['views'], ['durable', 'snapshot'])


if __name__ == '__main__': unittest.main()
