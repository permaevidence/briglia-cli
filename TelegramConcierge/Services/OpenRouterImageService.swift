import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Image generation and editing through OpenRouter's Image API, for the
/// OpenRouter lane without an OpenAI key (`MediaRouting.imageBackend ==
/// .openRouter`): GPT Image 2.5 Flare (engine `fast`, default) and Sunburst
/// (engine `precise`), the same engines as the direct OpenAI path.
///
/// Route: `POST /api/v1/images` with `{model, prompt, aspect_ratio?, quality?,
/// background?, input_references?}`; the image comes back as
/// `data[0].b64_json` + `media_type`. Verified live 2026-10-30 on the owner's
/// key (BYOK): Flare 3:2 → 1536x1024 PNG, Sunburst high, a Flare edit with a
/// data-URL input reference, a transparent 1:1 Flare render
/// (`orimg/report.md`), and a top-level `size` passed through to OpenAI:
/// "3840x2160" → a 3840x2160 PNG, an edit at "2048x2048" → 2048x2048, and
/// "3840x3840" → OpenAI's own 400 "exceeds the current pixel budget"
/// (`orsize/`). `size` is not in the endpoint's advertised parameters but is
/// honoured; Briglia validates it with the direct path's rules
/// (`OpenAIImageSize`) and never sends it together with `aspect_ratio`
/// (OpenRouter rejects that pair). `output_format` and moderation are not
/// advertised for these models, so they are never sent.
///
/// There is NO fallback to another engine: every failure is a clear tool
/// error (owner decision 2026-10-30) — the tool schema the model saw belongs
/// to this engine, so a silent switch would reinterpret its arguments.
///
/// Spend: `usage.cost`, plus `usage.cost_details.upstream_inference_cost` on
/// a bring-your-own-key request (`is_byok`), where OpenRouter's fee and the
/// provider's charge on the user's own key are two separate charges (the
/// extractor rule of 6af22df). A request that was sent but never answered
/// (timeout, cancellation, a connection lost after sending) has an unknown
/// cost: it is written ahead to the in-flight record and becomes an
/// unknown-amount incident, exactly like a cut web extraction request.
actor OpenRouterImageService {
    static let shared = OpenRouterImageService()

    static let endpoint = "https://openrouter.ai/api/v1/images"
    /// Default engine (`fast`).
    static let fastModel = "openai/gpt-image-2.5-flare"
    /// Precise engine: careful edits that must preserve subjects, faces, text or layout.
    static let preciseModel = "openai/gpt-image-2.5-sunburst"
    static let engines = ["fast", "precise"]
    static let qualities = ["auto", "low", "medium", "high", "xhigh", "max"]
    static let backgrounds = ["auto", "opaque", "transparent"]
    /// The values the Image API accepts for `aspect_ratio` (not in the schema:
    /// a value carried over from an older schema is passed through when no
    /// size is given).
    static let aspectRatios = ["auto", "1:1", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16", "21:9"]
    /// A Sunburst high render took 55 s in the probe; xhigh/max take longer.
    static let defaultTimeout: TimeInterval = 600
    /// Stage name of the in-flight record and of an unknown-cost incident.
    static let spendStage = "image-openrouter"
    /// An input reference is sent unchanged up to this size and long side;
    /// larger ones are downscaled to JPEG (base64 inflates by 4/3 and the
    /// Image API answers 413 to a body that is too large).
    static let referenceMaxBytes = 3 * 1024 * 1024
    static let referenceMaxLongSide = 2048

    struct Options: Equatable {
        let engine: String
        let model: String
        let quality: String
        let background: String
        /// WIDTHxHEIGHT; nil = not sent (the API's own default, "auto").
        let size: String?
        /// Only when no size: an aspect ratio carried over from an older schema.
        let aspectRatio: String?
        var notes: [String]
    }

    struct Result {
        let data: Data
        let mimeType: String
        let spendUSD: Double?
        let options: Options
        let byok: Bool
        /// WIDTHxHEIGHT measured from the returned bytes; nil when unreadable.
        let actualSize: String?

        /// What was asked for (size, carried-over ratio, or auto).
        var requestedSize: String { options.size ?? options.aspectRatio ?? "auto" }

        func toolResultMetadata() -> [String: Any] {
            [
                "engine": options.engine, "model": options.model, "quality": options.quality,
                "background": options.background, "requested_size": requestedSize,
                "size": actualSize ?? "unknown",
                "via": "openrouter", "notes": options.notes,
                "estimated_spend_usd": spendUSD as Any? ?? NSNull(),
            ]
        }
    }

    enum ServiceError: LocalizedError, Equatable {
        case notConfigured
        case invalidOptions(String)
        /// An HTTP error answer (nothing to settle: the reply arrived).
        case api(status: Int, message: String)
        /// The model could not be served: 404 (no provider), 502 (upstream
        /// render failed, not billed) or OpenAI's organisation-verification
        /// 403 relayed through a BYOK key. The text says what to do.
        case unavailable(status: Int, message: String, verification: Bool)
        /// Sent, no reply: its cost is unknown (an incident was opened).
        case timedOut
        case connectionFailed(String)
        /// A 200 without a usable image; `spendUSD` is what the reply reported.
        case noImage(detail: String, spendUSD: Double?)
        /// Not sent: paid work is paused, or the send could not be tracked.
        case notSent(String)

        var spendUSD: Double? {
            if case .noImage(_, let spend) = self { return spend }
            return nil
        }

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "OpenRouter API key is not configured. Add it with briglia menu."
            case .invalidOptions(let message):
                return message
            case .api(let status, let message):
                return "OpenRouter image request failed: HTTP \(status): \(message)"
            case .unavailable(let status, let message, let verification):
                if verification {
                    return "OpenRouter image request failed: HTTP \(status): \(message). GPT Image 2.5 is refused because the OpenAI organisation of the OpenAI key connected to OpenRouter (BYOK) is not verified. Tell the user: verify the organisation at https://platform.openai.com/settings/organization/general, or remove that OpenAI key at https://openrouter.ai/settings/integrations so OpenRouter serves the model itself, or add an OpenAI API key in briglia menu (Voice & images) to create images directly with OpenAI. No image was created."
                }
                if status == 502 {
                    return "OpenRouter image request failed: HTTP 502: \(message). The upstream render failed and OpenRouter does not bill a failed render. Tell the user it can be retried in a moment; if it keeps failing, GPT Image 2.5 is unavailable on OpenRouter right now (status: https://status.openrouter.ai), and adding an OpenAI API key in briglia menu (Voice & images) creates images directly with OpenAI. No image was created."
                }
                return "OpenRouter image request failed: HTTP \(status): \(message). GPT Image 2.5 is not available to this OpenRouter key right now. Tell the user: check https://openrouter.ai/openai/gpt-image-2.5-flare and the key's provider/privacy restrictions at https://openrouter.ai/settings/privacy (OpenAI must be allowed), or add an OpenAI API key in briglia menu (Voice & images) to create images directly with OpenAI. No image was created."
            case .timedOut:
                return "OpenRouter image request timed out and was not retried. The render may still have been billed; its cost is unknown because no reply was received. Try a lower quality."
            case .connectionFailed(let detail):
                return "OpenRouter image request lost its connection before the reply (\(detail)). It was not retried; the render may still have been billed and its cost is unknown."
            case .noImage(let detail, _):
                return detail.isEmpty ? "OpenRouter returned no image." : "OpenRouter returned no image: \(detail.prefix(300))"
            case .notSent(let reason):
                return "The image request was not sent: \(reason)"
            }
        }
    }

    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let endpointURL: URL
    private let timeout: TimeInterval

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         endpoint: URL = URL(string: OpenRouterImageService.endpoint)!,
         timeout: TimeInterval = OpenRouterImageService.defaultTimeout) {
        self.transport = transport
        self.endpointURL = endpoint
        self.timeout = timeout
    }

    // MARK: Options (pure, selftest seam)

    private static func clean(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// nil/empty = default. An unknown engine or an invalid size is refused
    /// (no request; the size rules and message are the direct path's); an
    /// unknown quality/background is replaced with its default and noted,
    /// like the direct OpenAI path. `aspect_ratio` is not in this schema: a
    /// supported value carried over from an older schema is sent only when
    /// no size is given, anything else is ignored with a note.
    static func resolve(engine: String?, quality: String?, background: String?,
                        size: String?, aspectRatio: String? = nil) throws -> Options {
        let e = clean(engine).isEmpty ? "fast" : clean(engine)
        guard engines.contains(e) else {
            throw ServiceError.invalidOptions("Invalid engine '\(clean(engine))'. Use fast or precise.")
        }
        var notes: [String] = []
        var q = clean(quality).isEmpty ? "auto" : clean(quality)
        if !qualities.contains(q) {
            notes.append("Unsupported quality '\(q)' replaced with auto.")
            q = "auto"
        }
        var b = clean(background).isEmpty ? "auto" : clean(background)
        if !backgrounds.contains(b) {
            notes.append("Unsupported background '\(b)' replaced with auto.")
            b = "auto"
        }
        var resolvedSize: String? = nil
        if !clean(size).isEmpty {
            guard let parsed = OpenAIImageSize.parse(size) else {
                throw ServiceError.invalidOptions("Invalid image size '\(size ?? "")'. Use auto or WIDTHxHEIGHT with max edge <= 3840, both edges multiples of 16, aspect ratio <= 3:1, and total pixels between 655360 and 8294400.")
            }
            resolvedSize = parsed.rawValue == "auto" ? nil : parsed.rawValue
        }
        var ratio: String? = nil
        let r = clean(aspectRatio)
        if !r.isEmpty, r != "auto" {
            if resolvedSize != nil {
                notes.append("aspect_ratio '\(r)' was ignored because size was given.")
            } else if aspectRatios.contains(r) {
                ratio = r
            } else {
                notes.append("aspect_ratio '\(r)' is not supported and was ignored; use size.")
            }
        }
        return Options(engine: e, model: e == "precise" ? preciseModel : fastModel, quality: q, background: b,
                       size: resolvedSize, aspectRatio: ratio, notes: notes)
    }

    /// WIDTHxHEIGHT → the supported aspect ratio closest in log space.
    static func nearestAspectRatio(forSize size: String) -> String? {
        let parts = size.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        let target = log(w / h)
        func value(_ ratio: String) -> Double {
            let p = ratio.split(separator: ":").compactMap { Double($0) }
            return p.count == 2 && p[1] > 0 ? p[0] / p[1] : 1
        }
        return aspectRatios.dropFirst().min { abs(log(value($0)) - target) < abs(log(value($1)) - target) }
    }

    /// `size` is honoured by OpenRouter today but not advertised for these
    /// models. A 400 from OpenRouter ITSELF (no upstream provider named in
    /// the error metadata) whose message names `size` means the field
    /// stopped passing through: the caller retries once with the
    /// nearest aspect ratio. OpenAI's own size-rule 400 (provider "OpenAI",
    /// e.g. "exceeds the current pixel budget") is NOT this case and reaches
    /// the model unchanged, as on the direct path. Pure, selftest seam.
    static func isSizeFieldRejection(status: Int, error: ImagesResponse.APIError?, sentSize: Bool) -> Bool {
        guard sentSize, status == 400, let error else { return false }
        if let provider = error.metadata?.providerName, !provider.isEmpty { return false }
        let message = (error.message ?? "").lowercased()
        return message.range(of: #"\bsize\b"#, options: .regularExpression) != nil
    }

    /// The exact request body (selftest seam). Only non-default options are sent.
    static func requestBody(options: Options, prompt: String, reference: (data: Data, mime: String)?) throws -> Data {
        var body: [String: Any] = ["model": options.model, "prompt": prompt]
        if let size = options.size { body["size"] = size } else if let ratio = options.aspectRatio { body["aspect_ratio"] = ratio }
        if options.quality != "auto" { body["quality"] = options.quality }
        if options.background != "auto" { body["background"] = options.background }
        if let reference {
            body["input_references"] = [["type": "image_url",
                                         "image_url": ["url": "data:\(reference.mime);base64,\(reference.data.base64EncodedString())"]]]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The source image as an input reference: unchanged when it is a
    /// JPEG/PNG/WebP within `referenceMaxBytes` and `referenceMaxLongSide`;
    /// otherwise converted (GIF/HEIC/…) and/or downscaled to JPEG until it
    /// fits. Refused when it cannot be made to fit (nothing is sent).
    static func referencePayload(_ data: Data, declaredMime: String?) throws -> (data: Data, mime: String, note: String?) {
        let outcome = ModelImage.classify(data: data, declaredMime: declaredMime)
        guard var (bytes, mime) = outcome.attachable else {
            throw ServiceError.invalidOptions("The source image can't be used: \(outcome.refusalReason ?? "not a usable image").")
        }
        var note: String? = nil
        if case .converted(_, _, let from) = outcome { note = "The source image (\(from)) was converted to \(mime) for upload." }
        if mime == "image/gif" {
            guard let png = PlatformImage.convertFirstFrame(data: bytes, toJPEG: false, quality: FilesystemTools.imageDownscaleQuality) else {
                throw ServiceError.invalidOptions("The source image is a GIF and this machine could not convert it to PNG.")
            }
            bytes = png; mime = "image/png"
            note = "The source GIF was converted to PNG for upload."
        }
        let dims = PlatformImage.orientedDimensions(data: bytes)
        let longSide = dims.map { max($0.width, $0.height) }
        if bytes.count <= referenceMaxBytes, (longSide ?? 0) <= referenceMaxLongSide {
            return (bytes, mime, note)
        }
        if let dims, let longSide {
            for side in [referenceMaxLongSide, 1536, 1024] where side <= max(longSide, 1024) {
                let scale = Double(min(side, longSide)) / Double(longSide)
                let target = CGSize(width: max(1, Int((Double(dims.width) * scale).rounded())),
                                    height: max(1, Int((Double(dims.height) * scale).rounded())))
                if let jpeg = PlatformImage.resizeToJPEG(data: bytes, targetSize: target, quality: FilesystemTools.imageDownscaleQuality),
                   jpeg.count <= referenceMaxBytes {
                    return (jpeg, "image/jpeg",
                            "The source image was downscaled to \(Int(target.width))x\(Int(target.height)) JPEG for upload (any transparency is not kept).")
                }
            }
        }
        if bytes.count <= referenceMaxBytes { return (bytes, mime, note) }
        throw ServiceError.invalidOptions("The source image is too large to send through OpenRouter (\(bytes.count / 1_048_576) MB) and could not be downscaled on this machine. Use a smaller image.")
    }

    // MARK: Response

    struct ImagesResponse: Decodable {
        struct Item: Decodable {
            let b64JSON: String?
            let mediaType: String?
            enum CodingKeys: String, CodingKey { case b64JSON = "b64_json", mediaType = "media_type" }
        }
        struct Usage: Decodable {
            struct CostDetails: Decodable {
                let upstreamInferenceCost: LossyDouble?
                enum CodingKeys: String, CodingKey { case upstreamInferenceCost = "upstream_inference_cost" }
            }
            let promptTokens: Int?
            let completionTokens: Int?
            let cost: LossyDouble?
            let isByok: Bool?
            let costDetails: CostDetails?
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", cost
                case isByok = "is_byok", costDetails = "cost_details"
            }
        }
        struct APIError: Decodable {
            struct Metadata: Decodable {
                let providerName: String?
                let failedRoutingStep: String?
                enum CodingKeys: String, CodingKey { case providerName = "provider_name", failedRoutingStep = "failed_routing_step" }
            }
            let message: String?
            let code: LossyDouble?
            let metadata: Metadata?
        }
        let data: [Item]?
        let usage: Usage?
        let error: APIError?
    }

    /// The charge of one answered request (pure, selftest seam). BYOK: the
    /// OpenRouter fee plus the provider's charge on the user's key, as one
    /// charge; without a reported upstream cost the provider part is
    /// estimated from BOTH token counts (GPT Image 2.5 list prices). Not
    /// BYOK: `usage.cost` (upstream is only a breakdown there), else the
    /// token estimate. `complete` is false when the reply does not establish
    /// the whole charge (no usage, a BYOK fee without an upstream cost or
    /// both token counts, a missing fee): the known part is still counted,
    /// and the caller keeps an unknown-amount obligation for the rest.
    static func charge(_ usage: ImagesResponse.Usage?) -> (usd: Double?, complete: Bool) {
        guard let usage else { return (nil, false) }
        func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let cost = valid(usage.cost?.value)
        let estimate = (usage.promptTokens != nil && usage.completionTokens != nil)
            ? tokenEstimateUSD(promptTokens: usage.promptTokens, completionTokens: usage.completionTokens) : nil
        func sum(_ a: Double?, _ b: Double?) -> Double? {
            guard a != nil || b != nil else { return nil }
            let total = (a ?? 0) + (b ?? 0)
            return total.isFinite ? total : nil
        }
        if usage.isByok == true {
            let provider = valid(usage.costDetails?.upstreamInferenceCost?.value) ?? estimate
            let total = sum(cost, provider)
            return (total, cost != nil && provider != nil && total != nil)
        }
        if let cost { return (cost, true) }
        return (estimate, estimate != nil)
    }

    static func spendUSD(_ usage: ImagesResponse.Usage?) -> Double? { charge(usage).usd }

    /// Pixel size of the returned image: the PNG header (what the Image API
    /// returns), else the platform decoder. nil when unreadable.
    static func pixelSize(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(24))
        if b.count == 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47, b[12...15].elementsEqual(Array("IHDR".utf8)) {
            let w = b[16...19].reduce(0) { $0 << 8 | Int($1) }, h = b[20...23].reduce(0) { $0 << 8 | Int($1) }
            return w > 0 && h > 0 ? "\(w)x\(h)" : nil
        }
        return PlatformImage.dimensions(data: data).map { "\($0.width)x\($0.height)" }
    }

    /// Prompt tokens at the image-input rate (the higher input rate: the
    /// split between text and reference-image tokens is not reported),
    /// completion tokens at the image-output rate.
    static func tokenEstimateUSD(promptTokens: Int?, completionTokens: Int?) -> Double? {
        guard promptTokens != nil || completionTokens != nil else { return nil }
        let pricing = OpenAIImagePricing.gptImage25
        let total = (Double(max(0, promptTokens ?? 0)) * max(pricing.textInputCostPerMillionTokensUSD, pricing.imageInputCostPerMillionTokensUSD)
                     + Double(max(0, completionTokens ?? 0)) * pricing.imageOutputCostPerMillionTokensUSD) / 1_000_000
        return total.isFinite && total > 0 ? total : nil
    }

    /// Error answer → typed error (pure, selftest seam).
    static func classifyError(status: Int, message: String) -> ServiceError {
        if status == 404 || status == 502 {
            return .unavailable(status: status, message: message, verification: false)
        }
        if status == 403, OpenAIImageService.isVerificationRefusal(message) {
            return .unavailable(status: status, message: message, verification: true)
        }
        return .api(status: status, message: message)
    }

    // MARK: Request

    func generateImage(apiKey: String, prompt: String, sourceImageData: Data?, sourceMimeType: String?,
                       engine: String?, quality: String?, background: String?,
                       size: String?, aspectRatio: String? = nil) async throws -> Result {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ServiceError.notConfigured }
        var options = try Self.resolve(engine: engine, quality: quality, background: background,
                                       size: size, aspectRatio: aspectRatio)
        var reference: (data: Data, mime: String)? = nil
        if let sourceImageData {
            let payload = try Self.referencePayload(sourceImageData, declaredMime: sourceMimeType)
            reference = (payload.data, payload.mime)
            if let note = payload.note { options.notes.append(note) }
        }
        func makeRequest(_ options: Options) throws -> URLRequest {
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.requestBody(options: options, prompt: prompt, reference: reference)
            return request
        }

        var (data, response, ticket) = try await send(try makeRequest(options))
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var decoded = try? JSONDecoder().decode(ImagesResponse.self, from: data)
        // Guard for the undocumented `size` passthrough: exactly one retry,
        // without size, at the nearest supported aspect ratio.
        if let sentSize = options.size,
           Self.isSizeFieldRejection(status: status, error: decoded?.error, sentSize: true),
           let ratio = Self.nearestAspectRatio(forSize: sentSize) {
            options = Options(engine: options.engine, model: options.model, quality: options.quality,
                              background: options.background, size: nil, aspectRatio: ratio,
                              notes: options.notes + ["size \(sentSize) is not available through OpenRouter right now; rendered at aspect_ratio \(ratio) instead (about 1024–1536 px on the long side)."])
            DebugTelemetry.log(.info, summary: "OpenRouter image size rejected",
                detail: "size=\(sentSize) refused by OpenRouter (HTTP 400); retrying once at aspect_ratio \(ratio)")
            settle(ticket, complete: true)   // OpenRouter's own refusal: nothing rendered
            (data, response, ticket) = try await send(try makeRequest(options))
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            decoded = try? JSONDecoder().decode(ImagesResponse.self, from: data)
        }
        // An error answer renders nothing; a 200 is complete only when its
        // usage establishes the whole charge (otherwise the remainder stays
        // an unknown-amount incident).
        let charge = Self.charge(decoded?.usage)
        settle(ticket, complete: status != 200 || decoded?.error != nil || charge.complete)
        let errorMessage = decoded?.error?.message
            ?? String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "no error body"
        guard status == 200 else { throw Self.classifyError(status: status, message: errorMessage) }
        if let error = decoded?.error {
            let code = error.code.map { Int($0.value) } ?? 0
            throw Self.classifyError(status: code > 0 ? code : 500, message: error.message ?? "error in the reply")
        }
        let spend = charge.usd
        guard let item = decoded?.data?.first, let b64 = item.b64JSON,
              let image = Data(base64Encoded: b64), !image.isEmpty else {
            throw ServiceError.noImage(detail: decoded == nil ? "unreadable reply" : "", spendUSD: spend)
        }
        let mime = (item.mediaType?.isEmpty == false ? item.mediaType : nil) ?? ModelImage.sniff(image).mime
        let actual = Self.pixelSize(image)
        if let requested = options.size, let actual, actual != requested {
            // Reported, never re-rendered: the smaller image may already be billed.
            options.notes.append("Requested size \(requested) but OpenRouter returned \(actual): the size was not applied.")
        }
        let result = Result(data: image, mimeType: mime, spendUSD: spend, options: options,
                            byok: decoded?.usage?.isByok == true, actualSize: actual)
        DebugTelemetry.log(.info, summary: "OpenRouter image usage",
            detail: "model=\(options.model) engine=\(options.engine) quality=\(options.quality) size=\(options.size ?? options.aspectRatio ?? "auto") edit=\(reference != nil) byok=\(result.byok) prompt_tokens=\(decoded?.usage?.promptTokens.map(String.init) ?? "-") completion_tokens=\(decoded?.usage?.completionTokens.map(String.init) ?? "-") spend=\(spend.map { String(format: "%.6f", $0) } ?? "unknown")")
        return result
    }

    struct Ticket { let chargeId: UUID; let sentAt: Date }

    /// Close the in-flight record of an ANSWERED send: complete → ended;
    /// otherwise → an unknown-amount incident for what the reply left unknown.
    private func settle(_ ticket: Ticket, complete: Bool) {
        if complete {
            ToolChargeLedger.endInFlight(chargeId: ticket.chargeId)
        } else {
            ToolChargeLedger.abandonInFlight(chargeId: ticket.chargeId, generationId: nil, provider: "OpenRouter",
                                             stage: Self.spendStage, reason: "answered without a complete cost",
                                             startedAt: ticket.sentAt)
        }
    }

    /// One paid send: spend gate, write-ahead in-flight record, transport.
    /// No retry of any kind. A reply returns its open record (the caller
    /// settles it once the usage is read); a
    /// timeout, a cancellation or a connection lost after the request may
    /// have reached OpenRouter becomes an unknown-amount incident; a failure
    /// that demonstrably happened before sending (DNS, connect, TLS) ends
    /// the record without one.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse, Ticket) {
        try Task.checkCancellation()
        if let pause = SpendGate.pauseReason() { throw ServiceError.notSent(pause) }
        let chargeId = UUID()
        do { try ToolChargeLedger.beginInFlight(chargeId: chargeId, stage: Self.spendStage) } catch {
            throw ServiceError.notSent("its spend could not be tracked durably (\(error.localizedDescription))")
        }
        let sentAt = Date()
        do {
            let (data, response) = try await transport(request)
            return (data, response, Ticket(chargeId: chargeId, sentAt: sentAt))
        } catch is CancellationError {
            ToolChargeLedger.abandonInFlight(chargeId: chargeId, generationId: nil, provider: "OpenRouter",
                                             stage: Self.spendStage, reason: "cancelled while open", startedAt: sentAt)
            throw CancellationError()
        } catch let urlError as URLError {
            if urlError.code == .cancelled {
                ToolChargeLedger.abandonInFlight(chargeId: chargeId, generationId: nil, provider: "OpenRouter",
                                                 stage: Self.spendStage, reason: "cancelled while open", startedAt: sentAt)
                throw CancellationError()
            }
            if ExtractorDeadline.demonstrablyUnsent(urlError) {
                ToolChargeLedger.endInFlight(chargeId: chargeId)
                throw ServiceError.notSent("OpenRouter could not be reached (\(urlError.localizedDescription))")
            }
            let timedOut = urlError.code == .timedOut
            ToolChargeLedger.abandonInFlight(chargeId: chargeId, generationId: nil, provider: "OpenRouter",
                                             stage: Self.spendStage,
                                             reason: timedOut ? "timed out" : "connection failed before its reply completed",
                                             startedAt: sentAt)
            throw timedOut ? ServiceError.timedOut : ServiceError.connectionFailed(urlError.localizedDescription)
        } catch {
            ToolChargeLedger.abandonInFlight(chargeId: chargeId, generationId: nil, provider: "OpenRouter",
                                             stage: Self.spendStage, reason: "failed before its reply completed", startedAt: sentAt)
            throw ServiceError.connectionFailed(error.localizedDescription)
        }
    }
}

// MARK: - Schemas shown only on the OpenRouter lane without an OpenAI key

extension AvailableTools {
    static let openRouterGenerateImage = ToolDefinition(
        function: FunctionDefinition(
            name: "generate_image",
            description: "Generate an image with OpenAI GPT Image 2.5 through OpenRouter, or edit, restyle or take inspiration from one stored source image. Use when the user asks you to create, generate, draw, make, edit, transform, restyle, or use an image as inspiration. The image is saved and shown to you; it is not sent to the user automatically — use send_document_to_chat to share it. Provide source_image when the user refers to a specific prior image; this tool does not infer the most recent image automatically.",
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
                        description: "Optional image engine. Use 'fast' (GPT Image 2.5 Flare) by default. Choose 'precise' (GPT Image 2.5 Sunburst) for careful edits that must preserve subjects, faces, text, or layout.",
                        enumValues: OpenRouterImageService.engines
                    ),
                    "size": ParameterProperty(
                        type: "string",
                        description: "Optional output size. Use 'auto' by default, or any valid WIDTHxHEIGHT where both edges are multiples of 16, max edge is 3840px, aspect ratio is at most 3:1, and total pixels are 655,360 through 8,294,400. Good choices: 1024x1024, 1536x1024, 1024x1536, 2048x2048, 2048x1152, 3840x2160, 2160x3840."
                    ),
                    "quality": ParameterProperty(
                        type: "string",
                        description: "Optional rendering quality. Use 'auto' by default; use 'high' when detail and fidelity matter more than latency. 'xhigh' and 'max' cost more and are for explicit user requests for maximum detail.",
                        enumValues: OpenRouterImageService.qualities
                    ),
                    "background": ParameterProperty(
                        type: "string",
                        description: "Optional background behavior. 'transparent' gives a PNG with a transparent background (stickers, icons, logos); 'opaque' forces a filled background; 'auto' by default.",
                        enumValues: OpenRouterImageService.backgrounds
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
