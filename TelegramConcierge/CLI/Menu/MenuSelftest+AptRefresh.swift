import Foundation

/// apt-get package-list refresh (field report 2026-11-18): a Debian 13 first
/// install failed with "404 Not Found" for LibreOffice because the machine's
/// package lists were stale. apt-get installs now refresh the lists first:
/// the menu/Quick Setup plan a best-effort `sudo apt-get update` job before
/// the install job; the setup wizard and python3.X-venv refresh once per
/// process before their first install. dnf and pacman are unchanged. Fake
/// package managers only (shell scripts, an injected runner): no real sudo,
/// no real apt.
@MainActor
extension MenuSelftestContext {
    func aptRefresh() async {
        let fm = FileManager.default

        // MARK: A. The planner (pure, every platform)
        let Q = QuickSetupEnvironment.self
        let apt = Q.linuxPackageJobs(manager: "apt-get", managerPath: "/usr/bin/apt-get", sudo: "/usr/bin/sudo", packages: ["poppler-utils", "libreoffice"])
        check("apt refresh: apt-get → a list refresh, then the install, in that order",
              apt.map(\.label) == ["apt-get update", "apt-get install poppler-utils libreoffice"]
              && apt.map(\.command) == [["/usr/bin/sudo", "/usr/bin/apt-get", "update"],
                                        ["/usr/bin/sudo", "/usr/bin/apt-get", "install", "-y", "poppler-utils", "libreoffice"]],
              "\(apt.map(\.command))")
        check("apt refresh: only the refresh is best effort; both are terminal jobs (same terminal, so sudo may reuse its cached login)",
              apt.map(\.bestEffort) == [true, false] && apt.allSatisfy { $0.mode == .terminalHandoff }
              && apt.allSatisfy { $0.environment == ["DEBIAN_FRONTEND": "noninteractive"] }, "\(apt.map(\.bestEffort))")
        check("apt refresh: the refresh never upgrades (no upgrade, dist-upgrade or full-upgrade anywhere)",
              !apt.flatMap(\.command).contains { ["upgrade", "dist-upgrade", "full-upgrade"].contains($0) })
        let dnf = Q.linuxPackageJobs(manager: "dnf", managerPath: "/usr/bin/dnf", sudo: "/usr/bin/sudo", packages: ["pandoc"])
        check("apt refresh: dnf unchanged — one install job, no refresh",
              dnf.map(\.command) == [["/usr/bin/sudo", "/usr/bin/dnf", "install", "-y", "pandoc"]] && dnf.map(\.bestEffort) == [false]
              && dnf.map(\.label) == ["dnf install pandoc"], "\(dnf.map(\.command))")
        let pac = Q.linuxPackageJobs(manager: "pacman", managerPath: "/usr/bin/pacman", sudo: "/usr/bin/sudo", packages: ["pandoc"])
        check("apt refresh: pacman unchanged — one install job, never -Sy",
              pac.map(\.command) == [["/usr/bin/sudo", "/usr/bin/pacman", "-S", "--noconfirm", "--needed", "pandoc"]] && pac.map(\.bestEffort) == [false]
              && !pac.flatMap(\.command).contains { $0.hasPrefix("-Sy") }, "\(pac.map(\.command))")
        check("apt refresh: nothing to install → no job at all (never a refresh alone)",
              Q.linuxPackageJobs(manager: "apt-get", managerPath: "/usr/bin/apt-get", sudo: "/usr/bin/sudo", packages: []).isEmpty)
        let M = LinuxPackageMap.self
        check("apt refresh: refresh command is apt-get only",
              M.refreshCommand(manager: "apt-get", managerPath: "/x/apt-get") == ["/x/apt-get", "update"]
              && M.refreshCommand(manager: "dnf", managerPath: "/x/dnf") == nil && M.refreshCommand(manager: "pacman", managerPath: "/x/pacman") == nil
              && M.refreshCommand(manager: "zypper", managerPath: "/x/zypper") == nil)

        // MARK: B. One installer run, one package at a time (setup wizard, python3.X-venv)
        final class Calls: @unchecked Sendable { var argv: [[String]] = []; var announced: [String] = [] }
        func session(_ calls: Calls, update: LinuxInstallSession.Outcome = .exited(0),
                     install: LinuxInstallSession.Outcome = .exited(0)) -> LinuxInstallSession {
            LinuxInstallSession(run: { argv in
                calls.argv.append(argv)
                return argv.last == "update" ? update : install
            }, announce: { calls.announced.append($0) })
        }
        let c1 = Calls()
        let s1 = session(c1)
        let r1a = s1.install("poppler-utils", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        let r1b = s1.install("imagemagick", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        let r1c = s1.install("libreoffice", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        check("apt refresh (wizard): the lists are refreshed exactly once, before the run's first install",
              r1a == nil && r1b == nil && r1c == nil
              && c1.argv == [["/usr/bin/apt-get", "update"], ["/usr/bin/apt-get", "install", "-y", "poppler-utils"],
                             ["/usr/bin/apt-get", "install", "-y", "imagemagick"], ["/usr/bin/apt-get", "install", "-y", "libreoffice"]],
              "\(c1.argv)")
        check("apt refresh (wizard): the terminal is told once before the refresh",
              c1.announced == ["Refreshing package lists (apt-get update)\u{2026}"], "\(c1.announced)")

        let c2 = Calls()
        let r2 = session(c2, update: .exited(100)).install("libreoffice", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        check("apt refresh (wizard): the refresh fails → the install still runs, and succeeds quietly",
              r2 == nil && c2.argv == [["/usr/bin/apt-get", "update"], ["/usr/bin/apt-get", "install", "-y", "libreoffice"]], "\(c2.argv) \(String(describing: r2))")

        let c3 = Calls()
        let s3 = session(c3, update: .exited(100), install: .exited(100))
        let r3 = s3.install("libreoffice", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        check("apt refresh (wizard): refresh and install both fail → one install attempt; the text names both",
              r3 == "apt-get exited with status 100 (refreshing the package lists before it also failed: apt-get update exited with status 100)"
              && c3.argv.count == 2, "\(c3.argv) \(String(describing: r3))")
        let r3b = s3.install("pandoc", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        check("apt refresh (wizard): a later install in the same run does not refresh again, and still says why the lists may be stale",
              c3.argv.count == 3 && c3.argv.last == ["/usr/bin/apt-get", "install", "-y", "pandoc"]
              && r3b?.contains("apt-get update exited with status 100") == true, "\(c3.argv) \(String(describing: r3b))")

        let c4 = Calls()
        let r4 = session(c4, install: .exited(100)).install("libreoffice", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        check("apt refresh (wizard): refresh fine, install fails → exactly one attempt, the usual text (no loop, no retry)",
              r4 == "apt-get exited with status 100" && c4.argv == [["/usr/bin/apt-get", "update"], ["/usr/bin/apt-get", "install", "-y", "libreoffice"]],
              "\(c4.argv) \(String(describing: r4))")

        let c5 = Calls()
        let r5 = session(c5, update: .launchFailed("no tty")).install("libreoffice", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        let c5b = Calls()
        let r5b = session(c5b, update: .launchFailed("no tty"), install: .launchFailed("no tty")).install("x", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        check("apt refresh (wizard): the refresh cannot even start → the install still runs; a failing install names both",
              r5 == nil && c5.argv.count == 2
              && r5b == "failed to launch apt-get: no tty (refreshing the package lists before it also failed: failed to launch apt-get update: no tty)",
              "\(c5.argv) \(String(describing: r5b))")

        let others: [(String, [String])] = [("dnf", ["install", "-y"]), ("pacman", ["-S", "--noconfirm", "--needed"])]
        for (manager, args) in others {
            let c = Calls()
            let s = session(c, install: .exited(1))
            let bin = "/usr/bin/" + manager
            let r = s.install("pandoc", manager: manager, managerPath: bin)
            _ = s.install("ffmpeg", manager: manager, managerPath: bin)
            let want: [[String]] = [[bin] + args + ["pandoc"], [bin] + args + ["ffmpeg"]]
            let sameArgv = c.argv == want
            let sameText = r == manager + " exited with status 1"
            check("apt refresh (wizard): \(manager) unchanged — installs only, the same arguments and text",
                  sameArgv && sameText && c.announced.isEmpty, "\(c.argv) \(String(describing: r))")
        }

        // MARK: C. The menu ("Install what's missing") with fake sudo + apt-get
        func fakeDir(update: Int, install: Int, updateSleeps: Bool = false, updateCommand: String? = nil) -> URL {
            let d = tempRoot.appendingPathComponent("apt-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            let sudo = "#!/bin/sh\nexec \"$@\"\n"
            let aptScript = """
            #!/bin/sh
            dir=$(dirname "$0")
            echo "$*" >> "$dir/calls.log"
            case "$1" in
              update) echo "Hit:1 http://deb.debian.org/debian trixie InRelease"; \(updateCommand.map { $0 + "; " } ?? "")\(updateSleeps ? "sleep 20; " : "")exit \(update) ;;
              install)
                if [ \(install) -eq 0 ]; then touch "$dir/installed"; exit 0; fi
                echo "E: Failed to fetch http://deb.debian.org/debian-security/pool/updates/main/l/libreoffice/x.deb  404  Not Found"
                exit \(install) ;;
            esac
            exit 2
            """
            for (name, text) in [("sudo", sudo), ("apt-get", aptScript)] {
                let u = d.appendingPathComponent(name)
                try? text.write(to: u, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            }
            return d
        }
        func calls(_ d: URL) -> [String] {
            ((try? String(contentsOf: d.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func workflow(_ d: URL, language: String = "en", bestEffort: Bool = true,
                      adjustRefresh: @escaping @Sendable (inout SetupJobRunner.Spec) -> Void = { _ in }) async -> MenuWorkflow {
            let w = world()
            var e = env(w, linux: true)
            e.language = language
            let installed = d.appendingPathComponent("installed").path
            e.toolchainStatus = {
                let done = FileManager.default.fileExists(atPath: installed)
                return ToolchainService.DesktopStatus(doctorRan: true, missing: done ? [] : ["pandoc"], libreOffice: true, mandatoryMissing: done ? [] : ["pandoc"])
            }
            // The real planner; detached here only because the selftest has
            // no terminal to lend (the jobs are terminal jobs in real use).
            e.quick.toolchainJobs = { _ in
                QuickSetupEnvironment.linuxPackageJobs(manager: "apt-get", managerPath: d.appendingPathComponent("apt-get").path,
                                                       sudo: d.appendingPathComponent("sudo").path, packages: ["pandoc"])
                    .map { var j = $0; j.mode = .detached; if !bestEffort { j.bestEffort = false }; if j.bestEffort { adjustRefresh(&j) }; return j }
            }
            let m = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
            m.now = { w.clock }
            await m.start(); await m.settle()
            return m
        }
        func tools(_ m: MenuWorkflow) -> [String: Any] { m.status()["tools"] as? [String: Any] ?? [:] }

        let d1 = fakeDir(update: 0, install: 0)
        let m1 = await workflow(d1)
        let a1 = await act(m1, ["action": "tools_install"])
        check("apt refresh (menu): refresh, then install, each once; the install completes",
              ok(a1) && calls(d1) == ["update", "install -y pandoc"] && tools(m1)["complete"] as? Bool == true && tools(m1)["error"] == nil,
              "\(calls(d1)) \(tools(m1))")

        let d2 = fakeDir(update: 100, install: 0)
        let m2 = await workflow(d2)
        _ = await act(m2, ["action": "tools_install"])
        check("apt refresh (menu): the refresh fails → the install still runs and completes, with a warning line",
              calls(d2) == ["update", "install -y pandoc"] && tools(m2)["complete"] as? Bool == true && tools(m2)["error"] == nil
              && m2.jobLines.contains("\u{26A0} Could not refresh the package lists (apt-get update: exited with status 100); installing anyway."),
              "\(calls(d2)) \(tools(m2)) \(m2.jobLines)")

        let d3 = fakeDir(update: 100, install: 100)
        let m3 = await workflow(d3)
        _ = await act(m3, ["action": "tools_install"])
        let e3 = tools(m3)["error"] as? String ?? ""
        check("apt refresh (menu): refresh and install both fail → one install attempt; the error names both",
              calls(d3) == ["update", "install -y pandoc"]
              && e3 == "Installation stopped \u{2014} apt-get install pandoc: exited with status 100 (refreshing the package lists before it also failed: apt-get update: exited with status 100).",
              "\(calls(d3)) \(e3)")
        check("apt refresh (menu): …and the installer's own 404 line is kept for the page",
              m3.jobLines.contains { $0.contains("404  Not Found") }, "\(m3.jobLines)")

        let d4 = fakeDir(update: 0, install: 100)
        let m4 = await workflow(d4)
        _ = await act(m4, ["action": "tools_install"])
        let e4 = tools(m4)["error"] as? String ?? ""
        check("apt refresh (menu): refresh fine, install fails → one attempt, the usual error (no refresh note, no retry)",
              calls(d4) == ["update", "install -y pandoc"] && e4 == "Installation stopped \u{2014} apt-get install pandoc: exited with status 100.",
              "\(calls(d4)) \(e4)")

        let d5 = fakeDir(update: 100, install: 100)
        let m5 = await workflow(d5, language: "it")
        _ = await act(m5, ["action": "tools_install"])
        let e5 = tools(m5)["error"] as? String ?? ""
        check("apt refresh (menu, Italian): the warning and the error are in Italian",
              e5 == "Installazione interrotta: apt-get install pandoc: exited with status 100 (anche l\u{2019}aggiornamento dell\u{2019}elenco dei pacchetti prima non era riuscito: apt-get update: exited with status 100)."
              && m5.jobLines.contains("\u{26A0} Non è stato possibile aggiornare l\u{2019}elenco dei pacchetti (apt-get update: exited with status 100); installo comunque."),
              "\(e5) \(m5.jobLines)")

        let d6 = fakeDir(update: 100, install: 0)
        let m6 = await workflow(d6, bestEffort: false)
        _ = await act(m6, ["action": "tools_install"])
        check("apt refresh (menu): a failed step that is NOT best effort still stops the run (the next step never starts)",
              calls(d6) == ["update"] && (tools(m6)["error"] as? String) == "Installation stopped \u{2014} apt-get update: exited with status 100.",
              "\(calls(d6)) \(tools(m6))")

        let d7 = fakeDir(update: 100, install: 0, updateSleeps: true)
        let m7 = await workflow(d7)
        _ = await act(m7, ["action": "tools_install"], settle: false)
        var waited = 0
        while calls(d7).isEmpty, waited < 200 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        await m7.revoke(cancelJob: true)   // shutdown: the running refresh is stopped too
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("apt refresh (menu): the page shuts down during the refresh → the install never starts",
              calls(d7) == ["update"] && !fm.fileExists(atPath: d7.appendingPathComponent("installed").path), "\(calls(d7))")

        // MARK: E. An interrupted refresh ends the install (Codex round 1, P2)
        // A signal death of the refresh (Ctrl-C in the terminal hand-off, SIGTERM, SIGKILL) is an interrupt: the
        // install never starts. Only an ordinary failure (non-zero exit, timeout, could not start) is passed over.
        // The selftest runs the jobs detached (no terminal to lend), and a detached runner child starts with
        // SIGINT/SIGTERM blocked (the `__setsid-exec` trampoline's mask), so the fake unblocks before killing
        // itself; in real use the refresh is a terminal job, whose child starts with an empty mask.
        func killSelf(_ name: String) -> String {
            if name == "SIGKILL" { return "kill -KILL $$" }   // cannot be blocked or caught
            return "exec /usr/bin/python3 -I -c \"import os,signal; signal.signal(signal.\(name), signal.SIG_DFL); signal.pthread_sigmask(signal.SIG_SETMASK, []); os.kill(os.getpid(), signal.\(name))\""
        }
        for (name, number) in [("SIGINT", 2), ("SIGTERM", 15), ("SIGKILL", 9)] {
            let d = fakeDir(update: 0, install: 0, updateCommand: killSelf(name))
            let m = await workflow(d)
            _ = await act(m, ["action": "tools_install"])
            let e = tools(m)["error"] as? String ?? ""
            check("apt refresh (menu): the refresh is killed by \(name) → interrupted, the install never starts",
                  calls(d) == ["update"] && !fm.fileExists(atPath: d.appendingPathComponent("installed").path)
                  && e == "Installation stopped \u{2014} apt-get update was interrupted (signal \(number), \(name)), so nothing was installed."
                  && !m.jobLines.contains { $0.contains("installing anyway") },
                  "\(calls(d)) \(e) \(m.jobLines)")
        }
        let dIt = fakeDir(update: 0, install: 0, updateCommand: killSelf("SIGINT"))
        let mIt = await workflow(dIt, language: "it")
        _ = await act(mIt, ["action": "tools_install"])
        let eIt = tools(mIt)["error"] as? String ?? ""
        check("apt refresh (menu, Italian): an interrupted refresh says so in Italian",
              calls(dIt) == ["update"]
              && eIt == "Installazione interrotta: apt-get update è stato interrotto (segnale 2, SIGINT), quindi non è stato installato nulla.",
              "\(calls(dIt)) \(eIt)")
        // Controls: the ordinary failures still go on to the install (exit 100 is row C2 above).
        let dTimeout = fakeDir(update: 0, install: 0, updateSleeps: true)
        let mTimeout = await workflow(dTimeout, adjustRefresh: { $0.timeout = 1 })
        _ = await act(mTimeout, ["action": "tools_install"])
        check("apt refresh (menu): control — a refresh that times out still goes on to the install",
              calls(dTimeout) == ["update", "install -y pandoc"] && tools(mTimeout)["complete"] as? Bool == true
              && mTimeout.jobLines.contains { $0.contains("apt-get update: timed out); installing anyway") },
              "\(calls(dTimeout)) \(mTimeout.jobLines)")
        let dNoStart = fakeDir(update: 0, install: 0)
        let mNoStart = await workflow(dNoStart, adjustRefresh: { $0.command[0] = "/nonexistent/briglia-apt-selftest/sudo" })
        _ = await act(mNoStart, ["action": "tools_install"])
        check("apt refresh (menu): control — a refresh whose program is missing (the trampoline exits 127) still goes on to the install",
              calls(dNoStart) == ["install -y pandoc"] && tools(mNoStart)["complete"] as? Bool == true,
              "\(calls(dNoStart)) \(mNoStart.jobLines)")

        // MARK: F. The wizard / python-env path: the real terminal adapter + the session (Codex round 1, P2)
        // `ToolchainService.runThroughTerminal` is the adapter the Linux session uses (sudo resolved by
        // PlatformBinary there; the fake sudo here). Without a terminal, the hand-off just runs and waits.
        func adapter(_ d: URL, _ argv: [String]) -> LinuxInstallSession.Outcome {
            // The child inherits this process's stdout (as in real use): flush first so its
            // lines never land inside a half-written check line of ours.
            fflush(stdout)
            return ToolchainService.runThroughTerminal(executable: d.appendingPathComponent("sudo").path, arguments: argv)
        }
        for (name, number) in [("SIGINT", Int32(2)), ("SIGTERM", Int32(15)), ("SIGKILL", Int32(9))] {
            let d = fakeDir(update: 0, install: 0, updateCommand: killSelf(name))
            let out = adapter(d, [d.appendingPathComponent("apt-get").path, "update"])
            check("apt refresh (wizard adapter): a refresh killed by \(name) is reported as that signal, not an exit status",
                  out == .signaled(number), "\(out)")
        }
        let dExit = fakeDir(update: 100, install: 0)
        let dMissing = tempRoot.appendingPathComponent("apt-missing-\(UUID().uuidString.prefix(6))")
        let exitOut = adapter(dExit, [dExit.appendingPathComponent("apt-get").path, "update"])
        let missingOut = adapter(dMissing, ["update"])
        var missingIsLaunchFailure = false
        if case .launchFailed = missingOut { missingIsLaunchFailure = true }
        check("apt refresh (wizard adapter): an ordinary exit stays an exit status; a missing program cannot launch",
              exitOut == .exited(100) && missingIsLaunchFailure, "\(exitOut) \(missingOut)")

        let dInt = fakeDir(update: 0, install: 0, updateCommand: killSelf("SIGINT"))
        let sInt = LinuxInstallSession(run: { adapter(dInt, $0) })
        let aptInt = dInt.appendingPathComponent("apt-get").path
        let rInt = sInt.install("pandoc", manager: "apt-get", managerPath: aptInt)
        let rInt2 = sInt.install("ffmpeg", manager: "apt-get", managerPath: aptInt)
        check("apt refresh (wizard): the refresh is interrupted → nothing installed, and the run is over",
              calls(dInt) == ["update"] && !fm.fileExists(atPath: dInt.appendingPathComponent("installed").path)
              && rInt == "Installation interrupted: apt-get update was interrupted (signal 2, SIGINT), so pandoc was not installed. Run it again to retry."
              && rInt2 == "not installed: the installation was interrupted (apt-get update was interrupted (signal 2, SIGINT)). Run it again to retry.",
              "\(calls(dInt)) \(String(describing: rInt)) | \(String(describing: rInt2))")
        let dCtl = fakeDir(update: 100, install: 0)
        let sCtl = LinuxInstallSession(run: { adapter(dCtl, $0) })
        let rCtl = sCtl.install("pandoc", manager: "apt-get", managerPath: dCtl.appendingPathComponent("apt-get").path)
        check("apt refresh (wizard): control — an ordinary failed refresh (exit 100) still goes on to the install",
              rCtl == nil && calls(dCtl) == ["update", "install -y pandoc"], "\(calls(dCtl)) \(String(describing: rCtl))")

        let cTerm = Calls()
        let sTerm = session(cTerm, install: .signaled(15))
        let rTerm = sTerm.install("libreoffice", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        let rTerm2 = sTerm.install("pandoc", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        check("apt refresh (wizard): an interrupted install ends the run; the next install never runs",
              rTerm == "Installation interrupted: apt-get was interrupted (signal 15, SIGTERM)"
              && cTerm.argv == [["/usr/bin/apt-get", "update"], ["/usr/bin/apt-get", "install", "-y", "libreoffice"]]
              && rTerm2?.hasPrefix("not installed: the installation was interrupted (apt-get was interrupted (signal 15, SIGTERM))") == true,
              "\(cTerm.argv) \(String(describing: rTerm)) | \(String(describing: rTerm2))")
        let cKill = Calls()
        let rKill = session(cKill, update: .signaled(9)).install("pandoc", manager: "apt-get", managerPath: "/usr/bin/apt-get")
        check("apt refresh (wizard): any signal counts (SIGKILL on the refresh → no install)",
              cKill.argv == [["/usr/bin/apt-get", "update"]] && rKill?.contains("signal 9, SIGKILL") == true,
              "\(cKill.argv) \(String(describing: rKill))")

        // MARK: D. The real planner on this host
        #if os(Linux)
        if let manager = ToolchainService.linuxPackageManager(), let sudo = PlatformBinary.find("sudo"),
           let path = PlatformBinary.find(manager.name) {
            let saved = QuickSetupEnvironment.venvPackageNeeded
            QuickSetupEnvironment.venvPackageNeeded = { nil }
            let jobs = QuickSetupEnvironment.defaultToolchainJobs(.init(doctorRan: true, missing: ["pandoc"], libreOffice: true, mandatoryMissing: ["pandoc"]))
            QuickSetupEnvironment.venvPackageNeeded = saved
            let pandoc = LinuxPackageMap.package("pandoc", manager: manager.name)
            var expected: [[String]] = []
            if manager.name == "apt-get" { expected.append([sudo, path, "update"]) }
            expected.append([sudo] + LinuxPackageMap.installCommand(manager: manager.name, managerPath: path, packages: [pandoc]))
            check("apt refresh: this host's real plan (\(manager.name)) is the planner's", jobs.map(\.command) == expected
                  && jobs.allSatisfy { $0.mode == .terminalHandoff }, "\(jobs.map(\.command))")
        } else {
            check("apt refresh: no package manager + sudo on this host (row skipped)", true)
        }
        #else
        if ToolchainService.brewPath() != nil {
            let jobs = QuickSetupEnvironment.defaultToolchainJobs(.init(doctorRan: true, missing: ["pandoc"], libreOffice: false, mandatoryMissing: ["pandoc"]))
            check("apt refresh: macOS unchanged — brew jobs only, nothing best effort, no update step",
                  jobs.map(\.label) == ["brew install pandoc", "brew install --cask libreoffice"] && !jobs.contains { $0.bestEffort }, "\(jobs.map(\.label))")
        } else {
            check("apt refresh: Homebrew on this Mac (row skipped otherwise)", true)
        }
        #endif
    }
}
