import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Restart with a pending checkpoint that must NOT be promoted (plan §7
/// step 4): old generation, blocked login, another account, another token.
/// Records are injected as raw JSON, as a crash would leave them.
extension RefreshSettleSelftest {
    func checkpointTests(_ h: Harness, _ c: Checks) async throws {
        for variant in ["old-generation", "blocked", "other-account", "other-token"] {
            try await staleCheckpoint(h, c, variant)
        }
        try await checkpointRedactedAndValidated(h, c)
    }

    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(("briglia-refresh-op\u{0}" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func inject(_ store: SubscriptionAuthStore, _ edit: (inout [String: Any]) -> Void) throws {
        var object = disk(store)
        edit(&object)
        _ = try PrivateStorage.writeAtomically(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: store.file)
    }

    static func checkpoint(generation: String, replaces: String, account: String = "account-A") -> [String: Any] {
        ["generation": generation, "replaces": fingerprint(replaces),
         "credential": ["access": "pending-access", "refresh": "pending-refresh",
                        "expires": Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate, "account": account]]
    }

    func staleCheckpoint(_ h: Harness, _ c: Checks, _ variant: String) async throws {
        let s = try await h.scenario("stale-checkpoint-\(variant)")
        try Self.inject(s.store) { state in
            let generation = variant == "old-generation" ? UUID().uuidString : s.generation
            state["pendingRotation"] = Self.checkpoint(generation: generation, replaces: variant == "other-token" ? "r-other" : "r0",
                                                       account: variant == "other-account" ? "account-B" : "account-A")
            if variant == "blocked" { state["requiresLogin"] = true }
        }
        let result = await Self.outcome(s)
        let promoted = Self.diskRefresh(s.store) == "pending-refresh"
        if variant == "blocked" {
            c.check("checkpoint on a blocked login: not promoted, nothing sent", !promoted && result.hasPrefix("error:") && s.server.sends() == 0)
        } else if variant == "other-account" {
            // Bound to this login and token but failing revalidation: the
            // rotation happened for the wrong account → sign-in required.
            c.check("checkpoint (other-account): never promoted, login blocked, nothing sent",
                    !promoted && result.hasPrefix("error:") && Self.diskBlocked(s.store) && s.server.sends() == 0)
        } else {
            c.check("checkpoint (\(variant)): discarded, never promoted", !promoted && Self.disk(s.store)["pendingRotation"] == nil)
            c.check("checkpoint (\(variant)): ordinary refresh instead", result == "ok:" + s.server.current() && s.server.sends() == 1)
        }
    }

    func checkpointRedactedAndValidated(_ h: Harness, _ c: Checks) async throws {
        let store = SubscriptionAuthStore()
        let pending = try await store.beginLogin()
        var credential = SubscriptionSelftest.credential(); credential.refresh = "r0"
        let generation = try await store.commitLogin(credential, pending: pending)
        try Self.inject(store) { $0["pendingRotation"] = Self.checkpoint(generation: generation, replaces: "r0") }
        let values = CredentialCatalog.subscriptionRedactionValues()
        c.check("checkpoint tokens are redacted like the active ones", Set(values.values).isSuperset(of: ["pending-access", "pending-refresh", "r0"]))
        try Self.inject(store) { $0["refreshOp"] = ["opId": "not-a-uuid", "tokenFingerprint": "x", "generation": generation,
                                                    "startedAt": 0, "state": "sending"] }
        var refused = false
        do { _ = try store.read() } catch { refused = true }
        c.check("malformed refresh record fails closed (preserved, not overwritten)", refused)
        try FileManager.default.removeItem(at: store.file)
    }
}
