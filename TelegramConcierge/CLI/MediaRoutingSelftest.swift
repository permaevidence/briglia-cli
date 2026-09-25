import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `briglia __media-routing-selftest` — the OpenRouter lane without an
/// OpenAI key (owner decision 2026-09-25): voice transcription, image
/// generation and OCR route to OpenRouter only when no OpenAI key is
/// configured and the main provider is OpenRouter with a key; with an OpenAI
/// key everything (requests and tool schemas) is exactly as before.
/// Every request goes to an injected recording transport: no live key, no
/// network. Storage is isolated under a temp XDG root.
struct MediaRoutingSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__media-routing-selftest", shouldDisplay: false)

    /// Live mode (manual, never in CI): one transcription of this audio file
    /// and one fast image through OpenRouter with BRIGLIA_TEST_OPENROUTER_KEY.
    @Option(name: .customLong("live-audio")) var liveAudio: String?

    func run() async throws {
        if let liveAudio {
            guard let key = ProcessInfo.processInfo.environment["BRIGLIA_TEST_OPENROUTER_KEY"], !key.isEmpty else {
                throw ValidationError("set BRIGLIA_TEST_OPENROUTER_KEY")
            }
            let url = URL(fileURLWithPath: liveAudio)
            let text = try await OpenAITranscriptionService().transcribeAudioFile(url: url, apiKey: key,
                prompt: TranscriptionVocabulary.chatHint(assistantName: nil, userName: nil), endpoint: .openRouter)
            print("live transcript: \(text)")
            let srt = try await OpenAITranscriptionService().transcribeAudioFileSRT(url: url, apiKey: key, endpoint: .openRouter)
            print("live srt:\n\(srt)")
            let image = try await OpenRouterImageService().generateImage(apiKey: key, prompt: "A tiny green leaf icon on white, flat.",
                sourceImageData: nil, sourceMimeType: nil, engine: "fast", aspectRatio: "1:1", size: nil)
            print("live image: \(image.mimeType) \(image.data.count) bytes, model \(image.model), spend \(image.spendUSD.map { String($0) } ?? "nil")")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-media-routing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (key, dir) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(dir).path, 1)
        }
        setenv("TMPDIR", root.path + "/", 1)
        defer { try? FileManager.default.removeItem(at: root) }
        StoragePaths.ensureRoots()

        let c = ResponsesSelftest.Checks()
        try await Self.routing(c)
        try await Self.schemas(c)
        try await Self.transcription(c, root: root)
        try await Self.images(c)
        try await Self.ocr(c)
        print("Media routing selftest: \(c.total - c.failures)/\(c.total)")
        if c.failures > 0 { throw ValidationError("Media routing checks failed") }
    }

    // MARK: Fixtures (synthetic key shapes only)

    static let openAIKey = "sk-synthetic-openai-0123456789"
    static let openRouterKey = "sk-or-synthetic-0123456789"
    static let geminiKey = "synthetic-gemini-0123456789"

    /// Replace every setting this suite reads with exactly `values`.
    static func set(_ values: [String: String]) throws {
        let keys = [KeychainHelper.llmProviderKey, KeychainHelper.openRouterApiKeyKey,
                    KeychainHelper.openAITranscriptionApiKeyKey, KeychainHelper.openAIImageApiKeyKey,
                    KeychainHelper.webSearchOpenAIApiKeyKey, KeychainHelper.imageGenerationProviderKey,
                    KeychainHelper.geminiApiKeyKey, KeychainHelper.visionPreprocessorBackendKey,
                    KeychainHelper.voiceTranscriptionProviderKey]
        var batch: [String: String?] = [:]
        for key in keys { batch[key] = values[key].map { Optional($0) } ?? String?.none }
        try KeychainHelper.saveBatch(batch)
    }

    static let orLane: [String: String] = [KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue,
                                            KeychainHelper.openRouterApiKeyKey: openRouterKey]
    static let openAIKeys: [String: String] = [KeychainHelper.openAITranscriptionApiKeyKey: openAIKey,
                                                KeychainHelper.openAIImageApiKeyKey: openAIKey,
                                                KeychainHelper.webSearchOpenAIApiKeyKey: openAIKey,
                                                KeychainHelper.imageGenerationProviderKey: "openai",
                                                KeychainHelper.visionPreprocessorBackendKey: "openai"]
    /// What "remove the OpenAI key" leaves behind: the provider selections.
    static let openAIRemoved: [String: String] = [KeychainHelper.imageGenerationProviderKey: "openai",
                                                   KeychainHelper.visionPreprocessorBackendKey: "openai"]

    // MARK: 1. The rule

    static func routing(_ c: ResponsesSelftest.Checks) async throws {
        let both = orLane.merging(openAIKeys) { a, _ in a }
        c.check("rule: OpenAI key + OpenRouter lane → voice on OpenAI (unchanged)",
                MediaRouting.transcription(stored: both) == .openAI(key: openAIKey))
        c.check("rule: OpenAI key + OpenRouter lane → images on OpenAI (unchanged)",
                MediaRouting.imageBackend(stored: both) == .openAI)
        c.check("rule: OpenAI key with the default (Gemini) provider stays Gemini, even on OpenRouter",
                MediaRouting.imageBackend(stored: orLane.merging([KeychainHelper.openAIImageApiKeyKey: openAIKey]) { a, _ in a }) == .gemini)
        c.check("rule: no OpenAI key + OpenRouter lane → voice via OpenRouter with its key",
                MediaRouting.transcription(stored: orLane) == .openRouter(key: openRouterKey))
        c.check("rule: no OpenAI key + OpenRouter lane → images via OpenRouter",
                MediaRouting.imageBackend(stored: orLane) == .openRouter)
        c.check("rule: a removed OpenAI key (stored provider 'openai' left) → OpenRouter on its lane",
                MediaRouting.imageBackend(stored: orLane.merging(openAIRemoved) { a, _ in a }) == .openRouter
                && MediaRouting.transcription(stored: orLane.merging(openAIRemoved) { a, _ in a }).viaOpenRouter)
        c.check("rule: a configured Google key with the Gemini provider stays on Gemini",
                MediaRouting.imageBackend(stored: orLane.merging([KeychainHelper.geminiApiKeyKey: geminiKey]) { a, _ in a }) == .gemini)
        var otherProvider = orLane
        otherProvider[KeychainHelper.llmProviderKey] = LLMProvider.openAICompatible.rawValue
        c.check("rule: another main provider with a leftover OpenRouter key → current behavior (no key)",
                MediaRouting.transcription(stored: otherProvider) == .openAI(key: "")
                && MediaRouting.imageBackend(stored: otherProvider) == .gemini)
        c.check("rule: OpenRouter selected but no OpenRouter key → current behavior",
                MediaRouting.transcription(stored: [KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue]) == .openAI(key: "")
                && MediaRouting.imageBackend(stored: [KeychainHelper.llmProviderKey: LLMProvider.openRouter.rawValue, KeychainHelper.imageGenerationProviderKey: "openai"]) == .openAI)
        c.check("rule: whitespace-only keys count as absent",
                MediaRouting.transcription(stored: orLane.merging([KeychainHelper.openAITranscriptionApiKeyKey: "  "]) { a, _ in a }).viaOpenRouter)
        c.check("rule: status wording — openai / openrouter / nothing",
                MediaRouting.voiceAndImagesVia(stored: both) == "openai" && MediaRouting.voiceAndImagesVia(stored: orLane) == "openrouter"
                && MediaRouting.voiceAndImagesVia(stored: otherProvider) == nil)
        // Decided at call time: the stored-settings accessor follows a switch.
        try set(orLane)
        let first = MediaRouting.transcription.viaOpenRouter
        try set(otherProvider)
        c.check("rule: decided at call time (a /provider switch is followed immediately)",
                first && !MediaRouting.transcription.viaOpenRouter && MediaRouting.imageBackend == .gemini)
    }

    // MARK: 2. Tool schemas

    static func encode(_ tool: ToolDefinition) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(tool)
    }

    static func schemas(_ c: ResponsesSelftest.Checks) async throws {
        // Reference: an OpenAI setup that is not on the OpenRouter lane.
        try set(openAIKeys)
        let openAIImage = try encode(AvailableTools.generateImage)
        let openAITranscribe = try encode(AvailableTools.transcribeMedia)
        try set(openAIKeys.merging(orLane) { a, _ in a })
        c.check("schema: with an OpenAI key the image schema is byte-identical on the OpenRouter lane",
                try encode(AvailableTools.generateImage) == openAIImage)
        c.check("schema: with an OpenAI key transcribe_media is byte-identical on the OpenRouter lane",
                try encode(AvailableTools.transcribeMedia) == openAITranscribe)
        c.check("schema: the OpenAI image schema still carries GPT Image 2.5 options",
                AvailableTools.generateImage.function.parameters.properties["quality"] != nil
                && AvailableTools.generateImage.function.description.contains("GPT Image 2.5"))
        // The default (Gemini) schema, no keys, not on the lane.
        try set([:])
        let gemini = try encode(AvailableTools.generateImage)
        let plainTranscribe = try encode(AvailableTools.transcribeMedia)
        c.check("schema: with no keys and no OpenRouter lane the Gemini schema is unchanged",
                AvailableTools.generateImage.function.description.contains("using Gemini")
                && plainTranscribe == openAITranscribe)
        var leftover = orLane; leftover[KeychainHelper.llmProviderKey] = LLMProvider.openAICompatible.rawValue
        try set(leftover)
        c.check("schema: a leftover OpenRouter key on another provider changes nothing",
                try encode(AvailableTools.generateImage) == gemini && encode(AvailableTools.transcribeMedia) == openAITranscribe)

        try set(orLane)
        let tool = AvailableTools.generateImage.function
        let props = tool.parameters.properties
        c.check("schema: OpenRouter lane without OpenAI → Gemini-via-OpenRouter image schema, same tool name",
                tool.name == "generate_image" && tool.description.contains("through OpenRouter") && tool.parameters.required == ["prompt"])
        c.check("schema: OpenRouter image parameters are the Gemini ones",
                Set(props.keys) == ["prompt", "source_image", "source_image_role", "engine", "aspect_ratio", "size"]
                && props["engine"]?.enumValues == ["best", "fast"]
                && props["aspect_ratio"]?.enumValues == OpenRouterImageService.aspectRatios
                && props["size"]?.enumValues == ["1K", "2K", "4K"])
        c.check("schema: no GPT Image options leak into the OpenRouter schema",
                props["quality"] == nil && props["background"] == nil && props["output_format"] == nil && props["moderation"] == nil)
        c.check("schema: transcribe_media says OpenRouter on the lane, OpenAI otherwise",
                AvailableTools.transcribeMedia.function.description.contains("through OpenRouter")
                && !AvailableTools.transcribeMedia.function.description.contains("requires the OpenAI key"))
        c.check("schema: the OpenRouter tool is in the main inventory",
                AvailableTools.coreTools(webSearchAvailable: false).contains { $0.function.name == "generate_image" && $0.function.description.contains("through OpenRouter") })
        let args = try JSONDecoder().decode(GenerateImageArguments.self, from: Data(#"{"prompt":"p","engine":"fast","aspect_ratio":"16:9","size":"2K"}"#.utf8))
        c.check("schema: tool arguments decode aspect_ratio", args.aspectRatio == "16:9" && args.engine == "fast" && args.size == "2K")
    }

    // MARK: 3. Transcription requests

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var respond: (URLRequest) -> (Int, Data)
        init(_ respond: @escaping (URLRequest) -> (Int, Data)) { self.respond = respond }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { [self] request in
                lock.lock(); _requests.append(request); lock.unlock()
                let (status, body) = respond(request)
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    static func formFields(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for part in body.components(separatedBy: "Content-Disposition: form-data; name=\"").dropFirst() {
            guard let nameEnd = part.firstIndex(of: "\"") else { continue }
            let name = String(part[..<nameEnd])
            guard let valueStart = part.range(of: "\r\n\r\n")?.upperBound else { continue }
            let rest = part[valueStart...]
            out[name] = String(rest[..<(rest.range(of: "\r\n")?.lowerBound ?? rest.endIndex)])
        }
        return out
    }

    static func transcription(_ c: ResponsesSelftest.Checks, root: URL) async throws {
        let audio = root.appendingPathComponent("note.m4a")
        try Data("fake-audio".utf8).write(to: audio)
        let recorder = Recorder { request in
            let fields = formFields(request)
            if fields["response_format"] == "verbose_json" {
                return (200, Data(#"{"text":"Hi Bree. Bye.","segments":[{"start":0,"end":1.25,"text":" Hi Bree."},{"start":1.25,"end":3661.5,"text":" Bye."},{"start":4,"end":5,"text":"  "}],"usage":{"seconds":4,"cost":0}}"#.utf8))
            }
            if fields["response_format"] == "srt" { return (200, Data("1\n00:00:00,000 --> 00:00:01,000\nHi".utf8)) }
            return (200, Data(#"{"text":"Hello Bree","usage":{"seconds":4,"cost":0}}"#.utf8))
        }
        let service = OpenAITranscriptionService(transport: recorder.transport)
        _ = try await service.transcribeAudioFile(url: audio, apiKey: openAIKey, prompt: "Names: Bree (the assistant).")
        var r = recorder.requests.last!
        var f = formFields(r)
        c.check("voice: OpenAI request unchanged (api.openai.com, gpt-transcribe, prompt, Bearer)",
                r.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions" && f["model"] == "gpt-transcribe"
                && f["prompt"] == "Names: Bree (the assistant)." && r.value(forHTTPHeaderField: "Authorization") == "Bearer \(openAIKey)")
        let text = try await service.transcribeAudioFile(url: audio, apiKey: openRouterKey, prompt: "Names: Bree (the assistant).", endpoint: .openRouter)
        r = recorder.requests.last!; f = formFields(r)
        c.check("voice: OpenRouter request (openrouter.ai, openai/gpt-transcribe, same prompt hint, OpenRouter key)",
                text == "Hello Bree" && r.url?.absoluteString == "https://openrouter.ai/api/v1/audio/transcriptions"
                && f["model"] == "openai/gpt-transcribe" && f["prompt"] == "Names: Bree (the assistant)."
                && r.value(forHTTPHeaderField: "Authorization") == "Bearer \(openRouterKey)" && f["response_format"] == nil)
        _ = try await service.transcribeAudioFileSRT(url: audio, apiKey: openAIKey)
        f = formFields(recorder.requests.last!)
        c.check("voice: OpenAI SRT unchanged (whisper-1, srt)", f["model"] == "whisper-1" && f["response_format"] == "srt")
        let srt = (try? await service.transcribeAudioFileSRT(url: audio, apiKey: openRouterKey, language: "en", endpoint: .openRouter)) ?? "<threw>"
        r = recorder.requests.last!; f = formFields(r)
        c.check("voice: OpenRouter SRT asks whisper-1 for verbose_json (OpenRouter serves no srt)",
                r.url?.host == "openrouter.ai" && f["model"] == "openai/whisper-1" && f["response_format"] == "verbose_json" && f["language"] == "en")
        c.check("voice: SRT is built locally from the segments (blank cues skipped, hours rendered)",
                srt == "1\n00:00:00,000 --> 00:00:01,250\nHi Bree.\n\n2\n00:00:01,250 --> 01:01:01,500\nBye.")
        recorder.respond = { _ in (401, Data(#"{"error":{"message":"No auth credentials found","code":401}}"#.utf8)) }
        do {
            _ = try await service.transcribeAudioFile(url: audio, apiKey: openRouterKey, endpoint: .openRouter)
            c.check("voice: an OpenRouter error surfaces with its status and message", false)
        } catch { c.check("voice: an OpenRouter error surfaces with its status and message", error.localizedDescription == "HTTP 401: No auth credentials found") }
        do {
            _ = try await service.transcribeAudioFile(url: audio, apiKey: " ", endpoint: .openRouter)
            c.check("voice: an empty key names the right service", false)
        } catch { c.check("voice: an empty key names the right service", error.localizedDescription.contains("OpenRouter")) }

        // The transcribe_media tool picks the route at call time.
        recorder.respond = { _ in (200, Data(#"{"text":"Tool transcript"}"#.utf8)) }
        OpenAITranscriptionService.overrideForTesting = service
        defer { OpenAITranscriptionService.overrideForTesting = nil }
        let executor = ToolExecutor(outputMode: .subagent)
        func runTool() async throws -> String {
            let call = ToolCall(id: "t1", type: "function", function: FunctionCall(name: "transcribe_media", arguments: #"{"path":"\#(audio.path)"}"#))
            return try await executor.execute(call).content
        }
        try set(orLane)
        var out = try await runTool()
        c.check("voice: transcribe_media on the OpenRouter lane goes to OpenRouter",
                recorder.requests.last?.url?.host == "openrouter.ai" && out.contains("openrouter/openai/gpt-transcribe") && out.contains("Tool transcript"))
        try set(orLane.merging(openAIKeys) { a, _ in a })
        out = try await runTool()
        c.check("voice: with an OpenAI key transcribe_media stays on OpenAI",
                recorder.requests.last?.url?.host == "api.openai.com" && out.contains("\"openai/gpt-transcribe\""))
        try set([:])
        let before = recorder.requests.count
        out = try await runTool()
        c.check("voice: neither key → today's error, no request", recorder.requests.count == before && out.contains("No OpenAI API key"))
    }

    // MARK: 4. Images

    static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6z8AAAAASUVORK5CYII="

    static func images(_ c: ResponsesSelftest.Checks) async throws {
        let generate = try OpenRouterImageService.requestBody(model: OpenRouterImageService.bestModel, prompt: "A red bicycle",
            sourceImageData: nil, sourceMimeType: nil, aspectRatio: "16:9", size: "2K")
        c.check("image: generation body (modalities, image_config, usage, plain prompt)",
                String(decoding: generate, as: UTF8.self) == #"{"image_config":{"aspect_ratio":"16:9","image_size":"2K"},"messages":[{"content":"A red bicycle","role":"user"}],"modalities":["image","text"],"model":"google/gemini-3-pro-image","usage":{"include":true}}"#)
        let edit = try OpenRouterImageService.requestBody(model: OpenRouterImageService.fastModel, prompt: "Make it yellow",
            sourceImageData: Data([1, 2, 3]), sourceMimeType: "image/jpeg", aspectRatio: nil, size: nil)
        c.check("image: edit body puts the input image first, no image_config when unset",
                String(decoding: edit, as: UTF8.self) == #"{"messages":[{"content":[{"image_url":{"url":"data:image/jpeg;base64,AQID"},"type":"image_url"},{"text":"Make it yellow","type":"text"}],"role":"user"}],"modalities":["image","text"],"model":"google/gemini-3.1-flash-image","usage":{"include":true}}"#)
        c.check("image: engines map to Pro (best, default) and Flash (fast)",
                try OpenRouterImageService.resolve(engine: nil, aspectRatio: nil, size: nil).model == "google/gemini-3-pro-image"
                && OpenRouterImageService.resolve(engine: " FAST ", aspectRatio: nil, size: nil).model == "google/gemini-3.1-flash-image")
        c.rejects("image: an unknown engine is refused") { _ = try OpenRouterImageService.resolve(engine: "precise", aspectRatio: nil, size: nil) }
        c.rejects("image: an unsupported aspect ratio is refused") { _ = try OpenRouterImageService.resolve(engine: nil, aspectRatio: "7:3", size: nil) }
        c.rejects("image: an unsupported size is refused") { _ = try OpenRouterImageService.resolve(engine: nil, aspectRatio: nil, size: "8K") }

        let ok = #"{"choices":[{"message":{"content":"","images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(pngBase64)"}}]}}],"usage":{"cost":0.0672065}}"#
        let recorder = Recorder { _ in (200, Data(ok.utf8)) }
        let service = OpenRouterImageService(transport: recorder.transport)
        let result = try await service.generateImage(apiKey: openRouterKey, prompt: "A red bicycle", sourceImageData: nil,
            sourceMimeType: nil, engine: nil, aspectRatio: "16:9", size: nil)
        let request = recorder.requests.last!
        c.check("image: request goes to OpenRouter chat completions with the OpenRouter key",
                request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions"
                && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(openRouterKey)" && request.httpMethod == "POST")
        c.check("image: the data-URL image is decoded", result.data == Data(base64Encoded: pngBase64) && result.mimeType == "image/png")
        c.check("image: spend is OpenRouter's reported usage.cost", result.spendUSD == 0.0672065)
        recorder.respond = { _ in (402, Data(#"{"error":{"message":"Insufficient credits","code":402}}"#.utf8)) }
        do { _ = try await service.generateImage(apiKey: openRouterKey, prompt: "p", sourceImageData: nil, sourceMimeType: nil, engine: nil, aspectRatio: nil, size: nil); c.check("image: HTTP errors surface", false) }
        catch { c.check("image: HTTP errors surface", error.localizedDescription.contains("HTTP 402: Insufficient credits")) }
        recorder.respond = { _ in (200, Data(#"{"error":{"message":"upstream failed","code":502}}"#.utf8)) }
        do { _ = try await service.generateImage(apiKey: openRouterKey, prompt: "p", sourceImageData: nil, sourceMimeType: nil, engine: nil, aspectRatio: nil, size: nil); c.check("image: an error inside HTTP 200 surfaces", false) }
        catch { c.check("image: an error inside HTTP 200 surfaces", error.localizedDescription.contains("upstream failed")) }
        recorder.respond = { _ in (200, Data(#"{"choices":[{"message":{"content":"I can't draw that."}}],"usage":{"cost":0.001}}"#.utf8)) }
        do { _ = try await service.generateImage(apiKey: openRouterKey, prompt: "p", sourceImageData: nil, sourceMimeType: nil, engine: nil, aspectRatio: nil, size: nil); c.check("image: no image → the model's words", false) }
        catch { c.check("image: no image → the model's words", error.localizedDescription.contains("I can't draw that.")) }

        // Through the real tool executor: file saved, attachment, spend.
        recorder.respond = { _ in (200, Data(ok.utf8)) }
        ToolExecutor.openRouterImageServiceOverrideForTesting = service
        defer { ToolExecutor.openRouterImageServiceOverrideForTesting = nil }
        try set(orLane)
        let images = StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        try PrivateStorage.ensureDirectory(images)
        try Data(base64Encoded: pngBase64)!.write(to: images.appendingPathComponent("source.png"))
        let executor = ToolExecutor(outputMode: .subagent)
        let call = ToolCall(id: "img1", type: "function", function: FunctionCall(name: "generate_image",
            arguments: #"{"prompt":"Make the background yellow","source_image":"source.png","source_image_role":"edit","engine":"fast","aspect_ratio":"21:9","size":"1K"}"#))
        let toolResult = try await executor.execute(call)
        let sent = try JSONSerialization.jsonObject(with: recorder.requests.last!.httpBody!) as! [String: Any]
        let content = ((sent["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        c.check("image tool: OpenRouter lane → one OpenRouter request with the source image and the edit framing",
                sent["model"] as? String == "google/gemini-3.1-flash-image"
                && (sent["image_config"] as? [String: String]) == ["aspect_ratio": "21:9", "image_size": "1K"]
                && (content.first?["image_url"] as? [String: String])?["url"]?.hasPrefix("data:image/png;base64,") == true
                && (content.last?["text"] as? String)?.hasPrefix("Edit the input image directly") == true)
        let object = (try? JSONSerialization.jsonObject(with: Data(toolResult.content.utf8))) as? [String: Any] ?? [:]
        let filename = object["filename"] as? String ?? ""
        c.check("image tool: result names OpenRouter (Gemini), the model and the saved file",
                object["success"] as? Bool == true && object["provider"] as? String == "OpenRouter (Gemini)"
                && object["model"] as? String == "google/gemini-3.1-flash-image" && object["via"] as? String == "openrouter"
                && FileManager.default.fileExists(atPath: images.appendingPathComponent(filename).path))
        c.check("image tool: the image is attached for the model and spend is recorded",
                toolResult.fileAttachments.first?.mimeType == "image/png" && toolResult.spendUSD == 0.0672065)
        let bad = ToolCall(id: "img2", type: "function", function: FunctionCall(name: "generate_image", arguments: #"{"prompt":"p","aspect_ratio":"7:3"}"#))
        let before = recorder.requests.count
        let badResult = try await executor.execute(bad)
        c.check("image tool: invalid options are explained without a request",
                recorder.requests.count == before && badResult.content.contains("Invalid aspect_ratio"))
        try set(openAIKeys.merging(orLane) { a, _ in a })
        c.check("image tool: with an OpenAI key the executor takes the OpenAI path (backend decision shared with the schema)",
                MediaRouting.imageBackend == .openAI)
    }

    // MARK: 5. OCR

    static func ocr(_ c: ResponsesSelftest.Checks) async throws {
        let service = OpenRouterService()
        try set(orLane.merging(openAIRemoved) { a, _ in a })
        var backend = await service.resolvedVisionBackend()
        c.check("ocr: stored 'openai' without its key → OpenRouter on its lane (GPT-6 Luna, ZDR)",
                backend?.url == "https://openrouter.ai/api/v1/chat/completions" && backend?.bearer == openRouterKey
                && backend?.model == "openai/gpt-6-luna" && backend?.provider?.zdr == true && backend?.label == "OpenRouter")
        try set(orLane.merging(openAIKeys) { a, _ in a })
        backend = await service.resolvedVisionBackend()
        c.check("ocr: with an OpenAI key OCR stays on OpenAI", backend?.url == "https://api.openai.com/v1/chat/completions" && backend?.bearer == openAIKey)
        var leftover = orLane.merging(openAIRemoved) { a, _ in a }
        leftover[KeychainHelper.llmProviderKey] = LLMProvider.openAICompatible.rawValue
        try set(leftover)
        backend = await service.resolvedVisionBackend()
        c.check("ocr: off the OpenRouter lane a keyless 'openai' choice stays unavailable (current behavior)", backend == nil)
    }
}
