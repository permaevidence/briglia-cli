import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Creating, starting, stopping and listing assistants from the default
/// assistant (MULTI_ASSISTANT_PLAN §10.2, §28.3, §28.4): shared by
/// `briglia profiles add`, the menu's Assistants page and `/newassistant`.
/// Every write goes through the stage-1/2 machinery: `ProfileProvisioning.add`
/// (provisional record, unleased-instance check, identity lock), the profile's
/// own `__profile-init` child for its secrets, and the §5.6 reservation
/// transaction for its bot. Nothing here reads or writes another profile's
/// secret store directly.
enum AssistantControl {
    struct ControlError: Error, CustomStringConvertible, LocalizedError {
        let description: String
        init(_ d: String) { description = d }
        var errorDescription: String? { description }
    }

    struct CreateRequest {
        var profile: String
        var displayName: String
        var homeFolder: URL? = nil
        var botToken: String? = nil
        var botUsername: String? = nil
        /// Copy default's API keys and model choices (§10.1 allow-list).
        var copyKeys = true
        /// Pair the new bot with this chat (the owner's private chat).
        var chatId: String? = nil
        var template: String? = nil
        /// The new assistant says hello at its first start (§28.4).
        var greet = false
    }

    /// Test seam: the briglia executable children run (default: this binary).
    nonisolated(unsafe) static var executableOverride: String?
    static var executable: String { executableOverride ?? AgentMailService.brigliaPath() }

    /// Create an extra assistant (§28.6 S4-P1). The record stays provisional
    /// (`adding`, never admitted, never started) through every step — the
    /// profile's own `__profile-init` child, the reservation of its bot
    /// before any use, the optional `validate` of the token (network, inside
    /// the reservation), the secret commit — and is activated last. Any
    /// failure before activation removes exactly this provisional record and
    /// its roots. `autostart`: what the activated record asks for (the menu
    /// and /newassistant start it explicitly afterwards).
    @discardableResult
    static func create(_ r: CreateRequest, autostart: Bool = false,
                       registryPaths: AssistantRegistry.Paths = .live,
                       validate: ((String) async throws -> String?)? = nil) async throws -> URL {
        if let token = r.botToken, AssistantRegistry.digest(.bot, token) == nil {
            throw ControlError("That doesn't look like a bot token (format 123456789:AA…, from @BotFather).")
        }
        let home = r.homeFolder ?? LandingZone.defaultExtraHome(r.profile)
        let pending: ProfileProvisioning.PendingAdd
        do {
            pending = try ProfileProvisioning.beginAdd(name: r.profile, displayName: r.displayName, homeFolder: home,
                                                       botToken: r.botToken, template: r.template, registryPaths: registryPaths)
        } catch {
            throw ControlError("\(error)")
        }
        do {
            if let hook = afterProvisionalForTesting { try await hook(r.profile) }
            var secrets: [String: String] = r.copyKeys ? ProfileProvisioning.copyableSecrets() : [:]
            secrets[KeychainHelper.assistantNameKey] = r.displayName
            if r.greet { secrets[KeychainHelper.assistantGreetingPendingKey] = "true" }
            try ProfileProvisioning.runInit(profile: r.profile, payload: ["secrets": secrets], executable: executable,
                                            extraEnvironment: pending.admissionEnvironment)
            if let token = r.botToken {
                let tx = try AssistantRegistry.begin(profile: r.profile, kind: .bot, rawValue: token, paths: registryPaths,
                                                     provisioningOp: pending.op)
                do {
                    var username = r.botUsername
                    if let validate { username = try await validate(token) ?? username }
                    var botSecrets: [String: String] = [KeychainHelper.telegramBotTokenKey: token]
                    if let chat = r.chatId { botSecrets[KeychainHelper.telegramChatIdKey] = chat }
                    if let u = username, !u.isEmpty { botSecrets[KeychainHelper.telegramBotUsernameKey] = u }
                    try tx.commit {
                        try ProfileProvisioning.runInit(profile: r.profile, payload: ["secrets": botSecrets], executable: executable,
                                                        extraEnvironment: pending.admissionEnvironment)
                    }
                    try tx.finish()   // nobody consumed the old (absent) bot
                } catch {
                    tx.abort()
                    throw error
                }
            }
            try pending.activate(autostart: autostart)
        } catch {
            pending.rollback()
            throw ControlError("‘\(r.displayName)’ could not be set up (\(ManagedBotAPI.scrub("\(error)", token: r.botToken ?? ""))); nothing was left behind.")
        }
        return home
    }

    /// Test seam: runs while the record is provisional, before any init child.
    nonisolated(unsafe) static var afterProvisionalForTesting: ((String) async throws -> Void)?

    // MARK: - Start / stop

    /// Start an extra: autostart on; Linux enables its unit; macOS makes sure
    /// a supervisor runs (an existing one picks the record up; otherwise a
    /// detached extras-only supervisor is started).
    static func start(_ profile: String, registryPaths: AssistantRegistry.Paths = .live) throws -> String {
        guard profile != AssistantProfile.defaultName else {
            throw ControlError("The first assistant is started with `briglia menu` → Start, or `briglia`.")
        }
        try setAutostart(profile, true, registryPaths: registryPaths)
        #if os(Linux)
        if let starter = startOverride { return try starter(profile) }
        guard AgentServiceSupport.installExtraService(profile) else {
            throw ControlError("Could not start its background service (see `briglia doctor`).")
        }
        return "started as a background service"
        #else
        if let starter = startOverride { return try starter(profile) }
        if supervisorRunning(registryPaths) { return "starting (the assistants window picks it up within a second)" }
        try spawnSupervisor(registryPaths: registryPaths)
        return "starting in the background"
        #endif
    }

    /// Stop an extra: autostart off (it stays off), Linux disables its unit,
    /// then the lease-validated SIGTERM of `profiles stop`.
    static func stop(_ profile: String, registryPaths: AssistantRegistry.Paths = .live, wait: TimeInterval = 30) throws -> String {
        guard profile != AssistantProfile.defaultName else {
            throw ControlError("The first assistant is stopped from its own menu (Stop) or its window.")
        }
        try setAutostart(profile, false, registryPaths: registryPaths)
        if let stopper = stopOverride { return try stopper(profile) }
        #if os(Linux)
        AgentServiceSupport.disableExtraUnitIfPresent(profile)
        #endif
        switch ProfileLifecycle.stop(name: profile, wait: wait) {
        case .notRunning: return "stopped"
        case .stopped: return "stopped"
        case .failed(let why): throw ControlError(why)
        }
    }

    nonisolated(unsafe) static var startOverride: ((String) throws -> String)?
    nonisolated(unsafe) static var stopOverride: ((String) throws -> String)?

    /// Autostart on/off. Turning it on (Start) also bumps `startRevision`,
    /// which re-arms a stopped or parked supervisor child (§28.6 S4-P5).
    static func setAutostart(_ profile: String, _ on: Bool, registryPaths: AssistantRegistry.Paths) throws {
        try AssistantRegistry.withLock(registryPaths) { doc in
            guard var d = doc, let i = d.index(profile) else { throw ControlError("There is no assistant ‘\(profile)’ on this computer.") }
            guard d.records[i].state == "active" else { throw ControlError("‘\(profile)’ is being set up or removed; try again in a moment.") }
            d.records[i].autostart = on
            if on { d.records[i].startRevision = (d.records[i].startRevision ?? 0) + 1 }
            doc = d
        }
    }

    static func supervisorRunning(_ paths: AssistantRegistry.Paths) -> Bool {
        ProfileFileLock.probe(paths.root.appendingPathComponent("supervisor.lock")) != .dead
    }

    static func supervisorLogURL(_ paths: AssistantRegistry.Paths) -> URL { paths.root.appendingPathComponent("supervisor.log") }

    /// `briglia __setsid-exec -- briglia daemon --all --extras-only`, its own
    /// session, output appended to `briglia-shared/supervisor.log`. Never
    /// runs the default assistant (that one belongs to its window/menu).
    static func spawnSupervisor(registryPaths: AssistantRegistry.Paths) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["__setsid-exec", "--", executable, "daemon", "--all", "--extras-only"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        env[AssistantProfile.experimentalKey] = "1"
        p.environment = env
        let log = supervisorLogURL(registryPaths)
        let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ControlError("cannot open \(log.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = handle
        p.standardError = handle
        do { try p.run() } catch { throw ControlError("could not start the assistants supervisor: \(error)") }
    }

    // MARK: - Listing (menu Assistants cards)

    struct Card: Equatable {
        var profile: String
        var name: String
        var state: String          // active | adding | removing
        var running: Bool
        var autostart: Bool
        var botUsername: String?
        var hasBot: Bool
        var model: String?
        var isDefault: Bool
    }

    /// Registry + lease probe (cheap). Bot @handle and model come from the
    /// caller's cache (`details`).
    static func cards(registryPaths: AssistantRegistry.Paths = .live,
                      details: (String) -> (botUsername: String?, model: String?) = { _ in (nil, nil) }) -> [Card] {
        guard let doc = (try? AssistantRegistry.read(registryPaths)) ?? nil else { return [] }
        let ordered = doc.records.sorted { a, b in
            if a.name == AssistantProfile.defaultName { return true }
            if b.name == AssistantProfile.defaultName { return false }
            return a.displayName.lowercased() < b.displayName.lowercased()
        }
        return ordered.map { r in
            let isDefault = r.name == AssistantProfile.defaultName
            let dir = isDefault ? MemberLeases.defaultDirectory() : MemberLeases.extraDirectory(r.name, generation: r.generation)
            let running = !MemberLeases.users(dir, assistantsOnly: true).isEmpty
            let d = details(r.name)
            return Card(profile: r.name, name: r.displayName, state: r.state, running: running, autostart: r.autostart,
                        botUsername: d.botUsername, hasBot: r.bot.current != nil, model: d.model, isDefault: isDefault)
        }
    }

    /// `briglia --profile <n> setup-api status`, parsed (bot @handle, model).
    static func readDetails(profile: String) -> (botUsername: String?, model: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["--profile", profile, "setup-api", "status"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        env[AssistantProfile.experimentalKey] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (nil, nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        let username = (json["telegram"] as? [String: Any])?["bot_username"] as? String
        let providers = json["providers"] as? [String: Any]
        var model: String?
        if let active = providers?["active"] as? String,
           let entry = (providers?["profiles"] as? [String: Any])?[active] as? [String: Any] {
            model = entry["model"] as? String
        }
        return (username, model)
    }

    /// The menu's second-process settings page for an extra: `briglia
    /// --profile <n> menu` with `BRIGLIA_MENU_CHILD=1` (no Start/Stop there; if
    /// the assistant runs, its own live menu answers). Detached, output to
    /// that profile's log folder.
    static func openSettings(_ profile: String) throws {
        guard profile != AssistantProfile.defaultName else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["__setsid-exec", "--", executable, "--profile", profile, "menu"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        env[AssistantProfile.experimentalKey] = "1"
        env[MenuChild.key] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw ControlError("could not open its settings: \(error)") }
    }
}

/// A menu opened by the Assistants page for another assistant.
enum MenuChild {
    static let key = "BRIGLIA_MENU_CHILD"
    static var active: Bool { ProcessInfo.processInfo.environment[key] == "1" }
}
