#if os(macOS)
import Foundation

/// macOS Python bootstrap (owner, 2026-11-10; Codex plan review r1): when the
/// tools check could not run (no working Python 3 anywhere), "Install what's
/// missing" runs the planned Python job, checks again and installs what the
/// check then reports, in the same run. Fake jobs only (shell `touch`).
@MainActor
extension MenuSelftestContext {
    func pythonBootstrap() async {
        func workflow(_ dir: URL, failFirst: Bool, plans: MenuCount, planned: MenuCount) async -> MenuWorkflow {
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
                    let cmd = failFirst ? "echo no bottle; exit 1" : "touch '\(py)'"
                    return [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", cmd], mode: .detached, timeout: 30, label: "brew install python@3.14")]
                }
                return [SetupJobRunner.Spec(row: "toolchain", command: ["/bin/sh", "-c", "touch '\(rest)'"], mode: .detached, timeout: 30, label: "brew install pandoc")]
            }
            let m = MenuWorkflow(env: e, runner: SetupJobRunner(secrets: [:]))
            m.now = { w.clock }
            await m.start(); await m.settle()
            return m
        }
        func tools(_ m: MenuWorkflow) -> [String: Any] { m.status()["tools"] as? [String: Any] ?? [:] }

        let dir = tempRoot.appendingPathComponent("py-bootstrap-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plans = MenuCount(), planned = MenuCount()
        let m = await workflow(dir, failFirst: false, plans: plans, planned: planned)
        let r = await act(m, ["action": "tools_install"])
        let fm = FileManager.default
        check("python bootstrap: the tools check could not run → the Python job, a re-check, then what it reports, in one run",
              ok(r) && fm.fileExists(atPath: dir.appendingPathComponent("python-installed").path)
              && fm.fileExists(atPath: dir.appendingPathComponent("rest-installed").path) && plans.value == 2 && planned.value == 11,
              "plans=\(plans.value) planned=\(planned.value) \(m.jobLines)")
        check("python bootstrap: …ends complete, with no error", tools(m)["complete"] as? Bool == true && tools(m)["error"] == nil, "\(tools(m))")

        let dir2 = tempRoot.appendingPathComponent("py-bootstrap-fail-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let plans2 = MenuCount(), planned2 = MenuCount()
        let m2 = await workflow(dir2, failFirst: true, plans: plans2, planned: planned2)
        _ = await act(m2, ["action": "tools_install"])
        check("python bootstrap: the Python job fails → no second round, the failure is shown",
              plans2.value == 1 && !fm.fileExists(atPath: dir2.appendingPathComponent("rest-installed").path)
              && (tools(m2)["error"] as? String)?.contains("brew install python@3.14") == true, "plans=\(plans2.value) \(tools(m2))")
    }
}
#endif
