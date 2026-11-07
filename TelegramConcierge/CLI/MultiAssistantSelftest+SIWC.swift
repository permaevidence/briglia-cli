import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Sign in with ChatGPT with several assistants, in real child processes
/// (SIWC plan §3.8 "Scope changes", "Adding an assistant"; §8 several
/// assistants). The children run offline (`BRIGLIA_TEST_SIWC_OFFLINE`).
final class BlockingBox<T>: @unchecked Sendable { var value: T? }

extension ProfileHarness {
    func blocking<T>(_ body: @escaping @Sendable () async throws -> T) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingBox<T>()
        Task.detached { box.value = try? await body(); semaphore.signal() }
        semaphore.wait()
        return box.value
    }

    func extraSecrets(_ name: String) -> [String: String] {
        let file = configBase + "/briglia-profiles/\(name)/secrets.json"
        guard let data = FileManager.default.contents(atPath: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        return object
    }

    func writeExtraSecrets(_ name: String, merging values: [String: String]) {
        let file = URL(fileURLWithPath: configBase + "/briglia-profiles/\(name)/secrets.json")
        var current = extraSecrets(name)
        for (k, v) in values { current[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]) {
            try? data.write(to: file); chmod(file.path, 0o600)
        }
    }

    /// One saved, active SIWC registration in `dir` (offline primitives).
    func siwcSignedIn(_ dir: URL, clientId: String, sub: String) -> String? {
        let store = SIWCStore(directory: dir)
        let paths = SIWCSelftest.hostPaths(root.appendingPathComponent("siwc-host-\(clientId)"), stores: [dir])
        return blocking {
            let outcome = try await SIWCSelftest.signIn(store, paths, clientId: clientId, sub: sub, new: true,
                                                        tokens: SIWCSelftest.tokens("mp-\(clientId)"))
            guard case .saved(_, let generation) = outcome else { return nil }
            return try await store.activate(.init(clientId: clientId, generation: generation, replacementId: nil))
        } ?? nil
    }

    func siwcSection() {
        let offline = ["BRIGLIA_TEST_SIWC_OFFLINE": "1"]
        // Reuses the chatgpt section's extras (the machine allows 8 assistants).
        // 1. own → shared retires the own SIWC store in the journaled transition.
        guard ensureExtra("sa", display: "Sa") else { check("siwc: extra sa", false); return }
        let toOwn = run(["--profile", "sa", "subscription", "scope", "own"], extraEnv: offline)
        check("siwc scope: an extra moves to its own login", toOwn.status == 0, toOwn.out)
        let ownDir = URL(fileURLWithPath: configBase + "/briglia-profiles/sa", isDirectory: true)
        guard let generation = siwcSignedIn(ownDir, clientId: "oaiappScopeX", sub: "sub-scope-x") else { check("siwc: own login fixture", false); return }
        var selection: [String: String] = [:]
        for (k, v) in SIWCSelection.activationDelta(.init(clientId: "oaiappScopeX", sub: "sub-scope-x", generation: generation,
                                                          model: "gpt-6.1-sol", effort: nil, textOnly: false)) { if let v { selection[k] = v } }
        writeExtraSecrets("sa", merging: selection)
        let toShared = run(["--profile", "sa", "subscription", "scope", "shared"], extraEnv: offline)
        let ownStore = SIWCStore(directory: ownDir)
        let record = (try? ownStore.readTokens())?.record("oaiappScopeX")
        let after = extraSecrets("sa")
        check("siwc scope: own → shared succeeds", toShared.status == 0, toShared.out)
        check("siwc scope: the own SIWC registrations are signed out with the attempt's effect mark",
              record?.tokens == nil && record?.lastEffect != nil && record?.generation != generation)
        check("siwc scope: the scope is published and the SIWC selection cleared",
              after[SubscriptionSharing.scopeKey] == nil && SIWCSelection.selectionKeys.allSatisfy { after[$0] == nil }, "\(after.keys.sorted())")
        check("siwc scope: the remote revoke result is reported separately (offline: not confirmed)",
              toShared.out.contains("remote sign-out not confirmed"), toShared.out)
        // 2. An unreadable own SIWC store: nothing is published, the scope stays own.
        guard ensureExtra("sb", display: "Sb") else { check("siwc: extra sb", false); return }
        _ = run(["--profile", "sb", "subscription", "scope", "own"], extraEnv: offline)
        let syDir = URL(fileURLWithPath: configBase + "/briglia-profiles/sb", isDirectory: true)
        _ = siwcSignedIn(syDir, clientId: "oaiappScopeY", sub: "sub-scope-y")
        chmod(SIWCStore(directory: syDir).tokenFile.path, 0o644)
        let refused = run(["--profile", "sb", "subscription", "scope", "shared"], extraEnv: offline)
        chmod(SIWCStore(directory: syDir).tokenFile.path, 0o600)
        check("siwc scope: an unreadable own SIWC store refuses with nothing changed (scope stays own)",
              refused.status != 0 && extraSecrets("sb")[SubscriptionSharing.scopeKey] == SubscriptionSharing.Scope.own.rawValue
              && (try? SIWCStore(directory: syDir).readTokens())?.record("oaiappScopeY")?.tokens != nil, refused.out)
        // 3. profiles add --copy-keys from a default on the SIWC route: selection keys, never a token.
        let machineDir = URL(fileURLWithPath: configBase + "/briglia", isDirectory: true)
        guard let g2 = siwcSignedIn(machineDir, clientId: "oaiappCopyMP", sub: "sub-copy-mp") else { check("siwc: machine login fixture", false); return }
        var defaults: [String: String] = [:]
        for (k, v) in SIWCSelection.activationDelta(.init(clientId: "oaiappCopyMP", sub: "sub-copy-mp", generation: g2,
                                                          model: "gpt-6.1-sol", effort: "high", textOnly: false)) { if let v { defaults[k] = v } }
        let secretsFile = machineDir.appendingPathComponent("secrets.json")
        let original = FileManager.default.contents(atPath: secretsFile.path)
        try? writeDefaultSecrets(defaults)
        // The machine allows 8 assistants: free one slot first (sb is done).
        _ = run(["profiles", "remove", "sb", "--yes", "--no-export"], extraEnv: offline)
        let add = run(["profiles", "add", "sz", "--name", "Sz", "--home", root.appendingPathComponent("home-sz").path, "--copy-keys"], extraEnv: offline)
        let sz = extraSecrets("sz")
        let szText = (try? String(contentsOfFile: configBase + "/briglia-profiles/sz/secrets.json", encoding: .utf8)) ?? ""
        check("siwc copy-keys: profiles add succeeds", add.status == 0, add.out)
        check("siwc copy-keys: the route and SIWC selection keys are copied, bound to the current record",
              sz[ChatGPTRoute.routeKey] == "siwc" && sz[ChatGPTRoute.siwcGenerationKey] == g2
              && sz[ChatGPTRoute.siwcRegistrationKey] == defaults[ChatGPTRoute.siwcRegistrationKey], "\(sz.keys.sorted())")
        check("siwc copy-keys: no token and no runtime credential slot is copied",
              !szText.contains("synthetic-") && sz[KeychainHelper.openAICompatibleApiKeyKey] == nil)
        check("siwc copy-keys: the new extra's selection resolves on the SIWC route", ChatGPTRoute.resolve(stored: sz) != .ambiguous
              && ChatGPTRoute.resolve(stored: sz) != .legacy)
        if let original { try? original.write(to: secretsFile) } else { try? FileManager.default.removeItem(at: secretsFile) }
        _ = try? SIWCStore(directory: machineDir).removeFiles()
    }
}
