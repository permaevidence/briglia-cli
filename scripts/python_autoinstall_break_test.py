#!/usr/bin/env python3
"""Deliberate breaks for the macOS Python auto-install (0.2.71, owner request
2026-11-10; plan private-docs docs/PYTHON_AUTOINSTALL_PLAN.md).

Same method as quicksetup_break_test.py: copy the tree to a scratch
directory, build once (positive controls pass), then apply one mutation at a
time, rebuild incrementally and require the NAMED check to be reported as
failed (✖), not just a non-zero exit. The repository is never modified,
except by the Linux-view break, which edits one file in place, runs the
source check and restores it in a `finally`. Every Homebrew in these tests is
a stub: the selftests set both the fake installer and the "real brew" path.

macOS only. Usage: python3 scripts/python_autoinstall_break_test.py [--only P1,P2] [--verbose] [--keep-build DIR]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PR = "TelegramConcierge/Services/PythonRuntime.swift"
QE = "TelegramConcierge/CLI/QuickSetup/QuickSetupEnvironment.swift"
MW = "TelegramConcierge/CLI/Menu/MenuWorkflow.swift"
TS = "TelegramConcierge/Services/ToolchainService.swift"

# (label, test, check label prefix that must fail, file, old, new)
# test: "rt" (__private-runtime-selftest --only python), "qs" (__quicksetup-selftest --only 18b),
#       "menu" (__menu-selftest), "lv" (linux_view_unchanged.py --worktree on the repository)
BREAKS = [
    ("P1 installs although a usable Python exists", "rt", "brew: a usable Python now → brew is never asked again", PR,
     "        if selection.base == nil, trigger == .install {\n            if canInstallPythonInteractively(), claimHomebrewAttempt() {",
     "        if trigger == .install {\n            if canInstallPythonInteractively(), claimHomebrewAttempt() {"),
    ("P2 installs at startup (.auto)", "rt", "brew: startup (.auto) never installs", PR,
     "        if selection.base == nil, trigger == .install {\n            if canInstallPythonInteractively(), claimHomebrewAttempt() {",
     "        if selection.base == nil {\n            if canInstallPythonInteractively(), claimHomebrewAttempt() {"),
    ("P3 installs without a terminal", "rt", "brew: no terminal (stdin /dev/null) → nothing installed", PR,
     '?? (isatty(STDIN_FILENO) == 1)', '?? true'),
    ("P4 installs from the agent's shell", "rt", "brew: the agent's shell (BRIGLIA_PATH_FRONT present, even empty)", PR,
     '        if ProcessInfo.processInfo.environment["BRIGLIA_PATH_FRONT"] != nil { return false }\n', ''),
    ("P5 an empty BRIGLIA_PATH_FRONT counts as absent", "rt", "brew: the agent's shell (BRIGLIA_PATH_FRONT present, even empty)", PR,
     'environment["BRIGLIA_PATH_FRONT"] != nil { return false }', 'environment["BRIGLIA_PATH_FRONT"]?.isEmpty == false { return false }'),
    ("P6 a hard-coded python@3.14", "rt", "brew: …and moves with it, never a literal", PR,
     'static var homebrewPythonFormula: String { "python@3.\\(effectiveMaximumMinor)" }', 'static var homebrewPythonFormula: String { "python@3.14" }'),
    ("P7 brew may upgrade an installed formula", "rt", "brew: from a terminal, brew fails → one `brew install", PR,
     '"HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_UPGRADE": "1",', '"HOMEBREW_NO_AUTO_UPDATE": "1",'),
    ("P8 brew may upgrade dependents and clean up", "rt", "brew: from a terminal, brew fails → one `brew install", PR,
     '                                             "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]',
     '                                             ]'),
    ("P9 a second attempt in the same process", "rt", "brew: …the same process never tries again", PR,
     "        if homebrewAttemptClaimed { return false }\n", ""),
    ("P10 the earlier failure is not repeated", "rt", "brew: …the same process never tries again", PR,
     "            } else if let earlier = homebrewAttemptFailure {\n                return .unavailable(earlier)\n            }",
     "            }"),
    ("P11 the planner ignores a usable Python", "rt", "brew: a usable Python next to Apple's 3.9 → nothing planned", PR,
     "selectBaseBlocking().base == nil ? homebrewPythonFormula : nil", "homebrewPythonFormula"),
    ("P12 selftests could reach Homebrew (eligibility)", "rt", "brew: selftest without the fake brew → never eligible", PR,
     '        if RuntimeSeams.env("BRIGLIA_PYTHON_TEST_BREW_INSTALLER") == nil, RuntimeSeams.env("BRIGLIA_PYTHON_TEST_BASE_DIRS") != nil { return false }\n', ''),
    ("P13 selftests could reach Homebrew (installer)", "rt", "brew: …and the installer itself refuses to run the real brew", PR,
     '        if RuntimeSeams.env("BRIGLIA_PYTHON_TEST_BASE_DIRS") != nil { return "selftest without a fake Homebrew: nothing run" }\n', ''),
    ("P14 no hint for an unlinked formula", "rt", "brew: python@3.14 installed but not linked", PR,
     'return "; Homebrew\'s \\(formula) is installed but not linked: run `brew link \\(formula)`"', 'return ""'),
    ("P15 the tools check stays blind to a versioned Python", "rt", "tools check (python3Path): a broken python3 first on PATH", TS,
     "return firstWorkingPython((first.isEmpty ? [] : [first]) + PythonRuntime.baseCandidates(), works: runsPython3)",
     "return first.isEmpty ? nil : first"),
    ("P16 the brew job runs after the python-env job", "qs", "…right before the python-env job", QE,
     "            if let formula = pythonFormulaNeeded() { jobs.append(pythonFormulaJob(brew: brew, formula: formula)) }\n            jobs.append(pythonEnvJob)",
     "            jobs.append(pythonEnvJob)\n            if let formula = pythonFormulaNeeded() { jobs.append(pythonFormulaJob(brew: brew, formula: formula)) }"),
    ("P17 the Python check runs with no Python package missing", "qs", "no Python package missing → the Python check is not even run", QE,
     "        if !status.doctorRan, let formula = pythonFormulaNeeded() {", "        if let formula = pythonFormulaNeeded() {"),
    ("P18 no bootstrap when the tools check could not run", "qs", "the tools check could not run + no usable Python", QE,
     "        if !status.doctorRan, let formula = pythonFormulaNeeded() {\n            jobs.append(pythonFormulaJob(brew: brew, formula: formula))\n        }\n", ""),
    ("P19 the menu stops after the bootstrap", "menu", "python bootstrap: the tools check could not run → the Python job, a re-check", MW,
     "            if failure == nil, !status.doctorRan, after.doctorRan, !after.complete {", "            if false {"),
    ("P21 the second round ignores a revoked session", "menu", "python bootstrap: revoked during the check after the Python job", MW,
     "            if (try? checkpoint()) == nil || Task.isCancelled { failure = L(\"stopped\", \"interrotta\"); break }",
     "            if false { failure = L(\"stopped\", \"interrotta\"); break }"),
    ("P22 the second round goes on after a failed job", "menu", "python bootstrap: the first of two second-round jobs fails", MW,
     "                failure = \"\\(job.label): \\(r.failureReason ?? \"failed\")\"\n                for line in r.excerpt { appendJobLine(line) }\n                break",
     "                failure = \"\\(job.label): \\(r.failureReason ?? \"failed\")\"\n                for line in r.excerpt { appendJobLine(line) }"),
    ("P20 a Linux-visible edit", "lv", "linux view:", PR,
     'return "install Python 3.\\(minimumMinor)–3.\\(maximumMinor) with venv support (Debian/Ubuntu: `sudo apt install python3-venv`)"',
     'return "install Python 3.\\(minimumMinor)–3.\\(maximumMinor) with venv support (Debian/Ubuntu: `sudo apt install python3-venv`)."'),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    r = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch)], tree, timeout=5400)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


def test(kind, binary, workdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BRIGLIA_")}
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    if kind == "lv":
        return run([sys.executable, str(ROOT / "scripts" / "linux_view_unchanged.py"), "--worktree"], ROOT, timeout=300, env=env)
    args = {"rt": ["__private-runtime-selftest", "--only", "python"], "qs": ["__quicksetup-selftest", "--only", "18b"],
            "menu": ["__menu-selftest"]}[kind]
    try:
        return run([str(binary)] + args, workdir, timeout=1500, env=env)
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        return subprocess.CompletedProcess(exc.cmd, -9, out.decode("utf-8", "replace") if isinstance(out, bytes) else out, "timed out")


def failed_lines(text):
    return [l.strip() for l in text.splitlines() if l.strip().startswith("✖")]


def mutate(tree, rel, old, new):
    path = tree / rel
    text = path.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"break anchor moved: {rel}: {old!r} (found {text.count(old)})")
    path.write_text(text.replace(old, new))
    return text


def main():
    if sys.platform != "darwin":
        print("macOS only")
        return 2
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-build")
    ap.add_argument("--only")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="bm-pybreak-"))
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
        for kind in ("rt", "qs", "menu", "lv"):
            r = test(kind, binary, work)
            ok = r.returncode == 0
            print(("✔" if ok else "✖") + f" positive control ({kind}): the unmodified tree passes", flush=True)
            if not ok:
                print((r.stdout + r.stderr)[-3000:])
                return 1
        for label, kind, check, rel, old, new in BREAKS:
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            target = ROOT if kind == "lv" else tree
            original = mutate(target, rel, old, new)
            try:
                if kind != "lv":
                    binary = build(tree, scratch)
                r = test(kind, binary, work)
                if kind == "lv":
                    caught = r.returncode != 0 and "Linux view changed" in r.stdout
                    failed = failed_lines(r.stdout)
                else:
                    failed = failed_lines(r.stdout)
                    caught = r.returncode != 0 and any(l.startswith("✖ " + check) for l in failed)
                print(("✔" if caught else "✖") + f" {label}: \"{check}\" fails"
                      + (f" ({len(failed)} failing check(s))" if failed else ""), flush=True)
                failures += 0 if caught else 1
                executed += 1
                if not caught and args.verbose:
                    print((r.stdout + r.stderr)[-6000:])
            finally:
                (target / rel).write_text(original)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
