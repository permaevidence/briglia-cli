import Foundation
import ArgumentParser
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// UserDefaults reads AND writes are redirected here only in disposable builds.
enum P2Life {
    static let defaults = UserDefaults(suiteName: "dev.briglia.p2.lifecycle")!
    static var refreshCalls = 0
    static var failRefresh = false
    static func authPost(_ path: String, _ fields: [String: String], _ form: Bool) async throws -> SubscriptionAuthHTTP.Reply {
        if liveMode { return try await SubscriptionAuthHTTP().post(path: path, fields: fields, form: form) }
        guard path == "/oauth/token", fields["grant_type"] == "refresh_token" else { throw Failure("unexpected fixture auth request") }
        refreshCalls += 1
        if failRefresh { throw SubscriptionError("synthetic transport failure") }
        return (try SubscriptionSelftest.tokenData(), 200)
    }
    static var subscriptionCaptureURL: URL?
    static func route(_ request: URLRequest) -> URLRequest {
        guard !liveMode, let target = subscriptionCaptureURL,
              request.url?.absoluteString == SubscriptionEndpoint.inference else { return request }
        var routed = request; routed.url = target
        return routed
    }
    static var liveMode = false
    static var failFinalSave = false
    static var finalFaults = 0
    static var captureDelivery = false
    static var deliveries: [String] = []
    static var contexts: [ProviderExecutionContext] = []
    static func recordContext(_ context: ProviderExecutionContext) {
        budgetLock.lock(); defer { budgetLock.unlock() }
        contexts.append(context)
    }
    static func beforeConversationSave(_ url: URL, messages: [Message]) {
        guard failFinalSave, messages.last?.responsesReplay != nil else { return }
        failFinalSave = false
        do {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("before-final"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("block final replacement".utf8).write(to: url.appendingPathComponent("sentinel"))
            finalFaults += 1
        } catch { preconditionFailure("could not inject final-save fault") }
    }
    static var failSalvageAt: Int?
    static var salvageWrites = 0
    static func beforeSalvage(_ url: URL) throws {
        salvageWrites += 1
        if salvageWrites == failSalvageAt {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("block replacement".utf8).write(to: url.appendingPathComponent("sentinel"))
        }
    }
    private static let budgetLock = NSLock()
    private static var requests = 0
    static func claimLiveRequest() throws {
        budgetLock.lock(); defer { budgetLock.unlock() }
        if liveMode {
            requests += 1
            guard requests <= 8 else { throw Failure("live eight-request cap reached") }
        }
    }
    struct Failure: Error { let description: String; init(_ s: String) { description = s } }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label) }
        print("PASS " + label)
    }
    static func body(_ text: String, tool: String? = nil, path: String = "", id: String = UUID().uuidString,
                     status: String = "completed", toolArgs: [String: Any]? = nil) throws -> String {
        var output: [[String: Any]] = [
            ["type": "reasoning", "id": "rs_" + id, "summary": [], "encrypted_content": "opaque_" + id],
            ["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + id,
             "content": [["type": "output_text", "text": text, "annotations": []]]]
        ]
        if let tool {
            let arguments = String(data: try JSONSerialization.data(withJSONObject: toolArgs ?? ["path": path]), encoding: .utf8)!
            output.append(["type": "function_call", "id": "fc_" + id, "call_id": "call_" + id,
                           "status": "completed", "name": tool, "arguments": arguments])
        }
        let snapshot: [String: Any] = ["id": "resp_" + id, "status": status, "output": output,
            "usage": ["input_tokens": 100, "input_tokens_details": ["cached_tokens": 80], "output_tokens": 30, "output_tokens_details": ["reasoning_tokens": 20]]]
        func json(_ value: [String: Any]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), encoding: .utf8)!
        }
        guard subscriptionCaptureURL != nil else { return try json(snapshot) }
        // Model the observed subscription stream, including complete item events
        // and an empty terminal output. Ordinary API fixtures remain JSON.
        var events: [[String: Any]] = output.enumerated().map { index, item in
            ["type": "response.output_item.done", "output_index": index, "item": item]
        }
        var terminal = snapshot; terminal["output"] = []
        events.append(["type": "response.completed", "response": terminal])
        return try events.map { "data: " + (try json($0)) + "\n\n" }.joined()
    }
    static func input(_ request: CapturedHTTPRequest) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
        return root["input"] as! [[String: Any]]
    }
}

struct ResponsesLifecycleSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__responses-lifecycle-selftest", shouldDisplay: false)
    @Option var output: String
    @Flag var live = false
    @Flag var resumeLive = false
    @Flag var subscription = false
    @MainActor func run() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: output)
        if !resumeLive && !subscription { try fm.createDirectory(at: root, withIntermediateDirectories: false) }
        for (key, child) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(child).path, 1)
        }
        P2Life.defaults.removePersistentDomain(forName: "dev.briglia.p2.lifecycle")
        defer { P2Life.defaults.removePersistentDomain(forName: "dev.briglia.p2.lifecycle") }
        SetupAPICore.defaults = P2Life.defaults
        FileDescriptionsStore._testStoreURL = root.appendingPathComponent("descriptions.json")
        let server = try CaptureServer(); defer { server.stop() }
        var key = "synthetic-p2-key", model = "fixture-model", base = "http://127.0.0.1:\(server.port)/v1"
        P2Life.liveMode = live
        if live && !subscription {
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            let input = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
            guard let liveKey = input["api_key"], !liveKey.isEmpty else { throw P2Life.Failure("live key missing") }
            key = liveKey; model = "gpt-5.6-luna"; base = "https://api.openai.com/v1"
        }
        if subscription {
            guard live else { throw P2Life.Failure("subscription flag requires explicit live mode") }
            try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: "gpt-5.6-luna", effort: "low", textOnly: false)
            try ProviderProfiles.activate(.chatgpt)
        } else {
            try ProviderProfiles.saveProfile(.custom, apiKey: key, baseURL: base, model: model,
                effort: live ? "low" : nil, textOnly: false, wireProtocol: .responses)
            try ProviderProfiles.activate(.custom)
        }
        let settings = [KeychainHelper.maxContextTokensKey: "10000", KeychainHelper.targetContextTokensKey: "5000",
            KeychainHelper.archiveChunkSizeKey: "1000000", KeychainHelper.assistantNameKey: "Fixture Assistant",
            KeychainHelper.userNameKey: "Fixture User", KeychainHelper.emailCalendarProviderKey: "none"]
        try KeychainHelper.saveBatch(settings.mapValues { Optional($0) })
        let file = root.appendingPathComponent("read.txt")
        try Data("P2_TOOL_READ_OK".utf8).write(to: file)
        let manager = ConversationManager()
        if resumeLive {
            _ = try manager.p2Reload()
            let next = try await manager.p2Turn(human: Message(role: .user, content: "Without tools, repeat only the exact marker you read in the text file."))
            try P2Life.require(await manager.p2Error() == nil && next.last?.content.contains("P2_TOOL_READ_OK") == true, "live new-process continuation succeeds")
            return
        }
        try await manager.p2Seed([])
        if live {
            try await runLive(manager, root: root, textFile: file)
        } else {
            try await runMain(manager, server: server, root: root, file: file)
            try await runSubagents(server: server, root: root, file: file)
            try await runFinalSave(manager, server: server, file: file)
            try await runAuxiliary(server: server, root: root)
            try await runSwitching(manager, server: server, file: file)
            await manager.p2ReadOnlyCommands()
            try await runSubscription(manager, server: server, root: root, file: file)
            try await runSubscriptionRecovery(manager, server: server)
        }
        print("Responses lifecycle PASS")
    }

    @MainActor private func runSubscription(_ manager: ConversationManager, server: CaptureServer, root: URL, file: URL) async throws {
        let store = SubscriptionAuthStore()
        let pending = try await store.beginLogin()
        let generation = try await store.commitLogin(SubscriptionSelftest.credential(), pending: pending)
        try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil, model: "gpt-5.6-luna", effort: "high", textOnly: false)
        try ProviderProfiles.activate(.chatgpt)
        try P2Life.require(KeychainHelper.load(key: KeychainHelper.openAICompatibleApiKeyKey) == generation, "runtime slot contains generation, not OAuth token")
        P2Life.subscriptionCaptureURL = URL(string: "http://127.0.0.1:\(server.port)/v1/responses")!
        defer { P2Life.subscriptionCaptureURL = nil; server.contentTypeOverride = nil }
        server.contentTypeOverride = "text/event-stream\r\nx-codex-turn-state: fixture-turn-state"
        server.clear()
        server.script([try P2Life.body("Read subscription fixture", tool: "read_file", path: file.path), try P2Life.body("SUBSCRIPTION_OK")])
        let saved = try await manager.p2Turn(human: Message(role: .user, content: "Read the fixture through the subscription provider"))
        try P2Life.require(await manager.p2Error() == nil && saved.last?.content == "SUBSCRIPTION_OK", "subscription real manager tool continuation completes")
        try P2Life.require(saved.last?.toolInteractions.last?.results.first?.content.contains("P2_TOOL_READ_OK") == true, "subscription invokes the real local tool")
        for request in server.completeRequests {
            let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            try P2Life.require(request.headers["authorization"] == "Bearer synthetic-access" && request.headers["chatgpt-account-id"] == "account-A", "subscription dispatch attaches the captured account credentials")
            try P2Life.require(body["instructions"] != nil && body["truncation"] == nil && body["max_output_tokens"] == nil, "subscription manager uses endpoint field projection")
        }
        let identifiers = server.completeRequests.compactMap { $0.headers["session_id"] }
        try P2Life.require(identifiers.count == 2 && Set(identifiers).count == 1, "subscription tool rounds share stable main affinity")
        try P2Life.require(server.completeRequests[0].headers[ResponsesTurn.header] == nil && server.completeRequests[1].headers[ResponsesTurn.header] == "fixture-turn-state", "main tool continuation echoes first routing state")
        let usage = try ResponsesUsageStore().read()!.records.filter { $0.provider == .subscription }.suffix(2)
        try P2Life.require(usage.count == 2 && Set(usage.map { $0.operationID }).count == 1 && usage.allSatisfy { $0.counts.cachedInput == 80 && $0.counts.reasoningOutput == 20 && $0.outcome == .completed }, "real main requests persist server counters under one operation")
        _ = try manager.p2Reload()
        server.clear(); server.script([try P2Life.body("RESTART_OK")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Continue after reload"))
        let restartInput = (try JSONSerialization.jsonObject(with: server.completeRequests.last!.body) as! [String: Any])["input"] as! [[String: Any]]
        try P2Life.require(restartInput.contains { $0["encrypted_content"] != nil }, "subscription reload restores compatible encrypted items")
        try P2Life.require(server.completeRequests.last?.headers[ResponsesTurn.header] == nil, "new main turn does not reuse prior routing state")
        try await runSubagents(server: server, root: root, file: file)
        try P2Life.require(server.completeRequests.count == 3 && server.completeRequests[0].headers[ResponsesTurn.header] == nil && server.completeRequests[1].headers[ResponsesTurn.header] == "fixture-turn-state" && server.completeRequests[2].headers[ResponsesTurn.header] == nil, "subagent tools share state but resume starts fresh")
        try P2Life.require(server.completeRequests.allSatisfy { $0.headers["chatgpt-account-id"] == "account-A" }, "new and resumed subagents retain subscription account")
        let workerIDs = server.completeRequests.compactMap { $0.headers["session_id"] }
        try P2Life.require(workerIDs.count == 3 && Set(workerIDs).count == 1 && workerIDs.first != identifiers.first, "subscription subagent session affinity is stable and separate from main")
        server.clear(); P2Life.contexts = []
        let summary = String(repeating: "Useful archived fixture facts. ", count: 120)
        server.script([try P2Life.body(summary), try P2Life.body(summary), try P2Life.body("You prefer concise replies."),
                       try P2Life.body("Structured subscription context"), try P2Life.body("fixture.png: Description retained.")])
        let archive = ConversationArchiveService(); await archive.configure(apiKey: "unused")
        try P2Life.require(try await archive.p2Summary() == summary.trimmingCharacters(in: .whitespacesAndNewlines), "subscription archive summary")
        try P2Life.require(try await archive.p2Meta() == summary.trimmingCharacters(in: .whitespacesAndNewlines), "subscription historical meta summary")
        try P2Life.require(await archive.p2Restructure(), "subscription context restructuring")
        _ = try await UserContextStructurer.structure(assistantName: "Fixture", userName: "User", rawContext: "Concise", existingContext: "", config: .fromKeychain())
        let service = OpenRouterService(); await service.configure(apiKey: "unused")
        let descriptions = try await service.generateFileDescriptions(files: [("fixture.png", Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NsQ0AAAzCMP5/un0CNkuZ41wybXsHAAAAAAAAAAAAxR4yw/wuPL6QkAAAAABJRU5ErkJggg==")!, "image/png")],
            conversationContext: [Message(role: .assistant, content: "I read the earlier attachment.")])
        try P2Life.require(descriptions["fixture.png"] == "Description retained.", "subscription file descriptions retain assistant context")
        try P2Life.require(server.completeRequests.count == 5 && server.completeRequests.allSatisfy { $0.headers["chatgpt-account-id"] == "account-A" }, "all inherited auxiliary owners use subscription credentials")
        try P2Life.require(P2Life.contexts.prefix(3).allSatisfy { $0.lane == .archive }, "subscription archive lane retained")
        let scopes = P2Life.contexts.suffix(2).map { $0.lane.laneId }
        try P2Life.require(Set(scopes).count == 2 && scopes.allSatisfy { $0.hasPrefix("ephemeral:") }, "subscription auxiliary operation lanes distinct")
        try P2Life.require(server.completeRequests.allSatisfy { $0.headers[ResponsesTurn.header] == nil }, "auxiliary operations never borrow another operation routing state")
        let auxUsage = try ResponsesUsageStore().read()!.records.suffix(5)
        try P2Life.require(Set(auxUsage.map { $0.operationID }).count == 5 && auxUsage.suffix(2).map { $0.operation } == [.userContext, .fileDescription], "auxiliary receipts label owners and distinct operations")
        try await store.logout()
        server.clear()
        _ = try await manager.p2Turn(human: Message(role: .user, content: "This cannot dispatch after logout"))
        try P2Life.require(await manager.p2Error() != nil && server.completeRequests.isEmpty, "logout fails closed before another manager request")
    }

    @MainActor private func runSubscriptionRecovery(_ manager: ConversationManager, server: CaptureServer) async throws {
        let store = SubscriptionAuthStore()
        P2Life.subscriptionCaptureURL = URL(string: "http://127.0.0.1:\(server.port)/responses")!
        defer { P2Life.subscriptionCaptureURL = nil; P2Life.failRefresh = false }
        for mode in ["success", "double401", "transport", "retry-budget"] {
            let pending = try await store.beginLogin()
            let generation = try await store.commitLogin(SubscriptionSelftest.credential(), pending: pending)
            var context = ProviderExecutionContext.responsesAPI(baseURL: SubscriptionEndpoint.inference, key: generation,
                model: "gpt-5.6-luna", lane: .main, effort: "high")
            context.subscriptionGeneration = generation; context.profileIdentity = "chatgpt"; context.nativeToolMedia = false
            context.responsesTurn.receive("before-refresh", scope: context.responsesScope)
            P2Life.refreshCalls = 0; P2Life.failRefresh = mode == "transport"
            server.clear()
            if mode == "double401" { server.script(["{}", "{}"], statuses: [401, 401]) }
            else if mode == "retry-budget" { server.script(["{}", "{}", "{}", "{}", try P2Life.body("RECOVERED")], statuses: [401, 500, 500, 500, 200]) }
            else { server.script(["{}", try P2Life.body("RECOVERED")], statuses: [401, 200]) }
            let receipt = PreparedRequestReceipt(requestID: UUID(), historyFingerprint: "fixture", deliveryNonces: [])
            var succeeded = false
            do {
                _ = try await ResponsesAdapter(context: context).send(input: [ResponsesAdapter.message(role: "user", text: "Test")], tools: nil, receipt: receipt)
                succeeded = true
            } catch {}
            try P2Life.require(succeeded == (mode == "success" || mode == "retry-budget"), "401 owner outcome \(mode)")
            try P2Life.require(P2Life.refreshCalls == 1, "exactly one refresh \(mode)")
            let requests = server.completeRequests
            try P2Life.require(requests.count == (mode == "transport" ? 1 : mode == "retry-budget" ? 5 : 2), "bounded request count \(mode)")
            try P2Life.require(requests.allSatisfy { $0.headers[ResponsesTurn.header] == "before-refresh" }, "401 and server retries keep same-turn routing state " + mode)
            let attempts = try ResponsesUsageStore().read()!.records.filter { $0.requestID == receipt.requestID }
            try P2Life.require(attempts.count == requests.count && attempts.map { $0.attempt } == Array(1...requests.count) && attempts.first?.httpStatus == 401, "ledger records every HTTP attempt " + mode)
            if requests.count > 1 {
                try P2Life.require(requests[0].body == requests[1].body, "retry body byte-identical \(mode)")
                try P2Life.require(requests[0].headers["authorization"] != requests[1].headers["authorization"], "refreshed bearer used \(mode)")
            }
            try P2Life.require((try store.read()?.requiresLogin == true) == (mode == "double401"), "login-required persistence \(mode)")
            if mode == "double401" {
                var refused = false
                do { _ = try await store.credential(generation: generation) { _ in throw P2Life.Failure("must not refresh") } }
                catch { refused = true }
                try P2Life.require(refused && P2Life.refreshCalls == 1, "next credential refuses without refresh")
            }
        }
        P2Life.failRefresh = false
        let holding = try HoldingChatSelftestServer()
        defer { _ = holding.stopAndJoin() }
        P2Life.subscriptionCaptureURL = holding.url
        let generation = try store.read()!.generation
        var cancelledContext = ProviderExecutionContext.responsesAPI(baseURL: SubscriptionEndpoint.inference,
            key: generation, model: "gpt-5.6-luna", lane: .main, effort: "high")
        cancelledContext.subscriptionGeneration = generation; cancelledContext.profileIdentity = "chatgpt"
        cancelledContext.responsesTurn.receive("cancel-state", scope: cancelledContext.responsesScope)
        let cancelledReceipt = PreparedRequestReceipt(requestID: UUID(), historyFingerprint: "cancel-fixture", deliveryNonces: [])
        let cancelledTask = Task { try await ResponsesAdapter(context: cancelledContext).send(
            input: [ResponsesAdapter.message(role: "user", text: "Cancel this request")], tools: nil, receipt: cancelledReceipt) }
        let deadline = Date().addingTimeInterval(5)
        while holding.requestCount == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        cancelledTask.cancel()
        _ = try? await cancelledTask.value
        try P2Life.require(holding.requestCount == 1 && cancelledContext.responsesTurn.value(for: cancelledContext.responsesScope) == nil,
            "cancellation closes the real adapter routing owner")
        let cancelledRows = try ResponsesUsageStore().read()!.records.filter { $0.requestID == cancelledReceipt.requestID }
        try P2Life.require(cancelledRows.count == 1 && cancelledRows[0].outcome == .cancelled && cancelledRows[0].counts.input == nil,
            "cancelled request records unknown usage without inventing a cache miss")
        try await manager.p3PendingLoginBarrier()
    }

    @MainActor private func runMain(_ manager: ConversationManager, server: CaptureServer, root: URL, file: URL) async throws {
        server.script([try P2Life.body("Reading", tool: "read_file", path: file.path), try P2Life.body("Completed")])
        let queued = Message(role: .user, content: "Also confirm the queued instruction.")
        let saved = try await manager.p2Turn(human: Message(role: .user, content: "Read the fixture"), queued: queued)
        try P2Life.require(await manager.p2Error() == nil, "main loop completes")
        try P2Life.require(saved.last?.responsesReplay != nil && saved.last?.toolInteractions.count == 1, "main final and tool replay saved")
        try P2Life.require(saved.last?.toolInteractions.first?.results.first?.content.contains("P2_TOOL_READ_OK") == true, "real tool executed")
        try P2Life.require(await manager.p2Queue().isEmpty, "carried midturn batch acknowledged")
        try P2Life.require(saved.filter { $0.id == queued.id }.count == 1, "one canonical midturn user")
        let reloaded = try manager.p2Reload()
        try P2Life.require(reloaded.last?.responsesReplay?.fingerprint == saved.last?.responsesReplay?.fingerprint, "main restart replay restored")
        server.script([try P2Life.body("After restart")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Continue after restart"))
        let replay = try P2Life.input(server.completeRequests.last!)
        try P2Life.require(replay.filter { $0["type"] as? String == "function_call_output" }.count == 1, "restart replays one result")
        try P2Life.require(replay.contains { $0["encrypted_content"] != nil }, "restart carries matching ciphertext")
        let old = saved.last!
        let protected = Message(role: .assistant, content: "Protected recent work", toolInteractions: old.toolInteractions)
        server.script([try P2Life.body("Useful details retained by summary")])
        let pruned = try await manager.p2Prune([Message(role: .user, content: "Earlier work"), old,
            Message(role: .user, content: "Recent work"), protected])
        try P2Life.require(pruned.first { $0.id == old.id }?.responsesReplay == nil
            && pruned.first { $0.id == old.id }?.toolInteractions.isEmpty == true, "manual pruning removes evicted native replay")
        try P2Life.require(pruned.first { $0.id == protected.id }?.toolInteractions.isEmpty == false, "manual pruning preserves newest tool turn")
        let summaryBody = try JSONSerialization.jsonObject(with: server.completeRequests.last!.body) as! [String: Any]
        try P2Life.require((summaryBody["tools"] as? [Any])?.isEmpty == true, "Responses prune summary mechanically disables tools")
        let snapshotReference = pruned.first { $0.id == old.id }?.pruneArchiveReferences.first
        try P2Life.require(snapshotReference != nil, "Responses prune persists typed snapshot reference")
        _ = try manager.p2Reload()
        server.script([try P2Life.body("After pruning")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Continue using the concise context"))
        let linkedRequest = String(decoding: server.completeRequests.last!.body, as: UTF8.self)
        try P2Life.require(linkedRequest.contains(snapshotReference!.basename), "Responses real manager sends snapshot link after restart")
        // Failed terminal result must preserve queued delivery and completed work.
        try await manager.p2Seed([])
        server.script([try P2Life.body("Reading", tool: "read_file", path: file.path), try P2Life.body("partial", status: "failed")])
        let retryUser = Message(role: .user, content: "Queued during failure")
        let failed = try await manager.p2Turn(human: Message(role: .user, content: "Read again"), queued: retryUser)
        try P2Life.require(await manager.p2Error() != nil, "failed terminal surfaces error")
        try P2Life.require(await manager.p2Queue().map(\.id) == [retryUser.id], "failed terminal requeues exactly once")
        try P2Life.require(failed.last?.toolInteractions.first?.results.first?.content.contains("P2_TOOL_READ_OK") == true, "failure retains completed tool work")
        try P2Life.require(server.remainingResponses == 0 && server.errors.isEmpty, "main capture script exhausted without errors")
        try await manager.p2Seed([])
        for failingWrite in [1, 2] {
            let target = root.appendingPathComponent("side-effect-\(failingWrite).txt")
            P2Life.salvageWrites = 0; P2Life.failSalvageAt = failingWrite
            server.clear()
            server.script([try P2Life.body("Writing", tool: "write_file", toolArgs: ["path": target.path, "content": "persisted intent first"])])
            _ = try await manager.p2Turn(human: Message(role: .user, content: "Write the disposable fixture"))
            P2Life.failSalvageAt = nil
            try P2Life.require(await manager.p2Error() != nil, "salvage write \(failingWrite) failure surfaces")
            try P2Life.require(FileManager.default.fileExists(atPath: target.path) == (failingWrite == 2),
                failingWrite == 1 ? "failed intent prevents side effect" : "failed result save preserves already executed side effect")
            try P2Life.require(server.completeRequests.count == 1, "save failure prevents continuation and automatic rerun")
            let salvage = StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json")
            if FileManager.default.fileExists(atPath: salvage.path) { try FileManager.default.removeItem(at: salvage) }
            try await manager.p2Seed([])
        }
    }

    @MainActor private func runFinalSave(_ manager: ConversationManager, server: CaptureServer, file: URL) async throws {
        try await manager.p2Seed([])
        server.clear()
        server.script([try P2Life.body("Read before final failure", tool: "read_file", path: file.path), try P2Life.body("FINAL_ANSWER_DELIVERED")])
        P2Life.failFinalSave = true; P2Life.captureDelivery = true; P2Life.deliveries = []
        var human = Message(role: .user, content: "Read the fixture, then answer")
        human.originChannel = ChannelAddress(kind: .app, chatId: "fixture")
        let history = try await manager.p2Turn(human: human)
        P2Life.captureDelivery = false
        try P2Life.require(P2Life.finalFaults == 1, "final save hits real filesystem write failure")
        try P2Life.require(await manager.p2Error() == nil && history.last?.content == "FINAL_ANSWER_DELIVERED", "failed final save keeps completed answer without error append")
        try P2Life.require(P2Life.deliveries.filter { $0 == "FINAL_ANSWER_DELIVERED" }.count == 1, "failed final save delivers answer exactly once")
        let ids = history.flatMap(\.toolInteractions).flatMap { $0.assistantMessage.toolCalls.map(\.id) }
        try P2Life.require(ids.count == 1 && Set(ids).count == ids.count, "failed final save never duplicates call ids")
        let salvage = StoragePaths.dataRoot.appendingPathComponent("turn_salvage.json")
        try P2Life.require(FileManager.default.fileExists(atPath: salvage.path), "failed final save retains salvage")
        let disk = StoragePaths.dataRoot.appendingPathComponent("conversation.json")
        try FileManager.default.removeItem(at: disk)
        try FileManager.default.moveItem(at: disk.appendingPathExtension("before-final"), to: disk)
        _ = try manager.p2Reload(); manager.p2Recover()
        let recovered = try manager.p2Reload()
        try P2Life.require(recovered.flatMap(\.toolInteractions).count == 1 && !FileManager.default.fileExists(atPath: salvage.path), "restart recovers completed rounds once after final-save failure")
        for corrupt in [Data("not json".utf8), Data("[]".utf8)] {
            try corrupt.write(to: salvage); manager.p2Recover()
            try P2Life.require(!FileManager.default.fileExists(atPath: salvage.path), "invalid or empty salvage removed on startup")
        }
    }

    @MainActor private func runAuxiliary(server: CaptureServer, root: URL) async throws {
        server.clear(); P2Life.contexts = []
        let archive = ConversationArchiveService()
        await archive.configure(apiKey: "synthetic-unused-key")
        let summary = String(repeating: "Detailed fixture facts retained for the future. ", count: 100)
        server.script([try P2Life.body(summary), try P2Life.body(summary), try P2Life.body("You prefer concise replies and durable local memory.")])
        try P2Life.require(try await archive.p2Summary() == summary.trimmingCharacters(in: .whitespacesAndNewlines), "Responses archive summary decoded")
        try P2Life.require(try await archive.p2Meta() == summary.trimmingCharacters(in: .whitespacesAndNewlines), "Responses archive meta-summary decoded")
        try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: "You prefer concise replies.")
        try P2Life.require(await archive.p2Restructure(), "Responses archive restructure saved")
        try P2Life.require(KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) == "You prefer concise replies and durable local memory.", "restructured facts persist")
        server.script([try P2Life.body("Structured user fixture"), try P2Life.body("Structured second fixture"), try P2Life.body("fixture.png: A small red square.")])
        for index in 0..<2 {
            let structured = try await UserContextStructurer.structure(assistantName: "Fixture", userName: "User",
                rawContext: "Keep concise replies", existingContext: "", config: .fromKeychain())
            try P2Life.require(structured == (index == 0 ? "Structured user fixture" : "Structured second fixture"), "Responses standalone structurer decodes operation \(index)")
        }
        let service = OpenRouterService(); await service.configure(apiKey: "synthetic-unused-key")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NsQ0AAAzCMP5/un0CNkuZ41wybXsHAAAAAAAAAAAAxR4yw/wuPL6QkAAAAABJRU5ErkJggg==")!
        let descriptions = try await service.generateFileDescriptions(files: [("fixture.png", png, "image/png")],
            conversationContext: [Message(role: .user, content: "Describe the image later."),
                                  Message(role: .assistant, content: "I will retain its description.")])
        try P2Life.require(descriptions["fixture.png"] == "A small red square.", "Responses file description decoded")
        let descriptionBody = try JSONSerialization.jsonObject(with: server.completeRequests.last!.body) as! [String: Any]
        let descriptionInput = descriptionBody["input"] as! [[String: Any]]
        try P2Life.require(descriptionInput.map { $0["role"] as! String } == ["system", "user", "assistant", "user"], "description request retains prior user and assistant context")
        for message in descriptionInput {
            let expected = message["role"] as? String == "assistant" ? "output_text" : "input_text"
            let parts = message["content"] as! [[String: Any]]
            let textParts = parts.filter { $0["text"] != nil }
            try P2Life.require(!textParts.isEmpty && textParts.allSatisfy { $0["type"] as? String == expected }, "description wire text matches its message role")
        }

        try P2Life.require(P2Life.contexts.count == 6 && P2Life.contexts.prefix(3).allSatisfy { $0.lane == .archive }, "archive operations use archive affinity lane")
        let ephemeral = P2Life.contexts.suffix(3).map { $0.lane.laneId }
        try P2Life.require(ephemeral.allSatisfy { $0.hasPrefix("ephemeral:") } && Set(ephemeral).count == 3, "structuring and descriptions get independent operation lanes")
        try P2Life.require(server.completeRequests.count == 6 && server.completeRequests.allSatisfy { $0.target == "/v1/responses" }, "all inherited auxiliaries target Responses")
        for request in server.completeRequests {
            let body = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
            try P2Life.require(body["tools"] == nil && body["messages"] == nil, "auxiliary request has no tools or chat payload")
        }
        let usageBeforeProbe = try Data(contentsOf: ResponsesUsageStore().file)
        server.script(["{}", try P2Life.body("OK")], statuses: [500, 200])
        let probe = await Probes.responses(baseURL: "http://127.0.0.1:\(server.port)/v1", apiKey: "synthetic-p2-key", model: "gpt-5.6-luna")
        let probeBody = try JSONSerialization.jsonObject(with: server.completeRequests.last!.body) as! [String: Any]
        try P2Life.require(probe == nil && probeBody["max_output_tokens"] as? Int == 2048 && (probeBody["reasoning"] as? [String: String])?["effort"] == "low", "reasoning probe uses low effort and adequate cap")
        try P2Life.require(try Data(contentsOf: ResponsesUsageStore().file) == usageBeforeProbe, "real probe and retry leave existing usage bytes unchanged")
        try P2Life.require(server.remainingResponses == 0 && server.errors.isEmpty, "auxiliary capture script exhausted")
    }

    @MainActor private func runSwitching(_ manager: ConversationManager, server: CaptureServer, file: URL) async throws {
        func select(_ wire: ProviderWireProtocol, key: String = "synthetic-p2-key", model: String = "kimi-k2.5") throws {
            try ProviderProfiles.saveProfile(.custom, apiKey: key, baseURL: "http://127.0.0.1:\(server.port)/v1",
                model: model, effort: nil, textOnly: false, wireProtocol: wire)
            try ProviderProfiles.activate(.custom)
        }
        func chat(_ text: String, tool: Bool = false) throws -> String {
            var message: [String: Any] = ["role": "assistant", "content": text,
                "reasoning_details": [["type": "reasoning.text", "text": "chat-only-reasoning", "format": "unknown"]]]
            if tool {
                let args = String(data: try JSONSerialization.data(withJSONObject: ["path": file.path]), encoding: .utf8)!
                message["tool_calls"] = [["id": "functions.read_file:0", "type": "function", "function": ["name": "read_file", "arguments": args]]]
            }
            return String(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": message,
                "finish_reason": tool ? "tool_calls" : "stop"]], "usage": ["prompt_tokens": 100, "completion_tokens": 20]]), encoding: .utf8)!
        }
        try select(.chatCompletions); try await manager.p2Seed([]); server.clear()
        server.script([try chat("Chat tool round", tool: true), try chat("Chat final")])
        let chatHistory = try await manager.p2Turn(human: Message(role: .user, content: "Use the chat tool"))
        guard let chatFinal = chatHistory.last, let chatRound = chatFinal.toolInteractions.first else { throw P2Life.Failure("chat seed missing real round") }
        try P2Life.require(await manager.p2Error() == nil && chatRound.assistantMessage.toolCalls.first?.id == "functions.read_file:0"
            && chatRound.assistantMessage.reasoningDetails != nil && chatRound.assistantMessage.producedByModel != nil, "real chat history has foreign call id, reasoning details and provenance")
        let mappedID = "call_" + String(ResponsesReplayEnvelope.hash(Data("\(chatFinal.id):0:0:functions.read_file:0".utf8)).prefix(40))
        try select(.responses); server.clear()
        server.script([try P2Life.body("Native tool", tool: "read_file", path: file.path, id: "scopeA"), try P2Life.body("Native final", id: "scopeAfinal")])
        let native = try await manager.p2Turn(human: Message(role: .user, content: "Continue with native protocol and read again"))
        let first = try P2Life.input(server.completeRequests.first!)
        let historicalAssistantParts = first.filter { $0["role"] as? String == "assistant" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        try P2Life.require(historicalAssistantParts.count >= 2
            && historicalAssistantParts.allSatisfy { $0["type"] as? String == "output_text" },
            "real chat history replays assistant text as Responses output_text")
        try P2Life.require(await manager.p2Error() == nil && first.allSatisfy { $0["encrypted_content"] == nil && $0["id"] == nil }, "chat to Responses excludes foreign provider identities and ciphertext")
        try P2Life.require(first.filter { $0["call_id"] as? String == mappedID }.count == 2,
            "chat call and result map to one deterministic Responses id")
        func notes(_ items: [[String: Any]]) -> [[String: Any]] {
            items.filter { item in
                (item["content"] as? [[String: Any]])?.contains {
                    ($0["text"] as? String)?.contains("[reasoning record — harness note]") == true
                } == true
            }
        }
        try P2Life.require(notes(first).count == 2 && notes(first).allSatisfy { $0["role"] as? String == "system" },
            "tool and final textual reasoning each get a separate system note")
        try P2Life.require(historicalAssistantParts.allSatisfy {
            !(($0["text"] as? String)?.contains("chat-only-reasoning") ?? false)
        }, "historical assistant text never incorporates reasoning notes")
        try P2Life.require(first.allSatisfy { $0["reasoning_details"] == nil && $0["reasoning"] == nil },
            "textual reasoning never becomes native Responses reasoning fields")
        try P2Life.require(native.last?.responsesReplay != nil, "native era retained after real manager switch")
        _ = try manager.p2Reload()
        try select(.chatCompletions); server.clear(); server.script([try chat("Back on chat")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Continue on chat"))
        let chatBytes = String(decoding: server.completeRequests.last!.body, as: UTF8.self)
        let chatBody = try JSONSerialization.jsonObject(with: server.completeRequests.last!.body) as! [String: Any]
        let messages = chatBody["messages"] as! [[String: Any]]
        let calls = messages.flatMap { ($0["tool_calls"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        let results = messages.compactMap { $0["tool_call_id"] as? String }
        try P2Life.require(await manager.p2Error() == nil && server.completeRequests.last!.target == "/v1/chat/completions"
            && !chatBytes.contains("encrypted_content") && !chatBytes.contains("responsesReplay") && !chatBytes.contains("opaque_scopeA"), "native history passes frozen chat serializer without metadata leak")
        try P2Life.require(calls == results && calls.contains("functions.read_file:0") && calls.contains("call_scopeA"), "chat preserves canonical call ids and result pairing across protocols")
        try select(.responses, key: "synthetic-account-B"); server.clear(); server.script([try P2Life.body("Account B answer", id: "scopeB")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Use account B"))
        let accountB = try P2Life.input(server.completeRequests.last!)
        try P2Life.require(accountB.allSatisfy { $0["encrypted_content"] == nil }, "account switch omits A ciphertext")
        try select(.responses); server.clear(); server.script([try P2Life.body("Back to A", id: "scopeAreturn")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Restore account A"))
        let accountA = try P2Life.input(server.completeRequests.last!)
        let encrypted = accountA.compactMap { $0["encrypted_content"] as? String }
        try P2Life.require(encrypted.contains("opaque_scopeA") && encrypted.contains("opaque_scopeAfinal") && !encrypted.contains("opaque_scopeB"), "return restores only matching A native replay after chat and account switches")
        try P2Life.require(accountA.filter { $0["call_id"] as? String == mappedID }.count == 2, "semantic chat id remains stable after restart and switches")
        try P2Life.require(notes(accountA).count == 3, "restart and account switches do not duplicate historical notes")
        try select(.responses, model: "another-openai-model"); server.clear()
        server.script([try P2Life.body("Other model answer", id: "otherModel")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Change model"))
        let switched = try P2Life.input(server.completeRequests.last!)
        try P2Life.require(switched.allSatisfy { $0["encrypted_content"] == nil } && notes(switched).count == 3,
            "model change omits ciphertext while preserving readable notes")
        _ = try manager.p2Reload()
        try select(.responses); server.clear(); server.script([try P2Life.body("Original model again", id: "originalModel")])
        _ = try await manager.p2Turn(human: Message(role: .user, content: "Restore original model"))
        let returned = try P2Life.input(server.completeRequests.last!)
        let returnedCiphertext = returned.compactMap { $0["encrypted_content"] as? String }
        try P2Life.require(returnedCiphertext.contains("opaque_scopeA") && !returnedCiphertext.contains("opaque_otherModel")
            && notes(returned).count == 3, "model round trip after reload restores only compatible ciphertext")
        // Drive actual pruning, then serialize its result: no sidecar note can
        // outlive the canonical reasoning that the pruner cleared.
        server.clear(); server.script([try P2Life.body("Pruned summary")])
        let protected = Message(role: .assistant, content: "Recent protected turn", toolInteractions: chatFinal.toolInteractions)
        let pruned = try await manager.p2Prune([Message(role: .user, content: "Old task"), chatFinal,
            Message(role: .user, content: "Recent task"), protected])
        try P2Life.require(pruned.first { $0.id == chatFinal.id }?.finalReasoningDetails == nil
            && pruned.first { $0.id == chatFinal.id }?.toolInteractions.isEmpty == true,
            "pruning clears old textual reasoning at its canonical owner")
        server.script([try P2Life.body("After pruning")])
        _ = try await OpenRouterService().generateResponse(messages: pruned, imagesDirectory: file.deletingLastPathComponent(),
            documentsDirectory: file.deletingLastPathComponent(), tools: [], lane: .main)
        let afterPrune = try P2Life.input(server.completeRequests.last!)
        try P2Life.require(notes(afterPrune).count == 1, "pruned reasoning note disappears; recent protected reasoning remains")
        P2Life.captureDelivery = true; defer { P2Life.captureDelivery = false }
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleReasoningEffortKey, value: "low")
        await manager.p2Effort("ultra")
        try P2Life.require(KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey) == "low", "Responses effort command refuses ultra without persisting it")
        try P2Life.require(server.remainingResponses == 0 && server.errors.isEmpty, "switch capture script exhausted")
    }

    @MainActor private func runSubagents(server: CaptureServer, root: URL, file: URL) async throws {
        let runner = SubagentRunner(), service = OpenRouterService(), executor = ToolExecutor(outputMode: .subagent)
        let invocation = SubagentRunner.Invocation(subagentType: "general-purpose", description: "Responses worker",
            taskPrompt: "Read fixture", modelOverride: nil, runInBackground: false)
        server.clear()
        server.script([try P2Life.body("Reading", tool: "read_file", path: file.path), try P2Life.body("Worker completed")])
        let first = await runner.run(invocation: invocation, sessionId: nil, openRouterService: service,
            toolExecutor: executor, imagesDirectory: root, documentsDirectory: root, parentTools: [AvailableTools.readFile])
        try P2Life.require(first.error == nil && first.sessionPersisted, "new subagent executes and persists")
        let path = StoragePaths.dataRoot.appendingPathComponent("subagent_sessions/\(first.sessionId).json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(SubagentSessionRegistry.Session.self, from: Data(contentsOf: path))
        try P2Life.require(session.messages.last?.responsesReplay != nil && session.messages.last?.toolInteractions.count == 1,
            "subagent final owns replay and calls chronologically")
        server.script([try P2Life.body("Resumed worker")])
        let resumed = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service,
            toolExecutor: executor, imagesDirectory: root, documentsDirectory: root, parentTools: [])
        try P2Life.require(resumed.error == nil && resumed.sessionPersisted, "resumed subagent completes")
        let input = try P2Life.input(server.completeRequests.last!)
        let resultIndex = input.firstIndex { $0["type"] as? String == "function_call_output" }
        let lastUser = input.lastIndex { $0["role"] as? String == "user" }
        try P2Life.require(resultIndex != nil && lastUser != nil && resultIndex! < lastUser!, "resumed user follows completed tool result")
        try P2Life.require(server.remainingResponses == 0 && server.errors.isEmpty, "subagent capture script exhausted")
    }

    @MainActor private func runLive(_ manager: ConversationManager, root: URL, textFile: URL) async throws {
        let image = root.appendingPathComponent("pixel.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKElEQVR4nO3NsQ0AAAzCMP5/un0CNkuZ41wybXsHAAAAAAAAAAAAxR4yw/wuPL6QkAAAAABJRU5ErkJggg==")!
        try png.write(to: image)
        let prompt = "This is a bounded harness test. Use read_file on \(textFile.path) and \(image.path), then reply with the text file contents and a brief image observation. Use no other tools."
        let saved = try await manager.p2Turn(human: Message(role: .user, content: prompt))
        try P2Life.require(await manager.p2Error() == nil, "live main request succeeds")
        guard let final = saved.last, final.responsesReplay != nil else { throw P2Life.Failure("live native replay missing") }
        try P2Life.require(final.toolInteractions.contains { round in
            round.assistantMessage.responsesReplay?.entries.contains { ($0.encryptedContent?.isEmpty == false) } == true
        }, "live tool round persists encrypted reasoning")
        let results = final.toolInteractions.flatMap(\.results)
        try P2Life.require(results.contains { $0.content.contains("P2_TOOL_READ_OK") }, "live text tool succeeds")
        try P2Life.require(results.contains { !$0.fileAttachmentReferences.isEmpty }, "live image tool returned media")
        print("Live first phase passed; invoke --live --resume-live on this same isolated root for process-restart verification.")
    }
}
