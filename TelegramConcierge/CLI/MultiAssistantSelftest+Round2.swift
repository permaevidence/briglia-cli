import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Codex stage-2 round 1 findings R1–R7 (each reproduced first, then fixed).
extension ProfileHarness {
    func stage2Round2Section() {
        // Stay under the 8-assistant cap (D7) when earlier sections ran.
        for name in ["crashy", "solo", "sup", "gone", "sb"] where registryDoc()?.record(name) != nil {
            _ = run(["profiles", "remove", name, "--yes", "--no-export"])
        }
        r1FirstActivationExcludesUnleased()
        r3ReexecOfARunningOldImage()
        r4RemovalTransactions()
        r5ScopeChangeExcludesStartup()
        r6WipeKeepsOwnScopeWithoutSharingLock()
        r7StartupRecoversADeadCoordinator()
        doctorReadOnly()
    }

    private func freshRoots(_ tag: String) -> [String: String] {
        let data = root.appendingPathComponent("\(tag)-data"), config = root.appendingPathComponent("\(tag)-config")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let secretsDir = config.appendingPathComponent("briglia", isDirectory: true)
        try? FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        let secrets: [String: String] = ["llm_provider": "openai_compatible", "openai_compatible_base_url": "http://127.0.0.1:9/v1",
                                         "openai_compatible_model": "m", "openai_compatible_api_key": "k", "assistant_name": "Bree"]
        try? JSONSerialization.data(withJSONObject: secrets).write(to: secretsDir.appendingPathComponent("secrets.json"))
        chmod(secretsDir.appendingPathComponent("secrets.json").path, 0o600)
        return ["XDG_DATA_HOME": data.path, "XDG_CONFIG_HOME": config.path, "BRIGLIA_TEST_NO_BROWSER_BOOTSTRAP": "1"]
    }

    /// R1: a daemon started inactive (no switch, no registry) is never left
    /// outside the barrier: first add refuses it, a racing start enrolls late,
    /// and the upgrader refuses an unleased instance.
    private func r1FirstActivationExcludesUnleased() {
        let env1 = freshRoots("r1a")
        let data = env1["XDG_DATA_HOME"]!
        guard let d = startChild(["daemon"], extraEnv: env1.merging([AssistantProfile.experimentalKey: ""]) { $1 }),
              d.waitFor(30, { $0.contains("daemon running") }) else { check("R1: inactive daemon starts", false); return }
        check("R1: a daemon started inactive holds no member lease",
              !FileManager.default.fileExists(atPath: data + "/briglia/machine/members") || MemberLeases.list(URL(fileURLWithPath: data + "/briglia/machine/members")).isEmpty)
        let add = run(["profiles", "add", "work", "--name", "Work", "--home", root.appendingPathComponent("r1-home").path], extraEnv: env1)
        check("R1: first `profiles add` refuses while an unleased Briglia runs, creating nothing",
              add.status != 0 && add.out.contains("without coordination") && !FileManager.default.fileExists(atPath: data + "/" + AssistantProfile.sharedDirName + "/registry.json"),
              add.out)
        // The upgrader refuses too, even if a registry appears another way.
        let reg = AssistantRegistry.Paths(root: URL(fileURLWithPath: data + "/" + AssistantProfile.sharedDirName, isDirectory: true))
        _ = try? AssistantRegistry.withLock(reg) { doc in doc = AssistantRegistry.Document(version: 1, records: [AssistantRegistry.newRecord(name: "default", displayName: "Bree")]) }
        let up = run(["upgrade", "--yes"], extraEnv: env1.merging(["BRIGLIA_TEST_UPGRADE_STAGED": root.appendingPathComponent("nonexistent").path]) { $1 })
        check("R1: the upgrader refuses while an unleased Briglia runs", up.status != 0 && up.out.contains("without coordination"), up.out)
        d.kill(SIGTERM)
        try? FileManager.default.removeItem(at: reg.registry)
        // Race: the daemon took its instance lock before the registry existed
        // and looks for it only afterwards; the registry is published in
        // between (as the first add does) → it enrolls late.
        let env2 = freshRoots("r1b")
        guard let late = startChild(["daemon"], extraEnv: env2.merging([AssistantProfile.experimentalKey: "", "BRIGLIA_TEST_LATE_ENROLL_PAUSE_MS": "2500"]) { $1 }) else { return }
        let lockHeld = late.waitFor(15) { _ in UnleasedInstances.instanceHeld(URL(fileURLWithPath: env2["XDG_DATA_HOME"]! + "/briglia")) }
        let reg2 = AssistantRegistry.Paths(root: URL(fileURLWithPath: env2["XDG_DATA_HOME"]! + "/" + AssistantProfile.sharedDirName, isDirectory: true))
        _ = try? AssistantRegistry.withLock(reg2) { doc in doc = AssistantRegistry.Document(version: 1, records: [AssistantRegistry.newRecord(name: "default", displayName: "Bree")]) }
        let members = URL(fileURLWithPath: env2["XDG_DATA_HOME"]! + "/briglia/machine/members")
        check("R1: a daemon whose instance lock predates the registry enrolls late (its lease appears)",
              lockHeld && late.waitFor(15) { _ in !MemberLeases.users(members, assistantsOnly: true).isEmpty }, String(late.output.suffix(400)))
        let addLate = run(["profiles", "add", "work", "--name", "Work", "--home", root.appendingPathComponent("r1b-home").path], extraEnv: env2)
        check("R1: with the running daemon enrolled, add succeeds", addLate.status == 0, addLate.out)
        late.kill(SIGTERM)
    }

    /// R3: a running old image re-execs into the validated installed release
    /// even though its pathname now names the replacement; a failed exec
    /// never continues on the old image.
    private func r3ReexecOfARunningOldImage() {
        guard let fx = makeUpgradeFixtureR2("r3") else { check("R3: fixture", false); return }
        let paths = UpgradeBarrier.Paths(root: URL(fileURLWithPath: fx.data + "/briglia/machine/upgrade", isDirectory: true))
        for (label, executable, expect) in [("re-execs into the new binary", true, "PROBE-REEXECUTED"), ("a failed exec exits 75", false, "")] {
            guard let child = startFrom(fx.fx, ["__member-probe", "--reexec-after", "2.5"], extra: fx.env) else { continue }
            _ = child.waitFor(10) { $0.contains("\"profile\"") }
            let aside = fx.fx.exe.deletingLastPathComponent().appendingPathComponent("old-image")
            try? FileManager.default.moveItem(at: fx.fx.exe, to: aside)
            try? "#!/bin/sh\necho PROBE-REEXECUTED\n".write(to: fx.fx.exe, atomically: true, encoding: .utf8)
            chmod(fx.fx.exe.path, executable ? 0o755 : 0o644)
            let installed = UpgradeBarrier.Installed(version: "9.9.9", sequence: 124, executable: fx.fx.exe.path,
                                                     binarySHA256: UpgradeBarrier.sha256(file: fx.fx.exe) ?? "",
                                                     bundleHash: UpgradeBarrier.bundleHash(fx.fx.bundle) ?? "")
            try? UpgradeBarrier.writeFile(installed, to: paths.installed)
            let status = child.waitExit(15)
            if executable {
                check("R3: a running old image \(label) (pathname-independent)",
                      child.output.contains(expect) && !child.output.contains("CONTINUED-ON-OLD-IMAGE"), child.output)
            } else {
                check("R3: \(label) and never continues on the old image",
                      status == 75 && !child.output.contains("CONTINUED-ON-OLD-IMAGE"), "\(String(describing: status)) \(child.output)")
            }
            try? FileManager.default.removeItem(at: fx.fx.exe)
            try? FileManager.default.moveItem(at: aside, to: fx.fx.exe)
            try? FileManager.default.removeItem(at: paths.installed)
        }
    }

    struct R2Fixture { var fx: UpgradeFixture; var env: [String: String]; var data: String }

    /// A scratch install with its own XDG roots (R3).
    private func makeUpgradeFixtureR2(_ tag: String) -> R2Fixture? {
        let env = freshRoots(tag)
        let fm = FileManager.default
        let install = root.appendingPathComponent("\(tag)-install", isDirectory: true)
        try? fm.createDirectory(at: install, withIntermediateDirectories: true)
        let realExe = UpgradeService.executableURL
        let besideExe = realExe.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName)
        let realBundle = fm.fileExists(atPath: besideExe.path) ? besideExe : Bundle.module.bundleURL
        let exe = install.appendingPathComponent(Self.exeName), bundle = install.appendingPathComponent(BundleCheck.bundleName)
        guard (try? fm.copyItem(at: realExe, to: exe)) != nil, (try? fm.copyItem(at: realBundle, to: bundle)) != nil else { return nil }
        try? "123".write(to: bundle.appendingPathComponent(ReleaseSequence.testFileName), atomically: true, encoding: .utf8)
        var e = env
        e[ReleaseSequence.testKey] = "1"
        let fx = UpgradeFixture(install: install, exe: exe, bundle: bundle, staged: install, env: e)
        return R2Fixture(fx: fx, env: e, data: env["XDG_DATA_HOME"]!)
    }

    /// R4: removals are transactions; inbox removal refused while running.
    private func r4RemovalTransactions() {
        let paths = Reg.Paths(root: root.appendingPathComponent("r4-reg", isDirectory: true))
        _ = try? Reg.withLock(paths) { doc in
            var d = Reg.Document(version: 1, records: [Reg.newRecord(name: "default", displayName: "Bree"), Reg.newRecord(name: "work", displayName: "Work")])
            d.records[0].bot.current = Reg.digest(.bot, "123456:SYNTH")
            doc = d
        }
        guard let tx = try? Reg.begin(profile: "default", kind: .bot, rawValue: nil, paths: paths) else { check("R4: removal begins", false); return }
        let during = (try? Reg.read(paths))??.record("default")
        check("R4: a removal publishes a transaction and keeps the old value until commit",
              during?.activeTx["bot"] != nil && during?.bot.current == Reg.digest(.bot, "123456:SYNTH"))
        check("R4: another assistant cannot take the bot during the removal",
              (try? Reg.begin(profile: "work", kind: .bot, rawValue: "123456:OTHER", paths: paths)) == nil)
        do {
            try tx.commit { throw Reg.RegistryError("injected write failure") }
            check("R4: a failed deletion keeps ownership", false)
        } catch {
            tx.abort()
            check("R4: a failed deletion keeps ownership (nothing released)",
                  (try? Reg.read(paths))??.record("default")?.bot.current == Reg.digest(.bot, "123456:SYNTH")
                  && (try? Reg.read(paths))??.record("default")?.activeTx.isEmpty == true)
        }
        if let tx2 = try? Reg.begin(profile: "default", kind: .bot, rawValue: nil, paths: paths) {
            try? tx2.commit {}
            let after = (try? Reg.read(paths))??.record("default")
            check("R4: a committed removal keeps the bot `releasing` until the consumer stopped",
                  after?.bot.current == nil && after?.bot.releasing?.value == Reg.digest(.bot, "123456:SYNTH")
                  && (try? Reg.begin(profile: "work", kind: .bot, rawValue: "123456:OTHER", paths: paths)) == nil)
            try? tx2.finish()
            if let t3 = try? Reg.begin(profile: "work", kind: .bot, rawValue: "123456:OTHER", paths: paths) {
                t3.abort(); check("R4: after finish the bot is free", true)
            } else { check("R4: after finish the bot is free", false) }
        }
        // A removal held by an offline setter makes a starting assistant wait.
        guard ensureExtra("rm4", display: "Rm4") else { return }
        if let holder = startChild(["--profile", "rm4", "__member-probe", "--hold-tx", "inbox:", "--hold", "3"]),
           holder.waitFor(8, { $0.contains("TX_HELD") }) {
            let starter = startChild(["--profile", "rm4", "__member-probe", "--assistant"])
            Thread.sleep(forTimeInterval: 1.2)
            check("R4: a starting assistant waits for an offline removal (startup exclusion)",
                  starter?.running == true && starter?.output.contains("PROBE_DONE") == false)
            _ = holder.waitExit(10); _ = starter?.waitExit(10)
        } else { check("R4: removal holder", false) }
        // Inbox removal through setup-api while the assistant runs → refused.
        _ = sharedProbe("rm4", "set-secrets", "{\"\(KeychainHelper.agentMailInboxAddressKey)\":\"rm4@example.invalid\",\"\(KeychainHelper.agentMailApiKeyKey)\":\"k\"}")
        if let running = startChild(["--profile", "rm4", "__member-probe", "--assistant", "--hold", "5"]),
           running.waitFor(8, { $0.contains("\"uuid\"") }) {
            let r = run(["--profile", "rm4", "setup-api", "apply"], stdin: #"{"email_calendar":{"provider":"none","remove_credentials":true}}"#)
            let secrets = readJSON(configBase + "/briglia-profiles/rm4/secrets.json")
            check("R4: removing a running assistant's inbox credentials is refused and deletes nothing",
                  r.out.contains("identity_refused") && secrets?[KeychainHelper.agentMailInboxAddressKey] as? String == "rm4@example.invalid", r.out)
            _ = running.waitExit(10)
        }
    }

    /// R5: a scope change that waited for the sharing lock refuses when the
    /// assistant started meanwhile.
    private func r5ScopeChangeExcludesStartup() {
        guard ensureExtra("sc5", display: "Sc5"),
              case .acquired(let held) = ProfileFileLock.take(URL(fileURLWithPath: machineDir + "/chatgpt-share.lock")) else {
            check("R5: setup", false); return
        }
        guard let change = startChild(["--profile", "sc5", "subscription", "scope", "own"]) else { held.release(); return }
        Thread.sleep(forTimeInterval: 1)
        guard let asst = startChild(["--profile", "sc5", "__member-probe", "--assistant", "--hold", "6"]),
              asst.waitFor(10, { $0.contains("\"uuid\"") }) else { held.release(); check("R5: assistant", false); return }
        held.release()
        let status = change.waitExit(20)
        check("R5: the scope change refuses once the assistant runs (probe and publication under the registry lock)",
              status != 0 && change.output.contains("Stop this assistant") && sharedProbe("sc5", "status")["scope"] as? String == "shared",
              "\(String(describing: status)) \(change.output)")
        _ = asst.waitExit(15)
    }

    /// R6: without the sharing lock an own-scope extra's wipe keeps `own`.
    private func r6WipeKeepsOwnScopeWithoutSharingLock() {
        guard ensureExtra("own6", display: "Own6") else { return }
        _ = run(["--profile", "own6", "subscription", "scope", "own"])
        var own = SubscriptionAuthState(generation: UUID().uuidString)
        own.credential = Self.credential("acct-own6")
        writeMachineStore(own, dir: URL(fileURLWithPath: configBase + "/briglia-profiles/own6", isDirectory: true))
        guard case .acquired(let held) = ProfileFileLock.take(URL(fileURLWithPath: machineDir + "/chatgpt-share.lock")) else { return }
        let w = sharedProbe("own6", "wipe", extraEnv: ["BRIGLIA_TEST_SHARE_WAIT": "0.1"])
        held.release()
        check("R6: a wipe without the sharing lock keeps `own` and its signed-in own store, and reports it",
              w["scopeKey"] as? String == "own" && w["ownSignedIn"] as? Bool == true && ((w["failures"] as? [String])?.first?.contains("keeps its own login") ?? false), "\(w)")
    }

    /// R7: a starting assistant recovers an orphaned barrier (no running monitor).
    private func r7StartupRecoversADeadCoordinator() {
        let record = UpgradeBarrier.Record(id: "orphan-r7", state: .open, targetVersion: "9.9.9", targetSequence: 999, openedAt: Date(),
                                           coordinator: .init(lease: "dead", pid: 999_999, processStartTime: "dead"), participants: [],
                                           committedBinarySHA256: nil, reason: nil)
        try? UpgradeBarrier.writeBarrier(record, barrierPaths)
        try? FileManager.default.removeItem(at: barrierPaths.journal)
        guard let starter = startChild(["__member-probe", "--assistant"]) else { return }
        let status = starter.waitExit(20)
        if status == nil { starter.kill() }
        check("R7: a starting assistant takes over recovery of a dead coordinator's barrier and continues",
              status == 0 && starter.output.contains("PROBE_DONE") && UpgradeBarrier.current(barrierPaths)?.state == .cancelled, starter.output)
        clearBarrier()
    }

    /// `doctor --read-only` reports a stuck update while everything else refuses.
    private func doctorReadOnly() {
        writeBarrier(state: .stuck, id: "stuck-doc")
        let d = run(["doctor", "--read-only"])
        let s = run(["__member-probe"])
        check("doctor --read-only: exempt, reports the stuck update and the recovery command",
              d.status == 0 && d.out.contains("stuck") && d.out.contains("upgrade --recover") && s.status == 75, d.out)
        clearBarrier()
    }
}
