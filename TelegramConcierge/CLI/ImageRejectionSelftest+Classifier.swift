import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Prevention rows (plan v2 §2.5 P1–P3, P6) and the recogniser.
extension MidturnHarness {

    func irClassifierSection() {
        let supported: [(String, Data, String)] = [("JPEG", IRFixtures.jpeg, "image/jpeg"), ("PNG", IRFixtures.png, "image/png"),
                                                   ("WebP", IRFixtures.webp, "image/webp"), ("still GIF", IRFixtures.gif, "image/gif")]
        // P2: Linux without ImageMagick (simulated on every platform): valid
        // supported images pass with their bytes unchanged, structurally checked.
        ModelImage.simulateNoPlatformDecoderForTesting = true
        for (label, data, mime) in supported {
            let outcome = ModelImage.classify(data: data, declaredMime: "image/jpeg")
            check("P2 no decoder: \(label) attached with identical bytes, sniffed MIME, structural check",
                  outcome == .supported(data: data, mime: mime, validation: .structural), "\(outcome)")
        }
        let bmpNoDecoder = ModelImage.classify(data: IRFixtures.bmp(), declaredMime: "image/bmp")
        check("P2 no decoder: BMP → 'conversion not available' (never 'corrupt')",
              bmpNoDecoder == .needsConversionUnavailable(format: "BMP")
                && bmpNoDecoder.refusalReason?.contains("could not convert") == true
                && bmpNoDecoder.refusalReason?.contains("not a valid") == false, "\(bmpNoDecoder)")
        check("P2 no decoder: truncated PNG → malformed",
              { if case .malformed("PNG", _) = ModelImage.classify(data: IRFixtures.truncatedPNG) { return true }; return false }())
        check("P2 no decoder: truncated JPEG → malformed",
              { if case .malformed("JPEG", _) = ModelImage.classify(data: IRFixtures.truncatedJPEG) { return true }; return false }())
        check("P2 no decoder: animated GIF → conversion-unavailable text",
              ModelImage.classify(data: IRFixtures.animatedGIF) == .needsConversionUnavailable(format: "animated GIF"))
        ModelImage.simulateNoPlatformDecoderForTesting = false

        // P3: the same fixtures with this platform's tools.
        for (label, data, mime) in supported {
            let outcome = ModelImage.classify(data: data)
            let expected: ModelImage.Validation = ModelImage.platformDecoderAvailable ? .decoded : .structural
            check("P3 \(label): attached with identical bytes (\(expected.rawValue))",
                  outcome == .supported(data: data, mime: mime, validation: expected), "\(outcome)")
        }
        check("P3 truncated PNG → malformed",
              { if case .malformed = ModelImage.classify(data: IRFixtures.truncatedPNG) { return true }; return false }())
        check("P3 truncated JPEG → malformed",
              { if case .malformed = ModelImage.classify(data: IRFixtures.truncatedJPEG) { return true }; return false }())

        let converterHere = ModelImage.platformDecoderAvailable || PlatformImage.convertFirstFrame(data: IRFixtures.png, toJPEG: false, quality: 0.8) != nil
        let bmp = IRFixtures.bmp()
        let bmpOutcome = ModelImage.classify(data: bmp, declaredMime: "image/bmp")
        if converterHere {
            // P1: the benchmark case, a 320×200 24-bit BMP → PNG, same pixels.
            if case .converted(let png, "image/png", "image/bmp") = bmpOutcome {
                check("P1 BMP 320×200 → PNG, dimensions kept", PlatformImage.dimensions(data: png).map { $0 == (320, 200) } == true)
                check("P1 BMP → PNG keeps the pixels", irSamePixels(bmp: bmp, png: png))
                check("P1 the converted PNG is itself a supported image",
                      { if case .supported = ModelImage.classify(data: png) { return true }; return false }())
            } else { check("P1 BMP → PNG", false, "\(bmpOutcome)") }
            check("P3 TIFF → converted PNG",
                  { if case .converted(_, "image/png", "image/tiff") = ModelImage.classify(data: IRFixtures.tiff) { return true }; return false }())
            check("P3 animated GIF → first frame as PNG",
                  { if case .converted(_, "image/png", "image/gif (animated)") = ModelImage.classify(data: IRFixtures.animatedGIF) { return true }; return false }())
        } else {
            check("P3 BMP without a converter → conversion not available", bmpOutcome == .needsConversionUnavailable(format: "BMP"))
        }
        if let heic = IRFixtures.heic() {
            check("P3 HEIC (macOS) → converted JPEG",
                  { if case .converted(_, "image/jpeg", "image/heic") = ModelImage.classify(data: heic) { return true }; return false }())
        }

        // P6: accepted JPEG bytes reach the cache and every attachment site
        // unchanged (a re-encode of a valid JPEG must fail this row).
        ModelImageCache.shared.removeAll()
        let cached = ModelImage.classifyCached(data: IRFixtures.jpeg)
        let again = ModelImage.classifyCached(data: IRFixtures.jpeg)
        check("P6 valid JPEG: the memoized outcome returns the identical bytes",
              cached.attachable?.data == IRFixtures.jpeg && again == cached && ModelImageCache.shared.count == 1)
    }

    /// Pixel equality of a 24-bit BMP and its converted PNG (macOS decode;
    /// elsewhere ImageMagick text dump when available, else dimensions only).
    private func irSamePixels(bmp: Data, png: Data) -> Bool {
        #if canImport(ImageIO)
        func rgb(_ data: Data) -> [UInt8]? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let w = image.width, h = image.height
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            guard let context = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buffer
        }
        guard let a = rgb(bmp), let b = rgb(png) else { return false }
        return a == b
        #else
        return PlatformImage.dimensions(data: png).map { $0 == (320, 200) } == true
        #endif
    }

    /// Structural walkers: every truncation of every valid fixture is either
    /// malformed or (for a cut only inside trailing metadata) still valid —
    /// never a crash; hostile lengths are invalid with checked arithmetic.
    func irStructureSection() {
        for (label, data, format) in [("PNG", IRFixtures.png, ModelImage.Format.png), ("JPEG", IRFixtures.jpeg, .jpeg),
                                      ("GIF", IRFixtures.gif, .gif), ("WebP", IRFixtures.webp, .webp)] {
            check("S1 \(label) fixture is structurally valid", { if case .valid = ModelImage.structure(data, format: format) { return true }; return false }())
            var invalid = 0
            for cut in 1..<data.count {
                if case .invalid = ModelImage.structure(data.prefix(cut), format: format) { invalid += 1 }
            }
            check("S2 \(label): every one of \(data.count - 1) truncations is reported invalid", invalid == data.count - 1, "\(invalid)")
        }
        var hostilePNG = [UInt8](IRFixtures.png)
        hostilePNG[33] = 0xFF; hostilePNG[34] = 0xFF; hostilePNG[35] = 0xFF; hostilePNG[36] = 0xFF   // second chunk length 0xFFFFFFFF
        check("S3 PNG chunk length 0xFFFFFFFF → invalid, no overflow",
              { if case .invalid = ModelImage.structure(Data(hostilePNG), format: .png) { return true }; return false }())
        var hostileWebP = [UInt8](IRFixtures.webp)
        hostileWebP[4] = 0xFF; hostileWebP[5] = 0xFF; hostileWebP[6] = 0xFF; hostileWebP[7] = 0xFF
        check("S4 WebP RIFF size beyond the file → invalid",
              { if case .invalid = ModelImage.structure(Data(hostileWebP), format: .webp) { return true }; return false }())
        var hostileGIF = [UInt8](IRFixtures.gif)
        hostileGIF[10] |= 0x87   // largest global colour table, beyond the file
        check("S5 GIF colour table beyond the file → invalid",
              { if case .invalid = ModelImage.structure(Data(hostileGIF), format: .gif) { return true }; return false }())
        check("S6 animated GIF counts two frames",
              ModelImage.structure(IRFixtures.animatedGIF, format: .gif) == .valid(frames: 2))
        // A JPEG with extra bytes after EOI is still valid (common in the wild).
        check("S7 JPEG with trailing bytes after the end marker stays valid",
              { if case .valid = ModelImage.structure(IRFixtures.jpeg + Data([0, 0, 0, 0]), format: .jpeg) { return true }; return false }())
        check("S8 sniffing", ModelImage.sniff(IRFixtures.bmp(width: 2, height: 2)) == .bmp && ModelImage.sniff(IRFixtures.tiff) == .tiff
              && ModelImage.sniff(Data("hello".utf8)) == .unknown && ModelImage.sniff(IRFixtures.webp) == .webp)
    }

    /// read_file (site 1) with the classifier.
    func irReadFileSection() async {
        let bmpPath = irFile("frame.bmp", IRFixtures.bmp())
        let bmp = await FilesystemTools.shared.readFile(path: bmpPath)
        let converter = ModelImage.platformDecoderAvailable || PlatformImage.convertFirstFrame(data: IRFixtures.png, toJPEG: false, quality: 0.8) != nil
        if converter {
            check("P1 read_file frame.bmp → PNG attachment, converted noted",
                  bmp.attachments.count == 1 && bmp.attachments.first?.mimeType == "image/png"
                    && bmp.content.contains("\"converted\"") && bmp.content.contains("image/bmp"), bmp.content)
        }
        ModelImage.simulateNoPlatformDecoderForTesting = true
        ModelImageCache.shared.removeAll()
        let noTool = await FilesystemTools.shared.readFile(path: bmpPath)
        check("P2 read_file BMP without a converter: no attachment, honest text",
              noTool.attachments.isEmpty && noTool.content.contains("\"success\":false")
                && noTool.content.contains("could not convert") && !noTool.content.contains("not a valid"), noTool.content)
        let jpegPath = irFile("photo.jpg", IRFixtures.jpeg)
        let jpeg = await FilesystemTools.shared.readFile(path: jpegPath)
        check("P2/P6 read_file JPEG without any toolchain: same bytes as v0.2.51",
              jpeg.attachments.first?.data == IRFixtures.jpeg && jpeg.attachments.first?.mimeType == "image/jpeg")
        ModelImage.simulateNoPlatformDecoderForTesting = false
        ModelImageCache.shared.removeAll()
        let broken = await FilesystemTools.shared.readFile(path: irFile("broken.png", IRFixtures.truncatedPNG))
        check("P3 read_file truncated PNG: no attachment, reported as not a valid PNG",
              broken.attachments.isEmpty && broken.content.contains("not a valid PNG"), broken.content)
        let lying = await FilesystemTools.shared.readFile(path: irFile("lying.png", IRFixtures.jpeg))
        check("P6 read_file JPEG named .png: bytes unchanged, real MIME image/jpeg",
              lying.attachments.first?.data == IRFixtures.jpeg && lying.attachments.first?.mimeType == "image/jpeg")
    }

    func irRecognizerSection() {
        func body(_ s: String) -> ProviderErrorBody { ProviderErrorBody(raw: Data(s.utf8)) }
        let positives: [(String, String)] = [
            ("OpenAI Responses BMP", IRFixtures.openAIResponsesBMP), ("OpenAI Responses corrupt", IRFixtures.openAIResponsesCorrupt),
            ("OpenAI Chat invalid_image_format", IRFixtures.openAIChatBMP), ("OpenAI Chat image_parse_error", IRFixtures.openAIChatCorrupt),
            ("OpenRouter wrapped Responses", IRFixtures.openRouterWrapped(IRFixtures.openAIResponsesBMP)),
            ("OpenRouter wrapped Chat", IRFixtures.openRouterWrapped(IRFixtures.openAIChatCorrupt)),
            ("OpenCode passthrough", IRFixtures.openAIResponsesCorrupt),
        ]
        for (label, text) in positives {
            check("RC1 matches: \(label)", ProviderImageRejection.matches(status: 400, body: body(text)))
        }
        let negatives: [(String, String, Int)] = [
            ("invalid_value without image wording", #"{"error":{"message":"Invalid value for 'reasoning.effort'.","type":"invalid_request_error","param":"reasoning","code":"invalid_value"}}"#, 400),
            ("image wording in a different nested object than the code",
             #"{"error":{"message":"bad request","code":"invalid_value","details":{"message":"does not represent a valid image"}}}"#, 400),
            ("wrapper provider_error_code + nested unrelated message",
             IRFixtures.openRouterWrapped(#"{"error":{"message":"Context too long.","code":"context_length_exceeded"}}"#), 400),
            ("wrapper message with image words, code from elsewhere",
             #"{"error":{"message":"does not represent a valid image","code":400,"metadata":{"provider_error_code":"invalid_value","raw":"not json"}}}"#, 400),
            ("malformed wrapper", #"{"error":"invalid_value: does not represent a valid image"}"#, 400),
            ("non-JSON metadata.raw", #"{"error":{"message":"Provider returned error","code":400,"metadata":{"raw":"<html>invalid_image_format</html>"}}}"#, 400),
            ("context_length_exceeded", #"{"error":{"message":"This model's maximum context length is 400000 tokens.","type":"invalid_request_error","code":"context_length_exceeded"}}"#, 400),
            ("right body, status 413", IRFixtures.openAIChatBMP, 413),
            ("right body, status 429", IRFixtures.openAIResponsesBMP, 429),
            ("not JSON", "Bad Request", 400),
        ]
        for (label, text, status) in negatives {
            check("RC2 does not match: \(label)", !ProviderImageRejection.matches(status: status, body: body(text)))
        }
        // An otherwise valid image error padded past the bound: the cut text
        // still parses, but the truncation flag refuses recognition.
        let padded = IRFixtures.openAIChatBMP + String(repeating: " ", count: ProviderErrorBody.limit)
        let paddedBody = body(padded)
        check("RC3 oversized body (> 64 KiB) with valid image-error JSON → truncated, not recognised",
              paddedBody.truncated && (try? JSONSerialization.jsonObject(with: paddedBody.data)) != nil
                && !ProviderImageRejection.matches(status: 400, body: paddedBody))
        let withImage = Data(#"{"input":[{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}"#.utf8)
        let textOnly = Data(#"{"input":[{"type":"input_text","text":"hello"}]}"#.utf8)
        let rejected = ProviderImageRejection.classify(status: 400, rawBody: Data(IRFixtures.openAIResponsesBMP.utf8),
                                                       requestBody: withImage, underlying: ResponsesFailure.http(400, nil))
        check("RC4 image-carrying request → Rejected with the original description",
              (rejected as? ProviderImageRejection.Rejected) != nil && rejected.localizedDescription == "Responses HTTP 400")
        let plain = ProviderImageRejection.classify(status: 400, rawBody: Data(IRFixtures.openAIResponsesBMP.utf8),
                                                    requestBody: textOnly, underlying: ResponsesFailure.http(400, nil))
        check("RC5 request without images → original error untouched", { if case ResponsesFailure.http(400, nil) = plain { return true }; return false }())
    }

    /// Both transports against the capture server: the type changes only for
    /// a recognised 400 on an image-carrying request; other statuses keep
    /// their exact error.
    func irTransportSection() async throws {
        server.clear()
        let service = OpenRouterService()
        await service.configure(apiKey: apiKey)
        let images = StoragePaths.dataRoot.appendingPathComponent("images")
        let docs = StoragePaths.dataRoot.appendingPathComponent("documents")
        let imageName = irUserImage("t-photo.png", IRFixtures.png)
        let withImage = [Message(role: .user, content: "look", imageFileNames: [imageName])]
        let textOnly = [Message(role: .user, content: "hello")]
        func attempt(_ messages: [Message], status: Int, body: String) async -> Error? {
            server.script([body], statuses: [status])
            do { _ = try await service.generateResponse(messages: messages, imagesDirectory: images, documentsDirectory: docs, lane: .main); return nil }
            catch { return error }
        }
        for responses in [false, true] {
            let restore: (() -> Void)? = responses ? try useResponses() : nil
            let tag = responses ? "Responses" : "Chat"
            let rejection = Self.irRejection(responses: responses)
            let a = await attempt(withImage, status: 400, body: rejection)
            check("RT1 \(tag): recognised 400 on an image request → Rejected, same text as before",
                  (a as? ProviderImageRejection.Rejected) != nil
                    && a?.localizedDescription == (responses ? "Responses HTTP 400" : ProviderImageRejection.unwrap(a!).localizedDescription), "\(String(describing: a))")
            let b = await attempt(textOnly, status: 400, body: rejection)
            check("RT2 \(tag): the same 400 on a text-only request keeps its original type",
                  b != nil && (b as? ProviderImageRejection.Rejected) == nil, "\(String(describing: b))")
            let c = await attempt(withImage, status: 400, body: rejection + String(repeating: " ", count: ProviderErrorBody.limit))
            check("RT3 \(tag): an oversized body is never recognised", c != nil && (c as? ProviderImageRejection.Rejected) == nil,
                  "\(String(describing: c))")
            restore?()
        }
        server.script([])
    }
}
