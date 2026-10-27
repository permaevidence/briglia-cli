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
        subcommands: [List.self, Add.self]
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

    struct Add: ParsableCommand {
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

        func run() throws {
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
                try ProfileProvisioning.add(name: name, displayName: display, homeFolder: homeFolder, botToken: botToken)
            } catch {
                print("✖ \(error)")
                throw ExitCode(1)
            }
            var secrets: [String: String] = [:]
            if copyKeys { secrets = ProfileProvisioning.copyableSecrets() }
            secrets[KeychainHelper.assistantNameKey] = display
            do {
                try ProfileProvisioning.runInit(profile: name, payload: ["secrets": secrets])
                if let botToken {
                    let tx = try AssistantRegistry.begin(profile: name, kind: .bot, rawValue: botToken)
                    do {
                        try tx.commit {
                            try ProfileProvisioning.runInit(profile: name, payload: ["secrets": [KeychainHelper.telegramBotTokenKey: botToken]])
                        }
                        try tx.finish()   // nobody consumed the old (absent) bot
                    } catch {
                        tx.abort()
                        throw error
                    }
                }
            } catch {
                print("✖ The assistant ‘\(display)’ was created, but its settings could not be written: \(error)")
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
        Set(copyableSecretKeys + [KeychainHelper.assistantNameKey, KeychainHelper.telegramBotTokenKey])
    }

    /// Default's values for the allow-list (read in default's process).
    static func copyableSecrets() -> [String: String] {
        var out: [String: String] = [:]
        for key in copyableSecretKeys {
            if let value = KeychainHelper.load(key: key), !value.isEmpty { out[key] = value }
        }
        return out
    }

    static func validateDisplayName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 40,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProvisioningError("the assistant's name must be 1–40 characters without control characters")
        }
    }

    /// Create the profile (plan §5.7 `add`): refused at the assistant cap,
    /// for an invalid/reserved/existing id or a name already in use. Holds
    /// `machine/identity-tx.lock` (non-blocking) while the registry is created
    /// and default's current bot/inbox are seeded, so no default identity
    /// change started before the registry existed can commit after it.
    static func add(name: String, displayName: String, homeFolder: URL, botToken: String? = nil,
                    registryPaths: AssistantRegistry.Paths = .live) throws {
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
        defer { identity.release() }
        let defaultBot = KeychainHelper.load(key: KeychainHelper.telegramBotTokenKey)
        let defaultInbox = KeychainHelper.load(key: KeychainHelper.agentMailInboxAddressKey)
        let defaultName = (KeychainHelper.load(key: KeychainHelper.assistantNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            // is created (the reservation itself is the transaction below).
            if let botToken, let h = AssistantRegistry.digest(.bot, botToken),
               let owner = AssistantRegistry.holder(of: h, kind: .bot, excluding: name, in: d) {
                throw ProvisioningError(AssistantRegistry.conflictMessage(.bot, owner: owner))
            }
            let configRoot = AssistantProfile.extraConfigRoot(name)
            let dataRoot = AssistantProfile.extraDataRoot(name)
            try PrivateStorage.ensureDirectory(configRoot, mode: 0o700)
            try PrivateStorage.ensureDirectory(dataRoot, mode: 0o700)
            let meta = AssistantProfile.Metadata(version: 1, name: name, displayName: displayName,
                                                 createdAt: Date(), homeFolder: homeFolder.path, template: nil)
            try PrivateStorage.writeAtomically(try AssistantProfile.encodeMetadata(meta),
                                               to: AssistantProfile.metadataURL(name), mode: 0o600)
            try FileManager.default.createDirectory(at: homeFolder, withIntermediateDirectories: true)
            d.records.append(AssistantRegistry.newRecord(name: name, displayName: displayName))
            doc = d
        }
    }

    /// Run `briglia --profile <name> __profile-init` with `payload` (JSON) on
    /// stdin: the profile's own process writes its own secret store.
    static func runInit(profile: String, payload: [String: Any],
                        executable: String = AgentMailService.brigliaPath()) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--profile", profile, "__profile-init"]
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: AssistantProfile.environmentKey)
        env[AssistantProfile.experimentalKey] = "1"
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
