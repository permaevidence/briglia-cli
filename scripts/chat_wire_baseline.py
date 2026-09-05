#!/usr/bin/env python3
"""Freeze/compare raw legacy HTTP request bytes; never reserialize their JSON.

Recording is allowed only while production Services/Models match the pinned
release source. It creates a new baseline, never replaces an existing one.
The Swift driver uses isolated synthetic storage and loopback traffic only.
Base64 stores raw bytes without introducing the reserved harness prefix into
tracked fixtures. This is representation, not a volatility substitution.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import platform
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = "4dd86133de03b484bed62fb81ce59935b89a7de8"


def run_driver(binary, destination):
    run = subprocess.run([str(binary), "__chat-wire-selftest", "--capture-directory", str(destination)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if run.returncode:
        raise RuntimeError(run.stdout.decode(errors="replace")[-8000:])
    manifest = json.loads((destination / "manifest.json").read_text())
    names = [item["fixture"] for item in manifest]
    if len(names) != len(set(names)) or not names:
        raise RuntimeError("Empty/duplicate capture manifest")
    captured = {}
    for item in manifest:
        name = item["fixture"]
        if pathlib.Path(name).name != name or item["substitutions"] != "none":
            raise RuntimeError("Invalid fixture or unexpected volatility substitution")
        body = (destination / (name + ".body.json")).read_bytes()
        headers = json.loads((destination / (name + ".headers.json")).read_text())
        if int(headers["content-length"]) != len(body):
            raise RuntimeError("Incomplete capture: " + name)
        captured[name] = {"body_base64": base64.b64encode(body).decode(), "target": item["target"]}
    return captured, run.stdout.decode(errors="replace").splitlines()[-1]


def compare(expected, actual):
    if expected.keys() != actual.keys():
        raise RuntimeError("Fixture set changed: missing=%s extra=%s" %
                           (sorted(expected.keys() - actual.keys()), sorted(actual.keys() - expected.keys())))
    for name in expected:
        old = base64.b64decode(expected[name]["body_base64"], validate=True)
        new = base64.b64decode(actual[name]["body_base64"], validate=True)
        if old != new:
            offset = next((i for i, (a, b) in enumerate(zip(old, new)) if a != b), min(len(old), len(new)))
            raise RuntimeError(f"{name}: body differs at byte {offset}; expected {len(old)} bytes, got {len(new)}")
        if expected[name]["target"] != actual[name]["target"]:
            raise RuntimeError(name + ": request target changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--record", action="store_true", help="Create a new baseline from unchanged release production code")
    parser.add_argument("--baseline", type=pathlib.Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    platform_id = platform.system().lower() + "-" + platform.machine().lower()
    baseline = args.baseline or ROOT / "scripts" / "fixtures" / "chat-wire" / (platform_id + ".json")
    swift = subprocess.check_output(["swift", "--version"], text=True).strip()
    if args.record:
        if baseline.exists():
            raise RuntimeError("Refusing to overwrite a frozen baseline")
        subprocess.run(["git", "diff", "--exit-code", SOURCE, "--", "TelegramConcierge/Services", "TelegramConcierge/Models"],
                       cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        # Untracked production files would not appear in git diff.
        untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "--",
                                            "TelegramConcierge/Services", "TelegramConcierge/Models"], cwd=ROOT)
        if untracked.strip():
            raise RuntimeError("Untracked production code invalidates baseline recording")
    with tempfile.TemporaryDirectory(prefix="briglia-wire-baseline-") as temp:
        first, summary = run_driver(binary, pathlib.Path(temp) / "first")
        second, _ = run_driver(binary, pathlib.Path(temp) / "second")
        compare(first, second)  # separate processes, roots, ports and caches
        if args.record:
            document = {"version": 1, "source_sha": SOURCE, "platform": platform_id, "toolchain": swift,
                        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                        "build_kind": "release source with test instrumentation; not the shipped binary",
                        "scope": "initial main-builder matrix only; full P0 exit gate still pending",
                        "fixtures": first}
            baseline.parent.mkdir(parents=True, exist_ok=True)
            with baseline.open("x") as handle:
                json.dump(document, handle, sort_keys=True, indent=2)
                handle.write("\n")
            print("Recorded", len(first), "raw-byte fixtures:", baseline)
        else:
            document = json.loads(baseline.read_text())
            if document["version"] != 1 or document["source_sha"] != SOURCE:
                raise RuntimeError("Unknown baseline version/source")
            if document["platform"] != platform_id or document["toolchain"] != swift:
                raise RuntimeError("Platform/toolchain differs; a separately reviewed baseline is required")
            compare(document["fixtures"], first)
            print("Matched", len(first), "frozen raw-byte fixtures across two isolated runs")
        print(summary)


if __name__ == "__main__":
    main()
