import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `briglia __or-image-selftest` — GPT Image 2.5 (Flare/Sunburst) through
/// OpenRouter's Image API on the OpenRouter lane without an OpenAI key
/// (OR_IMAGE_25, 2026-10-30). Pure groups (options, bodies, references,
/// spend, error classes, schema) plus a loopback fake of the Image API for
/// requests, the size guard, every error class (no fallback, no retry),
/// timeouts, cancellation, the write-ahead/unknown-cost rules and the tool
/// executor. No live key, no network; storage under a temp XDG root.
struct OpenRouterImageSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__or-image-selftest", shouldDisplay: false)

    func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-or-image-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (key, dir) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(dir).path, 1)
        }
        setenv("TMPDIR", root.path + "/", 1)
        defer { try? FileManager.default.removeItem(at: root) }
        StoragePaths.ensureRoots()

        let c = ResponsesSelftest.Checks()
        Self.options(c)
        try Self.bodies(c)
        try Self.references(c)
        Self.spend(c)
        Self.errorClasses(c)
        try Self.schema(c)
        try await Self.server(c)
        try await Self.executor(c)
        print("OpenRouter image selftest: \(c.total - c.failures)/\(c.total)")
        if c.failures > 0 { throw ValidationError("OpenRouter image checks failed") }
    }

    typealias S = OpenRouterImageService

    // MARK: 1. Options

    static func options(_ c: ResponsesSelftest.Checks) {
        let d = try? S.resolve(engine: nil, quality: nil, background: nil, size: nil)
        c.check("O1 default: fast = Flare, quality auto, background auto, no size, no ratio, no notes",
                d == S.Options(engine: "fast", model: "openai/gpt-image-2.5-flare", quality: "auto", background: "auto",
                               size: nil, aspectRatio: nil, notes: []))
        c.check("O2 precise = Sunburst (case/whitespace tolerant)",
                (try? S.resolve(engine: " PRECISE ", quality: nil, background: nil, size: nil))?.model == "openai/gpt-image-2.5-sunburst")
        c.rejects("O3 an unknown engine is refused (the retired Gemini 'best')") { _ = try S.resolve(engine: "best", quality: nil, background: nil, size: nil) }
        c.check("O4 every quality passes through unchanged",
                S.qualities.allSatisfy { (try? S.resolve(engine: nil, quality: $0, background: nil, size: nil))?.quality == $0 })
        let badQ = try? S.resolve(engine: nil, quality: "ultra", background: "glass", size: nil)
        c.check("O5 unknown quality/background → auto with a note each (no refusal)",
                badQ?.quality == "auto" && badQ?.background == "auto" && badQ?.notes.count == 2)
        c.check("O6 background transparent/opaque pass through",
                (try? S.resolve(engine: nil, quality: nil, background: "transparent", size: nil))?.background == "transparent"
                && (try? S.resolve(engine: nil, quality: nil, background: "opaque", size: nil))?.background == "opaque")
        c.check("O7 WxH sizes up to 4K pass through (direct-path rules)",
                (try? S.resolve(engine: nil, quality: nil, background: nil, size: "3840x2160"))?.size == "3840x2160"
                && (try? S.resolve(engine: nil, quality: nil, background: nil, size: "2048x2048"))?.size == "2048x2048"
                && (try? S.resolve(engine: nil, quality: nil, background: nil, size: "1024x1536"))?.size == "1024x1536")
        c.check("O8 size aliases resolve like the direct path (4K → 3840x2160) and 'auto' sends nothing",
                (try? S.resolve(engine: nil, quality: nil, background: nil, size: "4K"))?.size == "3840x2160"
                && (try? S.resolve(engine: nil, quality: nil, background: nil, size: "auto"))?.size == nil)
        for bad in ["3840x3840", "1000x1000", "5000x1000", "huge"] {
            c.rejects("O9 invalid size \(bad) is refused before any request") { _ = try S.resolve(engine: nil, quality: nil, background: nil, size: bad) }
        }
        let carried = try? S.resolve(engine: nil, quality: nil, background: nil, size: nil, aspectRatio: "16:9")
        c.check("O10 a carried-over aspect_ratio is kept when no size is given",
                carried?.aspectRatio == "16:9" && carried?.size == nil && carried?.notes.isEmpty == true)
        let both = try? S.resolve(engine: nil, quality: nil, background: nil, size: "2048x2048", aspectRatio: "16:9")
        c.check("O11 size wins over aspect_ratio (never both on the wire), with a note",
                both?.size == "2048x2048" && both?.aspectRatio == nil && both?.notes.count == 1)
        let odd = try? S.resolve(engine: nil, quality: nil, background: nil, size: nil, aspectRatio: "7:3")
        c.check("O12 an unsupported aspect_ratio is ignored with a note, not refused",
                odd?.aspectRatio == nil && odd?.notes.count == 1)
        c.check("O13 nearest aspect ratio for the size guard",
                S.nearestAspectRatio(forSize: "3840x2160") == "16:9" && S.nearestAspectRatio(forSize: "2048x2048") == "1:1"
                && S.nearestAspectRatio(forSize: "1024x1536") == "2:3" && S.nearestAspectRatio(forSize: "3072x1024") == "21:9"
                && S.nearestAspectRatio(forSize: "2160x3840") == "9:16" && S.nearestAspectRatio(forSize: "bad") == nil)
    }

    // MARK: 2. Request bodies

    static func bodies(_ c: ResponsesSelftest.Checks) throws {
        let d = try S.resolve(engine: nil, quality: nil, background: nil, size: nil)
        c.check("B1 defaults send only model + prompt",
                String(decoding: try S.requestBody(options: d, prompt: "A red bicycle", reference: nil), as: UTF8.self)
                == #"{"model":"openai/gpt-image-2.5-flare","prompt":"A red bicycle"}"#)
        let full = try S.resolve(engine: "precise", quality: "high", background: "transparent", size: "3840x2160")
        c.check("B2 options map to size/quality/background (no output_format, no moderation, no n)",
                String(decoding: try S.requestBody(options: full, prompt: "p", reference: nil), as: UTF8.self)
                == #"{"background":"transparent","model":"openai/gpt-image-2.5-sunburst","prompt":"p","quality":"high","size":"3840x2160"}"#)
        c.check("B3 edit: one input_references data URL",
                String(decoding: try S.requestBody(options: d, prompt: "Make it yellow", reference: (Data([1, 2, 3]), "image/jpeg")), as: UTF8.self)
                == #"{"input_references":[{"image_url":{"url":"data:image/jpeg;base64,AQID"},"type":"image_url"}],"model":"openai/gpt-image-2.5-flare","prompt":"Make it yellow"}"#)
        let ratio = try S.resolve(engine: nil, quality: nil, background: nil, size: nil, aspectRatio: "3:2")
        c.check("B4 a carried-over ratio is sent as aspect_ratio",
                String(decoding: try S.requestBody(options: ratio, prompt: "p", reference: nil), as: UTF8.self)
                == #"{"aspect_ratio":"3:2","model":"openai/gpt-image-2.5-flare","prompt":"p"}"#)
    }

    // MARK: 3. Input references

    static let pngBase64 = MediaRoutingSelftest.pngBase64

    static func references(_ c: ResponsesSelftest.Checks) throws {
        let png = Data(base64Encoded: pngBase64)!
        let small = try S.referencePayload(png, declaredMime: "image/jpeg")
        c.check("R1 a small PNG is sent unchanged with its sniffed MIME (a lying extension is corrected)",
                small.data == png && small.mime == "image/png" && small.note == nil)
        c.rejects("R2 bytes that are not an image are refused (no request)") { _ = try S.referencePayload(Data("not an image".utf8), declaredMime: "image/png") }
        if let large = PlatformImage.resizeToJPEG(data: png, targetSize: CGSize(width: 3000, height: 2000), quality: 0.9) {
            let out = try S.referencePayload(large, declaredMime: "image/jpeg")
            let dims = PlatformImage.orientedDimensions(data: out.data)
            c.check("R3 a reference over 2048 px is downscaled to a ≤2048 px JPEG with a note",
                    out.mime == "image/jpeg" && dims.map { max($0.width, $0.height) <= S.referenceMaxLongSide } == true
                    && dims.map { max($0.width, $0.height) } == 2048 && out.note?.contains("downscaled") == true
                    && out.data.count <= S.referenceMaxBytes)
        } else {
            print("• R3 skipped: no image converter on this machine")
        }
    }

    // MARK: 4. Spend

    static func usage(_ json: String) -> S.ImagesResponse.Usage? {
        try? JSONDecoder().decode(S.ImagesResponse.Usage.self, from: Data(json.utf8))
    }

    static func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-12 } == true }

    static func spend(_ c: ResponsesSelftest.Checks) {
        c.check("$0 pixel size from the PNG header", S.pixelSize(Data(base64Encoded: pngBase64)!) == "1x1" && S.pixelSize(Data("x".utf8)) == nil)
        c.check("$1 BYOK: OpenRouter fee + upstream provider charge as ONE charge (6af22df rule)",
                near(S.spendUSD(usage(#"{"cost":0.0002,"is_byok":true,"cost_details":{"upstream_inference_cost":0.005}}"#)), 0.0052))
        c.check("$2 BYOK with a zero fee (the probe's shape) records the upstream charge, not $0",
                near(S.spendUSD(usage(#"{"prompt_tokens":30,"completion_tokens":158,"cost":0,"is_byok":true,"cost_details":{"upstream_inference_cost":0.00489}}"#)), 0.00489))
        c.check("$3 not BYOK: usage.cost only (upstream is a breakdown, not an extra charge)",
                near(S.spendUSD(usage(#"{"cost":0.05,"cost_details":{"upstream_inference_cost":0.04}}"#)), 0.05)
                && near(S.spendUSD(usage(#"{"cost":0.05,"is_byok":false,"cost_details":{"upstream_inference_cost":0.04}}"#)), 0.05))
        c.check("$4 BYOK without an upstream cost: fee + token estimate (30 in × $8/M + 158 out × $30/M)",
                near(S.spendUSD(usage(#"{"prompt_tokens":30,"completion_tokens":158,"cost":0,"is_byok":true}"#)), (30 * 8 + 158 * 30) / 1_000_000))
        c.check("$5 no cost reported: token estimate", near(S.spendUSD(usage(#"{"prompt_tokens":1000,"completion_tokens":1000}"#)), (1000 * 8 + 1000 * 30) / 1_000_000))
        c.check("$6 nothing usable → unknown (nil); no usage → nil",
                S.spendUSD(usage(#"{}"#)) == nil && S.spendUSD(nil) == nil)
        func complete(_ json: String) -> Bool { S.charge(usage(json)).complete }
        c.check("$8 completeness: a reply establishes the whole charge only with a fee plus an upstream cost or both token counts (Codex N1)",
                complete(#"{"cost":0,"is_byok":true,"cost_details":{"upstream_inference_cost":0.005}}"#)
                && complete(#"{"prompt_tokens":30,"completion_tokens":158,"cost":0,"is_byok":true}"#)
                && !complete(#"{"cost":0,"is_byok":true}"#) && !complete(#"{"cost":0,"is_byok":true,"prompt_tokens":30}"#)
                && !complete(#"{"is_byok":true,"cost_details":{"upstream_inference_cost":0.005}}"#)
                && complete(#"{"cost":0.01}"#) && complete(#"{"prompt_tokens":1,"completion_tokens":1}"#)
                && !complete(#"{"prompt_tokens":1}"#) && !complete(#"{}"#) && !S.charge(nil).complete)
        c.check("$9 a partial reply still counts its known part (fee 0, no tokens → $0 known, remainder unknown)",
                S.charge(usage(#"{"cost":0,"is_byok":true}"#)).usd == 0 && S.charge(usage(#"{"cost":0,"is_byok":true,"prompt_tokens":30}"#)).usd == 0)
        c.check("$7 non-finite or negative values are not charges",
                S.spendUSD(usage(#"{"cost":-1,"is_byok":true,"cost_details":{"upstream_inference_cost":"1e400"}}"#)) == nil
                && near(S.spendUSD(usage(#"{"cost":"0.01"}"#)), 0.01))
    }

    // MARK: 5. Error classes (no fallback anywhere)

    static func errorClasses(_ c: ResponsesSelftest.Checks) {
        func text(_ e: S.ServiceError) -> String { e.errorDescription ?? "" }
        let e404 = S.classifyError(status: 404, message: "No endpoints found")
        let e502 = S.classifyError(status: 502, message: "Upstream error")
        let e403v = S.classifyError(status: 403, message: "Your organization must be verified to use the model `gpt-image-2.5-flare`.")
        let e403 = S.classifyError(status: 403, message: "Key limit exceeded")
        c.check("E1 404 → 'not available', tells the user what to do, names no other engine",
                e404 == .unavailable(status: 404, message: "No endpoints found", verification: false)
                && text(e404).contains("HTTP 404") && text(e404).contains("Tell the user") && text(e404).contains("No image was created")
                && !text(e404).lowercased().contains("gemini"))
        c.check("E2 502 → upstream failed, not billed, retry later",
                e502 == .unavailable(status: 502, message: "Upstream error", verification: false)
                && text(e502).contains("does not bill") && !text(e502).lowercased().contains("gemini"))
        c.check("E3 403 'must be verified' → verification guidance (BYOK organisation)",
                e403v == .unavailable(status: 403, message: "Your organization must be verified to use the model `gpt-image-2.5-flare`.", verification: true)
                && text(e403v).contains("platform.openai.com/settings/organization/general") && text(e403v).contains("settings/integrations"))
        c.check("E4 any other 403 (spend limit, disabled key) is shown as today, no verification text",
                e403 == .api(status: 403, message: "Key limit exceeded") && !text(e403).contains("verified"))
        for status in [400, 401, 402, 413, 429, 500, 503] {
            let e = S.classifyError(status: status, message: "m")
            c.check("E5 HTTP \(status) is shown as today ('HTTP \(status): m')",
                    e == .api(status: status, message: "m") && text(e) == "OpenRouter image request failed: HTTP \(status): m")
        }
        c.check("E6 timeout / lost connection say the cost is unknown; refusals say nothing was sent",
                text(.timedOut).contains("cost is unknown") && text(.connectionFailed("x")).contains("cost is unknown")
                && text(.notSent("paused")).contains("not sent"))
        func err(_ json: String) -> S.ImagesResponse.APIError? { try? JSONDecoder().decode(S.ImagesResponse.APIError.self, from: Data(json.utf8)) }
        c.check("E7 size guard: OpenRouter's own 400 naming size/parameters triggers it only when size was sent",
                S.isSizeFieldRejection(status: 400, error: err(#"{"message":"No provider supports the requested parameter(s): size","code":400}"#), sentSize: true)
                && S.isSizeFieldRejection(status: 400, error: err(#"{"message":"Unrecognized key: size","code":400,"metadata":{"failed_routing_step":"Validate"}}"#), sentSize: true)
                && S.isSizeFieldRejection(status: 400, error: err(#"{"message":"Invalid Size","code":400}"#), sentSize: true)
                && !S.isSizeFieldRejection(status: 400, error: err(#"{"message":"No provider supports the requested parameter(s): size","code":400}"#), sentSize: false))
        c.check("E8 size guard: OpenAI's own size-rule 400 (provider named) is NOT the guard case",
                !S.isSizeFieldRejection(status: 400, error: err(#"{"message":"Invalid size '3840x3840'. Requested resolution exceeds the current pixel budget.","code":400,"metadata":{"provider_name":"OpenAI"}}"#), sentSize: true))
        c.check("E9b size guard: refusals that do not name size are not the guard case (Codex N2)",
                !S.isSizeFieldRejection(status: 400, error: err(#"{"message":"Unsupported parameter: quality","code":400}"#), sentSize: true)
                && !S.isSizeFieldRejection(status: 400, error: err(#"{"message":"Prompt is not allowed","code":400}"#), sentSize: true)
                && !S.isSizeFieldRejection(status: 400, error: err(#"{"message":"Unrecognized key: resize_mode","code":400}"#), sentSize: true))
        c.check("E9 size guard: other statuses or unrelated 400s are not the guard case",
                !S.isSizeFieldRejection(status: 404, error: err(#"{"message":"size","code":404}"#), sentSize: true)
                && !S.isSizeFieldRejection(status: 400, error: err(#"{"message":"Prompt is required","code":400}"#), sentSize: true)
                && !S.isSizeFieldRejection(status: 400, error: nil, sentSize: true))
    }

    // MARK: 6. Schema

    static func schema(_ c: ResponsesSelftest.Checks) throws {
        let tool = AvailableTools.openRouterGenerateImage.function
        let props = tool.parameters.properties
        c.check("S1 OpenAI-style schema with only what OpenRouter honours",
                Set(props.keys) == ["prompt", "source_image", "source_image_role", "engine", "size", "quality", "background"]
                && tool.parameters.required == ["prompt"] && tool.name == "generate_image")
        c.check("S2 engines fast/precise; qualities and backgrounds match the service",
                props["engine"]?.enumValues == ["fast", "precise"] && props["quality"]?.enumValues == S.qualities
                && props["background"]?.enumValues == S.backgrounds)
        c.check("S3 description names GPT Image 2.5 through OpenRouter; no Gemini, no output_format/moderation/aspect_ratio",
                tool.description.contains("GPT Image 2.5 through OpenRouter") && !tool.description.lowercased().contains("gemini")
                && props["output_format"] == nil && props["moderation"] == nil && props["aspect_ratio"] == nil
                && props["output_compression"] == nil)
        c.check("S4 size text is the direct path's size rule (up to 3840 px)",
                props["size"]?.description.contains("max edge is 3840px") == true && props["size"]?.enumValues == nil)
    }
}
