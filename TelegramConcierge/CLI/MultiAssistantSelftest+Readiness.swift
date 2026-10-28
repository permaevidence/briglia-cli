import ArgumentParser
import Foundation

/// Hidden child of `__multi-assistant-selftest` (runs inside the harness's
/// scratch roots as an assistant member): the §6.2 readiness of a REAL
/// manager and the monitor's park / resume / stuck transitions.
struct UpgradeReadinessCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__upgrade-readiness-check",
        abstract: "Internal: upgrade-barrier readiness of a real manager.",
        shouldDisplay: false
    )

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev"), let lease = MemberEntry.current else {
            print("CHECK 0 needs a development build and a member lease"); return
        }
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("CHECK \(ok ? 1 : 0) \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        }
        let m = ConversationManager()
        let idle = await m.upgradeBusyReason(initiating: false)
        check("readiness: an idle manager is ready to park", idle == nil, idle ?? "")
        // A detached Bash job keeps the assistant busy until it ends.
        let job = try? await BackgroundProcessRegistry.shared.start(command: "sleep 2", workdir: nil, description: "readiness")
        let withJob = await m.upgradeBusyReason(initiating: false)
        check("readiness: a running background command keeps the assistant busy", job != nil && withJob == "a background command", withJob ?? "nil")
        let paths = UpgradeBarrier.Paths.live
        let barrier = UpgradeBarrier.Record(id: "rd-1", state: .open, targetVersion: "9", targetSequence: 999, openedAt: Date(),
                                            coordinator: .init(lease: "x", pid: 1, processStartTime: "x"), participants: [],
                                            committedBinarySHA256: nil, reason: nil)
        try? UpgradeBarrier.writeBarrier(barrier, paths)
        // Hold upgrade.lock so the tick does not take over recovery.
        let held: ProfileFileLock? = { if case .acquired(let l) = ProfileFileLock.take(paths.lock) { return l }; return nil }()
        await m.upgradeMonitorTick(lease: lease)
        let busyAck = UpgradeBarrier.readAck(lease.uuid, paths)
        check("monitor: busy → acks busy with the reason and does not pause", busyAck?.state == .busy
              && busyAck?.reason == "a background command" && !m.admissionPaused, "\(String(describing: busyAck))")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, await BackgroundProcessRegistry.shared.runningBackgroundJobCount() > 0 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        check("readiness: ready again once the job ended", await m.upgradeBusyReason(initiating: false) == nil)
        let agentId = "rd-agent"
        let agent = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        await SubagentBackgroundRegistry.shared._testRegister(id: agentId, task: agent)
        let withAgent = await m.upgradeBusyReason(initiating: false)
        check("readiness: a background subagent keeps the assistant busy", withAgent == "a background agent", withAgent ?? "nil")
        agent.cancel()
        await SubagentBackgroundRegistry.shared._testUnregister(id: agentId)
        Prefs.store.set(true, forKey: m.shouldResumePollingDefaultsKey)
        await m.upgradeMonitorTick(lease: lease)
        let parkedAck = UpgradeBarrier.readAck(lease.uuid, paths)
        check("monitor: ready → pauses admission and acks parked", parkedAck?.state == .parked && m.admissionPaused,
              "\(String(describing: parkedAck)) paused=\(m.admissionPaused)")
        let refused = await m.sendFromApp(text: "hello", attachments: [])
        if case .refused(let why) = refused { check("pause: app/terminal input is refused while parked", why.contains("updating"), why) }
        else { check("pause: app/terminal input is refused while parked", false, "\(refused)") }
        var cancelled = barrier; cancelled.state = .cancelled
        try? UpgradeBarrier.writeBarrier(cancelled, paths)
        await m.upgradeMonitorTick(lease: lease)
        check("monitor: cancelled → admission resumes", !m.admissionPaused && m.upgradeParkedFor == nil)
        check("pause: parking never touches the polling preference (not stopPolling)",
              Prefs.store.object(forKey: m.shouldResumePollingDefaultsKey) as? Bool == true)
        var stuck = barrier; stuck.state = .stuck; stuck.id = "rd-2"
        try? UpgradeBarrier.writeBarrier(stuck, paths)
        await m.upgradeMonitorTick(lease: lease)
        check("monitor: stuck → stays paused", m.admissionPaused)
        try? FileManager.default.removeItem(at: paths.barrier)
        await m.upgradeMonitorTick(lease: lease)
        check("monitor: barrier gone → resumes", !m.admissionPaused)
        held?.release()
        // The /switchbot reservation through the REAL manager (Codex stage-1
        // notes 2 and 3): clearing the switch aborts the reservation and
        // drops the identity lock; an unconfirmed switch expires.
        if CoordinationMode.multi {
            let regPaths = AssistantRegistry.Paths.live
            func pending() -> String? { ((try? AssistantRegistry.read(regPaths)) ?? nil)?.record("default")?.bot.pending?.value }
            if let ticket = try? IdentityChange.begin(kind: .bot, rawValue: "7070:SWITCH", mode: .assistant) {
                m.pendingBotSwitch = ConversationManager.PendingBotSwitch(newToken: "7070:SWITCH", botDisplay: "@new", code: "123456")
                m.botSwitchTicket = ticket
                check("switch lifetime: the reservation is live while the switch is pending",
                      pending() == AssistantRegistry.digest(.bot, "7070:SWITCH")
                      && ProfileFileLock.probe(MachinePaths.identityTxLock) == .live)
                m.pendingBotSwitch = nil
                check("switch lifetime: cancelling the switch aborts the reservation and frees the identity lock",
                      pending() == nil && m.botSwitchTicket == nil && ProfileFileLock.probe(MachinePaths.identityTxLock) == .dead)
            } else { check("switch lifetime: reserve", false) }
            if let ticket = try? IdentityChange.begin(kind: .bot, rawValue: "7171:SWITCH", mode: .assistant) {
                var p = ConversationManager.PendingBotSwitch(newToken: "7171:SWITCH", botDisplay: "@new", code: "654321")
                p.discovered = .init(chatId: 99, senderDisplay: "New owner")
                p.discoveredAt = Date().addingTimeInterval(-(BotSwitchFlow.confirmTimeoutSeconds / 2 + 5))
                m.pendingBotSwitch = p
                m.botSwitchTicket = ticket
                await m.expireUnconfirmedBotSwitchIfDue()
                check("switch timeout: a reminder halfway, the switch still pending", m.pendingBotSwitch?.reminded == true && pending() != nil)
                await m.expireUnconfirmedBotSwitchIfDue(now: Date().addingTimeInterval(BotSwitchFlow.confirmTimeoutSeconds))
                check("switch timeout: an unconfirmed switch expires, releasing the bot and the identity lock (profiles add possible again)",
                      m.pendingBotSwitch == nil && pending() == nil && ProfileFileLock.probe(MachinePaths.identityTxLock) == .dead)
            } else { check("switch timeout: reserve", false) }
        }
        print("READINESS_DONE")
    }
}
