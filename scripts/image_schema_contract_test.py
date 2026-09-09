#!/usr/bin/env python3
"""Reviewed OpenAI-only schema migration; frozen Gemini/P0 fixtures stay intact."""
import base64
import copy
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "scripts/fixtures/image-tool/schema-v1.json"
ENGINE = {
    "type": "string",
    "description": "Optional image engine. Use 'fast' by default. Choose 'precise' for careful edits that must preserve subjects, faces, text, or layout. Configured model overrides are respected.",
    "enum": ["fast", "precise"],
}
QUALITY = "Optional rendering quality. Use 'auto' by default; use 'high' when detail and fidelity matter more than latency. 'xhigh' and 'max' cost more and are for explicit user requests for maximum detail. On older configured models they are reduced to 'high', with a note in the result."
BACKGROUND = "Optional background behavior. GPT Image 2.5 supports 'transparent' with png or webp; transparent with jpeg is rejected. Older configured models use 'auto' instead of transparent, with a note in the result."


def migrate(before):
    """Only the exact reviewed legacy OpenAI schema is eligible."""
    expected = json.loads(FIXTURE.read_text())["before"]
    if before != expected:
        raise ValueError("Unexpected legacy image schema; review the change explicitly")
    after = copy.deepcopy(before)
    fn = after["function"]
    fn["description"] = fn["description"].replace("OpenAI GPT Image,", "OpenAI GPT Image 2.5,", 1)
    props = fn["parameters"]["properties"]
    props["engine"] = copy.deepcopy(ENGINE)
    props["size"]["description"] = props["size"]["description"].replace("GPT Image 2 output", "GPT Image 2.5 output", 1)
    props["quality"]["description"] = QUALITY
    props["quality"]["enum"] = ["auto", "low", "medium", "high", "xhigh", "max"]
    props["background"]["description"] = BACKGROUND
    props["background"]["enum"] = ["auto", "opaque", "transparent"]
    return after


class Tests(unittest.TestCase):
    def test_reviewed_migration(self):
        fixture = json.loads(FIXTURE.read_text())
        self.assertEqual(migrate(fixture["before"]), fixture["after"])
        self.assertEqual(fixture["source"], "1b9c1f6")
        with self.assertRaises(ValueError):
            migrate(fixture["after"])

    def test_unrelated_changes_are_not_migrated_away(self):
        before = json.loads(FIXTURE.read_text())["before"]
        mutations = [
            lambda x: x["function"]["parameters"]["required"].append("source_image"),
            lambda x: x["function"]["parameters"]["properties"]["prompt"].update(type="integer"),
            lambda x: x["function"].update(name="different_tool"),
            lambda x: x["function"]["parameters"]["properties"]["source_image"].update(description="changed"),
        ]
        for mutation in mutations:
            candidate = copy.deepcopy(before)
            mutation(candidate)
            with self.assertRaises(ValueError):
                migrate(candidate)

    def test_candidate_negative_controls(self):
        fixture = json.loads(FIXTURE.read_text())
        expected = migrate(fixture["before"])
        for key in ["engine", "quality", "background"]:
            candidate = copy.deepcopy(fixture["after"])
            candidate["function"]["parameters"]["properties"][key]["enum"].append("unreviewed")
            self.assertNotEqual(expected, candidate)
        candidate = copy.deepcopy(fixture["after"])
        candidate["function"]["parameters"]["properties"]["prompt"]["description"] += " unrelated"
        self.assertNotEqual(expected, candidate)

    def test_historical_p0_image_tools_are_gemini(self):
        for platform in ["darwin-arm64", "linux-x86_64"]:
            for kind, count in [("chat-wire", 35), ("chat-lifecycle", 17)]:
                fixture = json.loads((ROOT / f"scripts/fixtures/{kind}/ci-{platform}-r2.json").read_text())["fixtures"]
                bodies = ([item["body"] for item in fixture["captures"]] if kind == "chat-lifecycle"
                          else [item["body_base64"] for item in fixture.values()])
                images = []
                for body in bodies:
                    images.extend(t for t in json.loads(base64.b64decode(body)).get("tools", []) or []
                                  if t.get("function", {}).get("name") == "generate_image")
                self.assertEqual(len(images), count)
                self.assertTrue(all("using Gemini" in t["function"]["description"] for t in images))


if __name__ == "__main__":
    binary = pathlib.Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else None
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Tests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        sys.exit(1)
    if binary:
        with tempfile.TemporaryDirectory(prefix="briglia-image-schema-") as tmp:
            output = pathlib.Path(tmp) / "schema.json"
            subprocess.run([str(binary), "__image-tool-selftest", "--capture-schema", str(output)], check=True, timeout=60)
            fixture = json.loads(FIXTURE.read_text())
            if json.loads(output.read_text()) != migrate(fixture["before"]):
                raise RuntimeError("Built OpenAI schema differs from the reviewed migration")
            print("Built OpenAI schema matches the narrow migration; frozen P0 fixtures unchanged.")
