import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden battery for the `[Ambient status]` request tail (private-docs
/// BRIGLIA_0253_PLAN v3 §3, Codex v3 corrections 1 and 3):
/// - A: the hardened renderer (one row per job, quoted data, redaction,
///   control/bidi/zero-width stripping, character AND byte caps that never
///   split a redaction placeholder, 20 rows per section, stable order);
/// - R: the role rule from the immutable execution context (system on known
///   OpenAI-family routes only; exact host matching, no substring/suffix);
/// - W: real serializer bodies on every route class (Chat Completions and
///   Responses), captured before any transport: same text everywhere, only
///   the role differs, always the last item, after the tail user message;
///   the context audit shows the same text; a response is still consumed
///   when the system-role note follows a prune-summary request.
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_CONFIG_HOME, XDG_DATA_HOME, CFFIXED_USER_HOME, TMPDIR) under a
/// differently named hard link. Synthetic secrets only.
struct AmbientStatusSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__ambient-status-selftest",
        abstract: "Internal: verify ambient-status rendering, its per-route role and the wire placement.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-ambient"
    static let rootPrefix = "briglia-ambient-status-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else {
            try ASIsolation.reexec(command: "__ambient-status-selftest", linkName: Self.linkName, rootPrefix: Self.rootPrefix, only: only)
            return
        }
        let h = ASHarness(only: only)
        defer { ASFixtures.resetSeams() }
        if h.wants("A") { h.renderSection() }
        if h.wants("R") { h.routeSection() }
        if h.wants("W") { await h.wireSection() }
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) ambient status check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) ambient status checks passed")
    }
}

enum ASIsolation {
    static func reexec(command: String, linkName: String, rootPrefix: String, only: String?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        env.removeValue(forKey: CacheDiagnostics.environmentKey)
        env.removeValue(forKey: ForceDetach.environmentKey)
        env.removeValue(forKey: RoundDelivery.environmentKey)
        env.removeValue(forKey: "BRIGLIA_DEV_AFFINITY_OPENCODE_BASE")
        env.removeValue(forKey: "BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE")
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = [command, "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

final class ASHarness {
    let only: String?
    var total = 0
    var failures = 0
    init(only: String?) { self.only = only }

    func wants(_ section: String) -> Bool { only == nil || only == section }

    func check(_ name: String, _ value: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if value { print("✔ \(name)") } else {
            failures += 1
            let d = detail()
            print("✖ \(name)" + (d.isEmpty ? "" : "\n    \(d)"))
        }
    }
}

/// Synthetic fixtures and seams shared by the ambient and cache-boundary batteries.
enum ASFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Synthetic secrets only (never copied from a log or a screenshot).
    static let secretName = "SYNTH_SERVICE_KEY"
    static let secret = "synthAMBIENTsecret0123456789abcdefXYZ"
    static let redaction = [secretName: secret]
    static var placeholder: String { "[REDACTED:\(secretName)]" }

    static func resetSeams() {
        AmbientStatus.rowsOverrideForTesting = nil
        AmbientStatus.nowOverrideForTesting = nil
        AmbientStatus.redactionEnvironmentForTesting = nil
        AmbientStatus.roleOverrideForTesting = nil
        WireInterceptForTesting.handler = nil
    }

    static func bash(_ id: String, _ command: String, _ description: String? = nil, ago: TimeInterval = 12) -> AmbientStatus.BashRow {
        AmbientStatus.BashRow(id: id, command: command, description: description, startedAt: now.addingTimeInterval(-ago))
    }

    static func subagent(_ id: String, _ type: String, _ description: String, ago: TimeInterval = 30) -> AmbientStatus.SubagentRow {
        AmbientStatus.SubagentRow(id: id, type: type, description: description, startedAt: now.addingTimeInterval(-ago))
    }

    /// Sets fixed rows, clock and redaction for the live request path.
    static func install(bash: [AmbientStatus.BashRow], subagents: [AmbientStatus.SubagentRow]) {
        AmbientStatus.nowOverrideForTesting = now
        AmbientStatus.redactionEnvironmentForTesting = redaction
        AmbientStatus.rowsOverrideForTesting = { (bash, subagents) }
    }

    static func context(_ provider: LLMProvider, endpoint: String, model: String, wire: ProviderWireProtocol,
                        profile: String = "legacy", subscription: Bool = false, anthropic: Bool = false,
                        lane: AffinityLane = .main) -> ProviderExecutionContext {
        var c = ProviderExecutionContext(provider: provider, model: model, endpoint: endpoint,
            authorization: "Bearer synthetic-ambient", affinityKey: "synthetic-ambient", lane: lane,
            provenance: model + (wire == .responses ? "#responses" : ""), providerPreferences: nil, reasoning: nil,
            reasoningEffort: nil, thinkingType: nil, useReasoningContent: false, textOnly: false,
            anthropicCacheControl: anthropic, renderPDFAsImages: true)
        c.wireProtocol = wire
        c.profileIdentity = profile
        if subscription { c.subscriptionGeneration = "synthetic-generation" }
        return c
    }

    /// One route per class of plan §3.3 (as corrected), with the role it must get.
    struct Route {
        let name: String
        let context: ProviderExecutionContext
        let expected: String
    }

    static var routes: [Route] {
        [
            Route(name: "Responses · OpenAI API", context: context(.openAICompatible, endpoint: "https://api.openai.com/v1",
                  model: "gpt-6-luna", wire: .responses, profile: "openai"), expected: "system"),
            Route(name: "Responses · ChatGPT subscription", context: context(.openAICompatible, endpoint: SubscriptionEndpoint.inference,
                  model: "gpt-6-sol", wire: .responses, profile: "chatgpt", subscription: true), expected: "system"),
            Route(name: "Responses · OpenCode Go Luna", context: context(.openAICompatible, endpoint: OpenCodeGo.baseURL,
                  model: "gpt-6-luna", wire: .responses, profile: "opencode"), expected: "system"),
            Route(name: "Responses · unknown custom server (model named gpt-6-luna)", context: context(.openAICompatible,
                  endpoint: "https://responses.example.invalid/v1", model: "gpt-6-luna", wire: .responses, profile: "custom"), expected: "user"),
            Route(name: "Chat · api.openai.com custom profile", context: context(.openAICompatible,
                  endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-6-luna", wire: .chatCompletions, profile: "custom"), expected: "system"),
            Route(name: "Chat · OpenRouter openai/", context: context(.openRouter, endpoint: "https://openrouter.ai/api/v1/chat/completions",
                  model: "openai/gpt-6-luna", wire: .chatCompletions, profile: "openrouter"), expected: "system"),
            Route(name: "Chat · OpenRouter anthropic/", context: context(.openRouter, endpoint: "https://openrouter.ai/api/v1/chat/completions",
                  model: "anthropic/claude-haiku-5.5", wire: .chatCompletions, profile: "openrouter", anthropic: true), expected: "user"),
            Route(name: "Chat · OpenRouter deepseek/", context: context(.openRouter, endpoint: "https://openrouter.ai/api/v1/chat/completions",
                  model: "deepseek/deepseek-v4.1-flash", wire: .chatCompletions, profile: "openrouter"), expected: "user"),
            Route(name: "Chat · OpenCode Go chat model", context: context(.openAICompatible, endpoint: OpenCodeGo.baseURL + "/chat/completions",
                  model: "deepseek-v4.1-flash", wire: .chatCompletions, profile: "opencode"), expected: "user"),
            Route(name: "Chat · named server with an openai/ model", context: context(.openAICompatible,
                  endpoint: "https://gateway.example.invalid/v1/chat/completions", model: "openai/gpt-6-luna", wire: .chatCompletions, profile: "custom"), expected: "user"),
            Route(name: "Chat · local server", context: context(.lmStudio, endpoint: "http://127.0.0.1:1234/v1/chat/completions",
                  model: "local-model", wire: .chatCompletions, profile: "local"), expected: "user"),
        ]
    }

    // MARK: Wire capture

    final class Box: @unchecked Sendable { var value: (String, Data)? }

    /// The final serialized body of one request, aborted before any transport.
    static func capture(_ service: OpenRouterService, _ conversation: PreparedConversation,
                        _ context: ProviderExecutionContext) async -> Data? {
        let box = Box()
        WireInterceptForTesting.handler = { proto, body in box.value = (proto, body) }
        defer { WireInterceptForTesting.handler = nil }
        do {
            if context.wireProtocol == .responses { _ = try await service.generateResponses(conversation, context: context) }
            else { _ = try await service.generateChatCompletion(conversation, context: context) }
        } catch {}
        return box.value?.1
    }

    /// Input items after the leading system prompt (Chat `messages[0]`,
    /// Responses `input[0]` or the subscription's `instructions`).
    static func items(_ body: Data) -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [] }
        var items = ((root["messages"] as? [Any]) ?? (root["input"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        if root["instructions"] == nil, items.first?["role"] as? String == "system" { items.removeFirst() }
        return items
    }

    static func role(_ item: [String: Any]) -> String { item["role"] as? String ?? "other" }

    /// Text of a message item on either protocol.
    static func text(_ item: [String: Any]) -> String {
        if let s = item["content"] as? String { return s }
        return ((item["content"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "\n")
    }

    static func conversation(_ messages: [Message], rounds: [ToolInteraction], tailSystem: String? = nil,
                             tailUser: String? = nil, omitAmbient: Bool = false) -> PreparedConversation {
        let dir = FileManager.default.temporaryDirectory
        var c = PreparedConversation(systemPrompt: "Synthetic ambient-status system prompt", messages: messages,
            imagesDirectory: dir, documentsDirectory: dir, tools: nil, toolResultMessages: rounds,
            tailSystemMessage: tailSystem, tailUserMessage: tailUser)
        c.omitAmbientStatus = omitAmbient
        return c
    }

    static func round(_ n: Int) -> ToolInteraction {
        let call = ToolCall(id: "call_\(n)", type: "function", function: FunctionCall(name: "read_file", arguments: "{\"path\":\"/tmp/f\(n)\"}"))
        return ToolInteraction(assistantMessage: .init(content: nil, toolCalls: [call]),
            results: [ToolResultMessage(toolCallId: "call_\(n)", content: "result \(n)")], measuredTokenCost: nil)
    }
}
