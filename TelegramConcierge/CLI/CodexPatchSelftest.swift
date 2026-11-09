import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// GPT `apply_patch` engine, stage S1 (GPT_APPLY_PATCH_PLAN §14.1–14.5,
/// §14.10b F2/F3/R3-1/R3-2, §21): source fidelity against the pinned Codex
/// sources, engine unit tests, transaction failure injection, the Codex
/// scenario corpus and the golden differential corpus.
///
/// Isolation: re-executes itself in a private scratch home (HOME, XDG_*_HOME,
/// CFFIXED_USER_HOME, TMPDIR) under a hard link with a reserved test prefix,
/// so it never touches a real install's state or preference domain.
struct CodexPatchSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__codex-patch-selftest",
        abstract: "Internal: verify the GPT apply_patch engine (Codex port).",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var fixtures: String?
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-codexpatch-selftest"
    static let rootPrefix = "briglia-codex-patch-"

    /// The vendored fixtures, next to this source file in the checkout.
    static var defaultFixtures: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/codex-apply-patch").path
    }

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let fixtureDir = fixtures ?? Self.defaultFixtures
        guard child else { try Self.reexecIsolated(fixtures: fixtureDir, only: only); return }
        let t = CPTest(fixtures: fixtureDir, only: only.map { Set($0.split(separator: ",").map(String.init)) })
        await Self.battery(t)
        print("Codex patch selftest: \(t.total - t.failures)/\(t.total) passed")
        if t.failures > 0 { throw ExitCode(1) }
    }

    static func reexecIsolated(fixtures: String, only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
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
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__codex-patch-selftest", "--child", "--fixtures", fixtures] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        if TestPrefsDomains.candidatePaths(linkName).contains(where: { fm.fileExists(atPath: $0) }) {
            TestPrefsDomains.purge(linkName)
            TestPrefsDomains.finalSweep()
        }
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }

    static func battery(_ t: CPTest) async {
        CodexPatchTransaction.faultInjector = nil
        if t.runs("F") { await fidelityParser(t); fidelityExtraVectors(t); await fidelityStreaming(t); fidelitySeek(t); await fidelityFileUpdate(t); await fidelityLib(t) }
        if t.runs("E") { await engineText(t); await enginePaths(t); await engineMatching(t); await engineLimits(t) }
        if t.runs("K") { await ledgerTests(t) }
        if t.runs("S") { await secretStoreTests(t) }
        if t.runs("T") { await transactionTests(t); await transactionRollbackTests(t); await rollbackStageFailureTests(t) }
        if t.runs("C") { await scenarioCorpus(t) }
        if t.runs("G") { await goldenCorpus(t) }
        if t.runs("X") { await extractionTests(t) }
        CodexPatchTransaction.faultInjector = nil
        CodexPatchTransaction.beforeRevalidateHook = nil
        CodexPatchTransaction.beforeRollbackHook = nil
    }
}

/// Shared harness state for the selftest groups.
final class CPTest: @unchecked Sendable {
    var total = 0
    var failures = 0
    let fixtures: String
    let only: Set<String>?
    /// A fresh working directory per test (inside the scratch home).
    let base: URL

    init(fixtures: String, only: Set<String>?) {
        self.fixtures = fixtures
        self.only = only
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSTemporaryDirectory()
        // Resolve /var → /private/var so displayed paths are canonical.
        base = URL(fileURLWithPath: home).resolvingSymlinksInPath().appendingPathComponent("cp-work")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func runs(_ group: String) -> Bool { only.map { $0.contains(group) } ?? true }

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if !ok { failures += 1 }
        let d = ok ? "" : detail()
        print("\(ok ? "✔" : "✖") \(label)\(d.isEmpty ? "" : " — \(String(d.prefix(1200)))")")
    }

    /// A new empty directory for one test.
    func dir(_ name: String) -> String {
        let url = base.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    // MARK: File helpers

    func write(_ path: String, _ text: String) { write(path, Data(text.utf8)) }
    func write(_ path: String, _ data: Data) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
    }
    func read(_ path: String) -> String? { (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) } }
    func bytes(_ path: String) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: path)) }
    func exists(_ path: String) -> Bool {
        if let id = try? FileIdentity.lstatPath(path) { return id != nil }
        return false
    }
    func mode(_ path: String) -> mode_t? { (try? FileIdentity.lstatPath(path))??.mode }

    /// Seeds fresh GPT evidence for `path` (as a delivered read would).
    func seed(_ path: String) async {
        let key = CodexPatch.evidenceKey(path)
        guard let id = (try? FileIdentity.lstatPath(key)) ?? nil else { return }
        await FileTimeTracker.shared.publishGPT(GPTEvidence.Receipt(key: key, identity: id, source: .gptReadFile))
    }

    func apply(_ patch: String, workdir: String? = nil) async -> CodexPatch.Result {
        await CodexPatch.apply(CodexPatch.Request(input: patch, lastWorkdir: workdir))
    }

    func wrap(_ body: String) -> String { "*** Begin Patch\n\(body)\n*** End Patch" }
}
