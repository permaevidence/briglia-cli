import Foundation

/// Stage C: `/deleteuserdata` with several assistants (SIWC plan §3.6,
/// §3.8 "Wipe", D24) and the own → shared scope transition (§3.8, R4).
extension SIWCSelftest {
    final class WipeProbe: @unchecked Sendable {
        var revoked: [String] = []
        var cleared = 0
        var confirm = true
    }

    static func wipeContext(_ root: URL, multi: Bool, isExtra: Bool, scopeOwn: Bool, own: SIWCStore, machine: SIWCStore,
                            others: [String], extraStores: [URL] = [], probe: WipeProbe, paths: SIWCHost.Paths) -> SIWCWipe.Context {
        SIWCWipe.Context(multi: multi, isExtra: isExtra, scopeOwn: scopeOwn, ownStore: own, machineStore: machine,
                         otherSharers: { others }, hostPaths: paths,
                         revoke: { t in probe.revoked.append(t.clientId); return probe.confirm },
                         clearSelection: { probe.cleared += 1 }, now: { Int(Date().timeIntervalSince1970) })
    }

    static func stageCWipeTests(_ root: URL, _ c: Checks) async throws {
        func fixture(_ name: String) -> (machine: SIWCStore, own: SIWCStore, extra: SIWCStore, paths: SIWCHost.Paths) {
            let base = root.appendingPathComponent(name)
            let machine = SIWCStore(directory: base.appendingPathComponent("machine-config"))
            let own = SIWCStore(directory: base.appendingPathComponent("extra-own"))
            let extra = SIWCStore(directory: base.appendingPathComponent("extra-other"))
            let paths = SIWCHost.Paths(machineConfigRoot: machine.directory, machineDir: base.appendingPathComponent("machine"),
                                       storeDirectories: { [machine.directory, own.directory, extra.directory] },
                                       shareLock: base.appendingPathComponent("machine/chatgpt-share.lock"))
            return (machine, own, extra, paths)
        }
        // 1. Never-multi: every registration signed out, revoked, files removed, host removed.
        do {
            let f = fixture("wipe-never")
            _ = try await signIn(f.machine, f.paths, clientId: "oaiappWipe1", sub: "s1", new: true, tokens: tokens("w1"))
            _ = try await signIn(f.machine, f.paths, clientId: "oaiappWipe2", sub: "s2", new: true, tokens: tokens("w2"))
            let probe = WipeProbe()
            var result = SIWCWipe.Result()
            await SIWCWipe.run(wipeContext(root, multi: false, isExtra: false, scopeOwn: false, own: f.machine, machine: f.machine,
                                           others: [], probe: probe, paths: f.paths), shareLocked: false, into: &result)
            c.check("wipe never-multi: every registration revoked", Set(probe.revoked) == ["oaiappWipe1", "oaiappWipe2"])
            c.check("wipe never-multi: the three SIWC files are removed", !FileManager.default.fileExists(atPath: f.machine.tokenFile.path)
                    && !FileManager.default.fileExists(atPath: f.machine.registrationsFile.path) && !FileManager.default.fileExists(atPath: f.machine.keyFile.path))
            c.check("wipe never-multi: the host file is removed (no registration left)", !FileManager.default.fileExists(atPath: f.paths.hostFile.path))
            c.check("wipe never-multi: the selection is cleared, no failure", probe.cleared == 1 && result.failures.isEmpty)
        }
        // 2. Revoke not confirmed: still cleared locally, the note says so.
        do {
            let f = fixture("wipe-unconfirmed")
            _ = try await signIn(f.machine, f.paths, clientId: "oaiappWipe3", new: true, tokens: tokens("w3"))
            let probe = WipeProbe(); probe.confirm = false
            var result = SIWCWipe.Result()
            await SIWCWipe.run(wipeContext(root, multi: false, isExtra: false, scopeOwn: false, own: f.machine, machine: f.machine,
                                           others: [], probe: probe, paths: f.paths), shareLocked: false, into: &result)
            c.check("wipe: remote revoke not confirmed → reported", result.notes.contains(SIWCLogoutOutcome.unconfirmedMessage)
                    && !FileManager.default.fileExists(atPath: f.machine.tokenFile.path))
        }
        // 3. A shared extra: only its own selection; the shared login stays; host kept.
        do {
            let f = fixture("wipe-shared-extra")
            _ = try await signIn(f.machine, f.paths, clientId: "oaiappWipe4", new: true, tokens: tokens("w4"))
            let probe = WipeProbe()
            var result = SIWCWipe.Result()
            await SIWCWipe.run(wipeContext(root, multi: true, isExtra: true, scopeOwn: false, own: f.own, machine: f.machine,
                                           others: ["Bree", "Health"], probe: probe, paths: f.paths), shareLocked: true, into: &result)
            c.check("wipe shared extra: nothing revoked, the shared login stays", probe.revoked.isEmpty
                    && (try? f.machine.readTokens())?.record("oaiappWipe4")?.tokens != nil)
            c.check("wipe shared extra: its own selection is cleared and the note names who keeps it",
                    probe.cleared == 1 && result.notes.contains { $0.contains("Bree, Health") })
            c.check("wipe shared extra: the host file is kept, and says so", FileManager.default.fileExists(atPath: f.paths.hostFile.path)
                    && result.notes.contains(SIWCHost.keptMessage))
        }
        // 4. An own extra: its own store is retired and removed before the scope moves; the machine store stays.
        do {
            let f = fixture("wipe-own-extra")
            _ = try await signIn(f.machine, f.paths, clientId: "oaiappWipe5", new: true, tokens: tokens("w5"))
            _ = try await signIn(f.own, f.paths, clientId: "oaiappWipe6", sub: "s6", new: true, tokens: tokens("w6"))
            let probe = WipeProbe()
            let ctx = wipeContext(root, multi: true, isExtra: true, scopeOwn: true, own: f.own, machine: f.machine,
                                  others: ["Bree"], probe: probe, paths: f.paths)
            var result = SIWCWipe.Result()
            await SIWCWipe.retireOwn(ctx, into: &result)
            c.check("wipe own extra: its own registrations are signed out, revoked and removed", !result.ownRetirementFailed
                    && probe.revoked == ["oaiappWipe6"] && !FileManager.default.fileExists(atPath: f.own.tokenFile.path))
            await SIWCWipe.run(ctx, shareLocked: true, into: &result)
            c.check("wipe own extra: the shared login is untouched", (try? f.machine.readTokens())?.record("oaiappWipe5")?.tokens != nil)
        }
        // 5. An own extra whose store can't be retired: the scope must stay own.
        do {
            let f = fixture("wipe-own-fails")
            _ = try await signIn(f.own, f.paths, clientId: "oaiappWipe7", new: true, tokens: tokens("w7"))
            chmod(f.own.tokenFile.path, 0o644)   // not owner-only: unreadable for the store
            let probe = WipeProbe()
            var result = SIWCWipe.Result()
            await SIWCWipe.retireOwn(wipeContext(root, multi: true, isExtra: true, scopeOwn: true, own: f.own, machine: f.machine,
                                                 others: [], probe: probe, paths: f.paths), into: &result)
            chmod(f.own.tokenFile.path, 0o600)
            c.check("wipe own extra: a failed retirement keeps the scope own and reports it", result.ownRetirementFailed
                    && result.failures.contains { $0.contains("keeps its own ChatGPT login") } && probe.revoked.isEmpty)
        }
        // 6. Default with sharers: nothing signed out; default as last sharer: signed out.
        do {
            let f = fixture("wipe-default")
            _ = try await signIn(f.machine, f.paths, clientId: "oaiappWipe8", new: true, tokens: tokens("w8"))
            let probe = WipeProbe()
            var result = SIWCWipe.Result()
            await SIWCWipe.run(wipeContext(root, multi: true, isExtra: false, scopeOwn: false, own: f.machine, machine: f.machine,
                                           others: ["Health"], probe: probe, paths: f.paths), shareLocked: true, into: &result)
            c.check("wipe default with sharers: the shared login stays, the note names them", probe.revoked.isEmpty
                    && (try? f.machine.readTokens())?.record("oaiappWipe8")?.tokens != nil && result.notes.contains { $0.contains("Health") })
            // An own extra elsewhere still has a registration: host kept (D24).
            _ = try await signIn(f.extra, f.paths, clientId: "oaiappWipe9", sub: "s9", new: true, tokens: tokens("w9"))
            var last = SIWCWipe.Result()
            await SIWCWipe.run(wipeContext(root, multi: true, isExtra: false, scopeOwn: false, own: f.machine, machine: f.machine,
                                           others: [], probe: probe, paths: f.paths), shareLocked: true, into: &last)
            c.check("wipe default as last sharer: the shared login is signed out and removed", probe.revoked == ["oaiappWipe8"]
                    && !FileManager.default.fileExists(atPath: f.machine.tokenFile.path))
            c.check("wipe (D24): the host stays while another store still has a registration", FileManager.default.fileExists(atPath: f.paths.hostFile.path)
                    && last.notes.contains(SIWCHost.keptMessage))
            _ = try await f.extra.retireAll(); _ = try f.extra.removeFiles()
            var final = SIWCWipe.Result()
            SIWCWipe.removeHost(wipeContext(root, multi: true, isExtra: false, scopeOwn: false, own: f.machine, machine: f.machine,
                                            others: [], probe: probe, paths: f.paths), shareLocked: false, into: &final)
            c.check("wipe (D24): removed once no registration is left anywhere", !FileManager.default.fileExists(atPath: f.paths.hostFile.path))
        }
        // 7. A live reservation keeps the host (a sign-in in progress elsewhere).
        do {
            let f = fixture("wipe-reservation")
            _ = try SIWCHost.reserve(f.paths, attemptId: UUID().uuidString, profile: "health", storePath: f.extra.directory.path,
                                     ownerLease: nil, now: Int(Date().timeIntervalSince1970))
            var result = SIWCWipe.Result()
            SIWCWipe.removeHost(wipeContext(root, multi: false, isExtra: false, scopeOwn: false, own: f.machine, machine: f.machine,
                                            others: [], probe: WipeProbe(), paths: f.paths), shareLocked: false, into: &result)
            c.check("wipe (R5): a live host reservation keeps the host", FileManager.default.fileExists(atPath: f.paths.hostFile.path)
                    && result.notes.contains(SIWCHost.keptMessage))
        }
        // 8. Integration: the never-multi `/deleteuserdata` ChatGPT step runs the SIWC step and merges its report.
        do {
            let f = fixture("wipe-integration")
            _ = try await signIn(f.machine, f.paths, clientId: "oaiappWipeI", new: true, tokens: tokens("wI"))
            let probe = WipeProbe(); probe.confirm = false
            let legacy = SubscriptionAuthStore(directory: root.appendingPathComponent("wipe-integration/legacy"))
            let report = await SubscriptionSharing.wipe(store: legacy, siwc: wipeContext(root, multi: false, isExtra: false, scopeOwn: false,
                own: f.machine, machine: f.machine, others: [], probe: probe, paths: f.paths))
            c.check("wipe integration: the SIWC step runs inside the ChatGPT step and its notes are reported",
                    probe.revoked == ["oaiappWipeI"] && report.notes.contains(SIWCLogoutOutcome.unconfirmedMessage))
        }
    }
}
