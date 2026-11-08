import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 0.2.68 (owner): `max` reasoning effort for ChatGPT models on BOTH sign-in
/// routes. The capability list is `ResponsesAdapter.allowedEfforts` (GPT-6
/// Sol / Luna / Astra, GPT-6.1 Sol, GPT-5.6 family); `max` is sent verbatim
/// as `reasoning.effort`, like OpenRouter's D11. Legacy-route evidence: the
/// 2026-09-23 subscription probe accepted max for gpt-6-sol/luna and the
/// GPT-6.1 Sol probe. No live evidence yet on the SIWC route (handoff).
extension SIWCSelftest {

    static func maxEffortTests(_ root: URL, _ c: Checks) async throws {
        func effort(_ request: URLRequest) -> String? {
            guard let data = request.httpBody,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return (json["reasoning"] as? [String: Any])?["effort"] as? String
        }
        let maxModels = ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna", "gpt-6-astra"]

        // Capability list (single source for /effort, buttons, /model repair,
        // doctor, setup-api/subscription select, SIWC activate, the menu).
        c.check("max: offered for GPT-6 Sol/Luna/Astra and GPT-6.1 Sol",
                maxModels.allSatisfy { ResponsesAdapter.allowedEfforts(model: $0).last == "max" })
        c.check("max: not offered for a model without it (unknown model keeps xhigh)",
                !ResponsesAdapter.allowedEfforts(model: "o-unknown").contains("max"))
        c.check("max: a saved max survives a switch to another max model; xhigh is kept as xhigh",
                ResponsesAdapter.compatibleEffort("max", model: "gpt-6-luna") == "max"
                && ResponsesAdapter.compatibleEffort("xhigh", model: "gpt-6.1-sol") == "xhigh")
        let buttons = TelegramCommandMenu.effortMenu(levels: ResponsesAdapter.allowedEfforts(model: "gpt-6.1-sol"),
                                                     context: TelegramCommandMenu.effortContext(profile: "chatgpt", model: "gpt-6.1-sol"), current: "high", currentDescription: "high", offAllowed: true)
        c.check("max: the Telegram /effort buttons for a ChatGPT model include max",
                buttons.rows.flatMap { $0 }.contains { $0.label == "max" })

        // Legacy subscription route: verbatim on the wire.
        for model in maxModels {
            let ctx = ProviderExecutionContext(provider: .openAICompatible, model: model, endpoint: "http://127.0.0.1:9/v1/responses",
                authorization: "", affinityKey: "", lane: .ephemeral(UUID()), provenance: model, providerPreferences: nil,
                reasoning: nil, reasoningEffort: "max", thinkingType: nil, useReasoningContent: false, textOnly: false,
                anthropicCacheControl: false, renderPDFAsImages: true)
            let request = try ResponsesAdapter(context: ctx).request(input: [user("hi")], tools: nil)
            c.check("max: legacy route sends reasoning.effort max verbatim (\(model))", effort(request) == "max", "\(effort(request) ?? "nil")")
        }
        let noMax = ProviderExecutionContext(provider: .openAICompatible, model: "o-unknown", endpoint: "http://127.0.0.1:9/v1/responses",
            authorization: "", affinityKey: "", lane: .ephemeral(UUID()), provenance: "o-unknown", providerPreferences: nil,
            reasoning: nil, reasoningEffort: "max", thinkingType: nil, useReasoningContent: false, textOnly: false,
            anthropicCacheControl: false, renderPDFAsImages: true)
        c.check("max: legacy route refuses max for a model without it (nothing sent)",
                (try? ResponsesAdapter(context: noMax).request(input: [user("hi")], tools: nil)) == nil)

        // SIWC route: verbatim on the wire too.
        let (source, _) = try await liveSelection(clientId: "oaiappEffortMax")
        for model in maxModels {
            let ctx = ProviderExecutionContext.siwcContext(source: source, model: model, effort: "max", lane: .main,
                                                           textOnly: false, nativeToolMedia: false)
            let request = try ResponsesAdapter(context: ctx).request(input: [user("hi")], tools: nil)
            c.check("max: SIWC route sends reasoning.effort max verbatim (\(model))", effort(request) == "max", "\(effort(request) ?? "nil")")
        }
        let xhigh = ProviderExecutionContext.siwcContext(source: source, model: "gpt-6.1-sol", effort: "xhigh", lane: .main,
                                                         textOnly: false, nativeToolMedia: false)
        c.check("max: SIWC route keeps a saved xhigh as xhigh",
                effort(try ResponsesAdapter(context: xhigh).request(input: [user("hi")], tools: nil)) == "xhigh")
        let siwcNoMax = ProviderExecutionContext.siwcContext(source: source, model: "o-unknown", effort: "max", lane: .main,
                                                             textOnly: false, nativeToolMedia: false)
        c.check("max: SIWC route refuses max for a model without it (nothing sent)",
                (try? ResponsesAdapter(context: siwcNoMax).request(input: [user("hi")], tools: nil)) == nil)
    }
}
