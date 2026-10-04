import Foundation

/// Rows E1–E10 (eligibility, passes, cooldowns, growth gate, startup),
/// R2–R5 through the real transport, and the request budget (E5h, E5j).
extension UserContextMaintenanceSelftest {

    static func eligibilityRows(_ h: UCMHarness) async throws {
        // E1: under the threshold with cleanup done → no request.
        var archive = try h.fresh(profile: UCMHarness.profile(size: 35_000))
        var state = UserContextMaintenanceState(); state.cleanupV1 = .done
        try h.writeState(state)
        h.check("E1 35k profile, cleanup done → 0 sends", await h.event(archive) == 0)

        // E2: a reply that reaches the target ends after one pass.
        let p45 = UCMHarness.profile(size: 45_000)
        archive = try h.fresh(profile: p45)
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        var sends = await h.event(archive)
        h.check("E2 one pass when pass 1 reaches the target", sends == 1 && h.profile.count <= 30_000, "sends \(sends), size \(h.profile.count)")
        h.check("E2 success clears failure/deferral and marks cleanup done",
                h.validState.map { $0.cleanupV1 == .done && $0.deferral == nil && $0.failure == nil && $0.attempt == nil } == true)

        // E3: still over target after pass 1 → exactly one more pass, never a third.
        archive = try h.fresh(profile: p45)
        h.script([UCMHarness.dropOps(for: p45, toBelow: 38_000), "{\"drop\":[1]}", "{\"drop\":[1]}"])
        sends = await h.event(archive)
        h.check("E3 two passes at most, then accepted (no third pass)", sends == 2, "sends \(sends)")
        let e3Pass2 = h.maintenanceRequests.last.map { UCMHarness.systemText($0.body) } ?? ""
        h.check("E3 pass 2 is renumbered and says how far over the target it still is",
                e3Pass2.contains("Still ") && e3Pass2.contains("over the limit of 30,000") && e3Pass2.contains("[1] "))

        // E4: pass-2 failure keeps pass 1's commit.
        archive = try h.fresh(profile: p45)
        h.script([UCMHarness.dropOps(for: p45, toBelow: 38_000), "garbage", "garbage", "garbage"])
        sends = await h.event(archive)
        let afterPass1 = h.profile.count
        h.check("E4 pass-2 failure keeps the pass-1 commit and records a failure",
                afterPass1 < 39_000 && h.validState?.failure?.kind == .transient && sends == 4, "size \(afterPass1) sends \(sends)")

        // E5 + amendment 3: a 45k profile and `{}` (no change) replies → one
        // run, then nothing until it has grown by 4k, then 8k; never at restarts.
        archive = try h.fresh(profile: p45)
        h.defaultMaintenanceReply = "{}"
        sends = await h.event(archive)
        h.check("E5 no-change reply: one run, two passes (pass 2 asks once more), then accepted", sends == 2, "sends \(sends)")
        let deferral = h.validState?.deferral
        h.check("E5 completed but still above 40k → deferral recorded (consecutive 1) and cleanup done",
                deferral?.consecutive == 1 && deferral?.sizeAtDeferral == p45.count && h.validState?.cleanupV1 == .done)
        var repeats = 0
        for _ in 0..<5 { repeats += await h.event(archive) }
        for _ in 0..<3 { repeats += await h.event(ConversationArchiveService(), .startupRecovery) }
        h.check("E5 amendment 3: unchanged result → 0 sends at the next 5 archive events and 3 restarts", repeats == 0, "\(repeats)")
        try h.setProfile(p45 + String(repeating: "- grown fact padding padding padding padding padding padding padding\n", count: 40))
        let belowGrowth = await h.event(archive)
        h.check("E5 below +4k growth still closed", h.profile.count < p45.count + 4_000 && belowGrowth == 0)
        try h.setProfile(p45 + String(repeating: "- grown fact padding padding padding padding padding padding padding\n", count: 60))
        h.check("E5 +4k growth reopens one run (two passes)", await h.event(archive) == 2)
        h.check("E5 second non-converging run: consecutive 2, gate now +8k", h.validState?.deferral?.consecutive == 2)
        h.check("E5 no run again until +8k", await h.event(archive) == 0)

        // Amendment 3: a run that makes the profile LARGER is deferred from its final size.
        let p41 = UCMHarness.profile(size: 41_000)
        archive = try h.fresh(profile: p41)
        let longAdds = (0..<40).map { "{\"text\":\"added fact \($0) that makes the whole profile larger than before\"}" }.joined(separator: ",")
        h.script(["{\"add\":[\(longAdds)]}", "{}"])
        sends = await h.event(archive)
        let grownSize = h.profile.count
        h.check("amendment 3: growth-only reply is applied (no shrink check) and the run still ends", grownSize > p41.count && sends == 2, "size \(grownSize) sends \(sends)")
        h.check("amendment 3: deferral is anchored at the final (larger) size",
                h.validState?.deferral?.sizeAtDeferral == grownSize, "\(String(describing: h.validState?.deferral))")
        let rerunArchive = await h.event(archive)
        let rerunStartup = await h.event(ConversationArchiveService(), .startupRecovery)
        h.check("amendment 3: no re-run at the next archive or restart", rerunArchive == 0 && rerunStartup == 0)

        // E6: growth formula, saturating.
        let policy = UserContextMaintenancePolicy.standard
        let growth = (1...6).map { policy.growth(consecutive: $0) }
        h.check("E6 growth 4k/8k/16k/32k/32k/32k", growth == [4_000, 8_000, 16_000, 32_000, 32_000, 32_000], "\(growth)")
        h.check("E6 gate arithmetic saturates (huge sizeAtDeferral)",
                !UserContextMaintenance.growthGateOpen(.init(sizeAtDeferral: Int.max - 10, consecutive: 1_000_000, at: Date()), size: Int.max - 20, policy: policy))

        // E7: startup never runs on size alone.
        archive = try h.fresh(profile: p45)
        h.check("E7 startup with a 45k profile and no due failure → 0 sends", await h.event(archive, .startupRecovery) == 0)
        h.check("E7 startup leaves cleanup pending (it never decides on size)", h.validState == nil || h.validState?.cleanupV1 == .pending)

        // E9: one-time cleanup.
        let p35 = UCMHarness.profile(size: 35_000)
        archive = try h.fresh(profile: p35)
        h.script([UCMHarness.dropOps(for: p35, toBelow: 29_000)])
        h.check("E9 35k with no state: one cleanup run at the first archive event", await h.event(archive) == 1)
        let e9Again = await h.event(archive)
        h.check("E9 then cleanup done; no further run under 40k", h.validState?.cleanupV1 == .done && e9Again == 0)
        archive = try h.fresh(profile: UCMHarness.profile(size: 25_000))
        h.check("E9 25k: no run, cleanup marked done", await h.event(archive) == 0 && h.validState?.cleanupV1 == .done)

        // E10: the legacy flag is ignored and removed.
        UserDefaults.standard.set(true, forKey: UserContextMaintenance.legacyRetryFlagKey)
        archive = try h.fresh(profile: UCMHarness.profile(size: 25_000))
        h.check("E10 legacy retry flag set: no full rewrite request, 0 sends", await h.event(archive) == 0 && h.server.requests.isEmpty)
        h.check("E10 legacy flag removed after the first state load", UserDefaults.standard.object(forKey: UserContextMaintenance.legacyRetryFlagKey) == nil)
    }

    static func failureRows(_ h: UCMHarness) async throws {
        let p45 = UCMHarness.profile(size: 45_000)
        // R2 / E5b: failing replies → cooldown 1 h / 6 h / 24 h, 0 sends in between.
        var archive = try h.fresh(profile: p45)
        h.defaultMaintenanceReply = "not json at all"
        var sends = await h.event(archive)
        h.check("R2 malformed replies: one pass of 3 attempts, then a transient failure", sends == 3 && h.validState?.failure?.kind == .transient, "\(sends)")
        h.check("R2 the profile is untouched", h.profile == p45)
        var between = 0
        for _ in 0..<4 { between += await h.event(archive) }
        h.clock.advance(59 * 60); between += await h.event(archive)
        h.check("E5b no sends during the 1 h cooldown", between == 0, "\(between)")
        h.clock.advance(61); sends = await h.event(archive)
        h.check("E5b after 1 h one retry run; failure count 2 → 6 h cooldown", sends == 3 && h.validState?.failure?.count == 2)
        h.clock.advance(5 * 3600); h.check("E5b nothing at 5 h", await h.event(archive) == 0)
        h.clock.advance(3601); _ = await h.event(archive)
        h.clock.advance(23 * 3600); h.check("E5b third failure → 24 h cooldown (nothing at 23 h)", await h.event(archive) == 0)
        h.clock.advance(3601); h.defaultMaintenanceReply = UCMHarness.dropOps(for: p45, toBelow: 29_000)
        h.check("E5b recovery run succeeds and clears the failure", await h.event(archive) == 1 && h.validState?.failure == nil)

        // E5c: cleanup pending + failures → same cooldown.
        let p35 = UCMHarness.profile(size: 35_000)
        archive = try h.fresh(profile: p35)
        h.defaultMaintenanceReply = "@HTTP:503"
        sends = await h.event(archive)
        h.check("E5c cleanup pending with transient failures: one failed run", sends == 3 && h.validState?.cleanupV1 == .pending)
        between = 0
        for _ in 0..<3 { between += await h.event(archive) }
        h.check("E5c cleanup pending does not bypass the cooldown", between == 0, "\(between)")

        // R5 / E5d: deterministic HTTP → one attempt; next only at an archive event after 24 h, never at startup.
        archive = try h.fresh(profile: p45)
        h.defaultMaintenanceReply = "@HTTP:401"
        sends = await h.event(archive)
        h.check("R5 deterministic HTTP 401 (Chat): one attempt, no retry", sends == 1 && h.validState?.failure?.kind == .deterministic, "\(sends)")
        h.clock.advance(24 * 3600 + 1)
        h.check("E5d deterministic failure never retried at startup", await h.event(ConversationArchiveService(), .startupRecovery) == 0)
        h.check("E5d retried at the first archive event after 24 h", await h.event(archive) == 1)

        // R3: a cut-off reply is rejected even though its JSON parses.
        archive = try h.fresh(profile: p45)
        let cut = "@LENGTH:" + UCMHarness.dropOps(for: p45, toBelow: 29_000)
        h.script([cut, cut, cut])
        sends = await h.event(archive)
        h.check("R3 Chat finish_reason=length rejected though the JSON parses; profile untouched",
                sends == 3 && h.profile == p45 && h.retired().isEmpty, "\(sends)")

        // R4: empty and tool-call replies, no internal re-ask.
        archive = try h.fresh(profile: p45)
        h.script(["@EMPTY", "@TOOLS", "@TOOLS"])
        sends = await h.event(archive)
        h.check("R4 empty and tool-call replies are failed attempts, never re-asked inside one attempt",
                sends == 3 && h.validState?.failure?.kind == .transient, "\(sends)")

        // E5g: an obsolete failure is cleared when the profile shrinks externally.
        h.clock.advance(3601 * 30)
        try h.setProfile(UCMHarness.profile(size: 20_000))
        _ = await h.event(archive)
        h.check("E5g obsolete failure and deferral cleared when the profile is ≤ threshold", h.validState?.failure == nil && h.validState?.deferral == nil)

        // E5j: classifier equal on both protocols.
        let statuses = [400, 401, 402, 403, 404, 405, 413, 422, 408, 429, 500, 502, 503]
        let same = statuses.allSatisfy {
            UserContextMaintenance.classify(ArchiveError.apiHTTPError(status: $0, detail: nil))
                == UserContextMaintenance.classify(ResponsesFailure.http($0, nil))
        }
        h.check("E5j HTTP classification identical for Chat and Responses", same)
        h.check("E5j configuration and subscription errors deterministic; budgets and cut-offs transient",
                UserContextMaintenance.classify(ArchiveError.notConfigured(reason: "x")) == .deterministic
                && UserContextMaintenance.classify(SubscriptionError("x")) == .deterministic
                && UserContextMaintenance.classify(UserContextMaintenance.ConfigurationError(reason: "x")) == .deterministic
                && UserContextMaintenance.classify(SendBudgetExhausted(limit: 6)) == .transient
                && UserContextMaintenance.classify(AuthBudgetExhausted(limit: 2)) == .transient
                && UserContextMaintenance.classify(UserContextMaintenance.CutOffReply(finishReason: "length")) == .transient)
    }

    static func budgetRows(_ h: UCMHarness) async throws {
        let p45 = UCMHarness.profile(size: 45_000)
        for proto in ["chat", "responses"] {
            if proto == "chat" { try h.useChat() } else { try h.useResponses() }
            // E5h: always failing → ≤ 6 sends per run, no adapter-internal retries.
            for (label, reply) in [("tool call", "@TOOLS"), ("malformed", "nope"), ("5xx", "@HTTP:503"), ("429", "@HTTP:429")] {
                let archive = try h.fresh(profile: p45)
                // Pass 1 fails twice then succeeds partially, so pass 2 also
                // runs and fails three times: the shared 6-send budget is reached.
                h.script([reply, reply, UCMHarness.dropOps(for: p45, toBelow: 41_000)])
                h.defaultMaintenanceReply = reply
                let sends = await h.event(archive)
                h.check("E5h \(proto) \(label): sends counted at the fixture = 6 per run (no adapter-internal retries, no re-ask)",
                        sends == 6, "sends \(sends)")
                let a2 = ConversationArchiveService()
                h.clock.advance(25 * 3600)
                h.script([]); h.defaultMaintenanceReply = reply
                let more = await h.event(a2)
                h.check("E5h \(proto) \(label): an always-failing run stops after one pass (3 sends)", more == 3, "\(more)")
            }
            // Budget exhaustion within one pass: policy with 3 attempts and a 2-send budget.
            var tight = UserContextMaintenancePolicy(attemptDelays: [0, 0]); tight.maxModelSendsPerRun = 2
            let archive = try h.fresh(profile: p45, policy: tight)
            if proto == "responses" { try h.useResponses() }
            h.defaultMaintenanceReply = "@HTTP:503"
            let sends = await h.event(archive)
            h.check("E5h \(proto): the send budget is a hard bound (2-send budget → 2 sends, transient failure)",
                    sends == 2 && h.validState?.failure?.kind == .transient, "\(sends)")
            // R5 Responses deterministic.
            if proto == "responses" {
                let a = try h.fresh(profile: p45); try h.useResponses()
                h.defaultMaintenanceReply = "@HTTP:403"
                let s = await h.event(a)
                h.check("R5 deterministic HTTP 403 (Responses): one attempt, no adapter retry", s == 1 && h.validState?.failure?.kind == .deterministic, "\(s)")
                let r3 = try h.fresh(profile: p45); try h.useResponses()
                h.defaultMaintenanceReply = "@LENGTH:" + UCMHarness.dropOps(for: p45, toBelow: 29_000)
                let s3 = await h.event(r3)
                h.check("R3 Responses incomplete reply rejected; profile untouched", s3 == 3 && h.profile == p45, "\(s3)")
                // A successful Responses run end to end.
                let ok = try h.fresh(profile: p45); try h.useResponses()
                h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
                h.check("Responses maintenance run succeeds with one send", await h.event(ok) == 1 && h.profile.count <= 30_000)
                let body = h.maintenanceRequests.last.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
                h.check("Responses maintenance request: archive layout, no tools, no output cap",
                        body.contains("archive-memory worker") && !body.contains("\"tools\"") && !body.contains("max_output_tokens"))
            }
        }
        try h.useChat()

        // Unit: SendBudget / refresher.
        let budget = SendBudget(limit: 2)
        try budget.consume(); try budget.consume()
        var threw = false
        do { try budget.consume() } catch is SendBudgetExhausted { threw = true }
        h.check("E5k SendBudget throws on the third consume and counts exactly", threw && budget.consumed == 2 && budget.remaining == 0)
        let auth = SendBudget(limit: 0, exhausted: { AuthBudgetExhausted(limit: $0) })
        var authThrew = false
        do { try auth.requireCapacity() } catch is AuthBudgetExhausted { authThrew = true }
        h.check("E5k exhausted auth budget throws AuthBudgetExhausted (not a login error)", authThrew)
    }
}
