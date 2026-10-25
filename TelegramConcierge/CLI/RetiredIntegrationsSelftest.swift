import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden test of the gws / WhatsApp retirement (plan
/// `DROP_GWS_WHATSAPP_PLAN.md` v3): migration state machine and crash/fault
/// safety, the bridge scanner, the descriptor remover, retired alerts, the
/// notice state machine, and (in +Manager) the manager-level routing and
/// notice loop. Re-execs itself under a private link name in a scratch home
/// (files AND preferences isolated; never the live install).
struct RetiredIntegrationsSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__retired-integrations-selftest",
        abstract: "Internal: verify the gws / WhatsApp retirement migration and notices.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-retired-selftest"
    static let rootPrefix = "briglia-retired-selftest-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = MidturnHarness(only: only)
        try await h.runRetiredIntegrations()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) retirement check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) retirement checks passed")
    }

    static func reexecIsolated(only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__retired-integrations-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        // settle: on the CI runner image this domain's empty shell came back
        // ~8 s after the sweep had removed it (smoke diagnostics, run
        // 40153678448); keep unlinking reappearances for 25 s.
        TestPrefsDomains.finalSweep(settle: 25)
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Shared fixtures for the unit sections.
enum RIUnits {
    /// The unit sections use this child's own STANDARD domain (its process
    /// name is `linkName`, enforced before any section runs), like the
    /// manager section and every other `briglia-mw-` selftest, and reset it
    /// key by key (the only two keys `RetiredIntegrations` reads). The CI
    /// preference-file leak this used to trigger turned out to be cfprefsd
    /// rewriting the domain's empty shell after the parent's sweep; the parent
    /// handles that with `finalSweep(settle:)` (see `reexecIsolated`).
    static let defaultsKeys = [RetiredIntegrations.lastUserChannelDefaultsKey,
                               RetiredIntegrations.whatsappEnabledDefaultsKey]

    /// A fake process table the scanner reads; `onSignal` mutates it.
    final class Table {
        var rows: [BridgeScanner.Proc] = []
        var unreadable = false
        var signals: [(Int32, Int32)] = []
        /// Which pids die on SIGTERM (others need SIGKILL; `immortal` never die).
        var dieOnTerm: Set<Int32> = []
        var immortal: Set<Int32> = []
        /// pid → replacement row after the first SIGTERM (pid reuse).
        var replaceAfterTerm: [Int32: BridgeScanner.Proc] = [:]
        /// table read number (1-based) → replacement row for its pid.
        var replaceAtRead: [Int: BridgeScanner.Proc] = [:]
        var reads = 0
        var termWait: TimeInterval = 3
        /// Called after each recorded signal (mid-batch table changes).
        var afterSignal: ((Int32, Int32, Table) -> Void)?

        func scanner(resolve: @escaping (String) -> String?) -> BridgeScanner {
            BridgeScanner(
                table: {
                    self.reads += 1
                    if let r = self.replaceAtRead.removeValue(forKey: self.reads) {
                        self.rows.removeAll { $0.pid == r.pid }
                        self.rows.append(r)
                    }
                    return self.unreadable ? nil : self.rows
                },
                signal: { pid, sig in
                    self.signals.append((pid, sig))
                    if let replacement = self.replaceAfterTerm.removeValue(forKey: pid) {
                        self.rows.removeAll { $0.pid == pid }
                        self.rows.append(replacement)
                        return
                    }
                    defer { self.afterSignal?(pid, sig, self) }
                    guard !self.immortal.contains(pid) else { return }
                    if sig == SIGKILL || self.dieOnTerm.contains(pid) { self.rows.removeAll { $0.pid == pid } }
                },
                reap: { _ in },
                sleep: { _ in },
                resolve: resolve,
                uid: 501, selfPid: 1, termWait: termWait)
        }
    }

    static func proc(_ pid: Int32, _ argv: [String]?, uid: uid_t = 501, zombie: Bool = false, ppid: Int32 = 1000) -> BridgeScanner.Proc {
        BridgeScanner.Proc(pid: pid, ppid: ppid, uid: uid, zombie: zombie, argv: argv)
    }

    /// An Env over the isolated data root with injected gws paths, the child's
    /// private standard preference domain, a fake (empty) process table and live remover seams.
    static func env(root: URL, table: Table = Table()) -> RetiredIntegrations.Env {
        let defaults = UserDefaults.standard
        let fake = root.appendingPathComponent("fake-host", isDirectory: true)
        return RetiredIntegrations.Env(
            dataRoot: StoragePaths.dataRoot,
            stateURL: StoragePaths.dataRoot.appendingPathComponent("retired-integrations.json"),
            defaults: defaults,
            gwsCandidates: ["opt-homebrew-bin", "usr-local-bin", "cargo-bin", "local-bin", "usr-bin"]
                .map { fake.appendingPathComponent($0 + "/gws").path },
            gwsConfigDirectory: fake.appendingPathComponent("home/.config/gws", isDirectory: true),
            userBinGws: fake.appendingPathComponent("local-bin/gws").path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            bridge: table.scanner(resolve: { path in
                guard let p = realpath(path, nil) else { return nil }
                defer { free(p) }
                return String(cString: p)
            }),
            remover: .live,
            now: { Date() })
    }

    static func resetStore(_ env: RetiredIntegrations.Env) {
        try? FileManager.default.removeItem(at: env.stateURL)
        try? FileManager.default.removeItem(at: env.dataRoot.appendingPathComponent("whatsapp-bridge"))
        for key in defaultsKeys { env.defaults.removeObject(forKey: key) }
        for key in [KeychainHelper.emailCalendarProviderKey, KeychainHelper.retiredGwsOAuthClientIDKey,
                    KeychainHelper.retiredGwsOAuthClientSecretKey, KeychainHelper.retiredWhatsappOwnerPhoneKey,
                    KeychainHelper.telegramBotTokenKey, KeychainHelper.telegramChatIdKey,
                    KeychainHelper.agentMailApiKeyKey] {
            try? KeychainHelper.delete(key: key)
        }
        RetiredIntegrations.saveFaultForTesting = nil
        KeychainHelper._testFailWrites = false
    }

    static func state(_ env: RetiredIntegrations.Env) -> RetiredIntegrations.State? {
        if case .ok(let s) = RetiredIntegrations.load(env.stateURL) { return s }
        return nil
    }

    static func plantExecutable(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }

    static func plantBridge(_ env: RetiredIntegrations.Env) -> URL {
        let dir = env.dataRoot.appendingPathComponent("whatsapp-bridge", isDirectory: true)
        let fm = FileManager.default
        for sub in ["auth", "media", "node_modules/baileys/lib"] {
            try? fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: dir.appendingPathComponent("index.js").path, contents: Data("// bridge".utf8))
        fm.createFile(atPath: dir.appendingPathComponent("auth/creds.json").path, contents: Data("{}".utf8))
        fm.createFile(atPath: dir.appendingPathComponent("node_modules/baileys/lib/x.js").path, contents: Data("1".utf8))
        return dir
    }
}

extension MidturnHarness {

    func runRetiredIntegrations() async throws {
        let data = StoragePaths.dataRoot.path
        guard data.contains(RetiredIntegrationsSelftest.rootPrefix),
              ProcessInfo.processInfo.processName == RetiredIntegrationsSelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        try PrivateStorage.ensureDirectory(StoragePaths.dataRoot)
        try PrivateStorage.ensureDirectory(StoragePaths.configRoot)
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ri-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        if section("gws") { riGwsSection(scratch) }
        if section("whatsapp") { riWhatsAppSection(scratch) }
        if section("scanner") { riScannerSection(scratch) }
        if section("remover") { riRemoverSection(scratch) }
        if section("alerts") { riAlertsSection() }
        if section("notices") { riNoticeStateSection(scratch) }
        if section("manager") { try await riManagerSection(scratch) }
    }

    // MARK: gws

    func riGwsSection(_ scratch: URL) {
        let env = RIUnits.env(root: scratch)
        func reset() { RIUnits.resetStore(env); try? FileManager.default.removeItem(at: scratch.appendingPathComponent("fake-host")) }
        func provider() -> String? { KeychainHelper.load(key: KeychainHelper.emailCalendarProviderKey) }

        // G1 stored gws → none, OAuth copies deleted, notice owed.
        reset()
        try? KeychainHelper.saveBatch([KeychainHelper.emailCalendarProviderKey: "gws",
                                       KeychainHelper.retiredGwsOAuthClientIDKey: "id",
                                       KeychainHelper.retiredGwsOAuthClientSecretKey: "secret"])
        RetiredIntegrations.migrate(env)
        var s = RIUnits.state(env)
        check("G1 stored gws → provider none, OAuth copies deleted, conversion done, notice pending",
              provider() == "none" && KeychainHelper.load(key: KeychainHelper.retiredGwsOAuthClientIDKey) == nil
                && KeychainHelper.load(key: KeychainHelper.retiredGwsOAuthClientSecretKey) == nil
                && s?.gws == RetiredIntegrations.Gws(legacyUnset: false, conversion: .done, notice: .pending) && s?.evaluated == true)

        // G2 legacy rule at each candidate path.
        for (i, path) in env.gwsCandidates.enumerated() {
            reset()
            RIUnits.plantExecutable(path)
            RetiredIntegrations.migrate(env)
            s = RIUnits.state(env)
            check("G2.\(i) unset + gws binary at candidate \(i) → legacy-unset record, explicit none, notice pending",
                  provider() == "none" && s?.gws?.legacyUnset == true && s?.gws?.notice == .pending && s?.gws?.conversion == .done)
        }

        // G3 unset + no binary → evaluated, no record; a binary added later never earns a notice.
        reset()
        RetiredIntegrations.migrate(env)
        s = RIUnits.state(env)
        check("G3 unset + no gws → evaluated, no gws record, provider still unset",
              s?.evaluated == true && s?.gws == nil && provider() == nil)
        RIUnits.plantExecutable(env.gwsCandidates[3])
        RetiredIntegrations.migrate(env)
        check("G3b a gws installed later never creates a record or a notice (durable negative evaluation)",
              RIUnits.state(env)?.gws == nil && provider() == nil)

        // G4 explicit agentmail / none untouched.
        for value in ["agentmail", "none"] {
            reset()
            RIUnits.plantExecutable(env.gwsCandidates[0])
            try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: value)
            RetiredIntegrations.migrate(env)
            check("G4 stored \(value) (gws binary present) → unchanged, no gws record",
                  provider() == value && RIUnits.state(env)?.gws == nil)
        }

        // G5 crash after the first state write (stored-gws and legacy-unset variants).
        for legacy in [false, true] {
            reset()
            if !legacy { try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "gws") }
            try? RetiredIntegrations.save(RetiredIntegrations.State(version: 1, evaluated: true,
                gws: .init(legacyUnset: legacy, conversion: .pending, notice: .pending), whatsapp: nil), to: env.stateURL)
            RetiredIntegrations.migrate(env)
            check("G5 crash after the first write (\(legacy ? "legacy-unset" : "stored gws")) → next start converts to explicit none",
                  provider() == "none" && RIUnits.state(env)?.gws?.conversion == .done)
        }

        // G6 secret-store transaction failure → pending, no notice eligibility; then retried.
        reset()
        try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "gws")
        RetiredIntegrations.save(fault: false, env)
        KeychainHelper._testFailWrites = true
        let failed = RetiredIntegrations.migrate(env)
        KeychainHelper._testFailWrites = false
        s = RIUnits.state(env)
        check("G6 a failed conversion transaction leaves conversion pending and no notice due",
              failed.conversionFailed != nil && s?.gws?.conversion == .pending
                && RetiredIntegrations.dueNotices(s!, now: Date()).isEmpty)
        RetiredIntegrations.migrate(env)
        check("G6b the next start converts", provider() == "none" && RIUnits.state(env)?.gws?.conversion == .done)

        // G7 state write failure after conversion → conversion stays pending on disk; next start completes.
        reset()
        try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "gws")
        var writes = 0
        RetiredIntegrations.saveFaultForTesting = { _ in writes += 1; return writes == 2 }
        let r7 = RetiredIntegrations.migrate(env)
        RetiredIntegrations.saveFaultForTesting = nil
        check("G7 a failed state write after conversion stops the pass with conversion still pending on disk",
              r7.stateWriteFailed && RIUnits.state(env)?.gws?.conversion == .pending)
        RetiredIntegrations.migrate(env)
        check("G7b the next start records conversion done", RIUnits.state(env)?.gws?.conversion == .done && provider() == "none")

        // G8 first write fails → nothing touched.
        reset()
        try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "gws")
        RetiredIntegrations.saveFaultForTesting = { _ in true }
        let r8 = RetiredIntegrations.migrate(env)
        RetiredIntegrations.saveFaultForTesting = nil
        check("G8 a failed first write touches no setting and leaves no record",
              r8.stateWriteFailed && provider() == "gws" && RetiredIntegrations.load(env.stateURL) == .absent)

        // G9 concurrent AgentMail selection between detection and conversion: AgentMail kept.
        reset()
        try? RetiredIntegrations.save(RetiredIntegrations.State(version: 1, evaluated: true,
            gws: .init(legacyUnset: true, conversion: .pending, notice: .pending), whatsapp: nil), to: env.stateURL)
        try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "agentmail")
        RetiredIntegrations.migrate(env)
        check("G9 a concurrent explicit agentmail choice survives the pending conversion", provider() == "agentmail")

        // G10 stale OAuth copies with AgentMail selected and no record → deleted silently.
        reset()
        RetiredIntegrations.migrate(env)   // evaluated, nothing detected
        try? KeychainHelper.saveBatch([KeychainHelper.emailCalendarProviderKey: "agentmail",
                                       KeychainHelper.retiredGwsOAuthClientIDKey: "id"])
        RetiredIntegrations.migrate(env)
        check("G10 stale OAuth copy with AgentMail selected → deleted, AgentMail kept, no record/notice",
              KeychainHelper.load(key: KeychainHelper.retiredGwsOAuthClientIDKey) == nil && provider() == "agentmail"
                && RIUnits.state(env)?.gws == nil)

        // G11 provider restored to gws after done → none, no second notice.
        reset()
        try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "gws")
        RetiredIntegrations.migrate(env)
        var done = RIUnits.state(env)!; done.gws?.notice = .done
        try? RetiredIntegrations.save(done, to: env.stateURL)
        try? KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "gws")
        RetiredIntegrations.migrate(env)
        check("G11 gws restored after done → silently none again, notice stays done",
              provider() == "none" && RIUnits.state(env)?.gws?.notice == .done)

        // G12 unreadable / wrong version / corrupt state → fully inert.
        for (label, body) in [("corrupt", Data("{not json".utf8)),
                              ("future version", Data(#"{"version":2,"evaluated":true}"#.utf8))] {
            reset()
            try? KeychainHelper.saveBatch([KeychainHelper.emailCalendarProviderKey: "gws",
                                           KeychainHelper.retiredGwsOAuthClientIDKey: "id"])
            try? PrivateStorage.writeAtomically(body, to: env.stateURL)
            let r = RetiredIntegrations.migrate(env)
            check("G12 \(label) state file → fully inert (no conversion, no silent cleanup), doctor line",
                  r.inert != nil && provider() == "gws" && KeychainHelper.load(key: KeychainHelper.retiredGwsOAuthClientIDKey) == "id"
                    && RetiredIntegrations.doctorLines(env).contains { $0.contains("unreadable") })
        }
        check("G12b reads stay safe while inert: a stored gws still reads as none", EmailCalendarProvider.current == .none)

        // G14 an unreadable secret store at first evaluation → inert, no record.
        reset()
        RIUnits.plantExecutable(env.gwsCandidates[1])
        let secrets = URL(fileURLWithPath: KeychainHelper.secretStorePath)
        let savedSecrets = try? Data(contentsOf: secrets)
        try? PrivateStorage.writeAtomically(Data("{damaged".utf8), to: secrets)
        let r14 = RetiredIntegrations.migrate(env)
        check("G14 unreadable secrets.json at first evaluation → inert, no record written",
              r14.inert?.contains("secret store unreadable") == true && RetiredIntegrations.load(env.stateURL) == .absent)
        if let savedSecrets { try? PrivateStorage.writeAtomically(savedSecrets, to: secrets) } else { try? FileManager.default.removeItem(at: secrets) }

        // G13 never-touch: fake gws binary and ~/.config/gws untouched.
        reset()
        RIUnits.plantExecutable(env.userBinGws)
        let cfg = env.gwsConfigDirectory
        try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cfg.appendingPathComponent("client_secret.json").path, contents: Data("{\"x\":1}".utf8))
        func fingerprint(_ path: String) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path),
                  let d = FileManager.default.contents(atPath: path) else { return "missing" }
            return "\(d.base64EncodedString())|\(a[.posixPermissions] ?? "")|\(a[.modificationDate] ?? "")"
        }
        let before = [fingerprint(env.userBinGws), fingerprint(cfg.appendingPathComponent("client_secret.json").path)]
        RetiredIntegrations.migrate(env)
        RetiredIntegrations.migrate(env)
        _ = EmailCredentialWipe.execute()
        let after = [fingerprint(env.userBinGws), fingerprint(cfg.appendingPathComponent("client_secret.json").path)]
        check("G13 the gws binary and the gws config are byte-, mode- and mtime-identical after migration and the credential wipe",
              before == after && !before.contains("missing"))
        check("G13b doctor names the leftover ~/.local/bin/gws without touching it",
              RetiredIntegrations.doctorLines(env).contains { $0.contains(env.userBinGws) && $0.contains("no longer uses") })
        check("G13c the wipe warning helper sees the gws config directory", RetiredIntegrations.gwsConfigDirectoryExists(env))
        reset()
    }

    // MARK: WhatsApp

    func riWhatsAppSection(_ scratch: URL) {
        let env = RIUnits.env(root: scratch)
        let enabledKey = RetiredIntegrations.whatsappEnabledDefaultsKey
        let lastKey = RetiredIntegrations.lastUserChannelDefaultsKey
        func lastStored() -> ChannelAddress? {
            env.defaults.data(forKey: lastKey).flatMap { try? JSONDecoder().decode(ChannelAddress.self, from: $0) }
        }
        let wa = ChannelAddress(kind: .whatsapp, chatId: "393330000000@s.whatsapp.net")

        // W1 enabled + phone + folder → wasEnabled captured, settings removed, folder deleted, notice pending.
        RIUnits.resetStore(env)
        env.defaults.set(true, forKey: enabledKey)
        env.defaults.set(try? JSONEncoder().encode(wa), forKey: lastKey)
        try? KeychainHelper.saveBatch([KeychainHelper.retiredWhatsappOwnerPhoneKey: "393330000000",
                                       KeychainHelper.telegramBotTokenKey: "123:synthetic", KeychainHelper.telegramChatIdKey: "42"])
        let dir = RIUnits.plantBridge(env)
        let r1 = RetiredIntegrations.migrate(env)
        var s = RIUnits.state(env)
        check("W1 enabled WhatsApp: wasEnabled, settings done, folder done (dir), notice pending",
              s?.whatsapp?.wasEnabled == true && s?.whatsapp?.settings == .done && s?.whatsapp?.folder == .done
                && s?.whatsapp?.topKind == .dir && s?.whatsapp?.notice == .pending && !FileManager.default.fileExists(atPath: dir.path))
        check("W1b settings removed; stored last channel WhatsApp → paired Telegram",
              env.defaults.object(forKey: enabledKey) == nil && KeychainHelper.load(key: KeychainHelper.retiredWhatsappOwnerPhoneKey) == nil
                && lastStored() == ChannelAddress(kind: .telegram, chatId: "42") && r1.lastUserChannelReplacement == lastStored())
        check("W1c text A says the folder was deleted and how to unlink the phone",
              RetiredIntegrations.text(.whatsapp, state: s!, language: "en", dataRoot: env.dataRoot).contains("deleted its private WhatsApp bridge folder")
                && RetiredIntegrations.text(.whatsapp, state: s!, language: "it", dataRoot: env.dataRoot).contains("Dispositivi collegati"))

        // W2 no Telegram → last channel removed.
        RIUnits.resetStore(env)
        env.defaults.set(try? JSONEncoder().encode(wa), forKey: lastKey)
        RetiredIntegrations.migrate(env)
        check("W2 without Telegram the stored WhatsApp last channel is removed", lastStored() == nil && env.defaults.data(forKey: lastKey) == nil)

        // W3 disabled leftovers → cleaned quietly, no notice.
        RIUnits.resetStore(env)
        env.defaults.set(false, forKey: enabledKey)
        try? KeychainHelper.save(key: KeychainHelper.retiredWhatsappOwnerPhoneKey, value: "393330000000")
        _ = RIUnits.plantBridge(env)
        RetiredIntegrations.migrate(env)
        s = RIUnits.state(env)
        check("W3 disabled leftovers: cleaned, no notice owed",
              s?.whatsapp?.wasEnabled == false && s?.whatsapp?.notice == RetiredIntegrations.NoticeState.none
                && s?.whatsapp?.folder == .done && RetiredIntegrations.dueNotices(s!, now: Date()).isEmpty)

        // W4 wasEnabled survives a crash after the first write; reused.
        RIUnits.resetStore(env)
        env.defaults.set(true, forKey: enabledKey)
        try? KeychainHelper.save(key: KeychainHelper.retiredWhatsappOwnerPhoneKey, value: "39")
        var writes = 0
        RetiredIntegrations.saveFaultForTesting = { _ in writes += 1; return writes == 2 }
        RetiredIntegrations.migrate(env)    // first write ok, settings removed, settings-done write fails
        RetiredIntegrations.saveFaultForTesting = nil
        check("W4 crash after the first write: settings already gone, wasEnabled persisted",
              RIUnits.state(env)?.whatsapp?.wasEnabled == true && env.defaults.object(forKey: enabledKey) == nil)
        RetiredIntegrations.migrate(env)
        s = RIUnits.state(env)
        check("W4b next start finishes and still owes the notice", s?.whatsapp?.settings == .done && s?.whatsapp?.notice == .pending)

        // W5 restored settings or folder after done → cleaned silently, notice untouched.
        var d = s!; d.whatsapp?.notice = .done
        try? RetiredIntegrations.save(d, to: env.stateURL)
        env.defaults.set(true, forKey: enabledKey)
        let again = RIUnits.plantBridge(env)
        RetiredIntegrations.migrate(env)
        check("W5 settings and folder restored after done → removed again, notice stays done",
              env.defaults.object(forKey: enabledKey) == nil && !FileManager.default.fileExists(atPath: again.path)
                && RIUnits.state(env)?.whatsapp?.notice == .done)

        // W6 a running bridge (unknown) → folder kept, text B, doctor reason.
        RIUnits.resetStore(env)
        env.defaults.set(true, forKey: enabledKey)
        try? KeychainHelper.save(key: KeychainHelper.retiredWhatsappOwnerPhoneKey, value: "39")
        let kept = RIUnits.plantBridge(env)
        let table = RIUnits.Table()
        table.rows = [RIUnits.proc(77, ["/usr/bin/node", kept.appendingPathComponent("index.js").path])]
        table.immortal = [77]
        let busy = RIUnits.env(root: scratch, table: table)
        RetiredIntegrations.migrate(busy)
        s = RIUnits.state(busy)
        check("W6 a bridge that will not die → folder kept, pending with a reason, notice due with text B",
              FileManager.default.fileExists(atPath: kept.path) && s?.whatsapp?.folder == .pending && s?.whatsapp?.folderDetail != nil
                && RetiredIntegrations.dueNotices(s!, now: Date()) == [.whatsapp]
                && RetiredIntegrations.text(.whatsapp, state: s!, language: "en", dataRoot: busy.dataRoot).contains("could not finish removing")
                && RetiredIntegrations.doctorLines(busy).contains { $0.contains("is not finished") })
        table.immortal = []
        RetiredIntegrations.migrate(busy)
        check("W6b once the bridge can be stopped the next start removes the folder (done, notice still owed once)",
              !FileManager.default.fileExists(atPath: kept.path) && RIUnits.state(busy)?.whatsapp?.folder == .done)

        // W7 crash after unlink before done: topKind recorded → done; without a record → absent, text C.
        RIUnits.resetStore(env)
        try? RetiredIntegrations.save(RetiredIntegrations.State(version: 1, evaluated: true, gws: nil,
            whatsapp: .init(wasEnabled: true, settings: .done, folder: .pending, topKind: .link, folderDetail: nil, notice: .pending)), to: env.stateURL)
        RetiredIntegrations.migrate(env)
        s = RIUnits.state(env)
        check("W7 crash between unlink and done (link) → done, text A-link after restart",
              s?.whatsapp?.folder == .done
                && RetiredIntegrations.text(.whatsapp, state: s!, language: "en", dataRoot: env.dataRoot).contains("removed the link"))
        RIUnits.resetStore(env)
        env.defaults.set(true, forKey: enabledKey)
        try? KeychainHelper.save(key: KeychainHelper.retiredWhatsappOwnerPhoneKey, value: "39")
        RetiredIntegrations.migrate(env)
        s = RIUnits.state(env)
        check("W7b enabled but no folder ever → absent, text C (nothing claimed deleted)",
              s?.whatsapp?.folder == .absent
                && RetiredIntegrations.text(.whatsapp, state: s!, language: "en", dataRoot: env.dataRoot).contains("No WhatsApp bridge folder was found")
                && !RetiredIntegrations.text(.whatsapp, state: s!, language: "en", dataRoot: env.dataRoot).contains("deleted"))

        // W8 top-level symlink → only the link removed, target kept, text A-link.
        RIUnits.resetStore(env)
        env.defaults.set(true, forKey: enabledKey)
        try? KeychainHelper.save(key: KeychainHelper.retiredWhatsappOwnerPhoneKey, value: "39")
        let outside = scratch.appendingPathComponent("outside-bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside.appendingPathComponent("keep.txt").path, contents: Data("k".utf8))
        try? FileManager.default.createSymbolicLink(at: env.dataRoot.appendingPathComponent("whatsapp-bridge"), withDestinationURL: outside)
        RetiredIntegrations.migrate(env)
        s = RIUnits.state(env)
        var lst = stat()
        check("W8 a top-level symlink: only the link is removed, its target survives, text A-link",
              lstat(env.dataRoot.appendingPathComponent("whatsapp-bridge").path, &lst) != 0
                && FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path)
                && s?.whatsapp?.topKind == .link
                && RetiredIntegrations.text(.whatsapp, state: s!, language: "en", dataRoot: env.dataRoot).contains("was not touched"))

        // W9 folder already gone, record pending: an orphan bridge (its script
        // deleted, so only the literal path identifies it) is still stopped.
        RIUnits.resetStore(env)
        try? RetiredIntegrations.save(RetiredIntegrations.State(version: 1, evaluated: true, gws: nil,
            whatsapp: .init(wasEnabled: true, settings: .done, folder: .pending, topKind: nil, folderDetail: nil, notice: .pending)), to: env.stateURL)
        let orphanScript = env.dataRoot.appendingPathComponent("whatsapp-bridge/index.js").path
        let t9 = RIUnits.Table()
        t9.rows = [RIUnits.proc(90, ["node", orphanScript])]
        t9.dieOnTerm = [90]
        let r9 = RetiredIntegrations.migrate(RIUnits.env(root: scratch, table: t9))
        check("W9 folder absent: an orphan bridge with the literal path is still stopped (TERM), then the folder is absent",
              t9.signals.map(\.0) == [90] && r9.bridge == .clear && RIUnits.state(env)?.whatsapp?.folder == .absent,
              "signals \(t9.signals) bridge \(String(describing: r9.bridge))")

        // W10 cleanup was done, then an orphan that cannot be stopped is found:
        // the folder work reopens (pending, reason) and the notice is untouched.
        var dn = RIUnits.state(env)!; dn.whatsapp?.folder = .done; dn.whatsapp?.notice = .done
        try? RetiredIntegrations.save(dn, to: env.stateURL)
        let t10 = RIUnits.Table()
        t10.rows = [RIUnits.proc(91, ["node", orphanScript])]
        t10.immortal = [91]
        RetiredIntegrations.migrate(RIUnits.env(root: scratch, table: t10))
        s = RIUnits.state(env)
        check("W10 an unstoppable orphan after done → pending with a reason, doctor shows it, notice stays done",
              s?.whatsapp?.folder == .pending && s?.whatsapp?.folderDetail?.contains("may still be running") == true
                && s?.whatsapp?.notice == .done && RetiredIntegrations.doctorLines(env).contains { $0.contains("is not finished") })

        // W11 a folder that reappears after done and cannot be removed: the
        // record reopens truthfully (doctor and a still-pending notice say so).
        RIUnits.resetStore(env)
        try? RetiredIntegrations.save(RetiredIntegrations.State(version: 1, evaluated: true, gws: nil,
            whatsapp: .init(wasEnabled: true, settings: .done, folder: .done, topKind: .dir, folderDetail: nil, notice: .pending)), to: env.stateURL)
        let back = RIUnits.plantBridge(env)
        mkfifo(back.appendingPathComponent("special").path, 0o600)
        RetiredIntegrations.migrate(env)
        s = RIUnits.state(env)
        check("W11 a reappeared folder that cannot be removed → pending with the reason, text B, doctor 'not deleted yet'",
              s?.whatsapp?.folder == .pending && s?.whatsapp?.folderDetail?.contains("special file") == true
                && RetiredIntegrations.text(.whatsapp, state: s!, language: "en", dataRoot: env.dataRoot).contains("could not finish removing")
                && RetiredIntegrations.doctorLines(env).contains { $0.contains("is not finished") } && s?.whatsapp?.notice == .pending)
        try? FileManager.default.removeItem(at: back.appendingPathComponent("special"))
        RetiredIntegrations.migrate(env)
        check("W11b once removable it is done again; the notice is still owed exactly once",
              RIUnits.state(env)?.whatsapp?.folder == .done && RIUnits.state(env)?.whatsapp?.notice == .pending)

        // W12 after absent, a symlink appears: removed as a link, kind recorded.
        RIUnits.resetStore(env)
        try? RetiredIntegrations.save(RetiredIntegrations.State(version: 1, evaluated: true, gws: nil,
            whatsapp: .init(wasEnabled: true, settings: .done, folder: .absent, topKind: nil, folderDetail: nil, notice: .pending)), to: env.stateURL)
        try? FileManager.default.createSymbolicLink(at: env.dataRoot.appendingPathComponent("whatsapp-bridge"), withDestinationURL: outside)
        RetiredIntegrations.migrate(env)
        s = RIUnits.state(env)
        check("W12 a link appearing after absent → done with kind link, text A-link, target kept",
              s?.whatsapp?.folder == .done && s?.whatsapp?.topKind == .link
                && FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path)
                && RetiredIntegrations.text(.whatsapp, state: s!, language: "en", dataRoot: env.dataRoot).contains("removed the link"))
        RIUnits.resetStore(env)
    }
}

extension RetiredIntegrations {
    /// Selftest helper: write a fresh "evaluated" record (optionally faulted).
    static func save(fault: Bool, _ env: Env) {
        var s = State(version: stateVersion, evaluated: true, gws: nil, whatsapp: nil)
        if KeychainHelper.load(key: KeychainHelper.emailCalendarProviderKey) == "gws" {
            s.gws = Gws(legacyUnset: false, conversion: .pending, notice: .pending)
        }
        if !fault { try? save(s, to: env.stateURL) }
    }
}
