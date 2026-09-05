#!/usr/bin/env python3
"""Negative checks for the independent raw-byte comparison and instrumentation."""
import base64
import copy
import pathlib
import tempfile
import unittest
from chat_wire_baseline import compare, instrument, URL_FILE, URL_LITERAL, validate_scratch_path


class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.reference = {"fixture": {"body_base64": base64.b64encode(b'{"role":"tool"}').decode(),
                          "target": "/v1/chat/completions", "headers": {"host": "127.0.0.1:<capture-port>",
                          "x-session-id": "fixed", "accept": "*/*"}, "scratch_path_substitutions": 1}}

    def test_rejects_mutations(self):
        for mutation in ("space", "role", "truncation", "missing", "extra", "target", "affinity", "accept", "new_header", "missing_header", "substitution"):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(self.reference)
                item = changed["fixture"]
                if mutation in ("space", "role", "truncation"):
                    bodies = {"space": b'{ "role":"tool"}', "role": b'{"role":"user"}', "truncation": b'{"role":'}
                    item["body_base64"] = base64.b64encode(bodies[mutation]).decode()
                elif mutation == "missing": changed.clear()
                elif mutation == "extra": changed["extra"] = copy.deepcopy(item)
                elif mutation == "target": item["target"] = "/responses"
                elif mutation == "affinity": item["headers"]["x-session-id"] = "rotated"
                elif mutation == "accept": item["headers"]["accept"] = "application/json"
                elif mutation == "new_header": item["headers"]["unexpected"] = "yes"
                elif mutation == "missing_header": del item["headers"]["accept"]
                else: item["scratch_path_substitutions"] = 0
                with self.assertRaises(RuntimeError): compare(self.reference, changed)

    def test_native_home_is_independent_of_python_home(self):
        native = "/synthetic-native-home/Documents/Briglia/scratch/repos"
        self.assertEqual(validate_scratch_path(native, native), native)
        for changed in ("/changed/Documents/Briglia/scratch/repos", "relative/Documents/Briglia/scratch/repos", native + "/changed"):
            with self.subTest(changed=changed), self.assertRaises(RuntimeError):
                validate_scratch_path(changed, native)
        with self.assertRaises(RuntimeError):
            validate_scratch_path("relative/Documents/Briglia/scratch/repos", "relative/Documents/Briglia/scratch/repos")

    def test_same_passes(self):
        compare(self.reference, copy.deepcopy(self.reference))

    def test_overlay_refuses_changed_production_anchor(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / "TelegramConcierge/CLI").mkdir(parents=True)
            (root / "TelegramConcierge/CLI/AdaMain.swift").write_text("AffinitySelftest.self,")
            (root / URL_FILE).parent.mkdir(parents=True)
            (root / URL_FILE).write_text(URL_LITERAL.replace("openrouter.ai", "example.com"))
            with self.assertRaisesRegex(RuntimeError, "URL anchor changed"):
                instrument(root)


if __name__ == "__main__":
    unittest.main()
