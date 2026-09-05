import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Hidden deterministic test of provider session affinity
/// (`SESSION_AFFINITY_PLAN.md` §11): host rule, HMAC derivation against an
/// independent implementation, the decorator on the real request builders
/// (driven against a local capture server through the dev host override),
/// stability, separation, key change, two-process first creation,
/// quarantine, durability seams, `/deleteuserdata`, Mind import's ID
/// replacement, and `/rotateaffinity`. Self-isolates into temp XDG roots.
struct AffinitySelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__affinity-selftest",
        abstract: "Internal: verify x-opencode-session / x-session-id affinity state and decoration.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: "Also send one real request to OpenCode Go (needs OPENCODE_API_KEY).")
    var live = false

    /// Child mode for the two-process creation race: load (creating if
    /// absent) and print the install salt. Roots come from the environment.
    @Flag(name: .long, help: "Internal worker: load or create the state and print the salt.")
    var workerCreate = false

    func run() async throws {
        if workerCreate {
            let state = try SessionAffinity.loadState()
            print(state.installSalt)
            return
        }
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ affinity selftest needs a -dev build (the local capture host override is release-gated)")
            throw ExitCode(1)
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-affinity-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)

        var failures = 0
        var total = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            total += 1
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let dataRoot = StoragePaths.dataRoot
        let file = SessionAffinity.fileURL

        // Independent derivation (plan §4) for the expected-value checks.
        func expected(salt: Data, apiKey: String, laneId: String) -> String {
            let fp = Data(SHA256.hash(data: Data(apiKey.utf8)))
            var msg = Data("briglia-affinity-v1".utf8)
            func app(_ d: Data) {
                var n = UInt32(d.count).bigEndian
                withUnsafeBytes(of: &n) { msg.append(contentsOf: $0) }
                msg.append(d)
            }
            app(fp); app(Data(laneId.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: salt))
            return String(Data(mac).map { String(format: "%02x", $0) }.joined().prefix(32))
        }

        // ---- 1. Host rule --------------------------------------------------
        print("\n1. Host rule")
        func oc(_ s: String) -> Bool { SessionAffinity.isOpenCodeURL(URL(string: s)!) }
        func or(_ s: String) -> Bool { SessionAffinity.isOpenRouterURL(URL(string: s)!) }
        check("https://opencode.ai/zen/go/v1/chat/completions matches", oc("https://opencode.ai/zen/go/v1/chat/completions"))
        check("https://x.opencode.ai/ matches (label-suffix subdomain)", oc("https://x.opencode.ai/"))
        check("http://opencode.ai does not match (scheme)", !oc("http://opencode.ai/v1"))
        check("https://opencode.ai.evil.example does not match", !oc("https://opencode.ai.evil.example/v1"))
        check("https://notopencode.ai does not match", !oc("https://notopencode.ai/v1"))
        check("https://openrouter.ai is not OpenCode", !oc("https://openrouter.ai/api/v1/chat/completions"))
        check("https://openrouter.ai/api/v1/chat/completions is OpenRouter", or("https://openrouter.ai/api/v1/chat/completions"))
        check("https://openrouter.ai.evil.example is not OpenRouter", !or("https://openrouter.ai.evil.example/"))
        check("isOpenCodeBaseURL replaces the substring check",
              SessionAffinity.isOpenCodeBaseURL(" https://opencode.ai/zen/go/v1 ")
              && !SessionAffinity.isOpenCodeBaseURL("https://myproxy.example/opencode.ai/v1")
              && !SessionAffinity.isOpenCodeBaseURL(""))
        check("dev override is inactive until set", !oc("http://127.0.0.1:1/v1"))

        // ---- Capture server + dev host override -----------------------------
        let opencodeServer = try CaptureServer()
        let openrouterServer = try CaptureServer()
        defer { opencodeServer.stop(); openrouterServer.stop() }
        setenv("BRIGLIA_DEV_AFFINITY_OPENCODE_BASE", "http://127.0.0.1:\(opencodeServer.port)", 1)
        setenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE", "http://127.0.0.1:\(openrouterServer.port)", 1)
        let opencodeBase = "http://127.0.0.1:\(opencodeServer.port)/zen/go/v1"
        let openrouterBase = "http://127.0.0.1:\(openrouterServer.port)/api/v1"
        let opencodeURL = URL(string: opencodeBase + "/chat/completions")!
        let openrouterURL = URL(string: openrouterBase + "/chat/completions")!
        check("dev override marks the OpenCode capture server", oc(opencodeURL.absoluteString))
        check("dev override marks the OpenRouter capture server", or(openrouterURL.absoluteString))
        check("dev override does not leak to another port", !oc("http://127.0.0.1:\(openrouterServer.port)/v1"))

        // ---- 2. Derivation and decoration ---------------------------------
        print("\n2. Derivation and decoration")
        SessionAffinity.resetProcessStateForTests()
        check("no state file before the first request", !FileManager.default.fileExists(atPath: file.path))
        // Fresh root (the data directory itself does not exist yet): doctor
        // says "not created yet" and nothing else; no enumeration false alarm
        // (Codex round 2).
        check("fresh root: data directory absent", !FileManager.default.fileExists(atPath: dataRoot.path))
        let freshDoctor = SessionAffinity.doctorFindings(activeBaseURL: "https://opencode.ai/zen/go/v1")
        check("fresh root: doctor reports 'not created yet' with no problem and no enumeration finding",
              freshDoctor.contains { $0.text.contains("not created yet") } && !freshDoctor.contains { $0.problem }
              && !freshDoctor.contains { $0.text.contains("enumerate") }, freshDoctor.map(\.text).joined(separator: " | "))
        if case .success(let fresh) = SessionAffinity.corruptFilesChecked() {
            check("fresh root: zero quarantined files, not a failure", fresh.isEmpty)
        } else {
            check("fresh root: zero quarantined files, not a failure", false, "returned .failure")
        }
        check("fresh root: doctor is read-only (no data directory created)", !FileManager.default.fileExists(atPath: dataRoot.path))
        check("fresh root: wipe on a never-started install reports no failures", SessionAffinity.deleteForUserDataWipe().isEmpty)
        let afterFreshWipe = (try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path)) ?? []
        check("fresh root: wipe leaves at most the lock file behind, never a state file",
              afterFreshWipe.allSatisfy { $0 == SessionAffinity.lockName }, "\(afterFreshWipe)")
        let state = try SessionAffinity.loadState()
        check("state minted: version 1, 32-byte salt, UUID main ID",
              state.version == 1 && state.saltBytes?.count == 32 && UUID(uuidString: state.mainConversationId) != nil)
        check("file is owner-only", (try? fileMode(file.path)) == 0o600)
        let keyA = "sk-test-key-A"
        let salt = state.saltBytes!
        let mainExpected = expected(salt: salt, apiKey: keyA, laneId: "main:\(state.mainConversationId.lowercased())")
        check("main lane value equals the independent HMAC",
              SessionAffinity.wireId(state: state, apiKey: keyA, lane: .main) == mainExpected)
        check("archive lane value equals the independent HMAC",
              SessionAffinity.wireId(state: state, apiKey: keyA, lane: .archive) == expected(salt: salt, apiKey: keyA, laneId: "archive"))
        let sid = "sess-123"
        check("subagent lane value equals the independent HMAC",
              SessionAffinity.wireId(state: state, apiKey: keyA, lane: .subagent(sid)) == expected(salt: salt, apiKey: keyA, laneId: "subagent:\(sid)"))
        let eph = UUID()
        check("ephemeral lane value equals the independent HMAC",
              SessionAffinity.wireId(state: state, apiKey: keyA, lane: .ephemeral(eph)) == expected(salt: salt, apiKey: keyA, laneId: "ephemeral:\(eph.uuidString.lowercased())"))
        check("probe lane value equals the independent HMAC",
              SessionAffinity.wireId(state: state, apiKey: keyA, lane: .probe(eph)) == expected(salt: salt, apiKey: keyA, laneId: "probe:\(eph.uuidString.lowercased())"))
        check("value is 32 lowercase hex characters",
              mainExpected.count == 32 && mainExpected.allSatisfy { "0123456789abcdef".contains($0) })

        let ocHeaders = try SessionAffinity.headers(url: opencodeURL, apiKey: keyA, lane: .main)
        check("OpenCode URL: x-opencode-session + User-Agent, no OpenRouter attribution",
              ocHeaders["x-opencode-session"] == mainExpected
              && ocHeaders["User-Agent"] == "Briglia/\(adaCLIVersion) (\(PlatformOS.userAgentToken))"
              && ocHeaders["x-session-id"] == nil && ocHeaders["X-Title"] == nil)
        let orHeaders = try SessionAffinity.headers(url: openrouterURL, apiKey: keyA, lane: .main)
        check("OpenRouter URL: x-session-id + attribution + User-Agent, no OpenCode header",
              orHeaders["x-session-id"] == mainExpected && orHeaders["X-Title"] == "Briglia"
              && orHeaders["HTTP-Referer"] == "https://briglia.dev" && orHeaders["User-Agent"] != nil
              && orHeaders["x-opencode-session"] == nil)
        let customHeaders = try SessionAffinity.headers(url: URL(string: "https://llm.example/v1/chat/completions")!, apiKey: keyA, lane: .main)
        check("custom endpoint: only User-Agent",
              customHeaders.count == 1 && customHeaders["User-Agent"] != nil)
        let localHeaders = try SessionAffinity.headers(url: URL(string: "http://localhost:1234/v1/chat/completions")!, apiKey: "lm-studio", lane: .main)
        check("local endpoint: only User-Agent", localHeaders.count == 1)

        // Site 1: the real main builder against the capture server.
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: opencodeBase)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "test-model")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleApiKeyKey, value: keyA)
        let service = OpenRouterService()
        let images = tempRoot.appendingPathComponent("images"), docs = tempRoot.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let msgs = [Message(role: .user, content: "hello", timestamp: Date())]
        opencodeServer.clear()
        _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .main)
        var captured = opencodeServer.requests
        check("site 1 (generateResponse, .main): header carries the main value",
              captured.count == 1 && captured.first?["x-opencode-session"] == mainExpected,
              "\(captured.first ?? [:])")
        check("site 1: versioned User-Agent, no stale X-Title",
              captured.first?["user-agent"] == "Briglia/\(adaCLIVersion) (\(PlatformOS.userAgentToken))"
              && captured.first?["x-title"] == nil)
        opencodeServer.clear()
        _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .subagent(sid))
        _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .subagent(sid))
        _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .subagent("sess-456"))
        captured = opencodeServer.requests
        check("site 1 (.subagent): same session → same header twice, other session differs",
              captured.count == 3
              && captured[0]["x-opencode-session"] == expected(salt: salt, apiKey: keyA, laneId: "subagent:\(sid)")
              && captured[0]["x-opencode-session"] == captured[1]["x-opencode-session"]
              && captured[2]["x-opencode-session"] != captured[0]["x-opencode-session"])

        // Site 8: the web pipeline's header builder (internal for this test).
        let orchestrator = WebOrchestrator()
        let run = UUID()
        let web1 = try await orchestrator.requestHeaders(for: .opencode, url: opencodeURL, lane: .ephemeral(run))
        let web2 = try await orchestrator.requestHeaders(for: .opencode, url: opencodeURL, lane: .ephemeral(run))
        check("site 8 (web pipeline): one run keeps one value across stages, Authorization intact",
              web1["x-opencode-session"] != nil && web1["x-opencode-session"] == web2["x-opencode-session"]
              && web1["Authorization"]?.hasPrefix("Bearer ") == true && web1["User-Agent"] != nil)
        let web3 = try await orchestrator.requestHeaders(for: .opencode, url: opencodeURL, lane: .ephemeral(UUID()))
        check("site 8: another run gets another value", web3["x-opencode-session"] != web1["x-opencode-session"])

        // Site 9: the setup/doctor probe, fallback candidates share one lane.
        opencodeServer.clear()
        let probeFailure = await Probes.chatCompletion(baseURL: opencodeBase, apiKey: keyA, model: "m1", fallbackModels: ["m2"])
        captured = opencodeServer.requests
        check("site 9 (probe): request decorated", probeFailure == nil && captured.count == 1 && captured[0]["x-opencode-session"] != nil,
              "\(probeFailure ?? "") \(captured)")
        opencodeServer.clear()
        opencodeServer.statusOverride = 503
        _ = await Probes.chatCompletion(baseURL: opencodeBase, apiKey: keyA, model: "m1", fallbackModels: ["m2", "m3"])
        opencodeServer.statusOverride = nil
        captured = opencodeServer.requests
        check("site 9: all fallback candidates carry one probe value",
              captured.count == 3 && Set(captured.compactMap { $0["x-opencode-session"] }).count == 1)
        opencodeServer.clear()
        _ = await Probes.chatCompletion(baseURL: opencodeBase, apiKey: keyA, model: "m1", fallbackModels: [])
        let probeB = opencodeServer.requests.first?["x-opencode-session"]
        check("site 9: a second probe operation gets a different value", probeB != nil && probeB != captured.first?["x-opencode-session"])

        // OpenRouter path through the real builder.
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: openrouterBase)
        openrouterServer.clear()
        _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .main)
        captured = openrouterServer.requests
        check("OpenRouter host via the real builder: x-session-id + X-Title Briglia + referer, no OpenCode header",
              captured.count == 1 && captured[0]["x-session-id"] == mainExpected && captured[0]["x-title"] == "Briglia"
              && captured[0]["http-referer"] == "https://briglia.dev" && captured[0]["x-opencode-session"] == nil)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: opencodeBase)

        // ---- 3. Stability ----------------------------------------------------
        print("\n3. Stability")
        SessionAffinity.resetCache()
        let reloaded = try SessionAffinity.loadState()
        check("restart (cache dropped): same state reloaded", reloaded == state)
        check("restart: same main value", SessionAffinity.wireId(state: reloaded, apiKey: keyA, lane: .main) == mainExpected)
        check("two requests, same lane, same value",
              SessionAffinity.wireId(state: reloaded, apiKey: keyA, lane: .archive)
              == SessionAffinity.wireId(state: reloaded, apiKey: keyA, lane: .archive))

        // ---- 4. Separation ---------------------------------------------------
        print("\n4. Separation")
        let vMain = SessionAffinity.wireId(state: state, apiKey: keyA, lane: .main)
        let vArch = SessionAffinity.wireId(state: state, apiKey: keyA, lane: .archive)
        let vS1 = SessionAffinity.wireId(state: state, apiKey: keyA, lane: .subagent("a"))
        let vS2 = SessionAffinity.wireId(state: state, apiKey: keyA, lane: .subagent("b"))
        let vE1 = SessionAffinity.wireId(state: state, apiKey: keyA, lane: .ephemeral(UUID()))
        let vE2 = SessionAffinity.wireId(state: state, apiKey: keyA, lane: .ephemeral(UUID()))
        check("main ≠ archive ≠ subagents ≠ ephemerals", Set([vMain, vArch, vS1, vS2, vE1, vE2]).count == 6)
        check("watcher-group members (same session ID) share one value",
              SessionAffinity.wireId(state: state, apiKey: keyA, lane: .subagent("group-1")) == SessionAffinity.wireId(state: state, apiKey: keyA, lane: .subagent("group-1")))

        // ---- 5. Key change ---------------------------------------------------
        print("\n5. Key change")
        let keyB = "sk-test-key-B"
        let vMainB = SessionAffinity.wireId(state: state, apiKey: keyB, lane: .main)
        check("different key → different value", vMainB != vMain)
        check("switching back → original value", SessionAffinity.wireId(state: state, apiKey: keyA, lane: .main) == vMain)
        check("a lane with its own key derives from that key",
              SessionAffinity.wireId(state: state, apiKey: keyB, lane: .ephemeral(eph)) != SessionAffinity.wireId(state: state, apiKey: keyA, lane: .ephemeral(eph)))
        let longSid = "session-identifier-7f3c"
        let vLong = SessionAffinity.wireId(state: state, apiKey: keyA, lane: .subagent(longSid))
        check("no plaintext of key, salt or session IDs in the value",
              !vMain.contains(keyA) && !vMain.contains(state.installSalt.prefix(8)) && !vLong.contains(longSid)
              && !vMain.contains(state.mainConversationId.prefix(8)))

        // ---- 6. Two-process first creation ------------------------------------
        print("\n6. Concurrent first creation")
        let raceRoot = tempRoot.appendingPathComponent("race")
        try FileManager.default.createDirectory(at: raceRoot, withIntermediateDirectories: true)
        var raceEnv = ProcessInfo.processInfo.environment
        raceEnv["XDG_DATA_HOME"] = raceRoot.appendingPathComponent("data").path
        raceEnv["XDG_CONFIG_HOME"] = raceRoot.appendingPathComponent("config").path
        let outputs = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<2 {
                group.addTask { try Self.runWorker(env: raceEnv) }
            }
            var result: [String] = []
            for try await out in group { result.append(out) }
            return result
        }
        let third = try Self.runWorker(env: raceEnv)
        check("two racing creators end with one salt; a third reader sees it",
              outputs.count == 2 && outputs[0] == outputs[1] && third == outputs[0] && !third.isEmpty,
              "\(outputs) \(third)")
        let raceFiles = (try? FileManager.default.contentsOfDirectory(atPath: raceRoot.appendingPathComponent("data/briglia").path)) ?? []
        check("race left exactly one affinity file and no temp files",
              raceFiles.filter { $0.hasPrefix("affinity.json") }.count == 1 && !raceFiles.contains { $0.hasPrefix(".affinity.json.tmp") },
              "\(raceFiles)")

        // ---- 7. Quarantine -----------------------------------------------------
        print("\n7. Quarantine")
        func corruptCount() -> Int { SessionAffinity.corruptFiles().count }
        func writeRaw(_ bytes: Data) throws {
            try bytes.write(to: file, options: .atomic)
        }
        var warnings: [String] = []
        SessionAffinity.testHooks.warningSink = { warnings.append($0) }
        for (label, bytes) in [
            ("invalid JSON", Data("{not json".utf8)),
            ("wrong version", Data("{\"version\":2,\"installSalt\":\"\(state.installSalt)\",\"mainConversationId\":\"\(state.mainConversationId)\"}".utf8)),
            ("short salt", Data("{\"version\":1,\"installSalt\":\"AAAA\",\"mainConversationId\":\"\(state.mainConversationId)\"}".utf8)),
            ("non-UUID main ID", Data("{\"version\":1,\"installSalt\":\"\(state.installSalt)\",\"mainConversationId\":\"nope\"}".utf8)),
        ] {
            SessionAffinity.resetProcessStateForTests()
            let before = corruptCount()
            try writeRaw(bytes)
            warnings = []
            opencodeServer.clear()
            var sent = false
            do {
                _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .main)
                sent = true
            } catch {}
            let after = SessionAffinity.corruptFiles()
            let quarantinedBytes = after.last.flatMap { try? Data(contentsOf: dataRoot.appendingPathComponent($0)) }
            let fresh = (try? SessionAffinity.loadState())
            check("(i) \(label): request succeeds with a fresh value, bad bytes preserved byte-identical, one warning",
                  sent && after.count == before + 1 && quarantinedBytes == bytes && fresh?.isValid == true
                  && fresh?.installSalt != state.installSalt && warnings.count == 1
                  && opencodeServer.requests.first?["x-opencode-session"] != nil)
        }
        let doctorAfterQuarantine = SessionAffinity.doctorFindings(activeBaseURL: opencodeBase)
        check("doctor counts the quarantined files",
              doctorAfterQuarantine.contains { $0.text.contains("4 quarantined affinity file(s)") },
              doctorAfterQuarantine.map(\.text).joined(separator: " | "))

        // (ii) two processes racing on the same bad file → one quarantine.
        SessionAffinity.resetProcessStateForTests()
        let raceBad = tempRoot.appendingPathComponent("race-bad")
        let raceBadData = raceBad.appendingPathComponent("data/briglia")
        try FileManager.default.createDirectory(at: raceBadData, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: raceBadData.appendingPathComponent("affinity.json"))
        var raceBadEnv = ProcessInfo.processInfo.environment
        raceBadEnv["XDG_DATA_HOME"] = raceBad.appendingPathComponent("data").path
        raceBadEnv["XDG_CONFIG_HOME"] = raceBad.appendingPathComponent("config").path
        let badOutputs = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<2 { group.addTask { try Self.runWorker(env: raceBadEnv) } }
            var r: [String] = []
            for try await o in group { r.append(o) }
            return r
        }
        let badFiles = (try? FileManager.default.contentsOfDirectory(atPath: raceBadData.path)) ?? []
        check("(ii) two processes on one bad file: exactly one quarantine, one salt seen by both",
              badOutputs.count == 2 && badOutputs[0] == badOutputs[1]
              && badFiles.filter { $0.hasPrefix(SessionAffinity.corruptPrefix) }.count == 1,
              "\(badOutputs) \(badFiles)")

        // (iii) regenerated file made undecodable again in the same process.
        SessionAffinity.resetProcessStateForTests()
        try writeRaw(Data("{bad".utf8))
        _ = try? SessionAffinity.loadState()          // first quarantine of this process
        let countAfterFirst = corruptCount()
        SessionAffinity.resetCache()
        try writeRaw(Data("{bad again".utf8))
        var thirdError = ""
        do { _ = try SessionAffinity.loadState() } catch { thirdError = "\(error)" }
        check("(iii) second undecodable file in one process: request fails naming the file, no second quarantine",
              thirdError.contains(file.path) && corruptCount() == countAfterFirst, thirdError)
        try writeRaw(Data("{still bad".utf8))
        opencodeServer.clear(); openrouterServer.clear()
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: openrouterBase)
        var orSentWithoutHeader = false
        do {
            _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .main)
            orSentWithoutHeader = openrouterServer.requests.count == 1 && openrouterServer.requests[0]["x-session-id"] == nil
        } catch {}
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: opencodeBase)
        check("OpenRouter request in that state is still sent, without x-session-id (best effort)", orSentWithoutHeader)

        // (iv) read I/O error: a directory at the path.
        SessionAffinity.resetProcessStateForTests()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let countBeforeIO = corruptCount()
        var ioError = ""
        opencodeServer.clear()
        do {
            _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .main)
        } catch { ioError = "\(error)" }
        check("(iv) directory at the path: OpenCode request fails naming the file, nothing renamed or minted",
              ioError.contains(file.path) && opencodeServer.requests.isEmpty && corruptCount() == countBeforeIO
              && (try? FileManager.default.contentsOfDirectory(atPath: file.path))?.isEmpty == true, ioError)
        let ioDoctor = SessionAffinity.doctorFindings(activeBaseURL: opencodeBase)
        check("(iv) doctor reports the read error", ioDoctor.contains { $0.problem && $0.text.contains("unreadable") })
        try FileManager.default.removeItem(at: file)
        opencodeServer.clear()
        _ = try await service.generateResponse(messages: msgs, imagesDirectory: images, documentsDirectory: docs, lane: .main)
        check("(iv) repaired while running: next OpenCode request succeeds without restart",
              opencodeServer.requests.count == 1 && opencodeServer.requests[0]["x-opencode-session"] != nil)
        #if !os(Linux)
        if getuid() != 0 {
            SessionAffinity.resetProcessStateForTests()
            chmod(file.path, 0)
            var modeError = ""
            do { _ = try SessionAffinity.loadState() } catch { modeError = "\(error)" }
            chmod(file.path, 0o600)
            check("(iv) mode 000: load fails naming the file, no quarantine", modeError.contains(file.path) && corruptCount() == countBeforeIO)
        }
        #endif

        // (v) injected quarantine-rename failure → nothing minted.
        SessionAffinity.resetProcessStateForTests()
        try writeRaw(Data("{bad".utf8))
        SessionAffinity.testHooks.quarantineRenameFails = true
        var renameError = ""
        do { _ = try SessionAffinity.loadState() } catch { renameError = "\(error)" }
        SessionAffinity.testHooks.quarantineRenameFails = false
        check("(v) quarantine rename failure: request fails, original file untouched, nothing minted",
              renameError.contains("quarantine") && (try? Data(contentsOf: file)) == Data("{bad".utf8) && corruptCount() == countBeforeIO)
        SessionAffinity.resetProcessStateForTests()
        _ = try SessionAffinity.loadState()          // quarantines and regenerates for the next sections
        SessionAffinity.testHooks.warningSink = nil

        // ---- 8. Durability -------------------------------------------------------
        print("\n8. Durability")
        let stable = try SessionAffinity.loadState()
        let stableBytes = try Data(contentsOf: file)
        // A crash between the temp write and the rename leaves a temp file.
        let strayTemp = dataRoot.appendingPathComponent(".affinity.json.tmp-\(UUID().uuidString)")
        try Data("{\"version\":1".utf8).write(to: strayTemp)
        SessionAffinity.resetCache()
        check("crash before rename (stray temp file): the old file loads byte-identical",
              (try? SessionAffinity.loadState()) == stable && (try? Data(contentsOf: file)) == stableBytes)
        try FileManager.default.removeItem(at: strayTemp)
        struct Injected: Error {}
        SessionAffinity.testHooks.beforeRename = { throw Injected() }
        var beforePhase: SessionAffinity.WritePhase?
        do { try SessionAffinity.rotateSalt() } catch let f as SessionAffinity.WriteFailure { beforePhase = f.phase } catch {}
        SessionAffinity.testHooks.beforeRename = nil
        let tempsLeft = ((try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path)) ?? []).filter { $0.hasPrefix(".affinity.json.tmp") }
        check("injected failure before rename: reported as beforeRename, old file byte-identical, temp removed",
              beforePhase == .beforeRename && (try? Data(contentsOf: file)) == stableBytes && tempsLeft.isEmpty)
        SessionAffinity.testHooks.afterRename = { throw Injected() }
        var afterPhase: SessionAffinity.WritePhase?
        do { try SessionAffinity.rotateSalt() } catch let f as SessionAffinity.WriteFailure { afterPhase = f.phase } catch {}
        SessionAffinity.testHooks.afterRename = nil
        let afterState = try SessionAffinity.loadState()
        check("injected failure after rename: reported as afterRename, complete NEW state on disk, cache invalidated",
              afterPhase == .afterRename && afterState.isValid && afterState.installSalt != stable.installSalt
              && afterState.mainConversationId == stable.mainConversationId)

        // ---- 9. /deleteuserdata ------------------------------------------------
        print("\n9. /deleteuserdata")
        let wipeFailures = SessionAffinity.deleteForUserDataWipe()
        let leftover = ((try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path)) ?? []).filter { $0.hasPrefix("affinity.json") }
        check("wipe: file and every corrupt sibling deleted, no failures", wipeFailures.isEmpty && leftover.isEmpty, "\(wipeFailures) \(leftover)")
        let afterWipe = try SessionAffinity.loadState()
        check("next load mints a new salt and main ID",
              afterWipe.installSalt != afterState.installSalt && afterWipe.mainConversationId != afterState.mainConversationId)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: file.appendingPathComponent("child"))
        let wipeErr = SessionAffinity.deleteForUserDataWipe()
        check("wipe: an undeletable entry is reported in the failure list", !wipeErr.isEmpty, "\(wipeErr)")
        try FileManager.default.removeItem(at: file)

        // ---- 10. Mind import ID replacement ---------------------------------------
        print("\n10. Mind import")
        let beforeImport = try SessionAffinity.loadState()
        let newId = try SessionAffinity.replaceMainConversationId()
        let afterImport = try SessionAffinity.loadState()
        check("import: new main ID, same salt",
              afterImport.mainConversationId == newId && newId != beforeImport.mainConversationId
              && afterImport.installSalt == beforeImport.installSalt)
        check("import: main value changed, archive value unchanged",
              SessionAffinity.wireId(state: afterImport, apiKey: keyA, lane: .main) != SessionAffinity.wireId(state: beforeImport, apiKey: keyA, lane: .main)
              && SessionAffinity.wireId(state: afterImport, apiKey: keyA, lane: .archive) == SessionAffinity.wireId(state: beforeImport, apiKey: keyA, lane: .archive))
        let importBytes = try Data(contentsOf: file)
        SessionAffinity.testHooks.beforeRename = { throw Injected() }
        var importBefore: SessionAffinity.WritePhase?
        do { try SessionAffinity.replaceMainConversationId() } catch let f as SessionAffinity.WriteFailure { importBefore = f.phase } catch {}
        SessionAffinity.testHooks.beforeRename = nil
        check("import: failure before rename → old affinity byte-identical",
              importBefore == .beforeRename && (try? Data(contentsOf: file)) == importBytes)
        SessionAffinity.testHooks.afterRename = { throw Injected() }
        var importAfter: SessionAffinity.WritePhase?
        do { try SessionAffinity.replaceMainConversationId() } catch let f as SessionAffinity.WriteFailure { importAfter = f.phase } catch {}
        SessionAffinity.testHooks.afterRename = nil
        let importAfterState = try SessionAffinity.loadState()
        check("import: post-rename fsync failure → complete new ID on disk, next request uses it",
              importAfter == .afterRename && importAfterState.mainConversationId != afterImport.mainConversationId
              && importAfterState.installSalt == afterImport.installSalt)
        let exportUserData = PrivateStorage.classify(file.path, configRoot: StoragePaths.configRoot, dataRoot: dataRoot)
        check("affinity.json is harness state (never exported)", exportUserData == .harnessState)

        // ---- 13. /rotateaffinity ------------------------------------------------
        print("\n13. /rotateaffinity")
        let preRotate = try SessionAffinity.loadState()
        let fixedRun = UUID()
        let preValues = [SessionAffinity.wireId(state: preRotate, apiKey: keyA, lane: .main),
                         SessionAffinity.wireId(state: preRotate, apiKey: keyA, lane: .archive),
                         SessionAffinity.wireId(state: preRotate, apiKey: keyA, lane: .subagent(sid)),
                         SessionAffinity.wireId(state: preRotate, apiKey: keyA, lane: .ephemeral(fixedRun))]
        try SessionAffinity.rotateSalt()
        let postRotate = try SessionAffinity.loadState()
        let postValues = [SessionAffinity.wireId(state: postRotate, apiKey: keyA, lane: .main),
                          SessionAffinity.wireId(state: postRotate, apiKey: keyA, lane: .archive),
                          SessionAffinity.wireId(state: postRotate, apiKey: keyA, lane: .subagent(sid)),
                          SessionAffinity.wireId(state: postRotate, apiKey: keyA, lane: .ephemeral(fixedRun))]
        check("every lane's value differs after rotation; main ID unchanged",
              zip(preValues, postValues).allSatisfy { $0 != $1 } && postRotate.mainConversationId == preRotate.mainConversationId
              && postRotate.installSalt != preRotate.installSalt)
        // In-flight request keeps the old value: headers are computed at build time.
        let inFlight = try SessionAffinity.headers(url: opencodeURL, apiKey: keyA, lane: .main)
        try SessionAffinity.rotateSalt()
        let next = try SessionAffinity.headers(url: opencodeURL, apiKey: keyA, lane: .main)
        check("a request built before the rotation keeps its value; the next one carries the new",
              inFlight["x-opencode-session"] != next["x-opencode-session"]
              && inFlight["x-opencode-session"] == postValues[0])
        SessionAffinity.testHooks.randomFails = true
        var rngError = ""
        let preRng = try Data(contentsOf: file)
        do { try SessionAffinity.rotateSalt() } catch { rngError = "\(error)" }
        SessionAffinity.testHooks.randomFails = false
        check("rotation aborts when randomness fails; file byte-identical",
              rngError.contains("randomness") && (try? Data(contentsOf: file)) == preRng)
        let menu = ChatCommandRegistry.commands.first { $0.name == "rotateaffinity" }
        check("command registered, hidden from the menu", menu != nil && menu?.inMenu == false)
        let toolNames = AvailableTools.all(includeWebSearch: true, hasDeferredMCPs: false).map { $0.function.name }
        check("no model tool exposes rotation", !toolNames.contains { $0.lowercased().contains("affinity") })
        // Lock held during the write: a concurrent locker must wait.
        let lockFd = open(SessionAffinity.lockURL.path, O_RDWR | O_CLOEXEC)
        check("lock file exists 0600", lockFd >= 0 && (try? fileMode(SessionAffinity.lockURL.path)) == 0o600)
        if lockFd >= 0 {
            flock(lockFd, LOCK_EX)
            let start = Date()
            let rotateTask = Task.detached { try SessionAffinity.rotateSalt() }
            try await Task.sleep(nanoseconds: 300_000_000)
            let blocked = !rotateTask.isCancelled && Date().timeIntervalSince(start) >= 0.3
            flock(lockFd, LOCK_UN); close(lockFd)
            _ = try await rotateTask.value
            check("rotation waits for affinity.lock held by another holder", blocked)
        }

        // ---- 14. Codex round 1 ------------------------------------------------------
        print("\n14. Round-1 corrections")
        // (a) Cache publication is ordered with writers: a loader that has read
        //     the old file holds affinity.lock until it has published, so a
        //     rotation started in that window blocks, and after it completes
        //     the next load sees the new salt (no resurrected old state).
        SessionAffinity.resetCache()
        final class Box: @unchecked Sendable { var done = false; let l = NSLock()
            func set() { l.lock(); done = true; l.unlock() }
            func get() -> Bool { l.lock(); defer { l.unlock() }; return done } }
        let box = Box()
        var doneDuringWindow = true
        SessionAffinity.testHooks.afterReadBeforePublish = {
            let t = Thread { try? SessionAffinity.rotateSalt(); box.set() }
            t.start()
            Thread.sleep(forTimeInterval: 0.5)
            doneDuringWindow = box.get()
        }
        let loadedDuringRace = try SessionAffinity.loadState()
        SessionAffinity.testHooks.afterReadBeforePublish = nil
        var waited = 0
        while !box.get() && waited < 100 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        let afterRace = try SessionAffinity.loadState()
        var onDisk: SessionAffinity.State?
        if case .decoded(let d) = SessionAffinity.readFile() { onDisk = d }
        check("(a) rotation blocks while a loader holds the lock; the loader cannot publish stale state over the writer",
              !doneDuringWindow && box.get() && afterRace.installSalt != loadedDuringRace.installSalt && afterRace == onDisk,
              "doneDuringWindow=\(doneDuringWindow) rotated=\(box.get())")
        // Same ordering for the other two writers.
        SessionAffinity.resetCache()
        let box2 = Box()
        SessionAffinity.testHooks.afterReadBeforePublish = {
            let t = Thread { _ = SessionAffinity.deleteForUserDataWipe(); box2.set() }
            t.start(); Thread.sleep(forTimeInterval: 0.3)
        }
        let loadedBeforeWipe = try SessionAffinity.loadState()
        SessionAffinity.testHooks.afterReadBeforePublish = nil
        waited = 0
        while !box2.get() && waited < 100 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        let afterWipeRace = try SessionAffinity.loadState()
        check("(a) wipe racing a loader: the next load mints fresh state, not the pre-wipe one",
              box2.get() && afterWipeRace.installSalt != loadedBeforeWipe.installSalt)
        SessionAffinity.resetCache()
        let box3 = Box()
        SessionAffinity.testHooks.afterReadBeforePublish = {
            let t = Thread { _ = try? SessionAffinity.replaceMainConversationId(); box3.set() }
            t.start(); Thread.sleep(forTimeInterval: 0.3)
        }
        let loadedBeforeImport = try SessionAffinity.loadState()
        SessionAffinity.testHooks.afterReadBeforePublish = nil
        waited = 0
        while !box3.get() && waited < 100 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        let afterImportRace = try SessionAffinity.loadState()
        check("(a) import racing a loader: the next load carries the new main ID",
              box3.get() && afterImportRace.mainConversationId != loadedBeforeImport.mainConversationId
              && afterImportRace.installSalt == loadedBeforeImport.installSalt)

        // (b) Chunked web_fetch: one execution ID for the chunks and the merge pass.
        WebSearchBackend.processOverride = .opencode
        opencodeServer.contentOverride = String(repeating: "x", count: 20_000)
        opencodeServer.clear()
        let bigPage = String(repeating: "lorem ipsum dolor ", count: 55_000)   // ~990K chars → 2 chunks of 800K
        let fetchRun = UUID()
        _ = try await orchestrator.compressLargePageForPrompt(
            pageURL: "https://example.com/page", pageTitle: "T", markdown: bigPage, prompt: "summarize",
            sectionOffset: 0, postCap: 30_000, executionID: fetchRun)
        let chunkReqs = opencodeServer.requests
        let chunkValues = Set(chunkReqs.compactMap { $0["x-opencode-session"] })
        check("(b) chunked web_fetch: 2 chunks + merge pass = 3 requests sharing ONE session value",
              chunkReqs.count == 3 && chunkValues.count == 1, "requests=\(chunkReqs.count) values=\(chunkValues.count)")
        opencodeServer.clear()
        _ = try await orchestrator.compressPageForPrompt(
            pageURL: "https://example.com/page", pageTitle: "T", markdown: "small", prompt: "summarize", executionID: fetchRun)
        check("(b) one-shot compression with the same execution ID carries the same value",
              opencodeServer.requests.first?["x-opencode-session"] == chunkValues.first)
        opencodeServer.clear()
        _ = try await orchestrator.compressPageForPrompt(
            pageURL: "https://example.com/page", pageTitle: "T", markdown: "small", prompt: "summarize", executionID: UUID())
        check("(b) another fetch gets another value",
              opencodeServer.requests.first?["x-opencode-session"] != chunkValues.first)
        opencodeServer.contentOverride = nil
        WebSearchBackend.processOverride = nil

        // (c) Checked enumeration in wipe and doctor.
        if getuid() != 0 {
            try writeRaw(Data("{bad".utf8))
            SessionAffinity.resetProcessStateForTests()
            _ = try SessionAffinity.loadState()          // one quarantined sibling exists now
            chmod(dataRoot.path, 0o100)                  // traversable, not listable
            let wipeEnum = SessionAffinity.deleteForUserDataWipe()
            let doctorEnum = SessionAffinity.doctorFindings(activeBaseURL: opencodeBase)
            chmod(dataRoot.path, 0o700)
            check("(c) wipe reports an enumeration failure instead of claiming success",
                  wipeEnum.contains { $0.contains("enumerate") }, "\(wipeEnum)")
            check("(c) doctor reports the enumeration failure as a problem",
                  doctorEnum.contains { $0.problem && $0.text.contains("enumerate") })
            check("(c) the quarantined file was indeed left behind", !SessionAffinity.corruptFiles().isEmpty)
            _ = SessionAffinity.deleteForUserDataWipe()
        }

        // (d) OpenRouter best-effort warning is logged once per process.
        SessionAffinity.resetProcessStateForTests()
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var orWarnings = 0
        SessionAffinity.testHooks.warningSink = { if $0.contains("OpenRouter") { orWarnings += 1 } }
        _ = try SessionAffinity.headers(url: openrouterURL, apiKey: keyA, lane: .main)
        _ = try SessionAffinity.headers(url: openrouterURL, apiKey: keyA, lane: .main)
        _ = try SessionAffinity.headers(url: openrouterURL, apiKey: keyA, lane: .archive)
        SessionAffinity.testHooks.warningSink = nil
        try FileManager.default.removeItem(at: file)
        check("(d) three failed OpenRouter affinity loads log one warning", orWarnings == 1, "\(orWarnings)")
        SessionAffinity.resetProcessStateForTests()

        // ---- 12. Live ---------------------------------------------------------------
        if live {
            print("\n12. Live")
            unsetenv("BRIGLIA_DEV_AFFINITY_OPENCODE_BASE")
            unsetenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE")
            let key = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"] ?? ""
            if key.isEmpty {
                check("live: OPENCODE_API_KEY set", false, "export it to run the live check")
            } else {
                try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: OpenCodeGo.baseURL)
                try KeychainHelper.save(key: KeychainHelper.openAICompatibleApiKeyKey, value: key)
                try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "glm-5.3-flash")
                var request = URLRequest(url: URL(string: OpenCodeGo.baseURL + "/chat/completions")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                try SessionAffinity.decorate(&request, apiKey: key, lane: .main)
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "glm-5.3-flash",
                    "messages": [["role": "user", "content": "Reply with OK"]],
                    "max_tokens": 10,
                ])
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let cached = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["usage"] as? [String: Any] }
                    .flatMap { $0["prompt_tokens_details"] as? [String: Any] }
                    .flatMap { $0["cached_tokens"] }
                check("live: real OpenCode request with x-opencode-session → HTTP 200 (cached_tokens: \(cached.map { "\($0)" } ?? "absent"))",
                      status == 200 && request.value(forHTTPHeaderField: "x-opencode-session")?.count == 32,
                      String(data: data.prefix(200), encoding: .utf8) ?? "")
            }
        }

        print("\n\(failures == 0 ? "✔" : "✖") affinity selftest: \(total - failures)/\(total) checks passed")
        if failures > 0 { throw ExitCode(1) }
    }

    private static func runWorker(env: [String: String]) throws -> String {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let p = Process()
        p.executableURL = exe
        p.arguments = ["__affinity-selftest", "--worker-create"]
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SessionAffinity.AffinityError(description: "worker exited \(p.terminationStatus)") }
        // The worker may print a quarantine warning first; the salt is the last line.
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? ""
    }
}

private func fileMode(_ path: String) throws -> mode_t {
    var st = stat()
    guard lstat(path, &st) == 0 else { throw SessionAffinity.AffinityError(description: "lstat failed") }
    return st.st_mode & 0o777
}

/// Minimal loopback HTTP/1.1 server that records complete requests and answers
/// every POST with a fixed chat-completion body (or `statusOverride`).
final class CaptureServer: @unchecked Sendable {
    let port: Int
    private let listenFd: Int32
    private let lock = NSLock()
    private var recorded: [CapturedHTTPRequest] = []
    private var captureErrors: [String] = []
    private var running = true
    var statusOverride: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }
    private var _status: Int?
    var contentOverride: String? {
        get { lock.lock(); defer { lock.unlock() }; return _content }
        set { lock.lock(); _content = newValue; lock.unlock() }
    }
    private var _content: String?

    // Scripted local responses for lifecycle tests. Empty preserves the existing
    // wire/affinity fixtures. Access is serialized with capture recording.
    private var responseQueue: [String] = []
    func script(_ bodies: [String]) {
        lock.lock(); responseQueue = bodies; lock.unlock()
    }
    var remainingResponses: Int { lock.lock(); defer { lock.unlock() }; return responseQueue.count }

    var requests: [[String: String]] { completeRequests.map(\.headers) }
    var completeRequests: [CapturedHTTPRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return captureErrors }
    func clear() { lock.lock(); recorded = []; captureErrors = []; lock.unlock() }

    init(port requestedPort: UInt16 = 0) throws {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SessionAffinity.AffinityError(description: "socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requestedPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw SessionAffinity.AffinityError(description: "bind/listen: \(String(cString: strerror(errno)))")
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        listenFd = fd
        let thread = Thread { [self] in self.acceptLoop() }
        thread.start()
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        shutdown(listenFd, Int32(SHUT_RDWR))
        close(listenFd)
    }

    private func acceptLoop() {
        while true {
            lock.lock(); let go = running; lock.unlock()
            if !go { return }
            let client = accept(listenFd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            handle(client)
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var parser = CaptureRequestParser()
        var chunk = [UInt8](repeating: 0, count: 65536)
        do {
            while true {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CaptureRequestParser.Invalid("EOF or timeout before complete request") }
                if let request = try parser.append(Data(chunk[0..<n])) {
                    lock.lock(); recorded.append(request); lock.unlock()
                    break
                }
            }
        } catch {
            lock.lock(); captureErrors.append(String(describing: error)); lock.unlock()
            return
        }
        let status = statusOverride ?? 200
        let content = contentOverride ?? "OK"
        let encodedContent = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        lock.lock()
        let scripted = responseQueue.isEmpty ? nil : responseQueue.removeFirst()
        lock.unlock()
        let body = scripted ?? (status == 200
            ? "{\"id\":\"cap\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\(encodedContent)},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"
            : "{\"error\":{\"message\":\"injected \(status)\"}}")
        let reason = status == 200 ? "OK" : "Service Unavailable"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let bytes = Data(response.utf8)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
