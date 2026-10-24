import Foundation

/// §9.5.9 (security plan v17-v20, §15 item 18): the macOS weekly "updates
/// are waiting" message — pure rules, the read-only evaluation against a
/// fake Mac, wording, and the service against a fake channel.
extension LocalToolsSelftest {
    typealias MU = MacUpdates

    static func muItem(_ key: String, kind: MU.Kind = .formula, name: String? = nil) -> MU.Item {
        MU.Item(key: key, kind: kind, toolId: nil, name: name ?? key, installed: "1.0", available: "1.1",
                command: kind == .formula || kind == .cask ? String(key.split(separator: ":").last ?? "") : nil)
    }

    static func muEval(_ waiting: [MU.Item], resolved: [String] = [], complete: Bool = true, at: Date = LTF.now) -> MU.Evaluation {
        MU.Evaluation(at: at, waiting: waiting, resolved: resolved, complete: complete, catalogueAsOf: at,
                      softwareUpdateAsOf: at, tools: [], problems: [])
    }

    static let muDest = UpdateNotice.Destination(channelKind: "telegram", chatId: "1", channelGeneration: 0)

    static func macUpdatesRulesGroup(_ t: Tally) {
        let day: TimeInterval = 86_400
        var s = MacUpdatesState()
        let a = muItem("brew:ffmpeg"), b = muItem("brew:poppler")
        t.check("rules: a new waiting item with no history is due", MU.sendDue(s, muEval([a]), now: LTF.now))
        MU.consume(&s, muEval([a]), text: "x", noticeGeneration: 0, destination: muDest, now: LTF.now)
        MU.recordOutcome(&s, .accepted, now: LTF.now)
        t.check("rules: a terminal outcome clears the active slot", s.attempt == nil && s.lastOutcome?.outcome == .accepted)
        var bumped = a; bumped.available = "9.9"
        t.check("rules: a version bump of an item still waiting is not new (no weekly repeat)",
                MU.newItems(s, muEval([bumped])).isEmpty && !MU.sendDue(s, muEval([bumped]), now: LTF.now.addingTimeInterval(30 * day)))
        // B arrives at day 4: not before day 7, then A+B.
        t.check("rules: a second item 4 days later waits for the 7-day gate",
                !MU.sendDue(s, muEval([a, b]), now: LTF.now.addingTimeInterval(4 * day)))
        t.check("rules: …and is due at day 7", MU.sendDue(s, muEval([a, b]), now: LTF.now.addingTimeInterval(7 * day)))
        // Unknown evidence keeps a key; positive resolution removes it.
        var u = s
        MU.reconcile(&u, muEval([], resolved: [], complete: false))
        t.check("rules: unreadable/stale inputs never remove a recorded key", u.notified.map(\.key) == ["brew:ffmpeg"])
        MU.reconcile(&u, muEval([], resolved: ["brew:ffmpeg"]))
        t.check("rules: positive resolution removes the key", u.notified.isEmpty)
        t.check("rules: after resolution, a later waiting episode is new again", !MU.newItems(u, muEval([a])).isEmpty)
        // Software Update wildcard.
        var m = MacUpdatesState()
        m.notified = [.init(key: "macos:082-1", at: LTF.now), .init(key: "macos:082-2", at: LTF.now), .init(key: "brew:x", at: LTF.now)]
        MU.reconcile(&m, muEval([muItem("macos:082-2", kind: .macos)], resolved: ["macos:*"]))
        t.check("rules: a fresh Software Update record resolves macOS keys it no longer lists (only those)",
                m.notified.map(\.key) == ["macos:082-2", "brew:x"])
        // Crash after consume.
        var c = MacUpdatesState()
        MU.consume(&c, muEval([a]), text: "x", noticeGeneration: 0, destination: muDest, now: LTF.now)
        t.check("rules: crash after consume → lost, never resent", MU.settleCrashed(&c, now: LTF.now) && c.attempt == nil
                && c.lastOutcome?.outcome == .lost && !MU.sendDue(c, muEval([a]), now: LTF.now.addingTimeInterval(8 * day)))
        // Proven refusal; the user upgraded one item before the retry.
        var r = MacUpdatesState()
        MU.consume(&r, muEval([a, b]), text: "x", noticeGeneration: 0, destination: muDest, now: LTF.now)
        MU.recordOutcome(&r, .refused(retryAfter: 1), now: LTF.now)
        t.check("rules: a proven refusal keeps the attempt for a bounded retry", r.attempt?.state == .refused
                && MU.retryDecision(r, now: LTF.now.addingTimeInterval(2), noticeGeneration: 0, channelGeneration: { _ in 0 }) == .retry)
        t.check("rules: …dropped when a consumed item is no longer waiting", !MU.stillValid(r.attempt!, muEval([b])))
        t.check("rules: …dropped when the notice generation changed (OFF / deletion)",
                MU.retryDecision(r, now: LTF.now.addingTimeInterval(2), noticeGeneration: 1, channelGeneration: { _ in 0 }) == .drop)
        MU.recordOutcome(&r, .ambiguous, now: LTF.now)
        t.check("rules: an ambiguous outcome is terminal (no retry)", r.attempt == nil && r.lastOutcome?.outcome == .ambiguous)
        // Clock moved back.
        var k = MacUpdatesState(); k.lastMessageAt = LTF.now.addingTimeInterval(10 * day)
        MU.clampClock(&k, now: LTF.now)
        t.check("rules: lastMessageAt > 1 day in the future is clamped to now (counts as just sent)",
                k.lastMessageAt == LTF.now && !MU.sendDue(k, muEval([a]), now: LTF.now.addingTimeInterval(day)))
        macUpdatesOverflowGroup(t)
    }

    static func macUpdatesOverflowGroup(_ t: Tally) {
        let day: TimeInterval = 86_400
        let many = (0..<65).map { muItem(String(format: "macos:%03d", $0), kind: .macos) }
        var s = MacUpdatesState()
        MU.consume(&s, muEval(many), text: "x", noticeGeneration: 0, destination: muDest, now: LTF.now)
        MU.recordOutcome(&s, .accepted, now: LTF.now)
        t.check("overflow: 65 waiting keys → 64 recorded, quietOverflow set in the consume", s.notified.count == 64 && s.quietOverflow != nil)
        var resent = false
        for week in 1...3 {
            // Restart: the state is decoded from disk between cycles.
            s = try! LocalAdvisoryStore.decoder().decode(MacUpdatesState.self, from: LocalAdvisoryStore.encoder().encode(s))
            MU.reconcile(&s, muEval(many, complete: week != 2))
            if MU.sendDue(s, muEval(many), now: LTF.now.addingTimeInterval(Double(week) * 7 * day)) { resent = true }
        }
        t.check("overflow: three weekly cycles with a restart and an unreadable week never resend the set", !resent && s.quietOverflow != nil)
        var shrink = s
        MU.reconcile(&shrink, muEval(Array(many.suffix(10))))
        t.check("overflow: a small set still holding the omitted key keeps the flag", shrink.quietOverflow != nil
                && !MU.sendDue(shrink, muEval(Array(many.suffix(10))), now: LTF.now.addingTimeInterval(30 * day)))
        var contained = s
        MU.reconcile(&contained, muEval(Array(many.prefix(10))))
        t.check("overflow: a complete, fitting set entirely recorded clears the flag (and is not news)",
                contained.quietOverflow == nil && MU.newItems(contained, muEval(Array(many.prefix(10)))).isEmpty)
        var incomplete = s
        MU.reconcile(&incomplete, muEval(Array(many.prefix(10)), complete: false))
        t.check("overflow: an incomplete evaluation never clears the flag", incomplete.quietOverflow != nil)
        var empty = s
        MU.reconcile(&empty, muEval([], resolved: ["macos:*"]))
        t.check("overflow: a fresh empty set resolves everything and clears the flag", empty.notified.isEmpty && empty.quietOverflow == nil)
        let bytes = (try? LocalAdvisoryStore.encoder().encode(s))?.count ?? .max
        t.check("overflow: a full state stays under the 64 KiB cap", bytes < MacUpdatesStore.maxBytes)
    }

    // MARK: - Evaluation against a fake Mac (files only)

    static func muMachine(catalogue: String? = nil, catalogueAge: TimeInterval = 3600) -> FakeMachine {
        let m = macMachine()
        let cache = "/home/u/Library/Caches/Homebrew/api/internal/packages.arm64_tahoe.jws.json"
        let payload = catalogue ?? #"{"formulae":{"ffmpeg":{"stable_version":"7.1.2"},"poppler":{"stable_version":"25.1.0"}},"casks":{"libreoffice":{"version":"26.8.1","auto_updates":false},"libreoffice-still":{"version":"26.2.6"},"google-chrome":{"version":"156.0","auto_updates":true}}}"#
        m.files[cache] = try! JSONSerialization.data(withJSONObject: ["payload": payload])
        m.mtimes[cache] = LTF.now.addingTimeInterval(-catalogueAge)
        m.dirs["/opt/homebrew/var/homebrew/pinned"] = []
        return m
    }

    static func suPlist(_ entries: [[String: Any]], age: TimeInterval = 3600) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: ["LastSuccessfulDate": LTF.now.addingTimeInterval(-age), "RecommendedUpdates": entries],
                                            format: .xml, options: 0)
    }

    static func addLibreOffice(_ m: FakeMachine, version: String, cask: String? = nil) {
        m.files["/Applications/LibreOffice.app/Contents/Info.plist"] = try! PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        if let cask { m.dirs["/opt/homebrew/Caskroom/\(cask)"] = [version] }
    }

    static func macUpdatesEvaluationGroup(_ t: Tally) {
        let m = muMachine()
        m.files["/Library/Preferences/com.apple.SoftwareUpdate.plist"] = suPlist([["Product Key": "082-83364", "Display Name": "Command Line Tools for Xcode 27.0"]])
        let e = MU.liveEvaluation(m.probe(.macOS), now: LTF.now)
        t.check("evaluate: the used ffmpeg keg 7.1.1_3 < catalogue 7.1.2 → waiting with `brew upgrade ffmpeg`",
                e.waiting.contains { $0.key == "brew:ffmpeg" && $0.command == "ffmpeg" && $0.available == "7.1.2" })
        t.check("evaluate: a fresh Software Update record → a macOS item with its validated name",
                e.waiting.contains { $0.key == "macos:082-83364" && $0.name == "Command Line Tools for Xcode 27.0" })
        t.check("evaluate: brew is never executed and nothing else is run but version probes",
                !m.commands.contains { $0.contains("brew") })
        let cur = muMachine(catalogue: #"{"formulae":{"ffmpeg":{"stable_version":"7.1.1","revision":3}},"casks":{}}"#)
        let ec = MU.liveEvaluation(cur.probe(.macOS), now: LTF.now)
        t.check("evaluate: catalogue equal to the keg → current and positively resolved",
                !ec.waiting.contains { $0.key == "brew:ffmpeg" } && ec.resolved.contains("brew:ffmpeg")
                && ec.tools.contains { $0.toolId == "ffmpeg" && $0.state == .current })
        let stale = muMachine(catalogueAge: 8 * 86_400)
        let es = MU.liveEvaluation(stale.probe(.macOS), now: LTF.now)
        t.check("evaluate: a catalogue older than 7 days → neither waiting nor resolved (unknown)",
                !es.waiting.contains { $0.key == "brew:ffmpeg" } && !es.resolved.contains("brew:ffmpeg") && !es.complete)
        let future = muMachine(catalogueAge: -3 * 3600)
        let ef = MU.liveEvaluation(future.probe(.macOS), now: LTF.now)
        t.check("evaluate: a catalogue dated in the future → unknown", !ef.waiting.contains { $0.key == "brew:ffmpeg" } && !ef.resolved.contains("brew:ffmpeg"))
        let pinned = muMachine()
        pinned.dirs["/opt/homebrew/var/homebrew/pinned"] = ["ffmpeg"]
        let ep = MU.liveEvaluation(pinned.probe(.macOS), now: LTF.now)
        t.check("evaluate: a pinned formula is excluded (brew upgrade skips it) and shown as pinned",
                !ep.waiting.contains { $0.key == "brew:ffmpeg" } && ep.tools.contains { $0.toolId == "ffmpeg" && $0.state == .pinned })
        let head = muMachine()
        head.links["/opt/homebrew/bin/ffmpeg"] = "/opt/homebrew/Cellar/ffmpeg/HEAD-1a2b3c/bin/ffmpeg"
        head.text("/opt/homebrew/Cellar/ffmpeg/HEAD-1a2b3c/INSTALL_RECEIPT.json", #"{"source":{"tap":"homebrew/core","versions":{"head":"HEAD"}}}"#)
        t.check("evaluate: a HEAD keg → unknown, never waiting",
                !MU.liveEvaluation(head.probe(.macOS), now: LTF.now).waiting.contains { $0.key == "brew:ffmpeg" })
        macUpdatesCaskGroup(t)
    }

    static func macUpdatesCaskGroup(_ t: Tally) {
        func lo(_ version: String, cask: String? = nil, catalogue: String? = nil) -> MU.Evaluation {
            let m = muMachine(catalogue: catalogue)
            addLibreOffice(m, version: version, cask: cask)
            return MU.liveEvaluation(m.probe(.macOS), now: LTF.now)
        }
        let caskNewer = lo("26.8.0", cask: "libreoffice")
        t.check("cask: Caskroom 26.8.0 < catalogue 26.8.1 → waiting with `brew upgrade --cask libreoffice`",
                caskNewer.waiting.contains { $0.key == "cask:libreoffice" && $0.command == "libreoffice" })
        let auto = muMachine(catalogue: #"{"formulae":{"ffmpeg":{"stable_version":"7.1.2"}},"casks":{"libreoffice":{"version":"26.8.1","auto_updates":true}}}"#)
        addLibreOffice(auto, version: "26.8.0", cask: "libreoffice")
        let ea = MU.liveEvaluation(auto.probe(.macOS), now: LTF.now)
        t.check("cask: an auto_updates cask is excluded (and positively resolved)",
                !ea.waiting.contains { $0.key == "cask:libreoffice" } && ea.resolved.contains("cask:libreoffice"))
        let legacy = lo("26.8.0", cask: "libreoffice", catalogue: #"{"formulae":{"ffmpeg":{"stable_version":"7.1.2"}}}"#)
        t.check("cask: a formula-only catalogue → cask unknown (brew is never run to fill it)",
                !legacy.waiting.contains { $0.key == "cask:libreoffice" } && legacy.tools.contains { $0.toolId == "libreoffice" && $0.state == .unknown })
        let unreadable = muMachine()
        addLibreOffice(unreadable, version: "26.8.0")
        unreadable.links["/opt/homebrew/Caskroom/libreoffice"] = "/opt/homebrew/Caskroom/libreoffice"   // exists, unreadable
        let eu = MU.liveEvaluation(unreadable.probe(.macOS), now: LTF.now)
        t.check("cask: an unreadable Caskroom is unknown, never a website install",
                !eu.waiting.contains { $0.key.hasPrefix("app:") } && eu.tools.contains { $0.toolId == "libreoffice" && $0.state == .unknown })
        // Codex's round-17 table (fresh 26.8.1, still 26.2.6).
        let table: [(String, Bool?)] = [("26.8.0.3", true), ("26.8.1.1", false), ("26.2.5.2", true), ("26.2.6.1", false), ("25.8.4.2", true), ("27.0.0.1", false)]
        for (v, want) in table {
            let e = lo(v)
            let waiting = e.waiting.contains { $0.key == "app:libreoffice" }
            let resolved = e.resolved.contains("app:libreoffice")
            t.check("LibreOffice.app \(v) vs fresh 26.8.1 / still 26.2.6 → \(want == true ? "waiting" : "not waiting (resolved)")",
                    want == true ? waiting && !resolved : !waiting && resolved)
        }
        let noCat = muMachine(catalogue: #"{"formulae":{"ffmpeg":{"stable_version":"7.1.2"}},"casks":{"libreoffice":{"version":"26.8.1"}}}"#)
        addLibreOffice(noCat, version: "25.8.4.2")
        let en = MU.liveEvaluation(noCat.probe(.macOS), now: LTF.now)
        t.check("LibreOffice.app: a missing reference line → unknown (no waiting, no resolution)",
                !en.waiting.contains { $0.key == "app:libreoffice" } && !en.resolved.contains("app:libreoffice"))
        // Software Update edge cases.
        let staleSU = MU.softwareUpdate(try! PropertyListSerialization.propertyList(from: suPlist([["Product Key": "082-1"]], age: 8 * 86_400), format: nil) as? [String: Any], now: LTF.now)
        t.check("software update: a record older than 7 days → no evidence", staleSU == nil)
        let badName = MU.softwareUpdate(try! PropertyListSerialization.propertyList(from: suPlist([["Product Key": "082-1", "Display Name": "Evil `rm -rf`"]]), format: nil) as? [String: Any], now: LTF.now)
        t.check("software update: an unsafe display name becomes 'an update'", badName?.entries.first?.name == "an update")
        let badKey = MU.softwareUpdate(try! PropertyListSerialization.propertyList(from: suPlist([["Product Key": "082\n1"]]), format: nil) as? [String: Any], now: LTF.now)
        t.check("software update: an unrecognised product key → no evidence (never a guess)", badKey == nil)
    }

    // MARK: - Wording

    static func macUpdatesWordingGroup(_ t: Tally) {
        let items = [muItem("brew:ffmpeg", name: "ffmpeg"), muItem("brew:poppler", name: "poppler"),
                     MU.Item(key: "cask:libreoffice", kind: .cask, toolId: "libreoffice", name: "LibreOffice", installed: "26.8.0", available: "26.8.1", command: "libreoffice"),
                     muItem("macos:082-1", kind: .macos, name: "Command Line Tools for Xcode 27.0")]
        for lang in ["en", "it"] {
            let msg = MacUpdatesText.message(items, lang: lang).lowercased()
            t.check("wording[\(lang)]: no security claim (no vulnerab/safe/CVE/fix/sicur)",
                    !["vulnerab", "safe", "cve", " fix", "sicur"].contains { msg.contains($0) })
        }
        let en = MacUpdatesText.message(items, lang: "en")
        t.check("wording: one command from the local names", en.contains("`brew upgrade ffmpeg poppler && brew upgrade --cask libreoffice`"))
        t.check("wording: a macOS line follows ('also')", en.contains("macOS also has updates waiting (Command Line Tools for Xcode 27.0)"))
        let suOnly = MacUpdatesText.message([items[3]], lang: "en")
        t.check("wording: a Software-Update-only message has its own opening", suOnly.hasPrefix("⬆️ macOS has updates waiting"))
        let bad = MU.Item(key: "brew:x", kind: .formula, toolId: nil, name: "x", installed: nil, available: nil, command: "x; rm -rf /")
        t.check("wording: an invalid formula name never reaches the command", !MacUpdatesText.message([bad], lang: "en").contains("rm -rf"))
        let thirty = (0..<30).map { muItem("brew:f\($0)", name: "f\($0)") }
        let big = MacUpdatesText.message(thirty, lang: "en")
        t.check("wording: ≤ 8 names, ≤ 20 command names, then 'and N more'",
                big.contains("and 22 more") && big.contains("f19") && !big.contains("f20 ") && big.contains("…and 10 more: see /status"))
        let app = MU.Item(key: "app:libreoffice", kind: .app, toolId: "libreoffice", name: "LibreOffice", installed: "25.8.4.2", available: "26.2.6", command: nil)
        let appMsg = MacUpdatesText.message([app], lang: "en")
        t.check("wording: LibreOffice.app → Help → Check for Updates or the download link, no command",
                appMsg.contains("Help → Check for Updates") && appMsg.contains("https://www.libreoffice.org/download/") && !appMsg.contains("brew"))
    }
}

/// The weekly-message service against a fake channel (temp roots only).
extension LocalToolsSelftest {
    @MainActor
    static func macUpdatesServiceGroup(_ t: Tally) async {
        let root = LTF.tempDir("macupdates")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = LTF.paths(root).notice
        var now = LTF.now
        var evaluation = muEval([muItem("brew:ffmpeg", name: "ffmpeg")])
        var sent: [String] = []
        var outcome: UpdateNotice.SendOutcome = .accepted
        var idle = true
        let svc = MacUpdatesService(deps: .init(
            paths: p, now: { now }, evaluate: { evaluation }, language: { "en" }, isIdle: { idle },
            destination: { muDest }, channelGeneration: { _ in 0 },
            send: { _, _, _, text in sent.append(text); return outcome }, log: { _ in }))
        idle = false
        await svc.tick()
        t.check("service: never sends while a turn runs", sent.isEmpty)
        idle = true
        await svc.tick()
        t.check("service: one message for a new waiting item", sent.count == 1 && sent[0].contains("brew upgrade ffmpeg"))
        await svc.tick()
        now = now.addingTimeInterval(8 * 86_400)
        await svc.tick()
        t.check("service: the unchanged set is never resent (also after 8 days)", sent.count == 1)
        evaluation = muEval([muItem("brew:ffmpeg", name: "ffmpeg"), muItem("brew:poppler", name: "poppler")])
        now = now.addingTimeInterval(1)
        await svc.tick()
        t.check("service: a new item after the 7-day gate → one message with the whole set",
                sent.count == 2 && sent[1].contains("brew upgrade ffmpeg poppler"))
        evaluation = muEval([muItem("brew:ffmpeg", name: "ffmpeg"), muItem("brew:poppler", name: "poppler"), muItem("brew:pandoc", name: "pandoc")])
        now = now.addingTimeInterval(3 * 86_400)
        await svc.tick()
        t.check("service: a third item 3 days later waits for the gate", sent.count == 2)
        // Ambiguous: never resent.
        outcome = .ambiguous
        now = now.addingTimeInterval(5 * 86_400)
        await svc.tick()
        now = now.addingTimeInterval(8 * 86_400)
        await svc.tick()
        t.check("service: an ambiguous send is never repeated", sent.count == 3)
        // Store failure: nothing sent.
        evaluation = muEval([muItem("brew:git", name: "git")])
        now = now.addingTimeInterval(8 * 86_400)
        LocalAdvisoryStore.failWritesForTesting = true
        await svc.tick()
        LocalAdvisoryStore.failWritesForTesting = false
        t.check("service: a failed state write sends nothing (fail-closed)", sent.count == 3)
        // OFF.
        try? UpdateNoticeStore.setEnabled(false, paths: p, now: now)
        await svc.tick()
        t.check("service: /upgradecheck off → no message", sent.count == 3)
        try? UpdateNoticeStore.setEnabled(true, paths: p, now: now)
        // Deletion removes the file.
        try? UpdateNoticeStore.wipeDerivedState(paths: p, now: now)
        t.check("service: /deleteuserdata deletes macupdates.json", !FileManager.default.fileExists(atPath: MacUpdatesStore.url(p).path))
        let mode = { () -> Int? in
            try? MacUpdatesStore.transaction(p, now: now) { _, s in s.lastMessageAt = now }
            return (try? FileManager.default.attributesOfItem(atPath: MacUpdatesStore.url(p).path))?[.posixPermissions] as? Int
        }()
        t.check("service: macupdates.json is written mode 0600", mode == 0o600)
    }
}
