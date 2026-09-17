import base64
import copy
import json
import unittest
from pathlib import Path
from chat_lifecycle_baseline import compare
from read_file_description_migration import migrate_lifecycle as migrate_read_file
from reasoning_history_removal_migration import migrate_lifecycle as migrate_reasoning_history
from subagent_dialogue_compaction_lifecycle_migration import migrate_lifecycle as migrate_subagent_dialogue
from web_subagent_r2_lifecycle_migration import (reverse_candidate, reverse_capture_body, verify_migration, RULE, CAPTURES,
                                                 WITH_LINE, WITHOUT_LINE, LINE, MARKDOWN)

FIXTURES = ('local-darwin-arm64-r2.json', 'ci-darwin-arm64-r2.json', 'ci-darwin-arm64-r2-image20260907.json', 'ci-linux-x86_64-r2.json')
R5_RULE = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle/newest-turn-protection-r5.json').read_text())
R5_ONLY = ('automatic-protected-0', 'exhausted-protected-0')
R4_DROPPED = ('loop-exhausted-1',)   # pinned-SOURCE only: the candidate answers loop-exhausted with one request since r4


def add_line(fixtures):
    """A synthetic R2 candidate: the reference with the line added wherever the reply-style
    section is, plus the two r5-only requests built from their pinned templates."""
    result = copy.deepcopy(fixtures)
    result['captures'] = [c for c in result['captures'] if c['fixture'] not in R4_DROPPED]
    headers = next(c for c in result['captures'] if c['fixture'] == 'over-prunable-0')['headers']
    for name in R5_ONLY:
        pinned = R5_RULE['captures'][name]
        result['captures'].append({'fixture': name, 'body': pinned['body_template_base64'], 'headers': headers,
                                   'method': pinned['method'], 'target': pinned['target']})
    for capture in result['captures']:
        body = base64.b64decode(capture['body'])
        if body.count(WITHOUT_LINE) == 1:
            capture['body'] = base64.b64encode(body.replace(WITHOUT_LINE, WITH_LINE, 1)).decode()
    return result


def without_r4_dropped(fixtures):
    result = copy.deepcopy(fixtures)
    result['captures'] = [c for c in result['captures'] if c['fixture'] not in R4_DROPPED]
    return result


def without_r5_only(fixtures):
    result = copy.deepcopy(fixtures)
    result['captures'] = [c for c in result['captures'] if c['fixture'] not in R5_ONLY]
    return result


class WebSubagentR2LifecycleMigrationTests(unittest.TestCase):
    def fixtures(self, name):
        return json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle' / name).read_text())['fixtures']

    def test_rule_names_every_prompt_carrying_capture(self):
        self.assertEqual(len(CAPTURES), 46)
        # The 45 reference captures with the reply-style section, plus the two r5-only requests
        # whose pinned templates carry the main prompt (recorded before R2, so without the line).
        for name in R5_ONLY:
            self.assertIn(name, CAPTURES)
            template = base64.b64decode(R5_RULE['captures'][name]['body_template_base64'])
            self.assertEqual(template.count(WITHOUT_LINE), 1)
            self.assertNotIn(LINE, template)
        for name, pinned in R5_RULE['captures'].items():
            template = base64.b64decode(pinned['body_template_base64'])
            self.assertEqual(MARKDOWN in template, name in CAPTURES)
        for fixture in FIXTURES:
            reference = self.fixtures(fixture)
            with_section = sorted(c['fixture'] for c in reference['captures'] if MARKDOWN in base64.b64decode(c['body']))
            self.assertEqual(with_section, sorted((CAPTURES - set(R5_ONLY)) | set(R4_DROPPED)))
            self.assertEqual(len(with_section), 45)

    def test_reversal_restores_the_reference_and_refuses_the_rest(self):
        for fixture in FIXTURES:
            reference = migrate_subagent_dialogue(migrate_reasoning_history(migrate_read_file(self.fixtures(fixture))))
            candidate = add_line(reference)
            self.assertEqual(sum(1 for c in candidate['captures'] if LINE in base64.b64decode(c['body'])), 46)
            restored = reverse_candidate(candidate)
            compare(without_r4_dropped(reference), without_r5_only(restored))
            for name in R5_ONLY:
                self.assertEqual(next(c for c in restored['captures'] if c['fixture'] == name)['body'], R5_RULE['captures'][name]['body_template_base64'])
            self.assertEqual(restored['observations'], reference['observations'])
            for old, new in zip(candidate['captures'], restored['captures']):
                self.assertNotIn(LINE, base64.b64decode(new['body']))
                for field in old:
                    if field != 'body':
                        self.assertEqual(old[field], new[field])
            with self.assertRaises(RuntimeError): compare(reference, candidate)
            partial = {'captures': candidate['captures'][:1] + reference['captures'][1:] + candidate['captures'][-2:], 'observations': reference['observations']}
            with self.assertRaises(RuntimeError): reverse_candidate(partial)            # named captures without the line
            twice = copy.deepcopy(candidate)
            twice['captures'][0]['body'] = base64.b64encode(base64.b64decode(twice['captures'][0]['body']).replace(WITH_LINE, WITH_LINE + LINE, 1)).decode()
            with self.assertRaises(RuntimeError): reverse_candidate(twice)              # two lines
            missing = copy.deepcopy(candidate)
            missing['captures'] = [c for c in missing['captures'] if c['fixture'] != 'manual-0']
            with self.assertRaises(RuntimeError): reverse_candidate(missing)            # a named capture absent

    def test_capture_rules(self):
        body = b'{"messages":[{"content":"intro\\n' + WITH_LINE + b'\\nrest","role":"system"}]}'
        self.assertEqual(reverse_capture_body('manual-0', body), b'{"messages":[{"content":"intro\\n' + WITHOUT_LINE + b'\\nrest","role":"system"}]}')
        self.assertEqual(reverse_capture_body('exhausted-protected-0', body), b'{"messages":[{"content":"intro\\n' + WITHOUT_LINE + b'\\nrest","role":"system"}]}')
        with self.assertRaises(RuntimeError): reverse_capture_body('manual-0', reverse_capture_body('manual-0', body))   # already restored
        with self.assertRaises(RuntimeError): reverse_capture_body('summarizer-x', body)                               # unnamed with the line
        with self.assertRaises(RuntimeError): reverse_capture_body('summarizer-x', b'{"c":"' + WITHOUT_LINE + b'"}')    # unnamed with the section
        self.assertEqual(reverse_capture_body('summarizer-x', b'{"messages":[]}'), b'{"messages":[]}')
        self.assertEqual(RULE['revision'], 1)

    def test_verify_delegates_to_r7(self):
        calls = []
        import web_subagent_r2_lifecycle_migration as module
        original = module.verify_r7
        module.verify_r7 = lambda expected, actual, compare: calls.append((expected, actual))
        try:
            reference = migrate_subagent_dialogue(migrate_reasoning_history(migrate_read_file(self.fixtures('local-darwin-arm64-r2.json'))))
            candidate = add_line(reference)
            verify_migration(reference, candidate, compare)
            self.assertEqual(len(calls), 1)
            compare(without_r4_dropped(reference), without_r5_only(calls[0][1]))
        finally:
            module.verify_r7 = original


if __name__ == '__main__':
    unittest.main()
