import Foundation

/// The shared ChatGPT login (§25, §16 6h, owner decision D18), with every
/// operation in a child process of the selected profile.
extension ProfileHarness {
    func sharedProbe(_ profile: String?, _ action: String, _ arg: String? = nil, extraEnv: [String: String] = [:]) -> [String: Any] {
        let r = run((profile.map { ["--profile", $0] } ?? []) + ["__shared-login-probe", action] + (arg.map { [$0] } ?? []), extraEnv: extraEnv)
        for line in r.out.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { return o }
        }
        return ["error": "no output: \(r.status) \(r.out.suffix(300))"]
    }

    var machineStoreDir: URL { URL(fileURLWithPath: configBase + "/briglia", isDirectory: true) }

    func writeMachineStore(_ state: SubscriptionAuthState, dir: URL? = nil) {
        let d = dir ?? machineStoreDir
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        chmod(d.path, 0o700)
        do { try SubscriptionAuthStore(directory: d).write(state) } catch { print("   (store write failed: \(error))") }
    }

    func readMachineStore(dir: URL? = nil) -> SubscriptionAuthState? { (try? SubscriptionAuthStore(directory: dir ?? machineStoreDir).read()) ?? nil }

    static func credential(_ account: String, access: String = "access-1", refresh: String = "refresh-1", expired: Bool = false) -> SubscriptionCredential {
        SubscriptionCredential(access: access, refresh: refresh, expires: Date().addingTimeInterval(expired ? -60 : 3600), account: account, residency: nil)
    }

    func sharedLoginSection() {
        guard ensureExtra("sa", display: "Sa"), ensureExtra("sb", display: "Sb") else { check("chatgpt: extras", false); return }
        let defaultRoot = machineStoreDir.standardizedFileURL.path
        // Resolver.
        let sa = sharedProbe("sa", "status"), def = sharedProbe(nil, "status")
        check("resolver: default uses its own config root (unchanged)", def["storeDir"] as? String == defaultRoot, "\(def)")
        check("resolver: an extra shares default's store by default", sa["storeDir"] as? String == defaultRoot, "\(sa)")
        let scope = run(["--profile", "sb", "subscription", "scope", "own"])
        let sb = sharedProbe("sb", "status")
        check("resolver: `subscription scope own` gives an extra its own store",
              scope.status == 0 && sb["storeDir"] as? String == (configBase + "/briglia-profiles/sb"), "\(scope.out) \(sb)")
        check("sharers: default + every extra not explicitly own", (sa["sharers"] as? [String]) == ["default", "sa"] || (sharedProbe("sa", "status")["sharers"] as? [String]) == ["default", "sa"])
        check("protection: an extra protects both stores (file tools, redaction)",
              (sa["protected"] as? [String])?.count == 2 && (def["protected"] as? [String])?.count == 1)

        // Cross-process refresh: exactly one refresh for two processes.
        let g1 = UUID().uuidString
        var state = SubscriptionAuthState(generation: g1)
        state.credential = Self.credential("acct-1", expired: true)
        writeMachineStore(state)
        let counter = root.appendingPathComponent("refresh-count")
        FileManager.default.createFile(atPath: counter.path, contents: Data())
        let a = startChild(["__shared-login-probe", "refresh", counter.path])
        let b = startChild(["--profile", "sa", "__shared-login-probe", "refresh", counter.path])
        _ = a?.waitExit(30); _ = b?.waitExit(30)
        let refreshes = (try? String(contentsOf: counter, encoding: .utf8))?.split(separator: "\n").count ?? -1
        check("refresh: two processes (default + extra) needing a refresh send exactly ONE refresh",
              refreshes == 1 && (a?.output.contains("access-2") ?? false) && (b?.output.contains("access-2") ?? false),
              "count \(refreshes) a=\(a?.output ?? "") b=\(b?.output ?? "")")
        check("refresh: the old refresh token is never sent twice", (try? String(contentsOf: counter, encoding: .utf8))?.components(separatedBy: "refresh-1").count == 2)

        // Bind `sa` to (g1, acct-1), active ChatGPT.
        let fp1 = SubscriptionSharing.fingerprint("acct-1")
        let bind = "{\"\(ProviderProfiles.subscriptionGenerationKey)\":\"\(g1)\",\"\(SubscriptionSharing.accountFingerprintKey)\":\"\(fp1)\",\"\(ProviderProfiles.activeProfileKey)\":\"chatgpt\",\"\(KeychainHelper.openAICompatibleApiKeyKey)\":\"\(g1)\",\"\(ProviderProfiles.subscriptionModelKey)\":\"gpt-test\"}"
        _ = sharedProbe("sa", "set-secrets", bind)
        // Same account re-signed in (from default) → sa rebinds automatically.
        let g2 = UUID().uuidString
        state = SubscriptionAuthState(generation: g2); state.credential = Self.credential("acct-1", access: "access-3"); state.signedInBy = "default"
        writeMachineStore(state)
        let same = sharedProbe("sa", "resolve", g1)
        check("rebind: a re-sign-in to the SAME account is picked up automatically (generation + active slot rewritten once)",
              same["generation"] as? String == g2 && same["boundGeneration"] as? String == g2 && same["runtimeSlot"] as? String == g2, "\(same)")
        // Different account → D18: refused, nothing rewritten.
        let g3 = UUID().uuidString
        state = SubscriptionAuthState(generation: g3); state.credential = Self.credential("acct-2", access: "access-4"); state.signedInBy = "default"
        writeMachineStore(state)
        let other = sharedProbe("sa", "resolve", g2)
        check("D18: a DIFFERENT account is never used silently; the message says to choose ChatGPT again and who changed it",
              (other["error"] as? String)?.contains("different account") == true && (other["error"] as? String)?.contains("Bree") == true
              && other["boundGeneration"] as? String == g2 && other["runtimeSlot"] as? String == g2, "\(other)")
        let act = sharedProbe("sa", "activate")
        check("D18: choosing ChatGPT again binds the new account explicitly",
              act["ok"] as? Bool == true && act["boundGeneration"] as? String == g3 && act["fp"] as? String == SubscriptionSharing.fingerprint("acct-2"), "\(act)")
        check("rebind: no fingerprint (pre-multi selection) after another sign-in → explicit choice required", { () -> Bool in
            _ = sharedProbe("sa", "set-secrets", "{\"\(SubscriptionSharing.accountFingerprintKey)\":\"\",\"\(ProviderProfiles.subscriptionGenerationKey)\":\"\(g2)\"}")
            return (sharedProbe("sa", "resolve", g2)["error"] as? String)?.contains("different account") == true
        }())

        // Pending-login ownership.
        let pend = sharedProbe("sa", "begin")
        check("pending: a sign-in records its owner", readMachineStore()?.pendingLoginBy == "sa" && pend["pending"] != nil, "\(pend)")
        check("pending: default's wipe/cancel never cancels sa's sign-in",
              sharedProbe(nil, "cancel-owned")["outcome"] as? String == "foreign" && readMachineStore()?.pendingLogin != nil)
        check("pending: the owner cancels its own", sharedProbe("sa", "cancel-owned")["outcome"] as? String == "cancelled"
              && readMachineStore()?.pendingLogin == nil && readMachineStore()?.pendingLoginBy == nil)
        var legacy = readMachineStore() ?? SubscriptionAuthState(generation: UUID().uuidString)
        legacy.pendingLogin = UUID().uuidString; legacy.pendingLoginBy = nil
        writeMachineStore(legacy)
        check("pending: no owner field = default's (an extra cannot cancel it; default can)",
              sharedProbe("sa", "cancel-owned")["outcome"] as? String == "foreign" && sharedProbe(nil, "cancel-owned")["outcome"] as? String == "cancelled")

        // Wipe rules.
        let saWipe = sharedProbe("sa", "wipe")
        check("wipe: an extra's wipe never signs the shared login out; its binding is cleared; it says so",
              saWipe["storeSignedIn"] as? Bool == true && saWipe["binding"] as? String == ""
              && ((saWipe["notes"] as? [String])?.first?.contains("stays signed in") ?? false), "\(saWipe)")
        if case .acquired(let held) = ProfileFileLock.take(URL(fileURLWithPath: machineDir + "/chatgpt-share.lock")) {
            let busy = sharedProbe(nil, "wipe", extraEnv: ["BRIGLIA_TEST_SHARE_WAIT": "1"])
            check("wipe: when the sharing lock is busy, default does not sign out (and says so)",
                  busy["storeSignedIn"] as? Bool == true && ((busy["notes"] as? [String])?.first?.contains("not signed out") ?? false), "\(busy)")
            held.release()
        }
        let defWipe = sharedProbe(nil, "wipe")
        check("wipe: default keeps the login while another extra shares it", defWipe["storeSignedIn"] as? Bool == true, "\(defWipe)")
        _ = run(["--profile", "sa", "subscription", "scope", "own"])
        let lastWipe = sharedProbe(nil, "wipe")
        check("wipe: the last sharer (default, every extra own) signs the machine store out", lastWipe["storeSignedIn"] as? Bool == false, "\(lastWipe)")
        // An own-scope extra's wipe signs its own store out and returns to shared.
        var own = SubscriptionAuthState(generation: UUID().uuidString)
        own.credential = Self.credential("acct-9")
        writeMachineStore(own, dir: URL(fileURLWithPath: configBase + "/briglia-profiles/sb", isDirectory: true))
        let sbWipe = sharedProbe("sb", "wipe")
        check("wipe: an own-scope extra signs its own store out and goes back to shared (protected transition)",
              sbWipe["ownSignedIn"] as? Bool == false && sbWipe["scopeKey"] as? String == "", "\(sbWipe)")
        // Never-multi: byte-identical (no owner fields, same path).
        let data = root.appendingPathComponent("nm3-data"), config = root.appendingPathComponent("nm3-config")
        let nm = ["XDG_DATA_HOME": data.path, "XDG_CONFIG_HOME": config.path]
        let nmBegin = sharedProbe(nil, "begin", extraEnv: nm)
        let raw = (try? String(contentsOfFile: config.path + "/briglia/subscription-auth.json", encoding: .utf8)) ?? ""
        check("never-multi: same store path, no owner fields written",
              nmBegin["storeDir"] as? String == URL(fileURLWithPath: config.path + "/briglia").standardizedFileURL.path
              && !raw.isEmpty && !raw.contains("pendingLoginBy") && !raw.contains("signedInBy"), raw)
        _ = run(["--profile", "sa", "subscription", "scope", "shared"])
    }
}
