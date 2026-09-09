import Foundation

/// Resolved before network suspension; validation, encoding and spend all use
/// this same value even if the service is reconfigured while a request is pending.
struct OpenAIImageOptions {
    static let engines: Set<String> = ["fast", "precise"]
    static let qualities: Set<String> = ["auto", "low", "medium", "high", "xhigh", "max"]
    static let backgrounds: Set<String> = ["auto", "opaque", "transparent"]
    static let formats: Set<String> = ["png", "jpeg", "webp"]
    let engine: String
    let model: String
    let quality: String
    let background: String
    let outputFormat: String
    let notes: [String]

    static func isImage25Family(_ model: String) -> Bool {
        let model = clean(model)
        return ["gpt-image-2.5-flare", "gpt-image-2.5-sunburst"].contains {
            model == $0 || model.hasPrefix($0 + "-202")
        }
    }

    static func supportedQualities(model: String) -> Set<String> {
        isImage25Family(model) ? qualities : qualities.subtracting(["xhigh", "max"])
    }

    static func supportedBackgrounds(model: String) -> Set<String> {
        isImage25Family(model) ? backgrounds : backgrounds.subtracting(["transparent"])
    }

    static func resolve(engine: String? = nil,
                        fastModel: String? = nil, preciseModel: String? = nil,
                        quality: String? = nil, defaultQuality: String = "auto",
                        outputFormat: String? = nil, defaultOutputFormat: String = "png",
                        background: String? = nil) throws -> Self {
        let engine = clean(engine).isEmpty ? "fast" : clean(engine)
        guard engines.contains(engine) else {
            throw OpenAIImageError.invalidOptions("Invalid image engine. Use fast or precise.")
        }
        let configured = clean(engine == "fast" ? fastModel : preciseModel)
        let model = configured.isEmpty
            ? (engine == "fast" ? KeychainHelper.defaultOpenAIImageModel : KeychainHelper.defaultOpenAIImagePreciseModel)
            : configured
        var notes: [String] = []
        let fallbackQuality = qualities.contains(clean(defaultQuality)) ? clean(defaultQuality) : "auto"
        var quality = clean(quality).isEmpty ? fallbackQuality : clean(quality)
        if !qualities.contains(quality) {
            quality = fallbackQuality
            notes.append("Unsupported quality replaced with \(quality).")
        }
        if !supportedQualities(model: model).contains(quality) {
            quality = "high"
            notes.append("The selected model does not support xhigh/max; quality was reduced to high.")
        }
        let fallbackFormat = formats.contains(clean(defaultOutputFormat)) ? clean(defaultOutputFormat) : "png"
        var format = clean(outputFormat).isEmpty ? fallbackFormat : clean(outputFormat)
        if !formats.contains(format) {
            format = fallbackFormat
            notes.append("Unsupported output format replaced with \(format).")
        }
        var background = clean(background).isEmpty ? "auto" : clean(background)
        if !backgrounds.contains(background) {
            background = "auto"
            notes.append("Unsupported background replaced with auto.")
        }
        // Validate the requested combination before any family downgrade.
        if background == "transparent" && format == "jpeg" {
            throw OpenAIImageError.invalidOptions("Transparent backgrounds require output_format png or webp; jpeg cannot store transparency.")
        }
        if !supportedBackgrounds(model: model).contains(background) {
            background = "auto"
            notes.append("Transparent backgrounds are enabled only for GPT Image 2.5; background was changed to auto for this model.")
        }
        return Self(engine: engine, model: model, quality: quality, background: background,
                    outputFormat: format, notes: notes)
    }

    private static func clean(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct OpenAIImageResult {
    let data: Data
    let mimeType: String
    let spendUSD: Double?
    let options: OpenAIImageOptions
    let usage: OpenAIImageUsage?

    /// Used by the actual tool result and its tests. Missing usage/cost stays
    /// unknown; estimates describe reported usage, not an authoritative invoice.
    func toolResultMetadata() -> [String: Any] {
        var fields: [String: Any] = [
            "engine": options.engine, "model": options.model, "quality": options.quality,
            "background": options.background, "output_format": options.outputFormat,
            "notes": options.notes, "usage": NSNull(),
            "estimated_spend_usd": spendUSD as Any? ?? NSNull()
        ]
        if let usage, let data = try? JSONEncoder().encode(usage),
           let object = try? JSONSerialization.jsonObject(with: data) {
            fields["usage"] = object
        }
        return fields
    }

    /// No prompt, reference image, credential or provider response body is logged.
    func telemetry(size: String) -> String {
        let fields: [String: Any] = [
            "model": options.model, "engine": options.engine, "quality": options.quality, "size": size,
            "input_tokens": usage?.inputTokens as Any? ?? NSNull(),
            "text_input_tokens": usage?.inputTokensDetails?.textTokens as Any? ?? NSNull(),
            "image_input_tokens": usage?.inputTokensDetails?.imageTokens as Any? ?? NSNull(),
            "output_tokens": usage?.outputTokens as Any? ?? NSNull(),
            "image_output_tokens": usage?.outputTokensDetails?.imageTokens as Any? ?? NSNull(),
            "text_output_tokens": usage?.outputTokensDetails?.textTokens as Any? ?? NSNull(),
            "estimated_spend_usd": spendUSD as Any? ?? NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "Image usage unavailable" }
        return text
    }
}

extension OpenAIImagePricing {
    static func estimatedSpendUSD(from usage: OpenAIImageUsage?, model: String) -> Double? {
        guard let usage, let pricing = pricing(for: model) else { return nil }
        let text = max(0, usage.inputTokensDetails?.textTokens ?? 0)
        let image = max(0, usage.inputTokensDetails?.imageTokens ?? 0)
        // When modality details are missing, use the higher input rate for the
        // unclassified remainder. This is an estimate, never an exact invoice.
        let unclassified = max(0, (usage.inputTokens ?? 0) - text - image)
        let imageOutput = max(0, usage.outputTokensDetails?.imageTokens
                              ?? max(0, (usage.outputTokens ?? 0) - (usage.outputTokensDetails?.textTokens ?? 0)))
        let textOutput = max(0, usage.outputTokensDetails?.textTokens ?? 0)
        let inputCost = Double(text) * pricing.textInputCostPerMillionTokensUSD
            + Double(image) * pricing.imageInputCostPerMillionTokensUSD
            + Double(unclassified) * max(pricing.textInputCostPerMillionTokensUSD, pricing.imageInputCostPerMillionTokensUSD)
        let outputCost = Double(imageOutput) * pricing.imageOutputCostPerMillionTokensUSD
            + Double(textOutput) * (pricing.textOutputCostPerMillionTokensUSD ?? 0)
        let total = (inputCost + outputCost) / 1_000_000
        return total.isFinite && total > 0 ? total : nil
    }
}
