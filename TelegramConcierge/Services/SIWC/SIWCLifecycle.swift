import Foundation

// Stage C lifecycle pieces of Sign in with ChatGPT (SIWC plan §3.8):
// file-tool protection, the process's auth activity (upgrade pause and
// quiescence), and the `/deleteuserdata` step with the host-file rule (D24).

// MARK: - File tools (§3.8 "File tools and redaction")

enum SIWCProtectedFiles {
    static let refusal = "Briglia's ChatGPT sign-in files can't be read or changed with file tools; use `briglia subscription status` or the menu."

    /// Every SIWC file of every protected store (token, registrations, key,
    /// lock) and the machine host and reservation files.
    static func paths(storeDirectories: [URL] = SubscriptionSharing.protectedStoreDirectories(),
                      hostPaths: SIWCHost.Paths = .live) -> [URL] {
        var out: [URL] = []
        for dir in storeDirectories {
            for name in SIWCEndpoint.storeFileNames { out.append(dir.appendingPathComponent(name)) }
        }
        out.append(hostPaths.hostFile)
        out.append(hostPaths.reservationsFile)
        return out
    }

    /// The real path, resolving links in the PARENT too when the file
    /// itself does not exist yet (a write that would create it).
    static func canonical(_ url: URL) -> String {
        if FileManager.default.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath().standardizedFileURL.path }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(url.lastPathComponent).path
    }

    static func isProtected(_ path: String, storeDirectories: [URL] = SubscriptionSharing.protectedStoreDirectories(),
                            hostPaths: SIWCHost.Paths = .live) -> Bool {
        let candidate = canonical(URL(fileURLWithPath: path))
        return paths(storeDirectories: storeDirectories, hostPaths: hostPaths).contains { canonical($0) == candidate }
    }
}

// MARK: - This process's auth activity (§3.8 "Upgrade pause", §3.1 Mind)

/// Bounded auth work owned by THIS process: pending sign-in attempts (their
/// verifier lives only here), in-flight refresh settles and in-flight
/// revokes. The upgrade pause treats them as busy; Mind import and wipe
/// cancel only the attempts this process owns.
final class SIWCActivity: @unchecked Sendable {
    static let shared = SIWCActivity()

    private let lock = NSLock()
    private var attempts: [String: (attempt: SIWCAttempt, signIn: SIWCSignIn)] = [:]
    private var settles = 0
    private var revokes = 0

    func register(_ attempt: SIWCAttempt, signIn: SIWCSignIn) {
        lock.lock(); attempts[attempt.id] = (attempt, signIn); lock.unlock()
    }

    func finish(_ attemptId: String) { lock.lock(); attempts[attemptId] = nil; lock.unlock() }

    /// Still owned by this process (not cancelled by quiescence or a wipe).
    func has(_ attemptId: String) -> Bool { lock.lock(); defer { lock.unlock() }; return attempts[attemptId] != nil }

    func beginSettle() { lock.lock(); settles += 1; lock.unlock() }
    func endSettle() { lock.lock(); settles = max(0, settles - 1); lock.unlock() }
    func beginRevoke() { lock.lock(); revokes += 1; lock.unlock() }
    func endRevoke() { lock.lock(); revokes = max(0, revokes - 1); lock.unlock() }

    /// nil = nothing of this kind keeps the process from parking. An
    /// attempt is busy only until its expiry (at most 10 minutes).
    func busyReason(now: Int = Int(Date().timeIntervalSince1970)) -> String? {
        lock.lock(); defer { lock.unlock() }
        if attempts.values.contains(where: { $0.attempt.expiresAt > now }) { return "a ChatGPT sign-in" }
        if settles > 0 { return "a ChatGPT sign-in refresh" }
        if revokes > 0 { return "a ChatGPT sign-out" }
        return nil
    }

    private func owned(store: URL?) -> [(attempt: SIWCAttempt, signIn: SIWCSignIn)] {
        lock.lock(); defer { lock.unlock() }
        let path = store?.standardizedFileURL.path
        return attempts.values.filter { path == nil || $0.attempt.storeDirectory.standardizedFileURL.path == path }
    }

    func ownedAttemptIds() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(attempts.keys) }

    /// Cancel this process's own attempts (all, or those of `store`): their
    /// pending markers and host reservations are cleared.
    func cancelOwned(store: URL? = nil) async {
        let mine = owned(store: store)
        for owned in mine { await owned.signIn.cancel(owned.attempt) }
    }

    func resetForTests() { lock.lock(); attempts = [:]; settles = 0; revokes = 0; lock.unlock() }
}

// MARK: - `/deleteuserdata` (§3.6, §3.8 "Wipe", D24)

enum SIWCWipe {
    struct Context {
        var multi: Bool
        var isExtra: Bool
        var scopeOwn: Bool
        /// This assistant's own config root store.
        var ownStore: SIWCStore
        /// The machine store (default's config root).
        var machineStore: SIWCStore
        /// Display names of the OTHER profiles that use the machine store.
        var otherSharers: () -> [String]
        var hostPaths: SIWCHost.Paths
        var revoke: (SIWCStore.Tombstone) async -> Bool
        /// Remove this assistant's SIWC selection keys.
        var clearSelection: () throws -> Void
        var now: () -> Int = { Int(Date().timeIntervalSince1970) }

        static var live: Context {
            Context(multi: CoordinationMode.multi, isExtra: AssistantProfile.isExtra,
                    scopeOwn: SubscriptionSharing.scope() == .own,
                    ownStore: SIWCStore(directory: StoragePaths.configRoot),
                    machineStore: SIWCStore(directory: MachinePaths.defaultConfigRoot()),
                    otherSharers: { SubscriptionSharing.displayNames(SubscriptionSharing.sharers().filter { $0 != AssistantProfile.selectedName }) },
                    hostPaths: .live,
                    revoke: { tombstone in
                        SIWCActivity.shared.beginRevoke(); defer { SIWCActivity.shared.endRevoke() }
                        return await SIWCSignIn(store: SIWCStore.resolved()).revokeAll(tombstone)
                    },
                    clearSelection: {
                        _ = try KeychainHelper.conditionalTransaction { s in
                            for (k, v) in SIWCSelection.clearDelta(stored: s) { if let v { s[k] = v } else { s.removeValue(forKey: k) } }
                        }
                    })
        }
    }

    struct Result: Equatable {
        var failures: [String] = []
        var notes: [String] = []
        /// The own SIWC store could not be retired: the scope must stay own.
        var ownRetirementFailed = false
    }

    static func hasState(_ store: SIWCStore) -> Bool {
        let tokens = try? store.readTokens(), registrations = try? store.readRegistrations()
        return !(tokens?.records.isEmpty ?? true) || !(registrations?.registrations.isEmpty ?? true)
            || FileManager.default.fileExists(atPath: store.tokenFile.path) || FileManager.default.fileExists(atPath: store.registrationsFile.path)
    }

    /// Sign out and revoke every registration of `store`, then remove its
    /// SIWC files (checked). Registrations metadata is removed with them.
    static func signOutAndRemove(_ store: SIWCStore, _ ctx: Context, label: String, into result: inout Result) async -> Bool {
        guard hasState(store) else { return true }
        let tombstones: [SIWCStore.Tombstone]
        do { tombstones = try await store.retireAll() } catch {
            result.failures.append("\(label) sign-out: \((error as? SIWCError)?.message ?? error.localizedDescription)")
            return false
        }
        var confirmed = true
        for tombstone in tombstones { confirmed = await ctx.revoke(tombstone) && confirmed }
        if !confirmed { result.notes.append(SIWCLogoutOutcome.unconfirmedMessage) }
        let failed = (try? store.removeFiles()) ?? [SIWCEndpoint.tokenFileName]
        if !failed.isEmpty { result.failures.append("\(label): could not remove \(failed.joined(separator: ", "))") }
        return true
    }

    private static func clear(_ ctx: Context, into result: inout Result) {
        do { try ctx.clearSelection() } catch {
            result.failures.append("Sign in with ChatGPT selection: \(error.localizedDescription)")
        }
    }

    /// The own-store retirement of an `own` extra: runs BEFORE the scope is
    /// published back to shared; a failure keeps the scope `own`.
    static func retireOwn(_ ctx: Context, into result: inout Result) async {
        if !(await signOutAndRemove(ctx.ownStore, ctx, label: "Sign in with ChatGPT (own login)", into: &result)) {
            result.ownRetirementFailed = true
            result.failures.append("This assistant keeps its own ChatGPT login setting; run /deleteuserdata again.")
        }
    }

    /// Everything else of the SIWC step, after the legacy step. `shareLocked`
    /// = the caller holds `chatgpt-share.lock` (multi mode); without it,
    /// only this assistant's selection is cleared.
    static func run(_ ctx: Context, shareLocked: Bool, into result: inout Result) async {
        if !ctx.multi {
            _ = await signOutAndRemove(ctx.ownStore, ctx, label: "Sign in with ChatGPT", into: &result)
            clear(ctx, into: &result)
            removeHost(ctx, shareLocked: false, into: &result)
            return
        }
        guard shareLocked else { clear(ctx, into: &result); return }
        if ctx.isExtra {
            // `own` was retired by `retireOwn` before the scope moved.
            clear(ctx, into: &result)
            if hasState(ctx.machineStore) {
                let others = ctx.otherSharers()
                if !others.isEmpty {
                    result.notes.append("Sign in with ChatGPT stays signed in for \(others.joined(separator: ", ")); sign out from the menu to remove it for everyone.")
                }
            }
        } else {
            let others = ctx.otherSharers()
            if others.isEmpty {
                _ = await signOutAndRemove(ctx.machineStore, ctx, label: "Sign in with ChatGPT", into: &result)
            } else if hasState(ctx.machineStore) {
                result.notes.append("Sign in with ChatGPT stays signed in for \(others.joined(separator: ", ")); sign out from the menu to remove it for everyone.")
            }
            clear(ctx, into: &result)
        }
        removeHost(ctx, shareLocked: true, into: &result)
    }

    /// D24: the machine host file goes only when no registration is left in
    /// any store and no live reservation exists.
    static func removeHost(_ ctx: Context, shareLocked: Bool, into result: inout Result) {
        guard FileManager.default.fileExists(atPath: ctx.hostPaths.hostFile.path) else { return }
        do {
            let outcome = shareLocked ? try SIWCHost.removeIfUnusedLocked(ctx.hostPaths, now: ctx.now())
                                      : try SIWCHost.removeIfUnused(ctx.hostPaths, now: ctx.now())
            switch outcome {
            case .removed, .absent: break
            case .keptInUse, .unreadable: result.notes.append(SIWCHost.keptMessage)
            }
        } catch {
            result.notes.append(SIWCHost.keptMessage)
        }
    }
}

// MARK: - Own → shared retirement of an own SIWC store (§3.8 R4, Codex C-R2)

enum SIWCScopeRetire {
    enum Outcome: Equatable {
        /// Every own registration retired durably.
        case retired([SIWCStore.Tombstone])
        /// Retired (visible), durability not confirmed.
        case retiredUnconfirmed([SIWCStore.Tombstone])
        /// Nothing replaced.
        case notRetired(String)
        /// Not known: the journal stays for recovery.
        case unknown(String)
    }

    /// Revocation material of `file` (every refresh token any record held),
    /// kept across a post-replacement error.
    static func revokeMaterial(_ file: SIWCTokenFile?) -> [SIWCStore.Tombstone] {
        (file?.records ?? []).map { record in
            var revoke = record.cleanup ?? []
            if let t = record.tokens?.refresh { revoke.append(t) }
            if let t = record.staged?.tokens.refresh { revoke.append(t) }
            if let t = record.pendingRotation?.tokens.refresh { revoke.append(t) }
            return SIWCStore.Tombstone(clientId: record.clientId, generation: "", revoke: revoke)
        }.filter { !$0.revoke.isEmpty }
    }

    static func retire(_ store: SIWCStore, effect: SIWCJournalEffect, attempt: String, old: SIWCTokenFile?) async -> Outcome {
        do {
            return .retired(try await store.retireAll(effect: effect.mark(attempt: attempt)))
        } catch {
            let why = (error as? SIWCError)?.message ?? "\(error)"
            switch SIWCRecovery.overall(SIWCRecovery.evaluate(effect, attempt: attempt)) {
            case .applied: return .retiredUnconfirmed(revokeMaterial(old))
            case .notApplied, .none: return .notRetired(why)
            case .unknown: return .unknown(why)
            }
        }
    }
}
