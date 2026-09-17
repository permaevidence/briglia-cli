import base64
import copy
import json
import unittest
from pathlib import Path
from chat_wire_baseline import compare
from read_file_description_migration import migrate_wire_fixtures as migrate_read_file
from reasoning_history_removal_migration import migrate_wire_fixtures as migrate_reasoning_history
from chronology_wire_migration import migrate_wire_fixtures as migrate_chronology
from web_subagent_r2_wire_migration import (migrate_wire_fixtures, migrate_body, swift_bytes, RULE, MARKDOWN_LINE, REPLY_LINE,
                                            BULLET_BEFORE, BULLET_AFTER, REMOVED, REPLACED)

MODELS = ('glm-5.3', 'kimi-k3', 'kimi-k2.7-code', 'qwen3.8-max', 'custom-model', 'local-model', 'anthropic_claude-sonnet-4')
TOOL_INDICES = (6, 8, 9, 10)
SUBAGENTS_OFF_INDEX = 7


def system_text(message):
    content = message['content']
    return content if isinstance(content, str) else content[0]['text']


class WebSubagentR2WireMigrationTests(unittest.TestCase):
    def fixtures(self, name):
        return json.loads((Path(__file__).parent / 'fixtures/chat-wire' / name).read_text())['fixtures']

    def test_every_body_gains_the_line_and_exactly_28_tool_bodies_change_schemas(self):
        for name in ('ci-darwin-arm64-r2.json', 'ci-linux-x86_64-r2.json', 'local-darwin-arm64-r2.json'):
            fixtures = migrate_chronology(migrate_reasoning_history(migrate_read_file(self.fixtures(name))))
            migrated = migrate_wire_fixtures(fixtures)
            self.assertEqual(len(fixtures), 91)
            changed = sorted(k for k in fixtures if fixtures[k] != migrated[k])
            self.assertEqual(changed, sorted(fixtures))            # the line reaches all 91
            self.assertEqual(sorted(RULE['line_fixtures']), sorted(fixtures))
            self.assertEqual(sorted(RULE['tool_fixtures']), sorted(f'{m}-{i}' for m in MODELS for i in TOOL_INDICES))
            for key in fixtures:
                for field in ('target', 'headers', 'scratch_path_substitutions'):
                    self.assertEqual(fixtures[key][field], migrated[key][field])
                old = json.loads(base64.b64decode(fixtures[key]['body_base64']))
                new_bytes = base64.b64decode(migrated[key]['body_base64'])
                new = json.loads(new_bytes)
                self.assertEqual(swift_bytes(new), new_bytes)
                index = int(key.rsplit('-', 1)[1])
                # The line: once, right after the Markdown line, in the first system message; nothing else in messages changes.
                old_prompt, new_prompt = system_text(old['messages'][0]), system_text(new['messages'][0])
                self.assertEqual(old['messages'][0]['role'], 'system')
                self.assertEqual(new_prompt.count(REPLY_LINE), 1)
                self.assertIn(MARKDOWN_LINE + '\n' + REPLY_LINE + '\n', new_prompt)
                self.assertNotIn(REPLY_LINE, old_prompt)
                self.assertEqual(old['messages'][1:], new['messages'][1:])
                if isinstance(old['messages'][0]['content'], list):      # Anthropic: the cache_control block is kept on the prompt
                    self.assertEqual(old['messages'][0]['content'][0]['cache_control'], new['messages'][0]['content'][0]['cache_control'])
                for field in old:
                    if field not in ('messages', 'tools'):
                        self.assertEqual(old[field], new[field])
                old_tools, new_tools = old.get('tools') or [], new.get('tools') or []
                old_names = [t['function']['name'] for t in old_tools]
                new_names = [t['function']['name'] for t in new_tools]
                if index in TOOL_INDICES:
                    self.assertEqual(old_names[:2], REMOVED)
                    self.assertEqual(new_names, old_names[2:])
                    self.assertNotIn('web_search', new_names)
                    for tool_old, tool_new in zip(old_tools[2:], new_tools):
                        n = tool_old['function']['name']
                        if n in REPLACED:
                            self.assertEqual(tool_old, REPLACED[n]['before'])
                            self.assertEqual(tool_new, REPLACED[n]['after'])
                        else:
                            self.assertEqual(tool_old, tool_new)
                    agent = next(t for t in new_tools if t['function']['name'] == 'Agent')
                    self.assertIn('Web', agent['function']['parameters']['properties']['subagent_type']['enum'])
                    self.assertIn('deliverable', agent['function']['parameters']['properties'])
                    self.assertIn('refresh', next(t for t in new_tools if t['function']['name'] == 'web_fetch')['function']['parameters']['properties'])
                    self.assertIn('kind', next(t for t in new_tools if t['function']['name'] == 'subagent_manage')['function']['parameters']['properties'])
                    self.assertEqual(new_prompt.replace(REPLY_LINE + '\n', '', 1), old_prompt.replace(BULLET_BEFORE + '\n', BULLET_AFTER + '\n', 1))
                    self.assertEqual(new_prompt.count(BULLET_AFTER), 1)
                    self.assertNotIn(BULLET_BEFORE, new_prompt)
                else:
                    self.assertEqual(old_tools, new_tools)
                    self.assertEqual(new_prompt.replace(REPLY_LINE + '\n', '', 1), old_prompt)
                    self.assertNotIn(BULLET_AFTER, new_prompt)
                    if index == SUBAGENTS_OFF_INDEX:
                        self.assertEqual(old_names[:2], REMOVED)             # O5: legacy tools stay while subagents are off
                        self.assertNotIn('Agent', old_names)
                        self.assertIn(BULLET_BEFORE, new_prompt)
            compare(migrated, migrate_wire_fixtures(fixtures))
            with self.assertRaises(RuntimeError): compare(migrated, fixtures)
            with self.assertRaises(RuntimeError): migrate_wire_fixtures(migrated)   # a second line is refused, never inserted

    def test_body_rules(self):
        prompt = 'intro\n' + MARKDOWN_LINE + '\n\nrules\n' + BULLET_BEFORE + '\nmore\n'
        tools = [copy.deepcopy(REPLACED['web_fetch']['before']),
                 {'function': {'name': 'read_file', 'description': 'r', 'parameters': {}}, 'type': 'function'},
                 copy.deepcopy(REPLACED['Agent']['before']), copy.deepcopy(REPLACED['subagent_manage']['before'])]
        legacy = [{'function': {'name': n, 'description': 'legacy', 'parameters': {}}, 'type': 'function'} for n in REMOVED]
        body = swift_bytes({'messages': [{'content': prompt, 'role': 'system'}, {'content': 'hi', 'role': 'user'}], 'model': 'm', 'tools': legacy + tools})
        migrated, line, tool = migrate_body(body)
        self.assertEqual((line, tool), (1, 1))
        new = json.loads(migrated)
        self.assertEqual([t['function']['name'] for t in new['tools']], ['web_fetch', 'read_file', 'Agent', 'subagent_manage'])
        self.assertEqual(new['tools'][0], REPLACED['web_fetch']['after'])
        self.assertEqual(new['tools'][2], REPLACED['Agent']['after'])
        self.assertEqual(new['tools'][3], REPLACED['subagent_manage']['after'])
        self.assertEqual(new['messages'][0]['content'], 'intro\n' + MARKDOWN_LINE + '\n' + REPLY_LINE + '\n\nrules\n' + BULLET_AFTER + '\nmore\n')
        # Subagents off: legacy tools kept, only the line.
        off = swift_bytes({'messages': [{'content': prompt, 'role': 'system'}], 'model': 'm', 'tools': legacy + tools[:2]})
        migrated_off, line, tool = migrate_body(off)
        self.assertEqual((line, tool), (1, 0))
        self.assertEqual(json.loads(migrated_off)['tools'], legacy + tools[:2])
        self.assertIn(BULLET_BEFORE, json.loads(migrated_off)['messages'][0]['content'])
        # No system message → untouched.
        none = swift_bytes({'messages': [{'content': 'hi', 'role': 'user'}], 'model': 'm'})
        self.assertEqual(migrate_body(none), (none, 0, 0))
        # Anthropic shape: the cache_control block stays on the prompt.
        anthropic = swift_bytes({'messages': [{'content': [{'cache_control': {'type': 'ephemeral'}, 'text': prompt, 'type': 'text'}], 'role': 'system'}], 'model': 'm'})
        new = json.loads(migrate_body(anthropic)[0])
        self.assertEqual(new['messages'][0]['content'][0]['cache_control'], {'type': 'ephemeral'})
        self.assertIn(REPLY_LINE, new['messages'][0]['content'][0]['text'])
        with self.assertRaises(RuntimeError):
            migrate_body(migrated)                                                   # already carries the line
        with self.assertRaises(RuntimeError):
            migrate_body(b'{"messages": [{"role":"system","content":"x"}]}')       # not byte-stable Foundation JSON
        with self.assertRaises(RuntimeError):
            migrate_body(swift_bytes({'messages': [{'content': 'no markdown line here', 'role': 'system'}], 'model': 'm'}))
        with self.assertRaises(RuntimeError):                                        # a changed pinned schema is refused
            altered = copy.deepcopy(tools); altered[2]['function']['description'] += ' changed'
            migrate_body(swift_bytes({'messages': [{'content': prompt, 'role': 'system'}], 'model': 'm', 'tools': legacy + altered}))
        with self.assertRaises(RuntimeError):                                        # legacy tools not at the head
            migrate_body(swift_bytes({'messages': [{'content': prompt, 'role': 'system'}], 'model': 'm', 'tools': tools[:1] + legacy + tools[1:]}))
        with self.assertRaises(RuntimeError):                                        # tool body with subagents on but no legacy web bullet
            migrate_body(swift_bytes({'messages': [{'content': 'intro\n' + MARKDOWN_LINE + '\n', 'role': 'system'}], 'model': 'm', 'tools': legacy + tools}))
        with self.assertRaises(ValueError): migrate_body(b'not json')
        wrong = copy.deepcopy(self.fixtures('local-darwin-arm64-r2.json'))
        del wrong['glm-5.3-6']
        with self.assertRaises(RuntimeError): migrate_wire_fixtures(migrate_chronology(migrate_reasoning_history(migrate_read_file(wrong))))

    def test_rule_file_is_self_consistent(self):
        self.assertEqual(RULE['revision'], 1)
        for name, pair in REPLACED.items():
            self.assertEqual(pair['before']['function']['name'], name)
            self.assertEqual(pair['after']['function']['name'], name)
            self.assertNotEqual(pair['before'], pair['after'])
        self.assertEqual(set(RULE['tool_fixtures']) - set(RULE['line_fixtures']), set())
        self.assertIn('when available', REPLY_LINE)
        self.assertIn('never guess a URL or an address', REPLY_LINE)
        self.assertIn("Don't add unnecessary links", REPLY_LINE)


if __name__ == '__main__':
    unittest.main()
