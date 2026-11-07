import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Local page source for the real `web_fetch` entry (macOS selftests only):
/// answers r.jina.ai locally and refuses every other URL.
final class SIWCOfflineReader: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "r.jina.ai" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let data = Data(("# Synthetic page\n" + String(repeating: "Local review fixture. ", count: 30)).utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Codex round 2 (CHATGPT_SIWC_IMPL_AB_CODEX_REVIEW_ROUND2_2026-11-06).
extension SIWCSelftest {
    static func round2Tests(_ root: URL, _ c: Checks) async throws {
        let client = "oaiappClientA"
        // R1 error dispositions also preserve a changed record.
        for kind in [SIWCError.Kind.signInRequired, .invalidClient, .transient] {
            let (s, _, g) = try await activeStore(root, tokens: tokens("err-\(kind)", expiresIn: 10))
            _ = try? await s.credential(clientId: client, generation: g) { _ in
                try rewriteBound(s, client) { $0.tokens?.access = "synthetic-replacement" }
                throw SIWCError(kind, "synthetic error")
            }
            c.check("R1 error \(kind): the current record is preserved", s.readTokens_unsafe(client)?.tokens?.access == "synthetic-replacement"
                    && (try? s.validate(clientId: client, generation: g)) != nil)
        }
        // Q3: a usable replacement → "login changed" (terminal, not retried); unusable → sign-in.
        let (sQ, _, gQ) = try await activeStore(root, tokens: tokens("Q3", expiresIn: 10))
        await c.rejectsKind("Q3: a usable replacement ends the operation as 'login changed'", .loginChanged) {
            _ = try await sQ.credential(clientId: client, generation: gQ) { r in
                try rewriteBound(sQ, client) { $0.tokens?.access = "synthetic-replacement-q3" }
                return rotated(r)
            }
        }
        c.check("Q3: 'login changed' is never retried by the adapter or web loops", SIWCError.Kind.loginChanged != .transient)
        #if os(macOS)
        try await webFetchEntryTests(root, c)
        #endif
        try await stageDispatchTests(c)
        try await hostAccessTests(root, c)
    }

    /// R5: the real public `web_fetch` entry (local page, fake inference).
    static func webFetchEntryTests(_ root: URL, _ c: Checks) async throws {
        URLProtocol.registerClass(SIWCOfflineReader.self)
        defer { URLProtocol.unregisterClass(SIWCOfflineReader.self) }
        SIWCModels.resetForTests()
        SIWCModels.fetchOverride = { _ in (Data(#"{"models":[{"slug":"gpt-6-luna","visibility":"list"}]}"#.utf8), 200) }
        // (a) account switch + A tombstoned between the two attempts: no B request.
        let (a, _) = try await liveSelection(clientId: "oaiappFetchA", sub: "fetch-A")
        let wire = Wire()
        ResponsesAdapter.siwcSendOverride = { request in
            wire.lock.lock(); wire.requests.append(request); let n = wire.requests.count; wire.lock.unlock()
            if n == 1 {
                _ = try await liveSelection(clientId: "oaiappFetchB", sub: "fetch-B")
                _ = try await a.store.tombstone(a.clientId)
                return completed(text: nil)
            }
            return completed(text: "RESULT-FROM-B")
        }
        let orchestrator = WebOrchestrator()
        let resultA = try? await orchestrator.readUrlContentWithMetadata(url: "https://example.invalid/review-a", prompt: "Extract the local fixture")
        c.check("R5: one web_fetch never moves to another account after its login was signed out",
                wire.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") != "Bearer synthetic-access-live-oaiappFetchB" }
                && resultA?.result.content != "RESULT-FROM-B")
        // (b) provider switch between attempts: the remaining stage stays on SIWC.
        // A regression would reach the OpenRouter backend: point it at a
        // closed loopback port so nothing can leave this machine.
        setenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE", "http://127.0.0.1:9", 1)
        defer { unsetenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE") }
        let (c1, secrets) = try await liveSelection(clientId: "oaiappFetchC", sub: "fetch-C")
        let wire2 = Wire()
        ResponsesAdapter.siwcSendOverride = { request in
            wire2.lock.lock(); wire2.requests.append(request); let n = wire2.requests.count; wire2.lock.unlock()
            if n == 1 {
                // The web backend moves to OpenRouter (as after /provider openrouter).
                WebSearchBackend.processOverride = .openrouter
                return completed(text: nil)
            }
            return completed(text: "RESULT-ON-C")
        }
        let resultC = try? await WebOrchestrator().readUrlContentWithMetadata(url: "https://example.invalid/review-c", prompt: "Extract the local fixture")
        WebSearchBackend.processOverride = nil
        c.check("R5: a provider switch mid-fetch keeps the captured SIWC route (no other backend)", wire2.count == 2
                && wire2.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access-live-\(c1.clientId)" }
                && resultC?.result.content == "RESULT-ON-C")
        for key in secrets.keys { try? KeychainHelper.delete(key: key) }
    }

    static func stageDispatchTests(_ c: Checks) async throws {
        let (source, secrets) = try await liveSelection(clientId: "oaiappDispatch")
        c.check("R5: stage dispatch keeps a captured SIWC run on SIWC whatever the provider is now",
                WebOrchestrator.stageBackend(.openrouter, capture: .source(source)) == .chatgpt
                && WebOrchestrator.stageBackend(.openai, capture: .failure("x")) == .chatgpt)
        c.check("R5: stage dispatch leaves legacy/other runs on the current backend",
                WebOrchestrator.stageBackend(.openrouter, capture: .notSIWC) == .openrouter && WebOrchestrator.stageBackend(.openai, capture: nil) == .openai)
        for key in secrets.keys { try? KeychainHelper.delete(key: key) }
    }

    /// R8: an inaccessible extras path is uncertain, never "no extras".
    static func hostAccessTests(_ root: URL, _ c: Checks) async throws {
        let empty = root.appendingPathComponent("absent-config")
        try PrivateStorage.ensureDirectory(empty)
        c.check("R8: a genuinely absent extras root still means no extras", SIWCHost.Paths.liveStoreDirectories(environment: ["XDG_CONFIG_HOME": empty.path])?.count == 1)
        let broken = root.appendingPathComponent("broken-config")
        try PrivateStorage.ensureDirectory(broken)
        try FileManager.default.createSymbolicLink(atPath: broken.appendingPathComponent(AssistantProfile.extrasDirName).path,
                                                   withDestinationPath: root.appendingPathComponent("nowhere").path)
        c.check("R8: a broken extras-root link is uncertain", SIWCHost.Paths.liveStoreDirectories(environment: ["XDG_CONFIG_HOME": broken.path]) == nil)
        guard getuid() != 0 else {
            // Permission bits do not restrict root (Linux CI): the two
            // permission rows run on macOS and non-root Linux only.
            c.check("R8: permission rows skipped as root", true)
            return
        }
        let denied = root.appendingPathComponent("denied-parent")
        let config = denied.appendingPathComponent("config")
        try PrivateStorage.ensureDirectory(config.appendingPathComponent(AssistantProfile.extrasDirName))
        chmod(denied.path, 0o000)
        let census = SIWCHost.Paths.liveStoreDirectories(environment: ["XDG_CONFIG_HOME": config.path])
        chmod(denied.path, 0o700)
        c.check("R8: an unsearchable parent makes the census uncertain", census == nil)
        // Production .live removal with a symlinked extras root whose target becomes unsearchable.
        let machine = SIWCStore(directory: MachinePaths.defaultConfigRoot())
        _ = try? await machine.retireAll(); _ = try machine.removeFiles()
        let extra = SIWCStore(directory: AssistantProfile.extraConfigRoot("r2-host"))
        _ = try await signIn(extra, .live, clientId: "oaiappR2Host", new: true, tokens: tokens("r2host"))
        let extras = AssistantProfile.configBase().appendingPathComponent(AssistantProfile.extrasDirName)
        let targetParent = root.appendingPathComponent("external-extras")
        try PrivateStorage.ensureDirectory(targetParent)
        let target = targetParent.appendingPathComponent("profiles")
        try FileManager.default.moveItem(at: extras, to: target)
        try FileManager.default.createSymbolicLink(at: extras, withDestinationURL: target)
        c.check("R8: a reachable symlinked extra keeps the host", try SIWCHost.removeIfUnused(.live, now: extra.nowSeconds) == .keptInUse)
        chmod(targetParent.path, 0o000)
        let outcome = try SIWCHost.removeIfUnused(.live, now: extra.nowSeconds)
        chmod(targetParent.path, 0o700)
        c.check("R8: an inaccessible extras path keeps the host (uncertain)", outcome == .unreadable
                && FileManager.default.fileExists(atPath: SIWCHost.Paths.live.hostFile.path) && (try? extra.readRegistrations()?.registrations.count) == 1)
        try FileManager.default.removeItem(at: extras)
        try FileManager.default.moveItem(at: target, to: extras)
    }
}
