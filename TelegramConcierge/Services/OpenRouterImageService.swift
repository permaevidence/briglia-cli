import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Image generation and editing through OpenRouter, for the OpenRouter lane
/// without an OpenAI key (`MediaRouting.imageBackend == .openRouter`).
///
/// Route: `POST /api/v1/chat/completions` with `modalities: ["image","text"]`
/// and `image_config` — OpenRouter's documented image route, the one that
/// takes `aspect_ratio`/`image_size` and input images for editing. Verified
/// live 2026-09-25 on the owner's key: google/gemini-3.1-flash-image at 16:9
/// returned a 1376x768 PNG (cost $0.067); google/gemini-3-pro-image edited an
/// input image at 21:9 / 1K (1584x672, cost $0.138). The image arrives as
/// `choices[0].message.images[0].image_url.url`, a base64 data URL. Spend is
/// OpenRouter's reported `usage.cost`. GPT Image 2.5 is not on OpenRouter.
actor OpenRouterImageService {
    static let shared = OpenRouterImageService()

    static let endpoint = "https://openrouter.ai/api/v1/chat/completions"
    /// Default engine: Nano Banana Pro — best quality, text rendering, edits.
    static let bestModel = "google/gemini-3-pro-image"
    /// Quick/cheaper engine (about half the price per image).
    static let fastModel = "google/gemini-3.1-flash-image"
    static let engines = ["best", "fast"]
    /// Ratios both Gemini image models accept.
    static let aspectRatios = ["1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9"]
    static let sizes = ["1K", "2K", "4K"]

    struct Result {
        let data: Data
        let mimeType: String
        let spendUSD: Double?
        let model: String
        let engine: String
        let aspectRatio: String?
        let size: String?

        func toolResultMetadata() -> [String: Any] {
            var out: [String: Any] = ["model": model, "engine": engine, "via": "openrouter"]
            if let aspectRatio { out["aspect_ratio"] = aspectRatio }
            if let size { out["size"] = size }
            return out
        }
    }

    enum ServiceError: LocalizedError, Equatable {
        case notConfigured
        case invalidOptions(String)
        case api(String)
        case noImage(String?)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenRouter API key is not configured."
            case .invalidOptions(let message): return message
            case .api(let message): return "OpenRouter image request failed: \(message)"
            case .noImage(let text):
                if let text, !text.isEmpty { return "The model returned no image. It said: \(text.prefix(300))" }
                return "The model returned no image."
            }
        }
    }

    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    /// Pure option resolution (selftest seam). nil/empty = default.
    static func resolve(engine: String?, aspectRatio: String?, size: String?) throws
        -> (model: String, engine: String, aspectRatio: String?, size: String?) {
        let e = (engine ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedEngine = e.isEmpty ? "best" : e
        guard engines.contains(resolvedEngine) else {
            throw ServiceError.invalidOptions("Invalid engine '\(e)'. Use best or fast.")
        }
        let r = (aspectRatio ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty, !aspectRatios.contains(r) {
            throw ServiceError.invalidOptions("Invalid aspect_ratio '\(r)'. Supported: \(aspectRatios.joined(separator: ", ")).")
        }
        let rawSize = (size ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedSize: String?
        if !rawSize.isEmpty {
            guard let parsed = GeminiImageSize.parse(rawSize) else {
                throw ServiceError.invalidOptions("Invalid size '\(rawSize)'. Supported: 1K, 2K, 4K.")
            }
            resolvedSize = parsed.rawValue
        }
        return (resolvedEngine == "fast" ? fastModel : bestModel, resolvedEngine, r.isEmpty ? nil : r, resolvedSize)
    }

    /// The exact request body (selftest seam).
    static func requestBody(model: String, prompt: String, sourceImageData: Data?, sourceMimeType: String?,
                            aspectRatio: String?, size: String?) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "modalities": ["image", "text"],
            "usage": ["include": true],
        ]
        if let sourceImageData {
            let mime = sourceMimeType ?? "image/png"
            body["messages"] = [["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(sourceImageData.base64EncodedString())"]],
                ["type": "text", "text": prompt],
            ]]]
        } else {
            body["messages"] = [["role": "user", "content": prompt]]
        }
        var config: [String: Any] = [:]
        if let aspectRatio { config["aspect_ratio"] = aspectRatio }
        if let size { config["image_size"] = size }
        if !config.isEmpty { body["image_config"] = config }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func generateImage(apiKey: String, prompt: String, sourceImageData: Data?, sourceMimeType: String?,
                       engine: String?, aspectRatio: String?, size: String?) async throws -> Result {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ServiceError.notConfigured }
        let options = try Self.resolve(engine: engine, aspectRatio: aspectRatio, size: size)
        guard let url = URL(string: Self.endpoint) else { throw ServiceError.api("invalid endpoint URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(model: options.model, prompt: prompt, sourceImageData: sourceImageData,
            sourceMimeType: sourceMimeType, aspectRatio: options.aspectRatio, size: options.size)

        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(ChatImageResponse.self, from: data)
        guard status == 200 else {
            let detail = decoded?.error?.message
                ?? String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "no error body"
            throw ServiceError.api("HTTP \(status): \(detail)")
        }
        guard let decoded else { throw ServiceError.api("unreadable response") }
        if let error = decoded.error { throw ServiceError.api(error.message) }
        let message = decoded.choices?.first?.message
        guard let urlString = message?.images?.first?.imageURL.url else {
            throw ServiceError.noImage(message?.content)
        }
        let (imageData, mime) = try await Self.decodeImage(urlString, transport: transport)
        return Result(data: imageData, mimeType: mime, spendUSD: decoded.usage?.cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                      model: options.model, engine: options.engine, aspectRatio: options.aspectRatio, size: options.size)
    }

    /// A base64 data URL (what OpenRouter returns), or an https URL fetched once.
    static func decodeImage(_ string: String, transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> (Data, String) {
        if string.hasPrefix("data:") {
            guard let comma = string.firstIndex(of: ",") else { throw ServiceError.api("malformed image data URL") }
            let header = string[string.index(string.startIndex, offsetBy: 5)..<comma]
            let mime = header.split(separator: ";").first.map(String.init) ?? "image/png"
            guard header.contains("base64"), let data = Data(base64Encoded: String(string[string.index(after: comma)...])) else {
                throw ServiceError.api("image data URL is not valid base64")
            }
            return (data, mime.isEmpty ? "image/png" : mime)
        }
        guard let url = URL(string: string), url.scheme == "https" else { throw ServiceError.api("unsupported image URL") }
        let (data, response) = try await transport(URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw ServiceError.api("could not download the generated image")
        }
        return (data, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "image/png")
    }

    struct ChatImageResponse: Decodable {
        struct APIError: Decodable { let message: String }
        struct Choice: Decodable {
            struct Message: Decodable {
                struct Image: Decodable {
                    struct ImageURL: Decodable { let url: String }
                    let imageURL: ImageURL
                    enum CodingKeys: String, CodingKey { case imageURL = "image_url" }
                }
                let content: String?
                let images: [Image]?
            }
            let message: Message?
        }
        struct Usage: Decodable { let cost: Double? }
        let choices: [Choice]?
        let usage: Usage?
        let error: APIError?
    }
}

// MARK: - Schemas shown only on the OpenRouter lane without an OpenAI key

extension AvailableTools {
    static let openRouterGenerateImage = ToolDefinition(
        function: FunctionDefinition(
            name: "generate_image",
            description: "Generate an image with Google's Gemini image models (Nano Banana) through OpenRouter, or edit, restyle or take inspiration from one stored source image. Use when the user asks you to create, generate, draw, make, edit, transform, restyle, or use an image as inspiration. The generated image will be sent to the user in the chat. Provide source_image when the user refers to a specific prior image; this tool does not infer the most recent image automatically.",
            parameters: FunctionParameters(
                properties: [
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "A detailed description of the image to generate or the change to make. If using a source image, say what should be preserved, changed, or merely used as inspiration."
                    ),
                    "source_image": ParameterProperty(
                        type: "string",
                        description: "Optional. Stored image filename in the Briglia images store, e.g. 'abc123.jpg'. Use the exact basename from recent image/file metadata; do not pass an absolute path. Leave empty to generate a new image from scratch."
                    ),
                    "source_image_role": ParameterProperty(
                        type: "string",
                        description: "Optional. How to treat source_image when provided. Use 'reference' when the image is inspiration/style/composition only, 'edit' when preserving and directly changing the original, and 'transform' when restyling or reimagining the original subject.",
                        enumValues: ["reference", "edit", "transform"]
                    ),
                    "engine": ParameterProperty(
                        type: "string",
                        description: "Optional. 'best' (default) uses Gemini 3 Pro Image (Nano Banana Pro): the highest quality, the best text inside images and the most careful edits. 'fast' uses Gemini 3.1 Flash Image: quicker and about half the cost, good for drafts or when the user wants something quick.",
                        enumValues: OpenRouterImageService.engines
                    ),
                    "aspect_ratio": ParameterProperty(
                        type: "string",
                        description: "Optional output shape. Omit for the model's default (square for new images; an edit usually keeps the source's shape). Use '16:9' or '21:9' for wide, '9:16' for phone/story, '4:5' for portrait posts, '3:2'/'2:3' for photos.",
                        enumValues: OpenRouterImageService.aspectRatios
                    ),
                    "size": ParameterProperty(
                        type: "string",
                        description: "Optional output resolution: '1K' (default), '2K' or '4K'. Use '4K' only when the user wants very high resolution; it costs more.",
                        enumValues: OpenRouterImageService.sizes
                    )
                ],
                required: ["prompt"]
            )
        )
    )

    static let openRouterTranscribeMedia = ToolDefinition(
        function: FunctionDefinition(
            name: "transcribe_media",
            description: "Transcribe speech from an audio or video file on disk via cloud transcription through OpenRouter (your OpenRouter key; no OpenAI key needed). Video files and uncommon audio formats have their audio track extracted automatically via ffmpeg. Use format='text' for a plain transcript (default). Use format='srt' to get timestamped subtitles — the .srt file is written next to the input (or to output_path) and the result includes a preview; pair it with the video-edit skill to burn subtitles in or attach them as a soft track. Note: SRT uses whisper-1 (gpt-transcribe does not return timestamps); plain text uses gpt-transcribe.",
            parameters: FunctionParameters(
                properties: [
                    "path": ParameterProperty(type: "string", description: "Absolute path to the audio or video file."),
                    "format": ParameterProperty(type: "string", description: "Output format: 'text' (plain transcript, default) or 'srt' (timestamped subtitles written to a file).", enumValues: ["text", "srt"]),
                    "language": ParameterProperty(type: "string", description: "Optional ISO-639-1 language hint (e.g. 'it', 'en'). Omit for auto-detection."),
                    "output_path": ParameterProperty(type: "string", description: "For format='srt' only. Absolute path for the .srt file. Defaults to the input path with an .srt extension.")
                ],
                required: ["path"]
            )
        )
    )
}
