import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SIWCSelftest {
    static func sys(_ text: String) -> JSONValue { ResponsesAdapter.message(role: "system", text: text) }
    static func user(_ text: String) -> JSONValue { ResponsesAdapter.message(role: "user", text: text) }
    static func encode(_ value: [String: JSONValue]) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return String(data: (try? e.encode(JSONValue.object(value))) ?? Data(), encoding: .utf8) ?? ""
    }
    static func normalizes(_ body: [String: JSONValue], _ prompt: String?) -> [String: JSONValue]? { try? SIWCBody.normalize(body, typedPrompt: prompt) }

    /// `SIWCBody.normalize` (§4.2 normalizer tests, §8 v3.1).
    static func bodyTests(_ root: URL, _ c: Checks) async throws {
        let prompt = "Système\r\nprompt with trailing space \u{1F600} "
        let base: [String: JSONValue] = ["model": .string("gpt-6.1-sol"), "store": .bool(true), "stream": .bool(false),
            "input": .array([sys(prompt), user("hi"), sys("[Chronology] Monday"), user("there"), sys("[Ambient status] tail")])]
        guard let out = normalizes(base, prompt) else { c.check("body: normalize the main shape", false); return }
        c.check("body: the typed prompt becomes instructions byte-for-byte (Unicode, CRLF, trailing space)", out["instructions"]?.responsesString == prompt)
        let items = out["input"]?.responsesArray ?? []
        c.check("body: only input[0] was extracted", items.count == 4)
        c.check("body: later system notes keep role, text and position (D16)", encode(["i": .array(items)]) == encode(["i": .array([user("hi"), sys("[Chronology] Monday"), user("there"), sys("[Ambient status] tail")])]))
        c.check("body: system items never gain a type key", !encode(out).contains("\"type\":\"message\""))
        c.check("body: store false, stream true forced", { if case .bool(false)? = out["store"], case .bool(true)? = out["stream"] { return true }; return false }())
        c.check("body: repeated normalization is a no-op", normalizes(out, prompt).map(encode) == encode(out))
        var noSystem = base; noSystem["input"] = .array([user("hi")])
        c.check("body: no system item → instructions from the typed prompt, input untouched", normalizes(noSystem, prompt)?["input"]?.responsesArray?.count == 1
                && normalizes(noSystem, prompt)?["instructions"]?.responsesString == prompt)
        var history = base; history["instructions"] = .string(prompt); history["input"] = .array([sys("[History] note"), user("x")])
        c.check("body: existing instructions + leading history note: the note stays system at index 0",
                normalizes(history, prompt)?["input"]?.responsesArray.map { encode(["a": .array([$0[0]])]) } == encode(["a": .array([sys("[History] note")])]))
        var differing = base; differing["instructions"] = .string("other")
        c.check("body: instructions differing from the typed prompt throw", normalizes(differing, prompt) == nil)
        var wrongFirst = base; wrongFirst["input"] = .array([sys("not the prompt"), user("x")])
        c.check("body: input[0] system with another text throws (never promoted)", normalizes(wrongFirst, prompt) == nil)
        var multi = base
        multi["input"] = .array([.object(["role": .string("system"), "content": .array([
            .object(["type": .string("input_text"), "text": .string("a")]), .object(["type": .string("input_text"), "text": .string("b")])])])])
        c.check("body: a multi-part system prompt is never joined (throws)", normalizes(multi, "a\nb") == nil)
        for field in SIWCBody.contextReferenceFields {
            var ref = base; ref[field] = .string("x")
            c.check("body: \(field) is rejected locally, never stripped", normalizes(ref, prompt) == nil)
        }
        var noisy = base
        for field in SIWCBody.unsupportedFields { noisy[field] = .int(1) }
        let stripped = normalizes(noisy, prompt) ?? [:]
        c.check("body: every unsupported field is stripped (15)", SIWCBody.unsupportedFields.count == 15
                && SIWCBody.unsupportedFields.allSatisfy { stripped[$0] == nil } && (try? SIWCBody.check(stripped)) != nil)
        c.check("body: no typed prompt and no instructions → the legacy default instructions, nothing extracted",
                normalizes(base, nil)?["instructions"]?.responsesString == SIWCBody.defaultInstructions && normalizes(base, nil)?["input"]?.responsesArray?.count == 5)
        // Tools.
        let fn: JSONValue = .object(["type": .string("function"), "name": .string("read_file"), "parameters": .object([:]), "strict": .bool(false)])
        var tooled = base; tooled["tools"] = .array([fn, .object(["type": .string("function"), "name": .string("grep"), "parameters": .object([:])])])
        let wrapped = normalizes(tooled, prompt)?["tools"]?.responsesArray ?? []
        c.check("body: all function tools wrapped in ONE briglia namespace", wrapped.count == 1
                && wrapped[0].responsesObject?["type"]?.responsesString == "namespace" && wrapped[0].responsesObject?["name"]?.responsesString == "briglia"
                && wrapped[0].responsesObject?["tools"]?.responsesArray?.count == 2)
        var foreign = base; foreign["tools"] = .array([.object(["type": .string("namespace"), "name": .string("other"), "tools": .array([fn])])])
        c.check("body: a foreign tool namespace is refused", normalizes(foreign, prompt) == nil)
        var hosted = base; hosted["tools"] = .array([.object(["type": .string("web_search")])])
        c.check("body: only function tools are wrapped", normalizes(hosted, prompt) == nil)
        // Replay.
        let call: JSONValue = .object(["type": .string("function_call"), "call_id": .string("c1"), "name": .string("grep"), "arguments": .string("{}")])
        var replay = base; replay["input"] = .array([sys(prompt), call, .object(["type": .string("function_call_output"), "call_id": .string("c1"), "output": .string("x")])])
        let replayed = normalizes(replay, prompt)?["input"]?.responsesArray ?? []
        c.check("body: replayed calls carry namespace briglia; call_id correlation unchanged", replayed.first?.responsesObject?["namespace"]?.responsesString == "briglia"
                && replayed.first?.responsesObject?["call_id"]?.responsesString == "c1" && replayed.count == 2)
        var otherNS = base; otherNS["input"] = .array([.object(["type": .string("function_call"), "call_id": .string("c"), "name": .string("grep"),
                                                               "arguments": .string("{}"), "namespace": .string("evil")])])
        c.check("body: a replayed call in another namespace is refused", normalizes(otherNS, prompt) == nil)
        // Destination check.
        func dest(_ url: String, _ method: String) -> Bool {
            var r = URLRequest(url: URL(string: url)!); r.httpMethod = method
            return (try? SIWCBody.checkDestination(r)) != nil
        }
        c.check("dest: POST https://api.openai.com/v1/responses allowed", dest("https://api.openai.com/v1/responses", "POST"))
        c.check("dest: GET https://api.openai.com/v1/models allowed", dest("https://api.openai.com/v1/models", "GET"))
        for (label, url, method) in [("custom endpoint", "https://example.com/v1/responses", "POST"), ("http", "http://api.openai.com/v1/responses", "POST"),
                                     ("port", "https://api.openai.com:443/v1/responses", "POST"), ("query", "https://api.openai.com/v1/responses?x=1", "POST"),
                                     ("fragment", "https://api.openai.com/v1/responses#x", "POST"), ("userinfo", "https://u:p@api.openai.com/v1/responses", "POST"),
                                     ("chat completions", "https://api.openai.com/v1/chat/completions", "POST"), ("GET responses", "https://api.openai.com/v1/responses", "GET"),
                                     ("POST models", "https://api.openai.com/v1/models", "POST"), ("legacy backend", SubscriptionEndpoint.inference, "POST"),
                                     ("trailing slash", "https://api.openai.com/v1/responses/", "POST"), ("subdomain", "https://x.api.openai.com/v1/responses", "POST")] {
            c.check("dest: \(label) refused", !dest(url, method))
        }
        _ = root
    }

    // MARK: Route selection and context

    static func siwcSecrets(registrationFp: String, identityFp: String, generation: String) -> [String: String] {
        [ProviderProfiles.activeProfileKey: "chatgpt", KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
         ProviderProfiles.runtimeProtocolKey: "responses", KeychainHelper.openAICompatibleBaseURLKey: SIWCEndpoint.apiBase,
         KeychainHelper.openAICompatibleModelKey: "gpt-6.1-sol", ChatGPTRoute.routeKey: "siwc",
         ChatGPTRoute.siwcRegistrationKey: registrationFp, ChatGPTRoute.siwcIdentityKey: identityFp, ChatGPTRoute.siwcGenerationKey: generation]
    }

    /// A usable SIWC selection in the LIVE (temporary-XDG) roots: resolved
    /// store, machine host paths, secrets. Returns the source.
    static func liveSelection(clientId: String = "oaiappLiveA", sub: String = "user-sub-A", tokens t: SIWCTokens? = nil) async throws -> (SIWCCredentialSource, [String: String]) {
        let store = SIWCStore.resolved()
        var generation: String
        switch try await signIn(store, .live, clientId: clientId, sub: sub, new: (try store.readRegistrations()?.registration(clientId)) == nil,
                                tokens: t ?? tokens("live-\(clientId)")) {
        case .saved(_, let g): generation = try await store.activate(.init(clientId: clientId, generation: g, replacementId: nil))
        case .staged(_, let r, _): generation = try await store.activate(.init(clientId: clientId, generation: nil, replacementId: r))
        }
        let secrets = siwcSecrets(registrationFp: SIWCEndpoint.registrationFingerprint(clientId: clientId),
                                  identityFp: SIWCEndpoint.identityFingerprint(clientId: clientId, sub: sub), generation: generation)
        for (k, v) in secrets { try KeychainHelper.save(key: k, value: v) }
        guard case .siwc(let selection) = ChatGPTRoute.resolve(stored: KeychainHelper.loadSnapshot()) else { throw SIWCError(.local, "fixture") }
        return (try ChatGPTRoute.capture(selection, store: store), secrets)
    }

    static func routeTests(_ root: URL, _ c: Checks) async throws {
        let fpR = String(repeating: "a", count: 64), fpI = String(repeating: "b", count: 64), gen = UUID().uuidString
        let full = siwcSecrets(registrationFp: fpR, identityFp: fpI, generation: gen)
        func resolved(_ change: (inout [String: String]) -> Void, env: [String: String] = [:]) -> ChatGPTRoute.Resolved {
            var s = full; change(&s); return ChatGPTRoute.resolve(stored: s, environment: env)
        }
        c.check("route: another provider → not ChatGPT", resolved({ $0[ProviderProfiles.activeProfileKey] = "openrouter" }) == .notChatGPT)
        c.check("route: no route key → legacy (an existing install gains no key)", resolved({ $0[ChatGPTRoute.routeKey] = nil }) == .legacy)
        c.check("route: a complete SIWC selection resolves", resolved({ _ in }) == .siwc(.init(registrationFingerprint: fpR, identityFingerprint: fpI, generation: gen)))
        c.check("route: a legacy binding beside the SIWC route is ambiguous (D25)", resolved({ $0[ProviderProfiles.subscriptionGenerationKey] = UUID().uuidString }) == .ambiguous)
        c.check("route: a runtime credential slot beside the SIWC route is ambiguous", resolved({ $0[KeychainHelper.openAICompatibleApiKeyKey] = UUID().uuidString }) == .ambiguous)
        c.check("route: a legacy runtime endpoint is ambiguous", resolved({ $0[KeychainHelper.openAICompatibleBaseURLKey] = SubscriptionEndpoint.inference }) == .ambiguous)
        c.check("route: a missing fingerprint is ambiguous (never inferred)", resolved({ $0[ChatGPTRoute.siwcIdentityKey] = nil }) == .ambiguous)
        c.check("route: the kill switch disables the SIWC route", resolved({ _ in }, env: ["BRIGLIA_CHATGPT_ROUTE": "legacy"]) == .disabled)
        c.check("route: the kill switch leaves legacy alone", resolved({ $0[ChatGPTRoute.routeKey] = nil }, env: ["BRIGLIA_CHATGPT_ROUTE": "legacy"]) == .legacy)
        c.check("web: SIWC follows for web/extractor/OCR from the route keys (no runtime slot)", WebSearchBackend.followsSubscription(stored: full))
        c.check("web: an ambiguous SIWC selection still follows (its lanes refuse, no paid move)", WebSearchBackend.followsSubscription(stored: resolved_({ $0[ProviderProfiles.subscriptionGenerationKey] = "x" }, full)))
        var legacy = full; legacy[ChatGPTRoute.routeKey] = nil
        legacy[KeychainHelper.openAICompatibleApiKeyKey] = UUID().uuidString
        c.check("web: legacy follow rule unchanged (slot present)", WebSearchBackend.followsSubscription(stored: legacy))
        legacy[KeychainHelper.openAICompatibleApiKeyKey] = nil
        c.check("web: legacy follow rule unchanged (no slot → no follow)", !WebSearchBackend.followsSubscription(stored: legacy))
        // Capture against a real store.
        let (source, secrets) = try await liveSelection()
        c.check("capture: the selection names the store's active registration", source.clientId == "oaiappLiveA"
                && source.storeDirectory.standardizedFileURL == SubscriptionSharing.storeDirectory().standardizedFileURL)
        let context = ProviderExecutionContext.siwcFromStored(secrets, model: "gpt-6.1-sol", effort: "high", lane: .main, textOnly: false)
        c.check("context: SIWC context carries its source, no legacy generation", context?.siwc == source && context?.subscriptionGeneration == nil
                && context?.endpoint == SIWCEndpoint.apiBase && context?.isChatGPTPlan == true && context?.siwcFailure == nil)
        c.check("context: the API-key slot is never read (empty authorization)", context?.authorization == "")
        // Replay separation across API, legacy, SIWC A and SIWC B.
        let api = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "sk-test-synthetic", model: "gpt-6.1-sol", lane: .main)
        var legacyCtx = api; legacyCtx.subscriptionGeneration = UUID().uuidString
        let (sourceB, _) = try await liveSelection(clientId: "oaiappLiveB", sub: "user-sub-B")
        let ctxB = ProviderExecutionContext.siwcContext(source: sourceB, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false, nativeToolMedia: false)
        let scopes = [api.responsesScope.credentialFingerprint, context?.responsesScope.credentialFingerprint ?? "", ctxB.responsesScope.credentialFingerprint]
        c.check("replay: API, SIWC A and SIWC B never share a replay scope", Set(scopes).count == 3)
        c.check("spend: SIWC on api.openai.com is never priced as paid API", ResearchSpend.isPaidOpenAI(api) && !ResearchSpend.isPaidOpenAI(ctxB))
        c.check("usage: SIWC is booked in the subscription bucket", ResponsesUsageStore.record(context: ctxB, requestID: UUID(), attempt: 1, sentRoutingState: false).provider == .subscription)
        // Capture refusals.
        let store = SIWCStore.resolved()
        var regs = try store.readRegistrations()!
        c.check("capture: another registration active → D18 refusal, nothing inferred", {
            do { _ = try ChatGPTRoute.capture(.init(registrationFingerprint: SIWCEndpoint.registrationFingerprint(clientId: "oaiappLiveA"),
                    identityFingerprint: SIWCEndpoint.identityFingerprint(clientId: "oaiappLiveA", sub: "user-sub-A"), generation: source.generation), store: store, rebind: false); return false }
            catch let e as SIWCError { return e.message.contains("different account") } catch { return false } }())
        regs.active = "oaiappLiveA"
        _ = try PrivateStorage.writeAtomically(try SIWCStore.encode(regs), to: store.registrationsFile)
        c.check("capture: a stale generation is refused before any send", (try? ChatGPTRoute.capture(.init(registrationFingerprint: SIWCEndpoint.registrationFingerprint(clientId: "oaiappLiveA"),
            identityFingerprint: SIWCEndpoint.identityFingerprint(clientId: "oaiappLiveA", sub: "user-sub-A"), generation: UUID().uuidString), store: store)) == nil)
        // Selection unusable → a context that refuses, never the legacy path.
        var broken = secrets; broken[ChatGPTRoute.siwcGenerationKey] = UUID().uuidString
        let refusing = ProviderExecutionContext.siwcFromStored(broken, model: "gpt-6.1-sol", effort: nil, lane: .main, textOnly: false)
        c.check("context: an unusable SIWC selection yields a refusing SIWC context (not legacy, not API)",
                refusing?.siwc == nil && refusing?.siwcFailure != nil && refusing?.subscriptionGeneration == nil)
        do { _ = try ResponsesAdapter(context: refusing!).request(input: [user("x")], tools: nil); c.check("context: the refusing context builds no request", false) }
        catch { c.check("context: the refusing context builds no request", true) }
        for key in secrets.keys { try? KeychainHelper.delete(key: key) }
    }

    static func resolved_(_ change: (inout [String: String]) -> Void, _ base: [String: String]) -> [String: String] { var s = base; change(&s); return s }
}
