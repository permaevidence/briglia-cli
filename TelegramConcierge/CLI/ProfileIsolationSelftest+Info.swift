import ArgumentParser
import Foundation

/// Hidden, development-only: print what the SELECTED profile resolves to
/// (roots, display text, landing zone, spill directory, preferences suite,
/// machine paths, wrapper bytes, Playwright invocation) as one JSON object.
/// `--touch` additionally writes one marker into every per-profile store
/// (secrets, preferences, spill, landing zone, a data-root file) and reads
/// them back, so the isolation selftest can prove two profiles share no
/// state. Refused in stamped releases.
struct ProfileInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__profile-info",
        abstract: "Internal: show the selected assistant profile's resolved paths (development builds).",
        shouldDisplay: false
    )

    @Flag(name: .customLong("touch")) var touch = false
    @Flag(name: .customLong("read")) var read = false

    static let prefsProbeKey = "briglia.profileProbe"
    static let secretsProbeKey = KeychainHelper.userNameKey

    func run() throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ __profile-info is available only in development builds")
            throw ExitCode(2)
        }
        let name = AssistantProfile.selectedName
        var out: [String: Any] = [
            "profile": name,
            "envProfile": ProcessInfo.processInfo.environment[AssistantProfile.environmentKey] ?? NSNull(),
            "dataRoot": StoragePaths.dataRoot.path,
            "configRoot": StoragePaths.configRoot.path,
            "dataRootDisplay": StoragePaths.dataRootDisplay,
            "configRootDisplay": StoragePaths.configRootDisplay,
            "landingRoot": LandingZone.root.path,
            "scratchRepos": LandingZone.scratchReposRoot.path,
            "spillDir": TruncationService.truncationDir,
            "prefsSuite": Prefs.suiteName() ?? "standard",
            "machineDir": MachinePaths.machineDir().path,
            "sharedRoot": MachinePaths.sharedRoot().path,
            "releaseTrust": ReleaseTrustStore.fileURL.path,
            "noticeState": UpdateNoticeStore.Paths.live.state.path,
            "noticeSetting": UpdateNoticeStore.Paths.live.setting.path,
            "signInLock": MachinePaths.signInLock.path,
            "commandPrefix": AssistantProfile.commandPrefix,
            "agentmailWrapper": AgentMailService.wrapperScript(brigliaPath: "/opt/briglia"),
            "pythonWrapper": PythonRuntime.wrapperScript(brigliaPath: "/opt/briglia"),
            "playwrightArgs": ManagedPlaywright.managedInvocation(token: "0123456789abcdef", layout: .init()).arguments,
            "secretStore": KeychainHelper.secretStorePath,
            "sendsMachineNotices": UpdateNoticeService.sendsMachineNotices,
            "prefsStoreIsStandard": Prefs.store === UserDefaults.standard,
        ]
        if touch {
            try StoragePaths.ensureRootsChecked()
            let marker = "probe-\(name)"
            try KeychainHelper.save(key: Self.secretsProbeKey, value: marker)
            Prefs.store.set(marker, forKey: Self.prefsProbeKey)
            Prefs.store.synchronize()
            LandingZone.bootstrap()
            try marker.write(to: StoragePaths.dataRoot.appendingPathComponent("profile-probe.txt"), atomically: true, encoding: .utf8)
            let big = String(repeating: "\(marker)\n", count: 12_000)
            let spill = TruncationService.truncate(big)
            out["spillPath"] = spill.outputPath ?? NSNull()
            out["secretValue"] = KeychainHelper.load(key: Self.secretsProbeKey) ?? NSNull()
            out["prefsValue"] = Prefs.store.string(forKey: Self.prefsProbeKey) ?? NSNull()
        }
        if read {
            out["secretValue"] = KeychainHelper.load(key: Self.secretsProbeKey) ?? NSNull()
            out["prefsValue"] = Prefs.store.string(forKey: Self.prefsProbeKey) ?? NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
