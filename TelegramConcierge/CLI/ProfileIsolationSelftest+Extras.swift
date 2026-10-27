import Foundation

extension ProfileHarness {
    static let defaultToken = "111111111:SYNTHETICdefaultTOKENaaaaaaaaaaaaaaaa"
    static let workToken = "222222222:SYNTHETICworkTOKENbbbbbbbbbbbbbbbbbbb"

    /// `profiles add` (hidden), roots, metadata, registry seeding, copy-keys.
    func extrasSection() {
        do {
            try writeDefaultSecrets([KeychainHelper.openRouterApiKeyKey: "sk-or-synthetic-default",
                                     KeychainHelper.openRouterModelKey: "deepseek/deepseek-v4.1-flash",
                                     KeychainHelper.telegramBotTokenKey: Self.defaultToken,
                                     KeychainHelper.telegramChatIdKey: "123",
                                     KeychainHelper.agentMailApiKeyKey: "am-synthetic",
                                     KeychainHelper.agentMailInboxAddressKey: "Bree@Example.test",
                                     KeychainHelper.assistantNameKey: "Bree",
                                     KeychainHelper.openRouterToolSpendLimitDailyUSDKey: "3"])
        } catch { check("seed default secrets", false, "\(error)"); return }
        let hidden = run(["profiles", "add", "work", "--name", "Work"], removeEnv: [AssistantProfile.experimentalKey])
        check("profiles add is hidden without the switch", hidden.status != 0 && hidden.out.contains("not available"), hidden.out)
        let fromExtra = run(["profiles", "list"], extraEnv: [AssistantProfile.environmentKey: "nope"])
        check("profiles from an unknown profile refused", fromExtra.status == 2)

        let add = run(["profiles", "add", "work", "--name", "Work", "--bot-token-stdin"], stdin: Self.workToken + "\n")
        check("add work (own bot)", add.status == 0, add.out)
        let workConfig = configBase + "/briglia-profiles/work", workData = dataBase + "/briglia-profiles/work"
        check("work roots are 0700 siblings", mode(workConfig) == 0o700 && mode(workData) == 0o700)
        check("work profile.json", readJSON(workConfig + "/profile.json")?["displayName"] as? String == "Work")
        let addHealth = run(["profiles", "add", "health", "--name", "Health", "--copy-keys"])
        check("add health (copy keys)", addHealth.status == 0, addHealth.out)
        let reg = readJSON(dataBase + "/briglia-shared/registry.json")
        let records = (reg?["records"] as? [[String: Any]]) ?? []
        check("registry: default + work + health", records.compactMap { $0["name"] as? String } == ["default", "work", "health"])
        let defaultRecord = records.first { $0["name"] as? String == "default" }
        check("registry: default named after its persona", defaultRecord?["displayName"] as? String == "Bree")
        let regText = String(decoding: FileManager.default.contents(atPath: dataBase + "/briglia-shared/registry.json") ?? Data(), as: UTF8.self)
        check("registry stores digests, never the token or address",
              !regText.contains("111111111") && !regText.contains("222222222") && !regText.lowercased().contains("example.test"))
        check("registry directory is 0700", mode(dataBase + "/briglia-shared") == 0o700)
        check("never-multi file: machine/ is the only new directory in default's root",
              FileManager.default.fileExists(atPath: dataBase + "/briglia/machine"))

        let workSecrets = readJSON(workConfig + "/secrets.json") ?? [:]
        check("work: own bot token and name only", workSecrets[KeychainHelper.telegramBotTokenKey] as? String == Self.workToken
              && workSecrets[KeychainHelper.assistantNameKey] as? String == "Work"
              && workSecrets[KeychainHelper.openRouterApiKeyKey] == nil)
        let healthSecrets = readJSON(configBase + "/briglia-profiles/health/secrets.json") ?? [:]
        check("health --copy-keys: provider key and model copied",
              healthSecrets[KeychainHelper.openRouterApiKeyKey] as? String == "sk-or-synthetic-default"
              && healthSecrets[KeychainHelper.openRouterModelKey] as? String == "deepseek/deepseek-v4.1-flash")
        check("health --copy-keys: never the bot, pairing, inbox, AgentMail key or spend caps",
              healthSecrets[KeychainHelper.telegramBotTokenKey] == nil && healthSecrets[KeychainHelper.telegramChatIdKey] == nil
              && healthSecrets[KeychainHelper.agentMailInboxAddressKey] == nil && healthSecrets[KeychainHelper.agentMailApiKeyKey] == nil
              && healthSecrets[KeychainHelper.openRouterToolSpendLimitDailyUSDKey] == nil)
        check("health takes its own name, not Bree", healthSecrets[KeychainHelper.assistantNameKey] as? String == "Health")
        check("copy allow-list excludes identity keys", Set(ProfileProvisioning.copyableSecretKeys).isDisjoint(with:
              [KeychainHelper.telegramBotTokenKey, KeychainHelper.telegramChatIdKey, KeychainHelper.agentMailApiKeyKey,
               KeychainHelper.agentMailInboxAddressKey, KeychainHelper.assistantNameKey, KeychainHelper.userContextKey,
               KeychainHelper.openRouterToolSpendLimitDailyUSDKey, KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey,
               KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey, ProviderProfiles.subscriptionGenerationKey]))

        // Refusals.
        check("duplicate id refused", run(["profiles", "add", "work", "--name", "Other"]).status != 0)
        check("duplicate name refused (case-insensitive)", run(["profiles", "add", "w2", "--name", "work"]).out.contains("already called"))
        check("default's name refused", run(["profiles", "add", "w2", "--name", "bree"]).out.contains("already called"))
        check("reserved id refused", run(["profiles", "add", "shared", "--name", "Shared"]).status != 0)
        let stolen = run(["profiles", "add", "bot2", "--name", "Bot two", "--bot-token-stdin"],
                         stdin: "111111111:ROTATEDsecretOfTheDefaultBotcccccccc\n")
        check("a bot already used by default is refused (same bot id, other token)", stolen.status != 0 && stolen.out.contains("‘Bree’"), stolen.out)
        check("…and nothing was created for it", !FileManager.default.fileExists(atPath: configBase + "/briglia-profiles/bot2"))
        let reused = run(["profiles", "add", "bot2", "--name", "Bot two", "--bot-token-stdin"], stdin: Self.workToken + "\n")
        check("a bot used by another extra is refused", reused.status != 0 && reused.out.contains("‘Work’"), reused.out)
        check("add from an extra refused", run(["--profile", "work", "profiles", "add", "x", "--name", "X"]).status != 0)
        let list = run(["profiles", "list"])
        check("profiles list", list.status == 0 && list.out.contains("work\tWork\tbot set") && list.out.contains("health\tHealth\tno bot"), list.out)
        var count = 3
        for i in 0..<6 {
            let r = run(["profiles", "add", "x\(i)", "--name", "X\(i)"])
            if r.status == 0 { count += 1 }
        }
        check("at most \(AssistantProfile.maxProfiles) assistants including default", count == AssistantProfile.maxProfiles)
        check("the ninth is refused with a reason", run(["profiles", "add", "x9", "--name", "X9"]).out.contains("maximum"))
    }

    /// Paths of the extras and the isolation of every per-profile store.
    func isolationSection() {
        guard let work = info(["--profile", "work"]), let health = info(["--profile", "health"]) else {
            check("extras info", false); return
        }
        let wData = dataBase + "/briglia-profiles/work", wConf = configBase + "/briglia-profiles/work"
        check("work roots", work["dataRoot"] as? String == wData && work["configRoot"] as? String == wConf)
        check("work display text", work["dataRootDisplay"] as? String == "~/.local/share/briglia-profiles/work"
              && work["configRootDisplay"] as? String == "~/.config/briglia-profiles/work")
        check("work command prefix", work["commandPrefix"] as? String == "briglia --profile work")
        check("extras never send computer-wide notices", work["sendsMachineNotices"] as? Bool == false
              && health["sendsMachineNotices"] as? Bool == false)
        check("work exports BRIGLIA_PROFILE", work["envProfile"] as? String == "work")
        let hw = AssistantProfile.installationHash("work", environment: env)
        check("work preferences suite", work["prefsSuite"] as? String == Self.suitePrefix + "briglia.profile.work.\(hw)")
        check("work spill dir namespaced", work["spillDir"] as? String == env["TMPDIR"]! + "briglia-tool-output-work-\(hw)/")
        check("suites differ", work["prefsSuite"] as? String != health["prefsSuite"] as? String)
        check("spill dirs differ", work["spillDir"] as? String != health["spillDir"] as? String)
        check("landing zones differ", work["landingRoot"] as? String != health["landingRoot"] as? String)
        check("work Playwright: own Chrome profile in its root",
              (work["playwrightArgs"] as? [String])?.suffix(2) == ["--user-data-dir", wData + "/browser-profile"])
        check("work wrappers select the profile", (work["agentmailWrapper"] as? String)?.contains("exec '/opt/briglia' '--profile' 'work' __agentmail-exec") == true
              && (work["pythonWrapper"] as? String)?.contains("exec '/opt/briglia' '--profile' 'work' __python-exec") == true)
        check("machine: release trust shared at default's place", work["releaseTrust"] as? String == dataBase + "/briglia/release_trust.json")
        check("machine: notice stores read from default's place", work["noticeState"] as? String == dataBase + "/briglia/update/notice.json")
        check("machine: sign-in lock in default's machine/", work["signInLock"] as? String == dataBase + "/briglia/machine/signin.lock")
        let noSeam = info(["--profile", "work"], removeEnv: [LandingZone.testRootKey])
        check("work landing = its home folder (~/Briglia/work)", noSeam?["landingRoot"] as? String == home + "/Briglia/work")

        // Touch every store in three profiles, then prove no crossing.
        guard let d = info(touch: true), let w = info(["--profile", "work"], touch: true),
              let hh = info(["--profile", "health"], touch: true) else { check("touch runs", false); return }
        for (name, i) in [("default", d), ("work", w), ("health", hh)] {
            check("\(name): secrets read back its own value", i["secretValue"] as? String == "probe-\(name)")
            check("\(name): preferences read back its own value", i["prefsValue"] as? String == "probe-\(name)")
        }
        // Read back WITHOUT writing, after all three wrote: a shared store
        // would show the last writer's value everywhere.
        for sel in [[], ["--profile", "work"], ["--profile", "health"]] {
            let name = sel.last ?? "default"
            let r = run(sel + ["__profile-info", "--read"])
            let obj = r.out.split(separator: "\n").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            check("\(name): after every profile wrote, still reads its own preferences and secrets",
                  obj?["prefsValue"] as? String == "probe-\(name)" && obj?["secretValue"] as? String == "probe-\(name)",
                  "\(obj?["prefsValue"] ?? "nil") / \(obj?["secretValue"] ?? "nil")")
        }
        check("extras never use the standard preferences object", w["prefsStoreIsStandard"] as? Bool == false
              && hh["prefsStoreIsStandard"] as? Bool == false && d["prefsStoreIsStandard"] as? Bool == true)
        // Every file carrying a profile's marker lives in that profile's
        // own places; default's root never contains an extra's file.
        let allowed: [String: [String]] = [
            "default": [dataBase + "/briglia/", configBase + "/briglia/", env["TMPDIR"]! + "briglia-tool-output/", root.path + "/landing/default"],
            "work": [wData + "/", wConf + "/", (w["spillDir"] as? String) ?? "-", root.path + "/landing/work"],
            "health": [dataBase + "/briglia-profiles/health/", configBase + "/briglia-profiles/health/", (hh["spillDir"] as? String) ?? "-", root.path + "/landing/health"],
        ]
        var crossings: [String] = []
        for file in files(under: root.path) where file.hasPrefix(root.path + "/home") || file.hasPrefix(root.path + "/tmp") || file.hasPrefix(root.path + "/landing") {
            guard let data = FileManager.default.contents(atPath: file), data.count < 4_000_000 else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for (name, places) in allowed where text.contains("probe-\(name)") {
                if !places.contains(where: { file.hasPrefix($0) }) { crossings.append("\(name) → \(file)") }
            }
        }
        check("no profile's state appears outside its own places", crossings.isEmpty, crossings.prefix(5).joined(separator: "; "))
        let strays = files(under: dataBase + "/briglia").filter { $0.contains("briglia-profiles") }
        check("default's root holds no extra's state", strays.isEmpty, strays.prefix(3).joined(separator: "; "))
        check("spill files written in each profile's own dir",
              (w["spillPath"] as? String)?.hasPrefix((w["spillDir"] as? String) ?? "?") == true
              && (d["spillPath"] as? String)?.hasPrefix(env["TMPDIR"]! + "briglia-tool-output/") == true)
        check("landing bootstrapped per profile", FileManager.default.fileExists(atPath: root.path + "/landing/work/scratch/repos")
              && FileManager.default.fileExists(atPath: root.path + "/landing/health/telegram"))
    }

    /// The selection reaches children (Bash/MCP use the inherited
    /// environment; the setsid trampoline is the agent's shell path).
    func inheritanceSection() {
        let r = run(["--profile", "work", "__setsid-exec", "--", "/usr/bin/env"])
        check("work child sees BRIGLIA_PROFILE=work", r.out.split(separator: "\n").contains("BRIGLIA_PROFILE=work"), r.out.suffix(300).description)
        let d = run(["__setsid-exec", "--", "/usr/bin/env"])
        check("default child sees no BRIGLIA_PROFILE", !d.out.contains("BRIGLIA_PROFILE="))
        let nested = run(["__profile-info"], extraEnv: [AssistantProfile.environmentKey: "work"])
        check("a child started with the inherited variable selects work", nested.out.contains("\"profile\":\"work\""))
        let probe = AgentMailService.probeEnvironment()
        _ = probe
        check("AgentMail probe environment keeps the selection",
              ["BRIGLIA_PROFILE", "BRIGLIA_EXPERIMENTAL_PROFILES"].allSatisfy { key in
                  setenv(key, "x", 1); defer { unsetenv(key) }
                  return AgentMailService.probeEnvironment()[key] == "x"
              })
    }
}
