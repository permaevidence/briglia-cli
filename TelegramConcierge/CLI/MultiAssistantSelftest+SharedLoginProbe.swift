import ArgumentParser
import Foundation

/// Hidden child of `__multi-assistant-selftest` (§25 tests): runs one
/// shared-login operation as the SELECTED profile, inside the harness's
/// scratch roots, and prints one JSON line.
struct SharedLoginProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__shared-login-probe",
        abstract: "Internal: shared ChatGPT login probe for selftests.",
        shouldDisplay: false
    )

    @Argument var action: String
    @Argument var arg: String?

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { print("{\"error\":\"dev only\"}"); return }
        var out: [String: Any] = ["profile": AssistantProfile.selectedName]
        let store = SubscriptionAuthStore()
        out["storeDir"] = store.directory.standardizedFileURL.path
        switch action {
        case "status":
            out["scope"] = SubscriptionSharing.scope().rawValue
            out["protected"] = SubscriptionSharing.protectedStoreDirectories().map { $0.standardizedFileURL.path }
            out["redaction"] = CredentialCatalog.subscriptionRedactionValues().keys.sorted()
            out["sharers"] = SubscriptionSharing.sharers()
        case "refresh":
            // Cross-process refresh: the fake issuer is a counter file.
            let counter = URL(fileURLWithPath: arg ?? "/dev/null")
            guard let state = try store.read() else { out["error"] = "no store"; break }
            do {
                let credential = try await store.credential(generation: state.generation) { old in
                    let handle = try FileHandle(forWritingTo: counter)
                    try handle.seekToEnd(); try handle.write(contentsOf: Data("refresh \(old)\n".utf8)); try handle.close()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    return SubscriptionCredential(access: "access-2", refresh: "refresh-2", expires: Date().addingTimeInterval(3600),
                                                  account: "acct-1", residency: nil)
                }
                out["access"] = credential.access
            } catch { out["error"] = "\(error)" }
        case "resolve":
            do { out["generation"] = try await SubscriptionSharing.resolveGeneration(arg ?? "") } catch { out["error"] = "\(error)" }
            let s = KeychainHelper.loadSnapshot()
            out["boundGeneration"] = s[ProviderProfiles.subscriptionGenerationKey] ?? ""
            out["runtimeSlot"] = s[KeychainHelper.openAICompatibleApiKeyKey] ?? ""
        case "begin":
            do { out["pending"] = try await store.beginLogin() } catch { out["error"] = "\(error)" }
        case "cancel-owned":
            do { out["outcome"] = "\(try await store.cancelOwnedPending())" } catch { out["error"] = "\(error)" }
        case "wipe":
            let r = await SubscriptionSharing.wipe()
            out["failures"] = r.failures
            out["notes"] = r.notes
            out["storeSignedIn"] = ((try? SubscriptionAuthStore(directory: SubscriptionSharing.machineStoreDirectory).read())??.credential) != nil
            out["ownSignedIn"] = ((try? SubscriptionAuthStore(directory: StoragePaths.configRoot).read())??.credential) != nil
            let s = KeychainHelper.loadSnapshot()
            out["binding"] = s[ProviderProfiles.subscriptionGenerationKey] ?? ""
            out["scopeKey"] = s[SubscriptionSharing.scopeKey] ?? ""
        case "set-secrets":
            // arg = JSON object of keys to write into this profile's store.
            if let data = arg?.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
                var changes: [String: String?] = [:]
                for (k, v) in o { changes[k] = v.isEmpty ? String?.none : v }
                try KeychainHelper.saveBatch(changes)
                out["ok"] = true
            }
        case "activate":
            do { try ProviderProfiles.activate(.chatgpt); out["ok"] = true } catch { out["error"] = "\(error)" }
            let s = KeychainHelper.loadSnapshot()
            out["boundGeneration"] = s[ProviderProfiles.subscriptionGenerationKey] ?? ""
            out["fp"] = s[SubscriptionSharing.accountFingerprintKey] ?? ""
        default:
            out["error"] = "unknown action"
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
