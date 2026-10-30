import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Loopback groups of `__or-image-selftest`: a fake OpenRouter Image API
/// (`WebFixtureServer`) answers real HTTP requests from the real service
/// (real URLSession, real timeouts, real ledger files under the temp root).
extension OpenRouterImageSelftest {

    static let key = "sk-or-synthetic-0123456789"

    static func okBody(usage: String = #"{"prompt_tokens":30,"completion_tokens":158,"cost":0,"is_byok":true,"cost_details":{"upstream_inference_cost":0.00489}}"#,
                       mediaType: String? = "image/png") -> String {
        let media = mediaType.map { #","media_type":"\#($0)""# } ?? ""
        return #"{"created":1,"data":[{"b64_json":"\#(pngBase64)"\#(media)}],"usage":\#(usage)}"#
    }

    static func errorBody(_ status: Int, _ message: String, provider: String? = nil) -> String {
        let meta = provider.map { #","metadata":{"provider_name":"\#($0)"}"# } ?? ""
        return #"{"error":{"code":\#(status),"message":"\#(message)"\#(meta)}}"#
    }

    static func body(_ r: WebFixtureServer.Request) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
    }

    static func incidents() -> [SpendIncident] {
        if case .readable(let list) = ToolChargeLedger.loadIncidents() { return list }
        return []
    }

    static func inFlight() -> [ToolChargeLedger.InFlightRequest] {
        if case .readable(let list) = ToolChargeLedger.loadInFlight() { return list }
        return []
    }

    static func server(_ c: ResponsesSelftest.Checks) async throws {
        ToolChargeLedger.resetForTesting()
        let fake = try WebFixtureServer()
        defer { fake.stop() }
        let url = URL(string: "http://127.0.0.1:\(fake.port)/api/v1/images")!
        let service = S(endpoint: url, timeout: 2)

        func run(engine: String? = nil, quality: String? = nil, background: String? = nil, size: String? = nil,
                 aspect: String? = nil, source: Data? = nil) async -> Result<S.Result, Error> {
            do {
                return .success(try await service.generateImage(apiKey: key, prompt: "A red bicycle", sourceImageData: source,
                    sourceMimeType: source == nil ? nil : "image/png", engine: engine, quality: quality,
                    background: background, size: size, aspectRatio: aspect))
            } catch { return .failure(error) }
        }
        func respond(_ status: Int, _ text: String) { fake.route = { _ in .init(status: status, body: text) } }

        // H1 generation
        respond(200, okBody())
        var r = await run(engine: "precise", quality: "low", size: "3840x2160")
        var req = fake.requests.last
        c.check("H1 POST /api/v1/images with the OpenRouter key and the exact options",
                fake.requests.count == 1 && req?.method == "POST" && req?.path == "/api/v1/images"
                && req?.headers["authorization"] == "Bearer \(key)" && req?.headers["content-type"] == "application/json"
                && body(req!) as NSDictionary == ["model": "openai/gpt-image-2.5-sunburst", "prompt": "A red bicycle",
                                                  "quality": "low", "size": "3840x2160"] as NSDictionary)
        let ok = try? r.get()
        c.check("H2 the image, its media type and the BYOK charge come back",
                ok?.data == Data(base64Encoded: pngBase64) && ok?.mimeType == "image/png" && near(ok?.spendUSD, 0.00489)
                && ok?.byok == true && ok?.options.size == "3840x2160")
        c.check("H2b requested vs returned size are reported separately; a mismatch is noted, never re-rendered (Codex N3)",
                ok?.actualSize == "1x1" && ok?.requestedSize == "3840x2160" && fake.requests.count == 1
                && (ok?.toolResultMetadata()["size"] as? String) == "1x1" && (ok?.toolResultMetadata()["requested_size"] as? String) == "3840x2160"
                && ok?.options.notes.contains { $0.contains("Requested size 3840x2160") && $0.contains("1x1") } == true)
        c.check("H3 an answered request leaves no in-flight record and no incident", inFlight().isEmpty && incidents().isEmpty)

        // H4 edit
        fake.clear(); respond(200, okBody(mediaType: nil))
        r = await run(source: Data(base64Encoded: pngBase64)!)
        req = fake.requests.last
        let refs = req.map { body($0)["input_references"] as? [[String: Any]] } ?? nil
        c.check("H4 edit sends the source image as one data-URL input reference; missing media_type is sniffed",
                refs?.count == 1 && (refs?.first?["image_url"] as? [String: String])?["url"] == "data:image/png;base64,\(pngBase64)"
                && (try? r.get())?.mimeType == "image/png")

        // H5 error classes: exactly one request each, never another engine
        for (status, text, expect) in [(404, errorBody(404, "No endpoints found"), "not available"),
                                       (502, errorBody(502, "Upstream error"), "does not bill"),
                                       (403, errorBody(403, "Your organization must be verified to use the model."), "organisation"),
                                       (403, errorBody(403, "Key limit exceeded"), "HTTP 403: Key limit exceeded"),
                                       (400, errorBody(400, "Prompt rejected"), "HTTP 400: Prompt rejected"),
                                       (401, errorBody(401, "No auth credentials found"), "HTTP 401"),
                                       (402, errorBody(402, "Insufficient credits"), "HTTP 402"),
                                       (429, errorBody(429, "Rate limited"), "HTTP 429")] {
            fake.clear(); respond(status, text)
            let outcome = await run()
            var message = ""
            if case .failure(let e) = outcome { message = e.localizedDescription }
            c.check("H5 HTTP \(status) (\(expect)): one request, no retry, no other engine, clear error",
                    fake.requests.count == 1 && message.contains(expect) && !message.lowercased().contains("gemini")
                    && (fake.requests.first.map { body($0)["model"] as? String } ?? nil) == "openai/gpt-image-2.5-flare")
        }
        c.check("H6 error replies leave no in-flight record and no incident", inFlight().isEmpty && incidents().isEmpty)

        // H7 error object inside HTTP 200
        fake.clear(); respond(200, errorBody(502, "upstream failed"))
        if case .failure(let e) = await run() { c.check("H7 an error inside HTTP 200 is classified by its code", e.localizedDescription.contains("HTTP 502")) }
        else { c.check("H7 an error inside HTTP 200 is classified by its code", false) }

        // H8 200 without an image keeps its charge
        fake.clear(); respond(200, #"{"data":[],"usage":{"cost":0.003}}"#)
        if case .failure(let e) = await run(), let se = e as? S.ServiceError {
            c.check("H8 no image → noImage error that still carries the reported charge", near(se.spendUSD, 0.003))
        } else { c.check("H8 no image → noImage error that still carries the reported charge", false) }

        // H9 an answered 200 whose usage does not establish the whole charge
        // keeps the known part and an unknown-amount incident (Codex N1).
        ToolChargeLedger.resetForTesting()
        fake.clear(); respond(200, okBody(usage: #"{"cost":0,"is_byok":true}"#))
        let partial = try? await run().get()
        var list = incidents()
        c.check("H9 BYOK fee without the provider's charge → image kept, $0 known, unknown-cost incident, no record left",
                partial != nil && partial?.spendUSD == 0 && list.count == 1
                && list.first?.detail?.contains("answered without a complete cost") == true && inFlight().isEmpty)
        ToolChargeLedger.resetForTesting()
        fake.clear(); respond(200, #"{"data":[{"b64_json":"\#(pngBase64)"}]}"#)
        _ = await run()
        list = incidents()
        c.check("H10 a reply with no usage at all → unknown-cost incident", list.count == 1 && inFlight().isEmpty)
        ToolChargeLedger.resetForTesting()

        try await sizeGuard(c, fake: fake, run: { await run(size: $0) })
        try await unknownCost(c, fake: fake, url: url)
    }

    // MARK: Size guard (undocumented passthrough)

    static func sizeGuard(_ c: ResponsesSelftest.Checks, fake: WebFixtureServer,
                          run: (String) async -> Result<S.Result, Error>) async throws {
        // OpenRouter itself rejects the field: one retry without size.
        fake.clear()
        fake.route = { request in
            let sent = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            return sent["size"] != nil
                ? .init(status: 400, body: errorBody(400, "No provider for openai/gpt-image-2.5-flare supports the requested parameter(s): size"))
                : .init(status: 200, body: okBody())
        }
        let retried = try? await run("3840x2160").get()
        let second = fake.requests.count == 2 ? body(fake.requests[1]) : [:]
        c.check("G1 OpenRouter refusing 'size' → exactly one retry without size at the nearest ratio (16:9)",
                fake.requests.count == 2 && body(fake.requests[0])["size"] as? String == "3840x2160"
                && second["size"] == nil && second["aspect_ratio"] as? String == "16:9" && retried != nil)
        c.check("G2 the result says the size was not available and what was used",
                retried?.options.notes.contains { $0.contains("3840x2160") && $0.contains("16:9") } == true
                && retried?.options.size == nil && retried?.options.aspectRatio == "16:9"
                && (retried?.toolResultMetadata()["requested_size"] as? String) == "16:9" && incidents().isEmpty && inFlight().isEmpty)
        // OpenAI's own size-rule 400 reaches the model unchanged.
        fake.clear(); fake.route = { _ in .init(status: 400, body: errorBody(400, "Invalid size '3840x2160'. Requested resolution exceeds the current pixel budget.", provider: "OpenAI")) }
        var outcome = await run("3840x2160")
        var message = ""; if case .failure(let e) = outcome { message = e.localizedDescription }
        c.check("G3 OpenAI's own size 400 → one request, message passed through unchanged",
                fake.requests.count == 1 && message == "OpenRouter image request failed: HTTP 400: Invalid size '3840x2160'. Requested resolution exceeds the current pixel budget.")
        // The retry itself refused again: no third request.
        fake.clear(); fake.route = { _ in .init(status: 400, body: errorBody(400, "Unsupported parameter(s): size, aspect_ratio")) }
        outcome = await run("2048x2048")
        message = ""; if case .failure(let e) = outcome { message = e.localizedDescription }
        c.check("G4 a refused retry is surfaced; never a third request",
                fake.requests.count == 2 && message.contains("HTTP 400"))
        // No size sent → no guard.
        fake.clear(); fake.route = { _ in .init(status: 400, body: errorBody(400, "Unsupported parameter(s): size")) }
        _ = await run("auto")
        c.check("G5 without a size the same 400 is not retried", fake.requests.count == 1)
    }

    // MARK: Unknown cost, gate, write-ahead

    static func unknownCost(_ c: ResponsesSelftest.Checks, fake: WebFixtureServer, url: URL) async throws {
        ToolChargeLedger.resetForTesting()
        // U1 timeout: sent, never answered
        fake.clear(); fake.route = { _ in .init(status: 200, body: okBody(), silentFor: 4) }
        let short = S(endpoint: url, timeout: 1)
        var thrown: Error?
        do { _ = try await short.generateImage(apiKey: key, prompt: "p", sourceImageData: nil, sourceMimeType: nil,
                                               engine: nil, quality: nil, background: nil, size: nil) } catch { thrown = error }
        var list = incidents()
        c.check("U1 a timeout is not retried and opens one unknown-cost incident (image wording)",
                (thrown as? S.ServiceError) == .timedOut && fake.requests.count == 1 && list.count == 1
                && list.first?.kind == .unknownAmount && list.first?.state == .open
                && list.first?.detail?.hasPrefix(ToolChargeLedger.imageRequestDetailPrefix) == true
                && list.first?.detail?.contains("timed out") == true && inFlight().isEmpty)
        c.check("U2 /spend wording names an image request", list.first.map(ToolChargeLedger.describe)?.contains("unknown cost of a image generation request") == true)

        // U3 cancellation while open
        ToolChargeLedger.resetForTesting()
        fake.clear(); fake.route = { _ in .init(status: 200, body: okBody(), silentFor: 4) }
        let slow = S(endpoint: url, timeout: 30)
        let task = Task { try await slow.generateImage(apiKey: key, prompt: "p", sourceImageData: nil, sourceMimeType: nil,
                                                       engine: nil, quality: nil, background: nil, size: nil) }
        for _ in 0..<100 where fake.requests.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        task.cancel()
        thrown = nil
        do { _ = try await task.value } catch { thrown = error }
        list = incidents()
        c.check("U3 cancellation while open → CancellationError (no retry) and an unknown-cost incident",
                thrown is CancellationError && fake.requests.count == 1 && list.count == 1
                && list.first?.detail?.contains("cancelled while open") == true && inFlight().isEmpty)

        // U3b a transport that surfaces Swift's CancellationError (Linux
        // FoundationNetworking, a custom transport) is recorded the same way.
        ToolChargeLedger.resetForTesting()
        let cancelling = S(transport: { _ in throw CancellationError() }, endpoint: url, timeout: 30)
        thrown = nil
        do { _ = try await cancelling.generateImage(apiKey: key, prompt: "p", sourceImageData: nil, sourceMimeType: nil,
                                                    engine: nil, quality: nil, background: nil, size: nil) } catch { thrown = error }
        list = incidents()
        c.check("U3b a CancellationError from the transport → rethrown, unknown-cost incident, no record left",
                thrown is CancellationError && list.count == 1 && list.first?.detail?.contains("cancelled while open") == true && inFlight().isEmpty)

        // U4 cancelled before sending: nothing sent, nothing opened
        ToolChargeLedger.resetForTesting()
        fake.clear(); fake.route = { _ in .init(status: 200, body: okBody()) }
        let early = Task { () -> S.Result in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await slow.generateImage(apiKey: key, prompt: "p", sourceImageData: nil, sourceMimeType: nil,
                                                engine: nil, quality: nil, background: nil, size: nil)
        }
        thrown = nil
        do { _ = try await early.value } catch { thrown = error }
        c.check("U4 cancelled before sending → nothing sent, no incident", thrown is CancellationError && fake.requests.isEmpty && incidents().isEmpty)

        // U5 connection dropped after the reply started
        fake.clear(); fake.route = { _ in .init(status: 200, body: "{\"data\":", disconnectAfterHeaders: true) }
        thrown = nil
        do { _ = try await slow.generateImage(apiKey: key, prompt: "p", sourceImageData: nil, sourceMimeType: nil,
                                              engine: nil, quality: nil, background: nil, size: nil) } catch { thrown = error }
        list = incidents()
        c.check("U5 a connection lost after sending → not retried, cost unknown (incident)",
                fake.requests.count == 1 && list.count == 1 && inFlight().isEmpty
                && (thrown as? S.ServiceError).map { if case .connectionFailed = $0 { return true }; return false } == true)

        // U6 demonstrably unsent: nothing listening
        ToolChargeLedger.resetForTesting()
        let closed = S(endpoint: URL(string: "http://127.0.0.1:9/api/v1/images")!, timeout: 2)
        thrown = nil
        do { _ = try await closed.generateImage(apiKey: key, prompt: "p", sourceImageData: nil, sourceMimeType: nil,
                                                engine: nil, quality: nil, background: nil, size: nil) } catch { thrown = error }
        c.check("U6 a refused connection (never sent) → 'not sent', no incident, no record",
                (thrown as? S.ServiceError).map { if case .notSent = $0 { return true }; return false } == true
                && incidents().isEmpty && inFlight().isEmpty)

        // U7 write-ahead failure: refused before sending
        fake.clear(); fake.route = { _ in .init(status: 200, body: okBody()) }
        ToolChargeLedger.faultForTesting = { label in if label == "inflight-begin" { throw ToolChargeLedger.Failure("disk full") } }
        thrown = nil
        do { _ = try await slow.generateImage(apiKey: key, prompt: "p", sourceImageData: nil, sourceMimeType: nil,
                                              engine: nil, quality: nil, background: nil, size: nil) } catch { thrown = error }
        ToolChargeLedger.faultForTesting = nil
        c.check("U7 the in-flight record cannot be written → not sent",
                fake.requests.isEmpty && thrown?.localizedDescription.contains("tracked durably") == true)

        // U8 spend gate: a cap plus an open unknown → paused, nothing sent
        try ToolChargeLedger.openUnknownAmount(jobId: UUID(), day: Date(), detail: "selftest")
        try KeychainHelper.save(key: KeychainHelper.openRouterToolSpendLimitDailyUSDKey, value: "5")
        thrown = nil
        do { _ = try await slow.generateImage(apiKey: key, prompt: "p", sourceImageData: nil, sourceMimeType: nil,
                                              engine: nil, quality: nil, background: nil, size: nil) } catch { thrown = error }
        try KeychainHelper.saveBatch([KeychainHelper.openRouterToolSpendLimitDailyUSDKey: nil])
        c.check("U8 paid work paused by the spend gate → not sent",
                fake.requests.isEmpty && (thrown as? S.ServiceError).map { if case .notSent = $0 { return true }; return false } == true)
        ToolChargeLedger.resetForTesting()
    }

    // MARK: Executor

    static func executor(_ c: ResponsesSelftest.Checks) async throws {
        ToolChargeLedger.resetForTesting()
        let fake = try WebFixtureServer()
        defer { fake.stop() }
        ToolExecutor.openRouterImageServiceOverrideForTesting = S(endpoint: URL(string: "http://127.0.0.1:\(fake.port)/api/v1/images")!, timeout: 5)
        defer { ToolExecutor.openRouterImageServiceOverrideForTesting = nil }
        try MediaRoutingSelftest.set(MediaRoutingSelftest.orLane)
        let images = StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        try PrivateStorage.ensureDirectory(images)
        try Data(base64Encoded: pngBase64)!.write(to: images.appendingPathComponent("source.png"))
        let executor = ToolExecutor(outputMode: .subagent)
        func call(_ args: String) async throws -> ToolResultMessage {
            try await executor.execute(ToolCall(id: "img", type: "function", function: FunctionCall(name: "generate_image", arguments: args)))
        }
        fake.route = { _ in .init(status: 200, body: okBody()) }
        let result = try await call(#"{"prompt":"Make it yellow","source_image":"source.png","source_image_role":"edit","engine":"precise","quality":"high","background":"transparent","size":"2048x2048"}"#)
        let sent = fake.requests.last.map(body) ?? [:]
        let object = (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any] ?? [:]
        c.check("X1 tool → one Image API request: Sunburst, options, edit framing, input reference",
                fake.requests.count == 1 && sent["model"] as? String == "openai/gpt-image-2.5-sunburst"
                && sent["quality"] as? String == "high" && sent["background"] as? String == "transparent" && sent["size"] as? String == "2048x2048"
                && (sent["prompt"] as? String)?.hasPrefix("Edit the input image directly") == true && (sent["input_references"] as? [Any])?.count == 1)
        c.check("X2 result names the engine, model and size; image attached; BYOK charge recorded",
                object["success"] as? Bool == true && object["provider"] as? String == "OpenRouter (GPT Image 2.5)"
                && object["model"] as? String == "openai/gpt-image-2.5-sunburst" && object["resolution"] as? String == "1x1"
                && object["requested_size"] as? String == "2048x2048"
                && object["via"] as? String == "openrouter" && result.fileAttachments.first?.mimeType == "image/png"
                && near(result.spendUSD, 0.00489))
        fake.clear(); fake.route = { _ in .init(status: 200, body: #"{"data":[{"b64_json":"eA==","media_type":"image/png"}],"usage":{"cost":0.001}}"#) }
        let unreadable = try await call(#"{"prompt":"p","size":"2048x2048"}"#)
        let unreadableObject = (try? JSONSerialization.jsonObject(with: Data(unreadable.content.utf8))) as? [String: Any] ?? [:]
        c.check("X2b unreadable output bytes → resolution and size 'unknown', never the requested size (Codex r2 note)",
                unreadableObject["resolution"] as? String == "unknown" && unreadableObject["size"] as? String == "unknown"
                && unreadableObject["requested_size"] as? String == "2048x2048")
        fake.clear()
        let bad = try await call(#"{"prompt":"p","size":"5000x5000"}"#)
        c.check("X3 an invalid size is explained without a request", fake.requests.isEmpty && bad.content.contains("Invalid image size"))
        fake.route = { _ in .init(status: 404, body: errorBody(404, "No endpoints found")) }
        let missing = try await call(#"{"prompt":"p"}"#)
        c.check("X4 a 404 is a tool error with guidance; one request; no other engine",
                fake.requests.count == 1 && missing.content.contains("Image generation failed") && missing.content.contains("Tell the user")
                && missing.fileAttachments.isEmpty && missing.spendUSD == nil)
        fake.clear(); fake.route = { _ in .init(status: 200, body: #"{"data":[],"usage":{"cost":0.002}}"#) }
        let empty = try await call(#"{"prompt":"p"}"#)
        c.check("X5 a reply without an image is an error that still counts its charge", empty.content.contains("returned no image") && near(empty.spendUSD, 0.002))
        try MediaRoutingSelftest.set(MediaRoutingSelftest.openAIKeys.merging(MediaRoutingSelftest.orLane) { a, _ in a })
        c.check("X6 with an OpenAI key the backend is the direct OpenAI path (unchanged)", MediaRouting.imageBackend == .openAI)
        ToolChargeLedger.resetForTesting()
    }
}
