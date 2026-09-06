import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Typed request (plan §5.5)

enum QuickSetupField: String, CaseIterable {
    case opencode, chatgpt, openai, serper, jina, telegram, agentmail, openrouter, custom

    var title: String {
        switch self {
        case .opencode: return "OpenCode Go key"
        case .chatgpt: return "ChatGPT subscription"
        case .openai: return "OpenAI key"
        case .serper: return "Serper key"
        case .jina: return "Jina key"
        case .telegram: return "Telegram bot + chat"
        case .agentmail: return "AgentMail key"
        case .openrouter: return "OpenRouter key"
        case .custom: return "Custom endpoint"
        }
    }
}

struct QuickSetupRequest: Equatable {
    struct BadRequest: Error, CustomStringConvertible { let description: String }

    enum Value: Equatable {
        case kept
        case subscription(model: String, effort: String, generation: String)
        case key(String)
        case telegram(token: String, chatId: String)
        case custom(key: String, baseURL: String, model: String, vision: Bool)

        /// The bytes digested: field name ‖ 0x00 ‖ value parts joined by 0x00.
        func digestInput(field: QuickSetupField) -> Data? {
            var data = Data(field.rawValue.utf8)
            data.append(0)
            switch self {
            case .subscription(let m, let e, let g):
                data.append(Data([m, e, g].joined(separator: "\u{0}").utf8))
            case .kept: return nil
            case .key(let k): data.append(Data(k.utf8))
            case .telegram(let t, let c): data.append(Data(t.utf8)); data.append(0); data.append(Data(c.utf8))
            case .custom(let k, let b, let m, let v):
                data.append(Data(k.utf8)); data.append(0); data.append(Data(b.utf8)); data.append(0)
                data.append(Data(m.utf8)); data.append(0); data.append(v ? 1 : 0)
            }
            return data
        }
    }

    var name: String
    var values: [QuickSetupField: Value]

    static func parse(_ json: Any) throws -> QuickSetupRequest {
        guard let object = json as? [String: Any] else { throw BadRequest(description: "body must be a JSON object") }
        let allowed: Set<String> = Set(["name"] + QuickSetupField.allCases.map(\.rawValue))
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw BadRequest(description: "unknown field(s): \(unknown.sorted().joined(separator: ", "))") }
        guard let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw BadRequest(description: "name is required")
        }
        var values: [QuickSetupField: Value] = [:]
        for field in QuickSetupField.allCases {
            guard let raw = object[field.rawValue] else {
                if [.openai, .serper, .jina, .telegram].contains(field) || (field == .opencode && object["chatgpt"] == nil) {
                    throw BadRequest(description: "\(field.rawValue) is required")
                }
                continue
            }
            guard let entry = raw as? [String: Any] else { throw BadRequest(description: "\(field.rawValue) must be an object") }
            let keys = Set(entry.keys)
            if field == .chatgpt {
                guard keys == ["model", "effort", "generation"], let m = entry["model"] as? String, !m.isEmpty,
                      let e = entry["effort"] as? String, let g = entry["generation"] as? String, UUID(uuidString: g) != nil else {
                    throw BadRequest(description: "chatgpt requires model, effort and current login")
                }
                values[field] = .subscription(model: m, effort: e, generation: g); continue
            }
            if entry["kept"] as? Bool == true {
                guard keys == ["kept"] else { throw BadRequest(description: "\(field.rawValue): kept must be alone") }
                values[field] = .kept
                continue
            }
            func str(_ k: String) throws -> String {
                guard let v = (entry[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                    throw BadRequest(description: "\(field.rawValue).\(k) is required")
                }
                return v
            }
            switch field {
            case .telegram:
                guard keys.isSubset(of: ["token", "chat_id"]) else { throw BadRequest(description: "telegram: unknown key") }
                values[field] = .telegram(token: try str("token"), chatId: try str("chat_id"))
            case .custom:
                guard keys.isSubset(of: ["api_key", "base_url", "model", "vision"]) else { throw BadRequest(description: "custom: unknown key") }
                // Conservative like the terminal wizard: an unknown endpoint is
                // text-only unless the page's checkbox says it can see images.
                let vision = entry["vision"] as? Bool ?? false
                values[field] = .custom(key: try str("api_key"), baseURL: try str("base_url"), model: try str("model"), vision: vision)
            default:
                guard keys.isSubset(of: ["value"]) else { throw BadRequest(description: "\(field.rawValue): unknown key") }
                values[field] = .key(try str("value"))
            }
        }
        guard !(values[.opencode] != nil && values[.chatgpt] != nil) else { throw BadRequest(description: "Choose one main provider") }
        return QuickSetupRequest(name: name, values: values)
    }

    static func digest(_ input: Data) -> String {
        SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Environment (every side effect behind a closure, for the selftest)

struct QuickSetupEnvironment {
    var isLinux: Bool = {
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }()
    var subscription: ([String: Any], () throws -> Void) async -> [String: Any] = { await SubscriptionSetup().perform($0, ownsLease: true, checkpoint: $1) }
    var probe: ([String: Any]) async -> [String: Any] = {
        if $0["kind"] as? String == "chatgpt" {
            var request = $0; request.removeValue(forKey: "kind"); request["action"] = "probe"
            return await SubscriptionSetup().perform(request, ownsLease: true)
        }
        return await SetupAPICore.probe($0)
    }
    var apply: ([String: Any], () throws -> Void) async -> [String: Any] = { await SetupAPICore.apply($0, ownsLease: true, checkpoint: $1) }
    var storedValue: (String) -> String? = { KeychainHelper.load(key: $0) }
    var saveBatch: ([String: String?]) throws -> Void = { try KeychainHelper.saveBatch($0) }
    var fsyncConfigDirectory: () throws -> Void = { try PrivateStorage.fsyncDirectory(StoragePaths.configRoot.path) }
    var fullDiskAccessGranted: () -> Bool = { PermissionsService.fullDiskAccessGranted() }
    var terminalAppName: () -> String = {
        #if os(macOS)
        return QuickSetupEvidence.terminalAppName()
        #else
        return "your terminal"
        #endif
    }
    var openSettingsPane: () -> Void = {
        #if os(macOS)
        _ = GoogleWorkspaceService.runBlockingProcess(
            executable: "/usr/bin/open",
            args: ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"], timeoutSeconds: 10)
        #endif
    }
    var keepAwakeHeld: () -> Bool = { KeepAwake.isHeld && (KeepAwake.assertionListedBySystem(reason: KeepAwake.defaultReason) ?? true) }
    var autoSuspendVerdict: () -> AutoSuspendCensus.Verdict = {
        #if os(Linux)
        return PermissionsService.autoSuspendVerdict()
        #else
        return .sleepImpossible
        #endif
    }
    var disableGnomeAutoSuspend: () -> Bool = {
        #if os(Linux)
        return PermissionsService.disableGnomeAutoSuspend()
        #else
        return false
        #endif
    }
    var toolchainStatus: () -> ToolchainService.DesktopStatus = { ToolchainService.desktopStatus() }
    /// Jobs to run for the missing part of the toolchain, in order.
    var toolchainJobs: (ToolchainService.DesktopStatus) -> [SetupJobRunner.Spec] = QuickSetupEnvironment.defaultToolchainJobs
    var maskSleepTargetsJob: () -> SetupJobRunner.Spec? = {
        guard let sudo = PlatformBinary.find("sudo"), let systemctl = PlatformBinary.find("systemctl") else { return nil }
        return SetupJobRunner.Spec(row: "keepawake", command: [sudo, systemctl, "mask", "sleep.target", "suspend.target", "hibernate.target", "hybrid-sleep.target"],
                                   mode: .terminalHandoff, timeout: 300, label: "mask sleep targets")
    }
    var installAgentMail: (_ progress: @escaping @Sendable (String) -> Void, _ checkpoint: () throws -> Void, _ runner: SetupJobRunner) async -> String? = { progress, checkpoint, runner in
        switch await AgentMailService.repairTransaction(runner: .journaled(runner, row: "agentmail_cli")) {
        case .failedClosed(let why): return why
        case .busy: return "another AgentMail installation or repair is in progress — retry in a moment"
        default: break
        }
        return await AgentMailService.installAgentMailBinary(progress: progress, checkpoint: checkpoint,
                                                             runner: .journaled(runner, row: "agentmail_cli"))
    }
    var agentMailInstalled: () -> Bool = { AgentMailService.agentMailBrokerInstalled() }
    // Linux service
    var installUnit: () throws -> Void = QuickSetupEnvironment.defaultInstallUnit
    var enableService: (SetupJobRunner) async -> String? = QuickSetupEnvironment.defaultEnableService
    /// Async so the 20-second stability window never blocks the workflow
    /// actor (a blocked actor could not observe Enter's revocation).
    var serviceEvidence: () async -> (ok: Bool, linger: Bool, detail: String) = {
        #if os(Linux)
        let e = await QuickSetupEvidence.serviceEvidence()
        return (e.ok, e.linger, e.detail)
        #else
        return (false, false, "no service on macOS")
        #endif
    }
    var stopService: () -> Bool = {
        #if os(Linux)
        return AgentServiceSupport.run("systemctl", ["--user", "stop", AgentServiceSupport.userUnitName]).status == 0
        #else
        return false
        #endif
    }
    var releaseLease: () -> Void = {}
    var reacquireLease: () -> Bool = { true }
    var log: (String) -> Void = { print($0) }

    /// Dev builds only: `BRIGLIA_DEV_QUICKSETUP_STUBS=1` replaces the
    /// system-row evidence and installers with stubs (a marker file under the
    /// data root stands in for "toolchain installed"), so the headless smoke
    /// and the browser test can run the whole flow on any machine.
    static func applyDevStubsIfRequested(_ env: inout QuickSetupEnvironment) {
        guard adaCLIVersion.hasSuffix("-dev"),
              ProcessInfo.processInfo.environment["BRIGLIA_DEV_QUICKSETUP_STUBS"] == "1" else { return }
        let marker = StoragePaths.dataRoot.appendingPathComponent(".stub-toolchain-installed").path
        let serviceMarker = StoragePaths.dataRoot.appendingPathComponent(".stub-service-started").path
        let fm = FileManager.default
        env.fullDiskAccessGranted = { ProcessInfo.processInfo.environment["BRIGLIA_DEV_STUB_FDA"] != "0" }
        // keepAwakeHeld stays REAL: the headless/browser runs prove the
        // assertion quick setup holds is the one the row verifies (macOS).
        env.autoSuspendVerdict = { .sleepImpossible }
        env.agentMailInstalled = { true }
        env.toolchainStatus = {
            let installed = fm.fileExists(atPath: marker)
            return ToolchainService.DesktopStatus(doctorRan: true, missing: installed ? [] : ["pandoc"],
                                                  libreOffice: installed, mandatoryMissing: installed ? [] : ["pandoc"])
        }
        env.toolchainJobs = { _ in
            let slow = ProcessInfo.processInfo.environment["BRIGLIA_DEV_STUB_SLOW_TOOLCHAIN"] ?? "0"
            return [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "echo stub: installing toolchain; sleep \(slow); touch '\(marker)'; echo stub: done"],
                                        mode: .detached, timeout: 120, label: "stub toolchain install")]
        }
        env.installUnit = { }
        env.enableService = { _ in fm.createFile(atPath: serviceMarker, contents: Data()); return nil }
        env.serviceEvidence = { (fm.fileExists(atPath: serviceMarker), true, "stub service active") }
        env.stopService = { unlink(serviceMarker); return true }
        env.maskSleepTargetsJob = { nil }
    }

    static func defaultToolchainJobs(_ status: ToolchainService.DesktopStatus) -> [SetupJobRunner.Spec] {
        var jobs: [SetupJobRunner.Spec] = []
        let missing = Set(status.mandatoryMissing)
        let python = ToolchainService.python3Path()
        let pipPackages = ["python-docx", "python-pptx", "pillow", "pymupdf", "formulas", "openpyxl"].filter { missing.contains($0) }
        // `--break-system-packages` only where pip knows it (pip ≥ 23.1;
        // Ubuntu 22.04 ships 22.0 and rejects the option outright).
        let pipArgs = ["-m", "pip", "install"] + (python.map { ToolchainService.pipBreakSystemPackagesSupported(python: $0) } == true ? ["--break-system-packages"] : [])
        #if os(macOS)
        guard let brew = ToolchainService.brewPath() else { return [] }
        var formulas: [String] = []
        if !missing.isDisjoint(with: ["pdfinfo", "pdftotext", "pdftoppm", "pdfseparate", "pdfunite"]) { formulas.append("poppler") }
        if !missing.isDisjoint(with: ["ffmpeg", "ffprobe"]) { formulas.append("ffmpeg") }
        if missing.contains("pandoc") { formulas.append("pandoc") }
        for f in formulas {
            jobs.append(.init(row: "toolchain", command: [brew, "install", f], mode: .detached, timeout: 900,
                              environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], label: "brew install \(f)"))
        }
        if let python {
            for p in pipPackages {
                jobs.append(.init(row: "toolchain", command: [python] + pipArgs + [p],
                                  mode: .detached, timeout: 300, label: "pip install \(p)"))
            }
        }
        if !status.libreOffice {
            jobs.append(.init(row: "toolchain", command: [brew, "install", "--cask", "libreoffice"], mode: .detached, timeout: 2400,
                              environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"], label: "brew install --cask libreoffice"))
        }
        #else
        guard let manager = ToolchainService.linuxPackageManager(), let sudo = PlatformBinary.find("sudo"),
              let managerPath = PlatformBinary.find(manager.name) else { return [] }
        var logical: [String] = []
        if !missing.isDisjoint(with: ["pdfinfo", "pdftotext", "pdftoppm", "pdfseparate", "pdfunite"]) { logical.append("poppler") }
        if !missing.isDisjoint(with: ["magick", "identify", "convert", "imagemagick"]) { logical.append("imagemagick") }
        if !missing.isDisjoint(with: ["ffmpeg", "ffprobe"]) { logical.append("ffmpeg") }
        if missing.contains("pandoc") { logical.append("pandoc") }
        if !status.libreOffice { logical.append("libreoffice") }
        if !logical.isEmpty {
            let packages = logical.map { LinuxPackageMap.package($0, manager: manager.name) }
            jobs.append(.init(row: "toolchain", command: [sudo] + LinuxPackageMap.installCommand(manager: manager.name, managerPath: managerPath, packages: packages),
                              mode: .terminalHandoff, timeout: 2400, environment: ["DEBIAN_FRONTEND": "noninteractive"],
                              label: "\(manager.name) install \(packages.joined(separator: " "))"))
        }
        if let python {
            for p in pipPackages {
                jobs.append(.init(row: "toolchain", command: [python] + pipArgs + [p],
                                  mode: .detached, timeout: 300, label: "pip install \(p)"))
            }
        }
        #endif
        return jobs
    }

    static func defaultInstallUnit() throws {
        #if os(Linux)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let unitDir = AgentServiceSupport.userUnitDirectory(home: home)
        let unitPath = unitDir + "/" + AgentServiceSupport.userUnitName
        try FileManager.default.createDirectory(atPath: unitDir, withIntermediateDirectories: true)
        let text = AgentServiceSupport.userUnitText(adaPath: AgentServiceSupport.adaExecutablePath(), home: home)
        try PrivateStorage.writeAtomically(Data(text.utf8), to: URL(fileURLWithPath: unitPath), mode: 0o644)
        let reload = AgentServiceSupport.run("systemctl", ["--user", "daemon-reload"])
        guard reload.status == 0 else { throw NSError(domain: "briglia.quicksetup", code: 20, userInfo: [NSLocalizedDescriptionKey: "systemctl --user daemon-reload failed: \(reload.output)"]) }
        #endif
    }

    static func defaultEnableService(_ runner: SetupJobRunner) async -> String? {
        #if os(Linux)
        guard let systemctl = PlatformBinary.find("systemctl") else { return "systemctl not found" }
        let enable = await runner.run(.init(row: "service", command: [systemctl, "--user", "enable", "--now", AgentServiceSupport.userUnitName],
                                            mode: .detached, timeout: 120, label: "systemctl --user enable --now briglia"))
        guard enable.ok else { return "enable --now failed: \(enable.failureReason ?? "?")" }
        if !AgentServiceSupport.lingerEnabled() {
            if let loginctl = PlatformBinary.find("loginctl") {
                _ = await runner.run(.init(row: "service", command: [loginctl, "enable-linger", NSUserName()], mode: .detached, timeout: 60, label: "loginctl enable-linger"))
            }
            if !AgentServiceSupport.lingerEnabled(), let sudo = PlatformBinary.find("sudo"), let loginctl = PlatformBinary.find("loginctl") {
                let r = await runner.run(.init(row: "service", command: [sudo, loginctl, "enable-linger", NSUserName()], mode: .terminalHandoff, timeout: 300, label: "sudo loginctl enable-linger"))
                if !r.ok { return "linger could not be enabled (sudo declined?): run `sudo loginctl enable-linger \(NSUserName())`" }
            }
        }
        return nil
        #else
        return "no service on macOS"
        #endif
    }
}

// MARK: - Workflow actor (plan §4, §5.2, §5.5)

actor QuickSetupWorkflow {
    enum Phase: String { case intro, verifying, verified, saving, saved, system, systemComplete, finishing, done }

    struct RowState {
        var id: String
        var title: String
        var state: String   // pending | running | ok | failed
        var reason: String?
        var detail: String?
        var offer: String?
        var info: [String: Any] = [:]
    }

    struct Superseded: Error {}

    enum ResumeMode { case fresh, system, handoff }

    static let progressSystem = "quick:system"
    static let progressHandoff = "quick:handoff"
    static let sectionOrder = ["provider", "openai", "serper", "jina", "identity", "telegram", "email_calendar", "openrouter", "custom"]

    let env: QuickSetupEnvironment
    let runner: SetupJobRunner

    // Authorization
    private(set) var generation = 1
    /// nil after a rotation whose randomness failed: nothing can exchange.
    private var token: String?
    private var tokenIssuedAt = Date()
    private var tokenUsed = false
    private var cookie: String
    /// Operations of the current generation still executing (verify, save,
    /// system run, finish): rotation and the wizard handoff wait for them
    /// to unwind at their next checkpoint before proceeding.
    private var inFlight = 0
    private(set) var consumedByOther = false
    static let tokenLifetime: TimeInterval = 300
    nonisolated(unsafe) static var clock: () -> Date = { Date() }

    // Workflow
    private(set) var phase: Phase = .intro
    private var requestGeneration = 0
    private var digests: [QuickSetupField: String] = [:]
    private var verifyRows: [QuickSetupField: RowState] = [:]
    private(set) var kept: Set<QuickSetupField> = []
    private(set) var storedName: String
    private var savedSections: Set<String> = []
    private var lastRequest: QuickSetupRequest?
    private(set) var systemRows: [RowState] = []
    private var rowTask: Task<Void, Never>?
    private(set) var finishSteps: [RowState] = []
    private var finishTask: Task<Void, Never>?
    private(set) var wizardRequested = false
    private(set) var isDone = false
    private(set) var lastError: String?
    private var leaseReleased = false
    let resumeMode: ResumeMode

    init(env: QuickSetupEnvironment, runner: SetupJobRunner, resume: ResumeMode) throws {
        self.env = env
        self.runner = runner
        self.resumeMode = resume
        guard let t = Self.randomHex(), let c = Self.randomHex() else {
            throw NSError(domain: "briglia.quicksetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot generate a secure link on this system."])
        }
        token = t
        cookie = c
        storedName = env.storedValue(KeychainHelper.userNameKey) ?? ""
        kept = Self.computeKept(env)
        switch resume {
        case .fresh: phase = .intro
        case .system:
            phase = .system
            systemRows = Self.buildSystemRows(env: env, agentMail: kept.contains(.agentmail))
        case .handoff:
            phase = .finishing
            finishSteps = Self.buildFinishSteps(linux: env.isLinux)
        }
    }

    /// Selftest seam: simulate RNG failure.
    nonisolated(unsafe) static var randomHexFails = false

    static func randomHex() -> String? {
        if randomHexFails { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        #if os(Linux)
        // The Glibc module does not export getrandom(2); /dev/urandom is
        // the same CSPRNG pool. Any failure (missing device, short read)
        // aborts the command before listening — never a weaker fallback.
        let fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var filled = 0
        while filled < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + filled, $0.count - filled) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return nil }
            filled += n
        }
        #else
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        #endif
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func computeKept(_ env: QuickSetupEnvironment) -> Set<QuickSetupField> {
        var kept: Set<QuickSetupField> = []
        func has(_ key: String) -> Bool { !(env.storedValue(key) ?? "").isEmpty }
        if has(ProviderProfiles.opencodeApiKeyKey) { kept.insert(.opencode) }
        if has(KeychainHelper.openAITranscriptionApiKeyKey) { kept.insert(.openai) }
        if has(KeychainHelper.serperApiKeyKey) { kept.insert(.serper) }
        if has(KeychainHelper.jinaApiKeyKey) { kept.insert(.jina) }
        if has(KeychainHelper.telegramBotTokenKey) && has(KeychainHelper.telegramChatIdKey) { kept.insert(.telegram) }
        if has(KeychainHelper.agentMailApiKeyKey) && env.storedValue(KeychainHelper.emailCalendarProviderKey) == EmailCalendarProvider.agentmail.rawValue { kept.insert(.agentmail) }
        if has(KeychainHelper.openRouterApiKeyKey) { kept.insert(.openrouter) }
        if has(ProviderProfiles.customApiKeyKey) && has(ProviderProfiles.customBaseURLKey) && has(ProviderProfiles.customModelKey) { kept.insert(.custom) }
        return kept
    }

    // MARK: Authorization (§5.2)

    /// The live launch token; empty when none can be issued (RNG failure).
    var launchToken: String { token ?? "" }
    var currentCookie: String { cookie }

    /// `GET /start?t=`: single use, 5-minute lifetime, current generation.
    func exchange(token candidate: String) -> String? {
        guard let token, !tokenUsed, candidate == token, Self.clock().timeIntervalSince(tokenIssuedAt) <= Self.tokenLifetime else {
            if candidate == token && tokenUsed { consumedByOther = true }
            return nil
        }
        tokenUsed = true
        return cookie
    }

    /// Atomic authorization: the cookie check and the generation it
    /// authorizes are one actor call, so a rotation between "cookie is
    /// current" and "which generation" cannot hand an old cookie the new
    /// generation.
    func authorizedGeneration(cookie candidate: String?) -> Int? {
        guard let candidate, candidate == cookie else { return nil }
        return generation
    }

    func authorized(cookie candidate: String?) -> Bool { authorizedGeneration(cookie: candidate) != nil }

    private func beginOperation() { inFlight += 1 }
    private func endOperation() { inFlight -= 1 }

    /// Wait (bounded) until every operation of the revoked generation has
    /// unwound at its next checkpoint. Row and finish tasks are awaited by
    /// the caller separately.
    private func settleInFlight() async {
        var waited = 0
        while inFlight > 0, waited < 600 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
    }
    var inFlightOperations: Int { inFlight }
    func beginSettingsOperation(_ g: Int) throws { try checkpoint(g); beginOperation() }
    func endSettingsOperation() { endOperation() }

    func checkpoint(_ g: Int) throws {
        if g != generation { throw Superseded() }
    }

    /// Enter in the terminal: revoke, cancel + reap the running job, mint.
    /// Returns the poison state if reaping could not be confirmed.
    struct RotationResult {
        var poison: SetupJobRunner.Poison?
        /// Fresh randomness could not be obtained: the old authorization is
        /// revoked and NO new link exists (the command must report it).
        var randomnessFailed = false
    }

    /// Rotations are serialized: a second Enter while one is in progress
    /// waits for it (its own revocation is already effective — nothing is
    /// authorized between the first revocation and the final mint).
    private var rotating = false
    private var rotationWaiters: [CheckedContinuation<Void, Never>] = []

    func rotate() async -> RotationResult {
        // (1) REVOKE FIRST, before any await: no cookie authorizes, no token
        // exchanges, every checkpoint of the old generation throws. An
        // old-cookie request arriving during the cancellation window below
        // finds nothing to authorize and cannot inherit the new generation.
        generation += 1
        generationBox.set(generation)
        cookie = ""
        token = nil
        tokenUsed = true
        if rotating {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in rotationWaiters.append(c) }
            return RotationResult(poison: runner.currentPoison, randomnessFailed: token == nil)
        }
        rotating = true
        defer {
            rotating = false
            let waiters = rotationWaiters
            rotationWaiters = []
            for w in waiters { w.resume() }
        }
        let hadJob = runner.currentJob != nil
        if hadJob { env.log("cancelling the current step…") }
        rowTask?.cancel()
        finishTask?.cancel()
        let poison = await runner.cancelRunning()  // (2) confirmed reaping or poison
        if let t = rowTask { await t.value }
        if let t = finishTask { await t.value }
        await settleInFlight()                     // (3) suspended operations unwound
        await cancelSetupLogin()
        // (4) mint — or abort: the revoked token/cookie were already cleared.
        guard let newToken = Self.randomHex(), let newCookie = Self.randomHex() else {
            return RotationResult(poison: poison, randomnessFailed: true)
        }
        token = newToken
        cookie = newCookie
        tokenIssuedAt = Self.clock()
        tokenUsed = false
        consumedByOther = false
        return RotationResult(poison: poison)
    }

    // MARK: Status

    func status() -> [String: Any] {
        var out: [String: Any] = [
            "phase": phase.rawValue,
            "generation": generation,
            "platform": env.isLinux ? "linux" : "macos",
            "stored_name": storedName,
            "kept": kept.map(\.rawValue).sorted(),
            "rows": QuickSetupField.allCases.compactMap { field -> [String: Any]? in
                guard let row = verifyRows[field] else { return nil }
                return rowDict(row)
            },
            "system_rows": systemRows.map(rowDict),
            "finish_steps": finishSteps.map(rowDict),
            "saved_sections": savedSections.sorted(),
            "done": isDone,
            "wizard_requested": wizardRequested,
        ]
        if let job = runner.currentJob {
            out["current_job"] = ["row": job.row, "label": job.label, "pid": job.pid,
                                  "started_at": ISO8601DateFormatter().string(from: job.startedAt)] as [String: Any]
        }
        if let poison = runner.currentPoison {
            out["poisoned"] = poisonDict(poison)
        }
        if let lastError { out["last_error"] = lastError }
        if !env.isLinux {
            out["fda_granted"] = env.fullDiskAccessGranted()
            out["terminal_app"] = env.terminalAppName()
        }
        return out
    }

    private func rowDict(_ row: RowState) -> [String: Any] {
        var d: [String: Any] = ["id": row.id, "title": row.title, "state": row.state]
        if let r = row.reason { d["reason"] = r }
        if let r = row.detail { d["detail"] = r }
        if let o = row.offer { d["offer"] = o }
        for (k, v) in row.info { d[k] = v }
        return d
    }

    private func poisonDict(_ p: SetupJobRunner.Poison) -> [String: Any] {
        var d: [String: Any] = [
            "row": p.row, "command": p.command,
            "survivors": p.survivors.map { ["pid": $0.pid, "start_time": $0.startTime, "note": $0.note ?? ""] as [String: Any] },
            "enumeration_failed": p.enumerationFailed,
        ]
        if let u = p.unreadableJournal { d["unreadable_journal"] = u }
        return d
    }

    func jobLines(since offset: Int) -> [String: Any] {
        let (lines, next) = runner.lines(since: offset)
        var out: [String: Any] = ["lines": lines, "next": next]
        if let job = runner.currentJob { out["running"] = ["row": job.row, "label": job.label] as [String: Any] }
        return out
    }

    private var subscriptionPending: String?
    func subscription(_ request: [String: Any], generation g: Int) async throws -> (Int, [String: Any]) {
        try checkpoint(g)
        guard [.intro, .verified].contains(phase), inFlight == 0 else { return (409, ["error": "busy"]) }
        guard let action = request["action"] as? String, ["start", "poll", "cancel", "logout", "status"].contains(action) else {
            return (400, ["error": "invalid_action"])
        }
        beginOperation(); defer { endOperation() }
        let result = await env.subscription(request) { [weak self] in
            guard let self else { throw Superseded() }; try self.checkpointSync(g)
        }
        try checkpoint(g)
        if action == "start", let id = result["pending"] as? String { subscriptionPending = id }
        if ["signed_in", "cancelled", "signed_out"].contains(result["state"] as? String ?? "") { subscriptionPending = nil }
        if action != "status" { digests[.chatgpt] = nil; verifyRows[.chatgpt] = nil; phase = .intro }
        return (result["ok"] as? Bool == true ? 200 : 400, result)
    }
    private func cancelSetupLogin() async {
        if let pending = subscriptionPending {
            _ = await env.subscription(["action": "cancel", "pending": pending], {})
            subscriptionPending = nil
        }
    }

    // MARK: Verify (§4.3)

    func verify(_ request: QuickSetupRequest, generation g: Int) async throws -> (Int, [String: Any]) {
        try checkpoint(g)
        beginOperation(); defer { endOperation() }
        guard [.intro, .verified, .verifying].contains(phase) else { return (409, ["error": "phase", "phase": phase.rawValue]) }
        if let why = validateKept(request) { return (409, ["error": "kept", "message": why]) }
        phase = .verifying
        requestGeneration += 1
        let r = requestGeneration
        lastRequest = request
        storedName = request.name

        // Which fields need a probe: non-kept whose digest changed (or never verified).
        var toProbe: [(QuickSetupField, String, [String: Any])] = []
        for field in QuickSetupField.allCases {
            guard let value = request.values[field] else { verifyRows[field] = nil; digests[field] = nil; continue }
            if value == .kept {
                verifyRows[field] = RowState(id: field.rawValue, title: field.title, state: "ok", reason: nil, detail: "configured, keeping current")
                continue
            }
            let digest = QuickSetupRequest.digest(value.digestInput(field: field)!)
            if digests[field] == digest, verifyRows[field]?.state == "ok" { continue }
            digests[field] = nil
            verifyRows[field] = RowState(id: field.rawValue, title: field.title, state: "running")
            toProbe.append((field, digest, Self.probeRequest(field, value)))
        }
        // Concurrent probes, bounded to 4.
        let probe = env.probe
        var results: [(QuickSetupField, String, [String: Any])] = []
        await withTaskGroup(of: (QuickSetupField, String, [String: Any]).self) { group in
            var pending = toProbe[...]
            var inFlight = 0
            func launch() {
                guard let (field, digest, req) = pending.popFirst() else { return }
                inFlight += 1
                group.addTask { (field, digest, await probe(req)) }
            }
            while inFlight < 4, !pending.isEmpty { launch() }
            for await result in group {
                inFlight -= 1
                results.append(result)
                if !pending.isEmpty { launch() }
            }
        }
        // Apply results only if still the current request generation and authorization.
        guard r == requestGeneration else { throw Superseded() }
        try checkpoint(g)
        for (field, digest, payload) in results {
            var row = RowState(id: field.rawValue, title: field.title, state: "pending")
            if payload["ok"] as? Bool == true {
                row.state = "ok"
                digests[field] = digest
                var info: [String: Any] = [:]
                if let u = payload["bot_username"] as? String {
                    let title = payload["chat_title"] as? String ?? ""
                    let user = (payload["chat_username"] as? String).map { " (@\($0))" } ?? ""
                    info["resolved"] = "bot @\(u) → \(title)\(user)"
                }
                if let inboxes = payload["inboxes"] as? [String], let first = inboxes.first { info["resolved"] = first }
                row.info = info
            } else {
                row.state = "failed"
                row.reason = (payload["reason"] as? String)
                    ?? ((payload["error"] as? [String: Any])?["message"] as? String) ?? "verification failed"
                if let code = payload["reason_code"] as? String { row.info["reason_code"] = code }
            }
            verifyRows[field] = row
        }
        let allOK = QuickSetupField.allCases.allSatisfy { field in request.values[field] == nil || verifyRows[field]?.state == "ok" }
        phase = allOK ? .verified : .intro
        return (200, ["phase": phase.rawValue, "rows": QuickSetupField.allCases.compactMap { verifyRows[$0].map(rowDict) }])
    }

    private func validateKept(_ request: QuickSetupRequest) -> String? {
        for (field, value) in request.values where value == .kept && !kept.contains(field) {
            return "\(field.rawValue) was not stored — enter a value"
        }
        return nil
    }

    static func probeRequest(_ field: QuickSetupField, _ value: QuickSetupRequest.Value) -> [String: Any] {
        switch (field, value) {
        case (.chatgpt, .subscription(let m, let e, let g)): return ["kind": "chatgpt", "model": m, "effort": e, "generation": g]
        case (.opencode, .key(let k)): return ["kind": "opencode", "api_key": k]
        case (.openai, .key(let k)): return ["kind": "openai", "api_key": k]
        case (.serper, .key(let k)): return ["kind": "serper", "api_key": k]
        case (.jina, .key(let k)): return ["kind": "jina", "api_key": k]
        case (.agentmail, .key(let k)): return ["kind": "agentmail", "api_key": k]
        case (.openrouter, .key(let k)): return ["kind": "openrouter", "api_key": k]
        case (.telegram, .telegram(let t, let c)): return ["kind": "telegram_chat", "token": t, "chat_id": c]
        case (.custom, .custom(let k, let b, let m, _)): return ["kind": "custom", "api_key": k, "base_url": b, "model": m]
        default: return ["kind": "invalid"]
        }
    }

    // MARK: Save (§4.4)

    func save(_ request: QuickSetupRequest, generation g: Int) async throws -> (Int, [String: Any]) {
        try checkpoint(g)
        beginOperation(); defer { endOperation() }
        guard phase == .verified || phase == .saving else { return (409, ["error": "phase", "phase": phase.rawValue]) }
        if let why = validateKept(request) { return (409, ["error": "kept", "message": why]) }
        // Digest equality for every non-kept field.
        var mismatched: [String] = []
        for field in QuickSetupField.allCases {
            guard let value = request.values[field] else {
                if verifyRows[field] != nil { mismatched.append(field.rawValue) }
                continue
            }
            if value == .kept { continue }
            let digest = QuickSetupRequest.digest(value.digestInput(field: field)!)
            if digests[field] != digest || verifyRows[field]?.state != "ok" { mismatched.append(field.rawValue) }
        }
        if !mismatched.isEmpty {
            phase = .intro
            for name in mismatched { if let f = QuickSetupField(rawValue: name) { digests[f] = nil; verifyRows[f]?.state = "pending" } }
            return (409, ["error": "not_verified", "fields": mismatched])
        }
        guard let last = lastRequest, last.name == request.name else {
            return (409, ["error": "not_verified", "fields": ["name"]])
        }
        phase = .saving
        for section in Self.sectionOrder where !savedSections.contains(section) {
            if section == "provider", case .subscription(let model, let effort, let expected) = request.values[.chatgpt] {
                try checkpoint(g)
                let result = await env.subscription(["action": "select", "model": model, "effort": effort, "generation": expected]) { [weak self] in
                    guard let self else { throw Superseded() }; try self.checkpointSync(g)
                }
                try checkpoint(g)
                guard result["ok"] as? Bool == true else { return (409, result) }
                savedSections.insert(section); continue
            }
            guard let payload = Self.applyPayload(section: section, request: request) else { continue }
            try checkpoint(g)   // immediately before each apply
            let result = await env.apply(payload) { [weak self] in
                guard let self else { throw Superseded() }
                // Synchronous check from inside the section: the actor's
                // generation is read through a nonisolated snapshot.
                try self.checkpointSync(g)
            }
            try checkpoint(g)
            if result["ok"] as? Bool == true {
                savedSections.insert(section)
            } else {
                let err = (result["error"] as? [String: Any])
                let code = err?["code"] as? String ?? "save_failed"
                let message = err?["message"] as? String ?? "save failed"
                if code == "superseded" { throw Superseded() }
                lastError = message
                return (500, ["error": code, "message": message, "saved_sections": savedSections.sorted()])
            }
        }
        // Everything saved: persist progress and enter the system phase.
        try checkpoint(g)
        do {
            try env.saveBatch([SetupWizard.progressKey: Self.progressSystem])
        } catch {
            lastError = "could not record progress: \(error.localizedDescription)"
            return (500, ["error": "save_failed", "message": lastError!])
        }
        kept = Self.computeKept(env)
        phase = .system
        systemRows = Self.buildSystemRows(env: env, agentMail: request.values[.agentmail] != nil)
        return (200, ["phase": phase.rawValue, "saved_sections": savedSections.sorted(), "system_rows": systemRows.map(rowDict)])
    }

    /// Generation snapshot readable without actor hops (the apply seam's
    /// checkpoint runs synchronously inside the section).
    private nonisolated let generationBox = GenerationBox()
    private final class GenerationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 1
        func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    nonisolated func checkpointSync(_ g: Int) throws {
        if generationBox.get() != g { throw SetupAPICore.CheckpointRevoked("this quick-setup session was replaced") }
    }

    static func applyPayload(section: String, request: QuickSetupRequest) -> [String: Any]? {
        func key(_ f: QuickSetupField) -> String? {
            if case .key(let k)? = request.values[f] { return k }
            return nil
        }
        switch section {
        case "provider":
            guard let k = key(.opencode) else { return nil }
            let textOnly = OpenCodeGo.choices.first { $0.id == OpenCodeGo.defaultModel }?.textOnly ?? false
            return ["provider": ["profile": "opencode", "api_key": k, "model": OpenCodeGo.defaultModel, "effort": "high", "text_only": textOnly, "activate": true] as [String: Any]]
        case "openai": return key(.openai).map { ["openai": ["api_key": $0]] }
        case "serper": return key(.serper).map { ["serper": ["api_key": $0]] }
        case "jina": return key(.jina).map { ["jina": ["api_key": $0]] }
        case "identity": return ["identity": ["user_name": request.name]]
        case "telegram":
            if case .telegram(let t, let c)? = request.values[.telegram] { return ["telegram": ["token": t, "chat_id": c]] }
            return nil
        case "email_calendar":
            guard let k = key(.agentmail) else { return nil }
            return ["email_calendar": ["provider": "agentmail", "api_key": k, "install_cli": false] as [String: Any]]
        case "openrouter":
            guard let k = key(.openrouter) else { return nil }
            return ["provider": ["profile": "openrouter", "api_key": k, "model": "google/gemini-3-flash-preview", "text_only": false, "activate": false] as [String: Any]]
        case "custom":
            if case .custom(let k, let b, let m, let vision)? = request.values[.custom] {
                return ["provider": ["profile": "custom", "api_key": k, "base_url": b, "model": m, "text_only": !vision, "activate": false] as [String: Any]]
            }
            return nil
        default: return nil
        }
    }

    // MARK: System rows (§4.5)

    static func buildSystemRows(env: QuickSetupEnvironment, agentMail: Bool) -> [RowState] {
        var rows: [RowState] = []
        if agentMail { rows.append(RowState(id: "agentmail_cli", title: "AgentMail command-line tool", state: "pending")) }
        if !env.isLinux {
            rows.append(RowState(id: "fda", title: "Full Disk Access for \(env.terminalAppName())", state: "pending"))
        }
        rows.append(RowState(id: "keepawake", title: "Keep awake", state: "pending"))
        rows.append(RowState(id: "toolchain", title: "Toolchain", state: "pending"))
        return rows
    }

    var nextSystemRowIndex: Int? { systemRows.firstIndex { $0.state != "ok" } }

    func systemRun(row: String, option: String?, generation g: Int) async throws -> (Int, [String: Any]) {
        try checkpoint(g)
        guard phase == .system else { return (409, ["error": "phase", "phase": phase.rawValue]) }
        if let poison = runner.currentPoison { return (409, ["error": "poisoned", "poisoned": poisonDict(poison)]) }
        guard runner.currentJob == nil, rowTask == nil else { return (409, ["error": "busy"]) }
        guard let index = nextSystemRowIndex, systemRows[index].id == row else {
            return (409, ["error": "not_next", "next": nextSystemRowIndex.map { systemRows[$0].id } as Any])
        }
        systemRows[index].state = "running"
        systemRows[index].reason = nil
        systemRows[index].offer = nil
        let task = Task { [self] in await executeRow(index: index, option: option, generation: g) }
        rowTask = task
        return (202, ["row": rowDict(systemRows[index])])
    }

    private func executeRow(index: Int, option: String?, generation g: Int) async {
        defer { rowTask = nil }
        let id = systemRows[index].id
        var outcome: (ok: Bool, reason: String?, offer: String?, detail: String?) = (false, nil, nil, nil)
        switch id {
        case "agentmail_cli":
            if env.agentMailInstalled() {
                outcome = (true, nil, nil, "already installed")
            } else {
                let failure = await env.installAgentMail({ [weak self] line in
                    guard let self else { return }
                    Task { await self.runner.appendLine(line) }
                }, { [weak self] in
                    guard let self else { throw Superseded() }
                    try self.checkpointSync(g)
                }, runner)
                if let failure { outcome = (false, failure, nil, nil) }
                else { outcome = (env.agentMailInstalled(), env.agentMailInstalled() ? nil : "install finished but the wrapper is not verified", nil, nil) }
            }
        case "fda":
            outcome = env.fullDiskAccessGranted()
                ? (true, nil, nil, "granted")
                : (false, "Full Disk Access not granted yet — add \(env.terminalAppName()) in System Settings, then Retry", "open_settings", nil)
        case "keepawake":
            if env.isLinux {
                var verdict = env.autoSuspendVerdict()
                if case .maySuspend(let reason) = verdict, reason.hasPrefix("GNOME auto-suspend is on"), option == nil {
                    if env.disableGnomeAutoSuspend() { verdict = env.autoSuspendVerdict() }
                }
                if !verdict.isOK, option == "mask", let spec = env.maskSleepTargetsJob() {
                    let r = await runner.run(spec)
                    if r.ok { verdict = env.autoSuspendVerdict() }
                    else if r.survivors != nil || r.enumerationFailed { outcome = (false, r.failureReason, nil, nil); break }
                    else { outcome = (false, "sudo was declined in the terminal or masking failed (\(r.failureReason ?? "?"))", "mask", nil); break }
                }
                outcome = verdict.isOK
                    ? (true, nil, nil, verdict.summary)
                    : (false, "This machine may suspend and Briglia would stop (\(verdict.summary)). Mask the sleep targets, or use `briglia setup`.", "mask", AutoSuspendCensus.Verdict.maskCommand)
            } else {
                outcome = env.keepAwakeHeld()
                    ? (true, nil, nil, "Briglia prevents idle system sleep while it runs; a closed lid or a manual sleep still stops it")
                    : (false, "the keep-awake assertion is not held — restart `briglia quicksetup`", nil, nil)
            }
        case "toolchain":
            let status = env.toolchainStatus()
            if status.complete {
                outcome = (true, nil, nil, "all mandatory tools present")
            } else {
                let jobs = env.toolchainJobs(status)
                if jobs.isEmpty && !status.doctorRan {
                    outcome = (false, "the toolchain doctor could not run (python3?)", nil, nil)
                } else if jobs.isEmpty {
                    outcome = (false, "no installer available for: \(status.mandatoryMissing.joined(separator: ", "))", nil, nil)
                } else {
                    var failure: String?
                    for job in jobs {
                        if Task.isCancelled || generationBox.get() != g { failure = "cancelled"; break }
                        await runner.appendLine("▶ \(job.label)")
                        let r = await runner.run(job)
                        if !r.ok {
                            failure = "\(job.label): \(r.failureReason ?? "failed")"
                            if r.survivors != nil || r.enumerationFailed { break }
                            if job.mode == .terminalHandoff, case .exited = r.outcome { failure = "\(job.label): \(r.failureReason ?? "") (sudo declined in the terminal?)" }
                            break
                        }
                    }
                    let after = env.toolchainStatus()
                    if let failure { outcome = (false, failure, nil, nil) }
                    else if after.complete { outcome = (true, nil, nil, "installed") }
                    else { outcome = (false, "still missing after install: \(after.mandatoryMissing.joined(separator: ", "))\(after.libreOffice ? "" : ", LibreOffice")", nil, nil) }
                }
            }
        default:
            outcome = (false, "unknown row", nil, nil)
        }
        // Mutate only under the same generation.
        guard generationBox.get() == g else {
            systemRows[index].state = "failed"
            systemRows[index].reason = "this session was replaced; use the new link"
            return
        }
        systemRows[index].state = outcome.ok ? "ok" : "failed"
        systemRows[index].reason = outcome.reason
        systemRows[index].offer = outcome.offer
        systemRows[index].detail = outcome.detail
        if outcome.ok, systemRows.allSatisfy({ $0.state == "ok" }) {
            phase = .systemComplete
            finishSteps = Self.buildFinishSteps(linux: env.isLinux)
        }
    }

    func openSettings(generation g: Int) throws -> (Int, [String: Any]) {
        try checkpoint(g)
        guard phase == .system, !env.isLinux, let index = nextSystemRowIndex, systemRows[index].id == "fda" else {
            return (409, ["error": "phase"])
        }
        env.openSettingsPane()
        return (200, [:])
    }

    // MARK: Finish (§4.8)

    static func buildFinishSteps(linux: Bool) -> [RowState] {
        var steps = [RowState(id: "reverify", title: "Re-checking permissions, keep-awake and toolchain", state: "pending")]
        if linux {
            steps += [
                RowState(id: "unit", title: "Installing the background service", state: "pending"),
                RowState(id: "handoff", title: "Recording progress", state: "pending"),
                RowState(id: "release", title: "Handing over to the service", state: "pending"),
                RowState(id: "start", title: "Starting the service", state: "pending"),
                RowState(id: "service", title: "Verifying the service", state: "pending"),
            ]
        }
        steps += [
            RowState(id: "recheck", title: "Final check of everything", state: "pending"),
            RowState(id: "complete", title: "Marking setup complete", state: "pending"),
        ]
        return steps
    }

    func finish(generation g: Int) async throws -> (Int, [String: Any]) {
        try checkpoint(g)
        guard phase == .systemComplete || phase == .finishing else { return (409, ["error": "phase", "phase": phase.rawValue]) }
        if let poison = runner.currentPoison { return (409, ["error": "poisoned", "poisoned": poisonDict(poison)]) }
        guard finishTask == nil, runner.currentJob == nil else { return (409, ["error": "busy"]) }
        phase = .finishing
        if finishSteps.isEmpty { finishSteps = Self.buildFinishSteps(linux: env.isLinux) }
        let task = Task { [self] in await executeFinish(generation: g) }
        finishTask = task
        return (202, ["finish_steps": finishSteps.map(rowDict)])
    }

    private func setStep(_ id: String, _ state: String, reason: String? = nil, detail: String? = nil) {
        guard let i = finishSteps.firstIndex(where: { $0.id == id }) else { return }
        finishSteps[i].state = state
        finishSteps[i].reason = reason
        finishSteps[i].detail = detail
    }

    /// Non-service evidence, read-only (steps 2 and 8).
    private func nonServiceRegression() -> String? {
        if !env.isLinux, !env.fullDiskAccessGranted() { return "Full Disk Access is no longer granted" }
        if env.isLinux {
            if !env.autoSuspendVerdict().isOK { return "keep-awake: \(env.autoSuspendVerdict().summary)" }
        } else if !env.keepAwakeHeld() { return "keep-awake assertion not held" }
        let tc = env.toolchainStatus()
        if !tc.complete { return "toolchain incomplete: \(tc.mandatoryMissing.joined(separator: ", "))\(tc.libreOffice ? "" : " LibreOffice")" }
        if systemRows.contains(where: { $0.id == "agentmail_cli" }) || kept.contains(.agentmail), !env.agentMailInstalled(), kept.contains(.agentmail) {
            return "the AgentMail command-line tool is not installed"
        }
        return nil
    }

    private enum DurableOutcome { case done, barrierFailed(String), saveFailed(String) }

    /// Old-or-new semantics (§4.8): after a throw, re-read the store.
    private func durableSaveBatch(_ changes: [String: String?], newStatePresent: () -> Bool) -> DurableOutcome {
        do {
            try env.saveBatch(changes)
            return .done
        } catch {
            if newStatePresent() {
                var lastErr = "\(error)"
                for attempt in 0..<3 {
                    do { try env.fsyncConfigDirectory(); return .done } catch { lastErr = "\(error)" }
                    Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
                }
                return .barrierFailed("storage barrier failed: \(lastErr) (the new state is on disk but not confirmed durable)")
            }
            var lastErr = "\(error)"
            for attempt in 0..<3 {
                do { try env.saveBatch(changes); return .done } catch { lastErr = "\(error)" }
                Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
            }
            return .saveFailed("could not write secrets.json (store still holds the old state): \(lastErr)")
        }
    }

    private func executeFinish(generation g: Int) async {
        defer { finishTask = nil }
        func alive() -> Bool { generationBox.get() == g && !Task.isCancelled }
        func fail(_ id: String, _ reason: String) {
            guard alive() else { return }
            setStep(id, "failed", reason: reason)
            lastError = reason
        }
        let stepIDs = finishSteps.map(\.id)
        for id in stepIDs where finishSteps.first(where: { $0.id == id })?.state != "ok" {
            guard alive() else { return }
            setStep(id, "running")
            switch id {
            case "reverify":
                if resumeMode == .handoff {
                    // Constrained resume: regressed evidence → stop the service,
                    // reacquire the lease, back to the system phase.
                    if let why = nonServiceRegression() {
                        guard env.stopService() else { fail(id, "\(why) — and the service could not be stopped; stop it by hand (`systemctl --user stop briglia`) and rerun"); return }
                        guard env.reacquireLease() else { fail(id, "\(why) — and the instance lease could not be reacquired"); return }
                        leaseReleased = false
                        if case .saveFailed(let e) = durableSaveBatch([SetupWizard.progressKey: Self.progressSystem], newStatePresent: { env.storedValue(SetupWizard.progressKey) == Self.progressSystem }) {
                            fail(id, e); return
                        }
                        phase = .system
                        systemRows = Self.buildSystemRows(env: env, agentMail: kept.contains(.agentmail))
                        finishSteps = []
                        lastError = "\(why) — repairing through the system phase"
                        return
                    }
                    // Steps 3–6 are already done for a handoff resume.
                    for done in ["unit", "handoff", "release", "start"] { setStep(done, "ok") }
                } else if let why = nonServiceRegression() {
                    fail(id, why); return
                }
                setStep(id, "ok")
            case "unit":
                do { try env.installUnit() } catch { fail(id, "\(error.localizedDescription)"); return }
                setStep(id, "ok")
            case "handoff":
                switch durableSaveBatch([SetupWizard.progressKey: Self.progressHandoff], newStatePresent: { env.storedValue(SetupWizard.progressKey) == Self.progressHandoff }) {
                case .done: setStep(id, "ok")
                case .barrierFailed(let e): fail(id, e); return
                case .saveFailed(let e): fail(id, e); return
                }
            case "release":
                guard alive() else { return }
                if !leaseReleased { env.releaseLease(); leaseReleased = true }
                setStep(id, "ok")
            case "start":
                if let failure = await env.enableService(runner) { fail(id, failure); return }
                setStep(id, "ok")
            case "service":
                let ev = await env.serviceEvidence()
                guard alive() else { return }
                guard ev.ok else { fail(id, ev.detail); return }
                setStep(id, "ok", detail: ev.detail)
            case "recheck":
                if let why = nonServiceRegression() { fail(id, why); return }
                if env.isLinux {
                    let ev = await env.serviceEvidence()
                    guard alive() else { return }
                    guard ev.ok else { fail(id, "service: \(ev.detail)"); return }
                }
                let subscriptionActive = env.storedValue(ProviderProfiles.activeProfileKey) == "chatgpt"
                if subscriptionActive {
                    let auth = await env.subscription(["action": "status"]) { [weak self] in
                        guard let self else { throw Superseded() }; try self.checkpointSync(g)
                    }
                    guard alive() else { return }
                    guard auth["ok"] as? Bool == true, auth["state"] as? String == "signed_in",
                          auth["generation"] as? String == env.storedValue(ProviderProfiles.subscriptionGenerationKey) else {
                        fail(id, "ChatGPT login changed or ended; sign in and select it again before finishing setup"); return
                    }
                }
                for key in [(subscriptionActive ? ProviderProfiles.subscriptionModelKey : ProviderProfiles.opencodeApiKeyKey), KeychainHelper.openAITranscriptionApiKeyKey, KeychainHelper.serperApiKeyKey,
                            KeychainHelper.jinaApiKeyKey, KeychainHelper.telegramBotTokenKey, KeychainHelper.telegramChatIdKey, KeychainHelper.userNameKey]
                    where (env.storedValue(key) ?? "").isEmpty {
                    fail(id, "stored value missing: \(key)"); return
                }
                setStep(id, "ok")
            case "complete":
                guard alive() else { return }
                switch durableSaveBatch([SetupWizard.completeKey: "true", SetupWizard.progressKey: nil],
                                        newStatePresent: { env.storedValue(SetupWizard.completeKey) == "true" && env.storedValue(SetupWizard.progressKey) == nil }) {
                case .done:
                    setStep(id, "ok")
                    phase = .done
                    isDone = true
                case .barrierFailed(let e): fail(id, e); return
                case .saveFailed(let e): fail(id, e); return
                }
            default: break
            }
        }
    }

    // MARK: Recovery and fallback

    func recoverRecheck() -> (Int, [String: Any]) {
        if let p = runner.recheckPoison() { return (200, ["poisoned": poisonDict(p)]) }
        return (200, ["poisoned": NSNull()])
    }

    func stepByStep(generation g: Int) async throws -> (Int, [String: Any]) {
        try checkpoint(g)
        if let poison = runner.currentPoison { return (409, ["error": "poisoned", "poisoned": poisonDict(poison)]) }
        if runner.currentJob != nil || rowTask != nil || finishTask != nil { return (409, ["error": "busy"]) }
        // Revoke the page's authorization and let any in-flight verify/save
        // unwind before the wizard takes the terminal.
        generation += 1
        generationBox.set(generation)
        token = nil
        cookie = ""
        tokenUsed = true
        await settleInFlight()
        await cancelSetupLogin()
        wizardRequested = true
        return (200, ["message": "continue in the terminal"])
    }

    /// Keep the sync generation snapshot in step with the actor's.
    func syncGeneration() { generationBox.set(generation) }
}
