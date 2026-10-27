import Foundation

extension ProfileHarness {
    func decide(_ args: [String], env e: [String: String] = [AssistantProfile.experimentalKey: "1"],
                existing: Set<String> = ["work"]) -> Result<ProfileBootstrap.Decision, ProfileBootstrap.Failure> {
        ProfileBootstrap.decide(arguments: args, environment: e, exists: { existing.contains($0) },
                                available: { existing.sorted() })
    }

    func bootstrapSection() {
        // Name rules (§3.1).
        for good in ["a", "work", "w-2", "0x", String(repeating: "a", count: 24)] {
            check("valid name \(good)", AssistantProfile.isValidName(good))
        }
        for bad in ["", "-a", "Work", "a_b", "a.b", "a/b", String(repeating: "a", count: 25), "é", "a b"] {
            check("invalid name \(bad.debugDescription)", !AssistantProfile.isValidName(bad))
        }
        for reserved in ["default", "all", "shared", "profiles"] {
            check("reserved \(reserved) is not an extra id", !AssistantProfile.isUsableExtraName(reserved))
        }
        // Selection and argv handling (§3.2).
        func ok(_ r: Result<ProfileBootstrap.Decision, ProfileBootstrap.Failure>) -> ProfileBootstrap.Decision? {
            if case .success(let d) = r { return d } else { return nil }
        }
        func failed(_ r: Result<ProfileBootstrap.Decision, ProfileBootstrap.Failure>) -> String? {
            if case .failure(let f) = r { return f.message } else { return nil }
        }
        check("no flag → default, argv untouched", ok(decide(["chat"])) == .init(profile: "default", arguments: ["chat"]))
        check("--profile work daemon → work, flag removed", ok(decide(["--profile", "work", "daemon"])) == .init(profile: "work", arguments: ["daemon"]))
        check("--profile=work daemon → work", ok(decide(["--profile=work", "daemon"])) == .init(profile: "work", arguments: ["daemon"]))
        check("a later --profile belongs to the subcommand", ok(decide(["chat", "--profile", "work"])) == .init(profile: "default", arguments: ["chat", "--profile", "work"]))
        check("--profile without a name → exit 2", failed(decide(["--profile"])) != nil)
        check("--profile default equals no flag", ok(decide(["--profile", "default", "doctor"])) == .init(profile: "default", arguments: ["doctor"]))
        let envOnly = [AssistantProfile.experimentalKey: "1", AssistantProfile.environmentKey: "work"]
        check("BRIGLIA_PROFILE selects", ok(decide(["daemon"], env: envOnly))?.profile == "work")
        check("argv and env agreeing → accepted", ok(decide(["--profile", "work", "daemon"], env: envOnly))?.profile == "work")
        check("argv and env differing → refused", failed(decide(["--profile", "default"], env: envOnly))?.contains("conflicts") == true)
        check("empty BRIGLIA_PROFILE → default", ok(decide([], env: [AssistantProfile.environmentKey: ""]))?.profile == "default")
        check("unknown profile → refused, never default", failed(decide(["--profile", "nope"]))?.contains("no assistant profile ‘nope’") == true)
        check("unknown profile lists the profiles", failed(decide(["--profile", "nope"]))?.contains("default, work") == true)
        check("invalid name → refused", failed(decide(["--profile", "Work"]))?.contains("not a valid") == true)
        check("reserved name → refused", failed(decide(["--profile", "shared"])) != nil)
        check("hidden: without the experimental switch an extra is refused",
              failed(decide(["--profile", "work"], env: [:]))?.contains("not available") == true)
        check("hidden: default needs no switch", ok(decide(["--profile", "default"], env: [:]))?.profile == "default")
        for cmd in [["upgrade"], ["toolchain", "status"], ["migrate"], ["service", "install"], ["upgradecheck", "off"]] {
            check("extra refuses \(cmd.joined(separator: " "))", failed(decide(["--profile", "work"] + cmd)) != nil)
        }
        check("extra may read upgradecheck", ok(decide(["--profile", "work", "upgradecheck"]))?.profile == "work")
        check("default may run upgrade", ok(decide(["upgrade"]))?.profile == "default")

        // Real processes: exit 2, explanation, no roots created.
        let before = files(under: home)
        let unknown = run(["--profile", "nope", "doctor"])
        check("process: unknown profile exits 2", unknown.status == 2, "status \(unknown.status): \(unknown.out)")
        let conflict = run(["--profile", "work", "doctor"], extraEnv: [AssistantProfile.environmentKey: "health"])
        check("process: argv/env conflict exits 2", conflict.status == 2, "status \(conflict.status)")
        let hidden = run(["--profile", "nope", "--version"], removeEnv: [AssistantProfile.experimentalKey])
        check("process: hidden without the switch (exit 2)", hidden.status == 2 && hidden.out.contains("not available"), hidden.out)
        check("process: refused selections create nothing", files(under: home) == before
              && !FileManager.default.fileExists(atPath: dataBase + "/briglia-profiles/nope"))
    }

    func prefsSuiteSection() {
        let e = ["XDG_DATA_HOME": "/x/share", Prefs.testSuitePrefixKey: "briglia-mw-t-"]
        let h = AssistantProfile.installationHash("work", environment: e)
        check("default keeps UserDefaults.standard", Prefs.suiteName(profile: "default", environment: e, processName: "briglia") == nil)
        check("extra suite briglia.profile.<n>.<h>", Prefs.suiteName(profile: "work", environment: ["XDG_DATA_HOME": "/x/share"], processName: "briglia") == "briglia.profile.work.\(h)")
        check("hash = first 8 hex of the data-root path", h.count == 8 && h.allSatisfy(\.isHexDigit))
        check("two XDG installations → two suites",
              AssistantProfile.installationHash("work", environment: ["XDG_DATA_HOME": "/y/share"]) != h)
        check("test prefix ignored for a real executable name",
              Prefs.suiteName(profile: "work", environment: e, processName: "briglia") == "briglia.profile.work.\(h)")
        check("test prefix honoured only under briglia-mw-*",
              Prefs.suiteName(profile: "work", environment: e, processName: "briglia-mw-x") == "briglia-mw-t-briglia.profile.work.\(h)")
        check("a prefix that is not a test domain is ignored",
              Prefs.suiteName(profile: "work", environment: ["XDG_DATA_HOME": "/x/share", Prefs.testSuitePrefixKey: "evil-"],
                              processName: "briglia-mw-x") == "briglia.profile.work.\(h)")
        check("prefixed suite is a purgeable test domain", TestPrefsDomains.isTestDomain("briglia-mw-t-briglia.profile.work.\(h)"))
    }

    /// Default resolves exactly as before, three ways (§12 (a)/(b)).
    func defaultInvarianceSection() {
        let plain = info()
        let flag = info(["--profile", "default"])
        let viaEnv = info(extraEnv: [AssistantProfile.environmentKey: "default"])
        guard let plain, let flag, let viaEnv else { check("default info runs three ways", false); return }
        func strip(_ d: [String: Any]) -> NSDictionary {
            var d = d; d.removeValue(forKey: "envProfile"); return d as NSDictionary
        }
        check("no flag == --profile default", strip(plain) == strip(flag))
        check("no flag == BRIGLIA_PROFILE=default", strip(plain) == strip(viaEnv))
        check("default: no BRIGLIA_PROFILE is exported", plain["envProfile"] is NSNull, "\(plain["envProfile"] ?? "")")
        check("default data root", plain["dataRoot"] as? String == dataBase + "/briglia")
        check("default config root", plain["configRoot"] as? String == configBase + "/briglia")
        check("default display text byte-equal", plain["dataRootDisplay"] as? String == "~/.local/share/briglia"
              && plain["configRootDisplay"] as? String == "~/.config/briglia")
        check("default command prefix", plain["commandPrefix"] as? String == "briglia")
        check("default sends the computer-wide notices", plain["sendsMachineNotices"] as? Bool == true)
        check("default prefs: UserDefaults.standard", plain["prefsSuite"] as? String == "standard")
        check("default spill dir (test seam)", plain["spillDir"] as? String == env["TMPDIR"]! + "briglia-tool-output/")
        let realSpill = info(removeEnv: [TruncationService.testSpillRootKey])?["spillDir"] as? String
        check("default spill dir unchanged without the seam", realSpill == NSTemporaryDirectory() + "briglia-tool-output/", realSpill ?? "nil")
        check("default secret store", plain["secretStore"] as? String == configBase + "/briglia/secrets.json")
        check("default Playwright invocation unchanged (no extra args)", (plain["playwrightArgs"] as? [String])?.count == 1)
        check("default AgentMail wrapper bytes unchanged", plain["agentmailWrapper"] as? String == """
            #!/bin/sh
            # Installed by Briglia CLI. Runs Briglia's private AgentMail CLI after
            # checking it against its install receipt; the key is fetched at exec
            # time and handed only to that binary.
            exec '/opt/briglia' __agentmail-exec "$@"

            """)
        check("default Python wrapper bytes unchanged", plain["pythonWrapper"] as? String
              == "#!/bin/sh\n# Installed by Briglia CLI: Briglia's private Python environment (never the shared python3).\nexec '/opt/briglia' __python-exec \"$@\"\n")
        check("default release trust at its old place", plain["releaseTrust"] as? String == dataBase + "/briglia/release_trust.json")
        check("default notice state at its old place", plain["noticeState"] as? String == dataBase + "/briglia/update/notice.json"
              && plain["noticeSetting"] as? String == configBase + "/briglia/update-check.json")
        let noSeam = info(removeEnv: [LandingZone.testRootKey])
        check("default landing zone ~/Documents/Briglia without the test seam",
              canon(noSeam?["landingRoot"] as? String) == canon(home + "/Documents/Briglia"), "\(noSeam?["landingRoot"] ?? "")")
        check("diagnostics create no root and no briglia-shared",
              !FileManager.default.fileExists(atPath: dataBase + "/briglia")
              && !FileManager.default.fileExists(atPath: dataBase + "/briglia-shared"))
    }
}
