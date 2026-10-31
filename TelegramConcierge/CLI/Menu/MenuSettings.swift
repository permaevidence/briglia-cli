import Foundation

/// The menu's writes (KEYLESS_WEB_AND_LIVE_MENU plan Part B): every save is
/// prepared here (validation, probes, listings — nothing written) and
/// committed by the one settings writer — the running Briglia (the live hub
/// in-process, or forwarded over the app socket), or, when Briglia isn't
/// running, this process under the instance lease for the commit only. The
/// menu never holds the instance lease for its lifetime.
enum MenuSettings {
    /// A short human label for /status and the page ("Search key", …).
    static func label(_ request: [String: Any]) -> String {
        if request["provider"] != nil || request["server"] != nil || request["openrouter_pin"] != nil { return "AI model" }
        if let s = request["serper"] as? [String: Any] { return s["remove"] as? Bool == true ? "Serper key removal" : "Serper key" }
        if let s = request["jina"] as? [String: Any] { return s["remove"] as? Bool == true ? "Jina key removal" : "Jina key" }
        if request["openai"] != nil { return "OpenAI key" }
        if request["email_calendar"] != nil { return "Email" }
        if request["telegram"] != nil { return "Telegram" }
        if request["identity"] != nil { return "Your name" }
        if request["assistant"] != nil { return "Assistant name" }
        if request["web"] != nil { return "Free search" }
        if request["web_search_backend"] != nil { return "Page reading backend" }
        if request["mark_complete"] != nil { return "Setup" }
        return "Settings"
    }

    @MainActor
    static func apply(_ request: [String: Any], checkpoint: @escaping () throws -> Void) async -> [String: Any] {
        await SettingsClient.prepareAndCommit(origin: "menu", label: label(request), acceptPending: true, checkpoint: checkpoint) {
            await SetupAPICore.apply(request, ownsLease: true, checkpoint: checkpoint)
        }
    }

    /// Reads (status, probe) and the login network flow (start, poll's
    /// waiting) run directly; select, logout and cancel are commits.
    @MainActor
    static func subscription(_ request: [String: Any], checkpoint: @escaping () throws -> Void) async -> [String: Any] {
        let action = request["action"] as? String ?? ""
        guard ["select", "logout", "cancel", "poll"].contains(action) else {
            return await SubscriptionSetup().perform(request, ownsLease: true, checkpoint: checkpoint)
        }
        let label = action == "logout" ? "ChatGPT sign-out" : action == "select" ? "ChatGPT model" : "ChatGPT sign-in"
        return await SettingsClient.prepareAndCommit(origin: "menu", label: label, acceptPending: true, checkpoint: checkpoint) {
            await SubscriptionSetup().perform(request, ownsLease: true, checkpoint: checkpoint)
        }
    }

    enum Published { case applied(String), pending(String?) }

    /// A sign-in's final step: the publication of the finished login is a
    /// settings commit (plan B.5). The active-login replacement guard and
    /// the pending id are re-checked at the commit's decision point.
    @MainActor
    static func publishLogin(_ write: SubscriptionLogin.Commit,
                             checkpoint: @escaping @Sendable () throws -> Void) async throws -> Published {
        let (change, generation) = try await SettingsCapture.prepareThrowing(origin: "menu", label: "ChatGPT sign-in",
                                                                            acceptPending: true, guardActiveLogin: true) {
            try await write(checkpoint)
        }
        try checkpoint()
        let result = await SettingsClient.commit(change)
        switch result.state {
        case .applied: return .applied(generation)
        case .pending: return .pending(result.message)
        default: throw SubscriptionError(result.message ?? "The sign-in could not be saved.")
        }
    }

    @MainActor
    static func markComplete() async -> Bool {
        let reply = await SettingsClient.prepareAndCommit(origin: "menu", label: "Setup", acceptPending: true) {
            do {
                try KeychainHelper.saveBatch([SetupWizard.completeKey: "true", SetupWizard.progressKey: String?.none])
                return ["schema": SetupAPICore.schemaVersion, "ok": true]
            } catch {
                return SetupAPICore.errorResponse(code: "save_failed", message: "\(error)")
            }
        }
        return reply["ok"] as? Bool == true
    }

    /// Staged and recent results for the page (read from the pending store).
    static func pendingLines(lang: String) -> [String] {
        guard let doc = try? SettingsPendingStore.read() else { return [] }
        func L(_ en: String, _ it: String) -> String { lang == "it" ? it : en }
        var out: [String] = []
        for (_, slot) in doc.slots.sorted(by: { $0.key < $1.key }) {
            if let a = slot.active { out.append(L("Applying: \(a.change.label)…", "Applico: \(a.change.label)…")) }
            if let s = slot.staged {
                out.append(L("Waiting: \(s.change.label) applies when Briglia finishes its current task.",
                             "In attesa: \(s.change.label) si applica quando Briglia finisce il compito in corso."))
            }
        }
        if let last = doc.lastResults.last, Date().timeIntervalSince(last.at) < 600, last.state != "applied", last.state != "persisted" {
            let what: String
            switch last.state {
            case "dropped": what = L("not applied (changed again after you saved it)", "non applicata (cambiata di nuovo dopo il salvataggio)")
            case "uncertain": what = L("result unknown — check it", "esito sconosciuto: controllala")
            case "partial": what = L("only partly saved", "salvata solo in parte")
            case "cancelled": what = L("cancelled", "annullata")
            default: what = L("not saved", "non salvata")
            }
            out.append("\(last.label): \(what)\(last.message.map { " (\($0))" } ?? "")")
        }
        return out
    }
}

/// The offline menu's Telegram pairing step (plan B.9): it holds the
/// instance lease, labelled `menu-pairing`, while the step is open, so a
/// starting daemon can't poll the same bot. Briglia stays off meanwhile.
final class MenuPairingLease: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: InstanceLease?
    var held: Bool { lock.lock(); defer { lock.unlock() }; return lease?.held == true }

    /// Selftest seam.
    var acquireOverride: (() -> Bool)?

    func begin() -> Bool {
        if let acquireOverride { return acquireOverride() }
        lock.lock(); defer { lock.unlock() }
        if lease?.held == true { return true }
        if case .success(let held) = InstanceLease.acquire(label: "menu-pairing") { lease = held; return true }
        return false
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        if let lease, lease.held { lease.release() }
        lease = nil
    }

    /// Hands the held lease to a caller (macOS Start right after pairing).
    func take() -> InstanceLease? {
        lock.lock(); defer { lock.unlock() }
        defer { lease = nil }
        return lease?.held == true ? lease : nil
    }
}
