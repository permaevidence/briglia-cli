import base64
import copy
import hashlib
import json
import unittest
from keep_summaries_lifecycle_migration import migrate_candidate, KEY

SUMMARY = "S"
RECORD = {"version": 1, "line": "Earlier work 1 Sep 2026 10:00 · full summary: snapshot x.txt",
          "snapshot": {"id": "00000000-0000-4000-9000-000000000003", "basename": "2023-11-14_221320Z_00000000000040009000000000000003.txt", "version": 1}}
STUB = {"version": 1, "summaryDigest": hashlib.sha256(SUMMARY.encode()).hexdigest(), "record": RECORD}


def raw(with_stub=True, at_end=False, stub=STUB):
    head = '[{"id":"u","role":"user","content":"q"},{"id":"a","role":"assistant"'
    tail = ',"prunedContextSummary":"S","content":"reply"}]'
    if not with_stub:
        return (head + tail).encode()
    s = '"' + KEY + '":' + json.dumps(stub, separators=(',', ':'))
    if at_end:
        return (head + tail[:-2] + ',' + s + '}]').encode()
    return (head + ',' + s + tail).encode()


def fixture(at_end=False, stub=STUB):
    anchor = {"id": "a", "role": "assistant", "prunedContextSummary": SUMMARY, "content": "reply", KEY: copy.deepcopy(stub)}
    user = {"id": "u", "role": "user", "content": "q"}
    return {"observations": {"manual": {"durable": [user, copy.deepcopy(anchor)], "snapshot": [user, copy.deepcopy(anchor)],
                                        "rawConversation": base64.b64encode(raw(at_end=at_end, stub=stub)).decode()},
                             "persistence": {"rawConversation": base64.b64encode(b'[]').decode()}},
            "captures": [{"fixture": "manual-0", "body": base64.b64encode(b'{"model":"m","messages":[]}').decode()}]}


class Tests(unittest.TestCase):
    def test_exact_removal(self):
        for at_end in (False, True):
            migrated = migrate_candidate(fixture(at_end))
            item = migrated["observations"]["manual"]
            self.assertTrue(all(KEY not in m for v in ("durable", "snapshot") for m in item[v]))
            self.assertEqual(base64.b64decode(item["rawConversation"]), raw(False))

    def test_serials_renumbered(self):
        f = fixture()
        later = {"id": "00000000-0000-4000-9000-000000000005", "basename": "2023-11-14_221320Z_00000000000040009000000000000005.txt", "version": 1}
        earlier = {"id": "00000000-0000-4000-9000-000000000002", "basename": "2023-11-14_221320Z_00000000000040009000000000000002.txt", "version": 1}
        f["observations"]["manual"]["durable"][1]["pruneArchiveReferences"] = [earlier, later]
        f["captures"][0]["body"] = base64.b64encode(b'{"m":"prune-archives\\/2023-11-14_221320Z_00000000000040009000000000000005.txt"}').decode()
        migrated = migrate_candidate(f)
        refs = migrated["observations"]["manual"]["durable"][1]["pruneArchiveReferences"]
        self.assertEqual(refs[0]["id"], earlier["id"])
        self.assertEqual(refs[1]["id"], "00000000-0000-4000-9000-000000000004")
        self.assertTrue(refs[1]["basename"].endswith("00000000000040009000000000000004.txt"))
        self.assertIn(b"00000000000040009000000000000004", base64.b64decode(migrated["captures"][0]["body"]))

    def test_stub_serial_referenced_elsewhere_refused(self):
        f = fixture()
        f["observations"]["manual"]["durable"][1]["pruneArchiveReferences"] = [RECORD["snapshot"]]
        with self.assertRaises(RuntimeError):
            migrate_candidate(f)

    def test_usage_key(self):
        f = fixture()
        f["observations"]["manual"]["rawUsage"] = base64.b64encode(b'{"lastCompletionTokens":1,"lastPromptRenderKey":"keepsummaries:none","lastPromptTokens":2}').decode()
        migrated = migrate_candidate(f)
        self.assertEqual(base64.b64decode(migrated["observations"]["manual"]["rawUsage"]), b'{"lastCompletionTokens":1,"lastPromptTokens":2}')
        f["observations"]["manual"]["rawUsage"] = base64.b64encode(b'{"lastPromptRenderKey":"' + b"a" * 64 + b'","lastPromptTokens":2}').decode()
        with self.assertRaises(RuntimeError):
            migrate_candidate(f)

    def test_refuses_wrong_digest(self):
        bad = copy.deepcopy(STUB); bad["summaryDigest"] = "0" * 64
        with self.assertRaises(RuntimeError):
            migrate_candidate(fixture(stub=bad))

    def test_refuses_anchor_without_pointer(self):
        f = fixture()
        del f["observations"]["manual"]["durable"][1][KEY]
        with self.assertRaises(RuntimeError):
            migrate_candidate(f)

    def test_refuses_pointer_without_summary(self):
        f = fixture()
        f["observations"]["manual"]["durable"][0][KEY] = copy.deepcopy(STUB)
        with self.assertRaises(RuntimeError):
            migrate_candidate(f)

    def test_refuses_stub_in_request(self):
        f = fixture()
        f["captures"][0]["body"] = base64.b64encode(b'{"messages":[{"prunedContextSummaryStub":1}]}').decode()
        with self.assertRaises(RuntimeError):
            migrate_candidate(f)

    def test_refuses_demotion(self):
        f = fixture()
        f["observations"]["manual"]["durable"][1]["demotedPruneSummaries"] = []
        with self.assertRaises(RuntimeError):
            migrate_candidate(f)

    def test_raw_anchor_without_pointer(self):
        f = fixture()
        f["observations"]["manual"]["rawConversation"] = base64.b64encode(raw(False)).decode()
        with self.assertRaises(RuntimeError):
            migrate_candidate(f)


if __name__ == "__main__":
    unittest.main()
