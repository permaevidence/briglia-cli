#!/usr/bin/env python3
"""Deliberate breaks for the apt-get package-list refresh (0.2.72 candidate,
field report 2026-11-18: stale lists on Debian 13 → "404 Not Found").

Same method as python_autoinstall_break_test.py: copy the tree to a scratch
directory, build once (positive control passes), then apply one mutation at
a time, rebuild incrementally and require the NAMED check to be reported as
failed (✖), not just a non-zero exit. The repository is never modified.
Every package manager in these checks is a fake (an injected runner, or
shell scripts in a temp directory); no real sudo or apt ever runs.

The selftest binary runs through a hard link under a private name with
temporary XDG roots (macOS preferences follow the process name; this Mac
hosts a live Briglia under the plain name).

macOS only. Usage: python3 scripts/apt_refresh_break_test.py [--only R1,M2] [--verbose] [--keep-build DIR]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LP = "TelegramConcierge/Services/LinuxPackageMap.swift"
QE = "TelegramConcierge/CLI/QuickSetup/QuickSetupEnvironment.swift"
MW = "TelegramConcierge/CLI/Menu/MenuWorkflow.swift"
TS = "TelegramConcierge/Services/ToolchainService.swift"

# (label, check label prefix that must fail, file, old, new) — all in __menu-selftest
BREAKS = [
    ("R1 apt-get is never refreshed", "apt refresh: apt-get → a list refresh, then the install, in that order", LP,
     'manager == "apt-get" ? [managerPath, "update"] : nil', 'nil as [String]?'),
    ("R2 the refresh runs after the install", "apt refresh: apt-get → a list refresh, then the install, in that order", QE,
     'label: "\\(manager) install \\(packages.joined(separator: " "))"))\n        return jobs\n',
     'label: "\\(manager) install \\(packages.joined(separator: " "))"))\n        return jobs.reversed()\n'),
    ("R3 the refresh is not best effort", "apt refresh: only the refresh is best effort", QE,
     'label: "\\(manager) update", bestEffort: true))', 'label: "\\(manager) update", bestEffort: false))'),
    ("R4 the refresh upgrades packages", "apt refresh: the refresh never upgrades", LP,
     'manager == "apt-get" ? [managerPath, "update"] : nil', 'manager == "apt-get" ? [managerPath, "update", "&&", "full-upgrade"] : nil'),
    ("R5 dnf is refreshed too", "apt refresh: dnf unchanged", LP,
     'manager == "apt-get" ? [managerPath, "update"] : nil', '(manager == "apt-get" || manager == "dnf") ? [managerPath, manager == "dnf" ? "makecache" : "update"] : nil'),
    ("R6 pacman gets -Sy", "apt refresh: pacman unchanged", LP,
     'manager == "apt-get" ? [managerPath, "update"] : nil', 'manager == "apt-get" ? [managerPath, "update"] : (manager == "pacman" ? [managerPath, "-Sy"] : nil)'),
    ("R7 a refresh alone when nothing is to be installed", "apt refresh: nothing to install → no job at all", QE,
     "        guard !packages.isEmpty else { return [] }\n", ""),
    ("S1 the wizard refreshes before every install", "apt refresh (wizard): the lists are refreshed exactly once", LP,
     "        if !refreshAttempted, let refresh", "        if let refresh"),
    ("S2 a failed refresh stops the wizard's install", "apt refresh (wizard): the refresh fails → the install still runs", LP,
     '            case .exited(let code): refreshFailure = "\\(manager) update exited with status \\(code)"',
     '            case .exited(let code): return "\\(manager) update exited with status \\(code)"'),
    ("S3 the wizard's failure text forgets the refresh", "apt refresh (wizard): refresh and install both fail", LP,
     "        guard let refreshFailure else { return failure }", "        guard let refreshFailure, false else { return failure }"),
    ("S4 the wizard retries the install", "apt refresh (wizard): refresh fine, install fails → exactly one attempt", LP,
     '        case .exited(let code): failure = "\\(manager) exited with status \\(code)"',
     '        case .exited(let code): _ = run(LinuxPackageMap.installCommand(manager: manager, managerPath: managerPath, packages: [package])); failure = "\\(manager) exited with status \\(code)"'),
    ("S5 the wizard does not say it refreshes", "apt refresh (wizard): the terminal is told once before the refresh", LP,
     '            announce("Refreshing package lists (\\(manager) update)\\u{2026}")\n', ""),
    ("M1 the menu stops at a failed refresh", "apt refresh (menu): the refresh fails → the install still runs", MW,
     "                    if job.bestEffort, r.survivors == nil,", "                    if false, job.bestEffort, r.survivors == nil,"),
    ("M2 the menu's error forgets the refresh", "apt refresh (menu): refresh and install both fail", MW,
     "                    if let bestEffortFailure {\n                        failure = why",
     "                    if let bestEffortFailure, false {\n                        failure = why"),
    ("M3 the menu passes over any failed step", "apt refresh (menu): a failed step that is NOT best effort still stops", MW,
     "                    if job.bestEffort, r.survivors == nil,", "                    if r.survivors == nil,"),
    ("M4 the menu gives no warning line", "apt refresh (menu): the refresh fails → the install still runs", MW,
     '                        self.appendJobLine(self.L("\\u{26A0} Could not refresh', '                        _ = (self.L("\\u{26A0} Could not refresh'),
    # Round 2 (Codex round 1, P2): an interrupted refresh ends the install.
    ("I1 the menu passes over a signal-killed refresh", "apt refresh (menu): the refresh is killed by SIGINT", MW,
     "                    if job.bestEffort, case .signaled(let sig) = r.outcome {",
     "                    if false, job.bestEffort, case .signaled(let sig) = r.outcome {"),
    ("I2 the menu stops at a timed-out refresh", "apt refresh (menu): control — a refresh that times out still goes on", MW,
     "        case .timedOut, .failedToStart: return true", "        case .timedOut, .failedToStart: return false"),
    ("I3 the menu stops at an ordinary failed refresh", "apt refresh (menu): the refresh fails → the install still runs", MW,
     "        case .exited(let code): return code != 0\n        case .timedOut", "        case .exited: return false\n        case .timedOut"),
    ("I4 the wizard adapter drops the signal", "apt refresh (wizard adapter): a refresh killed by SIGINT", TS,
     "        if process.terminationReason == .uncaughtSignal { return .signaled(process.terminationStatus) }\n", ""),
    ("I5 the wizard installs after an interrupted refresh", "apt refresh (wizard): the refresh is interrupted → nothing installed", LP,
     "                interruption = why\n                return \"Installation interrupted: \\(why), so \\(package) was not installed. Run it again to retry.\"",
     "                refreshFailure = why"),
    ("I6 the wizard forgets an interruption", "apt refresh (wizard): the refresh is interrupted → nothing installed", LP,
     "        if let interruption {\n            return \"not installed: the installation was interrupted (\\(interruption)). Run it again to retry.\"\n        }\n", ""),
    ("I7 an interrupted install does not end the run", "apt refresh (wizard): an interrupted install ends the run", LP,
     "            interruption = why\n            failure = \"Installation interrupted: \\(why)\"",
     "            failure = \"Installation interrupted: \\(why)\""),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    cmd = ["taskpolicy", "-b", "swift", "build", "-j", "2", "--build-system", "native", "--scratch-path", str(scratch)]
    r = run(cmd, tree, timeout=5400)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


def test(binary, workdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "SM_"))}
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    name = "briglia-aptbreak-" + uuid.uuid4().hex[:8]
    link = binary.parent / name
    os.link(binary, link)
    try:
        return run(["taskpolicy", "-b", str(link), "__menu-selftest"], workdir, timeout=900, env=env)
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        return subprocess.CompletedProcess(exc.cmd, -9, out.decode("utf-8", "replace") if isinstance(out, bytes) else out, "timed out")
    finally:
        link.unlink(missing_ok=True)
        subprocess.run(["defaults", "delete", name], capture_output=True)
        Path.home().joinpath("Library/Preferences", name + ".plist").unlink(missing_ok=True)


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
    work = Path(tempfile.mkdtemp(prefix="bm-aptbreak-"))
    tree = work / "tree"
    tree.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / name, tree / name)
    shutil.copytree(ROOT / "TelegramConcierge", tree / "TelegramConcierge")
    scratch = Path(args.keep_build) if args.keep_build else work / "build"
    failures = executed = 0
    try:
        binary = build(tree, scratch)
        r = test(binary, work)
        ok = r.returncode == 0
        print(("✔" if ok else "✖") + " positive control: the unmodified tree passes", flush=True)
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
                failed = failed_lines(r.stdout)
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
