#if os(macOS)
import Foundation
import Darwin

/// macOS (owner, 2026-11-10): when no usable Python 3.11–3.<max> exists
/// anywhere Briglia scans, an install the user started installs Homebrew's
/// python@3.<max> once per process; never at startup, without a terminal or
/// from the agent's shell. Fake interpreters and a fake brew only: the real
/// Homebrew is never run (Codex plan review r1, finding 3).
extension RuntimeHarness {
    static let homebrewKeys = ["BRIGLIA_PYTHON_TEST_BASE_DIRS", "BRIGLIA_PYTHON_TEST_BREW_INSTALLER", "BRIGLIA_PYTHON_TEST_INTERACTIVE",
                               "BRIGLIA_PYTHON_TEST_NO_HOMEBREW", "BRIGLIA_PYTHON_TEST_BREW_PREFIX", "BRIGLIA_PYTHON_MIN_MINOR",
                               "BRIGLIA_PYTHON_MAX_MINOR", "BRIGLIA_PATH_FRONT", "BRIGLIA_PYTHON_TEST_REAL_BREW"]

    /// A fake brew: logs its arguments and the four Homebrew variables, then
    /// `ok` copies `staged` to `linked` (installs and links python3.X), `fail`
    /// exits 1, `nothing` exits 0 having done nothing.
    func writeFakeBrew(_ url: URL, log: URL, mode: String, staged: URL? = nil, linked: URL? = nil) throws {
        let act: String
        switch mode {
        case "ok": act = "cp '\(staged!.path)' '\(linked!.path)' && chmod 755 '\(linked!.path)'; exit 0"
        case "fail": act = "echo 'Error: no bottle available' >&2; exit 1"
        default: act = "exit 0"
        }
        let line = "$* AUTO_UPDATE=${HOMEBREW_NO_AUTO_UPDATE:-} INSTALL_UPGRADE=${HOMEBREW_NO_INSTALL_UPGRADE:-}"
            + " DEPENDENTS=${HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK:-} CLEANUP=${HOMEBREW_NO_INSTALL_CLEANUP:-}"
        try "#!/bin/sh\necho \"\(line)\" >> '\(log.path)'\n\(act)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }

    func brewLog(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    static func brewLine(_ formula: String) -> String {
        "install \(formula) AUTO_UPDATE=1 INSTALL_UPGRADE=1 DEPENDENTS=1 CLEANUP=1"
    }

    func unavailable(_ s: PythonRuntime.Status) -> String? { if case .unavailable(let w) = s { return w }; return nil }
    func ready(_ s: PythonRuntime.Status) -> Bool { if case .ready = s { return true }; return false }

    /// `body` with stdin on /dev/null: a process with no terminal.
    func withoutTerminal<T>(_ body: () async -> T) async -> T {
        let saved = dup(STDIN_FILENO)
        let null = open("/dev/null", O_RDONLY)
        dup2(null, STDIN_FILENO)
        close(null)
        defer { dup2(saved, STDIN_FILENO); close(saved) }
        return await body()
    }

    func saveHomebrewEnv() -> [(String, String?)] {
        let env = ProcessInfo.processInfo.environment
        return Self.homebrewKeys.map { ($0, env[$0]) }
    }

    /// Stands in for the real Homebrew in these sections: if any code path
    /// ever "reaches the real brew", this stub logs it and nothing happens.
    func realBrewStub() throws -> URL {
        let log = scratch.appendingPathComponent("hb-real-brew-\(UUID().uuidString.prefix(6))")
        let stub = scratch.appendingPathComponent("hb-real-brew-stub-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\necho \"REAL BREW REACHED: $*\" >> '\(log.path)'\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)
        setenv("BRIGLIA_PYTHON_TEST_REAL_BREW", stub.path, 1)
        return log
    }

    func restoreHomebrewEnv(_ saved: [(String, String?)]) {
        for (k, v) in saved { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        PythonRuntime.resetHomebrewAttemptForTesting()
    }

    /// Eligibility, refusals, messages and planning: no real Python needed,
    /// production range 3.11–3.<max>.
    func pythonHomebrewGuards() async throws {
        let R = PythonRuntime.self
        let T = ToolchainService.self
        let saved = saveHomebrewEnv()
        defer { restoreHomebrewEnv(saved) }
        for k in Self.homebrewKeys { unsetenv(k) }
        let realBrew = try realBrewStub()
        R.resetHomebrewAttemptForTesting()
        resetRuntime()

        check("brew: the formula is python@3.<maximumMinor> (python@3.\(R.maximumMinor) today)",
              R.homebrewPythonFormula == "python@3.\(R.maximumMinor)", R.homebrewPythonFormula)
        setenv("BRIGLIA_PYTHON_MAX_MINOR", "13", 1)
        check("brew: …and moves with it, never a literal (maximum 3.13 → python@3.13)", R.homebrewPythonFormula == "python@3.13", R.homebrewPythonFormula)
        unsetenv("BRIGLIA_PYTHON_MAX_MINOR")
        let formula = R.homebrewPythonFormula
        let maxMinor = R.maximumMinor

        // Apple's python3 3.9.6 only.
        let apple = try freshDir("hb-apple")
        try fakePython(apple.appendingPathComponent("python3"), version: "3.9.6", real: nil)
        let brewBin = try freshDir("hb-brewbin")
        let staged = scratch.appendingPathComponent("hb-staged-\(UUID().uuidString.prefix(6))")
        try fakePython(staged, version: "3.\(maxMinor).2", real: nil)
        let log = scratch.appendingPathComponent("hb-log-\(UUID().uuidString.prefix(6))")
        let brew = scratch.appendingPathComponent("hb-brew-\(UUID().uuidString.prefix(6))")
        try writeFakeBrew(brew, log: log, mode: "fail")
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", apple.path + ":" + brewBin.path, 1)

        // Safety: without the fake brew, nothing can reach the real Homebrew.
        setenv("BRIGLIA_PYTHON_TEST_INTERACTIVE", "1", 1)
        check("brew: selftest without the fake brew → never eligible, even with a simulated terminal", !R.canInstallPythonInteractively())
        let refused = await R.installHomebrewPython(formula)
        check("brew: …and the installer itself refuses to run the real brew", refused == "selftest without a fake Homebrew: nothing run" && brewLog(realBrew).isEmpty, refused ?? "nil")
        let s0 = await R.converge(trigger: .install)
        check("brew: …so an install only explains, and no attempt is used up",
              unavailable(s0)?.contains("`brew install \(formula)`") == true && R.homebrewAttemptFailure == nil && R.claimHomebrewAttempt(), "\(s0)")
        R.resetHomebrewAttemptForTesting()

        setenv("BRIGLIA_PYTHON_TEST_BREW_INSTALLER", brew.path, 1)
        check("brew: Apple's 3.9 only → the tools install plans \(formula)", R.homebrewPythonFormulaNeededBlocking() == formula)

        unsetenv("BRIGLIA_PYTHON_TEST_INTERACTIVE")
        let n1 = await withoutTerminal { await R.converge(trigger: .install) }
        check("brew: no terminal (stdin /dev/null) → nothing installed; `brew install \(formula)`, then `briglia python-env install`",
              brewLog(log).isEmpty && unavailable(n1).map {
                  $0.hasPrefix("no suitable python3: install Python 3.11–3.\(maxMinor) (`brew install \(formula)`), then run `briglia python-env install`")
              } == true, "\(n1)")

        setenv("BRIGLIA_PYTHON_TEST_INTERACTIVE", "1", 1)
        let a1 = await R.converge(trigger: .auto)
        check("brew: startup (.auto) never installs, even with a terminal", brewLog(log).isEmpty && unavailable(a1) != nil, "\(a1)")

        setenv("BRIGLIA_PATH_FRONT", "", 1)
        let g1 = await R.converge(trigger: .install)
        check("brew: the agent's shell (BRIGLIA_PATH_FRONT present, even empty) never installs; it gets the command",
              brewLog(log).isEmpty && unavailable(g1)?.contains("`brew install \(formula)`") == true && R.homebrewAttemptFailure == nil, "\(g1)")
        unsetenv("BRIGLIA_PATH_FRONT")

        let f1 = await R.converge(trigger: .install)
        check("brew: from a terminal, brew fails → one `brew install \(formula)` (no update, upgrade, dependents or cleanup), a clear message, nothing built",
              brewLog(log) == [Self.brewLine(formula)] && unavailable(f1)?.hasPrefix("could not install \(formula) with Homebrew (exit 1") == true
              && unavailable(f1)?.contains("run `brew install \(formula)`, then `briglia python-env install`") == true
              && receipt(.python)?.verified == nil, "\(f1) \(brewLog(log))")
        try writeFakeBrew(brew, log: log, mode: "ok", staged: staged, linked: brewBin.appendingPathComponent("python3.\(maxMinor)"))
        let f2 = await R.converge(trigger: .install)
        check("brew: …the same process never tries again and repeats why (the wizard calls converge per package)",
              brewLog(log).count == 1 && f2 == f1, "\(f2)")

        R.resetHomebrewAttemptForTesting()
        try writeFakeBrew(brew, log: log, mode: "nothing")
        let u1 = await R.converge(trigger: .install)
        let u2 = await R.converge(trigger: .install)
        check("brew: installed but still nothing usable → the precise reason (3.9.6 too old), one attempt only",
              unavailable(u1)?.hasPrefix("Homebrew installed \(formula), but still no usable Python 3.11–3.\(maxMinor)") == true
              && unavailable(u1)?.contains("is 3.9.6, older than 3.11") == true && brewLog(log).count == 2 && u2 == u1, "\(u1) \(brewLog(log))")

        let newer = try freshDir("hb-newer")
        try fakePython(newer.appendingPathComponent("python3"), version: "3.\(maxMinor + 1).1", real: nil)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", newer.path, 1)
        check("brew: only a newer Python (3.\(maxMinor + 1)) → the tools install plans \(formula)", R.homebrewPythonFormulaNeededBlocking() == formula)
        let usable = try freshDir("hb-usable")
        try fakePython(usable.appendingPathComponent("python3.\(maxMinor)"), version: "3.\(maxMinor).2", real: nil)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", apple.path + ":" + usable.path, 1)
        check("brew: a usable Python next to Apple's 3.9 → nothing planned", R.homebrewPythonFormulaNeededBlocking() == nil)

        // No Homebrew → no install; python.org or brew.sh.
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", apple.path, 1)
        R.resetHomebrewAttemptForTesting()
        setenv("BRIGLIA_PYTHON_TEST_NO_HOMEBREW", "1", 1)
        let h1 = await R.converge(trigger: .install)
        check("brew: no Homebrew → nothing installed; python.org (or brew.sh), then `briglia python-env install`",
              brewLog(log).count == 2 && unavailable(h1).map {
                  $0.hasPrefix("no suitable python3: install Python 3.11–3.\(maxMinor) — Homebrew isn't installed: get Python 3.\(maxMinor) from https://www.python.org/downloads/macos/")
                  && $0.contains("https://brew.sh") && $0.contains("`briglia python-env install`")
              } == true, "\(h1)")
        let only315 = R.choose([PythonRuntime.Probe(path: "/a/python3", version: "3.15.1", hasVenv: true)], minMinor: 11, maxMinor: 14)
        let hNew = R.unavailableMessage(only315)
        check("brew: no Homebrew, only 3.15 → python.org next to it",
              hNew.hasPrefix("Python 3.15 isn't supported yet — install Python 3.14 from https://www.python.org/downloads/macos/ (3.15 can stay), then run `briglia python-env install`"), hNew)
        unsetenv("BRIGLIA_PYTHON_TEST_NO_HOMEBREW")
        let bNew = R.unavailableMessage(only315)
        check("brew: Homebrew, only 3.15 → `brew install python@3.14` next to it, then python-env install",
              bNew.hasPrefix("Python 3.15 isn't supported yet — install Python 3.14 (`brew install python@3.14`; 3.15 can stay), then run `briglia python-env install`"), bNew)

        // Installed but not linked → the hint (Briglia never links).
        let prefix = try freshDir("hb-prefix")
        let keg = prefix.appendingPathComponent("opt/\(formula)/bin", isDirectory: true)
        try fm.createDirectory(at: keg, withIntermediateDirectories: true)
        try fakePython(keg.appendingPathComponent("python3.\(maxMinor)"), version: "3.\(maxMinor).2", real: nil)
        setenv("BRIGLIA_PYTHON_TEST_BREW_PREFIX", prefix.path, 1)
        let k1 = R.unavailableMessage(await R.selectBase())
        check("brew: \(formula) installed but not linked → `brew link \(formula)`",
              k1.contains("Homebrew's \(formula) is installed but not linked: run `brew link \(formula)`"), k1)
        let pbin = prefix.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: pbin, withIntermediateDirectories: true)
        try fakePython(pbin.appendingPathComponent("python3.\(maxMinor)"), version: "3.\(maxMinor).2", real: nil)
        check("brew: …linked → no such hint", !R.unavailableMessage(await R.selectBase()).contains("brew link"))
        unsetenv("BRIGLIA_PYTHON_TEST_BREW_PREFIX")

        // The tools check's interpreter: python3 when it works, else the
        // first working one scanned (a Homebrew python@3.X has only
        // versioned names; a broken python3 first on PATH must not blind it).
        let broken = scratch.appendingPathComponent("hb-broken-\(UUID().uuidString.prefix(6))")
        try "#!/bin/sh\nexit 1\n".write(to: broken, atomically: true, encoding: .utf8)
        chmod(broken.path, 0o755)
        let versionedDir = try freshDir("hb-versioned")
        let versioned = versionedDir.appendingPathComponent("python3.\(maxMinor)")
        try "#!/bin/sh\necho 3\n".write(to: versioned, atomically: true, encoding: .utf8)
        chmod(versioned.path, 0o755)
        check("tools check: a broken python3 first → the versioned python3.\(maxMinor) runs it",
              T.firstWorkingPython([broken.path, versioned.path], works: T.runsPython3) == versioned.path)
        check("tools check: no working Python 3 at all → none", T.firstWorkingPython([broken.path, "/nonexistent/python3"], works: T.runsPython3) == nil)
        let localPython = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/python3")
        try fm.createDirectory(at: localPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(to: localPython, atomically: true, encoding: .utf8)
        chmod(localPython.path, 0o755)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", versionedDir.path, 1)
        let p1 = T.python3Path()
        check("tools check (python3Path): a broken python3 first on PATH → the scanned python3.\(maxMinor)", p1 == versioned.path, p1 ?? "nil")
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", try freshDir("hb-empty").path, 1)
        let p2 = T.python3Path()
        check("tools check (python3Path): no working Python 3 anywhere → none (the menu then plans the bootstrap)", p2 == nil, p2 ?? "nil")
        try? fm.removeItem(at: localPython)

        // The setup wizard's bootstrap offer.
        let W = SetupWizard.self
        check("wizard: no working Python 3 + Homebrew from a terminal + none usable → offers \(formula)",
              W.pythonBootstrapOffer(workingPython: nil, canInstall: true, formulaNeeded: { formula }) == formula)
        check("wizard: a working Python 3 (the tools check runs) → no offer here",
              W.pythonBootstrapOffer(workingPython: "/usr/bin/python3", canInstall: true, formulaNeeded: { formula }) == nil)
        check("wizard: no terminal or no Homebrew → no offer", W.pythonBootstrapOffer(workingPython: nil, canInstall: false, formulaNeeded: { formula }) == nil)
        check("wizard: a usable Python → no offer", W.pythonBootstrapOffer(workingPython: nil, canInstall: true, formulaNeeded: { nil }) == nil)
        check("brew: the real Homebrew was never reached in this section", brewLog(realBrew).isEmpty, "\(brewLog(realBrew))")
    }

    /// Install → build with the runner's real Python (called from
    /// pythonEnv(), whose lock, wheels and probe settings are live).
    func pythonHomebrewBuild(found: PythonRuntime.Base) async throws {
        guard (10...PythonRuntime.maximumMinor).contains(found.minor) else {
            check("Homebrew build rows need a real python 3.10–3.\(PythonRuntime.maximumMinor) (skipped)", true); return
        }
        let R = PythonRuntime.self
        let saved = saveHomebrewEnv()
        defer { restoreHomebrewEnv(saved) }
        for k in Self.homebrewKeys { unsetenv(k) }
        let realBrew = try realBrewStub()
        // The supported range is exactly the runner's real minor X: Apple's
        // 3.9.6 is too old; Homebrew's python@3.X (running the real one) fixes it.
        setenv("BRIGLIA_PYTHON_MIN_MINOR", "\(found.minor)", 1)
        setenv("BRIGLIA_PYTHON_MAX_MINOR", "\(found.minor)", 1)
        let formula = "python@3.\(found.minor)"
        let apple = try freshDir("hbb-apple")
        try fakePython(apple.appendingPathComponent("python3"), version: "3.9.6", real: nil)
        let staged = scratch.appendingPathComponent("hbb-staged-\(UUID().uuidString.prefix(6))")
        try fakePython(staged, version: found.version, real: found.path)
        let log = scratch.appendingPathComponent("hbb-log-\(UUID().uuidString.prefix(6))")
        let brew = scratch.appendingPathComponent("hbb-brew-\(UUID().uuidString.prefix(6))")
        let brewBin = try freshDir("hbb-brewbin")
        let linked = brewBin.appendingPathComponent("python3.\(found.minor)")
        try writeFakeBrew(brew, log: log, mode: "ok", staged: staged, linked: linked)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", apple.path + ":" + brewBin.path, 1)
        setenv("BRIGLIA_PYTHON_TEST_BREW_INSTALLER", brew.path, 1)
        setenv("BRIGLIA_PYTHON_TEST_INTERACTIVE", "1", 1)
        resetRuntime()
        R.resetHomebrewAttemptForTesting()

        let ok1 = await R.converge(trigger: .install)
        check("brew: Apple's 3.9 only + a terminal → `brew install \(formula)` once (all four Homebrew variables), then built on it",
              ready(ok1) && brewLog(log) == [Self.brewLine(formula)] && receipt(.python)?.verifiedRecord?.extra?["base"] == linked.path,
              "\(ok1) \(brewLog(log))")
        R.resetHomebrewAttemptForTesting()
        let ok2 = await R.converge(trigger: .install)
        check("brew: a usable Python now → brew is never asked again (even with the attempt unused)", ready(ok2) && brewLog(log).count == 1, "\(brewLog(log))")

        let newer = try freshDir("hbb-newer")
        try fakePython(newer.appendingPathComponent("python3"), version: "3.\(found.minor + 1).1", real: nil)
        let brewBin2 = try freshDir("hbb-brewbin2")
        let linked2 = brewBin2.appendingPathComponent("python3.\(found.minor)")
        try writeFakeBrew(brew, log: log, mode: "ok", staged: staged, linked: linked2)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", newer.path + ":" + brewBin2.path, 1)
        resetRuntime()
        R.resetHomebrewAttemptForTesting()
        let t1 = await R.converge(trigger: .install)
        check("brew: only a newer Python (3.\(found.minor + 1)) → \(formula) installed next to it and used",
              ready(t1) && brewLog(log).count == 2 && receipt(.python)?.verifiedRecord?.extra?["base"] == linked2.path, "\(t1) \(brewLog(log))")

        let usable = try freshDir("hbb-usable")
        try fakePython(usable.appendingPathComponent("python3"), version: found.version, real: found.path)
        setenv("BRIGLIA_PYTHON_TEST_BASE_DIRS", apple.path + ":" + usable.path, 1)
        resetRuntime()
        R.resetHomebrewAttemptForTesting()
        let v1 = await R.converge(trigger: .install)
        check("brew: a usable Python next to Apple's 3.9 from the start → built on it, Homebrew never asked",
              ready(v1) && brewLog(log).count == 2 && receipt(.python)?.verifiedRecord?.extra?["base"] == usable.appendingPathComponent("python3").path,
              "\(v1) \(brewLog(log))")
        check("brew: the real Homebrew was never reached in these rows", brewLog(realBrew).isEmpty, "\(brewLog(realBrew))")
        resetRuntime()
    }
}
#endif
