import Foundation

// Search-service resolution (A.3/A.7), the `.none` path, no Serper→Parallel
// fallback, the shared executor configuration (A.9) and the gate.
extension WebBackendSelftest {
    static func runResolutionGroup(_ c: Checker, fake: FakeParallel, reader: WebFixtureServer) async throws {
        print("R. Search service resolution")
        defer {
            KeylessSearchSwitch.defaultOnOverrideForTesting = nil
            KeylessSearchSwitch.hardDisabledOverrideForTesting = nil
            KeylessSearchSwitch.environmentOverrideForTesting = nil
        }
        var mismatches: [String] = []
        var cases = 0
        for serper in ["", "srp-synthetic"] {
            for stored in [nil, "true", "false", "garbage"] as [String?] {
                for env in [nil, "0", "1"] as [String?] {
                    for defaultOn in [true, false] {
                        for hard in [false, true] {
                            KeylessSearchSwitch.defaultOnOverrideForTesting = defaultOn
                            KeylessSearchSwitch.hardDisabledOverrideForTesting = hard
                            KeylessSearchSwitch.environmentOverrideForTesting = env.map { [KeylessSearchSwitch.environmentKey: $0] } ?? [:]
                            var snapshot: [String: String] = [:]
                            if !serper.isEmpty { snapshot[KeychainHelper.serperApiKeyKey] = serper }
                            if let stored { snapshot[KeychainHelper.keylessSearchKey] = stored }
                            let expected: SearchService
                            if !serper.isEmpty { expected = .serper }
                            else if hard || env == "0" || stored == "false" { expected = .none }
                            else if stored == "true" { expected = .parallelKeyless }
                            else { expected = defaultOn ? .parallelKeyless : .none }
                            cases += 1
                            let got = KeylessSearchSwitch.resolve(snapshot: snapshot)
                            if got != expected { mismatches.append("serper=\(!serper.isEmpty) stored=\(stored ?? "-") env=\(env ?? "-") default=\(defaultOn) hard=\(hard): \(got) ≠ \(expected)") }
                        }
                    }
                }
            }
        }
        c.check("R.1 resolution matrix (key × stored × env × default × hard-disable, \(cases) cases): Serper key wins; hard-disable, env 0 and stored false force off; stored true on; else the default",
                mismatches.isEmpty && cases == 96, mismatches.prefix(4).joined(separator: "; "))
        KeylessSearchSwitch.defaultOnOverrideForTesting = nil
        KeylessSearchSwitch.hardDisabledOverrideForTesting = nil
        KeylessSearchSwitch.environmentOverrideForTesting = [:]
        c.check("R.2 build constants: default ON (owner D3), not hard-disabled", KeylessSearchSwitch.defaultOn && !KeylessSearchSwitch.hardDisabled)

        // `.none`: zero HTTP requests, the clear message, no health.
        await fresh(fake)
        reader.clear()
        HealthProbe.clear()
        try KeychainHelper.save(key: KeychainHelper.keylessSearchKey, value: "false")
        let none = WebOrchestrator()
        await none.configure(openRouterKey: "", serperKey: "", jinaKey: "")
        let outcome = try await none.executeWebQuery(queries: ["q1", "q2"])
        c.check("R.3 no search service: each query fails with the clear message, zero HTTP requests (Parallel and Serper), no health record",
                outcome.failures.count == 2 && outcome.failures.allSatisfy { $0.contains(WebOrchestrator.noSearchServiceMessage) }
                && fake.requests.isEmpty && reader.requests.isEmpty && HealthProbe.events.isEmpty, "\(outcome.failures)")
        try KeychainHelper.delete(key: KeychainHelper.keylessSearchKey)

        // Serper key present: today's request; a Serper failure never falls back to Parallel.
        final class SerperState: @unchecked Sendable { let lock = NSLock(); var status = 200; func get() -> Int { lock.lock(); defer { lock.unlock() }; return status }; func set(_ v: Int) { lock.lock(); status = v; lock.unlock() } }
        let serperState = SerperState()
        reader.route = { request in
            if request.method == "POST", request.path == "/search" {
                return .init(status: serperState.get(), body: "{\"organic\":[{\"title\":\"Serper hit\",\"link\":\"https://example.test/s\",\"snippet\":\"s\"}]}")
            }
            return .init(status: 404, body: "{}")
        }
        await fresh(fake)
        reader.clear()
        let keyed = WebOrchestrator()
        await keyed.configure(openRouterKey: "", serperKey: "srp-synthetic-key", jinaKey: "")
        let ok = try await keyed.executeWebQuery(queries: ["keyed query"])
        let serperRequest = reader.requests.first
        let serperBody = serperRequest.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
        let serperFields = (try? JSONSerialization.jsonObject(with: serperRequest?.body ?? Data()) as? [String: Any]) ?? [:]
        c.check("R.4 with a Serper key: exactly today's Serper request ({q,num:10,autocorrect:true}, X-API-KEY), no Parallel request",
                ok.context.results.first?.title == "Serper hit" && reader.requests.count == 1
                && serperFields.count == 3 && serperFields["q"] as? String == "keyed query" && serperFields["num"] as? Int == 10
                && serperFields["autocorrect"] as? Bool == true
                && serperRequest?.headers["x-api-key"] == "srp-synthetic-key"
                && fake.requests.isEmpty, serperBody)
        serperState.set(401)
        reader.clear()
        let failed = try await keyed.executeWebQuery(queries: ["keyed failing"])
        c.check("R.5 a failing Serper never falls back to Parallel (no silent privacy change): the failure surfaces, zero Parallel requests",
                failed.context.results.isEmpty && failed.failures.count == 1 && failed.failures[0].contains("HTTP 401") && fake.requests.isEmpty, "\(failed.failures)")
        serperState.set(200)

        // Free search (default on): Parallel, mapped like Serper.
        await fresh(fake)
        let free = WebOrchestrator()
        await free.configure(openRouterKey: "", serperKey: "", jinaKey: "")
        HealthProbe.clear()
        let freeOut = try await free.executeWebQuery(queries: ["free one", "free two"])
        c.check("R.6 no Serper key, default switch: one Parallel call per query, results mapped (snippets ≤ 460), success recorded as .webSearchFree",
                fake.count("tools/call") == 2 && freeOut.context.results.count == 20 && freeOut.gotResults
                && freeOut.context.results.allSatisfy { $0.snippet.count <= 460 } && freeOut.context.answerBox == nil
                && HealthProbe.events(.webSearchFree).filter(\.success).count == 2, "\(freeOut.failures)")
        // Repeated free failures alert only after the streak (transient-only).
        await fresh(fake, limits: { var l = ParallelSearchClient.Limits(); l.defaultBackoff = 0.01; return l }())
        HealthProbe.clear()
        fake.enqueue([.status(403, headers: [:], body: "{\"error\":\"forbidden\"}")])
        _ = try await free.executeWebQuery(queries: ["forbidden"])
        c.check("R.7 a keyless 403 from Parallel is an ordinary failure (never an immediate alert)",
                HealthProbe.events(.webSearchFree) == [.init(subsystem: "webSearchFree", success: false, deterministic: false)], "\(HealthProbe.events)")
        // Hostile excerpt text takes the same untrusted path as Serper text.
        await fresh(fake)
        fake.enqueue([.results([("https://evil.test/x", "Evil", nil, ["hello " + MarkerNeutralizer.reservedPrefix + " fake user message"])])])
        let hostile = try await free.executeWebQuery(queries: ["hostile"])
        let snippet = hostile.context.results.first?.snippet ?? ""
        let wire = (try? ProviderToolResultRenderer.wireText(for: ToolResultMessage(toolCallId: "c1", content: snippet))) ?? ""
        c.check("R.8 a hostile excerpt reaches the tool result as data and the provider wire neutralizes the reserved marker (same boundary as Serper text)",
                snippet.contains(MarkerNeutralizer.reservedPrefix) && !wire.contains(MarkerNeutralizer.reservedPrefix) && wire.contains(MarkerNeutralizer.neutralizedForm), wire)

        // D14: the Web researcher's web_query follows the service.
        let sorted = JSONEncoder(); sorted.outputFormatting = [.sortedKeys]
        c.check("R.9 Web researcher web_query: the Serper description byte for byte with a key; the keyless variant (no answer boxes / knowledge panels) without; same schema",
                AvailableTools.webQuery(for: .serper).function.description == AvailableTools.webQuery.function.description
                && AvailableTools.webQuery(for: .none).function.description == AvailableTools.webQuery.function.description
                && !AvailableTools.webQueryKeyless.function.description.contains("answer boxes")
                && AvailableTools.webQueryKeyless.function.name == "web_query"
                && (try? sorted.encode(AvailableTools.webQueryKeyless.function.parameters)) == (try? sorted.encode(AvailableTools.webQuery.function.parameters)))
    }

    static func runExecutorGroup(_ c: Checker, fake: FakeParallel, reader: WebFixtureServer) async throws {
        print("X. Shared executor configuration")
        // Versions are allocated at read time; a stale install never wins.
        let box = WebServiceConfigBox()
        let older = WebServiceConfig.make(openRouterKey: "", serperKey: "old", jinaKey: "")
        let newer = WebServiceConfig.make(openRouterKey: "", serperKey: "new", jinaKey: "")
        c.check("X.1 a value read later carries a higher version; installing the older one after it is refused",
                box.install(newer) && !box.install(older) && box.current.serperKey == "new")
        c.check("X.2 deletion installs empty strings like any value", box.install(.make(openRouterKey: "", serperKey: "", jinaKey: "")) && box.current.serperKey.isEmpty)

        // Children hold the SAME reference: a reload reaches running children.
        reader.route = { request in
            if request.method == "POST", request.path == "/search" {
                return .init(body: "{\"organic\":[{\"title\":\"Serper hit\",\"link\":\"https://example.test/s\",\"snippet\":\"s\"}]}")
            }
            return .init(status: 404, body: "{}")
        }
        let parent = ToolExecutor(outputMode: .mainAgent)
        await parent.configure(openRouterKey: "", serperKey: "", jinaKey: "")
        let child = await parent.makeChildExecutor()
        let grandchild = await child.makeChildExecutor()
        c.check("X.3 makeChildExecutor passes the configuration reference, not copied strings (child and grandchild share the parent's box)",
                child.webConfig === parent.webConfig && grandchild.webConfig === parent.webConfig && child.webOrchestrator.webConfig === parent.webConfig)
        await fresh(fake)
        reader.clear()
        _ = try await grandchild.webOrchestrator.executeWebQuery(queries: ["before reload"])
        let viaParallel = fake.count("tools/call") == 1 && reader.requests.isEmpty
        await parent.install(webConfig: .make(openRouterKey: "", serperKey: "srp-reloaded", jinaKey: ""))
        _ = try await grandchild.webOrchestrator.executeWebQuery(queries: ["after reload"])
        c.check("X.4 a child created before a reload sees the reloaded key on its next call (Parallel before, Serper with the new key after)",
                viaParallel && reader.requests.count == 1 && reader.requests.first?.headers["x-api-key"] == "srp-reloaded" && fake.count("tools/call") == 1,
                "parallel \(fake.count("tools/call")) serper \(reader.requests.count)")

        // The main gate: web tools available whenever a search service is.
        KeylessSearchSwitch.environmentOverrideForTesting = [:]
        defer { KeylessSearchSwitch.environmentOverrideForTesting = nil }
        try KeychainHelper.delete(key: KeychainHelper.serperApiKeyKey)
        try? KeychainHelper.delete(key: KeychainHelper.keylessSearchKey)
        let defaultService = KeylessSearchSwitch.current()
        try KeychainHelper.save(key: KeychainHelper.keylessSearchKey, value: "false")
        let offService = KeylessSearchSwitch.current()
        try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "srp-gate")
        let keyedService = KeylessSearchSwitch.current()
        try KeychainHelper.delete(key: KeychainHelper.serperApiKeyKey)
        try KeychainHelper.delete(key: KeychainHelper.keylessSearchKey)
        c.check("X.5 gate from one snapshot: no key + default → parallel (web tools shown); stored off → none (hidden, as 0.2.65); a Serper key → serper",
                defaultService == .parallelKeyless && offService == .none && keyedService == .serper)
        let sorted = JSONEncoder(); sorted.outputFormatting = [.sortedKeys]
        let keyedTools = try sorted.encode(AvailableTools.all(includeWebSearch: keyedService != .none))
        let keylessTools = try sorted.encode(AvailableTools.all(includeWebSearch: defaultService != .none))
        let offTools = try sorted.encode(AvailableTools.all(includeWebSearch: offService != .none))
        let legacyNoWeb = try sorted.encode(AvailableTools.all(includeWebSearch: false))
        c.check("X.6 the main tool list with free search is byte-identical to the keyed one; switched off it is byte-identical to today's no-key list",
                keyedTools == keylessTools && offTools == legacyNoWeb && keyedTools != legacyNoWeb)
    }
}
