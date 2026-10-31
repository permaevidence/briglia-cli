#!/usr/bin/env python3
"""Deliberate breaks for the terminal quick setup (0.2.67, owner spec
QUICKSETUP_OPENROUTER_SPEC.md).

Same method as live_menu_break_test.py: copy the tree to a scratch
directory, build once (positive control: `__quicksetup-selftest --only 19.`
and scripts/quicksetup_terminal_test.py pass), then apply one mutation at a
time, rebuild incrementally and require the NAMED check to be reported as
failed (✖), not just a non-zero exit. The repository is never modified.

Usage: python3 scripts/quicksetup_break_test.py [--keep-build DIR] [--only Q1,Q2] [--verbose] [--in-place]

--in-place (low disk): mutate the repository's own files and rebuild its
.build incrementally instead of a scratch copy; each file is restored in a
`finally`, and the run refuses to start unless the two mutated files are
clean in git.
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
T = "TelegramConcierge/CLI/QuickSetup/QuickSetupTerminal.swift"
M = "TelegramConcierge/CLI/Menu/MenuWorkflow.swift"

# (label, test, check label prefix that must fail, file, old, new)
# test: "selftest" (__quicksetup-selftest --only 19.) or "e2e" (quicksetup_terminal_test.py)
BREAKS = [
    ("Q1 the name is saved around the settings writer", "selftest", "qs A: every save went through the settings writer seam", T,
     '            let r = await act(["action": "name", "name": name])',
     '            try? KeychainHelper.saveBatch([KeychainHelper.userNameKey: name]); let r: (ok: Bool, message: String) = (true, "")'),
    ("Q2 the removed OpenAI sentence comes back", "selftest", "qs A: the removed OpenAI sentence is not shown", T,
     '                io.say("✔ The key works.")',
     '                io.say("✔ The key works.")\n                io.say("✔ Voice, images and OCR also go through OpenRouter. No OpenAI key needed.")'),
    ("Q3 keys stay in the environment for children", "selftest", "qs D: keys are read from the environment once and removed", T,
     '            unsetenv(name)\n', ''),
    ("Q4 --telegram-chat-id still opens the step in scan mode", "selftest", "qs B: --telegram-chat-id skips the /start wait", T,
     '            if knownChatId != nil { tokenAction["manual"] = true }', ''),
    ("Q5 the menu ignores the manual pairing flag", "selftest", "qs B: --telegram-chat-id skips the /start wait", M,
     'state: body["manual"] as? Bool == true ? "manual" : "waiting",', 'state: "waiting",'),
    ("Q6 the menu ignores the host's optional rows", "selftest", "qs B: setup completes without Full Disk Access or tools", M,
     '        if optionalItems.contains(item) { return false }\n', ''),
    ("Q7 the command no longer makes FDA and tools optional", "e2e", "--yes: exit 0 with nothing on stdin", T,
     '        menu.optionalItems = [.computer, .tools]', '        menu.optionalItems = []'),
    ("Q8 --yes still asks questions", "selftest", "qs B: --yes completes with no question asked", T,
     '    var interactive: Bool { !options.yes }', '    var interactive: Bool { true }'),
    ("Q9 a refused key is printed", "selftest", "qs A: no key ever printed", T,
     '            io.say(r.message.contains("refused this key")',
     '            io.say(key); io.say(r.message.contains("refused this key")'),
    ("Q10 a /start timeout leaves the pairing step open", "selftest", "qs G: pairing released", T,
     '        io.say("✖ No /start reached @\\(bot) within \\(Int(system.telegramWait / 60)) minutes. Run briglia quicksetup again when you\'re ready.")\n        _ = await act(["action": "telegram_reset"])',
     '        io.say("✖ No /start reached @\\(bot) within \\(Int(system.telegramWait / 60)) minutes. Run briglia quicksetup again when you\'re ready.")'),
    ("Q11 Bree's greeting is not sent", "selftest", "qs A: Bree's first Telegram message", T,
     '        if let failure = await system.sendGreeting(token, chatId, greetingText()) {',
     '        if let failure = Optional<String>.none {'),
    ("Q12 over SSH the Mac still opens System Settings", "selftest", "qs L: SSH → Full Disk Access skipped", T,
     '        } else if system.isSSH {', '        } else if false {'),
    ("Q13 Linux: no sudo notice", "selftest", "qs E: one sudo notice", T,
     '            io.say("The media tools and keep-awake need your password once (sudo):")', ''),
    ("Q14 a host is claimed though nothing was pinned", "selftest", "qs I: no host listing", T,
     '        guard ["auto_pinned", "user_host"].contains(host["host_state"] as? String ?? ""),',
     '        guard true,'),
    ("Q15 a set-up install is set up again", "e2e", "rerun: already set up", T,
     '        if QuickSetupFlow.alreadyFinished(complete: SetupWizard.setupComplete(),', '        if false && QuickSetupFlow.alreadyFinished(complete: SetupWizard.setupComplete(),'),
    ("Q16 the command lets the page auto-complete setup early", "e2e", "interrupted at Email", T,
     '        menu.autoComplete = false   // the flow writes completion at its finish', ''),
    ("Q17 the command ignores the resume marker", "selftest", "qs N: the command's guard resumes", T,
     '        complete && progress != progressMarker', '        complete'),
    ("Q18 completion clears the resume marker before the handoff", "selftest", "qs M: …so the next run resumes", T,
     '[SetupWizard.completeKey: "true", SetupWizard.progressKey: Self.progressMarker]', '[SetupWizard.completeKey: "true", SetupWizard.progressKey: nil]'),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    r = run(["swift", "build", "--build-system", "native", *LINUX_JOBS, "--scratch-path", str(scratch)], tree, timeout=5400)
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


def test(kind, binary, tree, workdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BRIGLIA_")}
    # Both tests make their own scratch roots; never the live install.
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    try:
        if kind == "e2e":
            return run([sys.executable, str(tree / "scripts" / "quicksetup_terminal_test.py"), str(binary)], tree, timeout=900, env=env)
        return run([str(binary), "__quicksetup-selftest", "--only", "19."], workdir, timeout=600, env=env)
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
    ap.add_argument("--in-place", action="store_true")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="bm-qsbreak-", dir="/tmp" if os.path.isdir("/tmp") else None))
    if args.in_place:
        dirty = run(["git", "status", "--porcelain", "--", T, M], ROOT).stdout.strip()
        if dirty:
            print("refusing --in-place: uncommitted changes in " + dirty)
            return 2
        tree = ROOT
        scratch = ROOT / ".build"
    else:
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
        for kind in ("selftest", "e2e"):
            r = test(kind, binary, tree, work)
            ok = r.returncode == 0
            print(("✔" if ok else "✖") + f" positive control ({kind}): the unmodified copy passes", flush=True)
            if not ok:
                print((r.stdout + r.stderr)[-3000:])
                return 1
        for label, kind, check, rel, old, new in BREAKS:
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            original = mutate(tree, rel, old, new)
            try:
                binary = build(tree, scratch)
                r = test(kind, binary, tree, work)
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
        if args.in_place:
            build(tree, scratch)   # leave the restored tree's binary in .build
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
