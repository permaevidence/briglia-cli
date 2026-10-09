import Foundation

/// The retained prefix keeps a valid tail count (implementation review R4):
/// trimming retained items must also trim the trailing region, or the next
/// comparison builds an invalid range (process trap) or skips stable items.
extension MidturnHarness {

    func cpTailSection() {
        CacheDiagnostics.enabledOverrideForTesting = true
        CacheDiagnostics.reset()
        defer {
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = nil
            CacheDiagnostics.enabledOverrideForTesting = nil
            CacheDiagnostics.reset()
        }
        let log = CacheDiagnostics.logURL
        func context() -> ProviderExecutionContext {
            ProviderExecutionContext(provider: .openAICompatible, model: "m", endpoint: "http://127.0.0.1/v1", authorization: "",
                affinityKey: "", lane: .ephemeral(UUID()), provenance: "m", providerPreferences: nil, reasoning: nil, reasoningEffort: nil,
                thinkingType: nil, useReasoningContent: false, textOnly: false, anthropicCacheControl: false, renderPDFAsImages: true)
        }
        func body(system: String, users: [String]) -> Data {
            let messages: [[String: Any]] = [["role": "system", "content": system]] + users.map { ["role": "user", "content": $0] }
            return try! JSONSerialization.data(withJSONObject: ["messages": messages], options: [.sortedKeys])
        }
        func lastLine() -> [String: Any]? {
            let last = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").last.map(String.init) ?? ""
            return try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
        }

        // T1 — the review's reproduction: a 64-byte bound keeps the system
        // hash plus ONE of three items, two of which are tail items. The
        // identical second request trapped the process on the old code.
        do {
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = 64
            let ctx = context()
            let request = body(system: String(repeating: "S", count: 1_000), users: ["stable", "tail1", "tail2"])
            CacheDiagnostics.observe(context: ctx, protocolName: "chat", body: request, tailCount: 2)
            CacheDiagnostics.observe(context: ctx, protocolName: "chat", body: request, tailCount: 2)
            let line = lastLine()
            check("T1 prefix ending before the tail: an identical second request is compared without a trap, no difference, partial comparison",
                  line != nil && line?["first_difference"] is NSNull
                    && (line?["comparison"] as? String)?.hasPrefix("partial") == true,
                  "\(String(describing: line?["first_difference"])) \(String(describing: line?["comparison"]))")
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = nil
        }

        // T2 — the prefix rule itself, for the three boundary shapes.
        do {
            let items = (0..<5).map { Data("item \($0)".utf8) }
            let parsed = CacheDiagnostics.Parsed(system: Data("s".utf8), items: items, tools: [], settings: [:], tailCount: 2, totalBytes: 0)
            let none = CacheDiagnostics.retainedPrefix(parsed, items: 0, tools: nil)
            let before = CacheDiagnostics.retainedPrefix(parsed, items: 2, tools: nil)
            let inside = CacheDiagnostics.retainedPrefix(parsed, items: 4, tools: nil)
            let whole = CacheDiagnostics.retainedPrefix(parsed, items: 9, tools: nil)
            check("T2 retained tail: no items → 0, prefix before the tail → 0, prefix inside the tail → 1, whole request → 2",
                  none.items.isEmpty && none.tailCount == 0 && before.items.count == 2 && before.tailCount == 0
                    && inside.items.count == 4 && inside.tailCount == 1 && whole.items.count == 5 && whole.tailCount == 2,
                  "none \(none.tailCount) before \(before.tailCount) inside \(inside.tailCount) whole \(whole.tailCount)")
            // An inconsistent record (tail larger than the items) compares
            // without a trap: the range is always valid.
            let broken = CacheDiagnostics.Parsed(system: Data(), items: [Data("a".utf8)], tools: [], settings: [:], tailCount: 5, totalBytes: 0)
            let diffs = CacheDiagnostics.differences(previous: broken, current: broken)
            check("T2b a tail count larger than the retained items never builds an invalid range", diffs.isEmpty)
            // No retained items at all compares nothing and reports nothing.
            let empty = CacheDiagnostics.differences(previous: none, current: parsed)
            check("T2c no retained items: nothing compared, no invented difference", empty.isEmpty)
        }

        // T3 — prefix ending INSIDE the tail: five items, tail 2, a bound
        // that keeps four hashes. Item 2 was stable and is retained, so its
        // change must still be reported (clamping the old tail count would
        // silently skip it).
        do {
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = 32 + 4 * 32
            let ctx = context()
            let system = String(repeating: "S", count: 400)
            let users = (0..<5).map { "user item \($0) " + String(repeating: "u", count: 40) }
            CacheDiagnostics.observe(context: ctx, protocolName: "chat", body: body(system: system, users: users), tailCount: 2)
            var changed = users; changed[2] = "user item 2 CHANGED " + String(repeating: "u", count: 40)
            CacheDiagnostics.observe(context: ctx, protocolName: "chat", body: body(system: system, users: changed), tailCount: 2)
            let diff = lastLine()?["first_difference"] as? [String: Any]
            check("T3 prefix inside the tail: a change to a retained stable item is still reported (item 2), offset 'unavailable'",
                  diff?["position"] as? String == "item 2" && diff?["byte_offset"] as? String == "unavailable",
                  "\(String(describing: diff))")
            CacheDiagnostics.maxRetainedBytesOverrideForTesting = nil
        }
    }
}
