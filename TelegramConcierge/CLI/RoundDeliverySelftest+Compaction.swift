import Foundation

/// Real active-turn compaction with a background result inside the
/// compacted prefix (T12, Codex acceptance check 1): the body reaches the
/// actual compaction request and the actual snapshot text, the typed
/// delivery id rides the snapshot's sidecar, acknowledgement follows the
/// saved outcome through that sidecar, and startup recovery uses it too.
/// Also the interrupted overflow path, and a snapshot publication failure
/// (never acknowledged; recovered at startup without a copy).
extension MidturnHarness {

    /// Scripted main agent that reads a large file every round until a
    /// compaction happened, launching one background job in round 1.
    final class CompactionScript: @unchecked Sendable {
        private let lock = NSLock()
        let responses: Bool
        let path: String
        let fact: String
        private(set) var ordinary = 0
        private(set) var summaryBodies: [String] = []
        var summaryReplies: [String] = []   // "" = an empty (rejected) summary
        init(responses: Bool, path: String, fact: String) { self.responses = responses; self.path = path; self.fact = fact }

        var summaries: [String] { lock.lock(); defer { lock.unlock() }; return summaryBodies }
        var ordinaryCount: Int { lock.lock(); defer { lock.unlock() }; return ordinary }

        func route(_ request: CapturedHTTPRequest) -> (body: String, delay: TimeInterval)? {
            let text = String(decoding: request.body, as: UTF8.self)
            let tokens = request.body.count / 3
            lock.lock(); defer { lock.unlock() }
            if text.contains("ACTIVE TURN COMPACTION") {
                summaryBodies.append(text)
                let reply = summaryReplies.isEmpty ? "Goal: read the file repeatedly. Background job result noted." : summaryReplies.removeFirst()
                return (Self.reply(responses: responses, text: reply, calls: [], tokens: tokens), 0)
            }
            if text.contains("[PRUNE SUMMARY") {
                return (Self.reply(responses: responses, text: "Earlier turn summary.", calls: [], tokens: tokens), 0)
            }
            ordinary += 1
            let read: (id: String, name: String, args: [String: Any]) = (id: "c\(ordinary)", name: "read_file", args: ["path": path, "limit": 200])
            if !summaryBodies.isEmpty || ordinary >= 40 {
                return (Self.reply(responses: responses, text: "T12_FINAL", calls: [], tokens: tokens), 0.05)
            }
            if ordinary == 1 {
                return (Self.reply(responses: responses, text: nil,
                                   calls: [MidturnHarness.bgCall("bgc", "sleep 0.2; echo \(fact)"), read], tokens: tokens), 0.15)
            }
            return (Self.reply(responses: responses, text: nil, calls: [read], tokens: tokens), 0.15)
        }

        static func reply(responses: Bool, text: String?, calls: [(id: String, name: String, args: [String: Any])], tokens: Int) -> String {
            func args(_ a: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]), as: UTF8.self) }
            var root: [String: Any]
            if responses {
                var output: [[String: Any]] = calls.map { ["type": "function_call", "id": "fc_" + $0.id, "call_id": $0.id,
                                                           "status": "completed", "name": $0.name, "arguments": args($0.args)] }
                if let text {
                    output.append(["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + UUID().uuidString,
                                   "content": [["type": "output_text", "text": text, "annotations": []]]])
                }
                root = ["id": "resp_" + UUID().uuidString, "status": "completed", "output": output,
                        "usage": ["input_tokens": tokens, "input_tokens_details": ["cached_tokens": 0],
                                  "output_tokens": 100, "output_tokens_details": ["reasoning_tokens": 0]]]
            } else {
                var message: [String: Any] = ["role": "assistant", "content": text.map { $0 as Any } ?? NSNull()]
                if !calls.isEmpty {
                    message["tool_calls"] = calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": args($0.args)]] }
                }
                root = ["id": "rc", "object": "chat.completion", "model": "glm-5.3",
                        "choices": [["index": 0, "message": message, "finish_reason": calls.isEmpty ? "stop" : "tool_calls"]],
                        "usage": ["prompt_tokens": tokens, "completion_tokens": 100, "total_tokens": tokens + 100]]
            }
            return String(decoding: try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
        }
    }

    func roundCompactionSection() async throws {
        try KeychainHelper.saveBatch([KeychainHelper.maxContextTokensKey: "250000", KeychainHelper.targetContextTokensKey: "70000",
                                      KeychainHelper.archiveChunkSizeKey: "1000000"].mapValues { Optional($0) })
        defer {
            for key in [KeychainHelper.maxContextTokensKey, KeychainHelper.targetContextTokensKey, KeychainHelper.archiveChunkSizeKey] {
                try? KeychainHelper.delete(key: key)
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rd-source-\(UUID().uuidString).txt")
        try Data(((0..<100).map { _ in String(repeating: "EXACT_EVIDENCE ", count: 55) }.joined(separator: "\n")).utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await roundCompacted(responses: false, file: file.path)
        let restore = try useResponses()
        do { try await roundCompacted(responses: true, file: file.path) }
        restore()
        try await roundInterruptedOverflow(file: file.path)
        try await roundPublicationFailure(file: file.path)
        try await roundCheckpointFailure(file: file.path)
    }

    /// Failed checkpoint publication during compaction, AFTER the snapshot
    /// was published: the error outcome saved to history references that
    /// complete snapshot, so the delivery is proven through its sidecar and
    /// acknowledged — never through the failed checkpoint; no idle copy;
    /// a restart finds nothing owed.
    private func roundCheckpointFailure(file: String) async throws {
        let (manager, _, _) = await startCompactionTurn("T12Q", responses: false, file: file) {
            ConversationManager.checkpointWriteFaultForTesting = { throw Injected() }
        }
        server.router = nil; server.concurrent = false
        ConversationManager.checkpointWriteFaultForTesting = nil
        let outcome = manager._testMessages.last { $0.role == .assistant }
        let snap = snapshotCarrying("T12Q_UNIQUE_FACT")
        let settled = await roundSettled(manager)
        await manager._testIdleDrains()
        check("T12Qa checkpoint write failed after publication: the saved error outcome references the snapshot; acknowledged through its sidecar",
              outcome?.pruneArchiveReferences.isEmpty == false && snap.sidecar?.deliveries.isEmpty == false && settled
                && !manager._testMessages.contains { $0.kind == .bashComplete },
              "refs \(outcome?.pruneArchiveReferences.count ?? -1) settled \(settled)")
        let restarted = await restart()
        check("T12Qb a restart finds nothing owed and appends nothing",
              records().isEmpty && !restarted._testMessages.contains { $0.kind == .bashComplete } && restarted._testRecoveredWakeTrigger == nil,
              "records \(records().map(\.completion.rawValue))")
    }

    private func startCompactionTurn(_ tag: String, responses: Bool, file: String, summaries: [String] = [],
                                     faults: (() -> Void)? = nil) async -> (ConversationManager, CompactionScript, Message) {
        let manager = await roundFresh()
        faults?()
        let script = CompactionScript(responses: responses, path: file, fact: "\(tag)_UNIQUE_FACT")
        script.summaryReplies = summaries
        server.concurrent = true
        server.router = { script.route($0) }
        let trigger = user("\(tag) read the file many times")
        manager._testStartTurn(for: trigger)
        _ = await manager._testAwaitIdle(timeout: 180)
        return (manager, script, trigger)
    }

    /// The snapshot file whose text carries `fact`, its completion id and
    /// its sidecar.
    private func snapshotCarrying(_ fact: String) -> (text: String, id: UUID?, sidecar: SettlementSidecar?) {
        let entries = (try? PruneArchiveStore.entries()) ?? []
        for entry in entries.reversed() {
            guard let text = try? String(contentsOf: PruneArchiveStore.root.appendingPathComponent(entry.reference.basename), encoding: .utf8),
                  text.contains(fact) else { continue }
            var id: UUID?
            if let range = text.range(of: #"completion_id: [0-9A-F-]{36}"#, options: .regularExpression) {
                id = UUID(uuidString: String(text[range].dropFirst("completion_id: ".count)))
            }
            var sidecar: SettlementSidecar?
            if case .present(let s) = SettlementEvidence.loadSidecar(entry.reference.id) { sidecar = s }
            return (text, id, sidecar)
        }
        return ("", nil, nil)
    }

    /// Recreate an owed foreign record for `completionId` and restart.
    private func restartWithOwedRecord(_ completionId: UUID, anchor: UUID) async throws -> ConversationManager {
        let base = Self.record(anchor: anchor)
        try DetachedJobStore.create(DetachedJobRecord(jobId: base.jobId, instanceId: UUID(), turnRunId: nil, toolCallId: "bgc",
                                                      callFingerprint: nil, handle: "bash_c", command: "echo", description: nil,
                                                      workdir: nil, startedAt: Date(), launch: .background,
                                                      completionMessageId: completionId, historyAnchorMessageId: anchor))
        return await restart()
    }

    private func roundCompacted(responses: Bool, file: String) async throws {
        let tag = responses ? "T12R" : "T12"
        let (manager, script, trigger) = await startCompactionTurn(tag, responses: responses, file: file)
        let fact = "\(tag)_UNIQUE_FACT"
        let outcome = manager._testMessages.last { $0.role == .assistant }
        check("\(tag)a a real active-turn compaction ran and the turn finished",
              !script.summaries.isEmpty && outcome?.activeTurnCompaction != nil && outcome?.content == "T12_FINAL",
              "summaries \(script.summaries.count), last \(outcome?.content.prefix(80) ?? "nil")")
        check("\(tag)b the background body reached the actual compaction request", script.summaries.contains { $0.contains(fact) })
        let snap = snapshotCarrying(fact)
        check("\(tag)c the actual snapshot text holds the body and its completion id", snap.id != nil && snap.text.contains(fact))
        check("\(tag)d the snapshot's sidecar lists the delivery (carried view)",
              snap.sidecar?.deliveries.contains { $0.completionIds.contains(snap.id ?? UUID()) && $0.view == .carried } == true)
        let settled = await roundSettled(manager)
        server.router = nil; server.concurrent = false
        await manager._testIdleDrains()
        check("\(tag)e acknowledged through the sidecar after the saved outcome; no idle copy",
              settled && !manager._testMessages.contains { $0.kind == .bashComplete } && !carriers(manager).contains { $0.content.contains(fact) })
        guard let id = snap.id else { return }
        let restarted = try await restartWithOwedRecord(id, anchor: trigger.id)
        check("\(tag)f startup: an owed record is settled from the sidecar (owning chain) — no copy, no wake",
              records().isEmpty && !restarted._testMessages.contains { $0.kind == .bashComplete } && restarted._testRecoveredWakeTrigger == nil)
    }

    /// Interrupted overflow: both summary attempts fail; the work moves into
    /// the overflow snapshot; the delivery is proven through its sidecar.
    private func roundInterruptedOverflow(file: String) async throws {
        let (manager, _, _) = await startCompactionTurn("T12I", responses: false, file: file, summaries: ["", ""])
        server.router = nil; server.concurrent = false
        let outcome = manager._testMessages.last { $0.role == .assistant }
        let snap = snapshotCarrying("T12I_UNIQUE_FACT")
        check("T12Ia interrupted overflow: the outcome references the overflow snapshot holding the body",
              outcome?.pruneArchiveReferences.isEmpty == false && snap.id != nil,
              outcome?.content.prefix(120).description ?? "nil")
        let settled = await roundSettled(manager)
        await manager._testIdleDrains()
        check("T12Ib acknowledged through the overflow snapshot's sidecar; no idle copy",
              settled && !manager._testMessages.contains { $0.kind == .bashComplete })
    }

    /// Failed snapshot publication: never acknowledged; the raw turn file is
    /// the carrier; startup recovery publishes it and settles the record
    /// from the typed evidence without a copy.
    private func roundPublicationFailure(file: String) async throws {
        let (manager, _, _) = await startCompactionTurn("T12P", responses: false, file: file) {
            PruneArchiveStore.faultForTesting = { stage in if stage == "publish" { throw Injected() } }
        }
        server.router = nil; server.concurrent = false
        let reserved = manager._testRoundReservations.values.contains { $0.state == .reserved }
        let queued = !(await BackgroundProcessRegistry.shared.pendingCompletionsForDelivery().isEmpty)
        let owed = records().contains { $0.completion == .owed }
        check("T12Pa failed snapshot publication: not acknowledged (reserved, queued, record owed)",
              reserved && queued && owed, "reserved \(reserved) queued \(queued) owed \(owed)")
        await manager._testIdleDrains()
        check("T12Pb no idle copy while the raw turn file carries it", !manager._testMessages.contains { $0.kind == .bashComplete })
        PruneArchiveStore.faultForTesting = nil
        let restarted = await restart()
        check("T12Pc startup recovery publishes the work and settles the record from its evidence (no copy)",
              records().isEmpty && !restarted._testMessages.contains { $0.kind == .bashComplete }
                && restarted._testRecoveredWakeTrigger == nil,
              "records \(records().map(\.completion.rawValue))")
    }
}

extension MidturnHarness {
    /// SR5 (Codex R1, compaction carrier): the delivered result's durable
    /// carrier is a compaction snapshot (acknowledged through its sidecar)
    /// and the withdrawal is held; a later turn's drain reads the queue,
    /// the withdrawal finishes, and the drain resumes — no second copy.
    func roundStaleCompactedCarrier() async throws {
        try KeychainHelper.saveBatch([KeychainHelper.maxContextTokensKey: "250000", KeychainHelper.targetContextTokensKey: "70000",
                                      KeychainHelper.archiveChunkSizeKey: "1000000"].mapValues { Optional($0) })
        defer {
            for key in [KeychainHelper.maxContextTokensKey, KeychainHelper.targetContextTokensKey, KeychainHelper.archiveChunkSizeKey] {
                try? KeychainHelper.delete(key: key)
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rd-stale-\(UUID().uuidString).txt")
        try Data(((0..<100).map { _ in String(repeating: "EXACT_EVIDENCE ", count: 55) }.joined(separator: "\n")).utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var release = false
        let (manager, script, _) = await startCompactionTurn("SR5", responses: false, file: file.path) {
            ConversationManager.roundWithdrawalHoldForTesting = { _ = await self.waitUntil(timeout: 60) { release } }
        }
        server.router = nil; server.concurrent = false
        let snap = snapshotCarrying("SR5_UNIQUE_FACT")
        let id = snap.id
        check("SR5a compaction moved the carrier into a snapshot; acknowledged through its sidecar; withdrawal pending",
              !script.summaries.isEmpty && id != nil && manager._testRoundReservations[id!]?.state == .acknowledging
                && !carriers(manager).contains { $0.deliveredCompletions.contains(id!) },
              "summaries \(script.summaries.count) id \(id?.uuidString ?? "nil") state \(id.flatMap { manager._testRoundReservations[$0]?.state }.map { "\($0)" } ?? "none")")
        var withdrawn = false
        onceAt("subagent-read") {
            release = true
            withdrawn = await self.waitUntil(timeout: 10) { id.map { manager._testRoundReservations[$0] == nil } ?? false }
        }
        server.script([
            Self.chatTools([Self.fgCall("sr5-second", "echo next-turn")]),
            Self.chatText("SR5 second turn done"),
        ])
        let before = server.completeRequests.count
        manager._testStartTurn(for: user("SR5 second turn"))
        _ = await manager._testAwaitIdle(timeout: 25)
        check("SR5b withdrawal finished after the drain read and before its eligibility check", withdrawn)
        check("SR5c no second copy in live history or in the next request; no idle copy, no extra wake",
              !carriers(manager).contains { $0.deliveredCompletions.contains(id ?? UUID()) }
                && !manager._testMessages.contains { $0.kind == .bashComplete }
                && !(requestBodies().last ?? "").contains("SR5_UNIQUE_FACT")
                && server.completeRequests.count == before + 2,
              "requests \(server.completeRequests.count) vs \(before) + 2")
        roundResetSeams()
    }
}
