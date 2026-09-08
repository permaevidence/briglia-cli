import copy
import unittest
from prune_lifecycle_migration_test import MigrationTests
from active_compaction_lifecycle_migration import verify_migration
from chat_lifecycle_baseline import compare

class ActiveMigrationTests(unittest.TestCase):
    def setUp(self):
        prior = MigrationTests(); prior.setUp()
        self.old, self.new = prior.old, prior.new
        self.new['observations']['loop-exhausted'] = {'ownerRequired': True}
        self.new['captures'] = [c for c in self.new['captures'] if c['fixture'] != 'loop-exhausted-1']
    def test_exact(self): verify_migration(self.old, self.new, compare)
    def test_negatives(self):
        for change in [
            lambda x: x['observations']['loop-exhausted'].update(ownerRequired=False),
            lambda x: x['captures'][0].update(body='e30='),
            lambda x: x['observations']['loop-tools'].update(measuredTools=0),
            lambda x: x['captures'].append(next(c for c in self.old['captures'] if c['fixture'] == 'loop-exhausted-1')),
        ]:
            candidate = copy.deepcopy(self.new); change(candidate)
            with self.assertRaises(RuntimeError): verify_migration(self.old, candidate, compare)

if __name__ == '__main__': unittest.main()
