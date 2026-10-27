import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden selftest of assistant profiles, stage 1 (MULTI_ASSISTANT_PLAN v5
/// §3, §5.1, §5.3–§5.6, §16 items 1, 3, 11 and 12): bootstrap rules, the
/// preferences suite, two extras that share no state with each other or with
/// default, default byte-for-byte unchanged, machine paths, the registry and
/// its reservation transactions, the sign-in lock.
///
/// Everything stateful runs in fresh CHILD processes inside a scratch root
/// (own HOME, XDG roots, TMPDIR, landing seam) through a hard link named
/// `briglia-mw-profiles`, so preference domains are throwaway and purged at
/// the end; in-process checks use temporary paths only. The real install,
/// its preferences domain and any Telegram bot are never touched.
struct ProfileIsolationSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__profile-isolation-selftest",
        abstract: "Internal: assistant-profile isolation selftest.",
        shouldDisplay: false
    )

    @Option(name: .customLong("only")) var only: String?

    func run() throws {
        let h = try ProfileHarness(only: only)
        defer { h.cleanup() }
        if h.section("bootstrap") { h.bootstrapSection() }
        if h.section("prefs") { h.prefsSuiteSection() }
        if h.section("default") { h.defaultInvarianceSection() }
        if h.section("extras") { h.extrasSection() }
        if h.section("isolation") { h.isolationSection() }
        if h.section("inheritance") { h.inheritanceSection() }
        if h.section("registry") { h.registrySection() }
        if h.section("transactions") { h.transactionSection() }
        if h.section("reconcile") { h.reconcileSection() }
        if h.section("signin") { h.signInSection() }
        if h.section("round2") { h.round2Section() }
        print("\n\(h.total - h.failures)/\(h.total) profile isolation checks passed")
        if h.failures > 0 { throw ExitCode(1) }
    }
}

final class ProfileHarness {
    let only: String?
    var failures = 0
    var total = 0
    let root: URL
    let exe: URL
    let env: [String: String]
    static let exeName = "briglia-mw-profiles"
    static let suitePrefix = "briglia-mw-profiles-"

    init(only: String?) throws {
        self.only = only
        let fm = FileManager.default
        // Canonical (symlink-free) scratch root, so path expectations hold
        // whether the temporary directory is /tmp, /var/folders or /private/….
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("briglia-pst-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for sub in ["home", "tmp", "landing"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        var e = ProcessInfo.processInfo.environment
        e["HOME"] = home.path
        e["CFFIXED_USER_HOME"] = home.path
        e["XDG_CONFIG_HOME"] = home.path + "/.config"
        e["XDG_DATA_HOME"] = home.path + "/.local/share"
        e["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        e[AssistantProfile.experimentalKey] = "1"
        e[LandingZone.testRootKey] = root.appendingPathComponent("landing").path
        e[TruncationService.testSpillRootKey] = root.appendingPathComponent("tmp").path + "/"
        e[Prefs.testSuitePrefixKey] = Self.suitePrefix
        e.removeValue(forKey: AssistantProfile.environmentKey)
        env = e
        // The same preference-domain trick as every other stateful selftest:
        // a binary named `briglia` is served the real install's domain.
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        exe = root.appendingPathComponent(Self.exeName)
        if link(source.path, exe.path) != 0 { try fm.copyItem(at: source, to: exe) }
    }

    func cleanup() {
        TestPrefsDomains.purge(Self.exeName)
        for name in ["work", "health", "bot2", "w2"] {
            TestPrefsDomains.purge(Self.suitePrefix + "briglia.profile.\(name).\(AssistantProfile.installationHash(name, environment: env))")
        }
        TestPrefsDomains.finalSweep()
        try? FileManager.default.removeItem(at: root)
    }

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

    // MARK: - Child processes

    struct Run { var status: Int32; var out: String }

    @discardableResult
    func run(_ args: [String], extraEnv: [String: String] = [:], removeEnv: [String] = [], stdin: String? = nil) -> Run {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var e = env
        for (k, v) in extraEnv { e[k] = v }
        for k in removeEnv { e.removeValue(forKey: k) }
        p.environment = e
        p.currentDirectoryURL = root
        let out = Pipe()
        let input = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input
        do { try p.run() } catch { return Run(status: -1, out: "spawn failed: \(error)") }
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, out: String(decoding: data, as: UTF8.self))
    }

    /// `__profile-info` for a selection; nil on failure.
    func info(_ selection: [String] = [], touch: Bool = false, extraEnv: [String: String] = [:],
              removeEnv: [String] = []) -> [String: Any]? {
        let r = run(selection + ["__profile-info"] + (touch ? ["--touch"] : []), extraEnv: extraEnv, removeEnv: removeEnv)
        guard r.status == 0, let line = r.out.split(separator: "\n").last,
              let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            print("   (info \(selection) failed: status \(r.status): \(r.out.suffix(400)))")
            return nil
        }
        return obj
    }

    var home: String { env["HOME"]! }
    var dataBase: String { env["XDG_DATA_HOME"]! }
    var configBase: String { env["XDG_CONFIG_HOME"]! }

    /// Every regular file under `dir` (relative-free absolute paths).
    func files(under dir: String) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let path = dir + "/" + rel
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { out.append(path) }
        }
        return out.sorted()
    }

    func writeDefaultSecrets(_ values: [String: String]) throws {
        let dir = URL(fileURLWithPath: configBase).appendingPathComponent("briglia", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        try data.write(to: dir.appendingPathComponent("secrets.json"))
        chmod(dir.appendingPathComponent("secrets.json").path, 0o600)
    }

    func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Symlink-free form for path comparisons with what a child resolved.
    func canon(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    func mode(_ path: String) -> mode_t {
        var st = stat()
        return stat(path, &st) == 0 ? (st.st_mode & 0o777) : 0
    }
}
