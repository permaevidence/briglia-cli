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
    # Codex stage-2 round 1 (R1–R7)
    ('M19 no late enrollment when the registry appears after the instance lock', 'round2', T + 'CLI/MemberEntry.swift',
     '        guard AssistantRegistry.presence() != .absent else { return }\n        enter(role: .assistant(kind: kind))',
     '        guard AssistantRegistry.presence() != .absent else { return }\n        _ = kind'),
    ('M20 an unleased running Briglia is not detected', 'round2', T + 'CLI/MemberLease.swift',
     '        case .unknown: return true\n        case .held: break\n        }',
     '        case .unknown: return true\n        case .held: return false\n        }'),
    ('M21 parked state admits Mind operations (and, through them, browser/menu settings)', 'upgrade', T + 'Services/ConversationManager+Persistence.swift',
     '        guard !admissionPaused, !isRestoringMind,',
     '        guard !isRestoringMind,'),
    ('M22 parked state admits terminal/app commands', 'upgrade', T + 'Services/ConversationManager+ControlCommands.swift',
     '        if admissionPaused, text.hasPrefix("/"), token != "/status", !(token == "/upgrade" && upgradeCoordinatorTask != nil) {',
     '        if false, admissionPaused, text.hasPrefix("/"), token != "/status", !(token == "/upgrade" && upgradeCoordinatorTask != nil) {'),
    ('M23 old-image re-exec identifies the running image by its pathname (round-1 shape)', 'round2', T + 'CLI/UpgradeBarrier.swift',
     '        if ProcessInfo.processInfo.environment[reexecGuardKey] == ',
     '        if sha256(file: (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()) == rec.binarySHA256 { return }\n        if ProcessInfo.processInfo.environment[reexecGuardKey] == '),
    ('M24 a removal publishes no transaction (round-1 shape)', 'round2', T + 'Services/AssistantRegistry.swift',
     '                d.records[i].activeTx[kind.rawValue] = ActiveTx(txId: txId, phase: "reserving")',
     '                if digest != nil { d.records[i].activeTx[kind.rawValue] = ActiveTx(txId: txId, phase: "reserving") }'),
    ('M25 the scope change ignores a starting assistant', 'round2', T + 'Services/SubscriptionSharing.swift',
     '                return MemberLeases.users(dir, assistantsOnly: true, except: ownLease).isEmpty ? nil',
     '                return MemberLeases.users(dir, assistantsOnly: true, except: ownLease).isEmpty || true ? nil'),
    ('M26 a wipe without the sharing lock drops `own`', 'round2', T + 'Services/SubscriptionSharing.swift',
     '            clearBinding(&result, removeScope: false)\n            if AssistantProfile.isExtra, scope() == .own {',
     '            clearBinding(&result, removeScope: true)\n            if AssistantProfile.isExtra, scope() == .own {'),
    ('M27 a starting assistant never recovers an orphaned barrier', 'round2', T + 'CLI/MemberEntry.swift',
     '                recoverAtStartupIfOrphaned(barrier)\n',
     '                _ = barrier\n'),
    ('M28 a command already inside its handler does not count as busy', 'upgrade', T + 'Services/ConversationManager+UpgradeBarrier.swift',
     '        if browserSettingsCommandIngress > (ownHandler ? 1 : 0) { return "a command" }',
     '        _ = ownHandler'),
    # Codex stage-2 round 2, F1–F4 (each restores the round-2 behaviour).
    ('M29 any live assistant lease certifies the instance owner (F1)', 'round3', T + 'CLI/MemberLease.swift',
     '            return s.pid == pid && s.processStartTime == start',
     '            return true'),
    ('M30 terminal /prune runs while parked: terminal and manager guards gone (F2)', 'round3', [
        (T + 'CLI/TerminalSession.swift', '            if manager.admissionPaused {\n                print(', '            if false {\n                print('),
        (T + 'Services/ConversationManager+ModelCommands.swift',
         '        guard !admissionPaused else {\n            print("[ConversationManager] /prune refused: parked for an update")\n            try? await sendText(Self.updatingRefusal, to: Self.appChannelAddress)',
         '        guard true else {\n            print("[ConversationManager] /prune refused: parked for an update")\n            try? await sendText(Self.updatingRefusal, to: Self.appChannelAddress)'),
        (T + 'Services/ConversationManager+ModelCommands.swift',
         '        guard !admissionPaused else {\n            print("[ConversationManager] /prune refused: parked for an update")\n            try? await sendText(Self.updatingRefusal, to: address)',
         '        guard true else {\n            print("[ConversationManager] /prune refused: parked for an update")\n            try? await sendText(Self.updatingRefusal, to: address)'),
     ]),
    ('M31 the terminal does not say why /prune was refused (F2)', 'round3', T + 'CLI/TerminalSession.swift',
     '            if manager.admissionPaused {\n                print(', '            if false {\n                print('),
    ('M32 closure does not validate the committed pair (F3)', 'upgrade', T + 'CLI/UpgradeCoordinator.swift',
     '        guard UpgradeBarrier.committedPairOnDisk(barrier, paths: settings.paths) else {\n            barrier.state = .stuck',
     '        guard true || UpgradeBarrier.committedPairOnDisk(barrier, paths: settings.paths) else {\n            barrier.state = .stuck'),
    ('M33 a post-commit rollback leaves installed.json naming the removed pair (F3)', 'upgrade', T + 'CLI/UpgradeJournal.swift',
     '                   rec.binarySHA256 == j.new.binarySHA256 {', '                   rec.binarySHA256 == j.new.binarySHA256, false {'),
    ('M34 the first add publishes its record active before the unleased check (F4)', 'round3', T + 'CLI/ProfilesCommand.swift',
     '            record.state = "adding"\n', '            record.state = "active"\n'),
    ('M35 the rollback deletes a record that is not its own provisional one (F4)', 'round3', T + 'CLI/ProfilesCommand.swift',
     '            guard var d = doc, let i = d.index(name), d.records[i].state == "adding",\n                  d.records[i].addingOp == op, d.records[i].generation == generation else { return }\n            try? FileManager.default.removeItem(at: configRoot',
     '            guard var d = doc, let i = d.index(name) else { return }\n            try? FileManager.default.removeItem(at: configRoot'),
    ('M36 remove ignores an add that is still running (F4)', 'round3', T + 'CLI/ProfilesCommand+Lifecycle.swift',
     '            if d.records[i].state == "adding", let adder = d.records[i].addingOp,', '            if false, let adder = d.records[i].addingOp,'),
    ('M37 a dead provisional record blocks the upgrader forever (F4)', 'round3', T + 'CLI/UpgradeCoordinator.swift',
     '                           ProfileFileLock.probe(settings.registryPaths.txLease(op)) == .dead { continue }',
     '                           ProfileFileLock.probe(settings.registryPaths.txLease(op)) == .dead, false { continue }'),
    # Codex stage-2 round 3, G1.
    ('M38 an instance.lock that cannot be opened counts as nobody running (G1)', 'round3', T + 'CLI/MemberLease.swift',
     '            return err == ENOENT ? .free : .unknown(', '            return err != -1 ? .free : .unknown('),
    ('M39 the probe needs write access to instance.lock (G1)', 'round3', T + 'CLI/MemberLease.swift',
     '        let fd = open(path, O_RDONLY | O_CLOEXEC)\n        guard fd >= 0 else {\n            let err = errno',
     '        let fd = open(path, O_RDWR | O_CLOEXEC)\n        guard fd >= 0 else {\n            let err = errno'),
    # Stage 3 (claims, board, tripwire, heads-ups, worktree helper; A2) and the stage-2 leftovers.
    ('M40 claims ignore other assistants', 'stage3', T + 'Services/FileClaims.swift',
     '                for c in claims(of: peer, ctx) where paths.contains(c.path) {', '                for c in claims(of: peer, ctx) where false && paths.contains(c.path) {'),
    ('M41 a crashed owner still protects its files', 'stage3', T + 'Services/FileClaims.swift',
     '        return doc.claims.filter { peer.probe(lease: $0.lease) != .dead }', '        return doc.claims.filter { _ in true }'),
    ('M42 a closed scope does not release claims (A2)', 'stage3', T + 'Services/FileClaims.swift',
     '                    if c.state == held, c.scopes.isEmpty { continue }', '                    if false, c.scopes.isEmpty { continue }'),
    ('M43 turn end releases claims while its jobs still run (A2)', 'stage3', T + 'Services/FileClaims.swift',
     '            if jobs.isEmpty, let ctx = MultiAssistant.context() {\n                self.close(scope, ctx)', '            if let ctx = MultiAssistant.context() {\n                self.close(scope, ctx)'),
    ('M44 a failed edit keeps its new reservation as held', 'stage3', T + 'Services/FileClaims.swift',
     '                } else if c.wasHeld == true, !kept.isEmpty {', '                } else {'),
    ('M45 another assistant\'s own state is editable (§7.4)', 'stage3', T + 'Services/FileClaims.swift',
     '                for peer in ctx.peers where peer.stateRoots.contains(where: { MultiAssistant.isInside(path, $0) }) {',
     '                for peer in ctx.peers where false && peer.stateRoots.contains(where: { MultiAssistant.isInside(path, $0) }) {'),
    ('M46 the ambient tail lists idle assistants (A2)', 'stage3', T + 'Services/AssistantBoard.swift',
     'now.timeIntervalSince($0.lastActiveAt) <= BoardEntry.activeWindow &&', 'now.timeIntervalSince($0.lastActiveAt) <= BoardEntry.hideAfterIdle &&'),
    ('M47 the board-only tail carries the jobs data note', 'stage3', T + 'Services/AmbientStatus.swift',
     '        if !bash.isEmpty || !subagents.isEmpty { lines.append(dataNote) }', '        lines.append(dataNote)'),
    ('M48 the tripwire never compares', 'stage3', T + 'Services/FileClaims.swift',
     '        snapshot.files.filter { !excluding.contains($0.owned.path) && stamp($0.owned.path) != $0.stamp }.map(\\.owned)',
     '        snapshot.files.filter { _ in false }.map(\\.owned)'),
    ('M49 the tripwire does not tell the claim owner', 'stage3', T + 'Services/FileClaims.swift',
     '        for c in changed { Self.notifyOwner(ctx, c) }', '        for _ in changed {}'),
    ('M50 heads-ups repeat within a turn', 'stage3', T + 'Services/FileClaims.swift',
     '        return announced.insert(key).inserted', '        _ = announced.insert(key); return true'),
    ('M51 the executor ignores a claim refusal', 'stage3e2e', T + 'Services/ToolExecutor.swift',
     '            return ToolResultMessage(toolCallId: call.id, content: MultiAssistantHooks.refusalContent(message))',
     '            _ = message'),
    ('M52 heads-ups for idle assistants', 'stage3', T + 'Services/MultiAssistantHooks.swift',
     '        let states = all.filter(\\.active)', '        let states = all'),
    ('M53 the board tool is listed with one assistant', 'stage3', T + 'Models/ToolModels.swift',
     '        let boardTools: [ToolDefinition] = MultiAssistant.context() != nil ? [board] : []', '        let boardTools: [ToolDefinition] = [board]'),
    ('M54 the coordinating assistant parks before the others (S2-12)', 'stage3e2e', T + 'Services/ConversationManager+UpgradeBarrier.swift',
     '            if detachedCoordinator, !Self.othersParked(barrier, lease: lease, paths: paths) { return }', '            _ = detachedCoordinator'),
    ('M55 /upgrade cancel is ignored by the coordinator (S2-12)', 'stage3', T + 'CLI/UpgradeCoordinator.swift',
     '            if settings.cancelRequested() {', '            if false {'),
    ('M56 integrate moves a branch that is checked out elsewhere', 'stage3e2e', T + 'CLI/WorktreeCommand.swift',
     '                    if checkedOut.isEmpty {', '                    if true {'),
    ('M57 doctor ignores stale reservations', 'stage3', T + 'CLI/DoctorCommand.swift',
     'now.timeIntervalSince($0.reservedAt) > 600', 'now.timeIntervalSince($0.reservedAt) > 6_000_000'),
    ('M58 a board entry naming another profile is trusted', 'stage3', T + 'Services/AssistantBoard.swift',
     '            if let e = entry, e.profile != peer.profile { entry = nil }', '            _ = entry'),
    # Codex stage-3 round 1 (each restores the round-1 behaviour).
    ('M59 claim paths skip padded paths (S3-1)', 'stage3', T + 'Services/MultiAssistantHooks.swift',
     '        return Array(Set(raw.filter { $0.hasPrefix("/") }.map(MultiAssistant.canonical))).sorted()',
     '        return Array(Set(ProjectInstructionsTracker.touchedPaths(toolName: toolName, argumentsJSON: argumentsJSON).map(MultiAssistant.canonical))).sorted()'),
    ('M60 a late settlement keeps closed scopes (S3-2)', 'stage3', T + 'Services/FileClaims.swift',
     '                    c.scopes = Array(kept.union(Set(scopes).intersection(openNow))).sorted()',
     '                    c.scopes = Array(Set(c.scopes).union(scopes)).sorted()'),
    ('M61 a failed checkout listing counts as not checked out (S3-3)', 'stage3e2e', T + 'CLI/WorktreeCommand.swift',
     '                    guard list.ok, list.out.hasPrefix("worktree ") else {', '                    guard true else {'),
    ('M62 every pending notice is acknowledged though only eight were shown (S3-4)', 'stage3', T + 'Services/AssistantBoard.swift',
     '            if markShown { BoardNotices.markShown(shown.map(\\.id)) }', '            if markShown { BoardNotices.markShown(notices.map(\\.id)) }'),
    ('M63 the tripwire caps all peers at 2,000 files (S3-5)', 'stage3', T + 'Services/FileClaims.swift',
     '        return Snapshot(files: owned.map { ($0, stamp($0.path)) }, jobsBefore: jobs)',
     '        return Snapshot(files: owned.prefix(2000).map { ($0, stamp($0.path)) }, jobsBefore: jobs)'),
    ('M64 a raised cancel is read only while someone is busy (S3-6)', 'stage3', [
        (T + 'CLI/UpgradeCoordinator.swift',
         '            // Checked before readiness is accepted (S3-6).\n            if settings.cancelRequested() {',
         '            // Checked before readiness is accepted (S3-6).\n            if !busy.isEmpty, settings.cancelRequested() {'),
        (T + 'CLI/UpgradeCoordinator.swift',
         '        if settings.cancelRequested() { return cancel("cancelled by the user before anything was installed") }\n        // 7–8.',
         '        // 7–8.'),
     ]),
    ('M65 a terminal/app /upgrade returns before its result (S3-7)', 'stage3e2e', T + 'Services/ConversationManager+ControlCommands.swift',
     '        if Self.commandCapture != nil {\n            upgradeHandlerAwaiting = true', '        if false {\n            upgradeHandlerAwaiting = true'),
    ('M66 the recorded-worktree heads-up needs an active board entry (§7.2)', 'stage3', T + 'Services/MultiAssistantHooks.swift',
     '        for s in all where !s.active {', '        for s in all where false {'),
    # Codex stage-3 round 2 (each restores the round-2 behaviour).
    ('M67 the path lock is released before a delayed settlement is recorded (S3-R2-2)', 'stage3', T + 'Services/MultiAssistantHooks.swift',
     '            settleWithRetry(ctx, opId: opId, changed: changed, scopes: scopes, unlocking: pending.locked)',
     '            settleWithRetry(ctx, opId: opId, changed: changed, scopes: scopes); ClaimPathLocks.shared.release(pending.locked)'),
    ('M68 a reservation takes over another unsettled operation (S3-R2-2)', 'stage3', T + 'Services/FileClaims.swift',
     '                if let c = doc.claims.first(where: { $0.path == path }), c.state == reserved, c.opId != opId {',
     '                if let c = doc.claims.first(where: { $0.path == path }), c.state == "-", c.opId != opId {'),
    ('M69 an out-of-turn edit inherits only the open scopes (S3-R2-3)', 'stage3', T + 'Services/FileClaims.swift',
     '        if inTurn { return openScopes().sorted() }',
     '        if inTurn || !openScopes().isEmpty { return openScopes().sorted() }'),
    ('M70 the ticker judges scopes published after its liveness sample (S3-R2-1)', 'stage3', T + 'Services/FileClaims.swift',
     '        let ready = known.filter { pending[$0.key] == $0.value && $0.value.isDisjoint(with: alive) }.map(\\.key)',
     '        let ready = pending.filter { $0.value.isDisjoint(with: alive) }.map(\\.key)'),
    ('M71 the tripwire settles watches added after the sample (S3-R2-1)', 'stage3', T + 'Services/FileClaims.swift',
     '        func finished(_ w: Watch) -> Bool { known.contains(w.id) && w.jobs.isDisjoint(with: alive) }',
     '        func finished(_ w: Watch) -> Bool { w.jobs.isDisjoint(with: alive) }'),
    ('M72 a committed terminal/app /upgrade restarts before delivering its reply (S3-R2-4)', 'stage3e2e', T + 'Services/ConversationManager+ControlCommands.swift',
     '            Self.commandCapture?.deliverBeforeExit()\n', ''),
    # Codex stage-3 round 3.
    ('M73 a job being terminated counts as finished (S3-R3-1)', 'stage3', T + 'Services/BashTools.swift',
     '        Set(entries.values.filter { !$0.lifecycleSettled || $0.terminationsInFlight > 0 }.map(\\.id))',
     '        Set(entries.values.filter { $0.status == .running }.map(\\.id))'),
    # Codex stage-3 round 4.
    ('M74 liveness ignores a process-tree termination still in progress (S3-R4-1)', 'stage3', T + 'Services/BashTools.swift',
     '        Set(entries.values.filter { !$0.lifecycleSettled || $0.terminationsInFlight > 0 }.map(\\.id))',
     '        Set(entries.values.filter { !$0.lifecycleSettled }.map(\\.id))'),
    # Codex stage-3 round 5.
    ('M75 retention prunes an entry whose termination is still in flight (S3-R5-1)', 'stage3', T + 'Services/BashTools.swift',
     '            guard e.terminationsInFlight == 0 else { return false }\n', ''),
    ('M76 removeEntry retires an entry whose termination is still in flight (S3-R5-1)', 'stage3', T + 'Services/BashTools.swift',
     '        if e.terminationsInFlight > 0 { e.retireWhenTerminated = true; return }\n', ''),
    ('M77 the wipe drops entries without joining terminations in flight (S3-R5-1)', 'stage3', T + 'Services/BashTools.swift',
     '            if !entries.values.contains(where: live) || Date() >= deadline { break }',
     '            break'),
    # Codex stage-3 round 6.
    ('M78 the wipe does not signal a /stop batch it has not reached (S3-R6-1)', 'stage3', T + 'Services/BashTools.swift',
     '        // stamped but not reached yet (terminateAll selects those too).\n        await terminateAll()\n',
     '        // stamped but not reached yet (terminateAll selects those too).\n'),
    ('M79 terminateAll skips pre-stamped trees still terminating (S3-R6-1)', 'stage3', T + 'Services/BashTools.swift',
     '            $0.status == .running || ($0.terminationsInFlight > 0 && $0.process.isRunning)',
     '            $0.status == .running'),
    ('M80 the wipe retires live entries when its join limit expires (S3-R6-1)', 'stage3', T + 'Services/BashTools.swift',
     '            if live(e) { retained += 1; continue }\n', ''),
    # Codex stage-3 rounds 7 and 9 (M81, M82, M84) are retired: the
    # wipe-refusal rule (owner decision 2026-10-29, M85–M94) refuses before
    # the claims step whenever a scope is open, so mutating that step's own
    # guard is no longer observable (the guard stays as a belt).
    # Codex stage-3 round 8.
    ('M83 the wipe ignores a turn whose end-of-turn sample is in progress (S3-R8-1)', 'stage3e2e', T + 'Services/FileClaims.swift',
     '    var hasOpenScopes: Bool { !openScopes().isEmpty }',
     '    var hasOpenScopes: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }'),
    # Owner decision 2026-10-29: the wipe / Mind import refuse while work runs.
    ('M85 the wipe has no refusal before it cancels work (owner 2026-10-29)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        if let why = await multiAssistantBusyRefusal() {\n            return ["ABORTED: " + why]\n        }\n',
     ''),
    ('M86 the wipe does not re-check at the destructive step (owner 2026-10-29)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        if let why = await multiAssistantBusyRefusal() {\n            await restartEmailPollingAfterAbortedWipe()\n            return ["ABORTED: " + why]\n        }\n',
     ''),
    ('M87 the refusal ignores background commands (owner 2026-10-29)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '            let bash = await BackgroundProcessRegistry.shared.unsettledEntryIds()\n',
     '            let bash = Set<String>()\n'),
    ('M88 the refusal ignores live subagents (owner 2026-10-29)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '            let agents = await SubagentBackgroundRegistry.shared.liveRunIds()\n',
     '            let agents = Set<String>()\n'),
    ('M89 the refusal ignores open claim scopes (owner 2026-10-29)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '                if !ClaimScopes.shared.hasOpenScopes { return nil }\n',
     '                return nil\n'),
    ('M90 a Mind import does not refuse while work runs (owner 2026-10-29)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        // subagent is cancelled (owner decision 2026-10-29).\n        if let why = await multiAssistantBusyRefusal(outcome: ("", "")) { return why }\n',
     '        // subagent is cancelled (owner decision 2026-10-29).\n'),
    ('M91 the pre-rule behaviour: no refusal anywhere (owner 2026-10-29)', 'stage3e2e', [
        (T + 'Services/ConversationManager+Persistence.swift', '        if let why = await multiAssistantBusyRefusal() {\n            return ["ABORTED: " + why]\n        }\n', ''),
        (T + 'Services/ConversationManager+Persistence.swift', '        if let why = await multiAssistantBusyRefusal() {\n            await restartEmailPollingAfterAbortedWipe()\n            return ["ABORTED: " + why]\n        }\n', ''),
        (T + 'Services/ConversationManager+Persistence.swift', '        // subagent is cancelled (owner decision 2026-10-29).\n        if let why = await multiAssistantBusyRefusal(outcome: ("", "")) { return why }\n', '        // subagent is cancelled (owner decision 2026-10-29).\n'),
        (T + 'Services/ConversationManager+Persistence.swift', '        // import\'s point of no return.\n        if let why = await multiAssistantBusyRefusal(outcome: ("", "")) { return why }\n', '        // import\'s point of no return.\n'),
    ]),
    # Codex stage-3 round 10 (S3-R10-1): input admitted before the gate.
    ('M92 the refusal does not wait for input admitted before the gate (S3-R10-1)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '            let busyIngress = browserSettingsPollIngress > ownPoll || browserSettingsAppIngress > 0 || browserSettingsCommandIngress > ownCommand\n',
     '            let busyIngress = false\n'),
    ('M93 the wipe counts its own Telegram poll tick as admitted input (S3-R10-1)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        let ownPoll = Self.commandCapture == nil ? min(1, browserSettingsPollIngress) : 0\n',
     '        let ownPoll = 0\n'),
    ('M94 a turn started by admitted input is not refused (S3-R10-1)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        if isTurnActive || activeProcessingTask != nil {',
     '        if false {'),
    # Codex stage-3 round 11 (S3-R11-1): startup in progress.
    ('M95 the refusal ignores a startup still in progress (S3-R11-1)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        if isStartingPolling && !startupHeldByRestoreGate {', '        if false {'),
    ('M96 a startup begun under the restore gate recovers at once (S3-R11-1)', 'stage3e2e', T + 'Services/ConversationManager+Inbound.swift',
     '        while isRestoringMind && Self.multiAssistantGateApplies {\n            Self.startupRecoveryWaitsForTesting += 1',
     '        while false {\n            Self.startupRecoveryWaitsForTesting += 1'),
    ('M97 a turn body runs under the restore gate (S3-R11-1 audit)', 'stage3e2e', T + 'Services/ConversationManager+MidTurn.swift',
     '        while isRestoringMind && Self.multiAssistantGateApplies && !Task.isCancelled {', '        while false {'),
    # The intake stop (owner decision 2026-10-29; Codex stage-3 S3-R12-1).
    ('M98 a startup begun under the restore gate runs configure() at once (S3-R12-1)', 'stage3e2e', T + 'Services/ConversationManager+Inbound.swift',
     '        if isRestoringMind && Self.multiAssistantGateApplies {\n            startupHeldByRestoreGate = true',
     '        if false {\n            startupHeldByRestoreGate = true'),
    ('M99 the archive clear does not wait for the chunk writer (S3-R12-1, storage)', 'stage3e2e', T + 'Services/ConversationArchiveService.swift',
     '        await acquireChunkWriter()\n        defer { releaseChunkWriter() }\n        // Delete all chunk files\n',
     '        // Delete all chunk files\n'),
    ('M100 the refusal ignores memory maintenance begun under the gate (intake stop)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        if archiveRecoveryTask != nil || !maintenanceActivities.isEmpty {\n            return Self.busyMessage("memory maintenance", outcome: outcome)',
     '        if false {\n            return Self.busyMessage("memory maintenance", outcome: outcome)'),
    ('M101 a startup held at the gate counts as starting up (intake stop)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        if isStartingPolling && !startupHeldByRestoreGate {', '        if isStartingPolling {'),
    ('M102 archive recovery starts under the restore gate (intake stop)', 'stage3e2e', T + 'Services/ConversationManager+Inbound.swift',
     '        if isRestoringMind && Self.multiAssistantGateApplies {\n            archiveRecoveryDeferredByRestoreGate = true',
     '        if false {\n            archiveRecoveryDeferredByRestoreGate = true'),
    ('M104 a turn held while the history was replaced still runs (intake stop)', 'stage3e2e', T + 'Services/ConversationManager+MidTurn.swift',
     '        if droppedAfterReplacement { return }\n', ''),
    # Codex stage-3 round 13 (S3-R13-1): commands under the gate.
    ('M105 commands are not refused under the restore gate (S3-R13-1)', 'stage3e2e', T + 'Services/ConversationManager+ControlCommands.swift',
     '        if isRestoringMind, text.hasPrefix("/"), !Self.commandsDuringMemoryReplacement.contains(token),',
     '        if false, text.hasPrefix("/"), !Self.commandsDuringMemoryReplacement.contains(token),'),
    ('M106 the busy check does not wait for a command admitted before the gate (S3-R13-1)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     ' || browserSettingsAppIngress > 0 || browserSettingsCommandIngress > ownCommand\n', ' || browserSettingsAppIngress > 0\n'),
    ('M107 the wipe waits for its own command handler (S3-R13-1)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '        let ownCommand = memoryReplacementOwnsCommand ? 1 : 0\n', '        let ownCommand = 0\n'),
    # Codex stage-3 round 14 (S3-R14-1/R14-2).
    ('M108 the wipe does not take the cross-process replacement lock (S3-R14-1)', 'stage3e2e', T + 'Services/ConversationManager+Persistence.swift',
     '            case .acquired(let lock): memoryReplacementLock = lock; return true\n            case .busy: return false\n',
     '            case .acquired(let lock): lock.release(); return true\n            case .busy: return true\n'),
    ('M109 setup-api apply ignores a memory replacement in progress (S3-R14-1)', 'stage3e2e', T + 'CLI/SetupAPICommand.swift',
     '            if verb == "apply" || verb == "subscription" {', '            if false {'),
    ('M110 an admitted Stop is not counted (S3-R14-2)', 'stage3e2e', T + 'Services/ConversationManager+Channels.swift',
     '        browserSettingsCommandIngress += 1\n        defer { browserSettingsCommandIngress -= 1 }\n        await stopActiveExecution(notify: Self.appChannelAddress)',
     '        await stopActiveExecution(notify: Self.appChannelAddress)'),
    # The round-12 head's behaviour (all three intake-stop fixes removed,
    # test seams kept): Codex's sequence must fail.
    ('M103 the round-12 head: no startup hold, no clear serialization, no deferral (S3-R12-1)', 'stage3e2e', [
        (T + 'Services/ConversationManager+Inbound.swift', '        if isRestoringMind && Self.multiAssistantGateApplies {\n            startupHeldByRestoreGate = true',
         '        if false {\n            startupHeldByRestoreGate = true'),
        (T + 'Services/ConversationArchiveService.swift', '        await acquireChunkWriter()\n        defer { releaseChunkWriter() }\n        // Delete all chunk files\n',
         '        // Delete all chunk files\n'),
        (T + 'Services/ConversationManager+Inbound.swift', '        if isRestoringMind && Self.multiAssistantGateApplies {\n            archiveRecoveryDeferredByRestoreGate = true',
         '        if false {\n            archiveRecoveryDeferredByRestoreGate = true'),
    ]),
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
        for entry in BREAKS:
            label, section, rel = entry[0], entry[1], entry[2]
            old, new = (entry[3], entry[4]) if len(entry) == 5 else (None, None)
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            edits = rel if isinstance(rel, list) else [(rel, old, new)]
            originals = {}
            for erel, eold, enew in edits:
                text = mutate(tree, erel, eold, enew)
                originals.setdefault(erel, text)
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
                for erel, text in originals.items():
                    (tree / erel).write_text(text)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
