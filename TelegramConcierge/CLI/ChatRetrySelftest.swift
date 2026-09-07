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

/// HTTP 413 in the shared chat request loop: retried with identical bytes on
/// OpenCode hosts only, on its own longer schedule; fatal at once on every
/// other host; the generic retry cap unchanged; the mid-turn annotation rides
/// every attempt; cancellation during the wait. Drives the real request
/// builder against local capture servers through the development host
/// override. Self-isolates into temp XDG roots before touching anything.
struct ChatRetrySelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__chat-retry-selftest",
        abstract: "Internal: verify the OpenCode-only HTTP 413 retry in the chat request loop.",
        shouldDisplay: false
    )

    private final class Decisions: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [(status: Int, attempt: Int, delay: TimeInterval)] = []
        func record(_ status: Int, _ attempt: Int, _ delay: TimeInterval) {
            lock.lock(); rows.append((status, attempt, delay)); lock.unlock()
        }
        func take() -> [(status: Int, attempt: Int, delay: TimeInterval)] {
            lock.lock(); defer { rows = []; lock.unlock() }; return rows
        }
    }

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Needs a development build") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-chat-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, child) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(name, root.appendingPathComponent(child).path, 1)
        }
        UserDefaults.standard.setVolatileDomain([
            "ada.applyPatchEnabled": false, "ada.shortcutsEnabled": false,
            KeychainHelper.serviceKeysMetadataDefaultsKey: Data("[]".utf8)
        ], forName: UserDefaults.argumentDomain)

        var total = 0
        var failures = 0
        func check(_ name: String, _ value: Bool, _ detail: String = "") {
            total += 1
            if !value { failures += 1 }
            print("\(value ? "✔" : "✖") \(name)\(value || detail.isEmpty ? "" : " — \(detail)")")
        }

        // ---- Hosts: OpenCode and OpenRouter through the dev override, one
        // plain loopback that matches neither rule (a custom endpoint).
        let opencodeServer = try CaptureServer()
        let openrouterServer = try CaptureServer()
        let customServer = try CaptureServer()
        defer { opencodeServer.stop(); openrouterServer.stop(); customServer.stop() }
        setenv("BRIGLIA_DEV_AFFINITY_OPENCODE_BASE", "http://127.0.0.1:\(opencodeServer.port)", 1)
        setenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE", "http://127.0.0.1:\(openrouterServer.port)", 1)
        defer {
            unsetenv("BRIGLIA_DEV_AFFINITY_OPENCODE_BASE")
            unsetenv("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE")
        }
        let opencodeBase = "http://127.0.0.1:\(opencodeServer.port)/zen/go/v1"
        let openrouterBase = "http://127.0.0.1:\(openrouterServer.port)/api/v1"
        let customBase = "http://127.0.0.1:\(customServer.port)/v1"

        print("1. Host rule")
        func req(_ s: String) -> URLRequest { URLRequest(url: URL(string: s)!) }
        check("1.1 opencode.ai apex and subdomain over https are OpenCode",
              OpenRouterService.isOpenCodeRequest(req("https://opencode.ai/zen/go/v1/chat/completions"))
              && OpenRouterService.isOpenCodeRequest(req("https://api.opencode.ai/v1/chat/completions")))
        check("1.2 look-alikes are not: path mention, label prefix, plain http, OpenRouter, custom loopback",
              !OpenRouterService.isOpenCodeRequest(req("https://evil.example/opencode.ai/v1/chat/completions"))
              && !OpenRouterService.isOpenCodeRequest(req("https://notopencode.ai/v1/chat/completions"))
              && !OpenRouterService.isOpenCodeRequest(req("http://opencode.ai/v1/chat/completions"))
              && !OpenRouterService.isOpenCodeRequest(req("https://openrouter.ai/api/v1/chat/completions"))
              && !OpenRouterService.isOpenCodeRequest(req(customBase + "/chat/completions")))
        check("1.3 dev override marks only the OpenCode capture server",
              OpenRouterService.isOpenCodeRequest(req(opencodeBase + "/chat/completions"))
              && !OpenRouterService.isOpenCodeRequest(req(openrouterBase + "/chat/completions")))

        print("\n2. Schedule")
        var scheduleOK = true
        var scheduleSum = 0.0
        for attempt in 1...5 {
            let base = OpenRouterService.oversizedBodyBaseDelays[attempt - 1]
            let d = OpenRouterService.oversizedBodyRetryDelay(forAttempt: attempt)
            scheduleSum += d
            if d < base || d > base + OpenRouterService.oversizedBodyRetryJitter { scheduleOK = false }
        }
        check("2.1 413 delays follow 2/4/8/12/16 s (+≤0.5 s jitter each)", scheduleOK)
        check("2.2 five waits span 42–44.5 s", scheduleSum >= 42 && scheduleSum <= 44.5, String(format: "%.2f", scheduleSum))
        let clamped = OpenRouterService.oversizedBodyRetryDelay(forAttempt: 9)
        check("2.3 attempts past the table clamp to the last delay", clamped >= 16 && clamped <= 16.5)
        check("2.4 six attempts total", OpenRouterService.oversizedBodyMaxAttempts == 6)
        check("2.5 body size formatting", OpenRouterService.formatBytes(5_812_345) == "5.54 MiB"
              && OpenRouterService.formatBytes(12) == "12 bytes")
        let exhausted = OpenRouterService.oversizedBodyExhaustedMessage(bodyBytes: 5_812_345, attempts: 6, upstream: "x")
        check("2.6 exhausted message names the cause, the body size and the way out",
              exhausted.hasPrefix("HTTP 413: ") && exhausted.contains("4.5 MiB") && exhausted.contains("5.54 MiB")
              && exhausted.contains("Send the message again") && exhausted.contains("/prune") && exhausted.hasSuffix("Provider said: x"))

        // ---- Real builder: provider = OpenAI-compatible, host decides.
        try KeychainHelper.save(key: KeychainHelper.llmProviderKey, value: LLMProvider.openAICompatible.rawValue)
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleModelKey, value: "glm-5.3-flash")
        try KeychainHelper.save(key: KeychainHelper.openAICompatibleApiKeyKey, value: "synthetic-413-key")
        try KeychainHelper.save(key: KeychainHelper.textOnlyModelEnabledKey, value: "false")
        let service = OpenRouterService()
        func context(_ base: String) async throws -> ProviderExecutionContext {
            try KeychainHelper.save(key: KeychainHelper.openAICompatibleBaseURLKey, value: base)
            return await service.executionContext(modelOverride: nil, providerOverride: nil,
                reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main)
        }
        let opencodeContext = try await context(opencodeBase)
        let openrouterContext = try await context(openrouterBase)
        let customContext = try await context(customBase)

        // A tool round carrying a mid-turn annotation: the rendered nonce must
        // ride every attempt unchanged (identical bytes), so the caller's
        // carried-check clears the batch exactly once, on the attempt that
        // succeeds.
        let human = Message(role: .user, content: "Keep the human instruction")
        let nonce = "0123456789abcdef0123456789abcdef"
        let annotation = try HarnessAnnotation.makeDirectUserBatch(
            deliveryNonce: nonce,
            messages: [.init(sourceMessageId: human.id, content: human.content, attachmentPaths: [])]
        )
        var toolResult = ToolResultMessage(toolCallId: "r413-call", content: "Observed a large screenshot")
        toolResult.harnessAnnotations = [annotation]
        let toolCall = ToolCall(id: "r413-call", type: "function", function: FunctionCall(name: "read_file", arguments: "{}"))
        let round = ToolInteraction(assistantMessage: .init(content: nil, toolCalls: [toolCall]), results: [toolResult], measuredTokenCost: nil)
        let conversation = PreparedConversation(systemPrompt: "Synthetic 413 prompt",
            messages: [human], imagesDirectory: root, documentsDirectory: root,
            tools: nil, toolResultMessages: [round], tailSystemMessage: nil, tailUserMessage: nil)

        let ok = #"{"choices":[{"message":{"role":"assistant","content":"Visible answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2}}"#
        let refused = #"{"error":{"message":"Upstream request failed: [invalid_request_error] Request body exceeds the 4.5 MiB limit.","type":"invalid_request_error"}}"#
        let unavailable = #"{"error":{"message":"injected 503"}}"#
        func body(for status: Int) -> String { status == 200 ? ok : (status == 413 ? refused : unavailable) }

        let decisions = Decisions()
        OpenRouterService.chatRetryTestHooks.retrySink = { decisions.record($0, $1, $2) }
        OpenRouterService.chatRetryTestHooks.sleepScale = 0.01
        defer { OpenRouterService.chatRetryTestHooks = .init() }

        func drive(_ server: CaptureServer, _ ctx: ProviderExecutionContext, _ statuses: [Int]) async -> (text: String?, error: String?) {
            server.clear()
            _ = decisions.take()
            server.script(statuses.map(body(for:)), statuses: statuses)
            do {
                let answer = try await service.generateChatCompletion(conversation, context: ctx)
                if case .text(let text, _, _, _, _, _, _) = answer { return (text, nil) }
                return (nil, "unexpected response shape")
            } catch OpenRouterError.apiError(let message) {
                return (nil, message)
            } catch {
                return (nil, "unexpected error: \(error)")
            }
        }
        func bodies(_ server: CaptureServer) -> [Data] { server.completeRequests.map(\.body) }
        func nonceCount(_ data: Data) -> Int {
            let text = String(decoding: data, as: UTF8.self)
            return text.components(separatedBy: nonce).count - 1
        }

        print("\n3. OpenCode host")
        var result = await drive(opencodeServer, opencodeContext, [413, 413, 200])
        var captured = bodies(opencodeServer)
        var rows = decisions.take()
        check("3.1 413, 413, 200 → answer on attempt 3, exactly three requests",
              result.text == "Visible answer" && captured.count == 3, "\(result) \(captured.count) \(opencodeServer.errors)")
        check("3.2 all three bodies byte-identical (same prepared request, no re-serialization)",
              captured.count == 3 && Set(captured).count == 1)
        // The typed annotation renders as one BEGIN/END delimited block, so
        // the nonce appears exactly twice per body; the same count on every
        // attempt proves the batch rides each retry unchanged.
        check("3.3 the mid-turn annotation (one BEGIN/END block, nonce twice) rides every attempt",
              captured.count == 3 && captured.allSatisfy { nonceCount($0) == 2 }, "\(captured.map(nonceCount))")
        check("3.4 every attempt carries the same Authorization and x-opencode-session",
              Set(opencodeServer.requests.map { $0["authorization"] ?? "" }) == ["Bearer synthetic-413-key"]
              && Set(opencodeServer.requests.compactMap { $0["x-opencode-session"] }).count == 1
              && opencodeServer.requests.count == 3)
        check("3.5 two 413 retry decisions on the 413 schedule (attempt 1 → 2 s, attempt 2 → 4 s)",
              rows.count == 2 && rows[0].status == 413 && rows[0].attempt == 1 && rows[0].delay >= 2 && rows[0].delay <= 2.5
              && rows[1].status == 413 && rows[1].attempt == 2 && rows[1].delay >= 4 && rows[1].delay <= 4.5, "\(rows)")

        result = await drive(opencodeServer, opencodeContext, Array(repeating: 413, count: 6))
        captured = bodies(opencodeServer)
        rows = decisions.take()
        check("3.6 413 ×6 → failure after exactly six requests",
              result.text == nil && captured.count == 6, "\(result) \(captured.count)")
        check("3.7 exhausted error names the cause, size and way out, and carries the provider text",
              (result.error ?? "").hasPrefix("HTTP 413: OpenCode's fallback route refuses requests over 4.5 MiB")
              && (result.error ?? "").contains("all 6 attempts") && (result.error ?? "").contains("/prune")
              && (result.error ?? "").contains("Request body exceeds the 4.5 MiB limit"), result.error ?? "")
        let delays = rows.map(\.delay)
        check("3.8 five waits on the 413 schedule spanning 42–44.5 s (before test scaling)",
              rows.count == 5 && rows.allSatisfy { $0.status == 413 } && rows.map(\.attempt) == [1, 2, 3, 4, 5]
              && zip(delays, OpenRouterService.oversizedBodyBaseDelays).allSatisfy { $0 >= $1 && $0 <= $1 + 0.5 }
              && delays.reduce(0, +) >= 42 && delays.reduce(0, +) <= 44.5, "\(delays)")
        check("3.9 six bodies still byte-identical", captured.count == 6 && Set(captured).count == 1)

        result = await drive(opencodeServer, opencodeContext, [413, 503, 200])
        rows = decisions.take()
        check("3.10 413 then 503 then 200: both schedules interleave, answer on attempt 3",
              result.text == "Visible answer" && bodies(opencodeServer).count == 3
              && rows.map(\.status) == [413, 503] && rows[1].delay >= 2 && rows[1].delay <= 2.25, "\(result) \(rows)")

        result = await drive(opencodeServer, opencodeContext, [503, 503, 503, 503])
        rows = decisions.take()
        check("3.11 generic statuses keep their four-attempt cap on OpenCode too",
              result.text == nil && (result.error ?? "").hasPrefix("HTTP 503: ") && bodies(opencodeServer).count == 4
              && rows.map(\.status) == [503, 503, 503], "\(result) \(rows)")

        result = await drive(opencodeServer, opencodeContext, [503, 413, 413, 413, 413, 413])
        rows = decisions.take()
        check("3.12 shared attempt counter: one 503 then 413s stop at the sixth request",
              result.text == nil && (result.error ?? "").hasPrefix("HTTP 413: OpenCode's fallback route")
              && bodies(opencodeServer).count == 6 && rows.map(\.status) == [503, 413, 413, 413, 413], "\(result) \(rows)")

        print("\n4. Other hosts: 413 stays fatal on the first hit")
        result = await drive(customServer, customContext, [413, 200])
        rows = decisions.take()
        check("4.1 custom endpoint: one request, unchanged generic error, no retry decision",
              result.text == nil && result.error == "HTTP 413: Upstream request failed: [invalid_request_error] Request body exceeds the 4.5 MiB limit."
              && bodies(customServer).count == 1 && rows.isEmpty && customServer.remainingResponses == 1, "\(result) \(rows)")
        result = await drive(openrouterServer, openrouterContext, [413, 200])
        rows = decisions.take()
        check("4.2 OpenRouter host: one request, unchanged generic error, no retry decision",
              result.text == nil && (result.error ?? "").hasPrefix("HTTP 413: Upstream request failed")
              && !(result.error ?? "").contains("/prune") && bodies(openrouterServer).count == 1 && rows.isEmpty
              && openrouterServer.requests.first?["x-session-id"] != nil, "\(result) \(rows)")
        result = await drive(customServer, customContext, [503, 200])
        rows = decisions.take()
        check("4.3 custom endpoint: 503 retry unchanged (two requests, answer)",
              result.text == "Visible answer" && bodies(customServer).count == 2 && rows.map(\.status) == [503])

        print("\n5. Cancellation during the 413 wait")
        OpenRouterService.chatRetryTestHooks.sleepScale = 1 // real 2 s wait after the first 413
        opencodeServer.clear()
        _ = decisions.take()
        opencodeServer.script([refused, ok], statuses: [413, 200])
        let cancelled = Task { () -> Bool in
            do {
                _ = try await service.generateChatCompletion(conversation, context: opencodeContext)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let deadline = Date().addingTimeInterval(3)
        while decisions.take().isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let firstSeen = opencodeServer.completeRequests.count
        cancelled.cancel()
        let wasCancelled = await cancelled.value
        try await Task.sleep(nanoseconds: 300_000_000)
        check("5.1 /stop during the 413 wait surfaces CancellationError",
              wasCancelled && firstSeen == 1, "cancelled=\(wasCancelled) firstSeen=\(firstSeen)")
        check("5.2 no further request is sent after cancellation",
              opencodeServer.completeRequests.count == 1 && opencodeServer.remainingResponses == 1,
              "\(opencodeServer.completeRequests.count) \(opencodeServer.remainingResponses)")
        OpenRouterService.chatRetryTestHooks.sleepScale = 0.01

        print("\n\(failures == 0 ? "✔" : "✖") chat retry selftest: \(total - failures)/\(total) checks passed")
        if failures > 0 { throw ExitCode(1) }
    }
}
