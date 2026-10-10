import Foundation

/// P1, P2, P4, P8: the main turn's persona is captured once after the
/// complete archive branch and holds for every request and local estimate
/// of the turn, whoever writes the profile mid-turn.
final class PPBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return _value } set { lock.lock(); _value = newValue; lock.unlock() } }
}

extension MidturnHarness {

    /// Where the first two different strings of `values` diverge (diagnostics).
    nonisolated static func ppFirstDifference(_ values: [String]) -> String {
        guard let first = values.first, let other = values.first(where: { $0 != first }) else { return "" }
        let a = Array(first), b = Array(other)
        var i = 0
        while i < min(a.count, b.count) && a[i] == b[i] { i += 1 }
        let lo = max(0, i - 80)
        return " — first difference at \(i): «\(String(a[lo..<min(a.count, i + 120)]))» vs «\(String(b[lo..<min(b.count, i + 120)]))»"
    }

    /// Checks shared by the rows: within the turn (from `mark`), every
    /// main-lane request and every estimate carries `old` and never `new`;
    /// the tool-carrying requests share one system prompt.
    func ppAssertTurnFrozen(_ tag: String, _ capture: PPCapture, since mark: (requests: Int, estimates: Int),
                            old: String, new: String, minRequests: Int = 2, sameSystem: Bool = true) {
        let main = capture.main(since: mark.requests)
        let systems = main.map(Self.ppSystem)
        let estimates = Array(capture.estimates.dropFirst(mark.estimates))
        check("\(tag)a every main-lane request of the turn carries the turn's persona, none the mid-turn write (\(main.count) requests)",
              main.count >= minRequests && systems.allSatisfy { $0.contains(old) }
                && main.allSatisfy { !Self.ppText($0).contains(new) },
              "requests \(main.count), with new \(main.filter { Self.ppText($0).contains(new) }.count), without old \(systems.filter { !$0.contains(old) }.count)")
        if sameSystem {
            let toolSystems = main.filter { Self.ppText($0).contains("\"tools\"") }.map(Self.ppSystem)
            check("\(tag)b the tool-carrying requests' system prompts are byte-identical",
                  toolSystems.count >= minRequests && Set(toolSystems).count == 1,
                  "distinct \(Set(toolSystems).count) of \(toolSystems.count)" + Self.ppFirstDifference(toolSystems))
        }
        check("\(tag)c every local estimate of the turn used the turn's persona (\(estimates.count) estimates)",
              !estimates.isEmpty && estimates.allSatisfy { $0.contains(old) && !$0.contains(new) },
              "with new \(estimates.filter { $0.contains(new) }.count)")
    }

    /// P1 (+P8): background archive mode; the archive's real fact
    /// extraction appends to the profile between round 1 and round 2.
    func ppBackgroundSection() async throws {
        for responses in [false, true] {
            let tag = responses ? "P1r" : "P1"
            let a = Self.ppSentinel("A"), b = Self.ppSentinel("B")
            let (manager, router, capture, done) = try await ppStart(responses: responses)
            try ppSetProfile(Self.ppProfile(a))
            manager._testSeedHistory(Self.ppArchiveHistory())
            router.extractionReply = "- \(b) newly learned durable fact"
            let landed = PPBox(false)
            router.onMain = { n, _ in
                if n == 1 { landed.value = Self.ppBlockUntil(60) { Self.ppStoredProfile().contains(b) } }
            }
            router.push([(id: "\(tag)-1", name: "bash", args: ["command": "echo one"])])
            router.push([(id: "\(tag)-2", name: "bash", args: ["command": "echo two"])])
            router.pushText("turn one done")
            let mark = capture.mark()
            let resetsBefore = capture.scopeResets
            await ppTurn(manager, "\(tag) turn one")
            check("\(tag)0 the background archive's fact extraction wrote the profile during round 1",
                  landed.value && router.extractions >= 1, "extractions \(router.extractions)")
            ppAssertTurnFrozen(tag, capture, since: mark, old: a, new: b, minRequests: 3)
            check("P8\(responses ? "r" : "") the mid-turn store write no longer resets the active-turn scope (measured prompt tokens kept)",
                  capture.scopeResets == resetsBefore, "resets \(capture.scopeResets - resetsBefore)")
            _ = await waitUntil(timeout: 60) { manager._baJobOutcome == "succeeded" }
            router.onMain = nil
            router.pushText("turn two done")
            let next = capture.mark()
            await ppTurn(manager, "\(tag) turn two")
            let first = capture.main(since: next.requests).first.map(Self.ppSystem) ?? ""
            check("\(tag)d the next turn adopts the new profile", first.contains(b) && first.contains(a), String(first.prefix(160)))
            done()
        }
    }

    /// P2: a profile-maintenance CAS commit and a direct /setname-equivalent
    /// store write mid-turn.
    func ppWritersSection() async throws {
        // (a) Maintenance CAS commit (real maintainUserContextIfNeeded run).
        do {
            let tag = "P2m"
            let a = Self.ppSentinel("A"), c = Self.ppSentinel("C")
            let (manager, router, capture, done) = try await ppStart()
            try? FileManager.default.removeItem(at: UserContextMaintenance.stateURL)
            // The archived-history section's retired-facts pointer is read
            // per request and appears with the FIRST retired record (once
            // per install; outside the persona snapshot, reported
            // separately). Seed one so this row isolates the persona.
            if !RetiredUserFacts.hasRecords() {
                try FileManager.default.createDirectory(at: RetiredUserFacts.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{\"line\":\"seeded synthetic retired fact\"}\n".utf8).write(to: RetiredUserFacts.url)
            }
            let profile = Self.ppProfile(a, facts: 420)
            try ppSetProfile(profile)
            router.maintenanceReply = "{\"drop\":[\((1...380).map(String.init).joined(separator: ","))],\"add\":[{\"text\":\"\(c) kept by maintenance\"}]}"
            let committed = PPBox(false)
            router.onMain = { n, _ in
                guard n == 1 else { return }
                let finished = DispatchSemaphore(value: 0)
                Task.detached {
                    await ConversationArchiveService().maintainUserContextIfNeeded(event: .archive)
                    finished.signal()
                }
                _ = finished.wait(timeout: .now() + 60)
                committed.value = Self.ppStoredProfile().contains(c)
            }
            router.push([(id: "\(tag)-1", name: "bash", args: ["command": "echo one"])])
            router.push([(id: "\(tag)-2", name: "bash", args: ["command": "echo two"])])
            router.pushText("turn one done")
            let mark = capture.mark()
            await ppTurn(manager, "\(tag) turn one")
            check("\(tag)0 profile maintenance committed (CAS) during round 1",
                  committed.value && router.maintenanceRequests >= 1 && Self.ppStoredProfile().count < profile.count,
                  "maintenance requests \(router.maintenanceRequests), size \(Self.ppStoredProfile().count)")
            ppAssertTurnFrozen(tag, capture, since: mark, old: a, new: c, minRequests: 3)
            let systems = capture.main(since: mark.requests).map(Self.ppSystem)
            check("\(tag)e the whole pre-maintenance profile stayed in every request of the turn",
                  !systems.isEmpty && systems.allSatisfy { $0.contains(MarkerNeutralizer.escape(profile)) })
            router.onMain = nil
            router.pushText("turn two done")
            let next = capture.mark()
            await ppTurn(manager, "\(tag) turn two")
            let first = capture.main(since: next.requests).first.map(Self.ppSystem) ?? ""
            check("\(tag)d the next turn adopts the maintained profile", first.contains(c) && !first.contains(MarkerNeutralizer.escape(profile)))
            try? FileManager.default.removeItem(at: UserContextMaintenance.stateURL)
            done()
        }
        // (b) Direct store write of the user name (the /setname store).
        do {
            let tag = "P2n"
            let a = Self.ppSentinel("A"), name = "Name-" + Self.ppSentinel("N")
            let (manager, router, capture, done) = try await ppStart()
            try ppSetProfile(Self.ppProfile(a))
            try? KeychainHelper.delete(key: KeychainHelper.userNameKey)
            router.onMain = { n, _ in
                if n == 1 { try? KeychainHelper.save(key: KeychainHelper.userNameKey, value: name) }
            }
            router.push([(id: "\(tag)-1", name: "bash", args: ["command": "echo one"])])
            router.push([(id: "\(tag)-2", name: "bash", args: ["command": "echo two"])])
            router.pushText("turn one done")
            let mark = capture.mark()
            await ppTurn(manager, "\(tag) turn one")
            ppAssertTurnFrozen(tag, capture, since: mark, old: a, new: name, minRequests: 3)
            router.onMain = nil
            router.pushText("turn two done")
            let next = capture.mark()
            await ppTurn(manager, "\(tag) turn two")
            let first = capture.main(since: next.requests).first.map(Self.ppSystem) ?? ""
            check("\(tag)d the next turn adopts the new user name", first.contains("The user's name is \(name)."))
            try? KeychainHelper.delete(key: KeychainHelper.userNameKey)
            done()
        }
    }

    /// P4: `/archiveinline on` — the inline archive's profile write lands
    /// before the capture, so the same turn's first request already has it
    /// (0.2.52 parity).
    func ppInlineSection() async throws {
        let tag = "P4"
        let a = Self.ppSentinel("A"), b = Self.ppSentinel("B")
        let (manager, router, capture, done) = try await ppStart()
        let channel = SVRecordingChannel(kind: .telegram)
        manager._svRegisterChannel(channel)
        manager._svSetLastUserAddress(ChannelAddress(kind: .telegram, chatId: "1234567"))
        _ = await manager.handleTerminalCommand("/archiveinline on")
        try ppSetProfile(Self.ppProfile(a))
        manager._testSeedHistory(Self.ppArchiveHistory())
        router.extractionReply = "- \(b) learned by the inline archive"
        router.push([(id: "\(tag)-1", name: "bash", args: ["command": "echo one"])])
        router.pushText("turn one done")
        let mark = capture.mark()
        await ppTurn(manager, "\(tag) turn one")
        let main = capture.main(since: mark.requests)
        let systems = main.map(Self.ppSystem)
        check("\(tag)a inline archive: the profile written by its fact extraction is in the same turn's first request",
              router.extractions >= 1 && !systems.isEmpty && systems.allSatisfy { $0.contains(b) && $0.contains(a) },
              "extractions \(router.extractions), requests \(main.count)")
        check("\(tag)b and in every estimate of that turn",
              capture.estimates.dropFirst(mark.estimates).allSatisfy { $0.contains(b) })
        _ = await manager.handleTerminalCommand("/archiveinline off")
        done()
    }
}
