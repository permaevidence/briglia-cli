import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Codex stage-1 round 1 (R1–R4): registry lookup errors fail closed, no
/// Telegram discovery on a bot another assistant holds, AgentMail reads only
/// the inbox this assistant holds, machine settings refused inside the
/// parsed command.
extension ProfileHarness {
    func round2Section() {
        registryErrorChecks()
        discoveryGateChecks()
        inboxScopeChecks()
        machineCommandChecks()
    }

    /// R1: only a genuinely absent registry is "one assistant".
    private func registryErrorChecks() {
        let locked = tempRegistry("eacces")
        seed(locked)
        chmod(locked.root.path, 0o000)
        let lockedPresence = Reg.presence(locked)
        let lockedResult = Reg.reconcile(profile: "default", kind: .bot, read: { "100:A" }, paths: locked)
        let lockedDiscovery = Reg.telegramDiscoveryRefusal(profile: "default", token: "100:A", paths: locked)
        chmod(locked.root.path, 0o700)
        if getuid() == 0 {
            check("EACCES case skipped as root (root reads mode-000 directories)", true)
        } else {
            check("registry in an unreadable directory is not 'absent'", { if case .unreadable = lockedPresence { return true }; return false }())
            check("…reconciliation refuses (no polling)", { if case .conflict = lockedResult { return true }; return false }(), "\(lockedResult)")
            check("…Telegram discovery refused", lockedDiscovery != nil)
        }
        let fileParent = root.appendingPathComponent("reg-enotdir")
        FileManager.default.createFile(atPath: fileParent.path, contents: Data("x".utf8))
        let notDir = Reg.Paths(root: fileParent)
        check("registry under a regular file is not 'absent'", { if case .unreadable = Reg.presence(notDir) { return true }; return false }())
        check("…reconciliation refuses", { if case .conflict = Reg.reconcile(profile: "default", kind: .bot, read: { "1:A" }, paths: notDir) { return true }; return false }())
        let missing = tempRegistry("missing-extra")
        check("an extra without a registry may not poll", { if case .conflict = Reg.reconcile(profile: "work", kind: .bot, read: { "1:A" }, paths: missing) { return true }; return false }())
        check("an extra without a registry may not scan Telegram", Reg.telegramDiscoveryRefusal(profile: "work", token: "1:A", paths: missing) != nil)
        check("an extra without a registry reads no inbox", { if case .none = Reg.inboxScope(profile: "work", configuredInbox: "w@x.test", paths: missing) { return true }; return false }())
        check("default without a registry: unchanged (no refusal)", Reg.telegramDiscoveryRefusal(profile: "default", token: "1:A", paths: missing) == nil
              && Reg.inboxScope(profile: "default", configuredInbox: nil, paths: missing) == .all)
    }

    /// R2: discovery (getUpdates) never runs on a bot another assistant
    /// holds as current, pending or releasing, nor on a new bot in multi mode.
    private func discoveryGateChecks() {
        let p = tempRegistry("discovery")
        seed(p)                                   // default holds 100
        guard let pend = try? Reg.begin(profile: "health", kind: .bot, rawValue: "300:H", paths: p),
              let rel = try? Reg.begin(profile: "health", kind: .inbox, rawValue: "dummy@x.test", paths: p) else {
            check("discovery fixtures", false); return
        }
        rel.abort()
        // A releasing value: work commits 400 then switches to 401 (400 releasing).
        if let t1 = try? Reg.begin(profile: "work", kind: .bot, rawValue: "400:W", paths: p) { try? t1.commit {}; try? t1.finish() }
        let t2 = try? Reg.begin(profile: "work", kind: .bot, rawValue: "401:W", paths: p)
        try? t2?.commit {}
        check("discovery refused: bot current in another assistant",
              Reg.telegramDiscoveryRefusal(profile: "work", token: "100:OTHERTOKEN", paths: p)?.contains("‘Bree’") == true)
        check("discovery refused: bot pending in another assistant",
              Reg.telegramDiscoveryRefusal(profile: "work", token: "300:X", paths: p)?.contains("‘Health’") == true)
        check("discovery refused: bot releasing in another assistant",
              Reg.telegramDiscoveryRefusal(profile: "health", token: "400:X", paths: p)?.contains("‘Work’") == true)
        check("discovery refused: a new free bot while several assistants exist",
              Reg.telegramDiscoveryRefusal(profile: "work", token: "999:NEW", paths: p) != nil)
        check("discovery allowed: the bot this assistant holds", Reg.telegramDiscoveryRefusal(profile: "default", token: "100:A", paths: p) == nil)
        pend.abort(); try? t2?.finish()
    }

    /// R3: the AgentMail read boundary (polling and prompt snapshots share it).
    private func inboxScopeChecks() {
        let ids = "work@example.test,Bree@Example.test,other@example.test"
        func scoped(_ sel: [String]) -> [String]? {
            let r = run(sel + ["__profile-info", "--inbox-scope", ids])
            let obj = r.out.split(separator: "\n").last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            return obj?["scopedInboxes"] as? [String]
        }
        // Default holds bree@example.test (seeded at the first add).
        check("default reads only its own inbox once several assistants exist", scoped([]) == ["Bree@Example.test"], "\(scoped([]) ?? [])")
        check("an extra without a configured inbox reads nothing", scoped(["--profile", "health"]) == [])
        let setWork = writeExtraSecret("work", KeychainHelper.agentMailInboxAddressKey, "work@example.test")
        check("work configured with its own inbox", setWork)
        check("an extra reads only the inbox it holds (account exposes three)", scoped(["--profile", "work"]) == ["work@example.test"], "\(scoped(["--profile", "work"]) ?? [])")
        _ = writeExtraSecret("health", KeychainHelper.agentMailInboxAddressKey, "bree@example.test")
        check("an extra configured with another assistant's inbox reads nothing", scoped(["--profile", "health"]) == [])
    }

    /// Writes one secret of an extra through its own process (allow-listed
    /// keys only, so the inbox goes through the store file directly here).
    private func writeExtraSecret(_ profile: String, _ key: String, _ value: String) -> Bool {
        let path = configBase + "/briglia-profiles/\(profile)/secrets.json"
        var obj = readJSON(path) ?? [:]
        obj[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// R4: refusals live in the parsed commands, not only in argv.
    private func machineCommandChecks() {
        let setting = configBase + "/briglia/update-check.json"
        let before = FileManager.default.contents(atPath: setting)
        let dashed = run(["--profile", "work", "upgradecheck", "--", "off"])
        check("extra: upgradecheck -- off refused", dashed.status == 2 && dashed.out.contains("computer-wide"), dashed.out)
        check("…and default's setting is untouched", FileManager.default.contents(atPath: setting) == before)
        let alias = run(["--profile", "work", "update", "--yes"])
        check("extra: the `update` alias of upgrade is refused", alias.status == 2, alias.out)
        let tool = run(["--profile", "work", "toolchain", "--", "status"])
        check("extra: toolchain refused", tool.status == 2, tool.out)
        let readOnly = run(["--profile", "work", "upgradecheck"])
        check("extra: reading the update setting is allowed", readOnly.status == 0, readOnly.out)
    }
}
