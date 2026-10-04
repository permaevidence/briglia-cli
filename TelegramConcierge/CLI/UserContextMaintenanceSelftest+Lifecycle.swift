import Foundation

/// Rows I1–I4 (unchanged extraction alongside maintenance), E8/I3 (one
/// archive event's order; consolidation makes no maintenance request),
/// L1–L3 (the maintenance window is bracketed by the phase the existing
/// barrier waits on), M1–M4 (Mind and deletion), X1.
extension UserContextMaintenanceSelftest {

    static func interactionRows(_ h: UCMHarness) async throws {
        let p45 = UCMHarness.profile(size: 45_000)
        // I1: an extraction-style load → append → save during the model call.
        var archive = try h.fresh(profile: p45)
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        UserContextMaintenance.testHooks?.afterSnapshot = { _ in
            let fresh = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
            try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: fresh + "\nLearned during the model call: plays piano")
        }
        _ = await h.event(archive)
        UserContextMaintenance.testHooks?.afterSnapshot = nil
        h.check("I1 extraction append during maintenance's model call → CAS conflict: appended fact present, nothing retired",
                h.profile.hasSuffix("Learned during the model call: plays piano") && h.profile.count > 45_000 && h.retired().isEmpty)
        h.script([UCMHarness.dropOps(for: h.profile, toBelow: 29_000)])
        h.check("I1 the next eligible event retries with fresh numbering", await h.event(archive) == 1 && h.profile.count <= 30_000)

        // I2: extraction after a commit appends to the committed text.
        let committed = h.profile
        h.extractionReply = "Learned after maintenance: likes hiking"
        _ = try await archive.archiveMessages(chunkMessages("i2"))
        h.check("I2 extraction after a maintenance commit appends to the committed profile",
                h.profile == committed + "\nLearned after maintenance: likes hiking")

        // I4: a setup-style write (KeychainHelper.save) between snapshot and commit.
        archive = try h.fresh(profile: p45)
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        UserContextMaintenance.testHooks?.afterSnapshot = { _ in
            try? KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: "Rewritten by setup")
        }
        _ = await h.event(archive)
        UserContextMaintenance.testHooks?.afterSnapshot = nil
        h.check("I4 a profile edit by another writer → conflict, the edit survives", h.profile == "Rewritten by setup")

        // I3 / E8: one archive event with extraction + backlog + maintenance +
        // consolidation, in that order; consolidation makes no maintenance request.
        archive = try h.fresh(profile: "- small profile fact\n")
        _ = await archive.clearAllArchives()   // no temporaries left over from earlier rows
        h.resetHooks()
        var start = Date(timeIntervalSince1970: 1_790_000_000)
        h.extractionReply = "@HTTP:500"                       // first chunk's extraction fails → backlog
        _ = try await archive.archiveMessages(chunkMessages("c1", start: start))
        h.extractionReply = "NO_CHANGES"
        for index in 2...4 {
            start = start.addingTimeInterval(3600)
            _ = try await archive.archiveMessages(chunkMessages("c\(index)", start: start))
        }
        // c2's event already drained the backlog; queue one more failure (5th
        // temporary) so the 6th chunk's event drains it and then consolidates.
        h.extractionReply = "@HTTP:500"
        start = start.addingTimeInterval(3600)
        _ = try await archive.archiveMessages(chunkMessages("c5b", start: start))
        try h.setProfile(p45)
        h.extractionReply = "NO_CHANGES"
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        h.server.clear()
        start = start.addingTimeInterval(3600)
        _ = try await archive.archiveMessages(chunkMessages("c6", start: start))
        let kinds: [String] = h.server.requests.map { request in
            let system = UCMHarness.systemText(request.body)
            if system.contains(h.maintenanceMarker) { return "M" }
            if system.contains(h.extractionMarker) { return "X" }
            return "S"
        }
        let joined = kinds.joined()
        h.check("I3 order: summary → extraction → backlog extraction → maintenance → consolidation summary",
                joined.hasPrefix("SXXM") && joined.dropFirst(4).allSatisfy { $0 == "S" } && joined.count >= 5, joined)
        h.check("E8 consolidation happened and made no maintenance request after it",
                await archive.getAllChunks().contains { $0.type == .consolidated } && !joined.dropFirst(4).contains("M"), joined)
        let rewriteAsks = h.server.requests.filter { UCMHarness.systemText($0.body).contains("reorganizing an AI assistant's persistent memory") }
        h.check("E8 no full-profile rewrite request anywhere", rewriteAsks.isEmpty)
    }

    static func lifecycleRows(_ h: UCMHarness) async throws {
        let p45 = UCMHarness.profile(size: 45_000)
        // L1–L3: the run is bracketed by the maintenance phase the manager's
        // barrier (beginMindRestore) refuses on, from before the snapshot to
        // after the commit.
        let archive = try h.fresh(profile: p45)
        final class Phases: @unchecked Sendable {
            private let lock = NSLock(); private var log: [(String, Bool)] = []
            func add(_ entry: (String, Bool)) { lock.lock(); log.append(entry); lock.unlock() }
            var last: (String, Bool)? { lock.lock(); defer { lock.unlock() }; return log.last }
            var restructuringActive: Bool { last.map { $0.0.contains("restructuring") && $0.1 } ?? false }
        }
        let phases = Phases()
        await archive.setMaintenancePhaseHandler { phase, began in phases.add(("\(phase)", began)) }
        var activeDuringModelCall = false
        var activeAtCommit = false
        UserContextMaintenance.testHooks?.afterSnapshot = { _ in
            activeDuringModelCall = phases.restructuringActive
        }
        UserContextMaintenance.testHooks?.beforeProfileCommit = {
            activeAtCommit = phases.restructuringActive
        }
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        _ = await h.event(archive)
        h.check("L1–L3 the maintenance phase is active from before the model call through the commit, and ends after",
                activeDuringModelCall && activeAtCommit && phases.last.map { $0.0.contains("restructuring") && !$0.1 } == true)
        UserContextMaintenance.testHooks?.afterSnapshot = nil
        UserContextMaintenance.testHooks?.beforeProfileCommit = nil

        // M1: full and lite Mind exports carry both files; import restores them 0600.
        let retiredBytes = try Data(contentsOf: h.retiredURL)
        let stateBytes = try Data(contentsOf: h.stateURL)
        for scope in [MindExportService.ExportScope.full, .lite] {
            let backup = FileManager.default.temporaryDirectory.appendingPathComponent("ucm-\(scope.rawValue)-\(UUID().uuidString).mind")
            try await MindExportService.shared.exportMind(to: backup, scope: scope)
            try FileManager.default.removeItem(at: h.retiredURL)
            try FileManager.default.removeItem(at: h.stateURL)
            let staged = try await MindExportService.shared.stageMind(from: backup)
            try await MindExportService.shared.applyStagedMind(staged)
            await archive.reloadFromDisk()
            var st = stat()
            _ = stat(h.retiredURL.path, &st)
            h.check("M1 \(scope.rawValue) Mind round trip restores the retired and state files byte-identical, 0600",
                    (try? Data(contentsOf: h.retiredURL)) == retiredBytes && (try? Data(contentsOf: h.stateURL)) == stateBytes
                    && st.st_mode & 0o777 == 0o600)
            try? FileManager.default.removeItem(at: backup)
        }
        let withFile = await OpenRouterService().formatChunkSummaries([sampleItem()], totalChunkCount: 1)
        h.check("W-RET the archive prompt mentions the retired file once it exists", withFile.contains("retired_user_facts.jsonl"))

        // M2: an old Mind (no state, no retired file) → defaults, cleanup pending.
        try FileManager.default.removeItem(at: h.retiredURL)
        try FileManager.default.removeItem(at: h.stateURL)
        h.check("M2 no state file → defaults (cleanup pending)", h.state() == .absent)
        let noFile = await OpenRouterService().formatChunkSummaries([sampleItem()], totalChunkCount: 1)
        h.check("W-RET no retired file → no prompt line", !noFile.contains("retired_user_facts"))
        try PrivateStorage.writeAtomically(Data(), to: h.retiredURL)
        let emptyFile = await OpenRouterService().formatChunkSummaries([sampleItem()], totalChunkCount: 1)
        h.check("W-RET an empty retired file → no prompt line", !emptyFile.contains("retired_user_facts"))
        try FileManager.default.removeItem(at: h.retiredURL)

        // M4: /deleteuserdata removes every maintenance file and the legacy key.
        h.script([UCMHarness.dropOps(for: h.profile, toBelow: 29_000)])
        try h.setProfile(p45)
        _ = await h.event(archive)
        try PrivateStorage.writeAtomically(Data("{}\n".utf8), to: h.archiveDir.appendingPathComponent("retired_user_facts.2025.jsonl"))
        UserDefaults.standard.set(true, forKey: UserContextMaintenance.legacyRetryFlagKey)
        let failures = await archive.clearAllArchives()
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: h.archiveDir.path)) ?? []).filter { $0.contains("retired") || $0.contains("user_context_state") }
        h.check("M4 clearAllArchives removes the retired file(s), the state file and the legacy key",
                failures.isEmpty && left.isEmpty && UserDefaults.standard.object(forKey: UserContextMaintenance.legacyRetryFlagKey) == nil, "\(left) \(failures)")
        if geteuid() != 0 {
            try PrivateStorage.writeAtomically(Data("{\"version\":1}\n".utf8), to: h.stateURL)
            chmod(h.archiveDir.path, 0o500)
            let blocked = await archive.clearAllArchives()
            chmod(h.archiveDir.path, 0o700)
            h.check("M4 a removal failure is reported to /deleteuserdata, not swallowed", !blocked.isEmpty, "\(blocked)")
            try? FileManager.default.removeItem(at: h.stateURL)
        }
    }

    static func sampleItem() -> ArchivedSummaryItem {
        ArchivedSummaryItem(id: UUID(), kind: .temporaryChunk, startDate: Date(timeIntervalSince1970: 1_790_000_000),
                            endDate: Date(timeIntervalSince1970: 1_790_003_600), tokenCount: 100, messageCount: 2,
                            summary: "A fixture summary.", sourceChunkCount: 1)
    }
}
