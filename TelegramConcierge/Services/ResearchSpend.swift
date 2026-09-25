import Foundation

/// Spend for research requests that run on the MAIN agent's execution
/// context (the Web researcher and the legacy `web_search` loop, owner
/// decision 2026-09-25).
///
/// The main adapters report dollars only where the provider does
/// (OpenRouter's `usage.cost`); the paid OpenAI API returns token counts
/// only, and `ResponsesAdapter` reports nil. Before the research moved to
/// the main transport the web pipeline estimated those calls itself, so
/// paid OpenAI research counted toward tool spend and the daily/monthly
/// limits. This keeps that accounting, locally to research: a reported
/// cost always wins; a paid api.openai.com call without one is estimated
/// from its tokens at the served model's published rates; subscriptions
/// (ChatGPT, OpenCode Go), custom endpoints and local servers stay nil
/// (no per-request dollars we could know).
enum ResearchSpend {
    /// Published api.openai.com rates, $ per 1M tokens (input, output),
    /// checked 2026-09-25 against OpenRouter's pricing for the same OpenAI
    /// endpoints. Hidden reasoning bills as output (already inside
    /// completion/output tokens). Cached input is billed at the full input
    /// rate: erring high is the safe direction for a spend limit.
    static let openAIRates: [(prefix: String, input: Double, output: Double)] = [
        ("gpt-6-astra", 10.0, 50.0),
        ("gpt-6-sol", 2.0, 10.0),
        ("gpt-6-luna", 0.10, 0.50),
        ("gpt-5.6-terra", 2.0, 12.0),
        ("gpt-5.6-sol", 2.0, 10.0),
        ("gpt-5.6-luna", 0.20, 1.20),
        ("gpt-5.5", 5.0, 30.0),
    ]
    /// An OpenAI model missing from the table: priced like the dearest
    /// standard tier above (GPT-5.6 Terra), never at Luna's rate.
    static let unknownOpenAIRates: (input: Double, output: Double) = (2.0, 12.0)

    /// Rates for a native OpenAI model id (an `openai/` prefix is tolerated).
    /// Dated snapshots (`gpt-6-sol-2026-…`) and `-pro` variants resolve to
    /// their family; the table is ordered so no family is a prefix of an
    /// earlier-listed one.
    static func rates(forOpenAIModel model: String) -> (input: Double, output: Double) {
        let id = (model.hasPrefix("openai/") ? String(model.dropFirst("openai/".count)) : model).lowercased()
        for entry in openAIRates where id == entry.prefix || id.hasPrefix(entry.prefix + "-") {
            return (entry.input, entry.output)
        }
        return unknownOpenAIRates
    }

    /// True for a paid OpenAI API context: no subscription login generation,
    /// and either the OpenAI API profile or any endpoint on api.openai.com
    /// (a custom profile pointed there pays the same rates; same host rule
    /// as `ResponsesUsageStore`).
    static func isPaidOpenAI(_ context: ProviderExecutionContext) -> Bool {
        guard context.subscriptionGeneration == nil else { return false }
        return context.profileIdentity == ProviderProfiles.Profile.openai.rawValue
            || URL(string: context.endpoint)?.host?.lowercased() == "api.openai.com"
    }

    /// The spend to record for one research request.
    static func settle(reported: Double?, promptTokens: Int?, completionTokens: Int?,
                       context: ProviderExecutionContext?) -> Double? {
        if let reported, reported.isFinite, reported >= 0 { return reported }
        guard let context, isPaidOpenAI(context) else { return nil }
        return estimate(model: context.model, promptTokens: promptTokens, completionTokens: completionTokens)
    }

    /// Token estimate with the web pipeline's >272K-input surcharge rule
    /// (2x input / 1.5x output for the whole request).
    static func estimate(model: String, promptTokens: Int?, completionTokens: Int?) -> Double? {
        let prompt = Double(promptTokens ?? 0)
        let completion = Double(completionTokens ?? 0)
        let large = (promptTokens ?? 0) > WebOrchestrator.openAILargeRequestInputTokens
        let r = rates(forOpenAIModel: model)
        let input = r.input * (large ? WebOrchestrator.openAILargeRequestInputMultiplier : 1)
        let output = r.output * (large ? WebOrchestrator.openAILargeRequestOutputMultiplier : 1)
        let usd = (prompt * input + completion * output) / 1_000_000
        return usd > 0 ? usd : nil
    }
}
