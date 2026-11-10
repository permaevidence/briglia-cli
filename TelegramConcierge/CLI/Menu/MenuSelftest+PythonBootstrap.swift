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
    }
}
#endif
