import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 0.2.71: GPT-6.2 Sol and GPT-6.2 Astra (OpenAI, 2026-11-17) get the GPT
/// editing profile on every route where GPT-6.1 Sol has it, in the tool form
/// each route was probed with that day (private-docs
/// docs/research/GPT_62_PROBE_2026-11-17.md): the freeform grammar tool on
/// api.openai.com with an API key and on OpenRouter's Responses endpoint
/// (probed), and on both ChatGPT sign-in routes (same code path as GPT-6.1
/// Sol; probed on Sign in with ChatGPT that day, NOT on the legacy route);
/// the JSON form on OpenRouter's chat
/// route (probed), OpenCode and custom endpoints.
extension GPTProfileSelftest {
    static let gpt62Models = ["gpt-6.2-sol", "gpt-6.2-astra"]

    static func gpt62Tests(_ t: CPTest) {
        let none: (String) -> Bool = { _ in false }
        func resolve(_ c: ProviderExecutionContext) -> EditingConfig { EditingConfig.resolve(c, switchOn: true, rejected: none) }

        for model in gpt62Models {
            // Detection: the version parser reads 6.2 as major 6.
            for id in [model, "openai/" + model, model + "-2026-11-17", "openai/" + model + ":nitro", model.uppercased(), "azure/openai/" + model] {
                t.check("G matcher accepts \(id)", GPTModelMatcher.isGPT(id))
            }
            t.check("G \(model) is in the subscription catalog and matched (drift)",
                    ResponsesAdapter.subscriptionModelChoices.contains { $0.id == model } && GPTModelMatcher.isGPT(model))

            // Route forms, the same table as GPT-6.1 Sol.
            func legacyContext(_ m: String) -> ProviderExecutionContext {
                var c = responses(m, base: SubscriptionEndpoint.inference); c.subscriptionGeneration = "g1"; return c
            }
            func siwcContext(_ m: String) -> ProviderExecutionContext {
                var c = responses(m, base: SIWCEndpoint.apiBase); c.siwcFailure = "fixture"; return c
            }
            let routes: [(String, (String) -> ProviderExecutionContext, EditingConfig)] = [
                ("legacy ChatGPT route at its pinned endpoint", legacyContext, .gptFreeform),
                ("legacy ChatGPT credential on any other endpoint",
                 { var c = responses($0, base: "https://openrouter.ai/api/v1"); c.subscriptionGeneration = "g1"; return c }, .gptJSON),
                ("Sign in with ChatGPT route", siwcContext, .gptFreeform),
                ("OpenAI key (api.openai.com Responses)", { responses($0, base: "https://api.openai.com/v1") }, .gptFreeform),
                ("OpenRouter Responses server", { responses("openai/" + $0, base: "https://openrouter.ai/api/v1") }, .gptFreeform),
                ("OpenRouter chat", { chat("openai/" + $0) }, .gptJSON),
                ("OpenAI key over Chat Completions", { chat($0, provider: .openAICompatible, endpoint: "https://api.openai.com/v1") }, .gptJSON),
                ("OpenCode Responses", { responses($0, base: "https://opencode.ai/zen/go/v1") }, .gptJSON),
                ("custom endpoint Responses", { responses($0, base: "https://llm.example.com/v1") }, .gptJSON),
                ("custom endpoint chat", { chat($0, provider: .openAICompatible, endpoint: "https://llm.example.com/v1") }, .gptJSON),
            ]
            for (label, make, expected) in routes {
                t.check("G \(model) on \(label) → \(expected == .gptFreeform ? "freeform" : "JSON")", resolve(make(model)) == expected)
                // Parity: GPT-6.1 Sol resolves the same way on the same route.
                t.check("G \(model) on \(label): the same form as GPT-6.1 Sol there", resolve(make("gpt-6.1-sol")) == expected)
            }
            t.check("G \(model): the patch switch off → standard tools on every route",
                    routes.allSatisfy { EditingConfig.resolve($0.1(model), switchOn: false, rejected: none) == .standard })
            let legacy = legacyContext(model), siwc = siwcContext(model)
            t.check("G \(model): a recorded refusal of the freeform form on a route → JSON there, nothing else changes",
                    EditingConfig.resolve(legacy, switchOn: true, rejected: { $0 == GPTPatchRoute.key(legacy) }) == .gptJSON
                    && EditingConfig.resolve(siwc, switchOn: true, rejected: { $0 == GPTPatchRoute.key(legacy) }) == .gptFreeform)
            t.check("G \(model): route keys name the route and the model",
                    GPTPatchRoute.key(legacy) == "chatgpt|" + SubscriptionEndpoint.inference + "|" + model
                    && GPTPatchRoute.key(siwc).hasPrefix("siwc|") && GPTPatchRoute.key(siwc).hasSuffix("|" + model))

            // Wire: the request Briglia builds for the OpenAI key route.
            let gptTools = AvailableTools.all(includeWebSearch: false, editing: .gptFreeform)
            let slot = gptTools.firstIndex { $0.function.name == "apply_patch" } ?? -1
            let input = [ResponsesAdapter.message(role: "system", text: "p"), ResponsesAdapter.message(role: "user", text: "u")]
            func keyContext(_ effort: String?, _ form: EditingConfig) -> ProviderExecutionContext {
                var c = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "synthetic-key", model: model,
                                                              lane: .main, effort: effort)
                c.editing = form
                return c
            }
            if let request = try? ResponsesAdapter(context: keyContext("max", .gptFreeform)).request(input: input, tools: gptTools), let data = request.httpBody {
                let ts = tools(data)
                let object = body(data)
                t.check("G \(model) OpenAI key request: model verbatim, effort max verbatim, Codex grammar tool in apply_patch's slot, every other tool a function",
                        object["model"] as? String == model
                        && (object["reasoning"] as? [String: Any])?["effort"] as? String == "max"
                        && slot >= 0 && slot < ts.count && ts[slot]["type"] as? String == "custom" && ts[slot]["name"] as? String == "apply_patch"
                        && (ts[slot]["format"] as? [String: Any])?["definition"] as? String == GPTFreeform.grammar
                        && (ts[slot]["format"] as? [String: Any])?["syntax"] as? String == "lark"
                        && ts[slot]["description"] as? String == AvailableTools.gptApplyPatchFreeformDescription
                        && ts.enumerated().allSatisfy { $0.offset == slot || $0.element["type"] as? String == "function" }
                        && request.url?.absoluteString == "https://api.openai.com/v1/responses")
            } else { t.check("G \(model) OpenAI key request builds", false) }
            if let data = (try? ResponsesAdapter(context: keyContext("high", .gptJSON)).request(input: input, tools: gptTools))?.httpBody {
                t.check("G \(model) OpenAI key request in the JSON form: apply_patch is a function tool",
                        !tools(data).contains { $0["type"] as? String == "custom" }
                        && tools(data).contains { $0["name"] as? String == "apply_patch" && $0["type"] as? String == "function" })
            } else { t.check("G \(model) OpenAI key JSON request builds", false) }
            // Efforts the model refuses never reach the wire (same local
            // refusal as GPT-6.1 Sol); the five it accepts are sent verbatim.
            for effort in ["none", "minimal"] {
                var message = ""
                do { _ = try ResponsesAdapter(context: keyContext(effort, .gptFreeform)).request(input: input, tools: gptTools) } catch { message = "\(error)" }
                t.check("G \(model): effort \(effort) is refused before sending", message.contains("reasoning effort \(effort) for \(model)"), message)
            }
            for effort in ["low", "medium", "high", "xhigh", "max"] {
                let sent = (try? ResponsesAdapter(context: keyContext(effort, .gptFreeform)).request(input: input, tools: gptTools))?.httpBody.map { body($0) }
                t.check("G \(model): effort \(effort) is sent verbatim", (sent?["reasoning"] as? [String: Any])?["effort"] as? String == effort)
            }

            // Wire: the legacy ChatGPT request, as for GPT-6.1 Sol.
            var legacyWire = ProviderExecutionContext.responsesAPI(baseURL: SubscriptionEndpoint.inference, key: "synthetic-key", model: model,
                                                                   lane: .main, effort: "high")
            legacyWire.subscriptionGeneration = "g1"
            legacyWire.editing = .gptFreeform
            if let request = try? ResponsesAdapter(context: legacyWire).request(input: input, tools: gptTools), let data = request.httpBody {
                let ts = tools(data)
                t.check("G \(model) legacy ChatGPT request: model verbatim, effort verbatim, grammar tool top level in apply_patch's slot, pinned endpoint",
                        body(data)["model"] as? String == model
                        && (body(data)["reasoning"] as? [String: Any])?["effort"] as? String == "high"
                        && slot >= 0 && slot < ts.count && ts[slot]["type"] as? String == "custom"
                        && (ts[slot]["format"] as? [String: Any])?["definition"] as? String == GPTFreeform.grammar
                        && ts.enumerated().allSatisfy { $0.offset == slot || $0.element["type"] as? String == "function" }
                        && request.url?.absoluteString == SubscriptionEndpoint.inference)
            } else { t.check("G \(model) legacy ChatGPT request builds", false) }
        }

        // Spend estimate for the paid OpenAI API (OpenAI pricing page, 2026-11-17).
        t.check("G rates: GPT-6.2 Astra $8 / $40, GPT-6.2 Sol $2 / $10 per million tokens; dated and openai/ ids resolve to the family",
                ResearchSpend.rates(forOpenAIModel: "gpt-6.2-astra") == (8.0, 40.0) && ResearchSpend.rates(forOpenAIModel: "gpt-6.2-sol") == (2.0, 10.0)
                && ResearchSpend.rates(forOpenAIModel: "gpt-6.2-astra-2026-11-17") == (8.0, 40.0)
                && ResearchSpend.rates(forOpenAIModel: "openai/gpt-6.2-sol") == (2.0, 10.0))
        t.check("G rates: the older rows are unchanged and no row shadows another",
                ResearchSpend.rates(forOpenAIModel: "gpt-6-astra") == (10.0, 50.0) && ResearchSpend.rates(forOpenAIModel: "gpt-6-sol") == (2.0, 10.0)
                && ResearchSpend.rates(forOpenAIModel: "gpt-6-luna") == (0.10, 0.50) && ResearchSpend.rates(forOpenAIModel: "gpt-5.6-terra") == (2.0, 12.0)
                && ResearchSpend.rates(forOpenAIModel: "gpt-5.6-luna") == (0.20, 1.20) && ResearchSpend.rates(forOpenAIModel: "gpt-6.1-sol") == (2.0, 12.0)
                && ResearchSpend.rates(forOpenAIModel: "gpt-7-nova") == (2.0, 12.0))
        let near: (Double?, Double) -> Bool = { a, b in a.map { abs($0 - b) < 1e-12 } ?? false }
        t.check("G rates: a GPT-6.2 Astra request of 100,000 input and 10,000 output tokens is estimated at $1.20; above 272K input the surcharge applies",
                near(ResearchSpend.estimate(model: "gpt-6.2-astra", promptTokens: 100_000, completionTokens: 10_000), 1.20)
                && near(ResearchSpend.estimate(model: "gpt-6.2-sol", promptTokens: 300_000, completionTokens: 10_000),
                        (300_000 * 2.0 * WebOrchestrator.openAILargeRequestInputMultiplier + 10_000 * 10.0 * WebOrchestrator.openAILargeRequestOutputMultiplier) / 1_000_000))
    }
}
