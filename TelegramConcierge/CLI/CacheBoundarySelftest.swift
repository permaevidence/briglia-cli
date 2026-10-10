import ArgumentParser
import Foundation

/// Hidden battery for request-to-request cache-boundary continuity
/// (private-docs BRIGLIA_0253_PLAN v3 §3.5, Codex v3 correction 2 and
/// answer 6). Real serializer bodies (Chat Completions and Responses) for
/// one route of each class, captured before any transport, are compared in
/// consecutive pairs. Three properties are reported separately:
/// - stable history: the previous request's non-tail items are an
///   index-aligned prefix of the next one (the 0.2.52 diagnostics contract);
/// - whole input: the previous request's entire input is a prefix;
/// - boundary continuity (a local, conservative check, not proof of a
///   cache hit): system text/instructions, tools and settings identical, and
///   every previous item up to and including its last non-system item is an
///   index-aligned, byte-identical prefix of the next request — i.e. only
///   trailing system items were replaced.
/// Expected values are asserted per route, so widening the role scope is a
/// deliberate, visible change.
struct CacheBoundarySelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__cache-boundary-selftest",
        abstract: "Internal: verify cache-boundary continuity of consecutive requests per route.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else {
            try ASIsolation.reexec(command: "__cache-boundary-selftest", linkName: "briglia-mw-cacheboundary",
                                   rootPrefix: "briglia-cache-boundary-", only: only)
            return
        }
        let h = ASHarness(only: only)
        defer { ASFixtures.resetSeams() }
        await h.boundarySection()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) cache boundary check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) cache boundary checks passed")
    }
}

/// A captured request split for comparison.
struct CBRequest {
    let system: Data
    let items: [Data]
    let roles: [String]
    let envelope: Data
    let tailCount: Int
    let body: Data

    init?(_ body: Data?, tailCount: Int) {
        guard let body, let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        var raw = ((root["messages"] as? [Any]) ?? (root["input"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        if let instructions = root["instructions"] { system = ASHarness.canonical(instructions) }
        else if let first = raw.first, first["role"] as? String == "system" { system = ASHarness.canonical(first); raw.removeFirst() }
        else { system = Data() }
        items = raw.map { ASHarness.canonical($0) }
        roles = raw.map(ASFixtures.role)
        envelope = ASHarness.envelope(body)
        self.tailCount = tailCount
        self.body = body
    }

    /// The shipped diagnostics verdict (CacheDiagnostics.continuity) for
    /// this request followed by `next`, with the whole request retained.
    func production(_ next: CBRequest) -> CacheDiagnostics.Continuity? {
        func parsed(_ r: CBRequest) -> CacheDiagnostics.Parsed? {
            CacheDiagnostics.parse(CacheDiagnostics.Request(lane: "x", protocolName: "x", body: r.body, tailCount: r.tailCount, transitions: []))
        }
        guard let previous = parsed(self), let current = parsed(next) else { return nil }
        let retained = CacheDiagnostics.Retained(parsed: previous, hashed: false, itemLimit: nil, toolLimit: nil,
                                                 originalItems: previous.items.count, originalTools: previous.tools.count)
        return CacheDiagnostics.continuity(previous: retained, current: current)
    }

    /// Previous non-tail items are an index-aligned prefix of `next`.
    func stableHistory(_ next: CBRequest) -> Bool {
        let stable = max(0, items.count - tailCount)
        return next.items.count >= stable && Array(next.items.prefix(stable)) == Array(items.prefix(stable))
    }

    func wholeInput(_ next: CBRequest) -> Bool {
        next.items.count >= items.count && Array(next.items.prefix(items.count)) == items
    }

    func boundary(_ next: CBRequest) -> Bool {
        guard system == next.system, envelope == next.envelope else { return false }
        guard let last = roles.lastIndex(where: { $0 != "system" }) else { return true }
        return next.items.count > last && Array(next.items.prefix(last + 1)) == Array(items.prefix(last + 1))
    }
}

extension ASHarness {

    func boundarySection() async {
        ASFixtures.resetSeams()
        defer { ASFixtures.resetSeams() }
        let service = OpenRouterService()
        let task = Message(role: .user, content: "Synthetic task: build and test")
        let r = (1...4).map(ASFixtures.round)
        let bashAt = { (seconds: TimeInterval) in [ASFixtures.bash("bash_1", "make test", "build", ago: seconds)] }
        let subAt = { (seconds: TimeInterval) in [ASFixtures.subagent("subagent_1", "general-purpose", "scan", ago: seconds)] }

        struct Step {
            var rounds: Int
            var bash: [AmbientStatus.BashRow] = []
            var subagents: [AmbientStatus.SubagentRow] = []
            var tailSystem: String? = nil
            var tailUser: String? = nil
            var systemPrompt: String? = nil
            var effort: String? = nil
            var tailCount: Int {
                (tailSystem == nil ? 0 : 1) + (tailUser == nil ? 0 : 1) + (bash.isEmpty && subagents.isEmpty ? 0 : 1)
            }
        }
        let clock = "Synthetic subagent run clock: started 10:00"
        // (name, N, N+1, expected boundary continuity on OpenAI-family routes, on the others)
        let cases: [(String, Step, Step, Bool, Bool)] = [
            ("S1 no tail → one more round", Step(rounds: 2), Step(rounds: 3), true, true),
            ("S2 constant system run clock → one more round", Step(rounds: 2, tailSystem: clock), Step(rounds: 3, tailSystem: clock), true, true),
            ("S3 ambient (Bash 12 s) → one more round, ambient 13 s", Step(rounds: 2, bash: bashAt(12)), Step(rounds: 3, bash: bashAt(13)), true, false),
            ("S4 ambient → job finished, no ambient", Step(rounds: 2, bash: bashAt(12)), Step(rounds: 3), true, false),
            ("S5 no ambient → job started, ambient", Step(rounds: 2), Step(rounds: 3, bash: bashAt(1)), true, true),
            ("S6 prune-summary user tail → ordinary round (accepted, one-shot)", Step(rounds: 2, tailUser: "Synthetic prune-summary request"), Step(rounds: 3), false, false),
            ("S6b prune-summary user tail + ambient → ordinary round", Step(rounds: 2, bash: bashAt(12), tailUser: "Synthetic prune-summary request"), Step(rounds: 3, bash: bashAt(13)), false, false),
            ("S8 subagent: run clock + ambient → one more round", Step(rounds: 2, subagents: subAt(30), tailSystem: clock), Step(rounds: 3, subagents: subAt(31), tailSystem: clock), true, false),
            ("S9 only the ambient text changes, one appended round", Step(rounds: 3, bash: bashAt(40), subagents: subAt(50)), Step(rounds: 4, bash: bashAt(42), subagents: subAt(52)), true, false),
            ("S10 persona/system prompt changed (no transition)", Step(rounds: 2, systemPrompt: "Prompt A"), Step(rounds: 3, systemPrompt: "Prompt B"), false, false),
            ("S11 settings changed (reasoning effort)", Step(rounds: 2, effort: "low"), Step(rounds: 3, effort: "medium"), false, false),
        ]

        func capture(_ step: Step, _ base: ProviderExecutionContext) async -> CBRequest? {
            ASFixtures.install(bash: step.bash, subagents: step.subagents)
            var context = base
            if let effort = step.effort {
                context = ProviderExecutionContext(provider: base.provider, model: base.model, endpoint: base.endpoint,
                    authorization: base.authorization, affinityKey: base.affinityKey, lane: base.lane, provenance: base.provenance,
                    providerPreferences: base.providerPreferences, reasoning: nil, reasoningEffort: effort, thinkingType: nil,
                    useReasoningContent: false, textOnly: false, anthropicCacheControl: base.anthropicCacheControl, renderPDFAsImages: true,
                    wireProtocol: base.wireProtocol, profileIdentity: base.profileIdentity, nativeToolMedia: base.nativeToolMedia,
                    configurationError: nil, subscriptionGeneration: base.subscriptionGeneration)
            }
            let dir = FileManager.default.temporaryDirectory
            let conversation = PreparedConversation(systemPrompt: step.systemPrompt ?? "Synthetic boundary system prompt",
                messages: [task], imagesDirectory: dir, documentsDirectory: dir, tools: nil,
                toolResultMessages: Array(r.prefix(step.rounds)), tailSystemMessage: step.tailSystem, tailUserMessage: step.tailUser)
            return CBRequest(await ASFixtures.capture(service, conversation, context), tailCount: step.tailCount)
        }

        for route in ASFixtures.routes {
            let family = route.expected == "system"
            for (name, first, second, onFamily, onOthers) in cases {
                guard let n = await capture(first, route.context), let next = await capture(second, route.context) else {
                    check("\(name) · \(route.name): captured", false); continue
                }
                let expected = family ? onFamily : onOthers
                check("\(name) · \(route.name): boundary continuity \(expected ? "✓" : "✗")", n.boundary(next) == expected,
                      "boundary \(n.boundary(next)) whole \(n.wholeInput(next)) stable \(n.stableHistory(next)) roles \(n.roles.suffix(3))")
                // Stable history (0.2.52 contract) holds in every case
                // without a system/settings change; whole input only
                // without any tail.
                if !name.hasPrefix("S10"), !name.hasPrefix("S11") {
                    check("\(name) · \(route.name): stable history holds", n.stableHistory(next))
                }
                let shipped = n.production(next)
                check("\(name) · \(route.name): the log's continuity function agrees (boundary, whole input, no unknowns)",
                      shipped?.boundaryPreserved == n.boundary(next) && shipped?.previousInputPreserved == n.wholeInput(next)
                        && shipped?.unknown == [], "\(String(describing: shipped))")
                if name.hasPrefix("S9"), family {
                    let kept = Array(n.items.dropLast())
                    check("S9 · \(route.name): N's whole input minus its trailing system ambient item is a prefix of N+1, which adds only new items",
                          n.roles.last == "system" && Array(next.items.prefix(kept.count)) == kept
                            && next.roles.last == "system" && next.items.count > kept.count + 1)
                }
                if name.hasPrefix("S1 ") {
                    check("S1 · \(route.name): whole previous input is a prefix", n.wholeInput(next))
                }
            }
            // S7 — forced final: a trailing system instruction, terminal (no next request to compare).
            if let forced = await capture(Step(rounds: 2, tailSystem: "Synthetic: tool calls are disabled, answer now"), route.context) {
                check("S7 · \(route.name): forced final ends with its system tail (n/a: terminal)", forced.roles.last == "system")
            }
        }
    }
}
