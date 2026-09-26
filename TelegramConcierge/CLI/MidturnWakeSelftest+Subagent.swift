import Foundation

/// Release 1b rows: foreground general/custom/Web subagent calls of the main
/// agent detach on a mid-turn wake (plan v7 §3.5), through the real manager
/// and the production tool loop. Subagent requests are answered by a
/// content router (delayed, costed replies) while the main agent's requests
/// use the scripted queue; the loopback server serves them concurrently.
extension MidturnHarness {

    /// Routed replies per subagent role, with the costs actually served.
    final class SubagentScript: @unchecked Sendable {
        private let lock = NSLock()
        private var general: [(body: String, delay: TimeInterval, cost: Double)] = []
        private var web: [(body: String, delay: TimeInterval, cost: Double)] = []
        private(set) var servedCost: Double = 0
        private(set) var generalTimes: [Date] = []
        private(set) var webTimes: [Date] = []
        var responses = false

        func general(_ reply: String, delay: TimeInterval, cost: Double) {
            lock.lock(); general.append((reply, delay, cost)); lock.unlock()
        }
        func web(_ reply: String, delay: TimeInterval, cost: Double) {
            lock.lock(); web.append((reply, delay, cost)); lock.unlock()
        }
        var served: Double { lock.lock(); defer { lock.unlock() }; return servedCost }
        var webRequestTimes: [Date] { lock.lock(); defer { lock.unlock() }; return webTimes }
        var generalRequestTimes: [Date] { lock.lock(); defer { lock.unlock() }; return generalTimes }

        func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
            let body = String(decoding: request.body, as: UTF8.self)
            let isWeb = MidturnHarness.isWebResearcherRequest(body)
            guard isWeb || MidturnHarness.isGeneralSubagentRequest(body) else { return nil }
            lock.lock(); defer { lock.unlock() }
            if isWeb { webTimes.append(Date()) } else { generalTimes.append(Date()) }
            let next: (body: String, delay: TimeInterval, cost: Double)?
            if isWeb { next = web.isEmpty ? nil : web.removeFirst() } else { next = general.isEmpty ? nil : general.removeFirst() }
            // An unscripted extra request (e.g. the Web zero-retrieval nudge)
            // gets a free final answer so every run terminates.
            let reply = next ?? (MidturnHarness.costedText("done", cost: 0, responses: responses), 0, 0)
            servedCost += reply.cost
            return (reply.body, reply.delay)
        }
    }

    nonisolated static func isWebResearcherRequest(_ body: String) -> Bool { body.contains("\"web_query\"") }
    nonisolated static func isGeneralSubagentRequest(_ body: String) -> Bool { body.contains("You are a focused general-purpose subagent") }
    nonisolated static func isSubagentRequest(_ body: String) -> Bool { isWebResearcherRequest(body) || isGeneralSubagentRequest(body) }

    func installSubagentRouter(_ script: SubagentScript) {
        server.concurrent = true
        server.router = { request in script.route(request) }
    }

    /// Main-agent requests only (subagent requests excluded).
    func mainRequestBodies() -> [String] { requestBodies().filter { !Self.isSubagentRequest($0) } }

    /// A final text reply carrying a provider-reported cost.
    nonisolated static func costedText(_ text: String, cost: Double, responses: Bool = false) -> String {
        if responses { return responsesCosted(text: text, cost: cost) }
        let body: [String: Any] = ["id": "sa", "object": "chat.completion", "model": "glm-5.3",
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 50, "completion_tokens": 5, "total_tokens": 55, "cost": cost]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    /// A tool-call reply (subagent side) carrying a cost.
    nonisolated static func costedTools(_ calls: [(id: String, name: String, args: [String: Any])], cost: Double) -> String {
        let toolCalls: [[String: Any]] = calls.map { call in
            let args = String(data: try! JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys]), encoding: .utf8)!
            return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": args]]
        }
        let body: [String: Any] = ["id": "sa", "object": "chat.completion", "model": "glm-5.3",
            "choices": [["index": 0, "message": ["role": "assistant", "content": NSNull(), "tool_calls": toolCalls],
                         "finish_reason": "tool_calls"]],
            "usage": ["prompt_tokens": 50, "completion_tokens": 5, "total_tokens": 55, "cost": cost]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    nonisolated private static func responsesCosted(text: String, cost: Double) -> String {
        let id = UUID().uuidString
        let body: [String: Any] = ["id": "resp_" + id, "status": "completed",
            "output": [["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + id,
                        "content": [["type": "output_text", "text": text, "annotations": []]]]],
            "usage": ["input_tokens": 50, "input_tokens_details": ["cached_tokens": 0],
                      "output_tokens": 5, "output_tokens_details": ["reasoning_tokens": 0], "cost": cost]]
        return String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func agentArgs(_ type: String = "general-purpose", description: String, prompt: String,
                          background: Bool = false, session: String? = nil) -> [String: Any] {
        var args: [String: Any] = ["subagent_type": type, "description": description, "prompt": prompt]
        if background { args["run_in_background"] = true }
        if let session { args["session_id"] = session }
        if type == "Web" { args["deliverable"] = "short" }
        return args
    }

    func ledgerEntries() -> [ToolChargeEntry] {
        if case .readable(_, let entries, _) = ToolChargeLedger.loadLedger() { return entries }
        return []
    }

    func openIncidents() -> [SpendIncident] {
        if case .readable(let list) = ToolChargeLedger.loadIncidents() { return list.filter { $0.state == .open } }
        return []
    }

    /// The model-spend ledger (UserDefaults, scratch preference domain).
    func modelSpendToday() -> Double { KeychainHelper.openRouterSpendSnapshot().today }
    func clearModelSpend() {
        UserDefaults.standard.removeObject(forKey: KeychainHelper.openRouterSpendLedgerDefaultsKey)
        UserDefaults.standard.removeObject(forKey: KeychainHelper.openRouterSpendLimitBoostDefaultsKey)
    }

    func waitForCompletionQueued(timeout: TimeInterval = 20) async -> Bool {
        await waitUntil(timeout: timeout) { await SubagentBackgroundRegistry.shared._testPendingCompletionsCount() > 0 }
    }

    /// A simulated crash of the process: registry state and in-memory charges
    /// die with it (runs are cancelled and record nothing more).
    func restartKillingSubagents() async -> ConversationManager {
        await SubagentBackgroundRegistry.shared._testReset()
        ToolChargeLedger.forgetHeldForTesting()
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await restart()
    }

    // MARK: - Section

    func subagentSection() async throws {
        clearModelSpend()
        try await subagentMovedDetach()
        try await subagentStatusLine()
        try await subagentShortCallReal()
        eligibilityRows()
        try await subagentIneligibleStaysForeground()
        try await subagentRecordFailureStaysForeground()
        try await subagentExplicitBackground()
        try await subagentExplicitBackgroundRecordFailure()
        try await subagentWebDetach()
        try await subagentNestedWebTravels()
        try await subagentBusySessionFailsFast()
        try await subagentForcedDetach()
    }

    /// SA1: a user message during a long foreground general subagent moves
    /// it to the background after the grace; the model reads the message now;
    /// the report is delivered later exactly once under the record's id; the
    /// run's whole spend is charged once, into the charge ledger.
    private func subagentMovedDetach() async throws {
        let manager = await freshManager()
        clearModelSpend()
        let sub = SubagentScript()
        sub.general(Self.costedText("sub report A — analysis complete", cost: 0.02), delay: 2.5, cost: 0.02)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa1", name: "Agent", args: Self.agentArgs(description: "long analysis", prompt: "Analyse the project"))]),
            Self.chatText("answered your question; the analysis continues"),
            Self.chatText("the analysis finished"),
        ])
        let t0 = Date()
        manager._testStartTurn(for: user("run a long analysis"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("quick question while it works"))
        let idle = await manager._testAwaitIdle(timeout: 30)
        let turnSeconds = Date().timeIntervalSince(t0)
        let result = results(manager).first { $0.toolCallId == "call-sa1" }
        let payload = parse(result?.content ?? "")
        check("SA1a turn ended before the subagent (early wake, not its 2.5 s run)", idle && turnSeconds < 2.2, "\(turnSeconds)s")
        check("SA1b moved result: moved_to_background, wake_reason user_message, handle, session named",
              payload["status"] as? String == "moved_to_background" && payload["wake_reason"] as? String == "user_message"
                && (payload["handle"] as? String ?? "").hasPrefix("subagent_") && payload["session_id"] is String, "\(payload)")
        check("SA1c moved note states idle-only delivery and how to stop it",
              (payload["note"] as? String ?? "").contains("once you are idle after this turn")
                && (payload["note"] as? String ?? "").contains("subagent_manage cancel"))
        let jobId = result?.outcomeBinding?.jobId
        check("SA1d result bound moved to the job, with the launch fingerprint",
              result?.outcomeBinding?.kind == .moved && jobId != nil && result?.outcomeBinding?.fingerprint != nil)
        let record = records().first { $0.jobId == jobId }
        check("SA1e crash record written before return (subagent, wakeDetached, owed, call id, anchor, provider called)",
              record?.isSubagent == true && record?.launch == .wakeDetached && record?.completion == .owed
                && record?.toolCallId == "call-sa1" && record?.historyAnchorMessageId != nil
                && record?.providerCalled == true && record?.subagentType == "general-purpose")
        let second = mainRequestBodies().dropFirst().first ?? ""
        check("SA1f next request carries the user's message and a wake note listing the moved subagent",
              second.contains("quick question while it works") && second.contains("[Harness status — not from the user.")
                && second.contains("subagent subagent_") && second.contains("moved to the background"))
        let running = await SubagentBackgroundRegistry.shared.runningHandles()
        check("SA1g the run kept going after the turn ended (listed as detached)",
              running.contains { $0.jobId == jobId && $0.detached })
        let queued = await waitForCompletionQueued()
        let recorded = ledgerEntries().filter { $0.chargeId == jobId }
        check("SA1h the run's whole spend is charged once into the ledger before its completion is queued",
              queued && recorded.count == 1 && abs((recorded.first?.amountUSD ?? 0) - 0.02) < 1e-9
                && records().first { $0.jobId == jobId }?.charge?.state == .recorded,
              "ledger \(recorded.map(\.amountUSD)), record \(String(describing: records().first { $0.jobId == jobId }?.charge))")
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 30)
        let notices = manager._testMessages.filter { $0.id == record?.completionMessageId }
        check("SA1i report delivered once under the record's completion id, and it wakes a turn",
              notices.count == 1 && notices.first?.kind == .subagentComplete
                && notices.first?.content.contains("sub report A") == true && mainRequestBodies().count == 3,
              "notices \(notices.count), main requests \(mainRequestBodies().count)")
        await manager._testSubagentDrainOnly()
        let again = manager._testMessages.filter { $0.id == record?.completionMessageId }.count
        check("SA1j a second drain adds nothing; the record retired after the durable save",
              again == 1 && !records().contains { $0.jobId == jobId })
        let spend = SpendGate.status()
        check("SA1k spend counted exactly once: model ledger untouched by the drain, snapshot total = the run's cost",
              modelSpendToday() == 0 && abs(spend.todaySpentUSD - 0.02) < 1e-9, "model \(modelSpendToday()), total \(spend.todaySpentUSD)")
    }

    /// SA1l: /status lists a detached subagent as moved to the background.
    private func subagentStatusLine() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        sub.general(Self.costedText("status row", cost: 0), delay: 2.5, cost: 0)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa1l", name: "Agent", args: Self.agentArgs(description: "status", prompt: "Status task"))]),
            Self.chatText("answered"),
            Self.chatText("done"),
        ])
        manager._testStartTurn(for: user("status subagent"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("wake"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let status = await manager._testBackgroundStatus() ?? ""
        check("SA1l /status lists the detached subagent as moved to the background",
              status.contains("subagent subagent_") && status.contains("moved to the background"), status)
        _ = await waitForCompletionQueued()
    }

    /// SA2: a subagent that finishes inside the grace returns its real result.
    private func subagentShortCallReal() async throws {
        let savedGrace = TurnWakeCenter.graceSecondsForTesting
        TurnWakeCenter.graceSecondsForTesting = 3.0
        defer { TurnWakeCenter.graceSecondsForTesting = savedGrace }
        let manager = await freshManager()
        let sub = SubagentScript()
        sub.general(Self.costedText("quick sub result", cost: 0.01), delay: 0.2, cost: 0.01)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa2", name: "Agent", args: Self.agentArgs(description: "quick", prompt: "Quick task"))]),
            Self.chatText("done"),
        ])
        manager._testStartTurn(for: user("quick subagent"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("and another thing"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let result = results(manager).first { $0.toolCallId == "call-sa2" }
        let payload = parse(result?.content ?? "")
        check("SA2 a subagent shorter than the grace returns its real result (no moved fields, no binding, no record)",
              payload["final_message"] as? String == "quick sub result" && payload["status"] == nil
                && result?.outcomeBinding == nil && records().isEmpty && result?.spendUSD == 0.01, "\(payload)")
    }

    /// SA3: eligibility. Browse (and any agent routed to the browser) never
    /// detaches in this release; general-purpose, custom and Web do.
    private func eligibilityRows() {
        check("SA3a Browse is never detachable", !ToolExecutor.subagentDetachEligible(type: SubagentTypes.browse))
        check("SA3b general-purpose and the Web researcher are detachable",
              ToolExecutor.subagentDetachEligible(type: SubagentTypes.generalPurpose)
                && ToolExecutor.subagentDetachEligible(type: SubagentTypes.webResearcher))
        let custom = SubagentType(name: "notes-writer", description: "custom", systemPromptSuffix: "x",
                                  allowedToolNames: nil, defaultMaxTurns: 10, preferredModel: .inherit)
        check("SA3c a custom agent without browser tools is detachable", ToolExecutor.subagentDetachEligible(type: custom))
        check("SA3d an unknown type is not detachable", !ToolExecutor.subagentDetachEligible("no-such-agent"))
        let browsing = SubagentType(name: "shop-bot", description: "custom", systemPromptSuffix: "x",
                                    allowedToolNames: nil, defaultMaxTurns: 10, preferredModel: .inherit,
                                    mcpToolPatterns: ["mcp__playwright__*"])
        check("SA3f a custom agent routed to the browser (Playwright tools) is not detachable",
              !ToolExecutor.subagentDetachEligible(type: browsing))
    }

    /// SA3e: an ineligible type (the Browse rule, forced here by the seam on
    /// general-purpose) stays blocking: the wake is ignored for it.
    private func subagentIneligibleStaysForeground() async throws {
        let manager = await freshManager()
        ToolExecutor.detachEligibilityOverrideForTesting = { $0 == "general-purpose" ? false : nil }
        defer { ToolExecutor.detachEligibilityOverrideForTesting = nil }
        let sub = SubagentScript()
        sub.general(Self.costedText("browse-like report", cost: 0), delay: 1.5, cost: 0)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa3", name: "Agent", args: Self.agentArgs(description: "blocking", prompt: "Blocking task"))]),
            Self.chatText("done"),
        ])
        manager._testStartTurn(for: user("blocking subagent"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("message during a blocking call"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let result = results(manager).first { $0.toolCallId == "call-sa3" }
        check("SA3e an ineligible (Browse-class) call waits for its real result despite the message; no record",
              parse(result?.content ?? "")["final_message"] as? String == "browse-like report" && records().isEmpty
                && result?.outcomeBinding == nil)
    }

    /// SA4: the crash record cannot be written → the wake is declined; the
    /// call stays foreground and returns the real result.
    private func subagentRecordFailureStaysForeground() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "create" { throw Injected() } }
        defer { DetachedJobStore.faultForTesting = nil }
        let sub = SubagentScript()
        sub.general(Self.costedText("stayed foreground", cost: 0.01), delay: 1.5, cost: 0.01)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa4", name: "Agent", args: Self.agentArgs(description: "no record", prompt: "Task"))]),
            Self.chatText("done"),
        ])
        manager._testStartTurn(for: user("record will fail"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("wake it"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let result = results(manager).first { $0.toolCallId == "call-sa4" }
        let running = await SubagentBackgroundRegistry.shared.runningHandles()
        check("SA4 record write fails → not detached: real result, no record, nothing running untracked",
              parse(result?.content ?? "")["final_message"] as? String == "stayed foreground" && records().isEmpty
                && running.isEmpty && result?.outcomeBinding == nil && result?.spendUSD == 0.01)
    }

    /// SA5: an explicit background launch gets its crash record BEFORE the
    /// handle result; its completion is delivered once and charged once.
    private func subagentExplicitBackground() async throws {
        let manager = await freshManager()
        clearModelSpend()
        let sub = SubagentScript()
        sub.general(Self.costedText("background report", cost: 0.03), delay: 0.8, cost: 0.03)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa5", name: "Agent", args: Self.agentArgs(description: "bg work", prompt: "Background task", background: true))]),
            Self.chatText("launched"),
            Self.chatText("background done"),
        ])
        manager._testStartTurn(for: user("launch in background"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let result = results(manager).first { $0.toolCallId == "call-sa5" }
        let jobId = result?.outcomeBinding?.jobId
        let record = records().first { $0.jobId == jobId }
        check("SA5a background launch: handle result bound moved; record (background, owed) written before it",
              parse(result?.content ?? "")["background"] as? Bool == true && result?.outcomeBinding?.kind == .moved
                && record?.launch == .background && record?.completion == .owed && record?.isSubagent == true)
        _ = await waitForCompletionQueued()
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 20)
        await manager._testSubagentDrainOnly()
        let notices = manager._testMessages.filter { $0.id == record?.completionMessageId }
        check("SA5b completion delivered once under the record's id; record retired",
              notices.count == 1 && notices.first?.content.contains("background report") == true
                && !records().contains { $0.jobId == jobId })
        check("SA5c charged once into the ledger, never by the drain",
              ledgerEntries().filter { $0.chargeId == jobId }.count == 1 && modelSpendToday() == 0,
              "ledger \(ledgerEntries().count), model \(modelSpendToday())")
    }

    /// SA5d: the record cannot be written → the background launch is
    /// refused honestly and nothing is started.
    private func subagentExplicitBackgroundRecordFailure() async throws {
        let manager = await freshManager()
        struct Injected: Error {}
        DetachedJobStore.faultForTesting = { if $0 == "create" { throw Injected() } }
        defer { DetachedJobStore.faultForTesting = nil }
        let sub = SubagentScript()
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa5d", name: "Agent", args: Self.agentArgs(description: "bg", prompt: "Bg", background: true))]),
            Self.chatText("reported the failure"),
        ])
        manager._testStartTurn(for: user("background with failing storage"))
        _ = await manager._testAwaitIdle(timeout: 20)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let result = results(manager).first { $0.toolCallId == "call-sa5d" }
        let running = await SubagentBackgroundRegistry.shared.runningHandles()
        check("SA5d record failure → background launch refused, not started (no run, no subagent request)",
              (result?.content ?? "").contains("could not record the background agent") && running.isEmpty
                && sub.generalRequestTimes.isEmpty && records().isEmpty)
    }

    /// SA6: the Web researcher detaches like any eligible agent; its report
    /// keeps the Web result contract.
    private func subagentWebDetach() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        sub.web(Self.costedText("web answer with sources", cost: 0.015), delay: 2.0, cost: 0.015)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa6", name: "Agent", args: Self.agentArgs("Web", description: "research", prompt: "Find it"))]),
            Self.chatText("answered while research continues"),
            Self.chatText("research arrived"),
        ])
        manager._testStartTurn(for: user("research something"))
        _ = await waitUntil(timeout: 10) { sub.webRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("meanwhile a question"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let result = results(manager).first { $0.toolCallId == "call-sa6" }
        check("SA6a Web research moves to the background on a wake (moved, bound, recorded)",
              parse(result?.content ?? "")["status"] as? String == "moved_to_background"
                && result?.outcomeBinding?.kind == .moved && records().first?.subagentType == "Web",
              "\(result?.content.prefix(200) ?? "nil")")
        let second = mainRequestBodies().dropFirst().first ?? ""
        check("SA6b the wake note labels it as Web research", second.contains("Web research subagent_"))
        _ = await waitForCompletionQueued()
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 20)
        let notice = manager._testMessages.first { $0.kind == .subagentComplete }
        check("SA6c the Web report keeps its contract lines (evidence_provenance) and is delivered once",
              notice?.content.contains("evidence_provenance:") == true
                && manager._testMessages.filter { $0.kind == .subagentComplete }.count == 1)
    }

    /// SA7: a nested Web run inside a detached general subagent travels with
    /// its parent: it keeps running after the detach, its result reaches the
    /// parent, and the parent's single charge includes the nested spend.
    private func subagentNestedWebTravels() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        sub.general(Self.costedTools([(id: "n1", name: "Agent", args: ["subagent_type": "Web", "description": "nested research",
                                                                        "prompt": "Look it up", "deliverable": "short"])], cost: 0.01),
                    delay: 0.1, cost: 0.01)
        sub.general(Self.costedText("general final after nested web", cost: 0.01), delay: 0.1, cost: 0.01)
        sub.web(Self.costedText("nested web finding", cost: 0.03), delay: 2.0, cost: 0.03)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa7", name: "Agent", args: Self.agentArgs(description: "with nested web", prompt: "Research via Web"))]),
            Self.chatText("answered; the agent continues"),
            Self.chatText("its report arrived"),
        ])
        manager._testStartTurn(for: user("delegate with nested research"))
        _ = await waitUntil(timeout: 10) { sub.webRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("question during nested research"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let detachedAt = Date()
        let result = results(manager).first { $0.toolCallId == "call-sa7" }
        let jobId = result?.outcomeBinding?.jobId
        check("SA7a the parent detaches while its nested Web run is still going",
              parse(result?.content ?? "")["status"] as? String == "moved_to_background")
        _ = await waitForCompletionQueued()
        let generalAfter = sub.generalRequestTimes.filter { $0 > detachedAt }
        check("SA7b the nested Web run finished after the detach and the parent continued with its result",
              !generalAfter.isEmpty, "general requests after detach: \(generalAfter.count)")
        await manager._testSubagentDrainOnly()
        _ = await manager._testAwaitIdle(timeout: 20)
        let notice = manager._testMessages.first { $0.kind == .subagentComplete }
        let charged = ledgerEntries().first { $0.chargeId == jobId }?.amountUSD ?? -1
        check("SA7c one report with the parent's final message; one charge = parent + nested spend",
              notice?.content.contains("general final after nested web") == true
                && abs(charged - sub.served) < 1e-9 && sub.served >= 0.05,
              "charged \(charged), served \(sub.served)")
        let (webSessions, _) = await SubagentSessionRegistry.shared.list(limit: 20, offset: 0, kind: .web)
        check("SA7d the nested Web session lives in the Web pool, created via its parent's session",
              webSessions.contains { $0.description.hasPrefix("via ") })
    }

    /// SA8: a session still worked on by a detached run cannot be resumed
    /// until its report arrives (fail fast, never mutate it under the run).
    private func subagentBusySessionFailsFast() async throws {
        let manager = await freshManager()
        let sub = SubagentScript()
        sub.general(Self.costedText("long report", cost: 0), delay: 3.0, cost: 0)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa8", name: "Agent", args: Self.agentArgs(description: "long", prompt: "Long task"))]),
            Self.chatText("answered"),
        ])
        manager._testStartTurn(for: user("long subagent"))
        _ = await waitUntil(timeout: 10) { sub.generalRequestTimes.count >= 1 }
        await manager._testDispatchUser(user("wake"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let moved = parse(results(manager).first { $0.toolCallId == "call-sa8" }?.content ?? "")
        guard let session = moved["session_id"] as? String else { check("SA8 moved result names the session", false, "\(moved)"); return }
        let holder = await SubagentBackgroundRegistry.shared.detachedRunHolding(sessionId: session)
        server.script([
            Self.chatTools([(id: "call-sa8r", name: "Agent", args: Self.agentArgs(description: "resume", prompt: "Continue", session: session))]),
            Self.chatText("ok"),
        ])
        manager._testStartTurn(for: user("resume it now"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let resumed = results(manager).first { $0.toolCallId == "call-sa8r" }?.content ?? ""
        check("SA8 resuming a session held by a detached run fails fast with 'session busy' (no new run)",
              holder != nil && resumed.contains("session busy") && sub.generalRequestTimes.count == 1, resumed)
        _ = await waitForCompletionQueued()
    }

    /// SA9: the hidden force-detach setting applies to eligible subagents
    /// (no user message, no queue entry, no suppression), never to an
    /// ineligible type.
    private func subagentForcedDetach() async throws {
        let manager = await freshManager()
        ForceDetach.overrideForTesting = true
        defer { ForceDetach.overrideForTesting = nil }
        let sub = SubagentScript()
        sub.general(Self.costedText("forced report", cost: 0), delay: 2.0, cost: 0)
        installSubagentRouter(sub)
        server.script([
            Self.chatTools([(id: "call-sa9", name: "Agent", args: Self.agentArgs(description: "forced", prompt: "Task"))]),
            Self.chatText("continued after the forced detach"),
            Self.chatText("report handled"),
        ])
        manager._testStartTurn(for: user("forced detach"))
        _ = await manager._testAwaitIdle(timeout: 20)
        let result = results(manager).first { $0.toolCallId == "call-sa9" }
        let payload = parse(result?.content ?? "")
        check("SA9a forced: moved with wake_reason test_forced, record launch forcedDetach, no user message queued",
              payload["wake_reason"] as? String == "test_forced" && records().first?.launch == .forcedDetach
                && (payload["note"] as? String ?? "").contains("test mode"), "\(payload)")
        _ = await waitForCompletionQueued()
        // Ineligible type under the same setting: never detached.
        let manager2 = await freshManager()
        ForceDetach.overrideForTesting = true
        ToolExecutor.detachEligibilityOverrideForTesting = { $0 == "general-purpose" ? false : nil }
        defer { ToolExecutor.detachEligibilityOverrideForTesting = nil }
        let sub2 = SubagentScript()
        sub2.general(Self.costedText("blocking under force", cost: 0), delay: 1.5, cost: 0)
        installSubagentRouter(sub2)
        server.script([
            Self.chatTools([(id: "call-sa9b", name: "Agent", args: Self.agentArgs(description: "ineligible", prompt: "Task"))]),
            Self.chatText("done"),
        ])
        manager2._testStartTurn(for: user("forced but ineligible"))
        _ = await manager2._testAwaitIdle(timeout: 20)
        let blocking = results(manager2).first { $0.toolCallId == "call-sa9b" }
        check("SA9b forced setting never detaches an ineligible (Browse-class) call",
              parse(blocking?.content ?? "")["final_message"] as? String == "blocking under force" && records().isEmpty)
    }
}
