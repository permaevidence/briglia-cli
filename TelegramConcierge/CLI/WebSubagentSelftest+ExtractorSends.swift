import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Group 21, round 5 (2026-09-29): spend tracking at each ACTUAL HTTP send of
// an OpenRouter extractor request. (R1) A pause opened while a request is
// outstanding, or during its transport backoff, stops the transport retry.
// (R2) A connection that fails after the request may have reached the host
// becomes an unknown charge under its own charge id before the retry; a
// failure that demonstrably sent nothing does not. (R3) An unknown charge
// covers every day from its send through its abandonment or restart
// recovery, across month and year boundaries.
// Kept apart from runExtractorDeadlineGroup (Linux CI frontend memory).
extension WebSubagentSelftest {
    struct ExtractorSendRowsContext {
        let check: (String, Bool, String) -> Void
        let serverD: WebFixtureServer
        let queue: ResponseScripts
        /// Run one extraction under the given main slots; returns the
        /// extractor stages sent and the spend gate's pause afterwards.
        let extractWith: ([String: String?], String) async -> ([String], String?)
        let plain: [String: String?]
        let capped: [String: String?]
        let incidents: () -> [SpendIncident]
        let inFlight: () -> [ToolChargeLedger.InFlightRequest]
        let faults: (Set<String>) -> Void
    }

    @Sendable static func extractorStage(_ request: WebFixtureServer.Request) -> String? {
        let t = String(decoding: request.body, as: UTF8.self)
        if t.contains("Select the parts of the provided TEXT") { return "excerpts" }
        if t.contains("You extract information from a web page") { return "compression" }
        return nil
    }

    static func runExtractorSendRows(_ c: ExtractorSendRowsContext) async throws {
        try await runExtractorTransportGateRows(c)
        try await runExtractorDisconnectRows(c)
        try runExtractorPeriodRows(c)
    }

    /// R1: the gate is checked at every actual send, transport retries included.
    static func runExtractorTransportGateRows(_ c: ExtractorSendRowsContext) async throws {
        let serverD = c.serverD, queue = c.queue
        WebSearchBackend.extractorDeadlineOverride = 10
        let priorRoute = serverD.route
        defer { serverD.route = priorRoute }

        // CODEX-D (round 4 reproduction, verbatim): a transport retry must
        // recheck a pause opened while the previous request was in flight.
        ToolChargeLedger.resetForTesting()
        queue.reset()
        let retryCount = LookupCounter()
        serverD.route = { request in
            if extractorStage(request) == "excerpts" {
                retryCount.bump()
                if retryCount.value == 1 {
                    try? ToolChargeLedger.openCutRequestUnknown(chargeId: UUID(), generationId: "gen-concurrent-cut", provider: "Reka", stage: "concurrent")
                    return .init(status: 503, body: "{}", headers: ["Retry-After": "0"])
                }
            }
            return priorRoute?(request) ?? .init(status: 500, body: "{}")
        }
        let (_, retryPause) = await c.extractWith(c.capped, "pause during transport retry")
        c.check("CODEX-D transport retries obey a pause opened while previous request was in flight", retryCount.value == 1 && retryPause != nil,
                "excerpts requests=\(retryCount.value), paused=\(retryPause != nil)")

        // 21.21 The pause opens during the transport BACKOFF (after the 503
        // arrived, before the retry): the retry is not sent either.
        ToolChargeLedger.resetForTesting()
        queue.reset()
        let backoffCount = LookupCounter()
        serverD.route = { request in
            if extractorStage(request) == "excerpts" {
                backoffCount.bump()
                if backoffCount.value == 1 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        try? ToolChargeLedger.openCutRequestUnknown(chargeId: UUID(), generationId: "gen-backoff-cut", provider: "Reka", stage: "concurrent")
                    }
                    return .init(status: 503, body: "{}", headers: ["Retry-After": "1"])
                }
            }
            return priorRoute?(request) ?? .init(status: 500, body: "{}")
        }
        let (_, backoffPause) = await c.extractWith(c.capped, "pause during transport backoff")
        c.check("21.21 R1 a pause opened during the transport backoff (after a complete 503, before the retry) stops the retry: 1 excerpts request, gate paused",
                backoffCount.value == 1 && backoffPause != nil, "excerpts requests=\(backoffCount.value), paused=\(backoffPause != nil)")

        // 21.22 Control, no cap: a complete 503 then success retries as
        // before; a complete error response is not an unknown charge.
        ToolChargeLedger.resetForTesting()
        queue.reset()
        let plainCount = LookupCounter()
        serverD.route = { request in
            if extractorStage(request) == "excerpts" {
                plainCount.bump()
                if plainCount.value == 1 { return .init(status: 503, body: "{}", headers: ["Retry-After": "0"]) }
            }
            return priorRoute?(request) ?? .init(status: 500, body: "{}")
        }
        let (_, plainPause) = await c.extractWith(c.plain, "transport retry without cap")
        c.check("21.22 R1 control: without a cap a 503 is retried (2 excerpts requests), leaves no unknown charge and no in-flight record",
                plainCount.value == 2 && plainPause == nil && c.incidents().isEmpty && c.inFlight().isEmpty,
                "excerpts requests=\(plainCount.value) incidents=\(c.incidents().count) inFlight=\(c.inFlight().count)")
    }

    /// R2: a transport failure after the request may have reached the host.
    static func runExtractorDisconnectRows(_ c: ExtractorSendRowsContext) async throws {
        let queue = c.queue
        WebSearchBackend.extractorDeadlineOverride = 10

        // CODEX-F (round 4 reproduction, verbatim): the provider started its
        // response, then the connection drops.
        ToolChargeLedger.resetForTesting()
        queue.reset()
        queue.push("excerpts", .init(body: "{", headers: ["X-Generation-Id": "gen-codex-disconnected", "X-Provider-Name": "Reka"], disconnectAfterHeaders: true))
        let (disconnectedStages, disconnectedPause) = await c.extractWith(c.capped, "connection cut after response headers")
        let disconnectedSnapshot = ToolChargeLedger.snapshot()
        c.check("CODEX-F connection loss after a response starts preserves an unknown charge and gates retries", !disconnectedSnapshot.isComplete && disconnectedPause != nil,
                "stages=\(disconnectedStages), complete=\(disconnectedSnapshot.isComplete), incidents=\(c.incidents().count), inFlight=\(c.inFlight().count)")
        let dropped = c.incidents().first { $0.generationId == "gen-codex-disconnected" }
        c.check("21.23 R2 under a cap the dropped send is an open unknown (its generation id, \"connection failed\") and its transport retry is not sent (1 excerpts request, no in-flight record left)",
                disconnectedStages.filter { $0 == "excerpts" }.count == 1 && dropped?.state == .open
                && dropped?.detail?.contains("connection failed before its reply completed") == true && c.inFlight().isEmpty,
                "stages=\(disconnectedStages) incident=\(String(describing: dropped?.detail))")

        // 21.24 No cap: the drop is still an unknown charge, the retry is
        // sent under its OWN charge id and completes (its record ends).
        ToolChargeLedger.resetForTesting()
        queue.reset()
        queue.push("excerpts", .init(body: "{", headers: ["X-Generation-Id": "gen-disc-nocap", "X-Provider-Name": "Reka"], disconnectAfterHeaders: true))
        let (noCapStages, noCapPause) = await c.extractWith(c.plain, "connection cut without cap")
        let noCapIncidents = c.incidents()
        // Darwin reports the cut as URLError.networkConnectionLost, which the
        // (unchanged) transport retry classification retries. Linux
        // FoundationNetworking reports curl's partial transfer ("transfer
        // closed with N bytes remaining") under a code that classification
        // has never retried, so there is no second send there; the accounting
        // assertions below are the same on both platforms.
        #if os(Linux)
        let expectedNoCapSends = 1
        #else
        let expectedNoCapSends = 2
        #endif
        c.check("21.24 R2 without a cap: the dropped send is retried where the platform reports a lost connection (2 excerpts sends on Darwin, 1 on Linux), exactly one unknown charge (the dropped send), no in-flight record left, totals incomplete",
                noCapStages.filter { $0 == "excerpts" }.count == expectedNoCapSends && noCapPause == nil
                && noCapIncidents.count == 1 && noCapIncidents.first?.generationId == "gen-disc-nocap"
                && c.inFlight().isEmpty && !ToolChargeLedger.snapshot().isComplete,
                "stages=\(noCapStages) incidents=\(noCapIncidents.map(\.id)) inFlight=\(c.inFlight().count)")

        // 21.25 A failure that demonstrably sent nothing (connection refused)
        // ends the record without an unknown charge.
        ToolChargeLedger.resetForTesting()
        let refusedDeadline = ExtractorDeadline(seconds: 5, spendStage: "unsent-probe")
        let refusedError: Error? = await withMainSlots(c.plain) {
            do { _ = try await refusedDeadline.fetch(URLRequest(url: URL(string: "http://127.0.0.1:1/unsent")!)); return nil }
            catch { return error }
        }
        c.check("21.25 R2 a send refused before anything reached a host (connection refused) leaves no unknown charge and no in-flight record; ambiguous transport errors are not \"unsent\"",
                (refusedError as? URLError).map { ExtractorDeadline.demonstrablyUnsent($0) } == true
                && c.incidents().isEmpty && c.inFlight().isEmpty
                && !ExtractorDeadline.demonstrablyUnsent(URLError(.networkConnectionLost))
                && !ExtractorDeadline.demonstrablyUnsent(URLError(.timedOut))
                && ExtractorDeadline.demonstrablyUnsent(URLError(.cannotFindHost)),
                "error=\(String(describing: refusedError)) incidents=\(c.incidents().count) inFlight=\(c.inFlight().count)")
    }

    /// R3: the unknown covers send → abandonment/recovery.
    static func runExtractorPeriodRows(_ c: ExtractorSendRowsContext) throws {
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: Date())!.start
        let yearStart = calendar.dateInterval(of: .year, for: Date())!.start

        // CODEX-E (round 4 reproduction, verbatim): restart recovery of a call
        // spanning a month boundary.
        ToolChargeLedger.resetForTesting()
        let startedPreviousMonth = monthStart.addingTimeInterval(-30)
        try ToolChargeLedger.beginInFlight(chargeId: UUID(), stage: "cross-month", at: startedPreviousMonth)
        ToolChargeLedger.simulateRestartForTesting()
        let crossMonth = ToolChargeLedger.snapshot(referenceDate: monthStart.addingTimeInterval(30))
        c.check("CODEX-E restarted in-flight request remains unknown in the month it may have completed", !crossMonth.isComplete,
                "complete=\(crossMonth.isComplete), incidents=\(crossMonth.incidents.count), storedPeriods=\(c.incidents().map(\.periods))")

        // 21.26 Same across a year boundary.
        ToolChargeLedger.resetForTesting()
        try ToolChargeLedger.beginInFlight(chargeId: UUID(), stage: "cross-year", at: yearStart.addingTimeInterval(-30))
        ToolChargeLedger.simulateRestartForTesting()
        let crossYear = ToolChargeLedger.snapshot(referenceDate: yearStart.addingTimeInterval(30))
        let yearIncident = c.incidents().first
        c.check("21.26 R3 a request sent just before a new year and recovered after a restart stays unknown in the new year (incident covers send day through recovery)",
                !crossYear.isComplete && yearIncident?.periods == [ToolChargeLedger.dayKey(yearStart.addingTimeInterval(-30))]
                && yearIncident?.throughDay == ToolChargeLedger.dayKey(Date()),
                "complete=\(crossYear.isComplete) periods=\(String(describing: yearIncident?.periods)) through=\(String(describing: yearIncident?.throughDay))")

        // 21.27 Incident save failing at recovery: the synthesized unsaved
        // unknown carries the same interval.
        ToolChargeLedger.resetForTesting()
        try ToolChargeLedger.beginInFlight(chargeId: UUID(), stage: "cross-month-unsaved", at: startedPreviousMonth)
        ToolChargeLedger.simulateRestartForTesting()
        c.faults(["incident-open"])
        let unsavedSnap = ToolChargeLedger.snapshot(referenceDate: monthStart.addingTimeInterval(30))
        c.faults([])
        let unsaved = unsavedSnap.incidents.first { $0.detail?.contains("not saved yet") == true }
        c.check("21.27 R3 with the incident save failing, the unsaved unknown from a restart still counts in the new month (range kept on the synthesized incident)",
                !unsavedSnap.isComplete && unsaved?.throughDay != nil && c.incidents().isEmpty,
                "complete=\(unsavedSnap.isComplete) unsaved=\(String(describing: unsaved?.periods))…\(String(describing: unsaved?.throughDay))")

        // 21.28 A live abandonment (cut/cancel/drop) whose send began before
        // the boundary covers both months.
        ToolChargeLedger.resetForTesting()
        let liveId = UUID()
        let liveStart = monthStart.addingTimeInterval(-30), liveEnd = monthStart.addingTimeInterval(30)
        try ToolChargeLedger.beginInFlight(chargeId: liveId, stage: "live-cross", at: liveStart)
        ToolChargeLedger.abandonInFlight(chargeId: liveId, generationId: "gen-live-cross", provider: "Reka", stage: "live-cross",
                                         reason: "cut at its deadline", startedAt: liveStart, at: liveEnd)
        let liveIncident = c.incidents().first { $0.generationId == "gen-live-cross" }
        let before = ToolChargeLedger.snapshot(referenceDate: monthStart.addingTimeInterval(-60))
        let after = ToolChargeLedger.snapshot(referenceDate: liveEnd)
        c.check("21.28 R3 a request abandoned after a month boundary it was sent before is unknown in BOTH months (periods from the send day through the abandonment day)",
                liveIncident?.periods == [ToolChargeLedger.dayKey(liveStart)] && liveIncident?.throughDay == ToolChargeLedger.dayKey(liveEnd)
                && !before.isComplete && !after.isComplete,
                "periods=\(String(describing: liveIncident?.periods)) through=\(String(describing: liveIncident?.throughDay)) before=\(before.isComplete) after=\(after.isComplete)")
    }
}
