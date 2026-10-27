#!/usr/bin/env python3
"""Deliberate breaks for assistant profiles, stage 1 (MULTI_ASSISTANT_PLAN v5
§16 item 12).

Copies the working tree to a scratch directory, builds it once (positive
control: the profile isolation selftest must pass there), then applies one
source mutation at a time, rebuilds incrementally and requires the selftest
(or, for the preferences lint, the lint) to FAIL. Every mutation is reverted
before the next. The repository itself is never modified.

Usage: python3 scripts/profile_isolation_break_test.py [--keep-build DIR] [--only Bn]
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

BREAKS = [
    ("B1 data root ignores the profile", "TelegramConcierge/CLI/StoragePaths.swift",
     "static let dataRoot: URL = AssistantProfile.selectedDataRoot()", "static let dataRoot: URL = resolveDataRoot()"),
    ("B2 every assistant shares one preferences domain", "TelegramConcierge/Utilities/Prefs.swift",
     "        guard let name = suiteName() else { return UserDefaults.standard }",
     "        guard let name = suiteName(), name.isEmpty else { return UserDefaults.standard }"),
    ("B3 spill pool not namespaced", "TelegramConcierge/Services/TruncationService.swift",
     '        : spillBase + "briglia-tool-output-\\(AssistantProfile.selectedName)-\\(AssistantProfile.installationHash(AssistantProfile.selectedName))/"',
     '        : spillBase + "briglia-tool-output/"'),
    ("B4 unknown profile falls back to default", "TelegramConcierge/CLI/ProfileBootstrap.swift",
     "            return .failure(Failure(message: unknownMessage(name, available: available(), invalid: false)))",
     "            return .success(Decision(profile: AssistantProfile.defaultName, arguments: args))"),
    ("B5 release trust read from the profile root", "TelegramConcierge/CLI/ReleaseSigning.swift",
     'return MachinePaths.defaultDataRoot().appendingPathComponent("release_trust.json")',
     'return StoragePaths.dataRoot.appendingPathComponent("release_trust.json")'),
    ("B6 an extra sends the computer-wide notices", "TelegramConcierge/CLI/Profile.swift",
     "nonisolated static var sendsMachineNotices: Bool { AssistantProfile.isDefault }",
     "nonisolated static var sendsMachineNotices: Bool { true }"),
    ("B7 duplicate-bot check skipped at reservation", "TelegramConcierge/Services/AssistantRegistry.swift",
     "                if let owner = holder(of: digest, kind: kind, excluding: profile, in: d) {\n                    throw RegistryError(conflictMessage(kind, owner: owner))",
     "                if let owner = holder(of: digest, kind: kind, excluding: profile, in: d), owner.name == \"-\" {\n                    throw RegistryError(conflictMessage(kind, owner: owner))"),
    ("B8 startup reconciliation polls a bot another assistant holds", "TelegramConcierge/Services/AssistantRegistry.swift",
     "                    doc = d\n                    return .conflict(conflictMessage(kind, owner: owner))",
     "                    doc = d\n                    _ = owner; return .allowed"),
    ("B9 shared Chrome profile", "TelegramConcierge/Services/ManagedPlaywright.swift",
     'browserProfile = extra ? dataRoot.appendingPathComponent("browser-profile", isDirectory: true) : nil',
     "browserProfile = nil"),
    ("B10 StoragePaths touched before the bootstrap", "TelegramConcierge/CLI/AdaMain.swift",
     "        let arguments = ProfileBootstrap.run()",
     "        _ = StoragePaths.dataRoot\n        let arguments = ProfileBootstrap.run()"),
    ("B11 ChatGPT sign-in lock not exclusive", "TelegramConcierge/Services/SubscriptionBrowserLogin.swift",
     "        switch ProfileFileLock.take(url) {",
     "        switch ProfileFileLock.take(url.appendingPathExtension(UUID().uuidString)) {"),
    ("B12 wrapper scripts lose the profile", "TelegramConcierge/Services/PrivateRuntime.swift",
     '        AssistantProfile.selectionArguments.map { " " + shellQuote($0) }.joined()',
     '        ""'),
    ("B13 a live writer's reservation expires", "TelegramConcierge/Services/AssistantRegistry.swift",
     "            guard ProfileFileLock.probe(paths.txLease(active.txId)) == .dead else { continue }",
     "            guard ProfileFileLock.probe(paths.txLease(active.txId)) != .unknown else { continue }"),
    ("B14 --copy-keys copies the bot token", "TelegramConcierge/CLI/ProfilesCommand.swift",
     "        KeychainHelper.llmProviderKey, ProviderProfiles.activeProfileKey,",
     "        KeychainHelper.telegramBotTokenKey, KeychainHelper.llmProviderKey, ProviderProfiles.activeProfileKey,"),
    ("B15 extras share default's landing zone", "TelegramConcierge/Services/LandingZone.swift",
     "        if AssistantProfile.isExtra {\n            if let folder",
     "        if AssistantProfile.isExtra && false {\n            if let folder"),
    ("B16 machine notice state follows the profile root", "TelegramConcierge/Services/UpdateNoticeStore.swift",
     'state: MachinePaths.defaultDataRoot().appendingPathComponent("update/notice.json"))',
     'state: StoragePaths.dataRoot.appendingPathComponent("update/notice.json"))'),
    ("B17 commit ignores a lost reservation", "TelegramConcierge/Services/AssistantRegistry.swift",
     "                guard record.activeTx[kind.rawValue]?.txId == txId, slot.pending?.txId == txId,",
     "                guard record.activeTx[kind.rawValue]?.txId != \"-\","),
]

LINT_BREAK = ("L1 UserDefaults.standard used directly", "TelegramConcierge/Services/ConversationManager+Inbound.swift",
              "            return Prefs.store.bool(forKey: shouldResumePollingDefaultsKey)",
              "            return UserDefaults.standard.bool(forKey: shouldResumePollingDefaultsKey)")


def run(cmd, cwd, timeout=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def build(tree, scratch):
    r = run(["swift", "build", *LINUX_JOBS, "--scratch-path", str(scratch)], tree, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


def selftest(binary, workdir):
    # A differently named hard link: never the real `briglia` domain.
    link = Path(workdir) / "briglia-pbreak"
    if link.exists():
        link.unlink()
    try:
        os.link(binary, link)
    except OSError:
        shutil.copy2(binary, link)
    return run([str(link), "__profile-isolation-selftest"], workdir, timeout=900)


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
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="briglia-pbreak-"))
    tree = work / "tree"
    tree.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / name, tree / name)
    shutil.copytree(ROOT / "TelegramConcierge", tree / "TelegramConcierge")
    shutil.copytree(ROOT / "scripts", tree / "scripts")
    scratch = Path(args.keep_build) if args.keep_build else work / "build"
    failures = 0
    try:
        # Lint break (no build needed).
        label, rel, old, new = LINT_BREAK
        if not args.only or args.only == label.split()[0]:
            original = mutate(tree, rel, old, new)
            r = run([sys.executable, str(tree / "scripts/prefs_lint.py")], tree)
            ok = r.returncode != 0
            print(("✔" if ok else "✖") + f" {label}: lint fails")
            failures += 0 if ok else 1
            (tree / rel).write_text(original)
        binary = build(tree, scratch)
        r = selftest(binary, work)
        ok = r.returncode == 0
        print(("✔" if ok else "✖") + " positive control: unmodified copy passes")
        if not ok:
            print((r.stdout + r.stderr)[-2000:])
            return 1
        for label, rel, old, new in BREAKS:
            if args.only and args.only != label.split()[0]:
                continue
            original = mutate(tree, rel, old, new)
            try:
                binary = build(tree, scratch)
                r = selftest(binary, work)
                caught = r.returncode != 0
                failed_checks = [l for l in r.stdout.splitlines() if l.startswith("✖")]
                print(("✔" if caught else "✖") + f" {label}: selftest fails"
                      + (f" ({failed_checks[0][2:80]}…)" if caught and failed_checks else ""))
                failures += 0 if caught else 1
            finally:
                (tree / rel).write_text(original)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    total = len(BREAKS) + 1
    print(f"\n{total - failures}/{total} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
