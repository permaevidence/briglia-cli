import Foundation

/// K1 composition table and edges; K2 parsing; K3 storage; K4 replies;
/// K5 registry visibility.
extension RetentionHarness {

    /// K1: anchors 0…60 × limits {1, 3, 5, 50, all}, against the frozen
    /// 0.2.57 demotion oracle (same snapshot, same line rule).
    func composeTableSection() {
        let snapshot = randomRef()
        var failures: [String] = []
        for count in [0, 1, 2, 3, 4, 5, 6, 10, 49, 50, 51, 60] {
            var history: [Message] = []
            for i in 0..<count {
                history.append(user("U\(i)", at: at(2026, 6, 1, 0, 0).addingTimeInterval(Double(i) * 3600)))
                var a = anchor("T\(i)", at: at(2026, 6, 1, 0, 30).addingTimeInterval(Double(i) * 3600), recorded: i % 3 != 0)
                a.measuredTokens = i % 2 == 0 ? 500 + i : nil
                history.append(a)
            }
            for index in history.indices where PruneSummaryRetention.isFullAnchor(history[index]) {
                history[index].prunedContextSummaryStub = PruneSummaryRetention.makeStub(for: history, anchor: index, snapshot: snapshot)
            }
            let input = encodedSorted(history)
            for limit in [KeepSummariesLimit.count(1), .count(3), .count(5), .count(50), .all] {
                let view = PruneSummaryRetention.compose(history, limit: limit)
                let keep: Int = { if case .count(let n) = limit { return n }; return Int.max }()
                if encodedSorted(history) != input { failures.append("\(count)/\(limit) mutated input") }
                if count <= keep {
                    if encodedSorted(view.messages) != input || view.renderKey != PruneSummaryRetention.emptyRenderKey || !view.stubIDs.isEmpty {
                        failures.append("\(count)/\(limit) not identity")
                    }
                    continue
                }
                let anchors = history.indices.filter { PruneSummaryRetention.isFullAnchor(history[$0]) }
                var oracle = history
                LegacyDemotionOracle.demote(&oracle, selected: Array(anchors.dropLast(keep)), snapshot: snapshot)
                var shown = view.messages
                for i in shown.indices { shown[i].prunedContextSummaryStub = nil; oracle[i].prunedContextSummaryStub = nil }
                if encodedSorted(shown) != encodedSorted(oracle) { failures.append("\(count)/\(limit) shape ≠ 0.2.57 oracle") }
                if view.stubIDs != Set(anchors.dropLast(keep).map { history[$0].id }) { failures.append("\(count)/\(limit) stub set") }
                if view.renderKey == PruneSummaryRetention.emptyRenderKey || !PruneSummaryRetention.isValidRenderKey(view.renderKey) {
                    failures.append("\(count)/\(limit) key")
                }
            }
        }
        check("K1a composition table (0…60 anchors × 1, 3, 5, 50, all): ≤ N is the identity with the empty key; beyond N each pointer equals the frozen 0.2.57 demotion; input never mutated",
              failures.isEmpty, failures.prefix(8).joined(separator: "; "))
    }

    /// K1 edges: stale / missing / unknown-version stubs show in full;
    /// renderKey depends only on the pointer set.
    func composeEdgeSection() {
        let snapshot = randomRef()
        var history: [Message] = []
        for i in 0..<5 { history.append(anchor("E\(i)", at: at(2026, 7, 1 + i, 10, 0))) }
        for i in history.indices { history[i].prunedContextSummaryStub = PruneSummaryRetention.makeStub(for: history, anchor: i, snapshot: snapshot) }
        var stale = history
        stale[0].prunedContextSummary = "FULL_SUMMARY_E0\n\nEXTENDED"
        stale[1].prunedContextSummaryStub = nil
        let view = PruneSummaryRetention.compose(stale, limit: .count(3))
        check("K1b a stale stub (summary extended after it) and a missing stub are shown in full",
              view.messages[0].prunedContextSummary == "FULL_SUMMARY_E0\n\nEXTENDED" && view.messages[1].prunedContextSummary == "FULL_SUMMARY_E1"
              && view.stubIDs.isEmpty && view.renderKey == PruneSummaryRetention.emptyRenderKey)
        var unknown = history
        if let stub = unknown[0].prunedContextSummaryStub,
           var object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(stub)) as? [String: Any] {
            object["version"] = 2
            unknown[0].prunedContextSummaryStub = try? JSONDecoder().decode(PruneSummaryStub.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let unknownView = PruneSummaryRetention.compose(unknown, limit: .count(3))
        check("K1c an unknown stub version is unusable (shown in full)",
              unknown[0].prunedContextSummaryStub?.version == 2 && unknownView.messages[0].prunedContextSummary == "FULL_SUMMARY_E0"
              && unknownView.stubIDs == [history[1].id])
        let a = PruneSummaryRetention.compose(history, limit: .count(3)), b = PruneSummaryRetention.compose(history, limit: .count(3))
        let c = PruneSummaryRetention.compose(history, limit: .count(4))
        check("K1d renderKey: stable for the same pointer set, different for another set, empty constant for none",
              a.renderKey == b.renderKey && a.renderKey != c.renderKey
              && PruneSummaryRetention.compose(history, limit: .all).renderKey == PruneSummaryRetention.emptyRenderKey)
        var corrupt = history
        corrupt[0].prunedContextSummaryStub = try? JSONDecoder().decode(PruneSummaryStub.self, from: Data(#"{"version":1,"summaryDigest":"x","record":{"bad":true}}"#.utf8))
        let decodedMessage = try? JSONDecoder().decode(Message.self, from: Data(#"{"id":"\#(UUID().uuidString)","role":"assistant","content":"c","prunedContextSummary":"S","prunedContextSummaryStub":{"version":"one"}}"#.utf8))
        check("K1e a malformed stub decodes as absent; the message still loads",
              corrupt[0].prunedContextSummaryStub == nil && decodedMessage?.prunedContextSummary == "S" && decodedMessage?.prunedContextSummaryStub == nil)
        let plain = Message(role: .assistant, content: "plain")
        let keys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])?.keys.map { $0 } ?? []
        check("K1f a message without a stub encodes no new key", !keys.contains("prunedContextSummaryStub"))
    }

    /// K2.
    func parsingSection() {
        let table: [(String, KeepSummariesLimit?)] = [
            ("1", .count(1)), ("3", .count(3)), ("10", .count(10)), ("50", .count(50)), ("all", .all), (" ALL ", .all), ("All", .all),
            ("0", nil), ("51", nil), ("99", nil), ("100", nil), ("03", nil), ("-1", nil), ("+3", nil), ("3.0", nil), ("1e1", nil),
            ("three", nil), ("all please", nil), ("", nil), ("3 4", nil), ("٣", nil),
        ]
        let wrong = table.filter { KeepSummariesSetting.parseArgument($0.0) != $0.1 }.map { "'\($0.0)'" }
        check("K2 parsing: 1–50 as ^[1-9][0-9]?$, 'all' case-insensitive; everything else refused", wrong.isEmpty, wrong.joined(separator: ", "))
    }

    /// K3: strict stored types, key removal, show never writes, cross-process.
    func storageSection() throws {
        let defaults = UserDefaults.standard
        let key = KeepSummariesSetting.defaultsKey
        defaults.removeObject(forKey: key)
        var wrong: [String] = []
        if KeepSummariesSetting.current() != .defaultValue { wrong.append("absent") }
        let cases: [(String, Any, KeepSummariesLimit)] = [
            ("Int 10", 10, .count(10)), ("Int 50", 50, .count(50)), ("Int 1", 1, .count(1)), ("\"all\"", "all", .all),
            ("Int 0", 0, .defaultValue), ("Int 51", 51, .defaultValue), ("Int -3", -3, .defaultValue),
            ("Bool true", true, .defaultValue), ("Bool false", false, .defaultValue), ("Double 10.0", 10.0, .defaultValue),
            ("Double 10.5", 10.5, .defaultValue), ("String \"10\"", "10", .defaultValue), ("String \"ALL\"", "ALL", .defaultValue),
            ("Array", [10], .defaultValue), ("Dictionary", ["n": 10], .defaultValue),
        ]
        for (name, value, expected) in cases {
            defaults.set(value, forKey: key)
            if KeepSummariesSetting.current() != expected { wrong.append(name) }
        }
        check("K3a strict stored types: Int 1…50 or \"all\"; Bool, Double, numeric strings and other types read as the default 3",
              wrong.isEmpty, wrong.joined(separator: ", "))
        for start in [10 as Any, "all" as Any, true as Any, "bogus" as Any, 3 as Any] {
            defaults.set(start, forKey: key)
            KeepSummariesSetting.store(.count(3))
            if defaults.object(forKey: key) != nil { wrong.append("store(3) from \(start)") }
        }
        check("K3b storing 3 removes the key (from Int, \"all\", invalid and an Int 3)", wrong.isEmpty, wrong.joined(separator: ", "))
        // Cross-process: a child process reads what this one stored, and this
        // one reads what the child stored.
        KeepSummariesSetting.store(.count(17))
        let read1 = probe(["--probe", "read"])
        _ = probe(["--probe", "all"])
        #if !canImport(Darwin)
        defaults.synchronize()
        #endif
        let read2 = KeepSummariesSetting.current()
        _ = probe(["--probe", "3"])
        #if !canImport(Darwin)
        defaults.synchronize()
        #endif
        let read3 = probe(["--probe", "read"])
        check("K3c cross-process round trip (store 17 → child reads 17; child stores all → parent reads all; child stores 3 → removed)",
              read1.contains("VALUE=17") && read2 == .all && read3.contains("VALUE=3") && KeepSummariesSetting.current() == .defaultValue,
              "\(read1) | \(read2) | \(read3)")
        defaults.removeObject(forKey: key)
    }

    /// Runs this binary as a K3 probe in the same isolated environment.
    func probe(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["__keep-summaries-selftest"] + arguments
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "launch failed: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// K4 replies (every one names the default 3); K5 registry visibility.
    func repliesSection() async {
        let defaults = UserDefaults.standard
        let key = KeepSummariesSetting.defaultsKey
        defaults.removeObject(forKey: key)
        let legacyRef = randomRef()
        var legacyHolder = Message(role: .assistant, content: "OLD")
        legacyHolder.demotedPruneSummaries = [record(legacyRef, label: "old")]
        guard let manager = try? await freshStubbed(2, edit: { $0.insert(legacyHolder, at: 0) }) else {
            check("K4 setup", false); return
        }
        let show = manager.keepSummariesReply(argument: "")
        let showWroteNothing = defaults.object(forKey: key) == nil
        let set10 = manager.keepSummariesReply(argument: "10")
        let stored10 = defaults.object(forKey: key) as? Int
        let same = manager.keepSummariesReply(argument: "10")
        let invalid = manager.keepSummariesReply(argument: "51")
        let afterInvalid = defaults.object(forKey: key) as? Int
        let all = manager.keepSummariesReply(argument: "ALL")
        let storedAll = defaults.object(forKey: key) as? String
        let back = manager.keepSummariesReply(argument: "3")
        let removed = defaults.object(forKey: key) == nil
        defaults.set(3, forKey: key)
        let already3 = manager.keepSummariesReply(argument: "3")
        let removedFromInt3 = defaults.object(forKey: key) == nil
        check("K4a show: current value, \"(default: 3)\", nothing deleted, how to change, \"/keepsummaries 3\" returns, cost line; never writes",
              show.contains("kept in full: 3 (default: 3)") && show.contains("nothing is deleted") && show.contains("/keepsummaries 3 returns to the default")
              && show.contains(ConversationManager.keepSummariesCostLine) && showWroteNothing, show)
        check("K4b set: names the value and the default 3; stores an Int",
              set10.hasPrefix("✅ Past-turn summaries kept in full: 10 (default is 3; send /keepsummaries 3 to return to it).")
              && set10.contains("Applies from the next request") && stored10 == 10, set10)
        check("K4c same value → \"already\" with the default", same == "Past-turn summaries kept in full: already 10 (default: 3).", same)
        check("K4d invalid → usage with current value and default; nothing stored",
              invalid == "Usage: /keepsummaries [1–50|all] (currently 10; default 3)." && afterInvalid == 10, invalid)
        check("K4e all → stored as \"all\"; 3 → key removed; an Int 3 left by hand is removed before \"already 3\"",
              all.contains("kept in full: all") && storedAll == "all" && back.contains("kept in full: 3") && removed
              && already3 == "Past-turn summaries kept in full: already 3 (default: 3)." && removedFromInt3, "\(all) | \(back) | \(already3)")
        check("K4f legacy pointers that stay pointers are named in a one-line note",
              show.contains("Note: 1 older summary can only be shown as a pointer") && set10.contains("Note: 1 older summary"), show)
        let command = ChatCommandRegistry.commands.first { $0.name == "keepsummaries" }
        let commandsText = await manager.bgPruneTestCommand("/commands")
        let help = ChatCommandRegistry.commands.filter { $0.name == "keepsummaries" }
        check("K5 registry: in /commands and terminal help only (not the Telegram menu), System, usage [N|all], default 3 named",
              command?.inMenu == false && command?.category == "System" && command?.usage == "[N|all]"
              && (command?.description.contains("default 3") ?? false) && (command?.description.contains("/keepsummaries 3") ?? false)
              && commandsText.contains("/keepsummaries") && help.count == 1, commandsText.suffix(400).description)
        let viaCommand = await manager.bgPruneTestCommand("/keepsummaries 5")
        check("K5b the command runs through the shared control dispatch (terminal and chat)",
              viaCommand.contains("kept in full: 5") && KeepSummariesSetting.current() == .count(5), viaCommand)
        defaults.removeObject(forKey: key)
    }
}
