import base64
import copy
import json
import re
import unittest
from active_compaction_lifecycle_migration_test import ActiveMigrationTests
from chat_lifecycle_baseline import compare
from newest_turn_protection_lifecycle_migration import RULE, SHIFT, verify_migration
from prune_lifecycle_migration import SCENARIOS as R3, reference

DATE_RE = re.compile(RULE['date_pattern'])


class ProtectionRemovalTests(unittest.TestCase):
    def setUp(self):
        prior = ActiveMigrationTests(); prior.setUp()
        self.old, self.new = prior.old, prior.new
        date = DATE_RE.findall(base64.b64decode(next(c for c in self.old['captures'] if c['fixture'] == 'over-prunable-0')['body']).decode())[0]
        # Later r3 scenarios move to the shifted serials.
        for old_serial, name in enumerate(R3, 1):
            if name in RULE['observations'] or old_serial not in SHIFT: continue
            item = self.new['observations'][name]
            for key in ['snapshot', 'durable']:
                anchor = next(m for m in item[key] if m.get('pruneArchiveReferences'))
                anchor['pruneArchiveReferences'] = [reference(SHIFT[old_serial])]
            item['rawConversation'] = base64.b64encode(json.dumps(item['durable']).encode()).decode()
        for name, pinned in RULE['observations'].items():
            self.new['observations'][name] = copy.deepcopy(pinned)
        headers = next(c for c in self.new['captures'] if c['fixture'] == 'over-prunable-0')['headers']
        captures = []
        for capture in self.new['captures']:
            name = capture['fixture']
            if name in RULE['captures']:
                capture = dict(capture, body=self.templated(name, date))
            captures.append(capture)
            if name == 'over-prunable-0':
                captures.append({'fixture': 'exhausted-protected-0', 'body': self.templated('exhausted-protected-0', date), 'headers': headers, 'method': 'POST', 'target': '/v1/chat/completions'})
            if name == 'automatic-prune-0':
                captures.append({'fixture': 'automatic-protected-0', 'body': self.templated('automatic-protected-0', date), 'headers': headers, 'method': 'POST', 'target': '/v1/chat/completions'})
        self.new['captures'] = captures
        entries = self.old['observations']['persistence']['mindEntries'] + ['prune-archives/'] + ['prune-archives/' + reference(s)['basename'] for s in range(1, 14)]
        self.new['observations']['persistence']['mindEntries'] = sorted(entries)

    @staticmethod
    def templated(name, date):
        template = base64.b64decode(RULE['captures'][name]['body_template_base64'])
        return base64.b64encode(template.replace(RULE['date_placeholder'].encode(), date.encode())).decode()

    def test_exact(self): verify_migration(self.old, self.new, compare)

    def test_negatives(self):
        def flip_body(x, name):
            c = next(c for c in x['captures'] if c['fixture'] == name)
            c['body'] = base64.b64encode(base64.b64decode(c['body']) + b' ').decode()
        for change in [
            lambda x: flip_body(x, 'exhausted-protected-0'),
            lambda x: flip_body(x, 'estimated-0'),
            lambda x: x['captures'].pop(next(i for i, c in enumerate(x['captures']) if c['fixture'] == 'automatic-protected-0')),
            lambda x: x['observations']['automatic-protected'].update(decision='unchanged'),
            lambda x: x['observations']['exhausted-after-prune']['durable'][2].pop('prunedContextSummary'),
            lambda x: x['observations']['manual']['durable'][1].update(pruneArchiveReferences=[reference(6)]),
            lambda x: x['observations']['persistence']['mindEntries'].remove('prune-archives/' + reference(13)['basename']),
            lambda x: x['observations']['over-prunable']['snapshot'][0].update(content='changed'),
            lambda x: x['captures'][0].update(body='e30='),
        ]:
            candidate = copy.deepcopy(self.new); change(candidate)
            with self.assertRaises(RuntimeError): verify_migration(self.old, candidate, compare)


if __name__ == '__main__': unittest.main()
