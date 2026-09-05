#!/usr/bin/env python3
"""Compare instrumented pinned-release and candidate requests on one toolchain.

Only disposable worktrees are instrumented. --record always builds SOURCE;
changed candidate production files can never become the reference.
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = "4dd86133de03b484bed62fb81ce59935b89a7de8"
DRIVERS = ["TelegramConcierge/CLI/" + name for name in
           ("ChatWireSelftest.swift", "CaptureRequestParser.swift", "AffinitySelftest.swift")]
URL_FILE = "TelegramConcierge/Services/OpenRouterService.swift"
URL_LITERAL = 'private let openRouterBaseURL = "https://openrouter.ai/api/v1/chat/completions"'
URL_OVERLAY = 'private var openRouterBaseURL: String { ProcessInfo.processInfo.environment["BRIGLIA_CHAT_WIRE_ROUTER_URL"]! }'


def command(args, cwd=ROOT, **kwargs):
    return subprocess.run(args, cwd=cwd, check=True, **kwargs)


def validate_scratch_path(actual, expected):
    # expected is calculated directly from Foundation in the test driver,
    # independently of the production LandingZone accessor.
    if (actual != expected or not actual.startswith("/")
            or not actual.endswith("/Documents/Briglia/scratch/repos")):
        raise RuntimeError("Unexpected scratch path")
    return actual


def run_driver(binary, destination):
    run = subprocess.run([str(binary), "__chat-wire-selftest", "--capture-directory", str(destination)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    if run.returncode:
        raise RuntimeError(run.stdout.decode(errors="replace")[-12000:])
    manifest = json.loads((destination / "manifest.json").read_text())
    names = [item["fixture"] for item in manifest]
    if len(names) != len(set(names)) or not names:
        raise RuntimeError("Empty/duplicate capture manifest")
    required = {f"{model}-{index}" for model in (
        "glm-5.3", "kimi-k3", "kimi-k2.7-code", "qwen3.8-max",
        "custom-model", "local-model", "anthropic_claude-sonnet-4") for index in range(11)}
    if set(names) != required:
        raise RuntimeError("Reviewed 77-case inventory changed; review fixture additions/removals explicitly")
    captured = {}
    for item in manifest:
        name = item["fixture"]
        if pathlib.Path(name).name != name or item["substitutions"] != "scratch-repos-path-and-host-port-v2":
            raise RuntimeError("Invalid fixture or unexpected substitutions")
        body = (destination / (name + ".body.json")).read_bytes()
        headers = json.loads((destination / (name + ".headers.json")).read_text())
        if int(headers.pop("content-length")) != len(body):
            raise RuntimeError("Incomplete capture: " + name)
        if headers.get("host") != item["authority"]:
            raise RuntimeError("Unexpected Host: " + name)
        # Exactly one header value; never discard other headers or ports in URLs.
        headers["host"] = "127.0.0.1:<capture-port>"
        # One exact absolute scratch-repos path inside the main system prompt.
        # No JSON decoding/re-encoding. Swift's encoder escapes slash bytes.
        path = validate_scratch_path(item["scratch_path"], item["expected_scratch_path"])
        old = path.replace("/", r"\/").encode()
        new = b"/__fixture_home__/Documents/Briglia/scratch/repos".replace(b"/", br"\/")
        count = body.count(old)
        if count != (1 if int(name.rsplit("-", 1)[1]) >= 6 else 0):
            raise RuntimeError("Scratch-path substitution count differs from the reviewed fixture")
        body = body.replace(old, new)
        captured[name] = {"body_base64": base64.b64encode(body).decode(), "target": item["target"],
                          "headers": headers, "scratch_path_substitutions": count}
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
        for field in ("target", "headers", "scratch_path_substitutions"):
            if expected[name][field] != actual[name][field]:
                raise RuntimeError(f"{name}: {field} changed")


def instrument(tree):
    evidence = {}
    for name in DRIVERS:
        source = ROOT / name
        shutil.copyfile(source, tree / name)
        if name.endswith("/ChatWireSelftest.swift"):
            driver = tree / name
            contents = driver.read_text()
            anchor = "private let chatWireRouterInstrumented = false"
            if contents.count(anchor) != 1:
                raise RuntimeError("OpenRouter test-only flag anchor changed")
            driver.write_text(contents.replace(anchor, "private let chatWireRouterInstrumented = true"))
        evidence[name] = hashlib.sha256((tree / name).read_bytes()).hexdigest()
    main = tree / "TelegramConcierge/CLI/AdaMain.swift"
    text = main.read_text()
    if "ChatWireSelftest.self" not in text:
        anchor = "AffinitySelftest.self,"
        if text.count(anchor) != 1:
            raise RuntimeError("Registration anchor changed")
        main.write_text(text.replace(anchor, anchor + " ChatWireSelftest.self,"))
    service = tree / URL_FILE
    text = service.read_text()
    if text.count(URL_LITERAL) != 1:
        raise RuntimeError("OpenRouter URL anchor changed: review the instrumentation")
    service.write_text(text.replace(URL_LITERAL, URL_OVERLAY))
    evidence["openrouter_url_overlay_sha256"] = hashlib.sha256(URL_OVERLAY.encode()).hexdigest()
    return evidence


def build_and_capture(tree, scratch, captures):
    captures.mkdir(parents=True, exist_ok=False)
    command(["swift", "build", "--scratch-path", str(scratch)], cwd=tree)
    binary_dir = subprocess.check_output(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"], cwd=tree, text=True).strip()
    binary = pathlib.Path(binary_dir) / "briglia"
    first, summary = run_driver(binary, captures / "first")
    second, _ = run_driver(binary, captures / "second")
    compare(first, second)
    print(summary, flush=True)
    return first, hashlib.sha256(binary.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", type=pathlib.Path, help="Create a new frozen reference from SOURCE; refuse overwrite")
    parser.add_argument("--save-reference", type=pathlib.Path, help="Save pinned evidence while also running the differential gate")
    parser.add_argument("--baseline", type=pathlib.Path, help="Also require the frozen reference on this platform/compiler")
    parser.add_argument("--scratch-root", type=pathlib.Path, help="Optional persistent Swift build caches")
    args = parser.parse_args()
    if any(path and path.exists() for path in (args.record, args.save_reference)):
        raise RuntimeError("Refusing to overwrite a frozen baseline")
    if args.record and args.baseline:
        parser.error("--record and --baseline are mutually exclusive")
    # Full source is required; CI checkouts fetch history explicitly.
    command(["git", "cat-file", "-e", SOURCE + "^{commit}"])
    with tempfile.TemporaryDirectory(prefix="briglia-wire-differential-") as temp:
        root = pathlib.Path(temp)
        scratch = (args.scratch_root or root / "builds").resolve()
        trees = []
        try:
            reference = root / "reference"
            command(["git", "worktree", "add", "--detach", str(reference), SOURCE])
            trees.append(reference)
            evidence = instrument(reference)
            fixtures, binary_hash = build_and_capture(reference, scratch / "reference", root / "reference-captures")
            document = {"version": 2, "source_sha": SOURCE,
                        "platform": platform.system().lower() + "-" + platform.machine().lower(),
                        "toolchain": subprocess.check_output(["swift", "--version"], text=True).strip(),
                        "binary_sha256": binary_hash, "instrumentation": evidence,
                        "build_kind": "pinned release source with test drivers and explicit loopback URL overlay; not shipped binary",
                        "substitutions": ["Host port only", "one exact scratch-repos absolute path"],
                        "fixtures": fixtures}
            output = args.record or args.save_reference
            if output:
                output.parent.mkdir(parents=True, exist_ok=True)
                with output.open("x") as handle:
                    json.dump(document, handle, sort_keys=True, indent=2)
                    handle.write("\n")
                print(f"Recorded {len(fixtures)} pinned-source fixtures: {output}", flush=True)
                if args.record:
                    return
            if args.baseline:
                frozen = json.loads(args.baseline.read_text())
                for key in ("version", "source_sha", "platform", "toolchain", "substitutions"):
                    if frozen[key] != document[key]:
                        raise RuntimeError("Frozen reference metadata differs: " + key)
                # Historical hashes describe the driver that CREATED the frozen
                # evidence. A revised driver must still match those same bytes;
                # requiring its hash to match would force pointless re-recording.
                compare(frozen["fixtures"], fixtures)
            candidate = root / "candidate"
            command(["git", "worktree", "add", "--detach", str(candidate), "HEAD"])
            trees.append(candidate)
            diff = subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT)
            if diff:
                command(["git", "apply", "--binary", "-"], cwd=candidate, input=diff)
            # Include untracked source, never ignored docs symlinks or local caches.
            untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z", "--", "TelegramConcierge"], cwd=ROOT)
            for raw in untracked.split(b"\0"):
                if raw:
                    name = os.fsdecode(raw)
                    (candidate / name).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / name, candidate / name, follow_symlinks=False)
            if instrument(candidate) != evidence:
                raise RuntimeError("Instrumentation changed during capture")
            actual, _ = build_and_capture(candidate, scratch / "candidate", root / "candidate-captures")
            compare(fixtures, actual)
            print(f"Matched {len(fixtures)} pinned-release bodies, targets and full header maps on the same toolchain", flush=True)
        finally:
            for tree in reversed(trees):
                command(["git", "worktree", "remove", "--force", str(tree)])


if __name__ == "__main__":
    main()
