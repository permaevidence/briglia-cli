import Foundation

/// Stale-batch suppression and generations (§3.1, §3.2), plus the forced
/// test setting (§3.13).
extension MidturnHarness {

    /// Holds the Nth provider request (1-based) until released, so a user
    /// message can land while the model is "generating".
    final class RequestHold: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var arrivedAt: Set<Int> = []
        private var gates: [Int: DispatchSemaphore] = [:]
        let held: Set<Int>
        init(held: Set<Int>) {
            self.held = held
            for n in held { gates[n] = DispatchSemaphore(value: 0) }
        }
        func observe() {
            lock.lock(); count += 1; let n = count; arrivedAt.insert(n); let gate = gates[n]; lock.unlock()
            gate?.wait()
        }
        func arrived(_ n: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return arrivedAt.contains(n) }
        func release(_ n: Int) { lock.lock(); let gate = gates[n]; lock.unlock(); gate?.signal() }
    }

    func suppressionSection() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mw-suppress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func marker(_ name: String) -> String { scratch.appendingPathComponent(name).path }

        // A1/A4: a message queued while the model generates suppresses the
        // whole batch it produced — ordered synthetic results, nothing runs.
        do {
            let manager = await freshManager()
            let hold = RequestHold(held: [1])
            server.requestObserver = { _ in hold.observe() }
            defer { server.requestObserver = nil }
            server.script([
                Self.chatTools([(id: "call-a1", name: "bash", args: ["command": "touch \(marker("a1"))"]),
                                (id: "call-a2", name: "bash", args: ["command": "touch \(marker("a2"))"])]),
                Self.chatText("read your message first"),
            ])
            manager._testStartTurn(for: user("do two things"))
            _ = await waitUntil { hold.arrived(1) }
            await manager._testDispatchUser(user("actually wait — change of plan"))
            hold.release(1)
            _ = await manager._testAwaitIdle(timeout: 20)
            let round = manager._testMessages.last?.toolInteractions.first
            let ids = round?.results.map(\.toolCallId) ?? []
            let allSuppressed = round?.results.allSatisfy {
                parse($0.content)["status"] as? String == "not_executed" && $0.outcomeBinding?.kind == .notExecuted
            } ?? false
            let ran = FileManager.default.fileExists(atPath: marker("a1")) || FileManager.default.fileExists(atPath: marker("a2"))
            check("A1 stale batch suppressed: every call not_executed (typed), nothing ran", allSuppressed && !ran && ids == ["call-a1", "call-a2"])
            let second = requestBodies().dropFirst().first ?? ""
            check("A4 the queue drained into the last synthetic result; the model sees the message",
                  second.contains("actually wait — change of plan") && second.contains("not_executed"))
            let log = manager._testToolLog
            check("A5 suppressed calls logged as deferred, not failed",
                  log.count == 2 && log.allSatisfy { $0.label.hasSuffix("(deferred)") && !$0.failed }, "\(log)")
        }

        // A2: a message the model has already seen does not suppress.
        do {
            let manager = await freshManager()
            server.script([
                Self.chatTools([(id: "call-b1", name: "bash", args: ["command": "sleep 1"])]),
                Self.chatTools([(id: "call-b2", name: "bash", args: ["command": "touch \(marker("b2"))"])]),
                Self.chatText("done both"),
            ])
            manager._testStartTurn(for: user("step one then two"))
            _ = await waitForRunningJob(timeout: 5)
            await manager._testDispatchUser(user("fyi: also log it"))
            _ = await manager._testAwaitIdle(timeout: 20)
            check("A2 a batch produced after the message was delivered runs normally",
                  FileManager.default.fileExists(atPath: marker("b2")))
            check("G1 seenGenerationAtRequest advanced past the delivered generation", manager._testSeenGeneration >= 1)
        }

        // A3: flood cap — three consecutive suppressions, then the next
        // batch is admitted even though another message is queued.
        do {
            let manager = await freshManager()
            let hold = RequestHold(held: [1, 2, 3, 4])
            server.requestObserver = { _ in hold.observe() }
            defer { server.requestObserver = nil }
            server.script((1...4).map { i in
                Self.chatTools([(id: "call-f\(i)", name: "bash", args: ["command": "touch \(marker("f\(i)"))"])])
            } + [Self.chatText("finally")])
            manager._testStartTurn(for: user("flood test"))
            for i in 1...4 {
                _ = await waitUntil { hold.arrived(i) }
                await manager._testDispatchUser(user("message \(i)"))
                hold.release(i)
            }
            _ = await manager._testAwaitIdle(timeout: 30)
            let ran = (1...4).map { FileManager.default.fileExists(atPath: marker("f\($0)")) }
            check("A3 flood cap: three suppressed batches, the fourth admitted", ran == [false, false, false, true], "\(ran)")
        }

        // G2: generations are memory-only — the queue file holds plain
        // messages, byte-identical to an ordinary encode.
        do {
            let manager = await freshManager()
            server.script([
                Self.chatTools([(id: "call-g", name: "bash", args: ["command": "sleep 2", "wait_seconds": 60])]),
                Self.chatText("ok"), Self.chatText("ok"),
            ])
            manager._testStartTurn(for: user("g"))
            _ = await waitForRunningJob()
            let queued = user("queued text")
            await manager._testDispatchUser(queued)
            let bytes = try? Data(contentsOf: manager._testPendingMidTurnURL)
            let plain = try? JSONEncoder().encode(manager._testQueue)
            let fileObject = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSArray
            let plainObject = plain.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSArray
            check("G2 no new bytes: the queue file is a plain [Message] encode (no generation field)",
                  fileObject != nil && fileObject == plainObject && fileObject?.count == 1
                    && !(String(decoding: bytes ?? Data(), as: UTF8.self).contains("generation")),
                  "file \(bytes.map { String(decoding: $0, as: UTF8.self) } ?? "nil") vs queue \(plain.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")
            _ = await manager._testAwaitIdle(timeout: 20)
            _ = await waitUntil(timeout: 10) { await BackgroundProcessRegistry.shared.runningMainOwnedJobs().isEmpty }
            await manager._testIdleDrains(); _ = await manager._testAwaitIdle(timeout: 20)
        }
    }

    // MARK: T1 — hidden force-detach setting (§3.13)

    func forcedSection() async throws {
        // F1: on → a long eligible wait moves after the forced delay with
        // wake_reason test_forced; no user message, annotation or
        // suppression; its completion is delivered later.
        do {
            let manager = await freshManager()
            ForceDetach.overrideForTesting = true
            defer { ForceDetach.overrideForTesting = nil }
            server.script([
                Self.chatTools([(id: "call-t1", name: "bash", args: ["command": "sleep 3; echo t1", "wait_seconds": 60])]),
                Self.chatText("continuing"),
                Self.chatText("completion seen"),
            ])
            manager._testStartTurn(for: user("forced run"))
            _ = await manager._testAwaitIdle(timeout: 20)
            let result = results(manager).first { $0.toolCallId == "call-t1" }
            let payload = parse(result?.content ?? "")
            check("F1a forced: moved with wake_reason test_forced and the test-mode clause",
                  payload["wake_reason"] as? String == "test_forced"
                    && (payload["message"] as? String ?? "").contains("because background-detach test mode is on")
                    && result?.outcomeBinding?.kind == .moved, "\(payload)")
            let second = requestBodies().dropFirst().first ?? ""
            check("F1b forced: no fake user message, annotation or suppression",
                  manager._testQueue.isEmpty && !second.contains("[Direct user message") && !second.contains("not_executed"))
            check("F1c forced record says forcedDetach", records().first?.launch == .forcedDetach)
            _ = await waitUntil(timeout: 10) { await BackgroundProcessRegistry.shared.runningMainOwnedJobs().isEmpty }
            await manager._testIdleDrains()
            _ = await manager._testAwaitIdle(timeout: 20)
            check("F1d forced detaches intentionally produce the later completion message",
                  manager._testMessages.contains { $0.content.contains("[BACKGROUND BASH COMPLETE]") && $0.content.contains("t1") })
        }
        // F2: a call shorter than the forced delay returns its real result.
        do {
            let manager = await freshManager()
            ForceDetach.overrideForTesting = true
            defer { ForceDetach.overrideForTesting = nil }
            server.script([Self.chatTools([(id: "call-t2", name: "bash", args: ["command": "sleep 0.2; echo fast"])]), Self.chatText("ok")])
            manager._testStartTurn(for: user("fast forced"))
            _ = await manager._testAwaitIdle(timeout: 20)
            let payload = parse(results(manager).first { $0.toolCallId == "call-t2" }?.content ?? "")
            check("F2 forced: a call shorter than the delay returns real", payload["wake_reason"] == nil && payload["status"] as? String == "exited")
        }
        // F3: depth > 0 is never forced (subagent executor).
        do {
            await resetState()
            ForceDetach.overrideForTesting = true
            defer { ForceDetach.overrideForTesting = nil }
            let executor = ToolExecutor(outputMode: .subagent)
            await executor.setSubagentBashCapability(.subagentManaged)
            let call = ToolCall(id: "call-t3", type: "function",
                                function: FunctionCall(name: "bash", arguments: "{\"command\":\"sleep 1.5; echo sub\",\"wait_seconds\":30}"))
            let out = (try? await executor.executeParallel([call]))?.first
            let payload = parse(out?.content ?? "")
            check("F3 forced: a subagent (depth 1) call is never detached", payload["wake_reason"] == nil && payload["status"] as? String == "exited", "\(payload)")
        }
        // F4: hidden — absent from command menus/help and from /commands.
        let listed = ChatCommandRegistry.commands.map { $0.name + " " + $0.description }.joined(separator: "\n")
        check("F4 force-detach is absent from /commands and menus", !listed.contains("FORCE_DETACH") && !listed.lowercased().contains("force-detach"))
        check("F5 unset → off (the constant the wire/lifecycle gates run with)",
              ForceDetach.overrideForTesting == nil && ProcessInfo.processInfo.environment[ForceDetach.environmentKey] == nil && !ForceDetach.active)
    }
}
