import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Base-interpreter selection (2026-10-29): never newer than the lock covers
/// (3.14; Homebrew python3 = 3.15 made pip refuse numpy 2.5.4), newest
/// supported first across every directory, the current base kept while it is
/// still offered unchanged, and the Debian/Ubuntu python3.X-venv package
/// installed by an explicit install run from a terminal.
extension RuntimeHarness {
    /// A fake interpreter: answers the base probe with `version` (venv
    /// present unless `venvMarker` is given and missing); anything else is
    /// exec'd by `real` (or fails when nil).
    func fakePython(_ url: URL, version: String, venvMarker: URL? = nil, real: String?) throws {
        let venv = venvMarker.map { "[ -e '\($0.path)' ] || exit 3; " } ?? ""
        let rest = real.map { "exec '\($0)' \"$@\"" } ?? "exit 1"
        try "#!/bin/sh\ncase \"$*\" in *briglia-base-probe*) echo \(version); \(venv)echo venv; exit 0;; esac\n\(rest)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    func freshDir(_ name: String) throws -> URL {
        let d = scratch.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Pure choice + probe parsing (no interpreter needed).
    func pythonBaseChoice() {
        typealias P = PythonRuntime.Probe
        let R = PythonRuntime.self
        check("the supported ceiling is 3.14 (the lock's newest wheels; tied by python_lock.py --check)", R.maximumMinor == 14)
        let a = R.choose([P(path: "/a/python3", version: "3.15.1", hasVenv: true), P(path: "/a/python3.14", version: "3.14.2", hasVenv: true)], minMinor: 11, maxMinor: 14)
        check("python3 = 3.15 + python3.14 → 3.14 (old: the first ≥ 3.11 → 3.15)", a.base?.path == "/a/python3.14" && a.base?.minor == 14, "\(String(describing: a.base))")
        let b = R.choose([P(path: "/a/python3", version: "3.12.3", hasVenv: true), P(path: "/b/python3.13", version: "3.13.9", hasVenv: true),
                          P(path: "/c/python3.11", version: "3.11.2", hasVenv: true)], minMinor: 11, maxMinor: 14)
        check("newest supported wins across directories (3.13 in a later directory beats python3 = 3.12)", b.base?.path == "/b/python3.13", "\(String(describing: b.base))")
        let tie = R.choose([P(path: "/a/python3.13", version: "3.13.1", hasVenv: true), P(path: "/b/python3.13", version: "3.13.9", hasVenv: true)], minMinor: 11, maxMinor: 14)
        check("same minor twice → PATH order", tie.base?.path == "/a/python3.13")
        let sticky = R.choose([P(path: "/a/python3", version: "3.12.3", hasVenv: true), P(path: "/b/python3.14", version: "3.14.0", hasVenv: true)],
                              recorded: ("/a/python3", "3.12.3"), minMinor: 11, maxMinor: 14)
        check("the base the environment was built on stays while offered unchanged (no surprise rebuild)", sticky.base?.path == "/a/python3")
        let moved = R.choose([P(path: "/a/python3", version: "3.12.4", hasVenv: true), P(path: "/b/python3.14", version: "3.14.0", hasVenv: true)],
                             recorded: ("/a/python3", "3.12.3"), minMinor: 11, maxMinor: 14)
        check("…but a changed version there → newest supported", moved.base?.path == "/b/python3.14")
        let upgraded = R.choose([P(path: "/a/python3", version: "3.15.0", hasVenv: true), P(path: "/b/python3.14", version: "3.14.0", hasVenv: true)],
                                recorded: ("/a/python3", "3.15.0"), minMinor: 11, maxMinor: 14)
        check("…and a recorded base that is now too new is never kept", upgraded.base?.path == "/b/python3.14")
        let onlyNew = R.choose([P(path: "/a/python3", version: "3.15.1", hasVenv: true), P(path: "/a/python3.16", version: "3.16.0", hasVenv: true)], minMinor: 11, maxMinor: 14)
        check("only newer pythons → no base, the newest unsupported is named", onlyNew.base == nil && onlyNew.newestUnsupported == "3.16.0" && onlyNew.missingVenv == nil)
        let msg = R.unavailableMessage(R.choose([P(path: "/a/python3", version: "3.15.1", hasVenv: true)], minMinor: 11, maxMinor: 14))
        #if os(Linux)
        check("…message: 'Python 3.15 isn't supported yet — install Python 3.14…'", msg.hasPrefix("Python 3.15 isn't supported yet — install Python 3.14"), msg)
        #else
        check("…message: 'Python 3.15 isn't supported yet — install Python 3.14 (brew install python@3.14)…'",
              msg.hasPrefix("Python 3.15 isn't supported yet — install Python 3.14") && msg.contains("brew install python@3.14"), msg)
        #endif
        let mixedVenv = R.choose([P(path: "/usr/bin/python3", version: "3.13.1", hasVenv: false), P(path: "/x/python3.12", version: "3.12.1", hasVenv: true)], minMinor: 11, maxMinor: 14)
        check("a usable older python beats a newer one without venv (no sudo needed)", mixedVenv.base?.path == "/x/python3.12" && mixedVenv.missingVenv == nil)
        let noVenv = R.choose([P(path: "/usr/bin/python3", version: "3.12.3", hasVenv: false), P(path: "/usr/bin/python3.15", version: "3.15.0", hasVenv: true)], minMinor: 11, maxMinor: 14)
        check("only a supported python without venv → reported as missing venv (newer one still skipped)",
              noVenv.base == nil && noVenv.missingVenv?.path == "/usr/bin/python3" && noVenv.missingVenv?.minor == 12)
        let old = R.choose([P(path: "/a/python3", version: "3.10.4", hasVenv: true), P(path: "/a/junk", version: nil, hasVenv: false)], minMinor: 11, maxMinor: 14)
        check("older-only / not python → no base, plain install hint", old.base == nil && R.unavailableMessage(old).hasPrefix("no suitable python3: install Python 3.11–3.14"), R.unavailableMessage(old))
        check("probe parse: version + venv", R.parseProbe(path: "p", status: 0, stdout: "3.14.2\nvenv\n") == P(path: "p", version: "3.14.2", hasVenv: true))
        check("probe parse: version, exit 3 → no venv", R.parseProbe(path: "p", status: 3, stdout: "3.12.3\n") == P(path: "p", version: "3.12.3", hasVenv: false))
        check("probe parse: garbage / python 2 / other failure → not usable",
              R.parseProbe(path: "p", status: 0, stdout: "hello").version == nil && R.parseProbe(path: "p", status: 0, stdout: "2.7.18\nvenv").version == nil
              && R.parseProbe(path: "p", status: 1, stdout: "3.12.1").version == nil)
    }

    /// Behaviour through findBase/converge with fake and real interpreters.
    /// Called from pythonEnv() with its lock, wheels and probe settings live.
    func pythonBaseSelection(found: PythonRuntime.Base) async throws {
        let savedMax = ProcessInfo.processInfo.environment["BRIGLIA_PYTHON_MAX_MINOR"]
        defer { if let savedMax { setenv("BRIGLIA_PYTHON_MAX_MINOR", savedMax, 1) } else { unsetenv("BRIGLIA_PYTHON_MAX_MINOR") } }
        // Fakes only (fixed names python3 / python3.14 / python3.13).
        let d1 = try freshDir("pysel")
        try fakePython(d1.appendingPathComponent("python3"), version: "3.15.1", real: nil)
        try fakePython(d1.appendingPathComponent("python3.14"), version: "3.14.2", real: nil)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", d1.path, 1)
        unsetenv("BRIGLIA_PYTHON_MAX_MINOR")
        let (b1, _) = await PythonRuntime.findBase()
        check("findBase: python3 → 3.15 is skipped, python3.14 next to it is used", b1?.path == d1.appendingPathComponent("python3.14").path && b1?.version == "3.14.2", "\(String(describing: b1))")
        let d2a = try freshDir("pysel-a"), d2b = try freshDir("pysel-b")
        try fakePython(d2a.appendingPathComponent("python3"), version: "3.12.3", real: nil)
        try fakePython(d2b.appendingPathComponent("python3.13"), version: "3.13.9", real: nil)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", d2a.path + ":" + d2b.path, 1)
        let (b2, _) = await PythonRuntime.findBase()
        check("findBase: newest supported first across PATH directories", b2?.path == d2b.appendingPathComponent("python3.13").path, "\(String(describing: b2))")
        let d3 = try freshDir("pysel-new")
        try fakePython(d3.appendingPathComponent("python3"), version: "3.15.1", real: nil)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", d3.path, 1)
        let before = receipt(.python)?.verified
        let s3 = await PythonRuntime.converge(trigger: .install)
        check("only python3 = 3.15 → unavailable 'Python 3.15 isn't supported yet — install Python 3.14', nothing built",
              { if case .unavailable(let w) = s3 { return w.hasPrefix("Python 3.15 isn't supported yet — install Python 3.14") }; return false }()
              && receipt(.python)?.verified == before, "\(s3)")

        // An environment built on a base that later became too new.
        guard found.minor <= 14 else { check("real-base rows need a base python ≤ 3.14 (skipped)", true); return }
        setenv("BRIGLIA_PYTHON_MAX_MINOR", "\(found.minor)", 1)   // works on every runner (3.10 jammy … 3.14)
        let dA = try freshDir("pyup-a"), dB = try freshDir("pyup-b")
        let linkA = dA.appendingPathComponent("python3")
        try fm.createSymbolicLink(atPath: linkA.path, withDestinationPath: found.path)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", dA.path, 1)
        resetRuntime()
        let u0 = await PythonRuntime.converge(trigger: .install)
        check("upgrade case: environment built on A/python3", { if case .ready = u0 { return true }; return false }()
              && receipt(.python)?.verifiedRecord?.extra?["base"] == linkA.path, "\(u0)")
        // A/python3 now resolves to a newer, unsupported python (like a brew
        // upgrade); the supported one is still installed in B.
        let newer = "3.\(found.minor + 1).0"
        try fm.removeItem(at: linkA)
        try fakePython(linkA, version: newer, real: found.path)
        try fm.createSymbolicLink(atPath: dB.appendingPathComponent("python3").path, withDestinationPath: found.path)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", dA.path + ":" + dB.path, 1)
        let built = receipt(.python)?.verified
        let u1 = await PythonRuntime.converge(trigger: .auto)
        let rec = receipt(.python)?.verifiedRecord?.extra
        check("…next start rebuilds on the supported B/python3, never on the newer A/python3 (old: rebuilt on \(newer))",
              { if case .ready = u1 { return true }; return false }() && rec?["base"] == dB.appendingPathComponent("python3").path
              && rec?["baseVersion"] == found.version && receipt(.python)?.verified != built, "\(u1) \(String(describing: rec))")
        let afterRebuild = receipt(.python)?.verified
        let u2 = await PythonRuntime.converge(trigger: .auto)
        check("…the start after that is up to date (no rebuild loop)", { if case .ready = u2 { return true }; return false }() && receipt(.python)?.verified == afterRebuild, "\(u2)")
        check("…briglia-python runs it", { if case .run = PythonRuntime.execDecision() { return true }; return false }())
        try fm.removeItem(at: dB.appendingPathComponent("python3"))
        let u3 = await PythonRuntime.converge(trigger: .auto)
        let u4 = await PythonRuntime.converge(trigger: .auto)
        check("…if only the newer one is left: unavailable with the next step, twice the same (no crash, no loop), receipt untouched",
              { if case .unavailable(let w) = u3 { return w.contains("isn't supported yet") }; return false }() && u3 == u4
              && receipt(.python)?.verified == afterRebuild, "\(u3)")
    }

    /// Debian/Ubuntu: the supported python lacks python3.X-venv.
    func pythonMissingVenv(found: PythonRuntime.Base) async throws {
        guard found.minor <= 14 else { check("missing-venv rows need a base python ≤ 3.14 (skipped)", true); return }
        let keys = ["BRIGLIA_PYTHON_TEST_SYSTEM_PREFIX", "BRIGLIA_PYTHON_TEST_VENV_INSTALLER", "BRIGLIA_PYTHON_TEST_INTERACTIVE", "BRIGLIA_PYTHON_MAX_MINOR"]
        defer { for k in keys { unsetenv(k) } }
        setenv("BRIGLIA_PYTHON_MAX_MINOR", "\(found.minor)", 1)
        let sys = try freshDir("pysys")
        let marker = scratch.appendingPathComponent("venv-installed-\(UUID().uuidString.prefix(6))")
        let py = sys.appendingPathComponent("python3")
        try fakePython(py, version: found.version, venvMarker: marker, real: found.path)
        let log = scratch.appendingPathComponent("apt-log-\(UUID().uuidString.prefix(6))")
        let installer = scratch.appendingPathComponent("fake-apt-\(UUID().uuidString.prefix(6))")
        func writeInstaller(ok: Bool) throws {
            try "#!/bin/sh\necho \"$*\" >> '\(log.path)'\n\(ok ? "touch '\(marker.path)'; exit 0" : "exit 100")\n".write(to: installer, atomically: true, encoding: .utf8)
            chmod(installer.path, 0o755)
        }
        func logged() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        let pkg = "python3.\(found.minor)-venv"
        try writeInstaller(ok: true)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", sys.path, 1)
        setenv("BRIGLIA_PYTHON_TEST_SYSTEM_PREFIX", sys.resolvingSymlinksInPath().path, 1)
        setenv("BRIGLIA_PYTHON_TEST_VENV_INSTALLER", installer.path, 1)
        resetRuntime()

        unsetenv("BRIGLIA_PYTHON_TEST_INTERACTIVE")
        let n1 = await PythonRuntime.converge(trigger: .install)
        check("no terminal → nothing installed; the message names the exact package (`sudo apt install \(pkg)`)",
              { if case .unavailable(let w) = n1 { return w.contains("sudo apt install \(pkg)") }; return false }() && logged().isEmpty, "\(n1)")

        setenv("BRIGLIA_PYTHON_TEST_INTERACTIVE", "1", 1)
        let a1 = await PythonRuntime.converge(trigger: .auto)
        check("startup never installs system packages (even with a terminal)", logged().isEmpty && { if case .ready = a1 { return false }; return true }(), "\(a1)")

        try writeInstaller(ok: false)
        let f1 = await PythonRuntime.converge(trigger: .install)
        check("install from a terminal, apt fails → one attempt, clear message, nothing built",
              { if case .unavailable(let w) = f1 { return w.contains("could not install \(pkg)") }; return false }() && logged() == [pkg]
              && receipt(.python)?.verified == nil, "\(f1) \(logged())")

        try writeInstaller(ok: true)
        let ok1 = await PythonRuntime.converge(trigger: .install)
        check("install from a terminal → installs exactly \(pkg) (old: stopped with a hint), then builds on it",
              { if case .ready = ok1 { return true }; return false }() && logged() == [pkg, pkg]
              && receipt(.python)?.verifiedRecord?.extra?["base"] == py.path, "\(ok1) \(logged())")
        let ok2 = await PythonRuntime.converge(trigger: .install)
        check("…a second install with venv present asks apt for nothing", { if case .ready = ok2 { return true }; return false }() && logged().count == 2, "\(logged())")

        // Not apt's interpreter (outside the system prefix) → never installs.
        try? fm.removeItem(at: marker)
        resetRuntime()
        setenv("BRIGLIA_PYTHON_TEST_SYSTEM_PREFIX", "/nonexistent-system-prefix", 1)
        let other = await PythonRuntime.converge(trigger: .install)
        check("a python outside /usr/bin (pyenv, own build) → no apt install, plain hint",
              { if case .unavailable(let w) = other { return w.hasPrefix("no suitable python3") }; return false }() && logged().count == 2, "\(other)")
        let b = PythonRuntime.Base(path: py.path, minor: found.minor, version: found.version)
        check("venvPackage: outside the system prefix → none", PythonRuntime.venvPackage(for: b) == nil)
        setenv("BRIGLIA_PYTHON_TEST_SYSTEM_PREFIX", sys.resolvingSymlinksInPath().path, 1)
        check("venvPackage: an interpreter under the system prefix → \(pkg)", PythonRuntime.venvPackage(for: b) == pkg)
    }
}
