import Foundation

/// Step 0 rows: the checker itself, a long steady session, and a session
/// crossing every recorded transition (both protocols).
extension MidturnHarness {

    /// The rule on synthetic bodies (each break must be reported).
    func cpUnitSection() {
        func body(system: String = "S", items: [Any], tools: [String] = ["a", "b"], effort: String = "high") -> Data {
            let object: [String: Any] = ["model": "m", "reasoning": ["effort": effort],
                                         "input": [["role": "system", "content": system]] + items,
                                         "tools": tools.map { ["type": "function", "name": $0] }]
            return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func req(_ data: Data, tail: Int = 0, _ transitions: [String] = []) -> CacheDiagnostics.Request {
            CacheDiagnostics.Request(lane: "main", protocolName: "responses", body: data, tailCount: tail, transitions: transitions)
        }
        let base: [Any] = [["role": "user", "content": "u1"], ["type": "function_call", "call_id": "c1"], ["type": "function_call_output", "call_id": "c1"]]
        let ambient: [Any] = [["role": "user", "content": "[Ambient status] bash_1 running"]]
        let next = base + [["type": "function_call", "call_id": "c2"], ["type": "function_call_output", "call_id": "c2"]]
        let ok = CacheDiagnostics.check([req(body(items: base + ambient), tail: 1), req(body(items: next))])
        check("U1 append-only after a documented tail: Class A holds", ok.findings.isEmpty && ok.classAPairs == 1, "\(ok.findings)")
        let reordered = CacheDiagnostics.check([req(body(items: base)), req(body(items: next, tools: ["b", "a"]))])
        check("U2 two tools reordered mid-generation → Class A break (tools reordering)",
              reordered.findings.first.map { $0.klass == "A" && $0.detail.contains("tools tool 0 reordering") } == true, "\(reordered.findings)")
        var dropped = next; dropped.remove(at: 1)
        let drop = CacheDiagnostics.check([req(body(items: base)), req(body(items: dropped))])
        check("U3 a mid-history item dropped → Class A break at its position",
              drop.findings.first.map { $0.detail.contains("input item 1") } == true, "\(drop.findings)")
        let effort = CacheDiagnostics.check([req(body(items: base)), req(body(items: next, effort: "low"))])
        check("U4 effort changed mid-generation → Class A break (settings)",
              effort.findings.first.map { $0.detail.contains("settings reasoning") } == true, "\(effort.findings)")
        let rewritten: [Any] = [["role": "user", "content": "summary"]] + next
        let prune = CacheDiagnostics.check([req(body(items: base)), req(body(system: "S2", items: rewritten), ["prune"])])
        check("U5 prune: input and system rewrite inside its scope → no finding, transition listed",
              prune.findings.isEmpty && prune.classBTransitions.count == 1, "\(prune.findings)")
        let unrecorded = CacheDiagnostics.check([req(body(items: base)), req(body(system: "S2", items: rewritten))])
        check("U6 the same rewrite without a recorded transition → Class A break", unrecorded.findings.first?.klass == "A")
        let outOfScope = CacheDiagnostics.check([req(body(items: base)), req(body(items: rewritten, tools: ["a", "b", "c"]), ["tool-exposure"])])
        check("U7 a tool-exposure label does not excuse an input rewrite → Class B scope break",
              outOfScope.findings.contains { $0.klass == "B" && $0.detail.contains("input") }, "\(outOfScope.findings)")
        let eviction = CacheDiagnostics.check([req(body(items: base)), req(body(items: rewritten, tools: ["a", "b"]), ["native-replay-eviction"])])
        check("U8 native replay eviction: an input rewrite in scope; a tools change would not be",
              eviction.findings.isEmpty)
    }

    /// ≥ 30 main-lane rounds across two turns: tool results, an image, a
    /// background job (ambient status tail, result appended mid-turn), an
    /// instruction-file load, a mid-turn user message, a turn boundary.
    func cpSteadySection() async throws {
        for responses in [false, true] {
            let tag = responses ? "CP-steady-responses" : "CP-steady-chat"
            let (manager, script, capture, done) = try await cpStart(responses: responses)
            let project = StoragePaths.dataRoot.appendingPathComponent("cp-project", isDirectory: true)
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try? Data("# Project rules\nRun the tests before committing.\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
            try? Data("notes\n".utf8).write(to: project.appendingPathComponent("notes.txt"))
            let text = project.appendingPathComponent("plain.txt"); try? Data("plain text file\n".utf8).write(to: text)
            let image = project.appendingPathComponent("pixel.png"); try? IRFixtures.png.write(to: image)
            script.push([(id: "s1", name: "bash", args: ["command": "echo one"])])
            script.push([(id: "s2", name: "read_file", args: ["path": text.path])])
            script.push([(id: "s3", name: "read_file", args: ["path": image.path])])
            script.push([(id: "s4", name: "bash", args: ["command": "sleep 1; echo CP_BACKGROUND", "wait_seconds": 0])])
            script.push([(id: "s5", name: "read_file", args: ["path": project.appendingPathComponent("notes.txt").path])])
            for i in 6...16 { script.push([(id: "s\(i)", name: "bash", args: ["command": "echo round \(i)"])]) }
            script.pushText("turn one done")
            script.onMainRequest = { n in
                if n == 8 { Task { @MainActor in await manager._testDispatchUser(self.user("a short note while you work")) } }
            }
            await cpTurn(manager, "start the long task")
            _ = await waitUntil(timeout: 10) { await BackgroundProcessRegistry.shared.runningMainOwnedJobs().isEmpty }
            _ = await manager._testAwaitIdle(timeout: 30)
            script.onMainRequest = nil
            for i in 1...15 { script.push([(id: "t\(i)", name: "bash", args: ["command": "echo second \(i)"])]) }
            script.pushText("turn two done")
            await cpTurn(manager, "continue")
            let main = capture.main
            let result = CacheDiagnostics.check(main)
            cpReport(tag, result)
            let bodies = main.map { String(decoding: $0.body, as: UTF8.self) }
            check("\(tag)a ≥ 30 main-lane requests captured, image, instructions and the mid-turn note were on the wire",
                  main.count >= 30 && bodies.contains { $0.contains(irBase64(IRFixtures.png)) }
                    && bodies.contains { $0.contains("Run the tests before committing") }
                    && bodies.contains { $0.contains("a short note while you work") }, "requests \(main.count)")
            check("\(tag)b the ambient status tail and the mid-turn background result appeared",
                  main.contains { $0.tailCount > 0 } && bodies.contains { $0.contains("CP_BACKGROUND") })
            check("\(tag)c Class A holds for every request pair without a transition (\(result.classAPairs) pairs)",
                  result.findings.isEmpty && result.classAPairs >= 25, result.findings.prefix(3).map(\.description).joined(separator: " | "))
            check("\(tag)d the turn boundary is a recorded transition",
                  result.classBTransitions.contains { $0.reasons.contains("turn-start") })
            done()
        }
    }

    /// Archive commit, a tool-exposure change, prune, active-turn
    /// compaction and (Responses) native replay eviction at the bound: every
    /// change happens at a recorded transition and inside its scope.
    func cpTransitionSection() async throws {
        try KeychainHelper.saveBatch([KeychainHelper.maxContextTokensKey: "250000", KeychainHelper.targetContextTokensKey: "70000"].mapValues { Optional($0) })
        defer {
            for key in [KeychainHelper.maxContextTokensKey, KeychainHelper.targetContextTokensKey] { try? KeychainHelper.delete(key: key) }
            ResponsesLimits.replayBytesOverrideForTesting = nil
        }
        try FileManager.default.createDirectory(at: StoragePaths.dataRoot, withIntermediateDirectories: true)
        let large = StoragePaths.dataRoot.appendingPathComponent("cp-large.txt")
        try Data(((0..<100).map { _ in String(repeating: "EXACT_EVIDENCE ", count: 55) }.joined(separator: "\n")).utf8).write(to: large)
        for responses in [false, true] {
            let tag = responses ? "CP-transitions-responses" : "CP-transitions-chat"
            let (manager, script, capture, done) = try await cpStart(responses: responses)
            // An archive-sized history (over the archive threshold).
            let base = Date().addingTimeInterval(-86_400)
            let old = (0..<24).map { i in
                Message(role: i % 2 == 0 ? .user : .assistant,
                        content: ArchiveFullChunkSelftest.filler("old-\(i)", size: 4_000, sentinel: "end of old-\(i)."),
                        timestamp: base.addingTimeInterval(TimeInterval(i * 60)))
            }
            manager._testSeedHistory(old)
            for i in 1...3 { script.push([(id: "a\(i)", name: "bash", args: ["command": "echo a\(i)"])]) }
            script.pushText("turn A done")
            await cpTurn(manager, "turn A")
            let archived = await waitUntil(timeout: 60) { manager._baJobOutcome == "succeeded" }
            for i in 1...2 { script.push([(id: "b\(i)", name: "bash", args: ["command": "echo b\(i)"])]) }
            script.pushText("turn B done")
            await cpTurn(manager, "turn B")
            _ = await manager.handleTerminalCommand("/subagents off")
            for i in 1...2 { script.push([(id: "c\(i)", name: "bash", args: ["command": "echo c\(i)"])]) }
            script.pushText("turn C done")
            await cpTurn(manager, "turn C")
            _ = await manager.handleTerminalCommand("/subagents on")
            await manager._testManualPrune()
            for i in 1...2 { script.push([(id: "d\(i)", name: "bash", args: ["command": "echo d\(i)"])]) }
            script.pushText("turn D done")
            await cpTurn(manager, "turn D")
            script.readUntilCompaction = large.path
            for i in 1...2 { script.push([(id: "e\(i)", name: "bash", args: ["command": "echo e\(i)"])]) }
            script.pushText("turn E done")
            await cpTurn(manager, "turn E: read the file many times", timeout: 300)
            script.readUntilCompaction = nil
            if responses {
                ResponsesLimits.replayBytesOverrideForTesting = 2_000
                for i in 1...8 { script.push([(id: "f\(i)", name: "bash", args: ["command": "echo f\(i)"])]) }
                script.pushText("turn F done")
                await cpTurn(manager, "turn F")
                ResponsesLimits.replayBytesOverrideForTesting = nil
            }
            let main = capture.main
            let result = CacheDiagnostics.check(main)
            cpReport(tag, result)
            let reasons = Set(result.classBTransitions.flatMap(\.reasons))
            var expected: Set<String> = ["turn-start", "archive-commit", "tool-exposure", "prune", "compaction"]
            if responses { expected.insert("native-replay-eviction") }
            check("\(tag)a the session crossed every transition (archive \(archived), compactions \(script.compactions))",
                  expected.isSubset(of: reasons), "recorded \(reasons.sorted())")
            check("\(tag)b no change outside a recorded transition or outside its scope",
                  result.findings.isEmpty, result.findings.prefix(3).map(\.description).joined(separator: " | "))
            if responses {
                check("\(tag)c native replay eviction is recorded mid-turn (not only at the turn start)",
                      result.classBTransitions.contains { $0.reasons == ["native-replay-eviction"] })
            }
            done()
        }
    }
}
