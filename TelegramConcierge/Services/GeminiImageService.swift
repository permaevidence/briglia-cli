import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ImageGenerationProvider: String, CaseIterable, Identifiable {
    case gemini
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI Images"
        }
    }

    var toolName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openAI: return "OpenAI Images"
        }
    }

    static func fromStoredValue(_ rawValue: String?) -> ImageGenerationProvider {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case ImageGenerationProvider.openAI.rawValue:
            return .openAI
        default:
            return .gemini
        }
    }
}

/// Service for generating images using a configurable Gemini image model
actor GeminiImageService {
    static let shared = GeminiImageService()
    
    private var apiKey: String = ""
    private var model: String = "gemini-3-pro-image-preview"
    private var pricing = GeminiImagePricing.default
    
    func configure(apiKey: String, model: String? = nil, pricing: GeminiImagePricing? = nil) {
        self.apiKey = apiKey
        if let model {
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            self.model = normalizedModel.isEmpty ? GeminiImagePricing.defaultModel : normalizedModel
        } else {
            self.model = GeminiImagePricing.defaultModel
        }
        self.pricing = pricing ?? .default
    }
    
    func isConfigured() -> Bool {
        !apiKey.isEmpty
    }
    
    /// Generate an image from a text prompt, optionally using a source image for transformation
    /// - Parameters:
    ///   - prompt: The text description of the image to generate or transformation to apply
    ///   - sourceImageData: Optional source image data for image-to-image transformation
    ///   - sourceMimeType: MIME type of the source image (e.g., "image/jpeg", "image/png")
    ///   - imageSize: Optional image size override. Supported values: 1K, 2K, 4K.
    /// - Returns: Image data (PNG/JPEG), MIME type, and estimated Gemini API spend in USD
    func generateImage(
        prompt: String,
        sourceImageData: Data? = nil,
        sourceMimeType: String? = nil,
        imageSize: String? = nil
    ) async throws -> (data: Data, mimeType: String, spendUSD: Double?) {
        guard !apiKey.isEmpty else {
            throw GeminiImageError.notConfigured
        }
        
        // Build request URL with API key
        let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard var urlComponents = URLComponents(string: baseURL) else {
            throw GeminiImageError.invalidURL
        }
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        
        guard let url = urlComponents.url else {
            throw GeminiImageError.invalidURL
        }
        
        // Build parts array - text prompt + optional source image
        var parts: [GeminiPart] = []
        
        // Add source image first if provided (Gemini expects image before text for editing)
        if let imageData = sourceImageData, let mimeType = sourceMimeType {
            let base64Image = imageData.base64EncodedString()
            let inlineData = GeminiInlineData(mimeType: mimeType, data: base64Image)
            parts.append(GeminiPart(inlineData: inlineData))
        }
        
        // Add text prompt
        parts.append(GeminiPart(text: prompt))
        
        // Build request body
        let requestBody = GeminiImageRequest(
            contents: [
                GeminiContent(parts: parts)
            ],
            generationConfig: GeminiGenerationConfig(
                responseModalities: ["TEXT", "IMAGE"],
                imageConfig: imageSize.map { GeminiImageConfig(imageSize: $0) }
            )
        )
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60  // Image generation can take time
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiImageError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            // Try to parse error message; keep the HTTP status so callers can
            // distinguish billing/auth problems from transient failures.
            if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
                throw GeminiImageError.apiError("HTTP \(httpResponse.statusCode): \(errorResponse.error.message)")
            }
            throw GeminiImageError.httpError(httpResponse.statusCode)
        }
        
        // Parse response
        let geminiResponse = try JSONDecoder().decode(GeminiImageResponse.self, from: data)
        let spendUSD = estimatedSpendUSD(
            from: geminiResponse.usageMetadata,
            imageSize: imageSize
        )
        
        // Find the image part in the response
        for candidate in geminiResponse.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                if let inlineData = part.inlineData {
                    guard let imageData = Data(base64Encoded: inlineData.data) else {
                        throw GeminiImageError.invalidImageData
                    }
                    return (imageData, inlineData.mimeType, spendUSD)
                }
            }
        }
        
        throw GeminiImageError.noImageGenerated
    }

    private func estimatedSpendUSD(
        from usageMetadata: GeminiUsageMetadata?,
        imageSize: String?
    ) -> Double? {
        var totalUSD = 0.0
        var didCalculate = false

        if let promptTokenCount = usageMetadata?.promptTokenCount,
           promptTokenCount > 0 {
            totalUSD += (Double(promptTokenCount) / 1_000_000.0) * pricing.inputCostPerMillionTokensUSD
            didCalculate = true
        }

        let candidateDetails = usageMetadata?.candidatesTokensDetails ?? []
        let candidateTextTokens = candidateDetails
            .filter { $0.modality == .text }
            .reduce(0) { $0 + $1.tokenCount }
        if candidateTextTokens > 0 {
            totalUSD += (Double(candidateTextTokens) / 1_000_000.0) * pricing.outputTextCostPerMillionTokensUSD
            didCalculate = true
        }

        let candidateImageTokens = candidateDetails
            .filter { $0.modality == .image }
            .reduce(0) { $0 + $1.tokenCount }
        if candidateImageTokens > 0 {
            totalUSD += (Double(candidateImageTokens) / 1_000_000.0) * pricing.outputImageCostPerMillionTokensUSD
            didCalculate = true
        } else if let fallbackImageTokens = fallbackImageTokenCount(for: imageSize) {
            totalUSD += (Double(fallbackImageTokens) / 1_000_000.0) * pricing.outputImageCostPerMillionTokensUSD
            didCalculate = true
        }

        guard didCalculate, totalUSD.isFinite, totalUSD > 0 else { return nil }
        return totalUSD
    }

    private func fallbackImageTokenCount(for imageSize: String?) -> Int? {
        guard let parsedSize = GeminiImageSize.parse(imageSize) else { return nil }
        switch parsedSize {
        case .oneK, .twoK:
            return 1120
        case .fourK:
            return 2000
        }
    }
}

/// Service for generating images and edits using OpenAI's Image API.
actor OpenAIImageService {
    static let shared = OpenAIImageService()

    private var apiKey: String = ""
    private var model: String = KeychainHelper.defaultOpenAIImageModel
    private var preciseModel: String = KeychainHelper.defaultOpenAIImagePreciseModel
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let now: @Sendable () -> Date
    /// Organisation verification is per OpenAI organisation, so one refusal
    /// gates the whole GPT Image 2.5 family for the key that received it,
    /// for `OpenAIImageOptions.verificationGateDuration`; a different key
    /// (another organisation) is never pre-judged. Process memory only.
    private var verificationGateUntil: [String: Date] = [:]

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    private var quality: String = KeychainHelper.defaultOpenAIImageQuality
    private var outputFormat: String = KeychainHelper.defaultOpenAIImageOutputFormat
    private var moderation: String = KeychainHelper.defaultOpenAIImageModeration

    func configure(
        apiKey: String,
        model: String? = nil,
        preciseModel: String? = nil,
        quality: String? = nil,
        outputFormat: String? = nil,
        moderation: String? = nil
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = Self.normalized(
            model,
            defaultValue: KeychainHelper.defaultOpenAIImageModel,
            allowedValues: nil
        )
        self.preciseModel = Self.normalized(preciseModel,
            defaultValue: KeychainHelper.defaultOpenAIImagePreciseModel, allowedValues: nil)
        self.quality = Self.normalized(
            quality,
            defaultValue: KeychainHelper.defaultOpenAIImageQuality,
            allowedValues: OpenAIImageOptions.qualities
        )
        self.outputFormat = Self.normalized(
            outputFormat,
            defaultValue: KeychainHelper.defaultOpenAIImageOutputFormat,
            allowedValues: ["png", "jpeg", "webp"]
        )
        self.moderation = Self.normalized(
            moderation,
            defaultValue: KeychainHelper.defaultOpenAIImageModeration,
            allowedValues: ["auto", "low"]
        )
    }

    func isConfigured() -> Bool {
        !apiKey.isEmpty
    }

    func generateImage(
        prompt: String,
        sourceImageData: Data? = nil,
        sourceMimeType: String? = nil,
        imageSize: String? = nil,
        engine: String? = nil,
        quality: String? = nil,
        outputFormat: String? = nil,
        outputCompression: Int? = nil,
        background: String? = nil,
        moderation: String? = nil
    ) async throws -> OpenAIImageResult {
        guard !apiKey.isEmpty else {
            throw OpenAIImageError.notConfigured
        }

        let resolvedSize = OpenAIImageSize.parse(imageSize)?.rawValue
        let options = try OpenAIImageOptions.resolve(
            engine: engine, fastModel: model, preciseModel: preciseModel,
            quality: quality, defaultQuality: self.quality,
            outputFormat: outputFormat, defaultOutputFormat: self.outputFormat,
            background: background
        )
        let resolvedModeration = Self.normalized(
            moderation,
            defaultValue: self.moderation,
            allowedValues: ["auto", "low"]
        )

        func render(_ options: OpenAIImageOptions) async throws -> OpenAIImageResult {
            // output_compression is only valid for jpeg/webp. OpenAI rejects it
            // with a 400 for png (the default format), so drop it when png.
            let compression = options.outputFormat == "png" ? nil : Self.normalizedCompression(outputCompression)
            let request: URLRequest
            if let sourceImageData {
                request = try editRequest(
                    model: options.model,
                    prompt: prompt,
                    sourceImageData: sourceImageData,
                    sourceMimeType: sourceMimeType ?? "image/png",
                    imageSize: resolvedSize,
                    quality: options.quality,
                    outputFormat: options.outputFormat,
                    outputCompression: compression,
                    background: options.background,
                    moderation: resolvedModeration
                )
            } else {
                request = try generationRequest(
                    model: options.model,
                    prompt: prompt,
                    imageSize: resolvedSize,
                    quality: options.quality,
                    outputFormat: options.outputFormat,
                    outputCompression: compression,
                    background: options.background,
                    moderation: resolvedModeration
                )
            }
            let response = try await perform(request)
            return try Self.decodeImageResponse(response, options: options)
        }

        // Verification fallback: only a GPT Image 2.5 target, only the
        // organisation-verification refusal (HTTP 403 "must be verified"),
        // exactly one retry on the fallback model. Every other failure, and a
        // refusal on any other model (including the fallback itself), surfaces.
        let fallbackEligible = OpenAIImageOptions.isImage25Family(options.model)
            && options.model != KeychainHelper.fallbackOpenAIImageModel
        func fallbackOptions() throws -> OpenAIImageOptions {
            try OpenAIImageOptions.verificationFallback(from: options,
                quality: quality, defaultQuality: self.quality,
                outputFormat: outputFormat, defaultOutputFormat: self.outputFormat,
                background: background)
        }
        let result: OpenAIImageResult
        if fallbackEligible, verificationGateActive() {
            result = try await render(try fallbackOptions())
        } else {
            do {
                result = try await render(options)
            } catch let error as OpenAIImageError {
                guard fallbackEligible, case .organizationNotVerified(let refusedModel, _) = error else { throw error }
                rememberVerificationGate()
                DebugTelemetry.log(.info, summary: "OpenAI image verification fallback",
                    detail: "\(refusedModel) refused (organisation not verified); rendering with \(KeychainHelper.fallbackOpenAIImageModel)")
                result = try await render(try fallbackOptions())
            }
        }
        DebugTelemetry.log(.info, summary: "OpenAI image usage",
            detail: result.telemetry(size: resolvedSize ?? "auto"))
        return result
    }

    private func verificationGateActive() -> Bool {
        guard let until = verificationGateUntil[apiKey] else { return false }
        if now() < until { return true }
        verificationGateUntil[apiKey] = nil
        return false
    }

    private func rememberVerificationGate() {
        verificationGateUntil[apiKey] = now().addingTimeInterval(OpenAIImageOptions.verificationGateDuration)
    }

    private func generationRequest(
        model: String,
        prompt: String,
        imageSize: String?,
        quality: String,
        outputFormat: String,
        outputCompression: Int?,
        background: String,
        moderation: String
    ) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            throw OpenAIImageError.invalidURL
        }

        let requestBody = OpenAIImageGenerationRequest(
            model: model,
            prompt: prompt,
            size: imageSize,
            quality: quality,
            outputFormat: outputFormat,
            outputCompression: outputCompression,
            background: background,
            moderation: moderation
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONEncoder().encode(requestBody)

        return request
    }

    private func editRequest(
        model: String,
        prompt: String,
        sourceImageData: Data,
        sourceMimeType: String,
        imageSize: String?,
        quality: String,
        outputFormat: String,
        outputCompression: Int?,
        background: String,
        moderation: String
    ) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/images/edits") else {
            throw OpenAIImageError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        appendMultipartField(name: "model", value: model, boundary: boundary, to: &body)
        appendMultipartField(name: "prompt", value: prompt, boundary: boundary, to: &body)
        if let imageSize {
            appendMultipartField(name: "size", value: imageSize, boundary: boundary, to: &body)
        }
        appendMultipartField(name: "quality", value: quality, boundary: boundary, to: &body)
        appendMultipartField(name: "output_format", value: outputFormat, boundary: boundary, to: &body)
        if let outputCompression {
            appendMultipartField(name: "output_compression", value: "\(outputCompression)", boundary: boundary, to: &body)
        }
        appendMultipartField(name: "background", value: background, boundary: boundary, to: &body)
        appendMultipartField(name: "moderation", value: moderation, boundary: boundary, to: &body)
        appendMultipartFile(
            name: "image[]",
            filename: "source.\(fileExtension(for: sourceMimeType))",
            mimeType: sourceMimeType,
            data: sourceImageData,
            boundary: boundary,
            to: &body
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = body

        return request
    }

    /// Performs the request with bounded retries on transient failures
    /// (HTTP 429/5xx, dropped connections), honoring Retry-After.
    /// Timeouts are never retried: the server may still finish and bill the render.
    /// A single provider hiccup no longer loses the whole generation. /stop
    /// (task cancellation) interrupts immediately and is never retried.
    private func perform(_ request: URLRequest) async throws -> Data {
        let maxAttempts = 4
        var lastError: Error?

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport(request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAIImageError.invalidResponse
                }

                if (200...299).contains(httpResponse.statusCode) {
                    return data
                }

                // Rate limit / transient server error: back off and retry.
                if attempt < maxAttempts,
                   httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                    let delay = Self.retryDelaySeconds(attempt: attempt, response: httpResponse)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Non-retryable, or attempts exhausted: surface the real error.
                if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                    if httpResponse.statusCode == 403,
                       Self.isVerificationRefusal(errorResponse.error.message) {
                        throw OpenAIImageError.organizationNotVerified(
                            model: Self.requestedModel(of: request), message: errorResponse.error.message)
                    }
                    throw OpenAIImageError.apiError("HTTP \(httpResponse.statusCode): \(errorResponse.error.message)")
                }
                throw OpenAIImageError.httpError(httpResponse.statusCode)
            } catch let error as OpenAIImageError {
                throw error // a decoded API error — not worth retrying
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError {
                if urlError.code == .cancelled {
                    throw CancellationError()
                }
                if urlError.code == .timedOut {
                    throw OpenAIImageError.renderTimedOut
                }
                lastError = urlError
                if attempt < maxAttempts, Self.isRetryable(urlError) {
                    let delay = Self.backoffSeconds(attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw urlError
            }
        }

        throw lastError ?? OpenAIImageError.invalidResponse
    }

    /// OpenAI's organisation-verification refusal has `code: null`, so it can
    /// only be recognised by status (403, checked by the caller) and message.
    static func isVerificationRefusal(_ message: String) -> Bool {
        message.lowercased().contains("must be verified")
    }

    private static func requestedModel(of request: URLRequest) -> String {
        guard let body = request.httpBody else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let model = object["model"] as? String {
            return model
        }
        // Multipart edit body: the model field is a plain text part.
        let text = String(decoding: body, as: UTF8.self)
        if let range = text.range(of: "name=\"model\"\r\n\r\n") {
            // "\r\n" is a single Character in Swift; split on the sequence, not on "\r".
            return text[range.upperBound...].components(separatedBy: "\r\n").first ?? ""
        }
        return ""
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Exponential backoff: 1s, 2s, 4s…
    private static func backoffSeconds(attempt: Int) -> Double {
        pow(2.0, Double(attempt - 1))
    }

    private static func retryDelaySeconds(attempt: Int, response: HTTPURLResponse) -> Double {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)) {
            return min(max(seconds, 0), 30)
        }
        return backoffSeconds(attempt: attempt)
    }

    static func decodeImageResponse(_ data: Data, options: OpenAIImageOptions) throws -> OpenAIImageResult {
        let response = try JSONDecoder().decode(OpenAIImagesResponse.self, from: data)
        guard let first = response.data?.first, let b64 = first.b64JSON,
              let image = Data(base64Encoded: b64), !image.isEmpty else {
            throw OpenAIImageError.invalidImageData
        }
        return OpenAIImageResult(data: image, mimeType: mimeType(for: response.outputFormat ?? options.outputFormat),
            spendUSD: OpenAIImagePricing.estimatedSpendUSD(from: response.usage, model: options.model),
            options: options, usage: response.usage)
    }

    private static func normalized(
        _ rawValue: String?,
        defaultValue: String,
        allowedValues: Set<String>?
    ) -> String {
        let normalized = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return defaultValue }
        if let allowedValues, !allowedValues.contains(normalized) {
            return defaultValue
        }
        return normalized
    }

    private static func normalizedCompression(_ rawValue: Int?) -> Int? {
        guard let rawValue else { return nil }
        return min(100, max(0, rawValue))
    }

    private func appendMultipartField(name: String, value: String, boundary: String, to body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendMultipartFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String,
        to body: inout Data
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/webp":
            return "webp"
        default:
            return "png"
        }
    }

    private static func mimeType(for outputFormat: String) -> String {
        switch outputFormat.lowercased() {
        case "jpeg", "jpg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        default:
            return "image/png"
        }
    }
}

struct OpenAIImageSize {
    let rawValue: String

    static func parse(_ rawValue: String?) -> OpenAIImageSize? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "auto", "default":
            return OpenAIImageSize(rawValue: "auto")
        case "1k", "1", "1024", "1024x1024", "square":
            return OpenAIImageSize(rawValue: "1024x1024")
        case "landscape", "1536x1024":
            return OpenAIImageSize(rawValue: "1536x1024")
        case "portrait", "1024x1536":
            return OpenAIImageSize(rawValue: "1024x1536")
        case "2k", "2", "2048", "2048x2048":
            return OpenAIImageSize(rawValue: "2048x2048")
        case "4k", "4", "uhd", "ultrahd", "ultra", "3840x2160":
            return OpenAIImageSize(rawValue: "3840x2160")
        default:
            return parseConstrainedDimensions(normalized)
        }
    }

    private static func parseConstrainedDimensions(_ normalized: String) -> OpenAIImageSize? {
        let dimensions = normalized.split(separator: "x")
        guard dimensions.count == 2,
              let width = Int(dimensions[0]),
              let height = Int(dimensions[1]),
              width > 0,
              height > 0 else {
            return nil
        }

        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        let totalPixels = width * height
        guard longEdge <= 3840,
              width.isMultiple(of: 16),
              height.isMultiple(of: 16),
              Double(longEdge) / Double(shortEdge) <= 3.0,
              totalPixels >= 655_360,
              totalPixels <= 8_294_400 else {
            return nil
        }

        return OpenAIImageSize(rawValue: "\(width)x\(height)")
    }
}

enum OpenAIImageError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case invalidImageData
    case invalidOptions(String)
    case renderTimedOut
    case organizationNotVerified(model: String, message: String)

    var errorDescription: String? {
        switch self {
        case .organizationNotVerified(let model, let message):
            return "OpenAI image API error: HTTP 403: \(message) (model \(model); OpenAI requires organisation verification for it, and no automatic fallback applies to this model)"
        case .renderTimedOut:
            return "OpenAI image request timed out and was not retried. The render may have been billed; its cost is unknown because no usage was received. Try a lower quality or smaller size."
        case .invalidOptions(let message):
            return message
        case .notConfigured:
            return "OpenAI image API key is not configured"
        case .invalidURL:
            return "Invalid OpenAI image API URL"
        case .invalidResponse:
            return "Invalid response from OpenAI image API"
        case .httpError(let code):
            return "OpenAI image API HTTP error: \(code)"
        case .apiError(let message):
            return "OpenAI image API error: \(message)"
        case .invalidImageData:
            return "Failed to decode OpenAI image data"
        }
    }
}

struct OpenAIImageGenerationRequest: Codable {
    let model: String
    let prompt: String
    let size: String?
    let quality: String
    let outputFormat: String
    let outputCompression: Int?
    let background: String
    let moderation: String

    enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case size
        case quality
        case outputFormat = "output_format"
        case outputCompression = "output_compression"
        case background
        case moderation
    }
}

struct OpenAIImagesResponse: Codable {
    let data: [OpenAIImageObject]?
    let outputFormat: String?
    let usage: OpenAIImageUsage?

    enum CodingKeys: String, CodingKey {
        case data
        case outputFormat = "output_format"
        case usage
    }
}

struct OpenAIImageObject: Codable {
    let b64JSON: String?

    enum CodingKeys: String, CodingKey {
        case b64JSON = "b64_json"
    }
}

struct OpenAIImageUsage: Codable {
    let inputTokens: Int?
    let inputTokensDetails: OpenAIImageInputTokensDetails?
    let outputTokens: Int?
    let outputTokensDetails: OpenAIImageOutputTokensDetails?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokens = "output_tokens"
        case outputTokensDetails = "output_tokens_details"
        case totalTokens = "total_tokens"
    }
}

struct OpenAIImageInputTokensDetails: Codable {
    let imageTokens: Int?
    let textTokens: Int?

    enum CodingKeys: String, CodingKey {
        case imageTokens = "image_tokens"
        case textTokens = "text_tokens"
    }
}

struct OpenAIImageOutputTokensDetails: Codable {
    let imageTokens: Int?
    let textTokens: Int?

    enum CodingKeys: String, CodingKey {
        case imageTokens = "image_tokens"
        case textTokens = "text_tokens"
    }
}

struct OpenAIImagePricing {
    static let gptImage25 = OpenAIImagePricing(
        textInputCostPerMillionTokensUSD: 5.0, imageInputCostPerMillionTokensUSD: 8.0,
        imageOutputCostPerMillionTokensUSD: 30.0, textOutputCostPerMillionTokensUSD: nil
    )
    static let gptImage2 = OpenAIImagePricing(
        textInputCostPerMillionTokensUSD: 5.0,
        imageInputCostPerMillionTokensUSD: 8.0,
        imageOutputCostPerMillionTokensUSD: 30.0,
        textOutputCostPerMillionTokensUSD: nil
    )

    static let gptImage15 = OpenAIImagePricing(
        textInputCostPerMillionTokensUSD: 5.0,
        imageInputCostPerMillionTokensUSD: 8.0,
        imageOutputCostPerMillionTokensUSD: 32.0,
        textOutputCostPerMillionTokensUSD: 10.0
    )

    static let gptImage1Mini = OpenAIImagePricing(
        textInputCostPerMillionTokensUSD: 2.0,
        imageInputCostPerMillionTokensUSD: 2.5,
        imageOutputCostPerMillionTokensUSD: 8.0,
        textOutputCostPerMillionTokensUSD: nil
    )

    let textInputCostPerMillionTokensUSD: Double
    let imageInputCostPerMillionTokensUSD: Double
    let imageOutputCostPerMillionTokensUSD: Double
    let textOutputCostPerMillionTokensUSD: Double?

    static func pricing(for model: String) -> OpenAIImagePricing? {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if OpenAIImageOptions.isImage25Family(normalized) {
            return .gptImage25
        }
        if normalized == "gpt-image-2" || normalized.hasPrefix("gpt-image-2-202") {
            return .gptImage2
        }
        if normalized.hasPrefix("gpt-image-1.5") {
            return .gptImage15
        }
        if normalized.hasPrefix("gpt-image-1-mini") {
            return .gptImage1Mini
        }
        return nil
    }
}

struct OpenAIErrorResponse: Codable {
    let error: OpenAIErrorDetail
}

struct OpenAIErrorDetail: Codable {
    let message: String
}

struct GeminiImagePricing {
    static let defaultModel = "gemini-3-pro-image-preview"
    static let `default` = GeminiImagePricing(
        inputCostPerMillionTokensUSD: 2.0,
        outputTextCostPerMillionTokensUSD: 12.0,
        outputImageCostPerMillionTokensUSD: 120.0
    )

    let inputCostPerMillionTokensUSD: Double
    let outputTextCostPerMillionTokensUSD: Double
    let outputImageCostPerMillionTokensUSD: Double
}

// MARK: - Error Types

enum GeminiImageError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case invalidImageData
    case noImageGenerated
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Gemini API key is not configured"
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from Gemini API"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .apiError(let message):
            return "Gemini API error: \(message)"
        case .invalidImageData:
            return "Failed to decode image data"
        case .noImageGenerated:
            return "No image was generated in the response"
        }
    }
}

// MARK: - Request Models

struct GeminiImageRequest: Codable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig
}

struct GeminiContent: Codable {
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    
    init(text: String) {
        self.text = text
        self.inlineData = nil
    }
    
    init(inlineData: GeminiInlineData) {
        self.text = nil
        self.inlineData = inlineData
    }
}

struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String  // Base64 encoded
}

struct GeminiGenerationConfig: Codable {
    let responseModalities: [String]
    let imageConfig: GeminiImageConfig?
}

struct GeminiImageConfig: Codable {
    let imageSize: String
}

enum GeminiImageSize: String {
    case oneK = "1K"
    case twoK = "2K"
    case fourK = "4K"
    
    static func parse(_ rawValue: String?) -> GeminiImageSize? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        
        guard !normalized.isEmpty else { return nil }
        
        switch normalized {
        case "1K", "1", "1024":
            return .oneK
        case "2K", "2", "2048":
            return .twoK
        case "4K", "4", "4096", "UHD", "ULTRAHD", "ULTRA":
            return .fourK
        default:
            return nil
        }
    }
}

// MARK: - Response Models

struct GeminiImageResponse: Codable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?

    enum CodingKeys: String, CodingKey {
        case candidates
        case usageMetadata = "usageMetadata"
    }
}

struct GeminiCandidate: Codable {
    let content: GeminiResponseContent?
}

struct GeminiResponseContent: Codable {
    let parts: [GeminiResponsePart]?
}

struct GeminiResponsePart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
}

struct GeminiUsageMetadata: Codable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
    let promptTokensDetails: [GeminiModalityTokenCount]?
    let candidatesTokensDetails: [GeminiModalityTokenCount]?

    enum CodingKeys: String, CodingKey {
        case promptTokenCount = "promptTokenCount"
        case candidatesTokenCount = "candidatesTokenCount"
        case totalTokenCount = "totalTokenCount"
        case promptTokensDetails = "promptTokensDetails"
        case candidatesTokensDetails = "candidatesTokensDetails"
    }
}

struct GeminiModalityTokenCount: Codable {
    let modality: GeminiTokenModality
    let tokenCount: Int

    enum CodingKeys: String, CodingKey {
        case modality
        case tokenCount = "tokenCount"
    }
}

enum GeminiTokenModality: String, Codable {
    case text = "TEXT"
    case image = "IMAGE"
    case audio = "AUDIO"
    case video = "VIDEO"
    case unspecified = "MODALITY_UNSPECIFIED"
}

struct GeminiErrorResponse: Codable {
    let error: GeminiError
}

struct GeminiError: Codable {
    let code: Int
    let message: String
    let status: String?
}
