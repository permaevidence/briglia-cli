import Foundation

/// The opt-in request log (plan v2 §1.5, §1.8; Codex round 2 answer 3).
extension MidturnHarness {

    func cpLogSection() async throws {
        let log = CacheDiagnostics.logURL, key = CacheDiagnostics.keyURL
        try? FileManager.default.removeItem(at: log.deletingLastPathComponent())
        // Off by default: nothing written, nothing captured.
        CacheDiagnostics.enabledOverrideForTesting = nil
        CacheDiagnostics.reset()
        do {
            let manager = await freshManager()
            server.script([Self.chatTools([(id: "l0", name: "bash", args: ["command": "echo off"])]), Self.chatText("off done")])
            await cpTurn(manager, "diagnostics off")
            check("L1 off by default: no log file, no key file", !CacheDiagnostics.enabled && !CacheDiagnostics.active
                  && !FileManager.default.fileExists(atPath: log.path) && !FileManager.default.fileExists(atPath: key.path))
        }
        // On: the observed body is exactly what the server received; the log
        // holds no raw content, credential, image bytes or key.
        CacheDiagnostics.enabledOverrideForTesting = true
        CacheDiagnostics.reset()
        let observed = CPCapture()
        CacheDiagnostics.captureForTesting = { observed.add($0) }
        let manager = await freshManager()
        server.clear()
        let canaryUser = "CANARY-USER-7f3e", canaryTool = "CANARY-TOOL-91ac"
        let fakeKey = "sk-proj-SYNTHETICcanaryKEY0123456789abcdefABCDEF"
        let image = StoragePaths.dataRoot.appendingPathComponent("cp-log.png"); try? IRFixtures.png.write(to: image)
        server.script([
            Self.chatTools([(id: "l1", name: "bash", args: ["command": "echo \(canaryTool) \(fakeKey)"])]),
            Self.chatTools([(id: "l2", name: "read_file", args: ["path": image.path])]),
            Self.chatText("on done"),
        ])
        await cpTurn(manager, "diagnostics on \(canaryUser)")
        CacheDiagnostics.captureForTesting = nil
        let received = server.completeRequests.map(\.body)
        let sent = observed.main.map(\.body)
        check("L2 diagnostics on: the server received exactly the bodies the diagnostics read (\(received.count) requests)",
              !received.isEmpty && received == sent, "received \(received.count) observed \(sent.count)")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        let parsed = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        check("L3 one JSON line per request with lane, protocol, sizes, hashes and the first difference",
              parsed.count == received.count && parsed.allSatisfy { $0["lane"] as? String == "main" && $0["item_hashes"] is [String] }
                && parsed.dropFirst().allSatisfy { $0.keys.contains("first_difference") }, "lines \(parsed.count)")
        let keyBytes = (try? Data(contentsOf: key)) ?? Data()
        let forbidden = [canaryUser, canaryTool, fakeKey, apiKey, irBase64(IRFixtures.png), String(irBase64(IRFixtures.png).prefix(24)),
                         keyBytes.base64EncodedString(), keyBytes.map { String(format: "%02x", $0) }.joined(), "Fixture Assistant"]
        check("L4 no raw text, tool output, credential, image bytes or HMAC key in the log",
              !text.isEmpty && forbidden.allSatisfy { !$0.isEmpty && !text.contains($0) }, forbidden.filter { text.contains($0) }.joined(separator: ","))
        let mode = ((try? FileManager.default.attributesOfItem(atPath: log.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let keyMode = ((try? FileManager.default.attributesOfItem(atPath: key.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check("L5 log and key are owner-only (0600), key is 32 random bytes", mode == 0o600 && keyMode == 0o600 && keyBytes.count == 32,
              String(format: "log %o key %o", mode, keyMode))
        let settingsValues = parsed.compactMap { $0["settings"] as? [String: Any] }.flatMap { $0.keys }
        check("L6 settings are allowlisted names (values only for allowlisted keys; others hashed)",
              Set(settingsValues).isSubset(of: CacheDiagnostics.loggedSettings.union(["reasoning.effort", "messages", "provider", "thinking", "reasoning", "include", "input"]))
                && !text.contains("\"tools\":["), "\(Set(settingsValues))")
        // The same request with diagnostics off and on: identical bytes on
        // the wire, both protocols.
        for responses in [false, true] {
            let restore: () -> Void = responses ? try useResponses() : {}
            let service = OpenRouterService()
            await service.configure(apiKey: apiKey)
            let fixed = Date(timeIntervalSince1970: 1_790_000_000)
            let history = [Message(role: .user, content: "same request", timestamp: fixed)]
            var wire: [Data] = []
            for on in [false, true] {
                CacheDiagnostics.enabledOverrideForTesting = on
                server.clear()
                server.script([responses ? Self.responsesText("ok") : Self.chatText("ok")])
                _ = try? await service.generateResponse(messages: history, imagesDirectory: StoragePaths.dataRoot.appendingPathComponent("images"),
                                                        documentsDirectory: StoragePaths.dataRoot.appendingPathComponent("documents"),
                                                        turnStartDate: fixed, lane: .main)
                wire.append(server.completeRequests.first?.body ?? Data())
            }
            CacheDiagnostics.enabledOverrideForTesting = true
            check("L2b \(responses ? "Responses" : "Chat"): the request bytes are identical with diagnostics off and on",
                  wire.count == 2 && !wire[0].isEmpty && wire[0] == wire[1])
            restore()
        }
        // Size cap and rotation.
        CacheDiagnostics.maxLogBytesForTesting = 2_048
        server.script([Self.chatTools([(id: "l3", name: "bash", args: ["command": "echo cap"])]), Self.chatTools([(id: "l4", name: "bash", args: ["command": "echo cap2"])]), Self.chatText("cap done")])
        await cpTurn(manager, "fill the log")
        let size = ((try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? Int) ?? 0
        let rotated = log.deletingLastPathComponent().appendingPathComponent("cache-diagnostics.log.1")
        check("L7 size cap: the log rotates and the current file never exceeds the cap",
              FileManager.default.fileExists(atPath: rotated.path) && size <= 2_048, "size \(size)")
        // One very long request: the line is cut to fit (explicit omitted
        // count), the current log stays under the cap.
        do {
            let ctx = ProviderExecutionContext(provider: .openAICompatible, model: "m", endpoint: "http://127.0.0.1/v1", authorization: "",
                affinityKey: "", lane: .ephemeral(UUID()), provenance: "m", providerPreferences: nil, reasoning: nil, reasoningEffort: nil,
                thinkingType: nil, useReasoningContent: false, textOnly: false, anthropicCacheControl: false, renderPDFAsImages: true)
            let items: [[String: Any]] = (0..<1_000).map { ["role": "user", "content": "item \($0)"] }
            let big = try JSONSerialization.data(withJSONObject: ["model": "m", "messages": [["role": "system", "content": "s"]] + items])
            try? FileManager.default.removeItem(at: log)
            CacheDiagnostics.observe(context: ctx, protocolName: "chat", body: big, tailCount: 0)
            let longText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let longSize = ((try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? Int) ?? 0
            check("L7b a 1,000-item request writes a bounded line with an omitted count; the log stays ≤ the cap",
                  longSize > 0 && longSize <= 2_048 && longText.contains("\"item_hashes_omitted\""), "size \(longSize)")
        }
        CacheDiagnostics.maxLogBytesForTesting = nil
        // Retained state: every component counts toward the per-stream
        // bound, and all stream dictionaries share the stream limit.
        do {
            CacheDiagnostics.reset()
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = 1_024
            let system = String(repeating: "x", count: 100_000)
            for lane in 0..<20 {
                let ctx = ProviderExecutionContext(provider: .openAICompatible, model: "m", endpoint: "http://127.0.0.1/v1", authorization: "",
                    affinityKey: "", lane: .ephemeral(UUID()), provenance: "m", providerPreferences: nil, reasoning: nil, reasoningEffort: nil,
                    thinkingType: nil, useReasoningContent: false, textOnly: false, anthropicCacheControl: false, renderPDFAsImages: true)
                var responsesCtx = ctx; responsesCtx.wireProtocol = .responses
                CacheDiagnostics.noteNativeReplayEviction(lane + 1, context: responsesCtx)
                CacheDiagnostics.noteTransition("turn-start", lane: .ephemeral(UUID()))
                let body = try JSONSerialization.data(withJSONObject: ["model": "m", "messages": [["role": "system", "content": system],
                                                                                                 ["role": "user", "content": "u\(lane)"]]])
                CacheDiagnostics.observe(context: ctx, protocolName: "chat", body: body, tailCount: 0)
            }
            let stats = CacheDiagnostics.retainedStats
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = nil
            check("L10 retained state bounded: ≤ \(CacheDiagnostics.maxLanes) streams × 1,024 bytes in total, every dictionary ≤ \(CacheDiagnostics.maxLanes) streams",
                  stats.bytes <= CacheDiagnostics.maxLanes * 1_024 && stats.previous <= CacheDiagnostics.maxLanes
                    && stats.pending <= CacheDiagnostics.maxLanes && stats.evicted <= CacheDiagnostics.maxLanes,
                  "bytes \(stats.bytes) previous \(stats.previous) pending \(stats.pending) evicted \(stats.evicted)")
        }
        // Byte offsets: exact within the retention bound; beyond it the lane
        // keeps hashes only and the offset is "unavailable", never invented.
        func lastDifference(retain: Int?) -> Any? {
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = retain
            let lane = ProviderExecutionContext(provider: .openAICompatible, model: "m", endpoint: "http://127.0.0.1/v1", authorization: "",
                affinityKey: "", lane: .ephemeral(UUID()), provenance: "m", providerPreferences: nil, reasoning: nil, reasoningEffort: nil,
                thinkingType: nil, useReasoningContent: false, textOnly: false, anthropicCacheControl: false, renderPDFAsImages: true)
            func body(_ second: String) -> Data {
                try! JSONSerialization.data(withJSONObject: ["model": "m", "messages": [["role": "system", "content": "s"],
                    ["role": "user", "content": "first" + String(repeating: "p", count: 200)],
                    ["role": "user", "content": second + String(repeating: "q", count: 200)]]], options: [.sortedKeys])
            }
            CacheDiagnostics.observe(context: lane, protocolName: "chat", body: body("abcdef"), tailCount: 0)
            CacheDiagnostics.observe(context: lane, protocolName: "chat", body: body("abcXef"), tailCount: 0)
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = nil
            let last = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").last.map(String.init) ?? ""
            let object = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
            return (object?["first_difference"] as? [String: Any])?["byte_offset"]
        }
        let exact = lastDifference(retain: nil) as? Int
        let unavailable = lastDifference(retain: 200) as? String
        check("L8 byte offset: exact within the bound (\(exact.map(String.init) ?? "nil")), 'unavailable' beyond it",
              exact != nil && exact! > 0 && unavailable == "unavailable", "\(String(describing: unavailable))")
        // Write failures change nothing for the turn.
        CacheDiagnostics.writeFaultForTesting = { throw IRInjected() }
        let failuresBefore = CacheDiagnostics.writeFailures
        server.script([Self.chatText("still fine")])
        await cpTurn(manager, "log write fails")
        CacheDiagnostics.writeFaultForTesting = nil
        check("L9 a failing log write is counted and the turn completes normally",
              CacheDiagnostics.writeFailures > failuresBefore && manager._testMessages.last?.content == "still fine")
        CacheDiagnostics.enabledOverrideForTesting = nil
        CacheDiagnostics.reset()
    }
}
