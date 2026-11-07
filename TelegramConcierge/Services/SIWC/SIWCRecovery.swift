import Foundation

/// Non-secret evidence of one SIWC record or pointer (SIWC plan §3.9
/// "Recovery evidence", round-2 correction): what recovery compares the
/// current state with. Never a token, never a raw `sub`.
struct SIWCRecordEvidence: Codable, Equatable {
    var absent: Bool
    var generation: String?
    var hasTokens: Bool = false
    var staged: String? = nil
    var requiresLogin: Bool = false
    /// The record's (or pointer's) `lastEffect` as "attempt/effectId".
    var lastEffect: String? = nil
    /// Registrations file: the active pointer (registration fingerprint).
    var active: String? = nil
    /// Tokens file: the pending sign-in id.
    var pending: String? = nil

    static func mark(_ m: SIWCEffectMark?) -> String? { m.map { $0.attempt + "/" + $0.effectId } }

    static func record(_ record: SIWCTokenRecord?) -> SIWCRecordEvidence {
        guard let record else { return SIWCRecordEvidence(absent: true, generation: nil) }
        return SIWCRecordEvidence(absent: false, generation: record.generation, hasTokens: record.tokens != nil,
                                  staged: record.staged?.replacementId, requiresLogin: record.requiresLogin == true,
                                  lastEffect: mark(record.lastEffect))
    }

    static func pointer(_ file: SIWCRegistrationsFile?) -> SIWCRecordEvidence {
        SIWCRecordEvidence(absent: file == nil, generation: nil,
                           lastEffect: mark(file?.activeLastEffect),
                           active: file?.active.map { SIWCEndpoint.registrationFingerprint(clientId: $0) })
    }

    static func pendingMarker(_ file: SIWCTokenFile?) -> SIWCRecordEvidence {
        SIWCRecordEvidence(absent: file == nil, generation: nil, pending: file?.pendingLogin)
    }
}

/// One route-qualified durable effect of a settings attempt (§3.9): the
/// exact targets it changes, with their old (and projected) evidence. A
/// grouped effect (several registrations retired in one token-file
/// replacement) lists every target; it is reported applied only when every
/// target is established.
struct SIWCJournalEffect: Codable, Equatable {
    enum Kind: String, Codable {
        /// A login saved (token record or staged replacement).
        case save
        /// Promotion of a staged replacement at activation.
        case promote
        /// The store's active-registration pointer.
        case pointer
        /// A sign-out tombstone.
        case tombstone
        /// Every registration of a store retired in one replacement.
        case retire
        /// A pending sign-in cancelled.
        case cancel
    }
    var effectId: String
    var route = "siwc"
    var kind: Kind
    var storePath: String
    /// "tokens" or "registrations".
    var file: String
    /// Registration fingerprints (`SIWCEndpoint.registrationFingerprint`),
    /// or `["store"]` for the pointer and the pending marker.
    var targets: [String]
    var oldEvidence: [String: SIWCRecordEvidence]
    var projectedEvidence: [String: SIWCRecordEvidence]? = nil

    func mark(attempt: String) -> SIWCEffectMark { SIWCEffectMark(attempt: attempt, effectId: effectId) }
}

/// Per-effect, per-target recovery (§3.9 rules: unreadable → unknown; the
/// exact `(attempt, effectId)` on the target → applied; target equal to its
/// old evidence → not applied; anything else → unknown). A file-level
/// `lastAttempt` is never evidence. Logout and activation are never replayed.
enum SIWCRecovery {
    typealias Evidence = SettingsRecovery.AuthEvidence

    /// Selftest seam: replaces the store reads.
    nonisolated(unsafe) static var readForTesting: ((String) throws -> (SIWCTokenFile?, SIWCRegistrationsFile?))?

    static func read(_ storePath: String) throws -> (SIWCTokenFile?, SIWCRegistrationsFile?) {
        if let readForTesting { return try readForTesting(storePath) }
        let store = SIWCStore(directory: URL(fileURLWithPath: storePath, isDirectory: true))
        return (try store.readTokens(), try store.readRegistrations())
    }

    /// The evidence of each target of `effect` for `attempt`.
    static func evaluate(_ effect: SIWCJournalEffect, attempt: String) -> [String: Evidence] {
        let files: (SIWCTokenFile?, SIWCRegistrationsFile?)
        do { files = try read(effect.storePath) } catch {
            return Dictionary(uniqueKeysWithValues: effect.targets.map { ($0, Evidence.unknown) })
        }
        let mark = SIWCRecordEvidence.mark(effect.mark(attempt: attempt))
        var out: [String: Evidence] = [:]
        for target in effect.targets {
            let current: SIWCRecordEvidence
            switch effect.kind {
            case .pointer: current = .pointer(files.1)
            case .cancel: current = .pendingMarker(files.0)
            default:
                let record = files.0?.records.first { SIWCEndpoint.registrationFingerprint(clientId: $0.clientId) == target }
                current = .record(record)
            }
            if effect.kind == .cancel {
                // The pending marker carries no effect mark: gone (or another
                // id) = cancelled; unchanged = not applied.
                let old = effect.oldEvidence[target]
                out[target] = current.pending == nil || current.pending != old?.pending ? .applied
                    : (current == old ? .notApplied : .unknown)
                continue
            }
            if let mark, current.lastEffect == mark { out[target] = .applied; continue }
            if let old = effect.oldEvidence[target], old == current { out[target] = .notApplied; continue }
            out[target] = .unknown
        }
        return out
    }

    /// One effect's overall evidence: applied only when every target is.
    static func overall(_ targets: [String: Evidence]) -> Evidence {
        let values = Array(targets.values)
        if values.isEmpty { return .none }
        if values.contains(.unknown) { return .unknown }
        if values.allSatisfy({ $0 == .applied }) { return .applied }
        if values.allSatisfy({ $0 == .notApplied }) { return .notApplied }
        return .unknown   // mixed targets of ONE grouped replacement: impossible unless something else wrote
    }

    static func describe(_ kind: SIWCJournalEffect.Kind) -> String {
        switch kind {
        case .save: return "Sign in with ChatGPT login saved"
        case .promote: return "new Sign in with ChatGPT login put in use"
        case .pointer: return "active ChatGPT account switched"
        case .tombstone: return "Sign in with ChatGPT signed out"
        case .retire: return "Sign in with ChatGPT logins signed out"
        case .cancel: return "pending ChatGPT sign-in no longer pending"
        }
    }

    /// The result of one SIWC attempt from its per-effect evidence and the
    /// secrets marker. `needsSecrets`: the attempt also had a secrets write.
    /// Never "nothing changed" when any effect is attributable.
    static func classify(_ record: SettingsPendingStore.Attempt, marker: Bool,
                         evaluate: (SIWCJournalEffect) -> Evidence) -> (state: String, message: String) {
        let effects = record.siwcEffects ?? []
        let evidence = effects.map { ($0, evaluate($0)) }
        let needsSecrets = !record.secretsKeys.isEmpty
        let lines = evidence.map { effect, e -> String in
            let state: String
            switch e {
            case .applied: state = "done"
            case .notApplied: state = "not done"
            case .unknown: state = "unknown"
            case .none: state = "n/a"
            }
            return "\(describe(effect.kind)): \(state)"
        }
        let detail = lines.joined(separator: "; ")
        if evidence.contains(where: { $0.1 == .unknown }) {
            return ("uncertain", "Briglia stopped while saving \(record.label); it could not tell what was saved (\(detail)). Check ChatGPT in the menu.")
        }
        let applied = evidence.filter { $0.1 == .applied }.count
        if applied == 0 {
            if needsSecrets && marker {
                return ("uncertain", "Briglia stopped while saving \(record.label) in an unexpected order; check ChatGPT in the menu.")
            }
            return ("failed", "interrupted before saving")
        }
        if needsSecrets && !marker {
            return ("partial", "partly applied (\(detail)); settings not saved")
        }
        if applied < evidence.count {
            return ("partial", "partly applied (\(detail))")
        }
        return ("persisted", "saved (Briglia restarted while applying it)")
    }

    /// Scope transitions with SIWC retirement (§3.8 "Scope changes", R4):
    /// the scope marker decides publication; otherwise each retired login is
    /// reported separately, never "nothing changed" after an attributable
    /// effect, never "login kept" because a write threw.
    static func classifyScope(_ record: SettingsPendingStore.Attempt, legacy: Evidence, siwc: Evidence,
                              published: Bool) -> (state: String, message: String) {
        let target = record.direction == "own->shared" ? "shared login" : "own login"
        if published { return ("persisted", "ChatGPT now uses the \(target).") }
        func word(_ e: Evidence) -> String {
            switch e {
            case .applied: return "signed out"
            case .notApplied, .none: return "not signed out"
            case .unknown: return "unknown"
            }
        }
        let parts = [record.authEffect ? "Own legacy login \(word(legacy))" : nil,
                     (record.siwcEffects ?? []).isEmpty ? nil : "own Sign in with ChatGPT login \(word(siwc))"].compactMap { $0 }
        let detail = parts.joined(separator: "; ") + "; scope still own."
        if legacy == .unknown || siwc == .unknown {
            return ("uncertain", "The ChatGPT login scope change was interrupted. \(detail) Check `briglia subscription scope`.")
        }
        if legacy == .applied || siwc == .applied { return ("partial", detail) }
        return ("failed", "nothing changed (login kept, scope unchanged)")
    }
}
