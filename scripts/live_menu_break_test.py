#!/usr/bin/env python3
"""Deliberate breaks for the live menu (KEYLESS_WEB_AND_LIVE_MENU_PLAN Part B,
§B.11).

Same method as keyless_web_break_test.py: copy the tree to a scratch
directory, build once (positive control: `__live-menu-selftest` and the
headless menu test pass), then apply one mutation at a time, rebuild
incrementally and require the NAMED check to be reported as failed (✖), not
just a non-zero exit. The repository is never modified.

Usage: python3 scripts/live_menu_break_test.py [--keep-build DIR] [--only L1,L2]
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
S = "TelegramConcierge/Services/"
W = S + "Settings/SettingsWriter.swift"
C = "TelegramConcierge/CLI/"

# (label, test, check label prefix that must fail, file, old, new)
# test: "selftest" (__live-menu-selftest) or "headless" (menu_headless_test.py)
BREAKS = [
    ("L1 the offline menu holds the instance lease for its lifetime", "headless",
     "the open offline menu holds no instance lease", C + "Menu/MenuCommand.swift",
     "        let leaseBox = QuickSetupSession.LeaseBox(legacyLease)",
     "        if legacyLease == nil, case .success(let l) = InstanceLease.acquire(label: \"menu\") { legacyLease = l }\n        let leaseBox = QuickSetupSession.LeaseBox(legacyLease)"),
    ("L2 classification at prepare time (written key roles only)", "selftest",
     "decision: removing a key while busy is staged", W,
     "            if routeChanged && !holdsBarrier && !immediate { return .needsBarrier }",
     "            let prepareTime = change.touchedKeys.contains { SettingsKeyRoles.role($0) == .route }\n            _ = routeChanged\n            if prepareTime && !holdsBarrier && !immediate { return .needsBarrier }"),
    ("L3 a route change is applied mid-turn", "selftest",
     "commit: a route change while busy is staged (pending)", W,
     "            if routeChanged && !holdsBarrier && !immediate { return .needsBarrier }",
     "            _ = holdsBarrier; _ = immediate"),
    ("L4 a staged change is not superseded by a Telegram write", "selftest",
     "supersede: a later write of its key drops the staged change", W,
     "        let relevant = keys.filter { !$0.hasPrefix(SettingsWriter.attemptMarkerPrefix) }",
     "        let relevant = Set<String>(); _ = keys"),
    ("L5 an uncertain logout is replayed by recovery", "selftest",
     "recovery: an uncertain logout is reported, never replayed", S + "Settings/SettingsRecovery.swift",
     "                doc.attempts.removeValue(forKey: id)\n",
     "                doc.attempts.removeValue(forKey: id)\n                if evidence == .unknown, record.authKind == \"logout\", let path = record.storePath { try? SettingsWriter.authStore(path).write(SubscriptionAuthState(generation: UUID().uuidString)) }\n"),
    ("L6 the replacement-epoch check is removed", "selftest",
     "epoch: a change prepared before a wipe is refused after it", W,
     "            guard epoch == change.epoch else { return .refused(epochMessage, code: \"epoch\") }",
     "            _ = epoch"),
    ("L7 the executor keeps a cached key (no stamp check)", "selftest",
     "stamp: a key saved elsewhere reaches the executor", S + "ConversationManager+SettingsWriter.swift",
     "        guard force || digest != serviceConfigStamp else { return }",
     "        guard force else { return }; _ = digest"),
    ("L8 the idle trigger is removed", "selftest",
     "daemon: the idle trigger applies the staged change", S + "ConversationManager+PruneSummaries.swift",
     "        // Same idle transitions wake the settings scheduler (plan B.5).\n        kickSettingsApply()\n",
     "        // Same idle transitions wake the settings scheduler (plan B.5).\n"),
    ("L9 an agent field edit bypasses the observer", "selftest",
     "agent edit: supersedes an overlapping staged menu change", S + "Settings/SettingsAgentEdit.swift",
     "        let result = await commit(prepared)",
     "        let result = await SettingsSupersede.$maintenanceWrite.withValue(true) { await commit(prepared) }"),
    ("L10 preconditions are not checked", "selftest",
     "race: a write before the decision point aborts the commit", W,
     "            for (key, digest) in change.expected where SettingsDigest.of(current[key]) != digest { conflicts.append(key) }",
     "            _ = change.expected"),
    ("L11 the auth state does not record the attempt", "selftest",
     "publish: the auth state records the attempt", W,
     "                    state.commitPending(credential, generation: generation)\n                    state.lastAttempt = attempt",
     "                    state.commitPending(credential, generation: generation)"),
    ("L12 closing admission leaves queued writers waiting", "selftest",
     "lifecycle: a queued writer is settled with a refusal", S + "Settings/SettingsCommitGate.swift",
     "            if w.lifecycle { kept.append(w) } else { w.resume.resume(returning: nil) }",
     "            kept.append(w)"),
    ("L13 a Telegram settings command commits inside counted ingress", "selftest",
     "daemon: the command waits for the token instead of writing", S + "ConversationManager+ControlCommands.swift",
     "        if Self.settingsCommandTokens.contains(token), !Self.settingsCommandInline {",
     "        if Self.settingsCommandTokens.contains(token), !Self.settingsCommandInline, Bool(\"false\") == true {"),
    ("L14 no handover when Briglia starts", "headless",
     "handover: the page is sent to the running Briglia's own menu", C + "Menu/MenuCommand.swift",
     "                    if let link = await Self.liveHubLink() {\n                        await menu.beginHandover(link: link)",
     "                    if let link = await Self.liveHubLink(), Bool(\"false\") == true {\n                        await menu.beginHandover(link: link)"),
    ("L15 the pairing step does not hold the lease", "selftest",
     "pairing: the open Telegram step holds the instance lease", C + "Menu/MenuWorkflow.swift",
     "            if env.live == nil, !env.pairing.begin() {",
     "            if env.live == nil, Bool(\"false\") == true, !env.pairing.begin() {"),
    ("L16 a daemon kept off by the pairing step fails (exit 1) instead of 75", "selftest",
     "startup: a daemon starting while the menu pairs Telegram exits 75", C + "TerminalSession.swift",
     "                    throw ExitCode(75)", "                    throw ExitCode(1)"),
    ("L17 a lost forwarded answer is resubmitted", "selftest",
     "forward: a lost answer is looked up once, never resubmitted", C + "Settings/SettingsClient.swift",
     "                // Lost after sending: never resubmit; one lookup by id.\n",
     "                // Lost after sending: never resubmit; one lookup by id.\n                _ = try? await Task.detached { try OwnerSocket.request([\"type\": \"settings_commit\", \"change\": object], timeout: 300) }.value\n"),
    ("L18 an older daemon gets a local write", "selftest",
     "forward: an older daemon answers owner_protocol_unsupported", C + "Settings/SettingsClient.swift",
     "                if why.contains(\"unknown request type\") {",
     "                if why.contains(\"unknown request type\"), Bool(\"false\") == true {"),
    ("L19 a credential value is a route input", "selftest",
     "roles: a credential's new value never changes the snapshot", S + "Settings/RouteSnapshot.swift",
     "                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields[\"c:\" + key] = \"present\" }",
     "                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields[\"c:\" + key] = value }"),
    ("L20 a refused barrier after the claim drops the staged change", "selftest",
     "apply: a refusal after the claim and before intent returns the change to staged", W,
     "            if result.state == .refused, [\"admission\", \"busy\"].contains(result.code ?? \"\") || gate.admissionClosedReason != nil {",
     "            if result.state == .refused, gate.admissionClosedReason != nil {"),
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


def test(kind, binary, tree, workdir):
    try:
        return _test(kind, binary, tree, workdir)
    except subprocess.TimeoutExpired as exc:
        return Timed(exc)


def _test(kind, binary, tree, workdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BRIGLIA_")}
    # Both tests make their own scratch roots; never the live install.
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    if kind == "headless":
        return run([sys.executable, str(tree / "scripts" / "menu_headless_test.py"), str(binary)], tree, timeout=900, env=env)
    return run([str(binary), "__live-menu-selftest"], workdir, timeout=900, env=env)


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
    work = Path(tempfile.mkdtemp(prefix="bm-lmbreak-", dir="/tmp" if os.path.isdir("/tmp") else None))
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
        for kind in ("selftest", "headless"):
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
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
