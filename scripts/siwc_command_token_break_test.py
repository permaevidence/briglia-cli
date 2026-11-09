#!/usr/bin/env python3
"""Deliberate breaks for the 0.2.70 settings-command token fix (Telegram
`/subscription login|use|cancel|logout official` deadlocked on the settings
writer's own commit token in 0.2.69).

Same method as live_menu_break_test.py: copy the tree to a scratch
directory, build once (positive control: `__siwc-selftest --only cmd-token`
passes), then apply one mutation at a time, rebuild incrementally and
require the NAMED check to be reported as failed (✖), not just a non-zero
exit. The repository is never modified; every run uses scratch XDG roots
(the selftest makes its own, and its Telegram child runs under its own HOME).

Usage: python3 scripts/siwc_command_token_break_test.py [--keep-build DIR] [--only K1,K2]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINUX_JOBS = ["-j", "2"] if sys.platform.startswith("linux") else []
S = "TelegramConcierge/Services/Settings/"
G = S + "SettingsCommitGate.swift"
W = S + "SettingsWriter.swift"
WS = S + "SettingsWriter+SIWC.swift"

# (label, check label prefix that must fail, file, old, new)
BREAKS = [
    ("K1 0.2.69: writer.commit never reuses the caller's token",
     "telegram: /subscription login official sends the sign-in link", W,
     "        if let held = reusableHeldToken() {\n            let r = await commitHolding(held, change, policy: policy, stillValid: stillValid)",
     "        if false, let held = reusableHeldToken() {\n            let r = await commitHolding(held, change, policy: policy, stillValid: stillValid)"),
    ("K2 commit reuse removed (in-process row)",
     "cmd-token T3: a commit from the task holding the token runs under it", W,
     "        if let held = reusableHeldToken() {\n            let r = await commitHolding(held, change, policy: policy, stillValid: stillValid)",
     "        if false, let held = reusableHeldToken() {\n            let r = await commitHolding(held, change, policy: policy, stillValid: stillValid)"),
    ("K3 the SIWC entry points never reuse the caller's token",
     "cmd-token T5: SIWC cancel and sign-out from the holding task answer at once", W,
     "        if let held = reusableHeldToken() { return (held, true) }",
     "        _ = reusableHeldToken()"),
    ("K4 SIWC sign-out does not reuse (Telegram logout hangs)",
     "telegram: /subscription logout official signs out", WS,
     "        guard let (token, reused) = await acquireOrReuse() else {\n            return .refused(gate.admissionClosedReason ?? \"Briglia is busy; try again in a moment. Nothing changed.\")",
     "        guard let token = await gate.acquire() else {\n            return .refused(gate.admissionClosedReason ?? \"Briglia is busy; try again in a moment. Nothing changed.\")\n        }\n        let reused = false\n        if reused {"),
    ("K5 SIWC cancel does not reuse (Telegram cancel hangs)",
     "telegram: a new login, then /subscription cancel official answers", WS,
     "        guard let (token, reused) = await acquireOrReuse() else { return .refused(gate.admissionClosedReason ?? \"Briglia is busy; try again in a moment.\") }",
     "        guard let token = await gate.acquire() else { return .refused(gate.admissionClosedReason ?? \"Briglia is busy; try again in a moment.\") }\n        let reused = false"),
    ("K6 a reused token is released by the inner write (the command loses it mid-body)",
     "cmd-token T5: SIWC cancel and sign-out from the holding task answer at once", WS,
     "        guard let (token, reused) = await acquireOrReuse() else { return .refused(gate.admissionClosedReason ?? \"Briglia is busy; try again in a moment.\") }\n        defer { if !reused { gate.release(token); kickAfterSIWC() } }",
     "        guard let (token, reused) = await acquireOrReuse() else { return .refused(gate.admissionClosedReason ?? \"Briglia is busy; try again in a moment.\") }\n        defer { _ = reused; gate.release(token); kickAfterSIWC() }"),
    ("K7 the gate's reentry guard is removed (a self-acquire waits forever)",
     "cmd-token T1: a task asking again for the token it holds is refused at once", G,
     "        if tokenHeldByCurrentTask != nil {\n            // Waiting here",
     "        if false, tokenHeldByCurrentTask != nil {\n            // Waiting here"),
    ("K8 ownership ignores the task (a spawned task borrows the token)",
     "cmd-token T2: a task spawned while the token is held queues behind it", G,
     "        guard let holder, let owner = holderTask, let me = Self.currentTaskKey(), owner == me else { return nil }",
     "        guard let holder else { return nil }"),
    ("K9 ownership ignores the task (another task's commit runs under the holder's token)",
     "cmd-token T4: a commit from another task waits for the holder", G,
     "        guard let holder, let owner = holderTask, let me = Self.currentTaskKey(), owner == me else { return nil }",
     "        guard let holder else { return nil }"),
    ("K10 reuse while admission is closed (a lifecycle's nested commit writes)",
     "cmd-token T6: with admission closed the holder's nested commit is refused", W,
     "        guard gate.admissionClosedReason == nil else { return nil }\n        return gate.tokenHeldByCurrentTask",
     "        return gate.tokenHeldByCurrentTask"),
    ("K11 the queued waiter's task is not recorded (handed-over token has no owner)",
     "cmd-token T7: a writer handed the token after waiting owns it", G,
     "            holder = token; holderTask = next.task; holderPhase = .preCommit; holderCancel = nil",
     "            holder = token; holderTask = nil; holderPhase = .preCommit; holderCancel = nil"),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    r = run(["swift", "build", "--build-system", "native", *LINUX_JOBS, "--scratch-path", str(scratch)], tree, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


class Timed:
    """A test killed at its deadline: still judged by the ✖ lines it printed."""
    def __init__(self, exc):
        out = exc.stdout or ""
        self.stdout = out.decode("utf-8", "replace") if isinstance(out, bytes) else out
        self.stderr = "timed out"
        self.returncode = -9


def test(binary, workdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BRIGLIA_")}
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    try:
        return run([str(binary), "__siwc-selftest", "--only", "cmd-token"], workdir, timeout=600, env=env)
    except subprocess.TimeoutExpired as exc:
        return Timed(exc)


def mutate(tree, rel, old, new):
    path = tree / rel
    text = path.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"break anchor moved: {rel}: {old!r} (found {text.count(old)})")
    path.write_text(text.replace(old, new))
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-build")
    ap.add_argument("--only")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="bm-cmdtoken-"))
    tree = work / "tree"
    tree.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / name, tree / name)
    shutil.copytree(ROOT / "TelegramConcierge", tree / "TelegramConcierge")
    shutil.copytree(ROOT / "scripts", tree / "scripts")
    scratch = Path(args.keep_build) if args.keep_build else work / "build"
    failures = executed = 0
    try:
        binary = build(tree, scratch)
        r = test(binary, work)
        ok = r.returncode == 0
        print(("✔" if ok else "✖") + " positive control: the unmodified copy passes", flush=True)
        if not ok:
            print((r.stdout + r.stderr)[-3000:])
            return 1
        for label, check, rel, old, new in BREAKS:
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            original = mutate(tree, rel, old, new)
            try:
                binary = build(tree, scratch)
                r = test(binary, work)
                failed = [l for l in r.stdout.splitlines() if l.startswith("✖")]
                caught = r.returncode != 0 and any(l.startswith("✖ " + check) for l in failed)
                print(("✔" if caught else "✖") + f" {label}: \"{check}\" fails"
                      + (f" ({len(failed)} failing check(s))" if failed else ""), flush=True)
                failures += 0 if caught else 1
                executed += 1
                if not caught and args.verbose:
                    print((r.stdout + r.stderr)[-6000:])
            finally:
                (tree / rel).write_text(original)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
