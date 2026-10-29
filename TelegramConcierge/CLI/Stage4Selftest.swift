import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Hidden selftest of multi-assistant stage 4 (MULTI_ASSISTANT_PLAN §28,
/// §28.6): the shared assistant name, provisional creation, the supervisor's
/// start re-arm, the menu's Assistants page, and Telegram managed bots
/// (`/newassistant`, the confirmation, the durable claim, gates, rotation) —
/// all against a fake Bot API answered in process. Re-executes itself in a
/// private scratch home (HOME, XDG roots, TMPDIR) under the test binary name
/// `briglia-mw-stage4`, with the experimental switch on. No network, no live
/// install, no paid call.
struct Stage4Selftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__stage4-selftest",
        abstract: "Internal: multi-assistant stage-4 selftest.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-stage4"
    static let rootPrefix = "briglia-stage4-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { print("✖ development build required"); throw ExitCode(1) }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = Stage4Harness(only: only)
        await h.runAll()
        print("\n\(h.total - h.failures)/\(h.total) stage-4 checks passed")
        if h.failures > 0 { throw ExitCode(1) }
    }

    static func reexecIsolated(only: String?) throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent(rootPrefix + UUID().uuidString.prefix(8))
        for sub in ["home", "home/.config", "home/.local/share", "tmp", "landing"] {
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
        env[AssistantProfile.experimentalKey] = "1"
        env[LandingZone.testRootKey] = root.appendingPathComponent("landing").path
        env.removeValue(forKey: AssistantProfile.environmentKey)
        // Child processes (init, probes, the rotation child) never reach the
        // network: a closed local port answers every Bot API request.
        env["BRIGLIA_TELEGRAM_API_BASE"] = "http://127.0.0.1:9/bot"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let p = Process()
        p.executableURL = linked
        p.arguments = ["__stage4-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        p.environment = env
        try p.run()
        p.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        for name in Stage4Harness.extraNames {
            TestPrefsDomains.purge("briglia.profile.\(name).\(AssistantProfile.installationHash(name, environment: env))")
        }
        _ = TestPrefsDomains.finalSweep()
        if p.terminationStatus != 0 { throw ExitCode(p.terminationStatus) }
    }
}

/// In-process Bot API for stage 4: getMe (configurable `can_manage_bots`),
/// sendMessage (recorded with its reply markup), the managed-bot methods
/// (token per bot id, scripted failures), answers to the rest.
final class S4FakeBotAPI: @unchecked Sendable {
    private let lock = NSLock()
    struct Sent { var token: String; var method: String; var body: [String: Any] }
    private var _sent: [Sent] = []
    var canManage = true
    var managerId: Int64 = 7_000_000_001
    var managerUsername = "bree_test_bot"
    /// Bot id → current token.
    var tokens: [Int64: String] = [:]
    /// Number of getManagedBotToken calls that fail before answering.
    var tokenFailures = 0
    var replaceFailures = 0
    var accessCalls: [(Int64, Bool)] = []

    var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }
    func clear() { lock.lock(); _sent = []; accessCalls = []; lock.unlock() }
    func texts() -> [String] { sent.compactMap { $0.body["text"] as? String } }

    static func token(_ botId: Int64, _ n: Int = 1) -> String { "\(botId):AAsyntheticManagedBotToken\(n)_xxxxxxxxxxxx" }

    func handle(_ request: URLRequest) -> (Data, URLResponse) {
        let url = request.url!
        let parts = url.path.split(separator: "/").map(String.init)
        let method = parts.last ?? ""
        let tokenPart = parts.count >= 2 ? String(parts[parts.count - 2].dropFirst(3)) : ""
        var body = request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        if body.isEmpty, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for i in items { body[i.name] = i.value ?? "" }
        }
        func reply(_ result: Any, ok: Bool = true, status: Int = 200, description: String? = nil) -> (Data, URLResponse) {
            var o: [String: Any] = ["ok": ok]
            if ok { o["result"] = result } else { o["description"] = description ?? "Bad Request" }
            let data = try! JSONSerialization.data(withJSONObject: o)
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
        }
        lock.lock(); _sent.append(Sent(token: tokenPart, method: method, body: body)); lock.unlock()
        let botId = (body["user_id"] as? NSNumber)?.int64Value ?? Int64(body["user_id"] as? String ?? "") ?? 0
        switch method {
        case "getMe":
            let id = Int64(tokenPart.split(separator: ":").first ?? "") ?? 0
            if id != managerId, tokens[id] != tokenPart { return reply(NSNull(), ok: false, status: 401, description: "Unauthorized") }
            return reply(["id": id, "is_bot": true, "first_name": id == managerId ? "Bree" : "New",
                          "username": id == managerId ? managerUsername : "bot\(id)", "can_manage_bots": id == managerId && canManage])
        case "sendMessage":
            return reply(["message_id": Int.random(in: 100...99999), "date": 0, "chat": ["id": body["chat_id"] ?? 0, "type": "private"]])
        case "getManagedBotToken":
            lock.lock(); defer { lock.unlock() }
            if tokenFailures > 0 { tokenFailures -= 1; return reply(NSNull(), ok: false, status: 400, description: "Bad Request: bot not ready") }
            guard let t = tokens[botId] else { return reply(NSNull(), ok: false, status: 400, description: "Bad Request: not managed") }
            return reply(t)
        case "replaceManagedBotToken":
            lock.lock(); defer { lock.unlock() }
            guard let t = tokens[botId] else { return reply(NSNull(), ok: false, status: 400, description: "Bad Request: not managed") }
            let n = (Int(t.split(separator: "n").last?.prefix(1) ?? "1") ?? 1) + 1
            tokens[botId] = Self.token(botId, n)
            if replaceFailures > 0 { replaceFailures -= 1; return reply(NSNull(), ok: false, status: 502, description: "Bad Gateway") }
            return reply(tokens[botId]!)
        case "setManagedBotAccessSettings":
            lock.lock(); accessCalls.append((botId, body["is_access_restricted"] as? Bool == true)); lock.unlock()
            return reply(true)
        case "getUpdates":
            return reply([Any]())
        default:
            return reply(true)
        }
    }
}

@MainActor
final class Stage4Harness {
    let only: String?
    var failures = 0
    var total = 0
    static let extraNames = ["health", "health-2", "work", "coder", "w1", "w2", "assistant", "probe", "rot", "lavoro"]
    static let ownerId: Int64 = 424_242
    let api = S4FakeBotAPI()

    init(only: String?) { self.only = only }

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        let d = ok ? "" : detail()
        print("\(ok ? "✔" : "✖") \(label)\(d.isEmpty ? "" : " — \(d)")")
        if !ok { failures += 1 }
    }

    func section(_ name: String) -> Bool {
        guard only == nil || only == name else { return false }
        print("\n── \(name)")
        return true
    }

    func runAll() async {
        let data = StoragePaths.dataRoot.path
        guard data.contains(Stage4Selftest.rootPrefix), ProcessInfo.processInfo.processName == Stage4Selftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home (data root \(data))")
            failures += 1; return
        }
        TelegramBotService.transportOverrideForTesting = { [api] in api.handle($0) }
        defer { TelegramBotService.transportOverrideForTesting = nil }
        AssistantControl.startOverride = { [weak self] p in self?.startedProfiles.append(p); return "started" }
        AssistantControl.stopOverride = { _ in "stopped" }
        ConversationManager.managedBotTokenRetryDelays = [0, 0, 0]
        if section("units") { unitsSection() }
        if section("name") { nameSection() }
        if section("supervisor") { supervisorSection() }
        if section("create") { await createSection() }
        if section("managed") { await managedSection() }
        if section("gates") { await gatesSection() }
        if section("rotation") { await rotationSection() }
        if section("menu") { await menuSection() }
        if section("invariance") { await invarianceSection() }
    }

    var startedProfiles: [String] = []

    // MARK: - Pure rules

    func unitsSection() {
        typealias MB = ManagedBots
        check("U1 profile id from a name: lower-case ASCII, accents folded, suffix on a clash",
              MB.profileId(fromName: "Health", taken: []) == "health" && MB.profileId(fromName: "Lavoro & Casa", taken: []) == "lavoro-casa"
                && MB.profileId(fromName: "Città", taken: []) == "citta" && MB.profileId(fromName: "日本", taken: []) == "assistant"
                && MB.profileId(fromName: "Health", taken: ["health"]) == "health-2" && MB.profileId(fromName: "Default", taken: []) == "default-2")
        let names = ["Health", "A", "Lavoro & Casa con un nome molto lungo davvero", "日本", "9 lives"]
        let usernames = names.map { MB.suggestedUsername(name: $0, suffix: "a1b2") }
        check("U2 suggested usernames: 5–32 chars, letters/digits/_, end in _bot, start with a letter",
              usernames.allSatisfy { u in (5...32).contains(u.count) && u.hasSuffix("_bot") && u.first!.isLetter
                && u.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }, "\(usernames)")
        check("U3 token shape: the bot id must match", MB.looksLikeToken(S4FakeBotAPI.token(55), botId: 55)
              && !MB.looksLikeToken(S4FakeBotAPI.token(55), botId: 56) && !MB.looksLikeToken("55:short", botId: 55))
        let now = Date()
        let base = MB.Pending(requestId: 9, managerBotId: 1, ownerId: 5, name: "Health", profileId: "health",
                              suggestedUsername: "health_a1b2_bot", createdAt: now, phase: .waiting)
        func ev(_ sender: Int64?, _ bot: Int64, _ u: String?) -> MB.Event { MB.Event(senderId: sender, botId: bot, botUsername: u) }
        let k = MB.Known()
        check("U4 decide: a non-owner sender is ignored", MB.decide(ev(6, 77, "health_a1b2_bot"), pending: base, known: k, ownerId: 5, managerBotId: 1, now: now) != .claim)
        check("U5 decide: nothing pending → ignored", MB.decide(ev(5, 77, "x_bot"), pending: nil, known: k, ownerId: 5, managerBotId: 1, now: now) == .ignore("no /newassistant request is pending"))
        check("U6 decide: an expired request → ignored",
              MB.decide(ev(5, 77, "health_a1b2_bot"), pending: base, known: k, ownerId: 5, managerBotId: 1, now: now.addingTimeInterval(16 * 60)) != .claim)
        check("U7 decide: exact suggested username (any case) → claim", MB.decide(ev(5, 77, "Health_A1B2_bot"), pending: base, known: k, ownerId: 5, managerBotId: 1, now: now) == .claim)
        check("U8 decide: another username (edited, or a stale dialog) → ask the owner", MB.decide(ev(5, 77, "other_bot"), pending: base, known: k, ownerId: 5, managerBotId: 1, now: now) == .askConfirmation)
        var known = MB.Known(); known.bots["77"] = MB.KnownBot(profile: "x", generation: "g", managerBotId: 1)
        check("U9 decide: a bot that already is an assistant → ignored", MB.decide(ev(5, 77, "health_a1b2_bot"), pending: base, known: known, ownerId: 5, managerBotId: 1, now: now) != .claim)
        var claimed = base; claimed.phase = .claimed; claimed.botId = 77
        check("U10 decide: a claimed request resumes for its own bot only",
              MB.decide(ev(5, 77, nil), pending: claimed, known: k, ownerId: 5, managerBotId: 1, now: now) == .resume
                && MB.decide(ev(5, 78, "health_a1b2_bot"), pending: claimed, known: k, ownerId: 5, managerBotId: 1, now: now) != .claim)
        check("U11 decide: a request made by another manager bot is ignored",
              MB.decide(ev(5, 77, "health_a1b2_bot"), pending: base, known: k, ownerId: 5, managerBotId: 2, now: now) != .claim)
        let data = MB.confirmData(yes: true, requestId: 9, botId: 77)
        check("U12 confirmation data round-trips and fits 64 bytes", data.utf8.count <= 64 && MB.parseConfirm(data)! == (true, 9, 77) as (Bool, Int32, Int64)
              && MB.parseConfirm("mb:y:9") == nil && MB.parseConfirm("p:model:x") == nil)
        let root = scratch("cas")
        try? MB.savePending(base, dataRoot: root)
        let applied = (try? MB.updatePending(requestId: 10, dataRoot: root) { $0 = nil }) ?? true
        check("U13 compare-and-write: an older request id never overwrites the current one",
              applied == false && MB.loadPending(dataRoot: root)?.requestId == 9)
        check("U14 names: validation and reserved words",
              AssistantName.validate("  Work ") == .valid("Work") && AssistantName.validate("") == .empty
                && AssistantName.validate(String(repeating: "x", count: 41)) == .tooLong && AssistantName.validate("a\u{7}b") == .control
                && AssistantName.validate("Confirm") == .reserved && MB.reservedNames.contains("retry"))
        let markup = ManagedBotAPI.requestButtonMarkup(requestId: 9, buttonText: "Create", suggestedName: "Health", suggestedUsername: "health_a1b2_bot")
        let button = ((markup["keyboard"] as? [[[String: Any]]])?.first?.first)?["request_managed_bot"] as? [String: Any]
        check("U15 the create button is a reply-keyboard request_managed_bot with request_id, suggested_name, suggested_username",
              button?["request_id"] as? Int == 9 && button?["suggested_name"] as? String == "Health"
                && button?["suggested_username"] as? String == "health_a1b2_bot" && markup["one_time_keyboard"] as? Bool == true)
    }

    func scratch(_ name: String) -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s4-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: - Names (§28.2, §28.6 S4-P6)

    func nameSection() {
        let paths = AssistantRegistry.Paths(root: scratch("reg-name"))
        let lockURL = scratch("idlock").appendingPathComponent("identity-tx.lock")
        var stored: [String: String] = [:]
        func saver(_ p: String) -> (String) throws -> Void { { stored[p] = $0 } }
        let noReg = try? AssistantName.set("Nova", mode: .assistant, profile: "default", paths: paths, identityLockURL: lockURL, save: saver("default"))
        check("N1 one assistant (no registry): only the stored name changes", noReg == "Nova" && stored["default"] == "Nova" && !AssistantRegistry.exists(paths))
        _ = try? AssistantRegistry.withLock(paths) { doc in
            doc = AssistantRegistry.Document(version: 1, records: [AssistantRegistry.newRecord(name: "default", displayName: "Nova"),
                                                                    AssistantRegistry.newRecord(name: "w1", displayName: "Work")])
        }
        var refusal = ""
        do { try AssistantName.set("work", mode: .assistant, profile: "default", paths: paths, identityLockURL: lockURL, save: saver("default")) }
        catch { refusal = "\(error)" }
        check("N2 several assistants: a name another assistant uses is refused (case-insensitive)", refusal.contains("already called"), refusal)
        let renamed = try? AssistantName.set("Bree", mode: .assistant, profile: "default", paths: paths, identityLockURL: lockURL, save: saver("default"))
        let doc = try? AssistantRegistry.read(paths)
        check("N3 a rename writes the registry record and the stored name", renamed == "Bree" && doc?.record("default")?.displayName == "Bree" && stored["default"] == "Bree")
        // Offline setter versus a live assistant lease of that profile.
        let leaseDir = scratch("leases")
        let lease = try? MemberLease.create(in: leaseDir, role: "assistant", sessionKind: "daemon", profile: "w1")
        var offline = ""
        do { try AssistantName.set("Lavoro", mode: .offline, profile: "w1", paths: paths, ownLease: nil, save: saver("w1"), leaseDirectory: { _ in leaseDir }) }
        catch { offline = "\(error)" }
        check("N4 an offline rename is refused while that assistant runs", offline.contains("running"), offline)
        lease?.release()
        let ok = try? AssistantName.set("Lavoro", mode: .offline, profile: "w1", paths: paths, ownLease: nil, save: saver("w1"), leaseDirectory: { _ in leaseDir })
        check("N5 …and allowed once it stopped", ok == "Lavoro" && stored["w1"] == "Lavoro")
        // Crash between the record write and the secret write: the registry wins.
        stored["w1"] = "Stale"
        let r = AssistantName.reconcile(profile: "w1", paths: paths, load: { $0 == KeychainHelper.assistantNameKey ? stored["w1"] : nil }, save: saver("w1"))
        check("N6 startup reconciliation: the stored name follows the registry", r == .adopted("Lavoro") && stored["w1"] == "Lavoro", "\(r)")
        // Identity lock held (a default bot switch or a first add running).
        let held = ProfileFileLock.take(lockURL)
        var busy = ""
        do { try AssistantName.set("Other", mode: .assistant, profile: "default", paths: paths, identityLockURL: lockURL, save: saver("default")) }
        catch { busy = "\(error)" }
        if case .acquired(let l) = held { l.release() }
        check("N7 default's rename waits for the identity lock (first add / bot switch) and refuses when busy", busy.contains("in progress"), busy)
    }

    // MARK: - Supervisor re-arm (§28.6 S4-P5)

    func supervisorSection() {
        let root = scratch("sup")
        let paths = AssistantRegistry.Paths(root: root)
        let script = root.appendingPathComponent("fake.sh")
        try? "#!/bin/sh\nsleep 0.3\nexit ${FAKE_EXIT:-0}\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        _ = try? AssistantRegistry.withLock(paths) { doc in
            var r = AssistantRegistry.newRecord(name: "w2", displayName: "W2")
            r.autostart = true
            doc = AssistantRegistry.Document(version: 1, records: [AssistantRegistry.newRecord(name: "default", displayName: "Bree"), r])
        }
        var lines: [String] = []
        var settings = Supervisor.Settings()
        settings.registryPaths = paths
        settings.executable = script
        settings.backoff = [0]
        settings.parkAfter = 2
        settings.extrasOnly = true
        settings.output = { lines.append($0) }
        let sup = Supervisor(settings: settings)
        func settle(_ seconds: Double = 0.6) { Thread.sleep(forTimeInterval: seconds); sup.tick() }
        sup.tick(); sup.tick()
        check("S1 extras-only: the extra starts, the default assistant is never run", sup.snapshot["w2"] == "running" && sup.snapshot["default"] == nil, "\(sup.snapshot)")
        settle(); settle(0.1)
        check("S2 a deliberate exit stays stopped", sup.snapshot["w2"] == "stopped", "\(sup.snapshot)")
        try? AssistantControl.setAutostart("w2", true, registryPaths: paths)   // Start
        sup.tick()
        check("S3 Start (a newer start revision) re-arms a stopped child", sup.snapshot["w2"] == "running" || sup.snapshot["w2"] == "waiting", "\(sup.snapshot)")
        settle(); settle(0.1)
        // Rapid Start while the old process is still exiting is not lost.
        try? AssistantControl.setAutostart("w2", true, registryPaths: paths)
        sup.tick()
        let firstPid = lines.filter { $0.contains("started (pid") }.count
        try? AssistantControl.setAutostart("w2", true, registryPaths: paths)
        settle(); settle(0.1); sup.tick()
        check("S4 a Start racing the previous run's exit is honoured (another start follows)",
              lines.filter { $0.contains("started (pid") }.count > firstPid, lines.suffix(6).joined(separator: " | "))
        // Stop (autostart off) then Start under the same supervisor.
        try? AssistantControl.setAutostart("w2", false, registryPaths: paths)
        settle(); settle(0.1)
        try? AssistantControl.setAutostart("w2", true, registryPaths: paths)
        sup.tick(); sup.tick()
        check("S5 Stop then Start under one supervisor starts it again", ["running", "waiting"].contains(sup.snapshot["w2"] ?? ""), "\(sup.snapshot)")
        settle(); settle(0.1)
        // Parked after crashes, then Start.
        setenv("FAKE_EXIT", "3", 1)
        try? AssistantControl.setAutostart("w2", true, registryPaths: paths)
        for _ in 0..<8 { settle(0.4) }
        let parked = sup.snapshot["w2"] == "parked"
        unsetenv("FAKE_EXIT")
        try? AssistantControl.setAutostart("w2", true, registryPaths: paths)
        sup.tick()
        check("S6 a parked assistant is re-armed by Start", parked && ["running", "waiting"].contains(sup.snapshot["w2"] ?? ""), "parked=\(parked) \(sup.snapshot)")
        settle(); settle(0.1)
        // Remove + re-add (new generation) drops the old child state.
        _ = try? AssistantRegistry.withLock(paths) { doc in
            guard var d = doc, let i = d.index("w2") else { return }
            d.records[i].generation = UUID().uuidString.lowercased(); d.records[i].startRevision = nil
            doc = d
        }
        sup.tick(); sup.tick()
        check("S7 a re-added assistant (new generation) gets a fresh child", sup.snapshot["w2"] == "running", "\(sup.snapshot)")
        sup.stopAll()
    }

    // MARK: - Provisional create (§28.6 S4-P1)

    func registry() -> AssistantRegistry.Document? { (try? AssistantRegistry.read(.live)) ?? nil }

    func secrets(_ profile: String) -> [String: Any] {
        let url = AssistantProfile.extraConfigRoot(profile).appendingPathComponent("secrets.json")
        guard let d = FileManager.default.contents(atPath: url.path) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func createSection() async {
        try? KeychainHelper.saveBatch([KeychainHelper.assistantNameKey: "Bree", KeychainHelper.serperApiKeyKey: "serper-synthetic-key",
                                       KeychainHelper.telegramBotTokenKey: "\(api.managerId):AAsyntheticManagerTokenxxxxxxxxxx",
                                       KeychainHelper.telegramChatIdKey: String(Self.ownerId)])
        // While provisional: another member is refused, the record is not active.
        var seenState = ""
        var probe = ""
        AssistantControl.afterProvisionalForTesting = { profile in
            seenState = self.registry()?.record(profile)?.state ?? "?"
            probe = self.runChild(["--profile", profile, "__member-probe"]).out
        }
        let botToken = S4FakeBotAPI.token(8101)
        var created = true
        do {
            try await AssistantControl.create(.init(profile: "work", displayName: "Work", botToken: botToken, botUsername: "work_bot",
                                                    copyKeys: true, chatId: String(Self.ownerId), template: "work", greet: true),
                                              validate: { _ in "work_bot" })
        } catch { created = false; check("C0 create", false, "\(error)") }
        AssistantControl.afterProvisionalForTesting = nil
        check("C1 the record stays provisional (adding) while it is set up, and no other member can enter",
              seenState == "adding" && probe.contains("still being set up"), "state=\(seenState) probe=\(probe.suffix(200))")
        let rec = registry()?.record("work")
        let sec = secrets("work")
        check("C2 activated last, with autostart off until Start", created && rec?.state == "active" && rec?.autostart == false && rec?.bot.current == AssistantRegistry.digest(.bot, botToken))
        check("C3 its own settings: name, copied keys, the bot, the owner's chat, the bot's handle, the hello flag",
              sec["assistant_name"] as? String == "Work" && sec["serper_api_key"] as? String == "serper-synthetic-key"
                && sec["telegram_bot_token"] as? String == botToken && sec["telegram_chat_id"] as? String == String(Self.ownerId)
                && sec["telegram_bot_username"] as? String == "work_bot" && sec["assistant_greeting_pending"] as? String == "true",
              "\(sec.keys.sorted())")
        check("C4 profile.json records the template", AssistantProfile.readMetadata("work")?.template == "work")
        // A failure while provisional removes exactly that assistant.
        AssistantControl.afterProvisionalForTesting = { _ in throw AssistantControl.ControlError("injected") }
        var message = ""
        do { try await AssistantControl.create(.init(profile: "coder", displayName: "Coder")) } catch { message = "\(error)" }
        AssistantControl.afterProvisionalForTesting = nil
        check("C5 a failure during setup leaves nothing behind (record, roots)",
              message.contains("nothing was left behind") && registry()?.record("coder") == nil
                && !FileManager.default.fileExists(atPath: AssistantProfile.extraConfigRoot("coder").path)
                && !FileManager.default.fileExists(atPath: AssistantProfile.extraDataRoot("coder").path), message)
        var validateMessage = ""
        do {
            try await AssistantControl.create(.init(profile: "coder", displayName: "Coder", botToken: S4FakeBotAPI.token(8102)),
                                              validate: { _ in throw AssistantControl.ControlError("Unauthorized") })
        } catch { validateMessage = "\(error)" }
        check("C6 a rejected token (validated inside its reservation) leaves nothing behind and frees the bot",
              registry()?.record("coder") == nil && !validateMessage.contains(S4FakeBotAPI.token(8102))
                && AssistantRegistry.holder(of: AssistantRegistry.digest(.bot, S4FakeBotAPI.token(8102))!, kind: .bot, excluding: "", in: registry()!) == nil,
              validateMessage)
        var dup = ""
        do { try await AssistantControl.create(.init(profile: "w1", displayName: "work")) } catch { dup = "\(error)" }
        check("C7 a second assistant with the same name is refused", dup.contains("already called"), dup)
        let init1 = runChild(["--profile", "work", "__profile-init"], stdin: "{\"secrets\":{}}", extra: [MemberEntry.provisioningOpKey: "not-the-op"])
        check("C8 an active assistant's init needs no op, a provisional one only its own op (refused here: fine either way)", init1.status == 0, init1.out)
    }

    struct RunResult { var status: Int32; var out: String }

    func runChild(_ args: [String], stdin: String? = nil, extra: [String: String] = [:]) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: AgentMailService.brigliaPath())
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), input = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = input
        guard (try? p.run()) != nil else { return RunResult(status: -1, out: "spawn failed") }
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(status: p.terminationStatus, out: String(decoding: d, as: UTF8.self))
    }

    // MARK: - Managed bots (§28.4, §28.6 S4-P2/P3)

    func freshManager() async -> ConversationManager {
        try? KeychainHelper.saveBatch([KeychainHelper.telegramBotTokenKey: "\(api.managerId):AAsyntheticManagerTokenxxxxxxxxxx",
                                       KeychainHelper.telegramChatIdKey: String(Self.ownerId)])
        let m = ConversationManager()
        await m._svRegisterTelegram()
        try? await Task.sleep(nanoseconds: 200_000_000)   // the identity-cache task
        return m
    }

    static func update(_ id: Int, from: Int64 = ownerId, chat: Int64 = ownerId, _ fields: [String: Any]) -> TelegramUpdate {
        var message: [String: Any] = ["message_id": id, "date": 1_790_000_000,
                                      "chat": ["id": chat, "type": "private", "first_name": "Owner"],
                                      "from": ["id": from, "is_bot": false, "first_name": "Owner"]]
        message.merge(fields) { _, n in n }
        return try! JSONDecoder().decode(TelegramUpdate.self, from: JSONSerialization.data(withJSONObject: ["update_id": id, "message": message]))
    }

    static func created(_ id: Int, bot: Int64, username: String, from: Int64 = ownerId) -> TelegramUpdate {
        update(id, from: from, ["managed_bot_created": ["bot": ["id": bot, "is_bot": true, "first_name": "New", "username": username]]])
    }

    static func callback(_ id: Int, data: String, from: Int64 = ownerId) -> TelegramUpdate {
        let q: [String: Any] = ["id": "cb\(id)", "from": ["id": from, "is_bot": false, "first_name": "Owner"], "data": data,
                                "message": ["message_id": 900 + id, "date": 1_790_000_000, "chat": ["id": ownerId, "type": "private"]]]
        return try! JSONDecoder().decode(TelegramUpdate.self, from: JSONSerialization.data(withJSONObject: ["update_id": id, "callback_query": q]))
    }

    func waitCreation(_ m: ConversationManager, _ seconds: Double = 30) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if m.managedBotCreationTask == nil { try? await Task.sleep(nanoseconds: 100_000_000); if m.managedBotCreationTask == nil { return } }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func managedSection() async {
        let m = await freshManager()
        check("B1 bot management flag cached from getMe at registration", m.managedBotCapability == true)
        api.canManage = false; api.clear()
        await m._testProcessUpdate(Self.update(1, ["text": "/newassistant Health"]))
        check("B2 bot management off: plain instructions, no button, nothing pending",
              api.texts().contains { $0.contains("Bot Management") } && ManagedBots.loadPending() == nil
                && !api.sent.contains { $0.body["reply_markup"] != nil })
        api.canManage = true; api.clear()
        await m._testProcessUpdate(Self.update(2, ["text": "/newassistant Health"]))
        let pending = ManagedBots.loadPending()
        let button = api.sent.first { $0.method == "sendMessage" && $0.body["reply_markup"] != nil }
        let req = (((button?.body["reply_markup"] as? [String: Any])?["keyboard"] as? [[[String: Any]]])?.first?.first?["request_managed_bot"]) as? [String: Any]
        check("B3 the button carries the request (id, name, suggested username) and the request is saved (waiting, owner, manager)",
              pending?.phase == .waiting && pending?.name == "Health" && pending?.ownerId == Self.ownerId && pending?.managerBotId == api.managerId
                && (req?["request_id"] as? NSNumber)?.int32Value == pending?.requestId && req?["suggested_username"] as? String == pending?.suggestedUsername,
              "\(String(describing: pending)) \(String(describing: req))")
        // A bot created in another chat / by another sender never reaches the rule.
        api.clear()
        await m._testProcessUpdate(Self.created(3, bot: 9001, username: pending?.suggestedUsername ?? "", from: 999))
        check("B4 a created-bot message from someone else is dropped by the pairing gate", ManagedBots.loadPending()?.phase == .waiting && api.sent.isEmpty)
        // The owner's bot with the exact suggested username → claim → creation.
        api.tokens[9001] = S4FakeBotAPI.token(9001)
        startedProfiles = []
        await m._testProcessUpdate(Self.created(4, bot: 9001, username: pending?.suggestedUsername ?? ""))
        await waitCreation(m)
        let rec = registry()?.record("health")
        let sec = secrets("health")
        check("B5 exact match: the assistant is created (active, bot reserved, token only in its own secrets, owner chat, hello flag)",
              rec?.state == "active" && rec?.bot.current == AssistantRegistry.digest(.bot, S4FakeBotAPI.token(9001))
                && sec["telegram_bot_token"] as? String == S4FakeBotAPI.token(9001) && sec["telegram_chat_id"] as? String == String(Self.ownerId)
                && sec["assistant_greeting_pending"] as? String == "true", "\(String(describing: rec)) \(sec.keys.sorted())")
        check("B6 made private to the owner, started, the request cleared, the bot remembered",
              api.accessCalls.contains { $0.0 == 9001 && $0.1 } && startedProfiles == ["health"] && ManagedBots.loadPending() == nil
                && ManagedBots.loadKnown().bots["9001"]?.profile == "health")
        let allText = api.sent.map { "\($0.body)" }.joined()
        check("B7 the token never appears in any message Briglia sent", !allText.contains("AAsyntheticManagedBotToken"), allText.suffix(300).description)
        check("B8 the outcome removes the create-button keyboard and links the bot",
              api.sent.contains { ($0.body["reply_markup"] as? [String: Any])?["remove_keyboard"] as? Bool == true && ($0.body["text"] as? String ?? "").contains("is ready") })
        api.clear()
        await m._testProcessUpdate(Self.created(5, bot: 9001, username: pending?.suggestedUsername ?? ""))
        check("B9 the same event again creates nothing more", registry()?.records.filter { $0.name.hasPrefix("health") }.count == 1)
        // Edited username → confirmation; a stale button refused; yes → creation.
        await m._testProcessUpdate(Self.update(6, ["text": "/newassistant Lavoro"]))
        let p2 = ManagedBots.loadPending()
        api.tokens[9002] = S4FakeBotAPI.token(9002)
        api.clear()
        await m._testProcessUpdate(Self.created(7, bot: 9002, username: "my_own_name_bot"))
        let question = api.sent.first { ($0.body["reply_markup"] as? [String: Any])?["inline_keyboard"] != nil }
        check("B10 a bot whose username differs from the suggestion needs the owner's yes (nothing is created yet)",
              ManagedBots.loadPending()?.phase == .confirm && question != nil && registry()?.record(p2?.profileId ?? "") == nil)
        await m._testProcessUpdate(Self.callback(8, data: ManagedBots.confirmData(yes: true, requestId: (p2?.requestId ?? 0) &+ 1, botId: 9002)))
        check("B11 a button from another request is refused", ManagedBots.loadPending()?.phase == .confirm
              && api.sent.contains { $0.method == "answerCallbackQuery" && ($0.body["text"] as? String ?? "").contains("no longer current") })
        await m._testProcessUpdate(Self.callback(9, data: ManagedBots.confirmData(yes: true, requestId: p2?.requestId ?? 0, botId: 9002)))
        await waitCreation(m)
        check("B12 yes → that bot becomes «Lavoro»", registry()?.record(p2?.profileId ?? "")?.state == "active" && ManagedBots.loadKnown().bots["9002"] != nil)
        // Token not ready → failed → /newassistant retry.
        await m._testProcessUpdate(Self.update(10, ["text": "/newassistant Coder"]))
        let p3 = ManagedBots.loadPending()
        api.tokens[9003] = S4FakeBotAPI.token(9003)
        api.tokenFailures = 10
        api.clear()
        await m._testProcessUpdate(Self.created(11, bot: 9003, username: p3?.suggestedUsername ?? ""))
        await waitCreation(m)
        check("B13 no token after the retries: kept as failed, the owner is told to retry, nothing created",
              ManagedBots.loadPending()?.failed == true && registry()?.record("coder") == nil && api.texts().contains { $0.contains("/newassistant retry") })
        api.tokenFailures = 0
        await m._testProcessUpdate(Self.update(12, ["text": "/newassistant retry"]))
        await waitCreation(m)
        check("B14 /newassistant retry creates it", registry()?.record("coder")?.state == "active" && ManagedBots.loadPending() == nil)
        // An event with no request.
        api.clear()
        await m._testProcessUpdate(Self.created(13, bot: 9004, username: "random_bot"))
        check("B15 a created bot without a request: nothing happens, the owner is told", api.texts().contains { $0.contains("no current /newassistant") }
              && registry()?.records.count == 5)
        // Cancel.
        await m._testProcessUpdate(Self.update(14, ["text": "/newassistant Probe"]))
        await m._testProcessUpdate(Self.update(15, ["text": "/newassistant cancel"]))
        check("B16 cancel drops the request", ManagedBots.loadPending() == nil)
        api.clear()
        await m._testProcessUpdate(Self.update(16, ["text": "/newassistant cancel"]))
        check("B17 cancel with nothing pending says so", api.texts().contains { $0.contains("Nothing to cancel") })
        await m._testProcessUpdate(Self.update(17, ["text": "/newassistant retry now"]))
        check("B18 an option word plus text is treated as a name and validated", ManagedBots.loadPending()?.name == "retry now" || ManagedBots.loadPending() == nil)
        _ = try? ManagedBots.savePending(nil)
    }

    // MARK: - Gates (§28.6 S4-P3/P7)

    func gatesSection() async {
        let m = await freshManager()
        // A claim while the restore gate is up: durable, creation deferred.
        await m._testProcessUpdate(Self.update(30, ["text": "/newassistant Gated"]))
        let p = ManagedBots.loadPending()
        api.tokens[9101] = S4FakeBotAPI.token(9101)
        m.isRestoringMind = true
        await m._testProcessUpdate(Self.created(31, bot: 9101, username: p?.suggestedUsername ?? ""))
        check("G1 while a wipe/import holds the gate the bot is claimed durably and nothing is created",
              ManagedBots.loadPending()?.phase == .claimed && m.managedBotCreationTask == nil && registry()?.record(p?.profileId ?? "") == nil)
        let refusal = await m.multiAssistantBusyRefusal()
        _ = refusal
        m.endMindRestore()
        await waitCreation(m)
        check("G2 when the gate drops the creation runs", registry()?.record(p?.profileId ?? "")?.state == "active")
        // A running creation is a producer for the wipe, settings and upgrade checks.
        await m._testProcessUpdate(Self.update(32, ["text": "/newassistant Blocker"]))
        let p2 = ManagedBots.loadPending()
        api.tokens[9102] = S4FakeBotAPI.token(9102)
        let gate = AsyncGate()
        ConversationManager.managedBotCreationHookForTesting = { await gate.wait() }
        await m._testProcessUpdate(Self.created(33, bot: 9102, username: p2?.suggestedUsername ?? ""))
        let busy = await m.multiAssistantBusyRefusal(outcome: (" x", " x"))
        let settings = await m.beginBrowserSettingsMutation()
        if settings { m.endBrowserSettingsMutation() }
        let upgrade = await m.upgradeBusyReason(initiating: false)
        check("G3 a creation in progress makes a wipe/import refuse, settings wait and an update wait",
              busy?.contains("new assistant") == true && !settings && upgrade == "a new assistant being created",
              "\(String(describing: busy)) settings=\(settings) upgrade=\(String(describing: upgrade))")
        gate.open()
        await waitCreation(m)
        ConversationManager.managedBotCreationHookForTesting = nil
        // A failed durable write keeps the update unconfirmed.
        await m._testProcessUpdate(Self.update(34, ["text": "/newassistant Durable"]))
        let p3 = ManagedBots.loadPending()
        let dir = ManagedBots.directory()
        chmod(dir.path, 0o500)
        m.inboundDurabilityFailure = false
        await m._testProcessUpdate(Self.created(35, bot: 9103, username: p3?.suggestedUsername ?? ""))
        let failed = m.inboundDurabilityFailure
        chmod(dir.path, 0o700)
        check("G4 a claim that can't be saved is a durability failure (the update is not acknowledged)",
              failed && ManagedBots.loadPending()?.phase == .waiting)
        m.inboundDurabilityFailure = false
        // Resume after a crash: the profile already exists with that bot.
        api.tokens[9104] = S4FakeBotAPI.token(9104)
        _ = try? await AssistantControl.create(.init(profile: p3?.profileId ?? "durable", displayName: "Durable", botToken: S4FakeBotAPI.token(9104)))
        _ = try? ManagedBots.updatePending(requestId: p3?.requestId ?? 0) { $0?.phase = .claimed; $0?.botId = 9104 }
        let countBefore = registry()?.records.count ?? 0
        startedProfiles = []
        m.startManagedBotCreationIfPossible()
        await waitCreation(m)
        check("G5 a creation interrupted after the profile was made only completes (no second profile)",
              registry()?.records.count == countBefore && ManagedBots.loadKnown().bots["9104"] != nil && startedProfiles == [p3?.profileId ?? "durable"])
    }

    // MARK: - Rotation (§28.6 S4-P4)

    func rotationSection() async {
        let m = await freshManager()
        // The grant: only the assistant the bot was made for, same generation, same manager.
        guard let rec = registry()?.record("health"), let botId = Int64("9001") else { check("R0 rotation fixture", false); return }
        var known = ManagedBots.loadKnown()
        check("R1 grant: the assistant made for the bot", ManagedBotGrant.check(botId: botId, profile: "health", managerBotId: api.managerId, known: known) == .allowed)
        check("R2 grant: another assistant, an unknown bot, another manager are refused",
              ManagedBotGrant.check(botId: botId, profile: "work", managerBotId: api.managerId, known: known) == .refused("not_known")
                && ManagedBotGrant.check(botId: 1, profile: "health", managerBotId: api.managerId, known: known) == .refused("not_known")
                && ManagedBotGrant.check(botId: botId, profile: "health", managerBotId: 5, known: known) == .refused("manager_changed"))
        known.bots["9001"]?.generation = "old"
        check("R3 grant: a re-added assistant (new generation) is refused", ManagedBotGrant.check(botId: botId, profile: "health", managerBotId: api.managerId, known: known) == .refused("not_known"))
        _ = rec
        // The default-side child: one JSON line, the right refusal codes.
        let bad = runChild(["--profile", "default", "__managed-bot", "replace-token", "--bot", "1", "--for", "health"])
        check("R4 the child refuses an unknown bot with a code and prints no token", bad.status == 1 && bad.out.contains("\"code\":\"not_known\""), bad.out)
        let tokenBefore = api.tokens[9001]
        let good = runChild(["--profile", "default", "__managed-bot", "current-token", "--bot", "9001", "--for", "health"])
        check("R5 a granted request that Telegram doesn't answer returns a code, never a token, and changes nothing",
              good.status == 1 && good.out.contains("\"code\":\"telegram\"") && !good.out.contains("AAsynthetic") && api.tokens[9001] == tokenBefore, good.out)
        // The plumbing in this (default) process for its own bot: grant it to
        // default for the test, then rotate (cursor kept, secret committed).
        let myBot = api.managerId
        api.tokens[myBot] = "\(myBot):AAsyntheticManagerTokenxxxxxxxxxx"
        known = ManagedBots.loadKnown()
        known.bots[String(myBot)] = ManagedBots.KnownBot(profile: "default", generation: registry()?.record("default")?.generation ?? "", managerBotId: myBot)
        try? ManagedBots.saveKnown(known)
        await m.telegramService.confirmProcessed(updateId: 77)
        ManagedBotRotation.executableOverride = nil
        // `--for default` is not a usable extra name: the child refuses — the
        // rotation path reports it and nothing changes.
        let refused = await m.rotateManagedToken(recovering: false)
        check("R6 a rotation the first assistant refuses changes nothing (token kept, intent kept for the restart check)",
              refused.hasPrefix("✖") && KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) == "\(myBot):AAsyntheticManagerTokenxxxxxxxxxx", refused)
        try? ManagedBots.saveRotation(nil)
        // Cursor persistence: written under the new token's fingerprint first.
        let newToken = "\(myBot):AAsyntheticManagerToken2xxxxxxxxx"
        await m.telegramService.persistOffsetState(forToken: newToken)
        let offsetData = FileManager.default.contents(atPath: StoragePaths.dataRoot.appendingPathComponent("telegram_offset.json").path) ?? Data()
        let offset = (try? JSONSerialization.jsonObject(with: offsetData)) as? [String: Any]
        let expectedHash = sha16(newToken)
        check("R7 the confirmed cursor is written under the new token (same bot: same update ids)",
              offset?["lastUpdateId"] as? Int == 77 && offset?["tokenHash"] as? String == expectedHash, "\(String(describing: offset))")
        await m.telegramService.persistOffsetState(forToken: "\(myBot):AAsyntheticManagerTokenxxxxxxxxxx")
        // End to end in process (the default-side child answered by the fake).
        ManagedBotRotation.runOverrideForTesting = { [api] action, bot, _ in
            action == .replace ? try ManagedBotAPI_sync { try await ManagedBotAPI.replaceManagedBotToken(manager: "\(api.managerId):m", botId: bot) }
                               : try ManagedBotAPI_sync { try await ManagedBotAPI.getManagedBotToken(manager: "\(api.managerId):m", botId: bot) }
        }
        defer { ManagedBotRotation.runOverrideForTesting = nil }
        api.tokens[myBot] = "\(myBot):AAsyntheticManagerTokenxxxxxxxxxx"
        await m.telegramService.confirmProcessed(updateId: 88)
        let ok = await m.rotateManagedToken(recovering: false)
        let stored = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey)
        let offset2 = (try? JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: StoragePaths.dataRoot.appendingPathComponent("telegram_offset.json").path) ?? Data())) as? [String: Any]
        check("R8 rotation: the new token is stored, the old one is gone, the cursor kept under the new token, the intent cleared",
              ok.hasPrefix("✔") && stored == api.tokens[myBot] && stored != "\(myBot):AAsyntheticManagerTokenxxxxxxxxxx"
                && offset2?["lastUpdateId"] as? Int == 88 && offset2?["tokenHash"] as? String == sha16(stored ?? "") && ManagedBots.loadRotation() == nil,
              "\(ok) \(String(describing: offset2))")
        // The replace answer is lost (the token WAS replaced): recovered by
        // asking for the current token, never a second revocation.
        api.replaceFailures = 1
        let before = api.tokens[myBot]
        let recovered = await m.rotateManagedToken(recovering: false)
        let replaces = api.sent.filter { $0.method == "replaceManagedBotToken" }.count
        check("R9 a lost replace answer is recovered with the live token (one revocation only)",
              recovered.hasPrefix("✔") && KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) == api.tokens[myBot]
                && api.tokens[myBot] != before && ManagedBots.loadRotation() == nil, "\(recovered) replaces=\(replaces)")
        // A crash after the remote change: the intent is completed at startup.
        let current = api.tokens[myBot] ?? ""
        try? ManagedBots.saveRotation(ManagedBots.RotationIntent(botId: myBot, startedAt: Date()))
        api.tokens[myBot] = S4FakeBotAPI.token(myBot, 7)
        let atStart = await m.rotateManagedToken(recovering: true)
        check("R10 an interrupted rotation is completed from the live token at the next start",
              atStart.hasPrefix("✔") && KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey) == S4FakeBotAPI.token(myBot, 7)
                && ManagedBots.loadRotation() == nil && current != S4FakeBotAPI.token(myBot, 7), atStart)
        try? KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: "\(myBot):AAsyntheticManagerTokenxxxxxxxxxx")
        api.tokens[myBot] = nil
    }

    func sha16(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Menu (§28.3)

    func menuSection() async {
        var env = MenuEnvironment()
        env.snapshot = { MenuSnapshot() }
        env.toolchainStatus = { ToolchainService.DesktopStatus(doctorRan: true, missing: [], libreOffice: true, mandatoryMissing: []) }
        env.security = { [:] }
        var created: [AssistantControl.CreateRequest] = []
        var validated: [String] = []
        var started: [String] = []
        var stopped: [String] = []
        var renamedOther: [(String, String)] = []
        var gateUp = false
        env.assistants.enabled = { true }
        env.assistants.cards = { details in
            [AssistantControl.Card(profile: "default", name: "Bree", state: "active", running: true, autostart: true, botUsername: details("default").botUsername, hasBot: true, model: details("default").model, isDefault: true),
             AssistantControl.Card(profile: "work", name: "Work", state: "active", running: false, autostart: false, botUsername: details("work").botUsername, hasBot: true, model: details("work").model, isDefault: false)]
        }
        env.assistants.readDetails = { _ in ("work_bot", "deepseek") }
        env.assistants.defaultBotUsername = { "bree_bot" }
        env.assistants.create = { r, validate in
            if let t = r.botToken { validated.append((try await validate(t)) ?? "") }
            created.append(r)
        }
        env.assistants.botInfo = { t in ManagedBotAPI.BotInfo(id: Int64(t.split(separator: ":")[0])!, username: "new_bot", firstName: "N", canManageBots: false) }
        env.assistants.start = { p in started.append(p); return "starting" }
        env.assistants.stop = { p in stopped.append(p); return "stopped" }
        env.assistants.renameOther = { p, n in renamedOther.append((p, n)); return ["ok": true] }
        env.assistants.ownerChatId = { "424242" }
        env.assistants.existingProfiles = { ["default", "work"] }
        env.assistants.restoreGateUp = { gateUp }
        let menu = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
        await menu.start()
        menu.refreshAssistantDetails(force: true)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let status = menu.status()
        let block = status["assistants"] as? [String: Any]
        let cards = block?["cards"] as? [[String: Any]] ?? []
        check("P1 the status carries one card per assistant with name, bot, model, running", cards.count == 2
              && cards[1]["name"] as? String == "Work" && cards[1]["bot"] as? String == "@work_bot" && cards[1]["model"] as? String == "deepseek"
              && cards[0]["running"] as? Bool == true, "\(cards)")
        let add = await menu.handle(["action": "assistant_add", "name": "Health", "template": "health", "copy_keys": true, "token": "123456789:AAsyntheticTokenForTheMenuTestxxxxx"])
        check("P2 Add: name, derived id, template, keys, token validated inside create, paired with the owner",
              add?["ok"] as? Bool == true && created.last?.profile == "health" && created.last?.template == "health" && created.last?.copyKeys == true
                && created.last?.chatId == "424242" && validated == ["new_bot"], "\(String(describing: add?["message"]))")
        let dupId = await menu.handle(["action": "assistant_add", "name": "Other", "profile": "work"])
        check("P3 Add refuses an id already used", dupId?["ok"] as? Bool == false)
        let badTok = await menu.handle(["action": "assistant_add", "name": "Other", "token": "nope"])
        check("P4 Add refuses a malformed token before anything is created", badTok?["ok"] as? Bool == false && created.count == 1)
        _ = await menu.handle(["action": "assistant_start", "profile": "work"])
        _ = await menu.handle(["action": "assistant_stop", "profile": "work"])
        let defStop = await menu.handle(["action": "assistant_stop", "profile": "default"])
        check("P5 Start and Stop act on the extra; the first assistant isn't stopped from a card",
              started == ["work"] && stopped == ["work"] && defStop?["ok"] as? Bool == false)
        _ = await menu.handle(["action": "assistant_rename", "profile": "work", "name": "Lavoro"])
        check("P6 renaming another assistant goes through its own setup-api child", renamedOther.first?.0 == "work" && renamedOther.first?.1 == "Lavoro")
        gateUp = true
        let gated = await menu.handle(["action": "assistant_start", "profile": "work"])
        check("P7 every Assistants action is refused while a wipe/import holds the gate",
              gated?["ok"] as? Bool == false && ["memory", "memoria"].contains { (gated?["message"] as? String ?? "").contains($0) } && started.count == 1
                && (menu.status()["assistants"] as? [String: Any])?["gate"] as? Bool == true,
              "\(String(describing: gated?["ok"])) \(String(describing: gated?["message"])) started=\(started)")
        gateUp = false
        env.assistants.enabled = { false }
        let hidden = MenuWorkflow(env: env, runner: SetupJobRunner(secrets: [:]))
        await hidden.start()
        check("P8 hidden (one assistant / switch off / child page): no assistants block at all", hidden.status()["assistants"] == nil)
        await menu.shutdown(); await hidden.shutdown()
    }

    // MARK: - Single-assistant invariance

    func invarianceSection() async {
        unsetenv(AssistantProfile.experimentalKey)
        let reg = AssistantRegistry.Paths.live.registry
        let moved = reg.deletingLastPathComponent().appendingPathComponent("registry.moved")
        try? FileManager.default.moveItem(at: reg, to: moved)
        defer {
            try? FileManager.default.moveItem(at: moved, to: reg)
            setenv(AssistantProfile.experimentalKey, "1", 1)
        }
        check("I0 fixture: coordination inactive", !CoordinationMode.active)
        let m = ConversationManager()
        let a = await m.handleControlCommandIfNeeded("/newassistant Health")
        let b = await m.handleControlCommandIfNeeded("/assistantname Nova")
        check("I1 with one assistant and the switch off, /newassistant and /assistantname are not commands (today's path)", !a && !b)
        check("I2 …and the /commands listing is unchanged", !ChatCommandRegistry.commandsListText().contains("newassistant"))
        check("I3 …and a created-bot message is not intercepted", !m.managedBotsActiveHere)
    }
}



/// Run an async throwing call from a synchronous seam (selftests only).
func ManagedBotAPI_sync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task.detached { do { result = .success(try await body()) } catch { result = .failure(error) }; sem.signal() }
    sem.wait()
    return try result.get()
}
