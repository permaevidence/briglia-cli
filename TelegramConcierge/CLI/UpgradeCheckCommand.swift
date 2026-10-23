import ArgumentParser
import Foundation

/// `briglia upgradecheck [on|off]` (security plan v8 §5.6): show or change
/// the update-check setting from a terminal. Serialized with the running
/// instance's checker through the same lock, so a late check result never
/// overwrites an explicit OFF. Never fetches anything itself.
struct UpgradeCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgradecheck",
        abstract: "Show or set the update check (Briglia tells you once about a new version; it never installs by itself)."
    )

    @Argument(help: "on | off (omit to show the current state)")
    var value: String?

    func run() throws {
        switch value?.lowercased() {
        case nil:
            print(ConversationManager.upgradeCheckReply(status: UpdateNoticeService.liveStatus()))
        case "on"?, "off"?:
            try IdentityMigration.gateMutatingEntry()
            try UpdateNoticeStore.setEnabled(value!.lowercased() == "on", paths: .live, now: Date())
            print(value!.lowercased() == "on" ? ConversationManager.upgradeCheckOnText : ConversationManager.upgradeCheckOffText)
        default:
            print("Usage: briglia upgradecheck [on|off]")
            throw ExitCode(2)
        }
    }
}

/// Dev-build-only driver for the end-to-end notice tests
/// (`scripts/update_notice_e2e_test.py`): one forced check against
/// `BRIGLIA_ENVELOPE_URL` (signed with `BRIGLIA_RELEASE_TEST_KEY`), then one
/// delivery pass whose transport prints `NOTICE: <text>` and reports the
/// outcome named by `--outcome`. `--now` pins the clock. Refuses in
/// stamped release builds.
struct UpdateCheckOnceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__update-check-once",
        abstract: "Run one update-notice check and delivery pass (development builds only).",
        shouldDisplay: false
    )

    @Option(help: "Fixed clock, seconds since 1970.")
    var now: Double?

    @Option(help: "accepted | refused | ambiguous (transport outcome to simulate).")
    var outcome: String = "accepted"

    @Flag(help: "Skip the check; only run the delivery pass.")
    var deliverOnly = false

    @Option(help: "Installed sequence to simulate (default: this binary's).")
    var installed: Int?

    @MainActor
    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ __update-check-once is a development-build command")
            throw ExitCode(2)
        }
        // A test driver: never against the real channel or the real roots.
        let env = ProcessInfo.processInfo.environment
        guard env["BRIGLIA_ENVELOPE_URL"] != nil, env["XDG_CONFIG_HOME"] != nil, env["XDG_DATA_HOME"] != nil else {
            print("✖ __update-check-once needs a test channel (BRIGLIA_ENVELOPE_URL) and isolated XDG_CONFIG_HOME/XDG_DATA_HOME")
            throw ExitCode(2)
        }
        let clock = now.map { Date(timeIntervalSince1970: $0) }
        let policy = ReleasePolicy.effective
        let wanted = outcome
        let service = UpdateNoticeService(deps: UpdateNoticeService.Deps(
            paths: .live, now: { clock ?? Date() }, installed: installed ?? adaCLIReleaseSequence,
            installedVersion: adaCLIVersion, policy: policy, platform: UpgradeService.platformKey,
            fetch: { try await UpgradeService.fetchVerifiedManifest(policy: policy) },
            trustFloor: { SecurityStatus.readTrust(path: ReleaseTrustStore.fileURL.path, domain: policy.trustDomain).floor },
            jitter: { 0 }, newClassId: { String(format: "%016llx", UInt64.random(in: 1...UInt64.max)) },
            language: { "en" }, isIdle: { true },
            destination: { UpdateNotice.Destination(channelKind: "telegram", chatId: "1", channelGeneration: 0) },
            channelGeneration: { _ in 0 },
            send: { record in
                print("NOTICE[\(record.kind.rawValue) attempt \(record.attempt)]: \(record.text)")
                switch wanted {
                case "refused": return .refused(retryAfter: 1)
                case "ambiguous": return .ambiguous
                default: return .accepted
                }
            },
            log: { print("log: \($0)") }))
        if !deliverOnly { await service.runCheck() }
        await service.deliverDue()
        let status = service.status()
        print("STATUS: \(status.part)")
        for r in status.reasons { print("ATTENTION: \(r.en)") }
        print("FETCHES: \(service.fetchesStarted)")
    }
}

/// Dev-build-only: ONE update-notice send through the Telegram classifier
/// (`BRIGLIA_TELEGRAM_API_BASE` points it at a fake server that counts wire
/// requests). Prints the outcome.
struct UpdateNoticeSendOnceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__update-notice-send-once",
        abstract: "Send one update notice through the one-attempt Telegram path (development builds only).",
        shouldDisplay: false
    )

    @Option var chat: String = "1"
    @Option var text: String = "test notice"

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ __update-notice-send-once is a development-build command")
            throw ExitCode(2)
        }
        guard ProcessInfo.processInfo.environment["BRIGLIA_TELEGRAM_API_BASE"] != nil else {
            print("✖ __update-notice-send-once needs a fake Bot API (BRIGLIA_TELEGRAM_API_BASE)")
            throw ExitCode(2)
        }
        let service = TelegramBotService()
        await service.configure(token: "123456:TEST_TOKEN_SHAPE_ONLY_abcdefghijklmnop")
        let outcome = await service.sendNoticeOnce(chatId: chat, text: text,
                                                   expectedGeneration: NoticeChannelGenerations.current(.telegram))
        print("OUTCOME: \(outcome)")
    }
}

/// Dev-build-only: the client's parse of a manifest payload's security
/// metadata, as one JSON line — the cross-language parity check between
/// `release_security.py authorize/emit` and `ReleaseSecurity.parse`
/// (round-1 R2: everything the tooling authorizes must parse as known).
struct ReleaseSecurityParseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__release-security-parse",
        abstract: "Print the client's parse of a manifest payload's security metadata (development builds only).",
        shouldDisplay: false
    )

    @Argument var payloadPath: String

    func run() throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ __release-security-parse is a development-build command")
            throw ExitCode(2)
        }
        let payload = try Data(contentsOf: URL(fileURLWithPath: payloadPath))
        let sequence = ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["sequence"] as? Int ?? 0
        let parsed = ReleaseSecurity.parse(payload: payload, sequence: sequence)
        var out: [String: Any] = ["componentsUnknown": parsed.components.unknownEntries,
                                  "componentsInvalid": parsed.components.invalid,
                                  "components": parsed.components.entries.count]
        switch parsed.security {
        case .absent: out["security"] = "absent"
        case .known(let b): out["security"] = "known"; out["cumulative"] = b.cumulative.count
        case .unknown(let why): out["security"] = "unknown"; out["reason"] = why
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
