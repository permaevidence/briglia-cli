import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension SIWCSelftest {
    /// File discipline (§3.1): owner-only, bounded, malformed preserved.
    static func storeTests(_ root: URL, _ c: Checks) async throws {
        let (store, _, generation) = try await activeStore(root)
        c.check("store: three owner-only files plus the lock", [store.tokenFile, store.registrationsFile, store.keyFile].allSatisfy { url in
            var st = stat(); return stat(url.path, &st) == 0 && st.st_mode & 0o077 == 0 })
        c.check("store: the legacy auth file is never created", !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(SubscriptionEndpoint.storeName).path))
        c.check("store: a fresh sign-in is usable", (try? store.validate(clientId: "oaiappClientA", generation: generation)) != nil)
        let raw = try String(contentsOf: store.tokenFile, encoding: .utf8)
        c.check("store: the token file holds no raw sub (keyed identity only)", !raw.contains("user-sub-A"))
        chmod(store.tokenFile.path, 0o644)
        c.check("store: a group/world-readable token file is refused", (try? store.readTokens()) == nil)
        chmod(store.tokenFile.path, 0o600)
        let good = try Data(contentsOf: store.tokenFile)
        _ = try PrivateStorage.writeAtomically(Data("{not json".utf8), to: store.tokenFile)
        c.check("store: a malformed token file is refused", (try? store.readTokens()) == nil)
        await c.rejects("store: a malformed file is never overwritten") { try store.writeTokens(SIWCTokenFile()) }
        c.check("store: malformed bytes preserved", try Data(contentsOf: store.tokenFile) == Data("{not json".utf8))
        _ = try PrivateStorage.writeAtomically(good, to: store.tokenFile)
        // Pending ownership (§3.8).
        let p1 = try await store.beginPending(owner: "work")
        await c.rejectsKind("pending: one per store; another assistant is refused", .busy) { _ = try await store.beginPending(owner: "health") }
        let p2 = try await store.beginPending(owner: "work")
        c.check("pending: the owner may supersede its own", p1 != p2 && (try! store.readTokens()?.pendingLogin) == p2)
        c.check("pending: a foreign cancel is refused", (try await store.cancelOwnedPending(profile: "health")) == .foreign)
        c.check("pending: the owner cancels", (try await store.cancelOwnedPending(profile: "work")) == .cancelled
                && (try! store.readTokens()?.pendingLogin) == nil)
        var clocked = store
        _ = try await store.beginPending(owner: "work")
        clocked.clock = { Date().addingTimeInterval(SIWCEndpoint.attemptLifetime + 5) }
        c.check("pending: an expired marker is cleared by the next start", (try? await clocked.beginPending(owner: "health")) != nil)
        c.check("pending: no pending sign-in blocks requests on the current generation",
                (try? store.validate(clientId: "oaiappClientA", generation: generation)) != nil)
        _ = try await store.cancelOwnedPending(profile: "health")
        // Several registrations, never mixed (§3.1).
        let store2 = SIWCStore(directory: root.appendingPathComponent("multi"))
        let paths2 = hostPaths(root.appendingPathComponent("hp-multi"), stores: [store2.directory])
        _ = try await signIn(store2, paths2, clientId: "oaiappClientA", new: true, tokens: tokens("A"))
        _ = try await signIn(store2, paths2, clientId: "oaiappClientB", sub: "user-sub-B", new: true, tokens: tokens("B"))
        let both = try store2.readTokens()!
        c.check("store: two registrations keep separate records and clients", both.records.count == 2
                && both.record("oaiappClientA")?.tokens?.access == "synthetic-access-A" && both.record("oaiappClientB")?.tokens?.access == "synthetic-access-B")
        c.check("store: saving never moves the active pointer", (try store2.readRegistrations()?.active) == nil)
        await c.rejects("store: a new registration cannot reuse an existing client") {
            try await signIn(store2, paths2, clientId: "oaiappClientA", new: true, tokens: tokens("A2"))
        }
        await c.rejects("store: a returning sign-in with another sub is refused") {
            try await signIn(store2, paths2, clientId: "oaiappClientA", sub: "user-sub-Z", new: false, tokens: tokens("Z"))
        }
        c.check("store: a refused sign-in changed nothing", try store2.readTokens()!.record("oaiappClientA")?.tokens?.access == "synthetic-access-A")
    }

    /// v2.8/v2.9: every bound field changed alone → sign-in required, no
    /// refresh sent; unbound fields don't matter; never repaired.
    static func bindingTests(_ root: URL, _ c: Checks) async throws {
        typealias Change = (inout SIWCTokenRecord) -> Void
        let cases: [(String, Change)] = [
            ("access token", { $0.tokens!.access += "x" }),
            ("refresh token", { $0.tokens!.refresh += "x" }),
            ("ID token", { $0.tokens!.idToken = "other.id.token" }),
            ("token type", { $0.tokens!.tokenType = "bearer" }),
            ("scopes", { $0.tokens!.scopes.append("extra") }),
            ("expiry", { $0.tokens!.expiresAt += 1 }),
            ("earliest refresh", { $0.tokens!.earliestRefreshAt = 1 }),
            ("identity sub", { $0.identity!.subKey = String(repeating: "a", count: 64) }),
            ("identity account", { $0.identity!.accountKey = String(repeating: "b", count: 64) }),
            ("owner field", { $0.signedInBy = "other" }),
            ("requiresLogin", { $0.requiresLogin = false }),
            ("invalidClient", { $0.invalidClient = false }),
            ("binding version", { $0.bindingVersion = 2 }),
            ("binding removed", { $0.binding = nil }),
            ("binding malformed", { $0.binding = "zz" + String(repeating: "0", count: 62) }),
            ("staged replacement", { $0.staged = SIWCStagedReplacement(replacementId: UUID().uuidString, tokens: SIWCSelftest.tokens("S"),
                identity: $0.identity!, hostFingerprint: String(repeating: "c", count: 64), generationToBe: UUID().uuidString) }),
        ]
        for (label, change) in cases {
            let fake = FakeAuth()
            fake.tokenReplies = [tokenReply("never")]
            let (store, _, generation) = try await activeStore(root, tokens: tokens("A", expiresIn: 10))
            try tamper(store, "oaiappClientA", change)
            let unusable: Bool
            do { try store.validate(clientId: "oaiappClientA", generation: generation); unusable = false }
            catch let e as SIWCError { unusable = e.kind == .signInRequired } catch { unusable = false }
            var refreshSent = false
            do { _ = try await store.credential(clientId: "oaiappClientA", generation: generation,
                    refresh: SIWCSignIn.refresher(auth: fake.client, clientId: "oaiappClientA", previousScopes: SIWCEndpoint.fullScopes)) }
            catch { refreshSent = fake.tokenCount() > 0 }
            c.check("binding: \(label) changed alone → sign-in required, refresh never sent", unusable && !refreshSent && fake.tokenCount() == 0)
        }
        // Unbound fields: savedAt, lastEffect, cleanup.
        let (store, _, generation) = try await activeStore(root)
        try tamper(store, "oaiappClientA") { $0.savedAt = 1; $0.lastEffect = SIWCEffectMark(attempt: UUID().uuidString, effectId: UUID().uuidString); $0.cleanup = ["old-token"] }
        c.check("binding: informational and cleanup fields are outside the binding", (try? store.validate(clientId: "oaiappClientA", generation: generation)) != nil)
        // Registration sub changed: identity disagrees.
        var regs = try store.readRegistrations()!
        regs.registrations[0].sub = "user-sub-OTHER"
        _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(regs), to: store.registrationsFile)
        c.check("binding: a registration whose sub changed makes the record unusable", (try? store.validate(clientId: "oaiappClientA", generation: generation)) == nil)
        // Missing key: unusable, and never re-created while records exist.
        let (s2, p2, g2) = try await activeStore(root)
        try FileManager.default.removeItem(at: s2.keyFile)
        c.check("binding: a missing integrity key leaves the record unusable", (try? s2.validate(clientId: "oaiappClientA", generation: g2)) == nil)
        await c.rejects("binding: the key is never re-created while records exist") {
            try await signIn(s2, p2, clientId: "oaiappClientC", sub: "user-sub-C", new: true, tokens: tokens("C"))
        }
        c.check("binding: no repair happened on load", (try? s2.validate(clientId: "oaiappClientA", generation: g2)) == nil
                && !FileManager.default.fileExists(atPath: s2.keyFile.path))
        // A new sign-in into a fresh store makes it usable again (no repair path needed).
        let (s3, _, g3) = try await activeStore(root)
        c.check("binding: an intact record works after a reload", (try? s3.validate(clientId: "oaiappClientA", generation: g3)) != nil)
    }

    /// Host ID lifetime (§3.8 R5, D24).
    static func hostTests(_ root: URL, _ c: Checks) async throws {
        let storeA = SIWCStore(directory: root.appendingPathComponent("default"))
        let storeB = SIWCStore(directory: root.appendingPathComponent("extra-own"))
        let paths = hostPaths(root.appendingPathComponent("machine"), stores: [storeA.directory, storeB.directory])
        let now = Int(Date().timeIntervalSince1970)
        let first = try SIWCHost.reserve(paths, attemptId: "a1", profile: "default", storePath: storeA.directory.path, ownerLease: nil, now: now)
        c.check("host: created lazily at the first reservation (urn:uuid v4)", SIWCHost.wellFormed(first.hostId) && first.hostId.hasPrefix("urn:uuid:"))
        let second = try SIWCHost.reserve(paths, attemptId: "a2", profile: "work", storePath: storeB.directory.path, ownerLease: nil, now: now)
        c.check("host: one per machine (an own store uses the same host)", first.hostId == second.hostId)
        c.check("host: removal refused while a live reservation exists", try SIWCHost.removeIfUnused(paths, now: now) == .keptInUse
                && FileManager.default.fileExists(atPath: paths.hostFile.path))
        try SIWCHost.release(paths, attemptId: "a1"); try SIWCHost.release(paths, attemptId: "a2")
        _ = try await signIn(storeB, paths, clientId: "oaiappOwn", new: true, tokens: tokens("O"))
        c.check("host: registrations carry the host fingerprint", try storeB.readRegistrations()?.registrations.first?.hostFingerprint == first.fingerprint)
        c.check("host: kept while any store has a registration", try SIWCHost.removeIfUnused(paths, now: now) == .keptInUse)
        // Missing host file with a registration present: refusal, no new ID.
        let saved = try Data(contentsOf: paths.hostFile)
        try FileManager.default.removeItem(at: paths.hostFile)
        c.check("host: a missing host file with users is a refusal, never a new ID",
                (try? SIWCHost.reserve(paths, attemptId: "a3", profile: "default", storePath: storeA.directory.path, ownerLease: nil, now: now)) == nil
                && !FileManager.default.fileExists(atPath: paths.hostFile.path))
        _ = try PrivateStorage.writeAtomically(Data("garbage".utf8), to: paths.hostFile)
        c.check("host: a corrupt host file is a refusal", (try? SIWCHost.reserve(paths, attemptId: "a4", profile: "default", storePath: storeA.directory.path, ownerLease: nil, now: now)) == nil)
        _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(SIWCHost.HostFile(extAgentHostId: "urn:uuid:" + UUID().uuidString.lowercased())), to: paths.hostFile)
        c.check("host: a host disagreeing with a registration is a refusal", (try? SIWCHost.reserve(paths, attemptId: "a5", profile: "default", storePath: storeA.directory.path, ownerLease: nil, now: now)) == nil)
        _ = try PrivateStorage.writeAtomically(saved, to: paths.hostFile)
        // Unreadable extra store: counts as a user.
        _ = try await storeB.retireAll()
        chmod(storeB.registrationsFile.path, 0o644)
        c.check("host: an unreadable store keeps the host", try SIWCHost.removeIfUnused(paths, now: now) == .unreadable)
        chmod(storeB.registrationsFile.path, 0o600)
        _ = try storeB.removeFiles()
        c.check("host: removed after the last registration", try SIWCHost.removeIfUnused(paths, now: now) == .removed
                && !FileManager.default.fileExists(atPath: paths.hostFile.path))
        // Expired reservation: publication refused; expired/dead-owner cleaned.
        let pending = try await storeA.beginPending(owner: nil)
        let h = try SIWCHost.reserve(paths, attemptId: "late", profile: "default", storePath: storeA.directory.path, ownerLease: nil, now: now - 700)
        await c.rejects("host: a callback after the reservation expired is refused, nothing written") {
            _ = try await storeA.save(SIWCSignInResult(clientId: "oaiappLate", newRegistration: true, tokens: tokens("L"), claims: claims()),
                                      pending: pending, attemptId: "late", hostFingerprint: h.fingerprint, hostPaths: paths)
        }
        c.check("host: the refused publication wrote no registration", (try storeA.readRegistrations()) == nil)
        let deadLease = root.appendingPathComponent("dead.lock").path
        _ = try SIWCHost.reserve(paths, attemptId: "dead", profile: "work", storePath: storeB.directory.path, ownerLease: deadLease, now: now)
        _ = try SIWCHost.reserve(paths, attemptId: "next", profile: "default", storePath: storeA.directory.path, ownerLease: nil, now: now)
        let list = try SIWCHost.readReservations(paths).reservations.map(\.attemptId)
        c.check("host: a dead owner's reservation is removed by the next lock holder", !list.contains("dead") && list.contains("next")
                && !list.contains("late"))
        // A wipe during a pending attempt keeps the host for it (R5).
        c.check("host: a wipe during a pending attempt keeps the host", try SIWCHost.removeIfUnused(paths, now: now) == .keptInUse)
        try SIWCHost.release(paths, attemptId: "next")
        c.check("host: wipe with no users removes host and reservations", try SIWCHost.removeIfUnused(paths, now: now) == .removed
                && !FileManager.default.fileExists(atPath: paths.reservationsFile.path))
        _ = try await storeA.cancelOwnedPending(profile: "default")
    }
}
