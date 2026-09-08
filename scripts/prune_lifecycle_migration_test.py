import base64
import copy
import json
import unittest
from pathlib import Path
from chat_lifecycle_baseline import compare
from prune_lifecycle_migration import verify_migration, SCENARIOS, reference, text

class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.old = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle/ci-darwin-arm64-r2.json').read_text())['fixtures']
        self.new = copy.deepcopy(self.old)
        inventory = self.new['observations']['persistence']['mindEntries']
        inventory.append('prune-archives/')
        for i, name in enumerate(SCENARIOS, 1):
            item = self.new['observations'][name]
            ref = reference(i)
            for key in ['snapshot', 'durable']:
                anchor = next(m for m in item[key] if m.get('prunedContextSummary'))
                anchor['pruneArchiveReferences'] = [ref]
                if 'measuredTokens' in anchor: anchor['measuredTokens'] += len(text(ref)) // 4
            item['rawConversation'] = base64.b64encode(json.dumps(item['durable']).encode()).decode()
            inventory.append('prune-archives/' + ref['basename'])
        inventory.sort()

    def test_exact_additions(self): verify_migration(self.old, self.new, compare)
    def test_rejects_unrelated_changes(self):
        for mutate in [
            lambda x: x['observations']['manual']['snapshot'][0].update(content='changed'),
            lambda x: x['observations']['manual'].update(decision='exhausted'),
            lambda x: x['observations']['manual']['durable'][1]['pruneArchiveReferences'][0].update(basename='../other'),
            lambda x: x['observations']['manual'].update(rawConversation=base64.b64encode(b'[]').decode()),
            lambda x: x['captures'][0].update(body=base64.b64encode(b'changed').decode()),
            lambda x: x['observations']['persistence']['mindEntries'].append('unexpected'),
        ]:
            candidate = copy.deepcopy(self.new); mutate(candidate)
            with self.assertRaises(RuntimeError): verify_migration(self.old, candidate, compare)
    def test_missing_reference_rejected(self):
        self.new['observations']['manual']['snapshot'][1].pop('pruneArchiveReferences')
        with self.assertRaises(RuntimeError): verify_migration(self.old, self.new, compare)

if __name__ == '__main__': unittest.main()
