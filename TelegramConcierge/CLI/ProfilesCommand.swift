import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `briglia profiles …` — extra assistants on this computer
/// (MULTI_ASSISTANT_PLAN v5 §10.1). Stage 1 of R1 ships HIDDEN (plan D1):
/// the command is not listed and refuses to run unless
/// `BRIGLIA_EXPERIMENTAL_PROFILES=1` is set. `remove`, `stop`, the
/// supervisor and the menu arrive with the later stages.
struct ProfilesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Manage extra assistants on this computer (experimental).",
        shouldDisplay: false,
        subcommands: [List.self, Add.self, Remove.self, Stop.self]
    )

    static func requireExperimental() throws {
        guard AssistantProfile.experimentalEnabled else {
            print("✖ Several assistants on one computer are not available in this version yet.")
            throw ExitCode(2)
        }
    }

    static func requireDefault() throws {
        guard AssistantProfile.isDefault else {
            print("✖ Manage assistants from the default assistant: run `briglia profiles …` without --profile.")
            throw ExitCode(2)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List the assistants on this computer.")

        func run() throws {
            try ProfilesCommand.requireExperimental()
            let doc: AssistantRegistry.Document?
            do { doc = try AssistantRegistry.read(.live) } catch {
                print("✖ \(error)")
                throw ExitCode(1)
            }
            guard let doc else {
                print("Only the default assistant exists on this computer.")
                return
            }
            for r in doc.records.sorted(by: { ($0.name == AssistantProfile.defaultName ? "" : $0.name) < ($1.name == AssistantProfile.defaultName ? "" : $1.name) }) {
                let bot = r.bot.current == nil ? "no bot" : "bot set"
                let inbox = r.inbox.current == nil ? "no inbox" : "inbox set"
                let state = r.state == "active" ? "" : " · \(r.state)"
                print("\(r.name)\t\(r.displayName)\t\(bot)\t\(inbox)\(state)")
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an assistant.")

        @Argument(help: "Profile id: lower-case letters, digits and -, up to 24 characters.")
        var name: String

        @Option(name: .customLong("name"), help: "The assistant's name (also the name it uses for itself).")
        var displayName: String

        @Option(name: .customLong("home"), help: "Home folder (default ~/Briglia/<profile>).")
        var home: String?

        @Flag(name: .customLong("copy-keys"), help: "Copy the default assistant's API keys and model choices (never its bot, ChatGPT login, inbox or spend).")
        var copyKeys = false

        @Flag(name: .customLong("bot-token-stdin"), help: "Read the new assistant's own Telegram bot token from standard input.")
        var botTokenStdin = false

        func run() async throws {
            try ProfilesCommand.requireExperimental()
            try ProfilesCommand.requireDefault()
            try IdentityMigration.gateMutatingEntry()
            let botToken: String? = botTokenStdin
                ? (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            if let botToken, AssistantRegistry.digest(.bot, botToken) == nil {
                print("✖ That doesn't look like a bot token (format 123456789:AA…, from @BotFather).")
                throw ExitCode(2)
            }
            let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let homeFolder = home.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
                ?? LandingZone.defaultExtraHome(name)
            do {
                try await AssistantControl.create(AssistantControl.CreateRequest(
                    profile: name, displayName: display, homeFolder: homeFolder, botToken: botToken, copyKeys: copyKeys),
                    autostart: true)
            } catch {
                print("✖ \(error)")
                throw ExitCode(1)
            }
            print("✔ Added the assistant ‘\(display)’ (profile \(name)). Home folder: \(homeFolder.path)")
            print("  Start it with: briglia --profile \(name) daemon")
        }
    }
}

/// Creation and per-profile initialisation (shared by the CLI now and the
/// menu later).
enum ProfileProvisioning {
    struct ProvisioningError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// The explicit allow-list copied by `--copy-keys` (plan §10.1, D2): LLM
    /// provider keys, provider profiles and servers, web-search, image and
    /// voice keys, model/effort/provider selection. Never: the Telegram bot
    /// or pairing, the ChatGPT login, the AgentMail key/inbox, the persona
    /// name, spend caps or history, the user profile.
    static let copyableSecretKeys: [String] = [
        KeychainHelper.llmProviderKey, ProviderProfiles.activeProfileKey, ProviderProfiles.runtimeProtocolKey,
        ProviderProfiles.runtimeNativeMediaKey, ProviderServers.listKey, ProviderServers.customBindingKey,
        ProviderServers.localBindingKey,
        KeychainHelper.openRouterApiKeyKey, KeychainHelper.openRouterModelKey, KeychainHelper.openRouterWebSearchModelKey,
        KeychainHelper.openRouterProvidersKey, KeychainHelper.openRouterReasoningEffortKey, ProviderProfiles.openrouterTextOnlyKey,
        ProviderProfiles.opencodeApiKeyKey, ProviderProfiles.opencodeModelKey, ProviderProfiles.opencodeReasoningEffortKey,
        ProviderProfiles.opencodeTextOnlyKey,
        ProviderProfiles.customBaseURLKey, ProviderProfiles.customApiKeyKey, ProviderProfiles.customModelKey,
        ProviderProfiles.customReasoningEffortKey, ProviderProfiles.customTextOnlyKey, ProviderProfiles.customProtocolKey,
        ProviderProfiles.customNativeMediaKey,
        ProviderProfiles.subscriptionModelKey, ProviderProfiles.subscriptionEffortKey, ProviderProfiles.subscriptionTextOnlyKey,
        ProviderProfiles.openaiApiKeyKey, ProviderProfiles.openaiModelKey, ProviderProfiles.openaiEffortKey,
        ProviderProfiles.openaiTextOnlyKey,
        KeychainHelper.lmStudioBaseURLKey, KeychainHelper.lmStudioModelKey, ProviderProfiles.localTextOnlyKey,
        KeychainHelper.lmStudioDescriptionModelKey, KeychainHelper.lmStudioDescriptionBaseURLKey,
        KeychainHelper.openAICompatibleBaseURLKey, KeychainHelper.openAICompatibleModelKey,
        KeychainHelper.openAICompatibleApiKeyKey, KeychainHelper.openAICompatibleReasoningEffortKey,
        KeychainHelper.textOnlyModelEnabledKey, KeychainHelper.visionPreprocessorModelKey,
        KeychainHelper.visionPreprocessorProviderKey, KeychainHelper.visionPreprocessorBackendKey,
        KeychainHelper.visionPreprocessorReasoningEffortKey,
        KeychainHelper.serperApiKeyKey, KeychainHelper.jinaApiKeyKey,
        KeychainHelper.webSearchOpenAIApiKeyKey, KeychainHelper.webSearchOpenCodeApiKeyKey,
        KeychainHelper.geminiApiKeyKey, KeychainHelper.imageGenerationProviderKey, KeychainHelper.geminiImageModelKey,
        KeychainHelper.geminiImageInputCostPerMillionTokensUSDKey, KeychainHelper.geminiImageOutputTextCostPerMillionTokensUSDKey,
        KeychainHelper.geminiImageOutputImageCostPerMillionTokensUSDKey,
        KeychainHelper.openAIImageApiKeyKey, KeychainHelper.openAIImageModelKey, KeychainHelper.openAIImagePreciseModelKey,
        KeychainHelper.openAIImageQualityKey, KeychainHelper.openAIImageOutputFormatKey, KeychainHelper.openAIImageModerationKey,
        KeychainHelper.voiceTranscriptionProviderKey, KeychainHelper.openAITranscriptionApiKeyKey,
    ]

    /// Keys the init child accepts: the allow-list plus the two identity
    /// values `profiles add` sets itself.
    static var initAcceptedKeys: Set<String> {
        Set(copyableSecretKeys + [KeychainHelper.assistantNameKey, KeychainHelper.telegramBotTokenKey,
                                  ProviderProfiles.subscriptionGenerationKey, SubscriptionSharing.accountFingerprintKey,
                                  // Stage 4 (§28.3/§28.4): the owner's chat, the bot's @handle, the greeting flag.
                                  KeychainHelper.telegramChatIdKey, KeychainHelper.telegramBotUsernameKey,
                                  KeychainHelper.assistantGreetingPendingKey])
    }

    /// Default's values for the allow-list (read in default's process).
    /// ChatGPT is never copied but SHARED (§25.6, D2): when default's provider
    /// is ChatGPT, the new extra is bound to the current machine login
    /// (generation + account fingerprint, from ONE validated snapshot); no
    /// token is ever copied. An unusable login binds nothing.
    static func copyableSecrets() -> [String: String] {
        var out: [String: String] = [:]
        for key in copyableSecretKeys {
            if let value = KeychainHelper.load(key: key), !value.isEmpty { out[key] = value }
        }
        if ProviderProfiles.activeProfile() == .chatgpt,
           let state = try? SubscriptionAuthStore(directory: MachinePaths.defaultConfigRoot()).read(),
           let credential = state.credential, state.requiresLogin != true, state.pendingLogin == nil {
            out[ProviderProfiles.subscriptionGenerationKey] = state.generation
            out[SubscriptionSharing.accountFingerprintKey] = SubscriptionSharing.fingerprint(credential.account)
            if out[KeychainHelper.openAICompatibleApiKeyKey] != nil { out[KeychainHelper.openAICompatibleApiKeyKey] = state.generation }
        } else if ProviderProfiles.activeProfile() == .chatgpt {
            // No usable login to bind: the runtime slot must not carry a stale generation.
            out.removeValue(forKey: KeychainHelper.openAICompatibleApiKeyKey)
        }
        return out
    }

    static func validateDisplayName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 40,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProvisioningError("the assistant's name must be 1–40 characters without control characters")
        }
    }

    /// Create the profile (plan §5.7 `add`) and activate it at once (the
    /// original one-step behaviour; `profiles add` without stage-4 setup).
    static func add(name: String, displayName: String, homeFolder: URL, botToken: String? = nil,
                    template: String? = nil, registryPaths: AssistantRegistry.Paths = .live) throws {
        let pending = try beginAdd(name: name, displayName: displayName, homeFolder: homeFolder, botToken: botToken,
                                   template: template, registryPaths: registryPaths)
        do { try pending.activate(autostart: true) } catch {
            pending.rollback()
            throw error
        }
    }

    /// A profile published PROVISIONAL (`adding`) by its operation, which
    /// holds the tx lease, `machine/identity-tx.lock` and the ChatGPT sharing
    /// lock until `activate` or `rollback` (§28.6 S4-P1). While it lasts no
    /// member may enter except this operation's `__profile-init` children
    /// (`MemberEntry`, `BRIGLIA_PROVISIONING_OP`), and the operation may
    /// reserve the profile's bot (`AssistantRegistry.begin(provisioningOp:)`).
    final class PendingAdd {
        let name: String
        let op: String
        let generation: String
        let registryPaths: AssistantRegistry.Paths
        let registryExisted: Bool
        private var adder: ProfileFileLock?
        private var identity: ProfileFileLock?
        private var share: ProfileFileLock?
        private(set) var finished = false

        fileprivate init(name: String, op: String, generation: String, registryPaths: AssistantRegistry.Paths,
                         registryExisted: Bool, adder: ProfileFileLock, identity: ProfileFileLock, share: ProfileFileLock?) {
            self.name = name; self.op = op; self.generation = generation; self.registryPaths = registryPaths
            self.registryExisted = registryExisted; self.adder = adder; self.identity = identity; self.share = share
        }

        /// The environment entry that admits this operation's init child.
        var admissionEnvironment: [String: String] { [MemberEntry.provisioningOpKey: op] }

        /// Activate only our own provisional record (same op and generation).
        /// On failure the operation keeps its leases and its rollback (Codex
        /// stage-4 S4-R1-7), unless the record is visibly active already (the
        /// write landed but reported an error): then it counts as activated.
        func activate(autostart: Bool) throws {
            precondition(!finished, "provisional add already finished")
            do {
                if let hook = ProfileProvisioning.activateFaultForTesting { try hook() }
                try AssistantRegistry.withLock(registryPaths) { doc in
                    guard var d = doc, let i = d.index(name), d.records[i].state == "adding",
                          d.records[i].addingOp == op, d.records[i].generation == generation else {
                        throw ProvisioningError("‘\(name)’ changed while it was being added; nothing was activated")
                    }
                    d.records[i].state = "active"
                    d.records[i].addingOp = nil
                    d.records[i].autostart = autostart
                    doc = d
                }
            } catch {
                if let r = (try? AssistantRegistry.read(registryPaths))??.record(name), r.state == "active", r.generation == generation {
                    release()
                    return
                }
                throw error
            }
            release()
        }

        /// Undo our own provisional record and its roots (never an active one).
        func rollback() {
            guard !finished else { return }
            defer { release() }
            ProfileProvisioning.rollbackAdd(name: name, op: op, generation: generation, registryPaths: registryPaths,
                                            removeRegistry: !registryExisted)
        }

        private func release() {
            finished = true
            adder?.release(); adder = nil
            try? FileManager.default.removeItem(at: registryPaths.txLease(op))
            share?.release(); share = nil
            identity?.release(); identity = nil
        }

        deinit { if !finished { rollback() } }
    }

    /// Publish the profile provisional (plan §5.7 `add`): refused at the
    /// assistant cap, for an invalid/reserved/existing id or a name already in
    /// use. Holds `machine/identity-tx.lock` (non-blocking) while the registry
    /// is created and default's current bot/inbox are seeded, so no default
    /// identity change started before the registry existed can commit after
    /// it.
    static func beginAdd(name: String, displayName: String, homeFolder: URL, botToken: String? = nil,
                         template: String? = nil, registryPaths: AssistantRegistry.Paths = .live) throws -> PendingAdd {
        guard AssistantProfile.isUsableExtraName(name) else {
            throw ProvisioningError("‘\(name)’ is not a valid assistant id (lower-case letters, digits and -, up to 24; not default/all/shared/profiles)")
        }
        try validateDisplayName(displayName)
        try MachinePaths.ensureMachineDir()
        let identity: ProfileFileLock
        switch ProfileFileLock.take(MachinePaths.identityTxLock) {
        case .acquired(let l): identity = l
        case .busy: throw ProvisioningError("finish the bot or email change in your first assistant, then try again")
        case .failed(let why): throw ProvisioningError(why)
        }
        // The new extra becomes a sharer of the ChatGPT login (§25.11).
        let share: ProfileFileLock?
        do { share = try ChatGPTShare.takeLock() } catch { identity.release(); throw ProvisioningError("\(error)") }
        // Codex stage-2 F4: the record is published PROVISIONAL (`adding`,
        // which the entry protocol never admits) under this operation's tx
        // lease, flipped to `active` only by `activate`; a failed add removes
        // only its own still-provisional record.
        let op = UUID().uuidString.lowercased()
        let adder: ProfileFileLock
        do {
            try PrivateStorage.ensureDirectory(registryPaths.root, mode: 0o700)
            try PrivateStorage.ensureDirectory(registryPaths.txDir, mode: 0o700)
            guard case .acquired(let l) = ProfileFileLock.take(registryPaths.txLease(op)) else {
                throw ProvisioningError("could not create the lease for adding this assistant")
            }
            adder = l
        } catch {
            share?.release(); identity.release()
            throw error
        }
        func releaseAll() {
            adder.release()
            try? FileManager.default.removeItem(at: registryPaths.txLease(op))
            share?.release()
            identity.release()
        }
        var generation = ""
        // A Briglia running without a member lease (started before any
        // registry, switch off) would sit outside every barrier (R1).
        let blocking = UnleasedInstances.findings(registryPaths: registryPaths)
        if !blocking.isEmpty { releaseAll(); throw ProvisioningError(UnleasedInstances.describe(blocking)) }
        let registryExisted = AssistantRegistry.exists(registryPaths)
        let defaultBot = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey)
        let defaultInbox = KeychainHelper.load(key: KeychainHelper.agentMailInboxAddressKey)
        let defaultName = (KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try AssistantRegistry.withLock(registryPaths) { doc in
                var d = doc ?? AssistantRegistry.Document(version: 1, records: [])
                if d.record(AssistantProfile.defaultName) == nil {
                    var seed = AssistantRegistry.newRecord(name: AssistantProfile.defaultName,
                                                           displayName: defaultName.isEmpty ? "Bree" : defaultName)
                    if let b = defaultBot, let h = AssistantRegistry.digest(.bot, b) { seed.bot.current = h }
                    if let i = defaultInbox, let h = AssistantRegistry.digest(.inbox, i) { seed.inbox.current = h }
                    d.records.insert(seed, at: 0)
                }
                AssistantRegistry.cleanAll(&d, registryPaths)
                // Refused while an upgrade barrier exists (§5.7, §6.3 step 3).
                if let barrier = UpgradeBarrier.current(), barrier.isActive {
                    throw ProvisioningError("Briglia is updating; try again in a minute")
                }
                guard d.record(name) == nil, !FileManager.default.fileExists(atPath: AssistantProfile.extraConfigRoot(name).path),
                      !FileManager.default.fileExists(atPath: AssistantProfile.extraDataRoot(name).path) else {
                    throw ProvisioningError("an assistant with the id ‘\(name)’ already exists")
                }
                guard d.records.count < AssistantProfile.maxProfiles else {
                    throw ProvisioningError("this computer already has \(AssistantProfile.maxProfiles) assistants, the maximum")
                }
                guard !AssistantRegistry.displayNameTaken(displayName, in: d) else {
                    throw ProvisioningError("another assistant is already called ‘\(displayName)’ — choose a different name")
                }
                // Early refusal of a bot another assistant holds, before anything
                // is created (the reservation itself is a transaction later).
                if let botToken, let h = AssistantRegistry.digest(.bot, botToken),
                   let owner = AssistantRegistry.holder(of: h, kind: .bot, excluding: name, in: d) {
                    throw ProvisioningError(AssistantRegistry.conflictMessage(.bot, owner: owner))
                }
                let configRoot = AssistantProfile.extraConfigRoot(name)
                let dataRoot = AssistantProfile.extraDataRoot(name)
                try PrivateStorage.ensureDirectory(configRoot, mode: 0o700)
                try PrivateStorage.ensureDirectory(dataRoot, mode: 0o700)
                let meta = AssistantProfile.Metadata(version: 1, name: name, displayName: displayName,
                                                     createdAt: Date(), homeFolder: homeFolder.path, template: template)
                try PrivateStorage.writeAtomically(try AssistantProfile.encodeMetadata(meta),
                                                   to: AssistantProfile.metadataURL(name), mode: 0o600)
                try FileManager.default.createDirectory(at: homeFolder, withIntermediateDirectories: true)
                var record = AssistantRegistry.newRecord(name: name, displayName: displayName)
                record.state = "adding"
                record.addingOp = op
                generation = record.generation
                d.records.append(record)
                doc = d
            }
        } catch {
            releaseAll()
            throw error
        }
        afterProvisionalPublish()
        // Publish, then look: an inactive Briglia that took its instance lock
        // before the registry existed either sees the registry and enrolls
        // (late enrollment) or is seen here. Give a racing enrollment a moment.
        let deadline = Date().addingTimeInterval(unleasedGraceSeconds)
        while case let late = UnleasedInstances.findings(registryPaths: registryPaths), !late.isEmpty {
            if Date() >= deadline {
                rollbackAdd(name: name, op: op, generation: generation, registryPaths: registryPaths, removeRegistry: !registryExisted)
                releaseAll()
                throw ProvisioningError(UnleasedInstances.describe(late))
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return PendingAdd(name: name, op: op, generation: generation, registryPaths: registryPaths,
                          registryExisted: registryExisted, adder: adder, identity: identity, share: share)
    }

    static var unleasedGraceSeconds: TimeInterval = 5

    /// Selftests: fail the activation write (S4-R1-7).
    nonisolated(unsafe) static var activateFaultForTesting: (() throws -> Void)?

    /// Test seam: runs right after the provisional record was published.
    static var afterProvisionalPublish: () -> Void = {}

    /// Undo our own just-created profile while it is still provisional
    /// (`adding`, same op and generation): nothing could have entered it. An
    /// active (or otherwise changed) record is never deleted here.
    static func rollbackAdd(name: String, op: String, generation: String, registryPaths: AssistantRegistry.Paths, removeRegistry: Bool,
                            configRoot: URL? = nil, dataRoot: URL? = nil) {
        var removed = false
        _ = try? AssistantRegistry.withLock(registryPaths) { doc in
            guard var d = doc, let i = d.index(name), d.records[i].state == "adding",
                  d.records[i].addingOp == op, d.records[i].generation == generation else { return }
            try? FileManager.default.removeItem(at: configRoot ?? AssistantProfile.extraConfigRoot(name))
            try? FileManager.default.removeItem(at: dataRoot ?? AssistantProfile.extraDataRoot(name))
            d.records.remove(at: i)
            doc = d
            removed = true
        }
        if removed, removeRegistry, let doc = (try? AssistantRegistry.read(registryPaths)) ?? nil,
           doc.records.allSatisfy({ $0.name == AssistantProfile.defaultName }) {
            try? FileManager.default.removeItem(at: registryPaths.registry)
        }
    }

    /// Run `briglia --profile <name> __profile-init` with `payload` (JSON) on
    /// stdin: the profile's own process writes its own secret store.
    static func runInit(profile: String, payload: [String: Any],
                        executable: String = AgentMailService.brigliaPath(),
                        extraEnvironment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--profile", profile, "__profile-init"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        env[AssistantProfile.experimentalKey] = "1"
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try? input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProvisioningError("initialising ‘\(profile)’ failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

/// Hidden: write the initial settings of the SELECTED extra profile from a
/// JSON payload on stdin (allow-listed keys only). Run by `profiles add`.
struct ProfileInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__profile-init",
        abstract: "Internal: initialise an extra assistant's settings.",
        shouldDisplay: false
    )

    func run() throws {
        guard AssistantProfile.isExtra else {
            print("✖ __profile-init runs only for an extra assistant")
            throw ExitCode(2)
        }
        // Only the add operation that is still setting this assistant up
        // (MemberEntry admitted it to its provisional record): never against
        // an active assistant (Codex stage-4 round-1 note).
        guard let record = (try? AssistantRegistry.read(.live))??.record(AssistantProfile.selectedName),
              record.state == "adding", MemberEntry.provisioningAdmits(record, role: .session(kind: "__profile-init")) else {
            print("✖ __profile-init runs only while its assistant is being added")
            throw ExitCode(2)
        }
        try StoragePaths.ensureRootsChecked()
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let secrets = object["secrets"] as? [String: String] else {
            print("✖ __profile-init: malformed payload")
            throw ExitCode(2)
        }
        let accepted = ProfileProvisioning.initAcceptedKeys
        let refused = secrets.keys.filter { !accepted.contains($0) }
        guard refused.isEmpty else {
            print("✖ __profile-init: refusing keys outside the allow-list: \(refused.sorted().joined(separator: ", "))")
            throw ExitCode(2)
        }
        var changes: [String: String?] = [:]
        for (k, v) in secrets { changes[k] = v }
        try KeychainHelper.saveBatch(changes)
    }
}
