#!/usr/bin/env python3
"""Deliberate breaks for assistant profiles, stage 2 (MULTI_ASSISTANT_PLAN §16
item 12 and §25.10 item 12): member leases and the entry protocol, identity
transactions, removal and stop, the upgrade barrier and its journal, the
supervisor and the shared ChatGPT login.

Same method as profile_isolation_break_test.py: copy the tree to a scratch
directory, build once (positive control: every section passes), then apply
one mutation at a time, rebuild incrementally and require the named section
of `__multi-assistant-selftest` to FAIL. The repository is never modified.

Usage: python3 scripts/multi_assistant_break_test.py [--keep-build DIR] [--only Mn]
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
T = "TelegramConcierge/"

BREAKS = [
    ("M1 entry does not re-check the registry after publishing its lease", "leases", T + "CLI/MemberEntry.swift",
     "        // 3. Look.\n        recheckRecord(profile)", "        // 3. Look.\n        _ = profile"),
    ("M2 starting assistants skip the settings admission check", "leases", T + "CLI/MemberEntry.swift",
     "                // 4. Settings admission.\n                settingsAdmission(profile: profile)",
     "                // 4. Settings admission.\n                _ = profile"),
    ("M3 offline setters ignore a running assistant", "identity", T + "Services/IdentityChange.swift",
     "            return MemberLeases.users(dir, assistantsOnly: true, except: ownLease).isEmpty ? nil : runningMessage",
     "            _ = dir; return nil"),
    ("M4 the barrier publishes without waiting for sessions", "upgrade", T + "CLI/UpgradeCoordinator.swift",
     "                        busy.append(\"‘\\(displayName(d.profile, settings.registryPaths))’ has \\(e.sidecar?.sessionKind ?? \"a window\") open\")",
     "                        _ = e"),
    ("M5 restart readiness ignores detached Bash jobs", "upgrade", T + "Services/ConversationManager+UpgradeBarrier.swift",
     "        if await BackgroundProcessRegistry.shared.runningBackgroundJobCount() > 0 { return \"a background command\" }",
     "        if await BackgroundProcessRegistry.shared.runningBackgroundJobCount() > 99 { return \"a background command\" }"),
    ("M6 parking uses stopPolling()", "upgrade", T + "Services/ConversationManager+UpgradeBarrier.swift",
     "    func pauseAdmission() { admissionPaused = true }",
     "    func pauseAdmission() { admissionPaused = true; stopPolling() }"),
    ("M7 journal backups deleted before commit", "upgrade", T + "CLI/UpgradeJournal.swift",
     "        j.phase = .placed; j.nextStep = nil\n",
     "        j.phase = .placed; j.nextStep = nil\n        try? fm.removeItem(at: n.backupBinary)\n"),
    ("M8 the barrier skips extra assistants", "upgrade", T + "CLI/UpgradeCoordinator.swift",
     "            for r in doc.records where r.name != AssistantProfile.defaultName {",
     "            for r in doc.records where r.name == \"-\" {"),
    ("M9 trust rule requires candidate > floor", "upgrade", T + "CLI/UpgradeCoordinator.swift",
     "        if let floor, candidate < floor {", "        if let floor, candidate <= floor {"),
    ("M10 a stuck barrier is reopened by recovery without a verified restore", "upgrade", T + "CLI/UpgradeJournal.swift",
     "            _ = write(.stuck, \"restoring the previous version failed\")",
     "            _ = write(.cancelled, \"restoring the previous version failed\")"),
    ("M11 rebind ignores the account fingerprint (D18)", "chatgpt", T + "Services/SubscriptionSharing.swift",
     "            guard oldFp == newFp else { throw SubscriptionError(differentAccountMessage(changedBy: state.signedInBy)) }",
     "            _ = newFp"),
    ("M12 the resolver gives a shared extra its own store", "chatgpt", T + "Services/SubscriptionSharing.swift",
     "        return scope() == .own ? StoragePaths.configRoot : MachinePaths.defaultConfigRoot()",
     "        return StoragePaths.configRoot"),
    ("M13 the wipe signs the shared login out while another assistant shares it", "chatgpt", T + "Services/SubscriptionSharing.swift",
     "        if others.isEmpty {\n            do { if try store.read() != nil { try await store.logout() } }",
     "        if true {\n            do { if try store.read() != nil { try await store.logout() } }"),
    ("M14 cancel ignores the pending login's owner", "chatgpt", T + "Services/SubscriptionSharing.swift",
     "        return (state.pendingLoginBy ?? AssistantProfile.defaultName) == profile",
     "        return true"),
    ("M15 stop signals an unvalidated pid", "remove", T + "CLI/ProfilesCommand+Lifecycle.swift",
     "            guard validated(side) else {", "            guard validated(side) || true else {"),
    ("M16 remove ignores a live member", "remove", T + "CLI/ProfilesCommand+Lifecycle.swift",
     "        if let user = users.first {", "        if let user = users.first, user.uuid == \"-\" {"),
    ("M17 the supervisor restarts an assistant stopped on purpose", "supervisor", T + "CLI/Supervisor.swift",
     "                if status == 0 || byOurSignal {", "                if byOurSignal {"),
    ("M18 owner fields written in never-multi mode", "chatgpt", T + "Services/SubscriptionSharing.swift",
     "    static var ownerTag: String? { CoordinationMode.multi ? AssistantProfile.selectedName : nil }",
     "    static var ownerTag: String? { AssistantProfile.selectedName }"),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    r = run(["swift", "build", "--build-system", "native", *LINUX_JOBS, "--scratch-path", str(scratch)], tree, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


def selftest(binary, workdir, section):
    link = Path(workdir) / "briglia-mbreak"
    if link.exists():
        link.unlink()
    try:
        os.link(binary, link)
    except OSError:
        shutil.copy2(binary, link)
    env = {k: v for k, v in os.environ.items() if not k.startswith("BRIGLIA_")}
    # The selftest makes its own scratch roots; never the live install.
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    args = [str(link), "__multi-assistant-selftest"] + (["--only", section] if section else [])
    return run(args, workdir, timeout=1800, env=env)


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
    ap.add_argument("--skip-control", action="store_true")
    ap.add_argument("--verbose", action="store_true", help="print the selftest output of a break that was not caught")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="briglia-mbreak-"))
    tree = work / "tree"
    tree.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / name, tree / name)
    shutil.copytree(ROOT / "TelegramConcierge", tree / "TelegramConcierge")
    shutil.copytree(ROOT / "scripts", tree / "scripts")
    scratch = Path(args.keep_build) if args.keep_build else work / "build"
    failures = 0
    executed = 0
    try:
        binary = build(tree, scratch)
        if not args.skip_control:
            r = selftest(binary, work, None)
            ok = r.returncode == 0
            print(("✔" if ok else "✖") + " positive control: unmodified copy passes every section", flush=True)
            if not ok:
                print((r.stdout + r.stderr)[-3000:])
                return 1
        for label, section, rel, old, new in BREAKS:
            if args.only and args.only != label.split()[0]:
                continue
            original = mutate(tree, rel, old, new)
            try:
                binary = build(tree, scratch)
                r = selftest(binary, work, section)
                caught = r.returncode != 0
                failed = [l for l in r.stdout.splitlines() if l.startswith("✖")]
                print(("✔" if caught else "✖") + f" {label}: section {section} fails"
                      + (f" ({failed[0][2:90]}…)" if caught and failed else ""), flush=True)
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
