import Foundation

/// One-time retirement of the gws email/calendar provider and the WhatsApp
/// bridge (owner decision, 2026-10-24; plan `DROP_GWS_WHATSAPP_PLAN.md` v2).
///
/// Runs in `startPolling`, before `configure()`, in the process that polls.
/// It never sends anything itself: it converts settings, cleans Briglia's
/// own leftovers and records which one-time notice is owed; the notice loop
/// (`ConversationManager+RetiredNotice.swift`) delivers it at most once.
///
/// Never touched: any gws binary, `~/.config/gws/**`, gws keyring entries,
/// anything outside `<dataRoot>/whatsapp-bridge`.
enum RetiredIntegrations {

    // MARK: - State file

    enum Step: String, Codable { case pending, done }
    enum NoticeState: String, Codable { case none, pending, attempted, done }
    enum FolderState: String, Codable { case pending, done, absent }

    /// What a consumed attempt was addressed to (kept for doctor/diagnosis).
    struct Attempt: Codable, Equatable {
        var channelKind: String?
        var chatId: String?
        var channelGeneration: UInt64
        var at: Date
    }

    struct Gws: Codable, Equatable {
        /// Detected through the legacy rule (no stored provider + a gws
        /// binary at a fixed path), so conversion also rewrites an ABSENT
        /// provider to an explicit "none".
        var legacyUnset: Bool
        var conversion: Step
        var notice: NoticeState
        var retryAt: Date?
        var attempt: Attempt?
    }

    struct WhatsApp: Codable, Equatable {
        /// Enabled AND configured before the settings were removed. Captured
        /// in the first write, reused after crashes; only then is a notice owed.
        var wasEnabled: Bool
        var settings: Step
        var folder: FolderState
        /// Recorded BEFORE the first destructive call, so a crash between the
        /// unlink and `done` is recognised and the notice text stays true.
        /// `link`: only the link was removed, its target untouched.
        var topKind: BridgeFolderRemover.TopKind?
        /// Why the folder step is still pending (doctor, notice text B).
        var folderDetail: String?
        var notice: NoticeState
        var retryAt: Date?
        var attempt: Attempt?
    }

    struct State: Codable, Equatable {
        var version: Int
        /// Set in the first write of this build: the legacy gws probe never
        /// runs again (durable negative completion), so a gws installed
        /// later never earns a retirement notice.
        var evaluated: Bool
        var gws: Gws?
        var whatsapp: WhatsApp?
    }

    static let stateVersion = 1
    static let maxStateBytes = 16 * 1024

    enum Loaded: Equatable {
        case absent
        case ok(State)
        /// Unreadable, too large, undecodable or a version this build does
        /// not know: the migration stays inert (never rebuilt automatically,
        /// so a corrupt file can never re-announce anything). Doctor says so.
        case unreadable(String)
    }

    static func load(_ url: URL) -> Loaded {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            return errno == ENOENT ? .absent : .unreadable("cannot stat (\(String(cString: strerror(errno))))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .unreadable("not a regular file") }
        guard Int(st.st_size) <= maxStateBytes else { return .unreadable("larger than \(maxStateBytes) bytes") }
        guard let data = FileManager.default.contents(atPath: url.path) else { return .unreadable("cannot read") }
        guard let state = try? JSONDecoder.retired.decode(State.self, from: data) else { return .unreadable("not valid retirement state") }
        guard state.version == stateVersion else { return .unreadable("unknown version \(state.version)") }
        return .ok(state)
    }

    /// Selftest seam: return true to make this save fail (fault injection).
    nonisolated(unsafe) static var saveFaultForTesting: ((State) -> Bool)?

    struct SaveFault: Error {}

    static func save(_ state: State, to url: URL) throws {
        if saveFaultForTesting?(state) == true { throw SaveFault() }
        let data = try JSONEncoder.retired.encode(state)
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
        try PrivateStorage.writeAtomically(data, to: url)
    }

    // MARK: - Environment (every path, clock and process seam injectable)

    struct Env {
        var dataRoot: URL
        var stateURL: URL
        var defaults: UserDefaults
        /// The five fixed paths the removed legacy rule probed.
        var gwsCandidates: [String]
        var gwsConfigDirectory: URL
        var userBinGws: String
        var isExecutable: (String) -> Bool
        var bridge: BridgeScanner
        var remover: BridgeFolderRemover.Seams
        var now: () -> Date

        static var live: Env {
            let home = NSHomeDirectory()
            let root = StoragePaths.dataRoot
            return Env(
                dataRoot: root,
                stateURL: root.appendingPathComponent("retired-integrations.json"),
                defaults: UserDefaults.standard,
                gwsCandidates: ["/opt/homebrew/bin/gws", "/usr/local/bin/gws", home + "/.cargo/bin/gws",
                                home + "/.local/bin/gws", "/usr/bin/gws"],
                gwsConfigDirectory: URL(fileURLWithPath: home).appendingPathComponent(".config/gws", isDirectory: true),
                userBinGws: home + "/.local/bin/gws",
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                bridge: .live,
                remover: .live,
                now: { Date() })
        }
    }

    /// Selftest seam for the live environment (doctor, the wipe warning).
    nonisolated(unsafe) static var envOverrideForTesting: Env?
    static var env: Env { envOverrideForTesting ?? .live }

    static let lastUserChannelDefaultsKey = "last_user_channel_address"
    static let whatsappEnabledDefaultsKey = "whatsapp_enabled"

    // MARK: - Migration

    struct Report: Equatable {
        var inert: String?
        var stateWriteFailed = false
        var conversionFailed: String?
        var cleanupFailed: String?
        var settingsFailed: String?
        /// Replacement for an in-memory WhatsApp `lastUserChannel` (nil = none).
        var lastUserChannelReplacement: ChannelAddress?
        var lastUserChannelWasWhatsApp = false
        var bridge: BridgeOutcome?
        var folder: FolderOutcome?
    }

    /// The whole startup pass. Idempotent; every failure leaves retryable work.
    @discardableResult
    static func migrate(_ env: Env = env) -> Report {
        var report = Report()
        // Routing hygiene for the already-loaded ambient fallback: computed
        // from the STORED pairing (configure() has not run yet), and applied
        // by the caller even when the durable steps below stay inert.
        report.lastUserChannelReplacement = pairedTelegramAddress()
        var state: State
        switch load(env.stateURL) {
        case .unreadable(let why):
            report.inert = why
            return report
        case .absent:
            state = evaluate(env)
            do { try save(state, to: env.stateURL) } catch {
                report.stateWriteFailed = true
                return report   // nothing changes until the record exists
            }
        case .ok(let loaded):
            state = loaded
        }

        // gws step 1: conversion (one conditional transaction; an explicit
        // agentmail/none written meanwhile by setup-api or the menu wins).
        if var gws = state.gws, gws.conversion == .pending {
            do {
                try KeychainHelper.conditionalTransaction { store in
                    let raw = store[KeychainHelper.emailCalendarProviderKey]
                    if raw == "gws" || (raw == nil && gws.legacyUnset) {
                        store[KeychainHelper.emailCalendarProviderKey] = EmailCalendarProvider.none.rawValue
                    }
                    store.removeValue(forKey: KeychainHelper.retiredGwsOAuthClientIDKey)
                    store.removeValue(forKey: KeychainHelper.retiredGwsOAuthClientSecretKey)
                }
                gws.conversion = .done
                state.gws = gws
                if !persist(state, env, &report) { return report }
            } catch {
                report.conversionFailed = error.localizedDescription
            }
        }

        // gws step 2: unconditional silent cleanup (stale copies with any
        // provider selected, a provider restored to "gws" by hand/backup).
        do {
            try KeychainHelper.conditionalTransaction { store in
                store.removeValue(forKey: KeychainHelper.retiredGwsOAuthClientIDKey)
                store.removeValue(forKey: KeychainHelper.retiredGwsOAuthClientSecretKey)
                if store[KeychainHelper.emailCalendarProviderKey] == "gws" {
                    store[KeychainHelper.emailCalendarProviderKey] = EmailCalendarProvider.none.rawValue
                }
            }
        } catch {
            report.cleanupFailed = error.localizedDescription
        }

        // WhatsApp step 1: settings (every start, silent).
        do {
            let telegram = report.lastUserChannelReplacement
            if let data = env.defaults.data(forKey: lastUserChannelDefaultsKey),
               let address = try? JSONDecoder().decode(ChannelAddress.self, from: data),
               address.kind == .whatsapp {
                report.lastUserChannelWasWhatsApp = true
                if let telegram, let encoded = try? JSONEncoder().encode(telegram) {
                    env.defaults.set(encoded, forKey: lastUserChannelDefaultsKey)
                } else {
                    env.defaults.removeObject(forKey: lastUserChannelDefaultsKey)
                }
            }
            env.defaults.removeObject(forKey: whatsappEnabledDefaultsKey)
            try KeychainHelper.conditionalTransaction { store in
                store.removeValue(forKey: KeychainHelper.retiredWhatsappOwnerPhoneKey)
            }
            if var wa = state.whatsapp, wa.settings == .pending {
                wa.settings = .done
                state.whatsapp = wa
                if !persist(state, env, &report) { return report }
            }
        } catch {
            report.settingsFailed = error.localizedDescription
        }

        // WhatsApp steps 2–3: stop any bridge, then remove the folder (every
        // start: a folder that reappears is removed again, silently).
        let bridgeDir = env.dataRoot.appendingPathComponent("whatsapp-bridge")
        var lst = stat()
        let present = lstat(bridgeDir.path, &lst) == 0
        if present || state.whatsapp?.folder == .pending {
            var outcome: FolderOutcome = .absent
            if present {
                let target = BridgeScanner.Target(
                    configured: bridgeDir.appendingPathComponent("index.js").path,
                    canonical: env.bridge.resolve(bridgeDir.appendingPathComponent("index.js").path))
                let stop = env.bridge.stopBridges(target: target)
                report.bridge = stop
                if case .clear = stop {
                    outcome = BridgeFolderRemover.remove(name: "whatsapp-bridge", under: env.dataRoot, seams: env.remover) { kind in
                        guard var wa = state.whatsapp else { return true }   // silent re-clean: nothing owed
                        guard wa.folder == .pending else { return true }
                        wa.topKind = kind
                        state.whatsapp = wa
                        return persist(state, env, &report)
                    }
                } else {
                    outcome = .deferred("a WhatsApp bridge process may still be running: \(stop.detail)")
                }
            }
            report.folder = outcome
            if var wa = state.whatsapp, wa.folder == .pending {
                switch outcome {
                case .removed:
                    wa.folder = .done; wa.folderDetail = nil
                case .absent:
                    // ENOENT after a recorded removal = a crash between the
                    // unlink and `done`; without a record Briglia deleted nothing.
                    wa.folder = wa.topKind == nil ? .absent : .done
                    wa.folderDetail = nil
                case .deferred(let why), .failed(let why):
                    wa.folderDetail = why
                }
                if wa != state.whatsapp {
                    state.whatsapp = wa
                    if !persist(state, env, &report) { return report }
                }
            }
        }
        return report
    }

    private static func persist(_ state: State, _ env: Env, _ report: inout Report) -> Bool {
        do { try save(state, to: env.stateURL); return true }
        catch { report.stateWriteFailed = true; return false }
    }

    /// First run of this build: detect both integrations once.
    static func evaluate(_ env: Env) -> State {
        var state = State(version: stateVersion, evaluated: true, gws: nil, whatsapp: nil)
        let raw = KeychainHelper.load(key: KeychainHelper.emailCalendarProviderKey)
        if raw == "gws" {
            state.gws = Gws(legacyUnset: false, conversion: .pending, notice: .pending)
        } else if raw == nil, env.gwsCandidates.contains(where: env.isExecutable) {
            state.gws = Gws(legacyUnset: true, conversion: .pending, notice: .pending)
        }
        let enabledKeyPresent = env.defaults.object(forKey: whatsappEnabledDefaultsKey) != nil
        let enabled = env.defaults.bool(forKey: whatsappEnabledDefaultsKey)
        let phone = (KeychainHelper.load(key: KeychainHelper.retiredWhatsappOwnerPhoneKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lst = stat()
        let folderPresent = lstat(env.dataRoot.appendingPathComponent("whatsapp-bridge").path, &lst) == 0
        var lastIsWhatsApp = false
        if let data = env.defaults.data(forKey: lastUserChannelDefaultsKey),
           let address = try? JSONDecoder().decode(ChannelAddress.self, from: data) {
            lastIsWhatsApp = address.kind == .whatsapp
        }
        if enabledKeyPresent || !phone.isEmpty || folderPresent || lastIsWhatsApp {
            let wasEnabled = enabled && !phone.isEmpty
            state.whatsapp = WhatsApp(wasEnabled: wasEnabled, settings: .pending,
                                      folder: folderPresent ? .pending : .absent, topKind: nil,
                                      folderDetail: nil, notice: wasEnabled ? .pending : .none)
        }
        return state
    }

    /// The paired Telegram address, derived the same way
    /// `updateTelegramChannelRegistration` does.
    static func pairedTelegramAddress() -> ChannelAddress? {
        let token = (KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = (KeychainHelper.load(key: KeychainHelper.telegramChatIdKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let id = Int(chat) else { return nil }
        return ChannelAddress(kind: .telegram, chatId: String(id))
    }

    // MARK: - Notices

    enum Which: String, CaseIterable { case gws, whatsapp }

    /// The notices owed right now (eligible, not throttled), oldest first.
    static func dueNotices(_ state: State, now: Date) -> [Which] {
        var out: [Which] = []
        if let g = state.gws, g.conversion == .done, g.notice == .pending, (g.retryAt ?? .distantPast) <= now {
            out.append(.gws)
        }
        // The folder step must have run once (done/absent, or pending with
        // the reason it could not finish) so the text tells the truth.
        if let w = state.whatsapp, w.wasEnabled, w.settings == .done, w.notice == .pending,
           w.folder != .pending || w.folderDetail != nil,
           (w.retryAt ?? .distantPast) <= now {
            out.append(.whatsapp)
        }
        return out
    }

    static func text(_ which: Which, state: State, language: String, dataRoot: URL) -> String {
        let italian = language == "it"
        switch which {
        case .gws:
            return italian
                ? "L'email Google tramite gws è stata rimossa da Briglia. Per continuare ad avere email e calendario, configura AgentMail in `briglia menu`. Il programma gws e il suo accesso a Google su questo computer non sono stati toccati."
                : "Google email via gws has been removed from Briglia. To keep email and calendar, set up AgentMail in `briglia menu`. Your own gws program and its Google sign-in on this computer were not touched."
        case .whatsapp:
            let wa = state.whatsapp
            let path = dataRoot.appendingPathComponent("whatsapp-bridge").path
            let phoneEN = " On your phone, open WhatsApp → Linked devices and remove the old Briglia entry."
            let phoneIT = " Sul telefono apri WhatsApp → Dispositivi collegati e rimuovi la vecchia voce di Briglia."
            let headEN = "The WhatsApp connection has been removed from Briglia; Telegram keeps working as before."
            let headIT = "Il collegamento WhatsApp è stato rimosso da Briglia; Telegram continua a funzionare come prima."
            if wa?.folder == .pending {
                return italian
                    ? headIT + " Briglia non è ancora riuscita a cancellare la sua cartella privata del bridge WhatsApp (\(path)); riprova a ogni avvio e `briglia doctor` ne mostra lo stato." + phoneIT
                    : headEN + " Briglia could not finish deleting its private WhatsApp bridge folder yet (\(path)); it retries at each start and `briglia doctor` shows the state." + phoneEN
            }
            if wa?.folder == .absent {
                return italian
                    ? headIT + " Su questo computer non è stata trovata alcuna cartella del bridge WhatsApp." + phoneIT
                    : headEN + " No WhatsApp bridge folder was found on this computer." + phoneEN
            }
            if wa?.topKind == .link {
                return italian
                    ? headIT + " Briglia ha rimosso il collegamento alla sua cartella del bridge WhatsApp; la cartella a cui puntava non è stata toccata." + phoneIT
                    : headEN + " Briglia removed the link to its WhatsApp bridge folder; the folder it pointed to was not touched." + phoneEN
            }
            return italian
                ? headIT + " Briglia ha cancellato la sua cartella privata del bridge WhatsApp su questo computer." + phoneIT
                : headEN + " Briglia deleted its private WhatsApp bridge folder on this computer." + phoneEN
        }
    }

    /// Consume one owed notice before its single send: `pending → attempted`
    /// durably, with the destination captured. Returns the text to send, or
    /// nil (not owed any more, or the write failed → nothing is sent).
    static func consume(_ which: Which, destination: Attempt, language: String, env: Env = env) -> String? {
        guard case .ok(var state) = load(env.stateURL) else { return nil }
        let text: String
        switch which {
        case .gws:
            guard var g = state.gws, g.conversion == .done, g.notice == .pending else { return nil }
            text = Self.text(.gws, state: state, language: language, dataRoot: env.dataRoot)
            g.notice = .attempted; g.attempt = destination; g.retryAt = nil
            state.gws = g
        case .whatsapp:
            guard var w = state.whatsapp, w.wasEnabled, w.notice == .pending else { return nil }
            text = Self.text(.whatsapp, state: state, language: language, dataRoot: env.dataRoot)
            w.notice = .attempted; w.attempt = destination; w.retryAt = nil
            state.whatsapp = w
        }
        do { try save(state, to: env.stateURL) } catch { return nil }
        return text
    }

    enum Settle: Equatable {
        /// accepted or ambiguous: never sent again.
        case done
        /// proven not delivered (refused / dropped): owed again after `retryAt`.
        case retry(Date)
    }

    static func settle(_ which: Which, _ outcome: Settle, env: Env = env) {
        guard case .ok(var state) = load(env.stateURL) else { return }
        switch which {
        case .gws:
            guard var g = state.gws, g.notice == .attempted else { return }
            switch outcome {
            case .done: g.notice = .done
            case .retry(let at): g.notice = .pending; g.retryAt = at
            }
            state.gws = g
        case .whatsapp:
            guard var w = state.whatsapp, w.notice == .attempted else { return }
            switch outcome {
            case .done: w.notice = .done
            case .retry(let at): w.notice = .pending; w.retryAt = at
            }
            state.whatsapp = w
        }
        try? save(state, to: env.stateURL)
    }

    // MARK: - Doctor and the wipe warning

    static func gwsConfigDirectoryExists(_ env: Env = env) -> Bool {
        var st = stat()
        return lstat(env.gwsConfigDirectory.path, &st) == 0
    }

    static func doctorLines(_ env: Env = env) -> [String] {
        var lines: [String] = []
        switch load(env.stateURL) {
        case .absent:
            break
        case .unreadable(let why):
            lines.append("retired integrations: state file \(env.stateURL.path) is unreadable (\(why)) — the gws/WhatsApp retirement steps are paused; move the file aside to let Briglia redo them")
        case .ok(let state):
            if let g = state.gws {
                let notice: String
                switch g.notice {
                case .none: notice = "no notice owed"
                case .pending: notice = "notice not sent yet"
                case .attempted, .done: notice = "notice sent"
                }
                lines.append("gws (Google email) was removed from Briglia — settings conversion \(g.conversion == .done ? "done" : "pending"), \(notice); set up AgentMail in `briglia menu` for email and calendar")
            }
            if let w = state.whatsapp {
                switch w.folder {
                case .pending:
                    lines.append("WhatsApp was removed from Briglia — its private bridge folder \(env.dataRoot.appendingPathComponent("whatsapp-bridge").path) is not deleted yet\(w.folderDetail.map { " (\($0))" } ?? ""); Briglia retries at each start")
                case .absent:
                    lines.append("WhatsApp was removed from Briglia — no bridge folder was found")
                case .done:
                    lines.append("WhatsApp was removed from Briglia — bridge folder \(w.topKind == .link ? "link removed (its target was not touched)" : "deleted")")
                }
            }
        }
        var st = stat()
        if lstat(env.userBinGws, &st) == 0 {
            lines.append("a gws program is at \(env.userBinGws) (an earlier Briglia may have installed it); Briglia no longer uses or updates it — remove it if you don't use it yourself")
        }
        return lines
    }
}

extension JSONEncoder {
    static var retired: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var retired: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
