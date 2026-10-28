import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `briglia daemon --all` (§4.3, §16 item 8) with real headless daemons.
extension ProfileHarness {
    func supervisorSection() {
        // Whatever happens below (a deliberate break such as M17 restarting
        // a stopped assistant), no supervised daemon outlives this section.
        defer { reapLeasedProcesses() }
        try? writeDefaultSecrets(["llm_provider": "openai_compatible", "openai_compatible_base_url": "http://127.0.0.1:9/v1",
                                  "openai_compatible_model": "mock-model", "openai_compatible_api_key": "k",
                                  "assistant_name": "Bree", "user_name": "Test"])
        for (id, name, keys) in [("sup", "Sup", true), ("crashy", "Crashy", false), ("solo", "Solo", true)] where registryDoc()?.record(id) == nil {
            var args = ["profiles", "add", id, "--name", name, "--home", root.appendingPathComponent("home-\(id)").path]
            if keys { args.append("--copy-keys") }
            let r = run(args)
            if r.status != 0 { check("supervisor: add \(id)", false, r.out); return }
        }
        // Only these assistants autostart in this scenario.
        mutateRegistry { d in for i in d.records.indices { d.records[i].autostart = ["default", "sup", "crashy", "solo"].contains(d.records[i].name) } }
        let seams = ["BRIGLIA_TEST_SUPERVISOR_BACKOFF": "0.2,0.2,0.2,0.2", "BRIGLIA_TEST_NO_BROWSER_BOOTSTRAP": "1"]
        guard let solo = startChild(["--profile", "solo", "__member-probe", "--assistant", "--hold", "90"], extraEnv: seams),
              solo.waitFor(10, { $0.contains("\"uuid\"") }) else { check("supervisor: solo runs elsewhere", false); return }
        defer { solo.kill() }
        guard let sup = startChild(["daemon", "--all"], extraEnv: seams) else { check("supervisor: start", false); return }
        defer { sup.kill() }
        let started = sup.waitFor(40) { $0.contains("[Bree]") && $0.contains("[Sup]") && $0.contains("daemon running") }
            && sup.waitFor(30) { _ in self.liveAssistants(self.defaultMembers).count == 1 && self.liveAssistants(self.extraLeaseDir("sup")).count == 1 }
        check("supervisor: starts every autostart assistant as its own child", started, String(sup.output.suffix(1500)))
        check("supervisor: child output is shown with the assistant's name (tailed from its own log file)",
              sup.output.contains("[Sup] Briglia daemon running") || sup.output.contains("[Bree] Briglia daemon running"), String(sup.output.suffix(800)))
        check("supervisor: a profile already running elsewhere is left alone",
              sup.waitFor(10) { $0.contains("[Solo] · running elsewhere") } && liveAssistants(extraLeaseDir("solo")).count == 1)
        check("supervisor: a crashing assistant is restarted with backoff, then parked",
              sup.waitFor(60) { $0.contains("[Crashy] · stopped after 5 crashes") }, String(sup.output.suffix(1500)))
        let second = run(["daemon", "--all"], extraEnv: seams)
        check("supervisor: a second supervisor is refused", second.status == 1 && second.out.contains("already running"), second.out)
        // `profiles stop` → exit 0 → not restarted.
        let stop = run(["profiles", "stop", "sup"])
        let stayed = stop.status == 0 && sup.waitFor(15) { $0.contains("[Sup] · stopped") }
        Thread.sleep(forTimeInterval: 2)
        check("supervisor: an assistant stopped on purpose is not restarted",
              stayed && liveAssistants(extraLeaseDir("sup")).isEmpty, stop.out + String(sup.output.suffix(600)))
        // The supervisor dies: its children keep running and logging.
        let defaultPid = liveAssistants(defaultMembers).first?.sidecar?.pid
        sup.kill(SIGKILL)
        Thread.sleep(forTimeInterval: 1)
        let logPath = defaultData + "/logs/daemon.log"
        let before = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? NSNumber)?.intValue ?? 0
        Thread.sleep(forTimeInterval: 2.5)
        let after = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? NSNumber)?.intValue ?? 0
        check("supervisor: after the supervisor dies its children keep running and logging to their own files",
              liveAssistants(defaultMembers).first?.sidecar?.pid == defaultPid && defaultPid != nil && after > before,
              "pid \(String(describing: defaultPid)) log \(before)→\(after)")
        // A new supervisor sees them as running elsewhere; SIGTERM stops only its own children.
        guard let sup2 = startChild(["daemon", "--all"], extraEnv: seams) else { return }
        check("supervisor: a new supervisor leaves the orphaned daemon alone (running elsewhere)",
              sup2.waitFor(15) { $0.contains("[Bree] · running elsewhere") })
        check("supervisor: and starts the assistants nobody runs", sup2.waitFor(30) { _ in self.liveAssistants(self.extraLeaseDir("sup")).count == 1 })
        let supPid = liveAssistants(extraLeaseDir("sup")).first?.sidecar?.pid
        kill(sup2.process.processIdentifier, SIGTERM)
        let exit = sup2.waitExit(40)
        check("supervisor: SIGTERM stops its children (group SIGTERM, grace, SIGKILL) and exits 0",
              exit == 0 && liveAssistants(extraLeaseDir("sup")).isEmpty && supPid.map { kill($0, 0) != 0 } == true,
              "\(String(describing: exit)) \(sup2.output.suffix(400))")
        _ = run(["profiles", "stop", "default"])
        check("supervisor: cleanup — no assistant left running", liveAssistants(defaultMembers).isEmpty)
    }
}
