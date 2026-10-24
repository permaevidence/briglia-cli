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
}
