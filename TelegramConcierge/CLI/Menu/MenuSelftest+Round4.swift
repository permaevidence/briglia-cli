import Foundation

/// Codex round 4 on 707b516: completion side effects of work that outlives a
/// live email change. R1 (reworked in round 5): an unstamped AgentMail
/// checkpoint is never adopted, even by a FRESH process after a storage
/// failure during an account change. R2: a late Google result clears/opens no maintenance episode,
/// bumps no failure counter and launches no further snippet subprocess.
@MainActor
extension MenuSelftestContext {

    func lateEmailEffects() async {
        await agentMailFreshProcess()
        await googleLateEffects()
    }

    // MARK: R1 — pre-upgrade AgentMail checkpoints, across a process restart
    //
    // Round 5 (Codex on 9105506): a durable marker can't be the guard, since
    // the marker and the checkpoint share the data directory and one storage
    // failure defeats both. An unstamped checkpoint has no provable owner, so
    // no process ever adopts it; only a checkpoint stamped for the current
    // account is restored.

    private func agentMailFreshProcess() async {
        let checkpoint = AgentMailService.pollStateURLForTesting
        let hourAgo = Date().addingTimeInterval(-3600)
        func writeCheckpoint(account: String?) throws {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try PrivateStorage.writeAtomically(try encoder.encode(AgentMailService.PollState(watermark: hourAgo, drains: [:], savedAt: hourAgo, account: account)), to: checkpoint)
        }
        func savedAccount() -> String? {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return (try? Data(contentsOf: checkpoint)).flatMap { try? decoder.decode(AgentMailService.PollState.self, from: $0) }?.account
        }
        /// A new actor = a new process's initial state.
        func freshProcessAdoptsOld() async -> Bool {
            let fresh = AgentMailService()
            await fresh.startBackgroundPoll()
            let adopted = await fresh.watermarkForTesting().map { $0 < Date().addingTimeInterval(-1800) } ?? false
            await fresh.stopBackgroundPoll()
            return adopted
        }
        let oldMarker = checkpoint.deletingLastPathComponent().appendingPathComponent("agentmail_poll_state.legacy-closed")
        do {
            let manager = ConversationManager()
            _ = await AgentMailService.shared.resetForWipe()
            try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "synthetic-round4-key-a")
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "agentmail")
            await manager.reloadBrowserSettings()
            await AgentMailService.shared.stopBackgroundPoll()

            // Positive control: the account's own stamped checkpoint is
            // restored by a new process (restart catch-up still works).
            let accountA = AgentMailService.currentAccountFingerprint()
            try writeCheckpoint(account: accountA)
            check("agentmail: control — a new process restores the account's own stamped checkpoint", await freshProcessAdoptsOld())

            // The first start after the upgrade: an unstamped checkpoint is
            // not adopted, and a fresh baseline stamped for the current
            // account replaces it.
            try writeCheckpoint(account: nil)
            check("agentmail: the first start after the upgrade never adopts an unstamped checkpoint", !(await freshProcessAdoptsOld()))
            check("agentmail: …and replaces it with a fresh baseline stamped for the current account", savedAccount() == accountA)
            check("agentmail: no closure marker file is written any more", !FileManager.default.fileExists(atPath: oldMarker.path))

            // Another account's stamped checkpoint is never adopted.
            try writeCheckpoint(account: String(repeating: "0", count: 64))
            check("agentmail: another account's stamped checkpoint is never adopted", !(await freshProcessAdoptsOld()))

            #if os(macOS)
            // Codex's round-5 reproduction: pre-upgrade checkpoint, account
            // change while the whole data directory is unwritable (removal
            // and every replacement fail), storage recovers, then a new
            // process starts on the new account.
            let root = checkpoint.deletingLastPathComponent()
            try writeCheckpoint(account: nil)
            try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "synthetic-round5-key-b")
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: root.path)
            await manager.reloadBrowserSettings()
            let stuck = savedAccount() == nil && FileManager.default.fileExists(atPath: checkpoint.path)
            await AgentMailService.shared.stopBackgroundPoll()
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: root.path)
            check("agentmail: fault injection — the unwritable data directory left the old unstamped checkpoint in place", stuck, "stuck \(stuck)")
            let adopted = await freshProcessAdoptsOld()
            check("agentmail: after the shared storage failure clears, a new process never gives the new account the old position",
                  !adopted && savedAccount() == AgentMailService.currentAccountFingerprint(), "adopted \(adopted)")
            #endif

            try? FileManager.default.removeItem(at: checkpoint)
            try KeychainHelper.delete(key: KeychainHelper.agentMailApiKeyKey)
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "none")
            await manager.reloadBrowserSettings()
        } catch { check("agentmail: round-4/5 fixture ran", false, error.localizedDescription) }
    }

    // MARK: R2 — late Google results have no completion side effects

    private func googleLateEffects() async {
        let gws = GoogleWorkspaceService.shared
        let alerts = MenuCount()
        await MaintenanceAlertCenter.shared.setDeliveryHandler { _ in alerts.add(1); return true }
        defer { Task { await MaintenanceAlertCenter.shared.setDeliveryHandler { _ in true } } }

        // (a) Late success after a stop: no recovery notification.
        _ = await MaintenanceAlertCenter.shared.reportFailure(.googleWorkspace, error: "synthetic round-4 failure", deterministic: false)
        alerts.reset()
        let gate = MenuGate()
        await gws.setArrivalFetchForTesting { _ in await gate.wait(); return [] }
        let tick = Task { await gws.pollOnceForTesting() }
        for _ in 0..<400 where !gate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
        _ = await gws.resetForWipe(timeoutSeconds: 0)
        gate.open(); await tick.value
        check("gws: a late success after Google is stopped sends no recovery notification", alerts.value == 0, "notifications \(alerts.value)")
        // Control: a current success does close the episode (one notice).
        await gws.setArrivalFetchForTesting { _ in [] }
        await gws.pollOnceForTesting()
        check("gws: control — a current success still reports recovery", alerts.value == 1, "notifications \(alerts.value)")

        // (b) Late final-attempt failure at the alert threshold: no counter
        // bump, no maintenance alert (and so no self-heal).
        alerts.reset()
        await gws.setConsecutiveFailuresForTesting(4)
        let calls = MenuCount()
        let lastGate = MenuGate()
        await gws.setArrivalFetchForTesting { _ in
            calls.add(1)
            if calls.value == 3 { await lastGate.wait() }
            return nil
        }
        let failing = Task { await gws.pollOnceForTesting() }
        for _ in 0..<1200 where !lastGate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
        _ = await gws.resetForWipe(timeoutSeconds: 0)
        lastGate.open(); await failing.value
        let counter = await gws.consecutiveFailuresForTesting()
        check("gws: a late final failed attempt after a stop changes no failure count and raises no alert",
              lastGate.hasArrived && counter == 4 && alerts.value == 0, "reached \(lastGate.hasArrived) counter \(counter) alerts \(alerts.value)")
        // Control: the same exhausted pass while current reaches the threshold.
        await gws.setArrivalFetchForTesting { _ in nil }
        await gws.pollOnceForTesting()
        let after = await gws.consecutiveFailuresForTesting()
        check("gws: control — a current exhausted pass counts and alerts at the threshold",
              after == 5 && alerts.value >= 1, "counter \(after) alerts \(alerts.value)")
        await gws.setArrivalFetchForTesting(nil)
        await gws.setConsecutiveFailuresForTesting(0)

        // (c) Triage finishes after a stop: no snippet subprocess starts.
        let triageJSON = #"{"messages":[{"id":"t1"},{"id":"t2"},{"id":"t3"}]}"#
        let snippets = MenuCount()
        func install(_ triageGate: MenuGate?) async {
            await gws.setRunGwsForTesting { args in
                if args.contains("+triage") {
                    if let triageGate { await triageGate.wait() }
                    return .init(stdout: triageJSON, failureDetail: nil, stderrHead: nil)
                }
                snippets.add(1)
                return .init(stdout: #"{"snippet":"s"}"#, failureDetail: nil, stderrHead: nil)
            }
        }
        await install(nil)
        let normal = await gws.fetchUnreadSnapshotForTesting()
        check("gws: control — triage then one snippet per message", normal?.count == 3 && snippets.value == 3,
              "emails \(normal?.count ?? -1) snippets \(snippets.value)")
        snippets.reset()
        let triageGate = MenuGate()
        await install(triageGate)
        let snapshot = Task { await gws.fetchUnreadSnapshotForTesting() }
        for _ in 0..<400 where !triageGate.hasArrived { try? await Task.sleep(nanoseconds: 5_000_000) }
        await gws.stopBackgroundPoll()
        triageGate.open()
        let late = await snapshot.value
        check("gws: triage that finishes after a stop launches no snippet subprocess and returns nothing",
              late == nil && snippets.value == 0, "result \(late?.count ?? -1) snippets \(snippets.value)")
        await gws.setRunGwsForTesting(nil)
        _ = await gws.resetForWipe(timeoutSeconds: 0)
    }
}
