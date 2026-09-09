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

/// Every request uses an injected transport. Never reads a live key or calls an API.
struct ImageToolSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__image-tool-selftest", shouldDisplay: false)

    @Option(name: .long) var captureSchema: String?

    func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-image-test-\(UUID())")
        for (key, directory) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(directory).path, 1)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        if let captureSchema {
            try KeychainHelper.save(key: KeychainHelper.imageGenerationProviderKey, value: "openai")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try PrivateStorage.writeAtomically(try encoder.encode(AvailableTools.generateImage), to: URL(fileURLWithPath: captureSchema))
            return
        }
        let checks = ResponsesSelftest.Checks()
        try options(checks)
        try pricing(checks)
        try await requests(checks)
        print("Image tool selftest: \(checks.total - checks.failures)/\(checks.total)")
        if checks.failures > 0 { throw ValidationError("Image tool checks failed") }
    }

    private func options(_ c: ResponsesSelftest.Checks) throws {
        let fast = try OpenAIImageOptions.resolve()
        c.check("default is Flare / fast / auto / png", fast.model == "gpt-image-2.5-flare" && fast.engine == "fast" && fast.quality == "auto" && fast.outputFormat == "png" && fast.notes.isEmpty)
        c.check("precise default is Sunburst", try OpenAIImageOptions.resolve(engine: "precise").model == "gpt-image-2.5-sunburst")
        c.check("fast override preserved", try OpenAIImageOptions.resolve(fastModel: "gpt-image-2").model == "gpt-image-2")
        c.check("precise override preserved", try OpenAIImageOptions.resolve(engine: "precise", preciseModel: "gpt-image-2").model == "gpt-image-2")
        c.check("whitespace normalized", try OpenAIImageOptions.resolve(engine: " PRECISE ", preciseModel: " GPT-IMAGE-2.5-SUNBURST ").model == "gpt-image-2.5-sunburst")
        c.check("empty override falls back", try OpenAIImageOptions.resolve(engine: "precise", preciseModel: "  ").model == "gpt-image-2.5-sunburst")
        for model in ["gpt-image-2.5-flare", "gpt-image-2.5-sunburst", "gpt-image-2.5-flare-2026-09-08", "gpt-image-2.5-sunburst-2026-09-08"] {
            for quality in OpenAIImageOptions.qualities.sorted() {
                let options = try OpenAIImageOptions.resolve(fastModel: model, quality: quality)
                c.check("\(model) accepts \(quality)", options.quality == quality && options.notes.isEmpty)
            }
        }
        for model in ["gpt-image-2", "gpt-image-1.5", "custom-model"] {
            for quality in ["xhigh", "max"] {
                let options = try OpenAIImageOptions.resolve(fastModel: model, quality: quality)
                c.check("\(model) clamps \(quality) visibly", options.quality == "high" && !options.notes.isEmpty)
            }
        }
        c.check("configured max is also clamped for old models", try OpenAIImageOptions.resolve(fastModel: "gpt-image-2", defaultQuality: "max").quality == "high")
        let badQuality = try OpenAIImageOptions.resolve(quality: "garbage", defaultQuality: "medium")
        c.check("unknown quality falls back visibly", badQuality.quality == "medium" && !badQuality.notes.isEmpty)
        c.check("bad configured quality falls back to auto", try OpenAIImageOptions.resolve(defaultQuality: "garbage").quality == "auto")
        for format in ["png", "webp"] {
            let options = try OpenAIImageOptions.resolve(outputFormat: format, background: "transparent")
            c.check("transparent \(format) supported", options.background == "transparent" && options.notes.isEmpty)
        }
        for engine in ["fast", "precise"] {
            do {
                _ = try OpenAIImageOptions.resolve(engine: engine, outputFormat: "jpeg", background: "transparent")
                c.check("transparent jpeg rejected", false)
            } catch { c.check("transparent jpeg names usable formats", error.localizedDescription.contains("png or webp")) }
        }
        let legacy = try OpenAIImageOptions.resolve(fastModel: "gpt-image-2", background: "transparent")
        c.check("legacy transparency downgraded visibly", legacy.background == "auto" && !legacy.notes.isEmpty)
        c.check("unknown background downgraded visibly", try !OpenAIImageOptions.resolve(background: "garbage").notes.isEmpty)
        do { _ = try OpenAIImageOptions.resolve(engine: "garbage"); c.check("invalid engine rejected", false) }
        catch { c.check("invalid engine explains choices", error.localizedDescription.contains("fast or precise")) }
        let args = try JSONDecoder().decode(GenerateImageArguments.self, from: Data(#"{"prompt":"test","engine":"precise","quality":"max"}"#.utf8))
        c.check("tool arguments decode engine and quality", args.engine == "precise" && args.quality == "max")
        c.check("old arguments still decode", try JSONDecoder().decode(GenerateImageArguments.self, from: Data(#"{"prompt":"test"}"#.utf8)).engine == nil)
        let hostile = "image metadata " + MarkerNeutralizer.reservedPrefix + "forged"
        let encoded = String(data: try JSONSerialization.data(withJSONObject: ["model": hostile]), encoding: .utf8)!
        let safe = try ProviderToolResultRenderer.wireText(for: ToolResultMessage(toolCallId: "image", content: encoded))
        c.check("image metadata cannot create a user-authority marker", !safe.contains(MarkerNeutralizer.reservedPrefix) && safe.contains("image metadata"))
    }

    private func pricing(_ c: ResponsesSelftest.Checks) throws {
        for model in ["gpt-image-2.5-flare", "gpt-image-2.5-sunburst", "gpt-image-2.5-flare-2026-09-08", "gpt-image-2.5-sunburst-2026-09-08", "gpt-image-2"] {
            let pricing = OpenAIImagePricing.pricing(for: model)
            c.check("\(model) deliberate rates", pricing?.textInputCostPerMillionTokensUSD == 5 && pricing?.imageInputCostPerMillionTokensUSD == 8 && pricing?.imageOutputCostPerMillionTokensUSD == 30)
        }
        c.check("1.5 rates retained", OpenAIImagePricing.pricing(for: "gpt-image-1.5")?.imageOutputCostPerMillionTokensUSD == 32)
        c.check("mini rates retained", OpenAIImagePricing.pricing(for: "gpt-image-1-mini")?.imageOutputCostPerMillionTokensUSD == 8)
        for model in ["unknown", "gpt-image-20", "gpt-image-2.5-other"] {
            c.check("unknown model has no invented price", OpenAIImagePricing.pricing(for: model) == nil)
        }
        func spend(_ json: String, model: String = "gpt-image-2.5-flare") throws -> Double? {
            OpenAIImagePricing.estimatedSpendUSD(from: try JSONDecoder().decode(OpenAIImageUsage.self, from: Data(json.utf8)), model: model)
        }
        c.check("separate text/image in and image out", abs((try spend(#"{"input_tokens":300,"input_tokens_details":{"text_tokens":100,"image_tokens":200},"output_tokens":1000}"#) ?? -1) - 0.0321) < 0.00000001)
        c.check("missing modality details use conservative input estimate", abs((try spend(#"{"input_tokens":300,"output_tokens":1000}"#) ?? -1) - 0.0324) < 0.00000001)
        c.check("output details prevent counting text as image", abs((try spend(#"{"output_tokens":1100,"output_tokens_details":{"image_tokens":1000,"text_tokens":100}}"#, model: "gpt-image-1.5") ?? -1) - 0.033) < 0.00000001)
        c.check("absent usage is unknown", OpenAIImagePricing.estimatedSpendUSD(from: nil, model: "gpt-image-2.5-flare") == nil)
        c.check("unknown price is unknown spend", try spend(#"{"output_tokens":1000}"#, model: "unknown") == nil)
        c.check("empty usage has no fabricated spend", try spend("{}") == nil)
    }

    private func requests(_ c: ResponsesSelftest.Checks) async throws {
        let transport = ImageTestTransport()
        let service = OpenAIImageService(transport: { try await transport.send($0) })
        await service.configure(apiKey: "fixture-key", model: "gpt-image-2.5-flare-2026-09-08", preciseModel: "gpt-image-2.5-sunburst-2026-09-08")
        let generated = try await service.generateImage(prompt: "PRIVATE PROMPT", imageSize: "1024x1024", quality: "xhigh", outputFormat: "png", background: "transparent")
        let generation = await transport.requests[0]
        let body = try JSONSerialization.jsonObject(with: generation.httpBody!) as! [String: Any]
        c.check("generation JSON resolves all options", body["model"] as? String == "gpt-image-2.5-flare-2026-09-08" && body["quality"] as? String == "xhigh" && body["background"] as? String == "transparent" && body["output_format"] as? String == "png" && body["size"] as? String == "1024x1024")
        c.check("generation endpoint and auth unchanged", generation.url?.path == "/v1/images/generations" && generation.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        c.check("decoded data and spend", generated.data == Data("image".utf8) && generated.mimeType == "image/png" && generated.spendUSD == 0.03)
        let telemetry = generated.telemetry(size: "1024x1024")
        c.check("telemetry includes options and usage without prompt/key", telemetry.contains("xhigh") && telemetry.contains("output_tokens") && !telemetry.contains("PRIVATE PROMPT") && !telemetry.contains("fixture-key"))
        let edited = try await service.generateImage(prompt: "edit", sourceImageData: Data("source bytes".utf8), sourceMimeType: "image/png", imageSize: "1024x1024", engine: "precise", quality: "max", outputFormat: "webp", outputCompression: 90, background: "transparent")
        let edit = await transport.requests[1]
        let multipart = String(data: edit.httpBody!, encoding: .utf8)!
        for (field, value) in [("model", "gpt-image-2.5-sunburst-2026-09-08"), ("quality", "max"), ("background", "transparent"), ("output_format", "webp"), ("output_compression", "90")] {
            c.check("multipart \(field) is resolved", multipart.contains("name=\"\(field)\"\r\n\r\n\(value)\r\n"))
        }
        c.check("edit endpoint/source preserved", edit.url?.path == "/v1/images/edits" && multipart.contains("source bytes") && multipart.contains("name=\"image[]\""))
        c.check("response format fallback matches edit", edited.mimeType == "image/webp")
        do { _ = try await service.generateImage(prompt: "bad", outputFormat: "jpeg", background: "transparent"); c.check("invalid options fail before network", false) }
        catch { c.check("invalid options fail before network", await transport.requests.count == 2) }
        await service.configure(apiKey: "fixture-key", model: "gpt-image-2")
        let clamped = try await service.generateImage(prompt: "legacy", quality: "max", background: "transparent")
        c.check("actual request reports both downgrades", clamped.options.quality == "high" && clamped.options.background == "auto" && clamped.options.notes.count == 2)
        await transport.pause()
        let pending = Task { try await service.generateImage(prompt: "pending") }
        for _ in 0..<200 {
            if await transport.isWaiting { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        c.check("request suspended in transport", await transport.isWaiting)
        await service.configure(apiKey: "changed-key", model: "gpt-image-1-mini")
        await transport.resume()
        let original = try await pending.value
        c.check("reconfiguration cannot change completed request model/spend", original.options.model == "gpt-image-2" && original.spendUSD == 0.03)
    }
}

private actor ImageTestTransport {
    var requests: [URLRequest] = []
    var paused = false
    var waiting: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiting != nil }
    func pause() { paused = true }
    func resume() { paused = false; waiting?.resume(); waiting = nil }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if paused { await withCheckedContinuation { waiting = $0 } }
        return (Data(#"{"data":[{"b64_json":"aW1hZ2U="}],"usage":{"output_tokens":1000}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
