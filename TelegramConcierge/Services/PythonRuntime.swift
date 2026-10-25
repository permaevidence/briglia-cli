import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Briglia's private Python environment (security plan v24 §7.9.4): a venv
/// built from ONE universal hashed lock (Resources/PythonEnv/requirements.lock)
/// with `pip install --require-hashes --no-deps --only-binary=:all:` on top
/// of the user's own python3 (≥ 3.11, never modified). Briglia never installs
/// into the shared interpreter again (no --break-system-packages) and
/// `briglia-python` never falls back to it (R21-3).
enum PythonRuntime {
    static let minimumMinor = 11
    static let importProbe = ["openpyxl", "docx", "pptx", "PIL", "formulas", "pymupdf"]
    static let legacyProbe = ["openpyxl", "docx", "pptx", "PIL", "formulas", "pymupdf", "fitz"]
    static let wrapperName = "briglia-python"
    static var wrapperURL: URL { RuntimePaths.binDir.appendingPathComponent(wrapperName) }

    // MARK: Lock

    static var lockURL: URL? {
        if let p = RuntimeSeams.env("BRIGLIA_PYTHON_TEST_LOCK") { return URL(fileURLWithPath: p) }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let bundleURL = executable.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path), let res = Bundle.module.resourceURL else { return nil }
        let url = res.appendingPathComponent("PythonEnv/requirements.lock")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var lockSHA256: String? { lockURL.flatMap { RuntimeFS.sha256(file: $0) } }

    // MARK: Base interpreter (user-owned)

    struct Base: Equatable { let path: String; let minor: Int; let version: String }

    static var effectiveMinimumMinor: Int { RuntimeSeams.env("BRIGLIA_PYTHON_MIN_MINOR").flatMap(Int.init) ?? minimumMinor }

    static func baseCandidates(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        let names = ["python3", "python3.14", "python3.13", "python3.12", "python3.11"]
        var dirs = (path ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        if let only = RuntimeSeams.env("BRIGLIA_PYTHON_TEST_BASE_DIRS") {
            dirs = only.split(separator: ":").map(String.init)   // selftests: exactly these directories
        } else {
            dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        }
        let root = RuntimePaths.dataRoot.resolvingSymlinksInPath().path
        var seen = Set<String>(), out: [String] = []
        for d in dirs {
            for n in names {
                let p = d + "/" + n
                guard FileManager.default.isExecutableFile(atPath: p) else { continue }
                let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
                if real.hasPrefix(root + "/") { continue }
                if seen.insert(real).inserted { out.append(p) }
            }
        }
        return out
    }

    /// The first user python ≥ 3.11 that has `venv` and `ensurepip`.
    static func findBase() async -> (Base?, [String]) {
        var reasons: [String] = []
        for p in baseCandidates() {
            let r = await RuntimeProcess.run(p, ["-c", "import sys, venv, ensurepip; print('%d.%d.%d' % sys.version_info[:3])"],
                                             env: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: 20)
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = v.split(separator: ".").compactMap { Int($0) }
            guard r.status == 0, parts.count == 3, parts[0] == 3 else {
                reasons.append("\(p): no usable venv/ensurepip"); continue
            }
            guard parts[1] >= effectiveMinimumMinor else { reasons.append("\(p) is \(v), older than 3.\(minimumMinor)"); continue }
            return (Base(path: p, minor: parts[1], version: v), reasons)
        }
        return (nil, reasons)
    }

    static func installHint() -> String {
        #if os(Linux)
        return "install Python 3.11 or newer with venv support (Debian/Ubuntu: `sudo apt install python3-venv`)"
        #else
        return "install Python 3.11 or newer (`brew install python`)"
        #endif
    }

    // MARK: Spec

    static func pin(base: Base) -> RuntimePin? {
        guard let sha = lockSHA256 else { return nil }
        return RuntimePin(triple: "\(NodeRuntime.platform)-py3.\(base.minor)", version: String(sha.prefix(12)), archiveSHA256: sha)
    }

    static func spec(base: Base, pin: RuntimePin) -> RuntimeSpec {
        RuntimeSpec(
            component: .python, pin: pin, binaryRelPath: "env/pyvenv.cfg", usesHold: false,
            directoryName: { p in "\(p.version)-py3.\(base.minor)" },
            stage: { payload, progress in try await build(base: base, payload: payload, progress: progress) },
            postProbe: { _ in await probe(python: RuntimePaths.current(.python).appendingPathComponent("env/bin/python").path) },
            validateExtra: { record, dir in validateExtra(record, dir) },
            stagesInPlace: true)
    }

    static func validateExtra(_ record: RuntimeRecord, _ dir: URL) -> String? {
        let link = RuntimeFS.readLink(dir.appendingPathComponent("env/bin/python"))
        if let want = record.extra?["pythonLink"], link != want { return "env/bin/python changed" }
        if let base = record.extra?["base"], !FileManager.default.isExecutableFile(atPath: base) {
            return "its base interpreter \(base) is gone"
        }
        return nil
    }

    static func build(base: Base, payload: URL, progress: (@Sendable (String) -> Void)?) async throws -> [String: String]? {
        guard let lock = lockURL else { throw RuntimeError("the Python lock is missing from the resource bundle") }
        try PrivateStorage.ensureDirectory(payload)
        let env = payload.appendingPathComponent("env", isDirectory: true)
        progress?("Creating Briglia's Python environment (Python \(base.version))…")
        let clean = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "PIP_DISABLE_PIP_VERSION_CHECK": "1",
                     "PIP_NO_INPUT": "1", "PIP_CONFIG_FILE": "/dev/null"]
        let mk = await RuntimeProcess.run(base.path, ["-m", "venv", env.path], env: clean, timeout: 300)
        guard mk.status == 0 else { throw RuntimeError("could not create the environment: \(RuntimeProcess.detail(mk)) — \(installHint())") }
        let py = env.appendingPathComponent("bin/python").path
        var args = ["-m", "pip", "install", "--require-hashes", "--no-deps", "--only-binary=:all:", "--no-cache-dir",
                    "--disable-pip-version-check", "--no-input", "-r", lock.path]
        if let links = RuntimeSeams.env("BRIGLIA_PYTHON_TEST_FIND_LINKS") { args += ["--no-index", "--find-links", links] }
        progress?("Installing the pinned Python packages (several hundred MB)…")
        let inst = await RuntimeProcess.run(py, args, env: clean, timeout: 3600)
        guard inst.status == 0 else { throw RuntimeError("pip refused the pinned packages: \(RuntimeProcess.detail(inst))") }
        if let why = await probe(python: py, lock: lock) { throw RuntimeError(why) }
        var extra: [String: String] = ["base": base.path, "baseVersion": base.version]
        if let link = RuntimeFS.readLink(env.appendingPathComponent("bin/python")) { extra["pythonLink"] = link }
        return extra
    }

    /// Imports + `pip check` + installed set == active lock entries plus the
    /// bootstrap allowance, and no locked runtime requirement satisfied only
    /// by a bootstrap package (v23). nil = passed.
    static func probe(python: String, lock: URL? = lockURL) async -> String? {
        guard let lock else { return "the Python lock is missing" }
        let clean = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "PIP_DISABLE_PIP_VERSION_CHECK": "1", "PIP_CONFIG_FILE": "/dev/null"]
        let modules = RuntimeSeams.env("BRIGLIA_PYTHON_TEST_PROBE")?.split(separator: ",").map(String.init) ?? importProbe
        let imp = await RuntimeProcess.run(python, ["-c", modules.map { "import \($0)" }.joined(separator: "; ")], env: clean, timeout: 120)
        guard imp.status == 0 else { return "a pinned package does not import: \(RuntimeProcess.detail(imp))" }
        let chk = await RuntimeProcess.run(python, ["-m", "pip", "check"], env: clean, timeout: 120)
        guard chk.status == 0 else { return "pip check: \(chk.stdout.prefix(200))" }
        let cmp = await RuntimeProcess.run(python, ["-c", distributionCheck, lock.path], env: clean, timeout: 120)
        guard cmp.status == 0 else { return "installed set differs from the lock: \(cmp.stdout.prefix(300))\(cmp.stderr.prefix(200))" }
        return nil
    }

    /// Run by the venv's interpreter: compare installed distributions with
    /// the lock entries active for this interpreter (markers evaluated with
    /// pip's vendored `packaging`), plus the bootstrap allowance.
    static let distributionCheck = """
    import sys, re, importlib.metadata as md
    from pip._vendor.packaging.markers import Marker
    from pip._vendor.packaging.requirements import Requirement
    norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
    want = {}
    for line in open(sys.argv[1], encoding="utf-8"):
        if not line[:1].isalnum():
            continue
        spec = line.split("\\\\")[0].strip()
        req, _, marker = spec.partition(";")
        name, _, ver = req.strip().partition("==")
        if marker.strip() and not Marker(marker.strip()).evaluate():
            continue
        want[norm(name)] = ver.strip()
    boot = {"pip"} | ({"setuptools"} if sys.version_info < (3, 12) else set())
    have = {norm(d.metadata["Name"]): d.version for d in md.distributions()}
    bad = []
    for n, v in have.items():
        if n in want:
            if want[n] != v: bad.append(f"{n} {v} != locked {want[n]}")
        elif n not in boot:
            bad.append(f"unexpected distribution {n} {v}")
    for n in want:
        if n not in have: bad.append(f"missing {n}")
    for n in want:
        try:
            reqs = md.distribution(n).requires or []
        except md.PackageNotFoundError:
            continue
        for r in reqs:
            q = Requirement(r)
            if q.marker is not None and not q.marker.evaluate({"extra": ""}):
                continue
            if norm(q.name) in boot and norm(q.name) not in want:
                bad.append(f"{n} needs the unpinned bootstrap package {q.name}")
    print("; ".join(bad))
    sys.exit(1 if bad else 0)
    """

    // MARK: Consumers

    static func wrapperScript(brigliaPath: String) -> String {
        "#!/bin/sh\n# Installed by Briglia CLI: Briglia's private Python environment (never the shared python3).\nexec '\(brigliaPath)' __python-exec \"$@\"\n"
    }

    static func ensureWrapper() throws {
        let bytes = Data(wrapperScript(brigliaPath: AgentMailService.brigliaPath()).utf8)
        if (try? Data(contentsOf: wrapperURL)) == bytes, FileManager.default.isExecutableFile(atPath: wrapperURL.path) { return }
        try PrivateStorage.ensureDirectory(RuntimePaths.binDir)
        switch RuntimeFS.kind(wrapperURL.path) {
        case .absent, .regular: break
        default: throw RuntimeError("\(wrapperURL.path) exists and is not a regular file — refusing")
        }
        try PrivateStorage.writeAtomically(bytes, to: wrapperURL, mode: 0o700)
    }

    enum ExecDecision: Equatable { case run(String), refuse(String) }

    /// Lock-free per-exec validation (cheap; §7.9.4).
    static func execDecision() -> ExecDecision {
        let c = RuntimeComponent.python
        let st = RuntimeSelectionStore.peek()?[c]
        guard let receipt = (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c))) ?? nil,
              let v = receipt.verifiedRecord, PrivateRuntimeEngine.currentState(c) == .ref(v.directory) else {
            if let a = st?.attempts.last(where: { $0.result == nil }), !RuntimeProcessIdentity.ownerGone(a) {
                return .refuse("Briglia's Python environment is being prepared — try again in a few minutes")
            }
            if let failed = st?.attempts.last?.result, failed.hasPrefix("failed") {
                return .refuse("Briglia's Python environment could not be set up (\(failed.dropFirst("failed: ".count))) — run `briglia python-env install`")
            }
            return .refuse("Briglia's Python environment is not set up yet — run `briglia python-env install` (or the toolchain button in `briglia menu`)")
        }
        let dir = RuntimePaths.dir(c).appendingPathComponent(v.directory)
        guard RuntimeFS.sha256(file: dir.appendingPathComponent("env/pyvenv.cfg")) == v.binarySHA256,
              validateExtra(v, dir) == nil else {
            return .refuse("Briglia's Python environment does not match its receipt — Briglia rebuilds it at the next start (or run `briglia python-env install`)")
        }
        return .run(dir.appendingPathComponent("env/bin/python").path)
    }

    // MARK: Convergence

    enum Status: Equatable { case ready(String), unavailable(String), failed(String), notSetUp }

    static func legacySharedSetup(base: Base) async -> Bool {
        let modules = RuntimeSeams.env("BRIGLIA_PYTHON_TEST_LEGACY_PROBE")?.split(separator: ",").map(String.init) ?? legacyProbe
        let list = "[" + modules.map { "'\($0)'" }.joined(separator: ",") + "]"
        let probe = "import importlib.util as u, sys; sys.exit(0 if any(u.find_spec(m) for m in \(list)) else 1)"
        let r = await RuntimeProcess.run(base.path, ["-c", probe], env: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], timeout: 30)
        return r.status == 0
    }

    /// `trigger: .install` (setup, `briglia python-env install`) always
    /// builds; startup (`.auto`) only rebuilds an existing venv for a new lock
    /// or moves a machine that had set Python features up the old way.
    static func converge(trigger: RuntimeTrigger, progress: (@Sendable (String) -> Void)? = nil) async -> Status {
        let (base, reasons) = await findBase()
        guard let base else { return .unavailable("no suitable python3: \(installHint())" + (reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))")) }
        guard let pin = pin(base: base) else { return .unavailable("the Python lock is missing from the resource bundle") }
        let spec = spec(base: base, pin: pin)
        if trigger == .auto {
            let health = await PrivateRuntimeEngine.recover(spec)
            let hadVenv: Bool = {
                if case .ready = health { return true }
                if case .unknown = health { return true }
                return ((try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.python))) ?? nil)?.records.isEmpty == false
            }()
            if !hadVenv, !(await legacySharedSetup(base: base)) { return .notSetUp }
        }
        let outcome = await PrivateRuntimeEngine.converge(spec, trigger: trigger, progress: progress)
        switch outcome {
        case .upToDate(let r), .converged(let r):
            try? ensureWrapper()
            _ = PrivateRuntimeEngine.collectGarbage(spec)
            return .ready(r.extra?["baseVersion"] ?? base.version)
        case .failed(let w), .abandoned(let w), .throttled(let w), .busy(let w), .notApplicable(let w):
            try? ensureWrapper()
            return .failed(w)
        case .held:
            return .failed("held")
        }
    }
}
