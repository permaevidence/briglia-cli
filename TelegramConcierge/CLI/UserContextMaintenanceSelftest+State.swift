import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Rows S1–S2 (damaged state, recovery by deletion), E5e/E5f (state-write
/// failures, crash after commit), C1–C7 (commit ordering, retired file).
extension UserContextMaintenanceSelftest {

    struct Injected: Error, LocalizedError {
        let what: String
        var errorDescription: String? { "injected: \(what)" }
    }

    static func stateRows(_ h: UCMHarness) async throws {
        let p45 = UCMHarness.profile(size: 45_000)
        // S1: damaged variants → preserved byte-identical, maintenance suspended, extraction unaffected.
        var variants: [(String, Data)] = [
            ("malformed", Data("{not json".utf8)),
            ("unknown version", Data("{\"version\":2,\"cleanupV1\":\"pending\"}".utf8)),
            ("invalid enum", Data("{\"version\":1,\"cleanupV1\":\"maybe\"}".utf8)),
            ("negative count", Data("{\"version\":1,\"failure\":{\"kind\":\"transient\",\"count\":0,\"nextEligibleAt\":\"2026-10-04T00:00:00.000Z\"}}".utf8)),
            ("huge consecutive", Data("{\"version\":1,\"deferral\":{\"sizeAtDeferral\":1,\"consecutive\":1000001,\"at\":\"2026-10-04T00:00:00.000Z\"}}".utf8)),
            ("bad date", Data("{\"version\":1,\"attempt\":{\"startedAt\":\"yesterday\",\"reason\":\"cleanup\"}}".utf8)),
            ("float id", Data("{\"version\":1.0}".utf8)),
            ("duplicate key", Data("{\"version\":1,\"version\":1}".utf8)),
            ("not UTF-8", Data([0xFF, 0xFE, 0x00])),
        ]
        variants.append(("empty file", Data()))
        for (label, bytes) in variants {
            let archive = try h.fresh(profile: p45)
            try PrivateStorage.writeAtomically(bytes, to: h.stateURL)
            var sends = 0
            for _ in 0..<5 { sends += await h.event(archive) }
            for _ in 0..<3 { sends += await h.event(ConversationArchiveService(), .startupRecovery) }
            let preserved = (try? Data(contentsOf: h.stateURL)) == bytes
            h.check("S1 damaged state (\(label)) → preserved byte-identical, 0 maintenance sends over 5 archives + 3 restarts",
                    preserved && sends == 0, "sends \(sends) preserved \(preserved)")
        }
        // S1: a directory in place of the file (works as root too).
        var archive = try h.fresh(profile: p45)
        try FileManager.default.createDirectory(at: h.stateURL, withIntermediateDirectories: true)
        h.check("S1 a directory at the state path is damage → 0 sends", await h.event(archive) == 0)
        if case .damaged = h.state() {} else { h.check("S1 directory reported damaged", false) }
        let findings = UserContextMaintenance.doctorFindings(profileSize: p45.count)
        h.check("S1 doctor row names the path and the recovery", findings.first.map { $0.problem && $0.text.contains(h.stateURL.path) && ($0.hint ?? "").contains("delete it") } == true)
        try? FileManager.default.removeItem(at: h.stateURL)
        if geteuid() != 0 {
            archive = try h.fresh(profile: p45)
            try PrivateStorage.writeAtomically(try UserContextMaintenanceState().encoded(), to: h.stateURL)
            chmod(h.stateURL.path, 0o000)
            h.check("S1 unreadable (chmod 000) state → 0 sends", await h.event(archive) == 0)
            chmod(h.stateURL.path, 0o600)
        }

        // S1: extraction is unaffected by damaged state (the real archive path).
        archive = try h.fresh(profile: p45)
        try PrivateStorage.writeAtomically(Data("{bad".utf8), to: h.stateURL)
        h.extractionReply = "Learned while state is damaged: likes chess"
        _ = try await archive.archiveMessages(chunkMessages("s1"))
        h.check("S1 extraction still appends while maintenance is paused", h.profile.hasSuffix("Learned while state is damaged: likes chess") && h.maintenanceSends == 0)

        // S2: recovery by deletion.
        try FileManager.default.removeItem(at: h.stateURL)
        h.script([UCMHarness.dropOps(for: h.profile, toBelow: 29_000)])
        let recovered = await h.event(archive)
        h.check("S2 deleting the damaged file: next event loads defaults and the cleanup runs once", recovered == 1 && h.validState?.cleanupV1 == .done)
        // /deleteuserdata clears a damaged file too.
        try PrivateStorage.writeAtomically(Data("{bad".utf8), to: h.stateURL)
        let wipeFailures = await archive.clearAllArchives()
        h.check("S2 /deleteuserdata (clearAllArchives) removes a damaged state file", wipeFailures.isEmpty && !FileManager.default.fileExists(atPath: h.stateURL.path))

        // B46 guard: Briglia never moves a damaged file aside by itself.
        archive = try h.fresh(profile: p45)
        try PrivateStorage.writeAtomically(Data("{bad".utf8), to: h.stateURL)
        for _ in 0..<3 { _ = await h.event(archive) }
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: h.archiveDir.path)) ?? []
        h.check("S1 no automatic move-aside: no backup/renamed copies appear", siblings.filter { $0.hasPrefix("user_context_state") } == ["user_context_state.json"], "\(siblings)")

        // E5e: attempt-record write fails → no model call; then no repeat.
        archive = try h.fresh(profile: p45)
        UserContextMaintenance.testHooks?.beforeStateWrite = { throw Injected(what: "state write") }
        var sends = 0
        for _ in 0..<3 { sends += await h.event(archive) }
        h.check("E5e attempt-record write failure → 0 model calls (suppressed)", sends == 0)
        UserContextMaintenance.testHooks?.beforeStateWrite = nil
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        sends = await h.event(archive)
        h.check("E5e storage back: one local write lifts suppression, then the run happens", sends == 1 && h.validState?.cleanupV1 == .done)

        // E5e: outcome write fails → in-memory outcome authoritative, no repeat.
        archive = try h.fresh(profile: p45)
        h.defaultMaintenanceReply = "{}"
        var writes = 0
        UserContextMaintenance.testHooks?.beforeStateWrite = { writes += 1; if writes >= 2 { throw Injected(what: "outcome write") } }
        sends = await h.event(archive)
        var repeatSends = 0
        for _ in 0..<3 { repeatSends += await h.event(archive) }
        h.check("E5e outcome write failure: no repeat in this process", sends == 2 && repeatSends == 0, "\(sends)/\(repeatSends)")
        UserContextMaintenance.testHooks?.beforeStateWrite = nil
        repeatSends = await h.event(ConversationArchiveService())   // restart: on-disk attempt → one cooldown
        h.check("E5e after restart the leftover attempt costs one cooldown, no immediate repeat",
                repeatSends == 0 && h.validState?.failure?.kind == .transient && h.validState?.attempt == nil)

        // E5f: crash after the commit, before the outcome → cooldown, no double processing.
        archive = try h.fresh(profile: p45)
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        writes = 0
        UserContextMaintenance.testHooks?.beforeStateWrite = { writes += 1; if writes >= 2 { throw Injected(what: "crash before outcome") } }
        _ = await h.event(archive)
        let committed = h.profile
        UserContextMaintenance.testHooks?.beforeStateWrite = nil
        let retiredCount = h.retired().count
        sends = await h.event(ConversationArchiveService())
        h.check("E5f crash after commit: profile committed once, restart converts the attempt to a cooldown, no second run",
                committed.count <= 30_000 && sends == 0 && h.retired().count == retiredCount)
    }

    /// One small chunk of conversation for real archive events.
    static func chunkMessages(_ label: String, start: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> [Message] {
        (0..<4).map { index in
            Message(role: index % 2 == 0 ? .user : .assistant,
                    content: "\(label)-\(index): an ordinary archived exchange about plans and preferences.",
                    timestamp: start.addingTimeInterval(TimeInterval(index * 60)))
        }
    }

    static func commitRows(_ h: UCMHarness) async throws {
        let base = UCMHarness.profile(size: 45_000)
        func union(_ profile: String, _ retired: [RetiredUserFacts.Record]) -> Bool {
            let lines = Set(UserProfileDocument(profile).lines.map(\.raw)).union(retired.map(\.line))
            return UserProfileDocument(base).lines.filter { $0.kind == .fact }.allSatisfy { lines.contains($0.raw) }
        }
        // C1: crash between the retired append and the profile write.
        var archive = try h.fresh(profile: base)
        h.script([UCMHarness.dropOps(for: base, toBelow: 29_000)])
        UserContextMaintenance.testHooks?.afterRetiredAppend = { throw Injected(what: "crash after append") }
        _ = await h.event(archive)
        h.check("C1 crash after the retired append: profile untouched, every fact in profile ∪ retired",
                h.profile == base && !h.retired().isEmpty && union(h.profile, h.retired()))
        UserContextMaintenance.testHooks?.afterRetiredAppend = nil
        h.clock.advance(2 * 3600)
        h.script([UCMHarness.dropOps(for: base, toBelow: 29_000)])
        _ = await h.event(archive)
        h.check("C1 the retry commits; duplicates in the retired file are harmless", h.profile.count <= 30_000 && union(h.profile, h.retired()))

        // C2: append failure → profile byte-identical.
        archive = try h.fresh(profile: base)
        h.script([UCMHarness.dropOps(for: base, toBelow: 29_000)])
        UserContextMaintenance.testHooks?.beforeRetiredAppend = { throw Injected(what: "append failure") }
        _ = await h.event(archive)
        h.check("C2 retired append failure → profile byte-identical, transient failure", h.profile == base && h.validState?.failure?.kind == .transient)
        UserContextMaintenance.testHooks?.beforeRetiredAppend = nil

        // C3: profile write failure (after the append).
        archive = try h.fresh(profile: base)
        h.script([UCMHarness.dropOps(for: base, toBelow: 29_000)])
        UserContextMaintenance.testHooks?.beforeProfileCommit = { throw Injected(what: "profile write failure") }
        _ = await h.event(archive)
        h.check("C3 profile write failure → profile unchanged, retired holds the copies, transient failure",
                h.profile == base && union(h.profile, h.retired()) && h.validState?.failure?.kind == .transient)
        UserContextMaintenance.testHooks?.beforeProfileCommit = nil

        // C4: CAS conflict from a second writer during the model call.
        archive = try h.fresh(profile: base)
        h.script([UCMHarness.dropOps(for: base, toBelow: 29_000)])
        UserContextMaintenance.testHooks?.afterSnapshot = { _ in
            try? KeychainHelper.transaction { $0[KeychainHelper.structuredUserContextKey] = base + "- appended by another writer\n" }
        }
        _ = await h.event(archive)
        h.check("C4 a concurrent write → conflict: nothing saved, the other writer's fact kept, nothing retired",
                h.profile == base + "- appended by another writer\n" && h.retired().isEmpty)
        h.check("C4 conflict clears only the attempt (no failure, no deferral)",
                h.validState.map { $0.attempt == nil && $0.failure == nil && $0.deferral == nil } == true)
        UserContextMaintenance.testHooks?.afterSnapshot = nil

        // C5: torn tail.
        archive = try h.fresh(profile: base)
        try PrivateStorage.writeAtomically(Data("{\"v\":1,\"at\":\"x\",\"li".utf8), to: h.retiredURL)
        h.script([UCMHarness.dropOps(for: base, toBelow: 29_000)])
        _ = await h.event(archive)
        let read = try RetiredUserFacts.read()
        let tornBytes = try Data(contentsOf: h.retiredURL)
        h.check("C5 a torn fragment is kept and skipped; the new batch starts on its own line",
                read.skipped == 1 && !read.records.isEmpty && tornBytes.starts(with: Data("{\"v\":1,\"at\":\"x\",\"li\n".utf8)))

        // C5b: encoding round trip.
        let tricky = "- real CR at end\r\n- literal \\r and \\\\ backslash\n- \"quotes\" and\ttab and \u{7} bell\n- emoji 👩‍👩‍👧 e\u{301}\n- last without newline"
        let doc = UserProfileDocument(tricky)
        let all = doc.apply(.init(drop: Array(1...doc.factCount)))
        let url = h.archiveDir.appendingPathComponent("c5b.jsonl")
        try? FileManager.default.removeItem(at: url)
        try RetiredUserFacts.append(RetiredUserFacts.records(from: all.retired, pass: 1, at: Date()), to: url)
        let back = try RetiredUserFacts.read(from: url).records
        h.check("C5b every original line round-trips exactly (real CR vs literal \\r, quotes, tab, control, emoji, combining, last line without \\n)",
                back.map(\.originalText).joined() == tricky + (tricky.hasSuffix("\n") ? "" : ""), back.map(\.line).description)
        try? FileManager.default.removeItem(at: url)

        // C6: format, 0600, survives the archive cleanup paths.
        var st = stat()
        _ = stat(h.retiredURL.path, &st)
        h.check("C6 retired file is 0600 JSON Lines (sorted keys, v/at/source/op/section/line/nl)",
                st.st_mode & 0o777 == 0o600
                && ((try? String(contentsOf: h.retiredURL, encoding: .utf8)) ?? "").contains("\"line\":") )
        let before = try Data(contentsOf: h.retiredURL)
        let reloaded = ConversationArchiveService()
        await reloaded.recoverPendingChunks(defaultContext: .empty)   // runs reconcile + backfill
        try? await Task.sleep(nanoseconds: 300_000_000)
        h.check("C6 retired and state files survive reconcile/backfill (startup recovery)",
                (try? Data(contentsOf: h.retiredURL)) == before && FileManager.default.fileExists(atPath: h.stateURL.path))

        // C7: no trimming past 4 MiB.
        archive = try h.fresh(profile: base)
        let line = try RetiredUserFacts.Record(at: "2026-10-04T00:00:00Z", source: "setup", op: "dropped", section: "",
                                               line: "- " + String(repeating: "x", count: 1000), followedByNewline: true).jsonLine()
        var big = Data(); for _ in 0..<(5 * 1024) { big.append(line) }
        try PrivateStorage.writeAtomically(big, to: h.retiredURL)
        h.script([UCMHarness.dropOps(for: base, toBelow: 29_000)])
        _ = await h.event(archive)
        let after = try Data(contentsOf: h.retiredURL)
        h.check("C7 a >4 MiB retired file is never trimmed: old bytes kept as the prefix", after.count > big.count && after.starts(with: big))
    }
}
