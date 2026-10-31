import Foundation

/// Crash recovery of the settings writer (KEYLESS_WEB_AND_LIVE_MENU plan B.5,
/// B.4c). Runs at startup before ordinary work and before the first idle
/// apply, and before an offline short commit. Results come from evidence —
/// the auth state's `lastAttempt` and the secrets attempt marker compared
/// with the exact attempt id — never from journal labels alone, and nothing
/// is ever replayed (a logout or an account change is never repeated).
enum SettingsRecovery {
    enum AuthEvidence: String, Equatable { case none, applied, notApplied = "not-applied", unknown }

    struct Report: Equatable {
        var results: [SettingsPendingStore.Result] = []
        var restaged: [String] = []
        var persisted: [String] = []
    }

    /// Ordered, exclusive evidence rules (B.5 rules 0–4).
    static func authEvidence(_ record: SettingsPendingStore.Attempt,
                             read: (String) throws -> SubscriptionAuthState?) -> AuthEvidence {
        guard record.authEffect, let path = record.storePath else { return .none }   // rule 0
        let state: SubscriptionAuthState?
        do { state = try read(path) } catch { return .unknown }                      // rule 1
        if state?.lastAttempt == record.attempt { return .applied }                  // rule 2
        if let old = record.oldEvidence, old.matches(state) { return .notApplied }   // rule 3
        return .unknown                                                              // rule 4
    }

    static func describeAuth(_ record: SettingsPendingStore.Attempt) -> String {
        switch record.authKind {
        case "publish": return "published"
        case "logout": return "signed out"
        case "cancel": return "pending login cancelled"
        default: return "changed"
        }
    }

    /// One attempt → its result (the B.5 table).
    static func classify(_ record: SettingsPendingStore.Attempt, evidence: AuthEvidence, marker: Bool)
        -> (state: String, message: String) {
        switch (evidence, marker) {
        case (.unknown, _):
            return ("uncertain", "Briglia stopped while saving \(record.label); it could not tell what was saved. Check the setting and save it again if needed. Known steps: \(record.steps.joined(separator: ", ")).")
        case (.none, false), (.notApplied, false):
            return ("failed", "interrupted before saving")
        case (.applied, false):
            return ("partial", "partly applied: ChatGPT login \(describeAuth(record)); settings not saved")
        case (.none, true), (.applied, true):
            return ("persisted", "saved (Briglia restarted while applying it)")
        case (.notApplied, true):
            return ("uncertain", "Briglia stopped while saving \(record.label) in an unexpected order; check the setting.")
        }
    }

    /// Recovery could not read its evidence; the journal is unchanged.
    struct RecoveryDeferred: Error, CustomStringConvertible {
        let reason: String
        var description: String { "the settings store can't be read (\(reason)); interrupted settings changes are kept and recovered once it is readable" }
    }

    /// Scope transitions (B.4c truth table), parameterized by direction.
    static func classifyScope(_ record: SettingsPendingStore.Attempt, evidence: AuthEvidence, published: Bool)
        -> (state: String, message: String) {
        let target = record.direction == "own->shared" ? "shared login" : "own login"
        if published { return ("persisted", "ChatGPT now uses the \(target).") }
        if record.retirement == "none" { return ("failed", "nothing changed (scope unchanged)") }
        switch evidence {
        case .applied: return ("partial", "the retired ChatGPT login was signed out; the login scope is unchanged")
        case .notApplied, .none: return ("failed", "nothing changed (login kept, scope unchanged)")
        case .unknown: return ("uncertain", "the ChatGPT login scope change was interrupted; check `briglia subscription scope`")
        }
    }

    /// Recovers every journaled attempt and every claimed-but-not-started
    /// pending apply. `secrets`: the current store (markers).
    @discardableResult
    static func run(secrets provided: [String: String]? = nil,
                    read: (String) throws -> SubscriptionAuthState? = { try SettingsWriter.authStore($0).read() }) throws -> Report {
        guard try SettingsPendingStore.presence() else { return Report() }
        // The markers are evidence: an unreadable store is UNKNOWN, never
        // "no marker" (Codex live-menu R1-6). With attempts to classify,
        // nothing is decided and every record is kept for a later run. Read
        // OUTSIDE the pending lock (lock order: secrets, then pending).
        var secrets: [String: String]? = provided
        if secrets == nil, !((try SettingsPendingStore.read()).attempts.isEmpty) {
            do { secrets = try KeychainHelper.strictSnapshot() } catch { throw RecoveryDeferred(reason: "\(error)") }
        }
        return try SettingsPendingStore.update { doc -> Report in
            var report = Report()
            guard doc.attempts.isEmpty || secrets != nil else { throw RecoveryDeferred(reason: "an attempt appeared while recovering") }
            let secrets = secrets ?? [:]
            for (id, record) in doc.attempts.sorted(by: { $0.value.startedAt < $1.value.startedAt }) {
                let evidence = authEvidence(record, read: read)
                let outcome: (state: String, message: String)
                if record.operation == "scope" {
                    outcome = classifyScope(record, evidence: evidence,
                                            published: secrets[SettingsWriter.scopePublishedKey] == id)
                } else {
                    outcome = classify(record, evidence: evidence,
                                       marker: secrets[SettingsWriter.attemptMarkerKey(record.category)] == id)
                }
                doc.attempts.removeValue(forKey: id)
                if outcome.state == "persisted" { report.persisted.append(id) }
                if record.operation == "pending-apply", var slot = doc.slots[record.category], slot.active?.attempt == id {
                    slot.active = nil
                    doc.slots[record.category] = slot.isEmpty ? nil : slot
                }
                let result = SettingsPendingStore.Result(ticket: record.ticket, clientRequestId: record.clientRequestId,
                    category: record.category, label: record.label, state: outcome.state,
                    message: outcome.message, at: Date())
                doc.appendResult(result)
                report.results.append(result)
            }
            // A pending apply interrupted BEFORE intent (claimed, nothing
            // written) returns to staged.
            for (category, var slot) in doc.slots {
                guard let active = slot.active, doc.attempts[active.attempt] == nil else { continue }
                if slot.staged == nil {
                    slot.staged = .init(ticket: active.ticket, change: active.change, stagedAt: active.claimedAt)
                    report.restaged.append(active.ticket)
                }
                slot.active = nil
                doc.slots[category] = slot
            }
            return report
        }
    }
}
