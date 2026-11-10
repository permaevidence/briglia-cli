#if os(macOS)
import Foundation

/// macOS Python bootstrap (owner, 2026-11-10; Codex plan review r1/r2): when
/// the tools check could not run (no working Python 3 anywhere), "Install
/// what's missing" runs the planned Python job, checks again and installs
/// what the check then reports, in the same run. Fake jobs only (shell
/// `touch`); the Python job ends with the formula, like the real one.
@MainActor
extension MenuSelftestContext {
    func pythonBootstrap() async {
        let formula = PythonRuntime.homebrewPythonFormula
        /// `python`: "ok" (Python appears), "fail" (the job fails), "nothing"
        /// (the job succeeds but no Python appears).
        func workflow(_ dir: URL, python: String, plans: MenuCount, planned: MenuCount) async -> MenuWorkflow {
            let w = world()
            let py = dir.appendingPathComponent("python-installed").path
            let rest = dir.appendingPathComponent("rest-installed").path
            var e = env(w)
            e.toolchainStatus = {
                let fm = FileManager.default
                guard fm.fileExists(atPath: py) else {
                    return ToolchainService.DesktopStatus(doctorRan: false, missing: [], libreOffice: true, mandatoryMissing: [])
                }
                let done = fm.fileExists(atPath: rest)
                return ToolchainService.DesktopStatus(doctorRan: true, missing: done ? [] : ["pandoc"], libreOffice: true, mandatoryMissing: done ? [] : ["pandoc"])
            }
            e.quick.toolchainJobs = { status in
                plans.add(1)
                if status.doctorRan { planned.add(10) } else { planned.add(1) }
                if !status.doctorRan {
                    let cmd = python == "fail" ? "echo no bottle; exit 1" : (python == "ok" ? "touch '\(py)'" : "true")
                    return [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", cmd, formula], mode: .detached, timeout: 30,
                                                label: "brew install \(formula)")]
                }
                return [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "touch '\(rest)'"], mode: .detached, timeout: 30, label: "brew install pandoc")]
            }
            let m = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
            m.now = { w.clock }
            await m.start(); await m.settle()
            return m
        }
        func tools(_ m: MenuWorkflow) -> [String: Any] { m.status()["tools"] as? [String: Any] ?? [:] }
        func freshDir(_ name: String) -> URL {
            let d = tempRoot.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let fm = FileManager.default

        let dir = freshDir("py-bootstrap")
        let plans = MenuCount(), planned = MenuCount()
        let m = await workflow(dir, python: "ok", plans: plans, planned: planned)
        let r = await act(m, ["action": "tools_install"])
        check("python bootstrap: the tools check could not run → the Python job, a re-check, then what it reports, in one run",
              ok(r) && fm.fileExists(atPath: dir.appendingPathComponent("python-installed").path)
              && fm.fileExists(atPath: dir.appendingPathComponent("rest-installed").path) && plans.value == 2 && planned.value == 11,
              "plans=\(plans.value) planned=\(planned.value) \(m.jobLines)")
        check("python bootstrap: …ends complete, with no error", tools(m)["complete"] as? Bool == true && tools(m)["error"] == nil, "\(tools(m))")

        let dir2 = freshDir("py-bootstrap-fail")
        let plans2 = MenuCount(), planned2 = MenuCount()
        let m2 = await workflow(dir2, python: "fail", plans: plans2, planned: planned2)
        _ = await act(m2, ["action": "tools_install"])
        check("python bootstrap: the Python job fails → no second round, the failure is shown",
              plans2.value == 1 && !fm.fileExists(atPath: dir2.appendingPathComponent("rest-installed").path)
              && (tools(m2)["error"] as? String)?.contains("brew install \(formula)") == true, "plans=\(plans2.value) \(tools(m2))")

        let dir3 = freshDir("py-bootstrap-nothing")
        let plans3 = MenuCount(), planned3 = MenuCount()
        let m3 = await workflow(dir3, python: "nothing", plans: plans3, planned: planned3)
        _ = await act(m3, ["action": "tools_install"])
        let e3 = tools(m3)["error"] as? String ?? ""
        check("python bootstrap: brew succeeds but the check still can't run → says so (brew link hint), no empty \"Still missing\"",
              plans3.value == 1 && e3.hasPrefix("Homebrew installed \(formula), but the tools check still can\u{2019}t run Python.")
              && e3.contains("brew link \(formula)") && !e3.contains("Still missing"), "plans=\(plans3.value) \(e3)")

        // Codex implementation review r1: the round boundary under
        // revocation, and a failure inside a multi-job second round.
        func boundaryWorkflow(_ dir: URL, hold: MenuGate?, second: [SetupJobRunner.Spec]) async -> MenuWorkflow {
            let w = world()
            let py = dir.appendingPathComponent("python-installed").path
            var e = env(w)
            let checks = MenuCount()
            e.toolchainStatus = {
                guard FileManager.default.fileExists(atPath: py) else {
                    return ToolchainService.DesktopStatus(doctorRan: false, missing: [], libreOffice: true, mandatoryMissing: [])
                }
                checks.add(1)
                if checks.value == 1, let hold { await hold.wait() }   // the check right after the Python job
                return ToolchainService.DesktopStatus(doctorRan: true, missing: ["pandoc", "ffmpeg"], libreOffice: true, mandatoryMissing: ["pandoc", "ffmpeg"])
            }
            e.quick.toolchainJobs = { status in
                status.doctorRan ? second
                    : [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "touch '\(py)'", formula], mode: .detached, timeout: 30,
                                           label: "brew install \(formula)")]
            }
            let m = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
            m.now = { w.clock }
            await m.start(); await m.settle()
            return m
        }
        func touchJob(_ path: String, _ label: String) -> SetupJobRunner.Spec {
            SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "touch '\(path)'"], mode: .detached, timeout: 30, label: label)
        }

        let dir4 = freshDir("py-bootstrap-revoked")
        let hold = MenuGate()
        let second4 = [touchJob(dir4.appendingPathComponent("pandoc").path, "brew install pandoc"),
                       touchJob(dir4.appendingPathComponent("ffmpeg").path, "brew install ffmpeg")]
        let m4 = await boundaryWorkflow(dir4, hold: hold, second: second4)
        _ = await act(m4, ["action": "tools_install"], settle: false)
        var waited = 0
        while hold.arrived == 0, waited < 400 {   // parked in the check after the Python job
            try? await Task.sleep(nanoseconds: 50_000_000); waited += 1
        }
        let revoking = Task { @MainActor in await m4.revoke() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        hold.open()
        await revoking.value
        check("python bootstrap: revoked during the check after the Python job → no second-round job starts",
              hold.arrived == 1 && fm.fileExists(atPath: dir4.appendingPathComponent("python-installed").path)
              && !fm.fileExists(atPath: dir4.appendingPathComponent("pandoc").path) && !fm.fileExists(atPath: dir4.appendingPathComponent("ffmpeg").path),
              "\(m4.jobLines)")

        let dir5 = freshDir("py-bootstrap-second-fails")
        let second5 = [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "echo no bottle; exit 1"], mode: .detached, timeout: 30, label: "brew install pandoc"),
                       touchJob(dir5.appendingPathComponent("ffmpeg").path, "brew install ffmpeg")]
        let m5 = await boundaryWorkflow(dir5, hold: nil, second: second5)
        _ = await act(m5, ["action": "tools_install"])
        let e5 = tools(m5)["error"] as? String ?? ""
        check("python bootstrap: the first of two second-round jobs fails → the other never starts, the failure is shown",
              !fm.fileExists(atPath: dir5.appendingPathComponent("ffmpeg").path) && e5.contains("brew install pandoc") && tools(m5)["installing"] as? Bool != true,
              "\(e5) \(m5.jobLines)")
    }
}
#endif
