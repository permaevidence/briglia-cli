import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for the live menu (KEYLESS_WEB_AND_LIVE_MENU plan Part B,
/// §B.11): preparation by capture, classification at the decision point,
/// the commit transaction, staging and the superseding observer, the idle
/// apply, subscription operations and their journal, crash recovery, the
/// commit token and lifecycle protocol, agent field edits as conditional
/// deltas, forwarding, the lock-file label, the /websearch move, the
/// daemon-level idle triggers and the setup provider order.
///
/// Isolation: re-executes itself in a private scratch home (HOME, XDG_*,
/// CFFIXED_USER_HOME, TMPDIR) through a `briglia-mw-*` link (private
/// preference domain); it never touches a real install. Sections live in
/// `LiveMenuSelftest+*` files so no single function grows past the Linux
/// frontend's budget.
struct LiveMenuSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__live-menu-selftest",
        abstract: "Internal: verify the live menu's single settings writer.",
        shouldDisplay: false
    )
    static let childName = "briglia-mw-live-menu-selftest"
    static let rootPrefix = "briglia-live-menu-"

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = LiveMenuHarness(only: only)
        guard h.isolated() else { throw ExitCode(1) }
        await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) live-menu check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) live-menu checks passed")
    }

    static func reexecIsolated(only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "home/.local/state", "home/.cache", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(childName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") { env.removeValue(forKey: key) }
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["XDG_STATE_HOME"] = home + "/.local/state"
        env["XDG_CACHE_HOME"] = home + "/.cache"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__live-menu-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(childName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// A settings owner whose busy state the test drives (the daemon's
/// `beginBrowserSettingsMutation` refuses while a turn runs).
@MainActor
final class FakeSettingsOwner: SettingsOwnerHost, SettingsApplyKicking {
    var busy = false
    var barrierHeld = false
    var barriersTaken = 0
    var admission: String?
    var reconciles: [(label: String, routeChanged: Bool)] = []
    var kicks = 0
    var isDaemon: Bool { true }
    func beginRouteBarrier() async -> Bool {
        if busy { return false }
        barrierHeld = true; barriersTaken += 1
        return true
    }
    func endRouteBarrier() { barrierHeld = false }
    func admissionRefusal() -> String? { admission }
    func reconcile(after change: PreparedChange, routeChanged: Bool) async { reconciles.append((change.label, routeChanged)) }
    var toolSwitches: SettingsToolSwitches { SettingsToolSwitches(subagents: true, webSubagent: true) }
    func kickSettingsApply() { kicks += 1 }
}

@MainActor
final class LiveMenuHarness {
    let only: String?
    var total = 0
    var failures = 0

    init(only: String?) { self.only = only }

    func isolated() -> Bool {
        let data = StoragePaths.dataRoot.path
        guard data.contains(LiveMenuSelftest.rootPrefix), ProcessInfo.processInfo.processName == LiveMenuSelftest.childName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return false
        }
        return true
    }

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("✔ \(label)") } else { failures += 1; print("✖ \(label)\(detail().isEmpty ? "" : " — " + detail())") }
    }

    func section(_ name: String) -> Bool {
        guard only == nil || only == name else { return false }
        print("\n── \(name) ──")
        return true
    }

    func runAll() async {
        if section("capture") { await captureSection(); await captureEdgeSection() }
        if section("roles") { rolesCompletenessSection(); rolesMutationSection() }
        if section("classify") { await classifySection() }
        if section("commit") { await commitSection(); await commitRaceSection() }
        if section("pending") { await pendingSection(); await pendingApplySection() }
        if section("subscription") { await subscriptionSection(); await subscriptionFailureSection() }
        if section("recovery") { recoverySection(); recoveryScopeSection() }
        if section("gate") { await gateSection(); await lifecycleSection() }
        if section("agent-edit") { await agentEditSection() }
        if section("forward") { await forwardSection(); leaseLabelSection() }
        if section("misc") { websearchSection(); orderSection() }
        if section("extra") { await extraSection(); await pairingSection() }
        if section("startup") { await startupSection() }
        if section("daemon") { await daemonSection() }
        if section("round1") { await round1Section() }
        if section("round2") { await round2Section() }
        if section("round3") { await round3Section() }
    }

    // MARK: Fixtures

    /// A fresh store and no pending file / auth store / epoch.
    func reset(_ store: [String: String] = [:]) {
        SettingsSupersede.uninstall()
        let fm = FileManager.default
        for url in [StoragePaths.configRoot.appendingPathComponent("secrets.json"), SettingsPendingStore.url,
                    StoragePaths.configRoot.appendingPathComponent(SubscriptionEndpoint.storeName), ReplacementEpoch.url] {
            try? fm.removeItem(at: url)
        }
        try? KeychainHelper.saveBatch(store.mapValues { Optional($0) })
        KeychainHelper._testFailWrites = false
        SettingsWriter.afterIntentForTesting = nil
        SettingsWriter.afterAuthWriteForTesting = nil
        SettingsWriter.afterSecretsWriteForTesting = nil
        SettingsWriter.authStoreForTesting = nil
    }

    /// Prepares a raw secrets delta as the menu would (through capture).
    func prepare(label: String = "test", accept: Bool = true, _ body: () throws -> Void) async -> PreparedChange? {
        let (change, _) = await SettingsCapture.prepare(origin: "selftest", label: label, acceptPending: accept) {
            do { try body(); return ["ok": true] } catch { return ["ok": false, "error": "\(error)"] }
        }
        return change
    }

    func store() -> [String: String] { (try? KeychainHelper.strictSnapshot()) ?? [:] }

    func pendingDoc() -> SettingsPendingStore.Document { (try? SettingsPendingStore.read()) ?? .init() }

    static let routeBase: [String: String] = [
        KeychainHelper.llmProviderKey: "openrouter",
        ProviderProfiles.activeProfileKey: "openrouter",
        KeychainHelper.openRouterModelKey: "deepseek/deepseek-v4.1-flash-1017",
        KeychainHelper.openRouterApiKeyKey: "sk-or-synthetic-old-0001",
        KeychainHelper.serperApiKeyKey: "serper-synthetic-old-0001",
        KeychainHelper.userNameKey: "Tester",
    ]

    func credential(_ account: String = "acct-1", _ tag: String = "1") -> SubscriptionCredential {
        SubscriptionCredential(access: "access-synthetic-\(tag)", refresh: "refresh-synthetic-\(tag)",
                               expires: Date().addingTimeInterval(3600), account: account, residency: nil)
    }

    var authStore: SubscriptionAuthStore { SubscriptionAuthStore(directory: StoragePaths.configRoot) }

    func writeAuth(_ state: SubscriptionAuthState) {
        try? PrivateStorage.ensureDirectory(StoragePaths.configRoot)
        do { try authStore.write(state) } catch { check("fixture: auth state written", false, "\(error)") }
    }
}
