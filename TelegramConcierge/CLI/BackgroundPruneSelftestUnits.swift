import Foundation

/// Pure units: the threshold-relative ceiling (B6, §9.1 v4.1, overflow-safe
/// +100k, 25k headroom, learned bound), identity-keyed window lookup and
/// the exact eligible-error table (§10.2), including the real chat
/// transport's 400 prefix.
enum BackgroundPruneSelftestUnits {
    @MainActor static func run(_ h: BackgroundPruneSelftestHarness) async {
        typealias C = BackgroundPruneCeiling
        // B6 relative ceiling edges.
        h.check("B6 default maximum, unknown window → C = 350,000", C.ceiling(maximum: 250_000, window: nil, observed: nil) == 350_000)
        h.check("B6 W 400k: maximum 250k → C = 350,000", C.ceiling(maximum: 250_000, window: 400_000, observed: nil) == 350_000)
        let c1 = C.ceiling(maximum: 342_232, window: 400_000, observed: nil)
        h.check("B6 W 400k: maximum 342,232 → C 367,232, headroom 25,000 allowed",
                c1 == 367_232 && C.backgroundAllowed(maximum: 342_232, ceiling: c1))
        let c2 = C.ceiling(maximum: 342_233, window: 400_000, observed: nil)
        h.check("B6 W 400k: maximum 342,233 → headroom 24,999 → inline",
                c2 == 367_232 && !C.backgroundAllowed(maximum: 342_233, ceiling: c2))
        h.check("B6 W 272k at the default maximum → C 239,232 (below the maximum) → inline",
                C.ceiling(maximum: 250_000, window: 272_000, observed: nil) == 239_232
                && !C.backgroundAllowed(maximum: 250_000, ceiling: 239_232))
        h.check("B6 lowered maximum 150k, unknown W → C 250,000 (not 350,000)", C.ceiling(maximum: 150_000, window: nil, observed: nil) == 250_000)
        let raised = C.ceiling(maximum: 400_000, window: 1_000_000, observed: nil)
        h.check("B6 raised maximum 400k, W 1M → C 500,000, background starts",
                raised == 500_000 && C.backgroundAllowed(maximum: 400_000, ceiling: raised))
        h.check("B6 learned bound 270k at 250k, unknown W → C 270k, headroom 20k → inline (v4.1 review)",
                C.ceiling(maximum: 250_000, window: nil, observed: 270_000) == 270_000
                && !C.backgroundAllowed(maximum: 250_000, ceiling: 270_000))
        h.check("overflow: maximum Int.max saturates instead of trapping",
                C.ceiling(maximum: Int.max, window: nil, observed: nil) == Int.max
                && C.ceiling(maximum: Int.max - 5, window: 1_000_000, observed: nil) == 1_000_000 - 32_768)
        h.check("overflow: tiny window minus reserve saturates", C.ceiling(maximum: 10_000, window: Int.min + 3, observed: nil) == Int.min)
        h.check("overflow: headroom of extreme values never traps",
                !C.backgroundAllowed(maximum: Int.max, ceiling: Int.min) && C.backgroundAllowed(maximum: Int.min, ceiling: Int.max))

        // §9.2 identity-keyed lookups.
        BackgroundPruneContextWindow.overrides = ["p|openai|chat|m|together": 200_000]
        h.check("window lookup is per identity (pin part of the identity)",
                BackgroundPruneContextWindow.window(identity: "p|openai|chat|m|together", model: "m") == 200_000
                && BackgroundPruneContextWindow.window(identity: "p|openai|chat|m|deepinfra", model: "m") == nil)
        BackgroundPruneContextWindow.overrides = [:]
        h.check("catalog is empty: every identity is 'window unknown' (C = maximum + 100k)",
                BackgroundPruneContextWindow.catalog.isEmpty)

        // §10.2 eligible errors.
        let eligible: [(String, Error, Bool)] = [
            ("Responses HTTP 400", ResponsesFailure.http(400, nil), true),
            ("Responses HTTP 413", ResponsesFailure.http(413, nil), true),
            ("Responses HTTP 401", ResponsesFailure.http(401, nil), false),
            ("Responses HTTP 429", ResponsesFailure.http(429, 1), false),
            ("Responses HTTP 503", ResponsesFailure.http(503, nil), false),
            ("Responses SSE context_length_exceeded", ResponsesFailure.failed("context_length_exceeded"), true),
            ("Responses SSE other code", ResponsesFailure.failed("server_error"), false),
            ("Responses local overflow", ResponsesFailure.overflow, false),
            ("Responses disconnected", ResponsesFailure.disconnected, false),
            ("chat HTTP 400 prefix", OpenRouterError.apiError("HTTP 400: {\"error\":{}}"), true),
            ("chat HTTP 413 prefix", OpenRouterError.apiError("HTTP 413: too big"), true),
            ("chat HTTP 500", OpenRouterError.apiError("HTTP 500: boom"), false),
            ("chat 413 exhausted (different prefix)", OpenRouterError.apiError("OpenCode refused the request body (HTTP 413) on every attempt"), false),
            ("chat notConfigured", OpenRouterError.notConfigured, false),
            ("cancellation", CancellationError(), false),
        ]
        for (label, error, expected) in eligible {
            h.check("§10.2 \(label) → \(expected ? "eligible" : "not eligible")", BackgroundPruneErrors.isEligibleInBand(error) == expected)
        }

        // E-group: the real chat transport's 400 with a nested OpenRouter body.
        let manager = await h.freshManager(history: h.prunableHistory(pairs: 2, size: 200), switchOn: nil)
        h.server.script(["{\"error\":{\"message\":\"Input is too long\",\"code\":400,\"metadata\":{\"raw\":\"context_length_exceeded\"}}}"], statuses: [400])
        let error = await manager.bgPruneTestRawSendError()
        h.check("E real chat transport: HTTP 400 nested body → eligible (prefix pinned)",
                error.map(BackgroundPruneErrors.isEligibleInBand) == true, "\(String(describing: error))")
        h.server.script(["{\"error\":{\"message\":\"nope\"}}"], statuses: [401])
        let unauthorized = await manager.bgPruneTestRawSendError()
        h.check("E real chat transport: HTTP 401 → not eligible", unauthorized.map(BackgroundPruneErrors.isEligibleInBand) == false)
    }
}
