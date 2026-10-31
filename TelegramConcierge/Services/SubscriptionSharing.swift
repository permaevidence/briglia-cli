import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// One ChatGPT login for every assistant (MULTI_ASSISTANT_PLAN §25, owner
/// decision D18).
///
/// - The machine store IS default's existing `subscription-auth.json` (and
///   its lock, which already makes one refresher plus re-readers across
///   processes). Extras use it unless their `subscription_login_scope` is
///   `own`; default always uses it. A never-multi install resolves exactly
///   today's directory and writes no new key or field.
/// - A selection is bound to one login generation plus, in multi mode, the
///   SHA-256 fingerprint of its account. A re-sign-in elsewhere to the SAME
///   account is picked up automatically (rebind); a DIFFERENT account is
///   never used silently: the user must choose ChatGPT again in this
///   assistant (D18).
/// - Pending sign-ins carry their owner profile; cancellation entry points
///   cancel only their own (a pending login without an owner is default's).
enum SubscriptionSharing {
    static let scopeKey = "subscription_login_scope"
    static let accountFingerprintKey = "subscription_account_fp"

    enum Scope: String { case shared, own }

    // MARK: Resolver (§25.2–§25.3)

    /// The selected profile's scope (default always shares: it owns the store).
    static func scope(stored: [String: String] = KeychainHelper.loadSnapshot()) -> Scope {
        guard AssistantProfile.isExtra else { return .shared }
        return stored[scopeKey] == Scope.own.rawValue ? .own : .shared
    }

    /// The directory of the store this assistant uses.
    static func storeDirectory() -> URL {
        if AssistantProfile.isDefault { return StoragePaths.configRoot }
        return scope() == .own ? StoragePaths.configRoot : MachinePaths.defaultConfigRoot()
    }

    static var machineStoreDirectory: URL { MachinePaths.defaultConfigRoot() }

    /// Both stores this assistant must protect (file tools, redaction):
    /// the machine store and its own (identical for default).
    static func protectedStoreDirectories() -> [URL] {
        var out = [machineStoreDirectory]
        if StoragePaths.configRoot.standardizedFileURL.path != machineStoreDirectory.standardizedFileURL.path {
            out.append(StoragePaths.configRoot)
        }
        return out
    }

    /// The owner tag for pending/signed-in fields: nil in never-multi mode,
    /// so the auth file stays byte-identical there.
    static var ownerTag: String? { CoordinationMode.multi ? AssistantProfile.selectedName : nil }

    static func fingerprint(_ account: String) -> String {
        SHA256.hash(data: Data("chatgpt-account:\(account)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sharers (§25.11 counting rule)

    /// Every profile that uses the machine store: default always; every extra
    /// unless its own secrets explicitly say `own` (unreadable = counted:
    /// fail safe means "do not sign out"). Registry records plus any extra
    /// directory on disk.
    static func sharers(registryPaths: AssistantRegistry.Paths = .live,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var names = Set(AssistantProfile.listExtras(environment: environment))
        if let doc = (try? AssistantRegistry.read(registryPaths)) ?? nil {
            names.formUnion(doc.records.map(\.name).filter { $0 != AssistantProfile.defaultName })
        }
        var out = [AssistantProfile.defaultName]
        for name in names.sorted() {
            let file = AssistantProfile.extraConfigRoot(name, environment: environment).appendingPathComponent("secrets.json")
            if let data = try? Data(contentsOf: file),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if object[scopeKey] as? String == Scope.own.rawValue { continue }
            }
            out.append(name)
        }
        return out
    }

    static func displayNames(_ profiles: [String]) -> [String] {
        let doc = (try? AssistantRegistry.read(.live)) ?? nil
        return profiles.map { p in doc?.record(p)?.displayName ?? (p == AssistantProfile.defaultName ? "Bree" : p) }
    }

    /// "This ChatGPT sign-in is used by: Bree, Work." (nil with one sharer).
    static func sharingSentence(signOut: Bool = false) -> String? {
        guard CoordinationMode.multi, scope() == .shared else { return nil }
        let names = displayNames(sharers())
        guard names.count >= 2 else { return nil }
        let list = names.joined(separator: ", ")
        return signOut
            ? "This signs ChatGPT out for every assistant that shares it: \(list). / Questo disconnette ChatGPT per tutti gli assistenti che lo condividono: \(list)."
            : "This ChatGPT sign-in is used by: \(list). / Questo accesso a ChatGPT è usato da: \(list)."
    }

    /// `/provider` and doctor line with several assistants (§25.7).
    static func scopeStatus() -> String? {
        guard CoordinationMode.multi else { return nil }
        if scope() == .own { return "own login" }
        let others = displayNames(sharers().filter { $0 != AssistantProfile.selectedName })
        return others.isEmpty ? "shared login" : "shared login (also used by \(others.joined(separator: ", ")); usage limits are shared)"
    }

    /// Revocation of a shared login affects every sharer (§25.5).
    static func decorateRevocation(_ message: String) -> String {
        guard CoordinationMode.multi, scope() == .shared, sharers().count >= 2 else { return message }
        return message + sharedRevocationSuffix
    }

    static let sharedRevocationSuffix = " (shared by all assistants that use the shared login) / (condiviso da tutti gli assistenti che usano il login condiviso)"

    // MARK: Rebind (§25.4, §25.13, §25.14 R2-3)

    static func differentAccountMessage(changedBy: String?) -> String {
        let who = changedBy.map { " (changed from ‘\(displayNames([$0]).first ?? $0)’)" } ?? ""
        return "The shared ChatGPT login now belongs to a different account\(who). Choose ChatGPT again to use it (/provider chatgpt). / Il login ChatGPT condiviso ora appartiene a un altro account\(who.isEmpty ? "" : " (modificato da ‘\(displayNames([changedBy!]).first ?? changedBy!)’)"). Scegli di nuovo ChatGPT per usarlo (/provider chatgpt)."
    }

    /// Selftest seam: runs between reading the store and the secrets commit.
    nonisolated(unsafe) static var _testBeforeRebindCommit: (() -> Void)?

    /// The generation a request should use, resolved ONCE before it is sent.
    /// Multi mode only: the same account re-signed in elsewhere → this
    /// assistant's binding is rewritten (conditional secrets transaction
    /// while the auth lock is held) and the new generation is returned; a
    /// different account → D18 error; anything else → `captured` unchanged
    /// (the ordinary validation then refuses a changed login).
    static func resolveGeneration(_ captured: String, store: SubscriptionAuthStore = SubscriptionAuthStore()) async throws -> String {
        guard CoordinationMode.multi else { return captured }
        return try await store.locked { () throws -> String in
            guard let state = try store.read() else { return captured }
            let saved = KeychainHelper.loadSnapshot()
            let bound = saved[ProviderProfiles.subscriptionGenerationKey]
            if state.generation == captured {
                // Lazy fingerprint of a selection made before multi mode.
                if saved[accountFingerprintKey] == nil, bound == captured, let cred = state.credential,
                   state.requiresLogin != true {
                    let fp = fingerprint(cred.account)
                    try KeychainHelper.conditionalTransaction { s in
                        guard s[ProviderProfiles.subscriptionGenerationKey] == captured, s[accountFingerprintKey] == nil else { return }
                        s[accountFingerprintKey] = fp
                    }
                }
                return captured
            }
            guard let cred = state.credential, state.requiresLogin != true, state.pendingLogin == nil else { return captured }
            let newFp = fingerprint(cred.account)
            guard let oldFp = saved[accountFingerprintKey] else {
                // The old identity is unknown: never inferred from the new
                // credential; the user chooses explicitly (§25.13).
                throw SubscriptionError(differentAccountMessage(changedBy: state.signedInBy))
            }
            guard oldFp == newFp else { throw SubscriptionError(differentAccountMessage(changedBy: state.signedInBy)) }
            _testBeforeRebindCommit?()
            let scopeNow = scope(stored: saved)
            var rebound = false
            try KeychainHelper.conditionalTransaction { s in
                // Re-check scope, provider binding and the prior binding.
                guard scope(stored: s) == scopeNow, scopeNow == .shared || AssistantProfile.isDefault,
                      s[ProviderProfiles.subscriptionGenerationKey] == bound, s[accountFingerprintKey] == oldFp else { return }
                s[ProviderProfiles.subscriptionGenerationKey] = state.generation
                // Only the ACTIVE ChatGPT runtime slot follows; a saved but
                // inactive selection updates only its saved keys.
                if s[ProviderProfiles.activeProfileKey] == "chatgpt", s[KeychainHelper.openAICompatibleApiKeyKey] == captured {
                    s[KeychainHelper.openAICompatibleApiKeyKey] = state.generation
                }
                rebound = true
            }
            return rebound ? state.generation : captured
        }
    }

    /// The binding keys an explicit selection writes in multi mode.
    static func bindingChanges(for state: SubscriptionAuthState) -> [String: String?] {
        guard CoordinationMode.multi, let cred = state.credential else { return [:] }
        return [accountFingerprintKey: fingerprint(cred.account)]
    }

    // MARK: Pending-login ownership (§25.12)

    /// A pending login belongs to `profile` (no owner field = default's).
    static func pendingOwned(_ state: SubscriptionAuthState, by profile: String = AssistantProfile.selectedName) -> Bool {
        guard state.pendingLogin != nil else { return false }
        return (state.pendingLoginBy ?? AssistantProfile.defaultName) == profile
    }

    static let foreignPendingMessage = "This ChatGPT sign-in was started by another assistant; finish or cancel it there."

    // MARK: Wipe (§25.6, §25.11, §25.14 R2-1)

    struct WipeResult { var failures: [String] = []; var notes: [String] = [] }

    /// `/deleteuserdata`'s ChatGPT step.
    static func wipe(store: SubscriptionAuthStore = SubscriptionAuthStore(),
                     shareLock: () throws -> ProfileFileLock? = { try ChatGPTShare.takeLock() }) async -> WipeResult {
        var result = WipeResult()
        guard CoordinationMode.multi else {
            // Never-multi: unchanged.
            do { if try store.read() != nil { try await store.logout() } }
            catch { result.failures.append("ChatGPT local sign-out: \(error.localizedDescription)") }
            return result
        }
        let lock: ProfileFileLock?
        do { lock = try shareLock() } catch {
            // Without the sharing lock nothing about sharing changes (Codex
            // stage-2 R6): the selection binding is cleared, the scope (and
            // an own store) stay as they are, and the reset is reported.
            clearBinding(&result, removeScope: false)
            if AssistantProfile.isExtra, scope() == .own {
                result.failures.append("ChatGPT (own login) was not reset because another assistant is changing its ChatGPT setting; this assistant keeps its own login — run /deleteuserdata again in a moment")
            } else {
                result.notes.append("ChatGPT was not signed out because another assistant is changing its ChatGPT setting; sign out from the menu.")
            }
            return result
        }
        defer { lock?.release() }
        if AssistantProfile.isExtra {
            if scope() == .own {
                // own → shared: own store out first; on failure the scope stays.
                do {
                    if try store.read() != nil { try await store.logout() }
                } catch {
                    result.failures.append("ChatGPT (own login) sign-out: \(error.localizedDescription); this assistant keeps its own login setting")
                    return result
                }
            }
            clearBinding(&result, removeScope: true)
            let others = displayNames(sharers().filter { $0 != AssistantProfile.selectedName })
            result.notes.append("ChatGPT stays signed in for \(others.joined(separator: ", ")); sign out from the menu to remove it for everyone. / ChatGPT resta connesso per \(others.joined(separator: ", ")); disconnettilo dal menu per rimuoverlo per tutti.")
            return result
        }
        // Default: sign the machine store out only when no extra shares it.
        let others = sharers().filter { $0 != AssistantProfile.defaultName }
        if others.isEmpty {
            do { if try store.read() != nil { try await store.logout() } }
            catch { result.failures.append("ChatGPT local sign-out: \(error.localizedDescription)") }
        } else {
            clearBinding(&result, removeScope: false)
            let names = displayNames(others).joined(separator: ", ")
            result.notes.append("ChatGPT stays signed in for \(names); sign out from the menu to remove it for everyone. / ChatGPT resta connesso per \(names); disconnettilo dal menu per rimuoverlo per tutti.")
        }
        return result
    }

    /// This assistant's own binding: generation, fingerprint, scope key, and
    /// the runtime slot only when it is the active ChatGPT binding.
    /// `removeScope` only under the sharing lock and after an own store was
    /// signed out (the own → shared transition, §25.14 R2-1).
    private static func clearBinding(_ result: inout WipeResult, removeScope: Bool) {
        do {
            try KeychainHelper.conditionalTransaction { s in
                let bound = s[ProviderProfiles.subscriptionGenerationKey]
                s.removeValue(forKey: ProviderProfiles.subscriptionGenerationKey)
                s.removeValue(forKey: accountFingerprintKey)
                if removeScope { s.removeValue(forKey: scopeKey) }
                if s[ProviderProfiles.activeProfileKey] == "chatgpt", let bound, s[KeychainHelper.openAICompatibleApiKeyKey] == bound {
                    s.removeValue(forKey: KeychainHelper.openAICompatibleApiKeyKey)
                }
            }
        } catch {
            result.failures.append("ChatGPT binding: \(error.localizedDescription)")
        }
    }

    // MARK: Scope change (§25.3)

    /// `briglia --profile <n> subscription scope shared|own`. Idle-only:
    /// refused while this assistant runs. Clears the selection binding.
    static func changeScope(to target: Scope) async throws -> String {
        guard AssistantProfile.isExtra else { throw SubscriptionError("The default assistant owns the shared ChatGPT login; it has no separate login.") }
        // Lock order: chatgpt-share.lock → registry.lock (inside). The probe
        // of this profile's assistant leases and the publication of a
        // settings transaction happen in ONE registry critical section, so a
        // starting assistant either is seen (refused) or waits for us
        // (startup admission), for the whole transition (Codex stage-2 R5).
        let lock = try ChatGPTShare.takeLock()
        defer { lock?.release() }
        let ownLease = MemberEntry.current?.uuid
        let tx: AssistantRegistry.SettingsTransaction
        do {
            tx = try AssistantRegistry.beginSettings(profile: AssistantProfile.selectedName, key: "chatgpt_scope") { record in
                let dir = MemberLeases.extraDirectory(record.name, generation: record.generation)
                return MemberLeases.users(dir, assistantsOnly: true, except: ownLease).isEmpty ? nil
                    : "Stop this assistant before changing its ChatGPT login."
            }
        } catch { throw SubscriptionError("\(error)") }
        defer { tx.finish() }
        let current = scope()
        guard current != target else { return "ChatGPT: already \(target == .own ? "its own login" : "the shared login")." }
        // KEYLESS_WEB_AND_LIVE_MENU plan B.4c: a journaled transition, its
        // outcome recoverable from evidence (the own store's `lastAttempt`,
        // the secrets publication marker), never replayed.
        let attempt = UUID().uuidString
        let own = SettingsWriter.authStore(StoragePaths.configRoot.path)
        let direction = target == .shared ? "own->shared" : "shared->own"
        // Decision point: own→shared signs the own store out first (when it
        // exists); shared→own never signs the shared store out.
        let oldOwn: SubscriptionAuthState?
        do { oldOwn = try own.read() } catch { throw SubscriptionError("ChatGPT (own login) can't be read: \(error.localizedDescription); nothing changed") }
        let retire = target == .shared && oldOwn != nil
        var tombstone = SubscriptionAuthState(generation: UUID().uuidString)
        tombstone.lastAttempt = attempt
        let record = SettingsPendingStore.Attempt(attempt: attempt, operation: "scope", category: "ai", ticket: nil,
            clientRequestId: attempt, label: "ChatGPT login scope", authEffect: retire, authKind: retire ? "logout" : nil,
            storePath: StoragePaths.configRoot.path, oldEvidence: SettingsPendingStore.AuthEvidence(oldOwn),
            projectedEvidence: retire ? SettingsPendingStore.AuthEvidence(tombstone) : nil, secretsKeys: [scopeKey],
            steps: ["intent"], direction: direction, retirement: retire ? "own" : "none", startedAt: Date())
        try SettingsPendingStore.update { $0.attempts[attempt] = record }
        func finish(_ state: String, _ message: String?) {
            _ = try? SettingsPendingStore.update { doc in
                doc.attempts.removeValue(forKey: attempt)
                doc.appendResult(.init(ticket: nil, clientRequestId: attempt, category: "ai", label: "ChatGPT login scope",
                                       state: state, message: message, at: Date()))
            }
        }
        if retire {
            let outcome = try await own.locked { own.writePhased(tombstone) }
            switch outcome {
            case .written: break
            case .notWritten(let error):
                _ = try? SettingsPendingStore.update { $0.attempts[attempt]?.steps.append("retire-failed-before-replace") }
                finish("failed", "could not sign out the assistant's own ChatGPT login; nothing changed")
                throw SubscriptionError("Could not sign out this assistant's own ChatGPT login (\(error.localizedDescription)); nothing changed.")
            case .writtenUnconfirmed:
                // Evidence, not the error, decides: re-read under the lock.
                let after = try? await own.locked { try own.read() }
                if after?.lastAttempt == attempt {
                    _ = try? SettingsPendingStore.update { $0.attempts[attempt]?.steps.append("retired-unconfirmed") }
                    finish("partial", "own ChatGPT login was signed out (not confirmed durable); scope still own")
                    throw SubscriptionError("This assistant's own ChatGPT login was signed out (not confirmed durable); its login scope is still its own. Run the command again.")
                }
                finish(after == nil ? "uncertain" : "failed", after == nil ? "the own login's state can't be read" : "nothing changed")
                throw SubscriptionError("Could not confirm the sign-out of this assistant's own ChatGPT login; nothing was published.")
            }
            SettingsSupersede.subscriptionChanged(store: StoragePaths.configRoot.path)
            _ = try? SettingsPendingStore.update { $0.attempts[attempt]?.steps.append("own-retired") }
        }
        // Publish: ONE secrets mutation — binding cleared, scope keys and the
        // publication marker — rechecked against the scope it started from.
        var published = false
        do {
            try KeychainHelper.withStoreLock { holding in
                guard scope(stored: holding.store) == current else { return }
                var change: [String: String?] = [
                    ProviderProfiles.subscriptionGenerationKey: nil,
                    accountFingerprintKey: nil,
                    scopeKey: target == .own ? Scope.own.rawValue : nil,
                    SettingsWriter.scopePublishedKey: attempt,
                ]
                if holding.store[ProviderProfiles.activeProfileKey] == "chatgpt",
                   let bound = holding.store[ProviderProfiles.subscriptionGenerationKey],
                   holding.store[KeychainHelper.openAICompatibleApiKeyKey] == bound {
                    change[KeychainHelper.openAICompatibleApiKeyKey] = .some(nil)
                }
                do { try holding.mutateHolding(change) } catch is PrivateStorage.ReplacedButNotDurable {}
                published = true
            }
        } catch {
            finish(retire ? "partial" : "failed", retire ? "own login signed out; scope still own" : "nothing changed")
            throw SubscriptionError("The new login scope could not be saved (\(error.localizedDescription))" + (retire ? "; this assistant's own login was signed out." : "."))
        }
        guard published else {
            finish(retire ? "partial" : "failed", "settings changed")
            throw SubscriptionError(retire ? "This assistant's own login was signed out, but its scope stays own because settings changed meanwhile." : "Settings changed meanwhile; nothing changed.")
        }
        finish("persisted", nil)
        return target == .own
            ? "This assistant now uses its own ChatGPT login: sign in with `briglia --profile \(AssistantProfile.selectedName) subscription login`."
            : "This assistant now uses the shared ChatGPT login; choose ChatGPT again (/provider chatgpt) to use it."
    }
}
