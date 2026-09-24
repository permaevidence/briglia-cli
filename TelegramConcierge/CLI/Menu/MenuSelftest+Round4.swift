import Foundation

/// Codex round 4 on 707b516: completion side effects of work that outlives a
/// live email change. R1: an unstamped AgentMail checkpoint that survives an
/// account change stays unadopted in a FRESH process (not just the same
/// actor). R2: a late Google result clears/opens no maintenance episode,
/// bumps no failure counter and launches no further snippet subprocess.
@MainActor
extension MenuSelftestContext {

    func lateEmailEffects() async {
        await agentMailFreshProcess()
        await googleLateEffects()
    }

    // MARK: R1 — legacy AgentMail checkpoints, across a process restart

    private func agentMailFreshProcess() async {
        let checkpoint = AgentMailService.pollStateURLForTesting
        let marker = AgentMailService.legacyClosedURLForTesting
        func writeLegacy() throws {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let hourAgo = Date().addingTimeInterval(-3600)
            try PrivateStorage.writeAtomically(try encoder.encode(AgentMailService.PollState(watermark: hourAgo, drains: [:], savedAt: hourAgo, account: nil)), to: checkpoint)
        }
        func savedAccount() -> String? {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return (try? Data(contentsOf: checkpoint)).flatMap { try? decoder.decode(AgentMailService.PollState.self, from: $0) }?.account
        }
        /// A new actor = a new process's initial state (same-actor
        /// stop/start keeps in-memory flags).
        func freshProcessAdoptsOld() async -> Bool {
            let fresh = AgentMailService()
            await fresh.startBackgroundPoll()
            let adopted = await fresh.watermarkForTesting().map { $0 < Date().addingTimeInterval(-1800) } ?? false
            await fresh.stopBackgroundPoll()
            return adopted
        }
        do {
            let manager = ConversationManager()
            _ = await AgentMailService.shared.resetForWipe()
            try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "synthetic-round4-key-a")
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "agentmail")
            await manager.reloadBrowserSettings()

            // Control: the first start after the upgrade (no marker yet)
            // adopts the same account's unstamped checkpoint and stamps it —
            // legacy catch-up still works.
            await AgentMailService.shared.stopBackgroundPoll()
            try? FileManager.default.removeItem(at: marker)
            try writeLegacy()
            check("agentmail: control — the first start after the upgrade adopts the account's own pre-upgrade checkpoint",
                  await freshProcessAdoptsOld() && savedAccount() == AgentMailService.currentAccountFingerprint())
            check("agentmail: …and records that the upgrade window is closed", FileManager.default.fileExists(atPath: marker.path))
            try writeLegacy()
            check("agentmail: an unstamped checkpoint appearing later is never adopted by a new process", !(await freshProcessAdoptsOld()))

            #if os(macOS)
            // Codex's reproduction: pre-upgrade checkpoint, account change
            // while the file can't be removed/replaced, storage recovers,
            // then a new process starts on the new account.
            try? FileManager.default.removeItem(at: marker)
            try writeLegacy()
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: checkpoint.path)
            do {
                try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "synthetic-round4-key-b")
                await manager.reloadBrowserSettings()
            } catch {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: checkpoint.path)
                throw error
            }
            let stuck = savedAccount() == nil && FileManager.default.fileExists(atPath: checkpoint.path)
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: checkpoint.path)
            await AgentMailService.shared.stopBackgroundPoll()
            check("agentmail: the account change records the closed window even though the old file couldn't be removed",
                  stuck && FileManager.default.fileExists(atPath: marker.path), "stuck \(stuck)")
            let adopted = await freshProcessAdoptsOld()
            check("agentmail: after the storage failure clears, a new process never gives the new account the old position",
                  !adopted && savedAccount() == AgentMailService.currentAccountFingerprint(), "adopted \(adopted)")
            #endif

            // Every platform: an ordinary account change closes the window
            // durably too (a file that reappears unstamped is inert).
            try? FileManager.default.removeItem(at: marker)
            try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "synthetic-round4-key-c")
            await manager.reloadBrowserSettings()
            await AgentMailService.shared.stopBackgroundPoll()
            check("agentmail: an account change leaves the durable closed-window record", FileManager.default.fileExists(atPath: marker.path))
            try writeLegacy()
            check("agentmail: …so a new process ignores an unstamped checkpoint after the change", !(await freshProcessAdoptsOld()))

            try? FileManager.default.removeItem(at: checkpoint)
            try KeychainHelper.delete(key: KeychainHelper.agentMailApiKeyKey)
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "none")
            await manager.reloadBrowserSettings()
        } catch { check("agentmail: round-4 fixture ran", false, error.localizedDescription) }
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
