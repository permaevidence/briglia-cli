#!/usr/bin/env python3
"""P0 release-versus-candidate lifecycle gate; all instrumentation is disposable."""
import argparse
import base64
import hashlib
import hmac
import struct
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import platform
import chat_wire_baseline as wire

ROOT = wire.ROOT
FIXTURES = ROOT / "scripts/fixtures/chat-lifecycle"


def replace(path, old, new, count=1):
    source = path.read_text()
    if source.count(old) != count:
        raise RuntimeError(f"Instrumentation anchor changed: {path.name}: {old}")
    path.write_text(source.replace(old, new))


def instrument(tree):
    evidence = {}
    for name in ("AffinitySelftest.swift", "CaptureRequestParser.swift"):
        shutil.copyfile(ROOT / "TelegramConcierge/CLI" / name, tree / "TelegramConcierge/CLI" / name)
    shutil.copyfile(FIXTURES / "Driver.swift", tree / "TelegramConcierge/CLI/ChatLifecycleSelftest.swift")
    main = tree / "TelegramConcierge/CLI/AdaMain.swift"
    replace(main, "AffinitySelftest.self,", "AffinitySelftest.self, ChatLifecycleSelftest.self,")
    for target, seam in (("ConversationManager.swift", "ManagerSeam.swift"), ("ConversationArchiveService.swift", "ArchiveSeam.swift"), ("OpenRouterService.swift", "MediaSeam.swift")):
        path = tree / "TelegramConcierge/Services" / target
        with path.open("a") as f:
            f.write((FIXTURES / seam).read_text())
    # Storage input seam: owner preferences must never be read/written by a fixture.
    # XDG handles files; this separately redirects every standard-defaults access.
    for path in (tree / "TelegramConcierge").rglob("*.swift"):
        if "selftest" in path.name.lower(): continue
        text = path.read_text()
        count = text.count("UserDefaults.standard")
        if count:
            path.write_text(text.replace("UserDefaults.standard", "P0Life.defaults"))
            evidence[str(path.relative_to(tree)) + ":defaults"] = count
        text = path.read_text()
        if "UserDefaults = .standard" in text:
            evidence[str(path.relative_to(tree)) + ":defaults-default"] = text.count("UserDefaults = .standard")
            path.write_text(text.replace("UserDefaults = .standard", "UserDefaults = P0Life.defaults"))
    manager = tree / "TelegramConcierge/Services/ConversationManager.swift"
    replace(manager, "let now = Date()\n        UserDefaults.standard.set(now, forKey: systemPromptTimestampKey)".replace("UserDefaults.standard", "P0Life.defaults"),
            "let now = P0Life.instant\n        P0Life.defaults.set(now, forKey: systemPromptTimestampKey)")
    replace(manager, "P0Life.defaults.set(Date(), forKey: systemPromptTimestampKey)",
            "P0Life.defaults.set(P0Life.instant, forKey: systemPromptTimestampKey)")
    replace(manager, "let currentRealTime = postToolTimeFormatter.string(from: Date())",
            "let currentRealTime = postToolTimeFormatter.string(from: P0Life.instant)")
    replace(tree / "TelegramConcierge/Services/UserContextStructurer.swift", "lane: .ephemeral(UUID())",
            'lane: .ephemeral(UUID(uuidString: "00000000-0000-4000-8000-000000000060")!)')
    # Only request-visible clock and session entropy inputs. Progress/staleness
    # clocks remain real. No encoder, accounting or decision code is replaced.
    path = tree / "TelegramConcierge/Services/SubagentRunner.swift"
    replace(path, "let turnStartDate = Date()", "let turnStartDate = P0Life.instant")
    replace(path, "timestamp: Date()", "timestamp: P0Life.instant", 2)
    path = tree / "TelegramConcierge/Services/SubagentSessionRegistry.swift"
    replace(path, "timestamp: Date()", "timestamp: P0Life.instant", 3)
    replace(path, 'id = String((0..<5).map { _ in base36.randomElement()! })', 'id = "p0001"')
    evidence["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    for name in ("AffinitySelftest.swift", "CaptureRequestParser.swift"):
        evidence[name] = hashlib.sha256((ROOT / "TelegramConcierge/CLI" / name).read_bytes()).hexdigest()
    for path in FIXTURES.glob("*.swift"):
        evidence[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return evidence


def expected_affinity(lane):
    payload = b"briglia-affinity-v1"
    for part in (hashlib.sha256(b"synthetic-lifecycle-key").digest(), lane.encode()):
        payload += struct.pack(">I", len(part)) + part
    return hmac.new(bytes(range(32)), payload, hashlib.sha256).hexdigest()[:32]


def run(binary, destination):
    env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING="1", LC_ALL="C", TZ="UTC")
    proc = subprocess.run([str(binary), "__chat-lifecycle-selftest", "--output", str(destination)],
                          env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    destination.parent.joinpath(destination.name + ".log").write_bytes(proc.stdout)
    if proc.returncode:
        raise RuntimeError(proc.stdout.decode(errors="replace")[-15000:])
    observations = json.loads((destination / "observations.json").read_text())
    captures = json.loads((destination / "captures.json").read_text())
    metadata = json.loads((destination / "metadata.json").read_text())
    home = wire.validate_scratch_path(metadata["scratch_path"], metadata["expected_scratch_path"])
    expected_scenarios = {"under", "boundary", "over-prunable", "exhausted-protected", "exhausted-after-prune", "unsent-delta", "estimated",
        "automatic-under", "automatic-prune", "automatic-protected", "manual", "reasoning-only", "media-prune", "synthetic-prune",
        "large-reasoning", "summary-tools-refused", "usage-decoder", "delivery", "loop-final", "loop-tools", "loop-exhausted", "loop-spend",
        "subagents", "media", "archive", "user-context"}
    if set(observations) != expected_scenarios: raise RuntimeError("Lifecycle scenario inventory changed")
    counts = {"over-prunable": 1, "exhausted-after-prune": 1, "unsent-delta": 1, "estimated": 1, "automatic-prune": 1,
        "manual": 1, "reasoning-only": 1, "media-prune": 1, "synthetic-prune": 1, "large-reasoning": 1, "summary-tools-refused": 5,
        "loop-final": 1, "loop-tools": 2, "loop-exhausted": 2, "loop-spend": 2, "subagent-new": 1, "subagent-resume": 1,
        "subagent-eager": 3, "subagent-midrun": 3, "subagent-forced-retry": 3, "media-rehydrated": 1, "media-missing": 1,
        "media-raw-document": 1, "archive": 1, "user-context": 1, "probe": 1}
    expected_captures = {f"{name}-{i}" for name, count in counts.items() for i in range(count)}
    names = [c["fixture"] for c in captures]
    if len(names) != len(set(names)) or set(names) != expected_captures: raise RuntimeError("Lifecycle request inventory changed")
    for capture in captures:
        body = base64.b64decode(capture["body"], validate=True)
        headers = capture["headers"]
        if int(headers.pop("content-length")) != len(body):
            raise RuntimeError("Incomplete capture")
        name = capture["fixture"]
        lane = "subagent:p0001" if name.startswith("subagent-") else ("archive" if name.startswith("archive-") else
                ("probe:00000000-0000-4000-8000-000000000001" if name.startswith("probe-") else ("ephemeral:00000000-0000-4000-8000-000000000060" if name.startswith("user-context-") else "main:33333333-3333-4333-8333-333333333333")))
        if headers.get("x-opencode-session") != expected_affinity(lane):
            raise RuntimeError(f"{name}: wrong affinity lane {lane}: {headers.get('x-opencode-session')}")
        if headers.get("authorization") != "Bearer synthetic-lifecycle-key" or capture["method"] != "POST":
            raise RuntimeError("Request method/auth changed")
        host = headers["host"]
        if host != "127.0.0.1:49179":
            raise RuntimeError("Non-loopback host")
        original = home.replace("/", r"\/").encode()
        count = body.count(original)
        # Only populated-tools main/subagent requests contain this path. The
        # no-tools summary/replay/probe builders do not. Counts are explicit.
        populated = name.startswith("loop-") or name == "manual-0" or name in {
            "subagent-midrun-0", "subagent-midrun-2", "subagent-forced-retry-0", "subagent-forced-retry-1", "subagent-forced-retry-2"}
        if count != int(populated): raise RuntimeError(f"{name}: scratch path substitution count {count}")
        body = body.replace(original, b"/__fixture_home__/Documents/Briglia/scratch/repos".replace(b"/", br"\/"))
        capture["scratch_substitutions"] = count
        capture["body"] = base64.b64encode(body).decode()
    return {"observations": observations, "captures": captures}


def compare(expected, actual, path="root"):
    if type(expected) != type(actual):
        raise RuntimeError(f"{path}: type changed")
    if isinstance(expected, dict):
        if expected.keys() != actual.keys():
            raise RuntimeError(f"{path}: keys changed")
        for key in expected:
            compare(expected[key], actual[key], path + "." + key)
    elif isinstance(expected, list):
        if len(expected) != len(actual):
            raise RuntimeError(f"{path}: length {len(expected)} != {len(actual)}")
        for i, (a, b) in enumerate(zip(expected, actual)):
            compare(a, b, f"{path}[{i}]")
    elif expected != actual:
        if path.endswith(".body"):
            a, b = base64.b64decode(expected), base64.b64decode(actual)
            offset = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
            raise RuntimeError(f"{path}: wire bytes differ at {offset}: {a[max(0,offset-60):offset+100]!r} / {b[max(0,offset-60):offset+100]!r}")
        raise RuntimeError(f"{path}: {str(expected)[:120]!r} != {str(actual)[:120]!r}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--save-reference", type=Path)
    p.add_argument("--baseline", type=Path)
    p.add_argument("--scratch-root", type=Path)
    p.add_argument("--keep-trees", action="store_true", help="Keep disposable trees/logs for debugging")
    p.add_argument("--candidate-only", action="store_true", help="Development diagnostic; NOT a differential pass")
    args = p.parse_args()
    if args.candidate_only and args.save_reference: p.error("diagnostic candidate cannot record a reference")
    if args.save_reference and args.save_reference.exists():
        raise RuntimeError("Refusing to overwrite frozen evidence")
    missing = [name for name in ("zip", "unzip") if shutil.which(name) is None]
    if missing:
        raise RuntimeError("Mind compatibility gate requires: " + ", ".join(missing) + ". Install them before building; this check cannot be skipped.")
    root = Path(tempfile.mkdtemp(prefix="briglia-lifecycle-"))
    trees = []
    try:
        results = {}
        binaries = {}
        reference_evidence = None
        for label, ref in ([("candidate", "HEAD")] if args.candidate_only else [("reference", wire.SOURCE), ("candidate", "HEAD")]):
            tree = root / label
            wire.command(["git", "worktree", "add", "--detach", str(tree), ref]); trees.append(tree)
            if label == "candidate":
                diff = subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT)
                if diff: wire.command(["git", "apply", "--binary", "-"], cwd=tree, input=diff)
                untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z", "--", "TelegramConcierge"], cwd=ROOT)
                for raw in untracked.split(b"\0"):
                    if raw:
                        name = os.fsdecode(raw)
                        (tree / name).parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(ROOT / name, tree / name, follow_symlinks=False)
            evidence = instrument(tree)
            if label == "reference": reference_evidence = evidence
            elif reference_evidence is not None and evidence != reference_evidence:
                raise RuntimeError("Instrumentation differs between release and candidate")
            scratch = (args.scratch_root or root / "build") / label
            wire.command(["swift", "build", "--scratch-path", str(scratch)], cwd=tree)
            bindir = subprocess.check_output(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"], cwd=tree, text=True).strip()
            binary = Path(bindir) / "briglia"
            binaries[label] = binary
            data = run(binary, root / (label + "-capture"))
            repeat = run(binary, root / (label + "-repeat"))
            compare(data, repeat)
            results[label] = data
            if label == "reference" and args.save_reference:
                args.save_reference.parent.mkdir(parents=True, exist_ok=True)
                with args.save_reference.open("x") as f:
                    json.dump({"source": wire.SOURCE, "instrumentation": evidence,
                               "platform": platform.platform(), "toolchain": subprocess.check_output(["swift", "--version"], text=True).strip(),
                               "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "fixtures": data}, f, indent=2, sort_keys=True)
            print(f"{label}: {len(data['observations'])} scenarios / {len(data['captures'])} requests stable", flush=True)
        if args.baseline:
            frozen = json.loads(args.baseline.read_text())
            if frozen["source"] != wire.SOURCE: raise RuntimeError("Wrong baseline source")
            if frozen["platform"] != platform.platform(): raise RuntimeError("Wrong baseline platform")
            if frozen["toolchain"] != subprocess.check_output(["swift", "--version"], text=True).strip():
                raise RuntimeError("Wrong baseline compiler")
            compare(frozen["fixtures"], results.get("reference", results["candidate"]))
        if not args.candidate_only:
            compare(results["reference"], results["candidate"])
            # New-binary export MUST open with the pinned release's actual importer.
            imported = root / "cross-import"
            env = dict(os.environ, SWIFT_DETERMINISTIC_HASHING="1", LC_ALL="C", TZ="UTC")
            wire.command([str(binaries["reference"]), "__chat-lifecycle-selftest", "--output", str(imported),
                          "--import-mind", str(root / "candidate-capture/compat.mind")], env=env)
            compare(json.loads((root / "candidate-capture/expected-import.json").read_text()),
                    json.loads((imported / "import.json").read_text()))
            wire.command(["python3", str(ROOT / "scripts/chat_lifecycle_client_test.py"),
                          str(root / "candidate-capture/status.json")])
        print("DIAGNOSTIC ONLY" if args.candidate_only else "Lifecycle pinned-release differential PASS")
    finally:
        print(f"Evidence: {root}", flush=True)
        if not args.keep_trees:
            for tree in reversed(trees): wire.command(["git", "worktree", "remove", "--force", str(tree)])
            # Retain capture/log evidence even after failure; no ignored-docs copies.

if __name__ == "__main__":
    main()
