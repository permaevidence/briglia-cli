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

    struct Base: Equatable {
        let path: String; let minor: Int; let version: String
        /// The interpreter the path resolves to (whole symlink chain).
        var resolved: String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        /// Identity bound into the pin (review R4): a different resolved
        /// interpreter or version — patch included — is a different pin, so
        /// startup rebuilds instead of taking the "up to date" fast path.
        var identity: String { String(RuntimeFS.sha256(Data("\(resolved)\u{0}\(version)".utf8)).prefix(10)) }
    }

    static var effectiveMinimumMinor: Int { RuntimeSeams.env("BRIGLIA_PYTHON_MIN_MINOR").flatMap(Int.init) ?? minimumMinor }

    /// The newest CPython minor the lock has wheels for. The lock
    /// (Resources/PythonEnv/requirements.lock) pins binary-only packages
    /// (numpy, scipy, pillow, lxml, …) whose cp3XX wheels exist only up to
    /// this minor; a newer interpreter makes pip refuse the lock (2026-10-29:
    /// Homebrew python3 = 3.15.1 had no numpy 2.5.4 wheel). Raise it only
    /// after regenerating/verifying the lock for the new minor; the
    /// `MAX_PYTHON_MINOR` constant in scripts/python_lock.py must match
    /// (`python_lock.py --check` compares them).
    static let maximumMinor = 14
    static var effectiveMaximumMinor: Int { RuntimeSeams.env("BRIGLIA_PYTHON_MAX_MINOR").flatMap(Int.init) ?? maximumMinor }

    static func baseCandidates(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        let names = ["python3"] + stride(from: maximumMinor, through: minimumMinor, by: -1).map { "python3.\($0)" }
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

    /// One candidate interpreter as probed: its version (nil = not a working
    /// CPython 3) and whether it has `venv` + `ensurepip`.
    struct Probe: Equatable { let path: String; let version: String?; let hasVenv: Bool
        var minor: Int? { version.flatMap { v in let p = v.split(separator: ".").compactMap { Int($0) }; return p.count == 3 && p[0] == 3 ? p[1] : nil } }
    }

    /// The outcome of choosing a base interpreter.
    struct Selection {
        var base: Base?
        var reasons: [String] = []
        /// The newest interpreter found that is newer than `maximumMinor` (only
        /// reported when nothing supported is usable).
        var newestUnsupported: String?
        /// The best supported-version interpreter that lacks venv/ensurepip
        /// (Debian/Ubuntu without python3.X-venv), when nothing usable exists.
        var missingVenv: Base?
    }

    /// Marker the probe carries so selftest fake interpreters can recognise it.
    static let baseProbeScript = """
    # briglia-base-probe
    import sys
    print('%d.%d.%d' % sys.version_info[:3], flush=True)
    try:
        import venv, ensurepip
    except Exception:
        sys.exit(3)
    print('venv', flush=True)
    """

    static func parseProbe(path: String, status: Int32, stdout: String) -> Probe {
        let lines = stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let v: String? = lines.first
        let parts: [Int] = (v ?? "").split(separator: ".").compactMap { Int(String($0)) }
        guard let v, parts.count == 3, parts[0] == 3, status == 0 || status == 3 else { return Probe(path: path, version: nil, hasVenv: false) }
        return Probe(path: path, version: v, hasVenv: status == 0 && lines.contains("venv"))
    }

    /// Pure choice (unit-tested): among interpreters whose minor is within
    /// [minimum, maximum] and that have venv, keep the one the current
    /// environment was built on when it is still offered with the very same
    /// version (no surprise rebuild of several hundred MB at startup);
    /// otherwise the newest minor wins (ties: PATH order). Interpreters newer
    /// than the maximum are never used, whatever `python3` resolves to.
    static func choose(_ probes: [Probe], recorded: (path: String, version: String)? = nil,
                       minMinor: Int = effectiveMinimumMinor, maxMinor: Int = effectiveMaximumMinor) -> Selection {
        var sel = Selection()
        var supported: [(Probe, Int)] = [], noVenv: [(Probe, Int)] = []
        var newest: (String, Int)?
        for p in probes {
            guard let v = p.version, let m = p.minor else { sel.reasons.append("\(p.path): not a working Python 3"); continue }
            if m > maxMinor {
                sel.reasons.append("\(p.path) is \(v), newer than the supported 3.\(maxMinor)")
                if newest.map({ m > $0.1 }) ?? true { newest = (v, m) }
                continue
            }
            if m < minMinor { sel.reasons.append("\(p.path) is \(v), older than 3.\(minMinor)"); continue }
            if p.hasVenv { supported.append((p, m)) } else { sel.reasons.append("\(p.path): no usable venv/ensurepip"); noVenv.append((p, m)) }
        }
        func best(_ list: [(Probe, Int)]) -> Probe? {
            list.enumerated().max { a, b in a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset > b.offset }?.element.0
        }
        let sticky = recorded.flatMap { r in supported.first { $0.0.path == r.path && $0.0.version == r.version }?.0 }
        if let chosen = sticky ?? best(supported), let v = chosen.version, let m = chosen.minor {
            sel.base = Base(path: chosen.path, minor: m, version: v)
            return sel
        }
        if let nv = best(noVenv), let v = nv.version, let m = nv.minor { sel.missingVenv = Base(path: nv.path, minor: m, version: v) }
        sel.newestUnsupported = newest?.0
        return sel
    }

    static func probeArgs() -> [String] { ["-c", baseProbeScript] }
    static let probeEnv: () -> [String: String] = { ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()] }

    static func recordedBase() -> (path: String, version: String)? {
        guard let extra = ((try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.python))) ?? nil)?.verifiedRecord?.extra,
              let p = extra["base"], let v = extra["baseVersion"] else { return nil }
        return (p, v)
    }

    static func selectBase() async -> Selection {
        var probes: [Probe] = []
        for p in baseCandidates() {
            let r = await RuntimeProcess.run(p, probeArgs(), env: probeEnv(), timeout: 20)
            probes.append(parseProbe(path: p, status: r.status, stdout: r.stdout))
        }
        return choose(probes, recorded: recordedBase())
    }

    /// Same, without async (menu job planning).
    static func selectBaseBlocking() -> Selection {
        let probes = baseCandidates().map { p -> Probe in
            let r = RuntimeProcess.runBlocking(p, probeArgs(), env: probeEnv(), cwd: nil, timeout: 20)
            return parseProbe(path: p, status: r.status, stdout: r.stdout)
        }
        return choose(probes, recorded: recordedBase())
    }

    /// The newest supported user python with `venv` and `ensurepip`.
    static func findBase() async -> (Base?, [String]) {
        let s = await selectBase()
        return (s.base, s.reasons)
    }

    static func installHint() -> String {
        #if os(Linux)
        return "install Python 3.\(minimumMinor)–3.\(maximumMinor) with venv support (Debian/Ubuntu: `sudo apt install python3-venv`)"
        #else
        return "install Python 3.\(minimumMinor)–3.\(maximumMinor) (`brew install python@3.\(maximumMinor)`)"
        #endif
    }

    /// Why nothing usable was found, with the exact next step.
    static func unavailableMessage(_ s: Selection) -> String {
        let detail = s.reasons.isEmpty ? "" : " (\(s.reasons.joined(separator: "; ")))"
        if let mv = s.missingVenv, let pkg = venvPackage(for: mv) {
            return "Python \(mv.version) has no venv support: install it with `sudo apt install \(pkg)`, then retry" + detail
        }
        if let newer = s.newestUnsupported, s.missingVenv == nil {
            let short = newer.split(separator: ".").prefix(2).joined(separator: ".")
            #if os(Linux)
            let how = "install Python 3.\(maximumMinor) (or 3.\(minimumMinor)–3.\(maximumMinor)) with venv support next to it"
            #else
            let how = "install Python 3.\(maximumMinor) (`brew install python@3.\(maximumMinor)`); it can stay next to \(short)"
            #endif
            return "Python \(short) isn't supported yet — \(how)" + detail
        }
        return "no suitable python3: \(installHint())" + detail
    }

    // MARK: Missing venv (Debian/Ubuntu)

    /// `python3.X-venv` for a distribution (apt-owned) interpreter: only when
    /// apt-get exists and the interpreter resolves under /usr/bin. nil
    /// otherwise (other managers ship venv with python; a user-built or
    /// pyenv interpreter is not apt's to fix).
    /// The package the menu's terminal job must install before the detached
    /// `briglia python-env install` can build (nil = none needed/possible).
    static func venvPackageNeededBlocking() -> String? {
        let s = selectBaseBlocking()
        guard s.base == nil, let mv = s.missingVenv else { return nil }
        return venvPackage(for: mv)
    }

    static func venvPackage(for base: Base) -> String? {
        let systemPrefix = RuntimeSeams.env("BRIGLIA_PYTHON_TEST_SYSTEM_PREFIX") ?? "/usr/bin"
        guard aptAvailable() else { return nil }
        guard base.resolved.hasPrefix(systemPrefix + "/") else { return nil }
        return "python3.\(base.minor)-venv"
    }

    static func aptAvailable() -> Bool {
        if RuntimeSeams.env("BRIGLIA_PYTHON_TEST_VENV_INSTALLER") != nil { return true }
        #if os(Linux)
        return PlatformBinary.find("apt-get") != nil
        #else
        return false
        #endif
    }

    /// Interactive only: a terminal on stdin (sudo can ask for the password)
    /// plus sudo + apt-get. The daemon, the agent's Bash tool and detached
    /// menu jobs never get here; the menu plans the package as its own
    /// terminal job instead (QuickSetupWorkflow.defaultToolchainJobs).
    static func canInstallVenvInteractively() -> Bool {
        if RuntimeSeams.env("BRIGLIA_PYTHON_TEST_VENV_INSTALLER") != nil {
            return RuntimeSeams.env("BRIGLIA_PYTHON_TEST_INTERACTIVE") == "1"
        }
        #if os(Linux)
        return isatty(STDIN_FILENO) == 1 && PlatformBinary.find("sudo") != nil && PlatformBinary.find("apt-get") != nil
        #else
        return false
        #endif
    }

    /// `sudo apt-get install -y <pkg>` through the terminal hand-off (the same
    /// path as the wizard's other system packages). nil = installed.
    static func installVenvPackage(_ pkg: String) -> String? {
        if let fake = RuntimeSeams.env("BRIGLIA_PYTHON_TEST_VENV_INSTALLER") {
            let r = RuntimeProcess.runBlocking(fake, [pkg], env: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 60)
            return r.status == 0 ? nil : "the installer exited with status \(r.status)"
        }
        #if os(Linux)
        return ToolchainService.installLinuxPackageSync(pkg)
        #else
        return "not supported on this system"
        #endif
    }

    // MARK: Spec

    static func pin(base: Base) -> RuntimePin? {
        guard let sha = lockSHA256 else { return nil }
        return RuntimePin(triple: "\(NodeRuntime.platform)-py\(base.version)-\(base.identity)", version: String(sha.prefix(12)), archiveSHA256: sha)
    }

    static func spec(base: Base, pin: RuntimePin) -> RuntimeSpec {
        RuntimeSpec(
            component: .python, pin: pin, binaryRelPath: "env/pyvenv.cfg", usesHold: false,
            directoryName: { p in "\(p.version)-py3.\(base.minor)" },
            stage: { payload, progress in try await build(base: base, payload: payload, progress: progress) },
            postProbe: { j in
                if let why = await probe(python: RuntimePaths.current(.python).appendingPathComponent("env/bin/python").path) { return why }
                return verifyTree(j.newRecord, RuntimePaths.dir(.python).appendingPathComponent(j.newTarget, isDirectory: true))
            },
            validateExtra: { record, dir in validateExtra(record, dir) },
            stagesInPlace: true)
    }

    /// Use/status check (cheap, no process): the recorded base interpreter
    /// still resolves to the same file, and so does the venv's interpreter
    /// chain (review R4). A changed version under the same path is caught at
    /// startup by the pin identity.
    static func validateExtra(_ record: RuntimeRecord, _ dir: URL) -> String? {
        let py = dir.appendingPathComponent("env/bin/python")
        let link = RuntimeFS.readLink(py)
        if let want = record.extra?["pythonLink"], link != want { return "env/bin/python changed" }
        guard let base = record.extra?["base"], FileManager.default.isExecutableFile(atPath: base) else {
            return "its base interpreter \(record.extra?["base"] ?? "?") is gone"
        }
        guard let resolved = record.extra?["baseResolved"], let interp = record.extra?["interpreterResolved"] else {
            return "the record lacks the base interpreter identity (built by an older Briglia)"
        }
        if URL(fileURLWithPath: base).resolvingSymlinksInPath().path != resolved { return "its base interpreter \(base) now points elsewhere" }
        if py.resolvingSymlinksInPath().path != interp { return "the environment's interpreter now points elsewhere" }
        guard FileManager.default.isExecutableFile(atPath: interp) else { return "the environment's interpreter \(interp) is gone" }
        guard let bid = record.extra?["baseIdentity"], let iid = record.extra?["interpreterIdentity"] else {
            return "the record lacks the base interpreter identity (built by an older Briglia)"
        }
        if fileIdentity(resolved) != bid { return "its base interpreter \(base) was replaced or updated in place" }
        if fileIdentity(interp) != iid { return "the environment's interpreter was replaced or updated in place" }
        return nil
    }

    /// device, inode, size and modification time (ns) of a regular file.
    static func fileIdentity(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        #if os(Linux)
        let m = st.st_mtim
        #else
        let m = st.st_mtimespec
        #endif
        return "\(st.st_dev):\(st.st_ino):\(st.st_size):\(m.tv_sec).\(m.tv_nsec)"
    }

    static func build(base: Base, payload: URL, progress: (@Sendable (String) -> Void)?) async throws -> [String: String]? {
        guard let lock = lockURL else { throw RuntimeError("the Python lock is missing from the resource bundle") }
        try RuntimeFS.ensureDir(payload)
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
        let interp = env.appendingPathComponent("bin/python").resolvingSymlinksInPath().path
        var extra: [String: String] = ["base": base.path, "baseVersion": base.version, "baseResolved": base.resolved,
                                       "interpreterResolved": interp]
        // File identity of the resolved base (and venv interpreter): a
        // same-path replacement or rewrite — e.g. a new version installed in
        // place — changes it, so use/status refuse until rebuilt (round 2).
        guard let bid = fileIdentity(base.resolved), let iid = fileIdentity(interp) else {
            throw RuntimeError("could not identify the base interpreter")
        }
        extra["baseIdentity"] = bid
        extra["interpreterIdentity"] = iid
        if let link = RuntimeFS.readLink(env.appendingPathComponent("bin/python")) { extra["pythonLink"] = link }
        guard let tree = treeSHA256(env) else { throw RuntimeError("could not hash the built environment") }
        extra["treeSHA256"] = tree
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
        "#!/bin/sh\n# Installed by Briglia CLI: Briglia's private Python environment (never the shared python3).\nexec \(RuntimeFS.shellQuote(brigliaPath))\(RuntimeFS.profileWords()) __python-exec \"$@\"\n"
    }

    static func ensureWrapper() throws {
        let bytes = Data(wrapperScript(brigliaPath: AgentMailService.brigliaPath()).utf8)
        if (try? Data(contentsOf: wrapperURL)) == bytes, FileManager.default.isExecutableFile(atPath: wrapperURL.path) { return }
        try RuntimeFS.ensureDir(RuntimePaths.binDir)
        switch RuntimeFS.kind(wrapperURL.path) {
        case .absent, .regular: break
        default: throw RuntimeError("\(wrapperURL.path) exists and is not a regular file — refusing")
        }
        try RuntimeFS.write(bytes, to: wrapperURL, mode: 0o700)
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
        guard (try? RuntimeFS.contain(dir.appendingPathComponent("env/pyvenv.cfg"))) != nil,
              (try? RuntimeFS.contain(dir.appendingPathComponent("env/bin/python"), finalMayBeSymlink: true)) != nil,
              RuntimeFS.sha256(file: dir.appendingPathComponent("env/pyvenv.cfg")) == v.binarySHA256,
              validateExtra(v, dir) == nil else {
            return .refuse("Briglia's Python environment does not match its receipt — Briglia rebuilds it at the next start (or run `briglia python-env install`)")
        }
        return .run(dir.appendingPathComponent("env/bin/python").path)
    }

    // MARK: File-tree hash (§7.9.4: post-commit probe and doctor)

    /// SHA-256 over the sorted (relative path, type, content-or-link-target)
    /// of every entry under `env`, skipping `__pycache__` (Python writes byte
    /// code there on first import). nil if any entry cannot be read.
    static func treeSHA256(_ env: URL) -> String? {
        guard let e = FileManager.default.enumerator(atPath: env.path) else { return nil }
        var rows: [String] = []
        for case let rel as String in e {
            if rel.split(separator: "/").contains("__pycache__") { continue }
            let path = env.path + "/" + rel
            switch RuntimeFS.kind(path) {
            case .directory: rows.append("d \(rel)")
            case .symlink:
                guard let t = RuntimeFS.readLink(URL(fileURLWithPath: path)) else { return nil }
                rows.append("l \(rel) \(t)")
            case .regular:
                guard let h = RuntimeFS.sha256(file: URL(fileURLWithPath: path)) else { return nil }
                rows.append("f \(rel) \(h)")
            default: rows.append("o \(rel)")
            }
        }
        return RuntimeFS.sha256(Data(rows.sorted().joined(separator: "\n").utf8))
    }

    /// nil when the recorded tree hash matches (or the record predates it is refused).
    static func verifyTree(_ record: RuntimeRecord, _ dir: URL) -> String? {
        guard let want = record.extra?["treeSHA256"] else { return "the record lacks a file-tree hash" }
        guard let have = treeSHA256(dir.appendingPathComponent("env", isDirectory: true)) else { return "the environment's files could not be read" }
        return have == want ? nil : "the environment's files differ from what was built"
    }

    /// Doctor: the full tree check of the verified environment.
    static func doctorTreeLine() -> (ok: Bool, text: String)? {
        guard let v = ((try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.python))) ?? nil)?.verifiedRecord else { return nil }
        if let why = verifyTree(v, RuntimePaths.dir(.python).appendingPathComponent(v.directory, isDirectory: true)) {
            return (false, "Briglia's Python environment: \(why) — run `briglia python-env install`")
        }
        return (true, "Briglia's Python environment files match what was built")
    }

    // MARK: Live consumers (plan §7.7, review R3)

    /// One lease per running `briglia-python` process, written under the
    /// component lock just before exec (exec keeps the PID and its start
    /// time). GC keeps every directory a live lease names.
    static var leaseDir: URL { RuntimePaths.dir(.python).appendingPathComponent("leases", isDirectory: true) }

    struct Lease: Codable { var pid: Int32; var startTime: UInt64; var directory: String }

    /// Decide and lease atomically w.r.t. GC (which holds the component lock).
    static func execDecisionLeased() -> ExecDecision {
        guard let lock = try? RuntimeLock.acquire(RuntimePaths.componentLock(.python), timeout: 30) else {
            return .refuse("Briglia's Python environment is busy (being updated) — try again in a moment")
        }
        defer { lock.release() }
        let d = execDecision()
        guard case .run = d, let v = ((try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.python))) ?? nil)?.verifiedRecord,
              let start = RuntimeProcessIdentity.startTime(pid: getpid()) else { return d }
        do {
            let lease = Lease(pid: getpid(), startTime: start, directory: v.directory)
            try RuntimeFS.write(try JSONEncoder().encode(lease), to: leaseDir.appendingPathComponent("\(getpid())-\(start).json"), mode: 0o600)
        } catch {
            return .refuse("could not record Briglia's Python use (\(error)) — try again")
        }
        return d
    }

    /// Directories named by leases whose process is still the same process;
    /// stale leases are removed (caller holds the component lock).
    static func liveLeaseDirectories() -> Set<String> {
        var keep = Set<String>()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: leaseDir.path)) ?? [] where name.hasSuffix(".json") {
            let url = leaseDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let l = try? JSONDecoder().decode(Lease.self, from: data) else {
                try? RuntimeFS.remove(url); continue
            }
            if kill(l.pid, 0) == 0 || errno == EPERM, RuntimeProcessIdentity.startTime(pid: l.pid) == l.startTime {
                keep.insert(l.directory)
            } else {
                try? RuntimeFS.remove(url)
            }
        }
        return keep
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
        var selection = await selectBase()
        // Debian/Ubuntu: the only supported python lacks python3.X-venv. An
        // explicit install run from a terminal installs exactly that package
        // (sudo apt, like the wizard's other system packages) and looks
        // again — once; never at startup, never without a terminal.
        if selection.base == nil, trigger == .install, let missing = selection.missingVenv,
           let pkg = venvPackage(for: missing), canInstallVenvInteractively() {
            (progress ?? { print("  \($0)") })("Python \(missing.version) needs \(pkg) for Briglia's environment: installing it with sudo apt-get (it may ask for your password)…")
            if let failure = installVenvPackage(pkg) {
                return .unavailable("could not install \(pkg) (\(failure)): run `sudo apt install \(pkg)`, then retry")
            }
            selection = await selectBase()
        }
        guard let base = selection.base else { return .unavailable(unavailableMessage(selection)) }
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
        let previous = ((try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.python))) ?? nil)?.verified
        let outcome = await PrivateRuntimeEngine.converge(spec, trigger: trigger, progress: progress)
        switch outcome {
        case .upToDate(let r), .converged(let r):
            try? ensureWrapper()
            // GC only at startup, never right after a switch: the tree that was
            // just replaced stays until a later start, and any tree a running
            // briglia-python leases stays while that process lives (§7.7).
            if trigger == .auto {
                var keep = Set<String>()
                if case .converged = outcome, let previous { keep.insert(previous) }
                _ = PrivateRuntimeEngine.collectGarbage(spec, keepRunning: keep, extraKeep: { liveLeaseDirectories() })
            }
            return .ready(r.extra?["baseVersion"] ?? base.version)
        case .failed(let w), .abandoned(let w), .throttled(let w), .busy(let w), .notApplicable(let w):
            try? ensureWrapper()
            return .failed(w)
        case .held:
            return .failed("held")
        }
    }
}
