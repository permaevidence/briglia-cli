import Foundation

/// Multi-assistant surfaces of the running assistant: the `/status` lines
/// (MULTI_ASSISTANT_PLAN §10.3, §25.7), `/board` (§8.5), and the default's
/// coordinated `/upgrade` running as its own task so the poll loop keeps
/// answering while the other assistants are asked to pause (S2-12).
extension ConversationManager {
    // MARK: /status (§10.3, §25.7)

    /// Extra `/status` lines while several assistants exist; empty otherwise.
    func multiAssistantStatusLines() -> [String] {
        guard CoordinationMode.multi, let doc = (try? AssistantRegistry.read(.live)) ?? nil else { return [] }
        let barrier = UpgradeBarrier.current()
        return Self.multiAssistantStatusLines(
            doc: doc, me: AssistantProfile.selectedName, waitingFor: upgradeWaitingFor,
            barrier: (barrier?.isActive ?? false) ? barrier : nil, ctx: MultiAssistant.context(),
            chatgptScope: ProviderProfiles.activeProfile() == .chatgpt ? SubscriptionSharing.scopeStatus() : nil,
            running: { r in
                guard let dir = MemberLeases.directory(profile: r.name, generation: r.generation) else { return false }
                return !MemberLeases.users(dir, assistantsOnly: true).isEmpty
            })
    }

    /// Pure renderer (selftests).
    nonisolated static func multiAssistantStatusLines(doc: AssistantRegistry.Document, me: String, waitingFor: [String],
                                                      barrier: UpgradeBarrier.Record?, ctx: MultiAssistant.Context?,
                                                      chatgptScope: String?, running: (AssistantRegistry.Record) -> Bool) -> [String] {
        guard doc.records.filter({ $0.state == "active" }).count >= 2 else { return [] }
        var lines: [String] = []
        let others = doc.records.filter { $0.name != me }.map { r in
            "\(r.displayName) " + (r.state == "active" ? (running(r) ? "running" : "stopped") : r.state)
        }
        lines.append("Assistant: \(doc.record(me)?.displayName ?? me) (profile \(me)) · others: \(others.joined(separator: ", "))")
        if let barrier {
            lines.append(waitingFor.isEmpty
                         ? "Updating to \(barrier.targetVersion) (\(barrier.state.rawValue))"
                         : "Updating to \(barrier.targetVersion): waiting for \(waitingFor.joined(separator: ", ")) (/upgrade cancel stops waiting)")
        }
        if let ctx {
            let active = AssistantBoard.peers(ctx).filter(\.active).map(\.peer.displayName)
            let claimed = FileClaims.claims(ofSelf: ctx).count
            lines.append("Board: " + (active.isEmpty ? "no other assistant active in the last 30 min" : "active now: \(active.joined(separator: ", "))")
                         + (claimed > 0 ? " · you are editing \(claimed) file\(claimed == 1 ? "" : "s")" : "") + " (/board for details)")
        }
        if let chatgptScope { lines.append("ChatGPT: \(chatgptScope)") }
        let sender = doc.record(AssistantProfile.defaultName)?.displayName ?? "Bree"
        lines.append(me == AssistantProfile.defaultName
                     ? "Computer-wide update and security notices are sent by this assistant."
                     : "Computer-wide update and security notices are sent by ‘\(sender)’ (the default assistant).")
        return lines
    }

    // MARK: /board

    func handleBoardCommand() async {
        guard let ctx = MultiAssistant.context() else {
            try? await sendText("The board exists only while several assistants are set up on this computer.")
            return
        }
        // The user's view: notices stay pending for the model (not "shown").
        try? await sendText(AssistantBoard.fullBoard(ctx, markShown: false))
    }

    // MARK: Coordinated /upgrade as its own task (S2-12)

    /// `/upgrade cancel` (and `/stop`) while this assistant waits for the
    /// others: the coordinator cancels before anything is installed.
    func handleUpgradeSubcommand(_ argument: String) async -> Bool {
        let arg = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard upgradeCoordinatorTask != nil else {
            if arg == "cancel" || arg == "status" {
                try? await sendText("No update is in progress.")
                return true
            }
            return false
        }
        switch arg {
        case "cancel":
            upgradeCancelFlag.set()
            try? await sendText("Cancelling the update… nothing is installed until every assistant has paused.")
        default:
            let waiting = upgradeWaitingFor.isEmpty ? "" : " Waiting for \(upgradeWaitingFor.joined(separator: ", "))."
            try? await sendText("An update is already in progress.\(waiting) Send /upgrade cancel to stop waiting.")
        }
        return true
    }

    /// `/stop` also stops an update that is still waiting (nothing installed yet).
    func cancelWaitingUpgradeForStop() async {
        guard upgradeCoordinatorTask != nil, !upgradeCancelFlag.value else { return }
        upgradeCancelFlag.set()
        try? await sendText("The update that was waiting for the other assistants is cancelled.")
    }

    /// Settings for the coordinator task: progress to the address that asked,
    /// waiting list and cancel flag on this manager.
    func coordinatorSettings(address: ChannelAddress?) -> UpgradeCoordinator.Settings {
        var settings = UpgradeCoordinator.Settings()
        settings.progress = { [weak self] line in Task { @MainActor in try? await self?.sendText(line, to: address) } }
        settings.onWaiting = { [weak self] names in Task { @MainActor in self?.upgradeWaitingFor = names } }
        let flag = upgradeCancelFlag
        settings.cancelRequested = { flag.value }
        return settings
    }
}

/// A flag read from the coordinator's (non-main) context.
final class UpgradeCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    func set() { lock.lock(); raised = true; lock.unlock() }
    func reset() { lock.lock(); raised = false; lock.unlock() }
}
