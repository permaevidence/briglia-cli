import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
import OpenCombineDispatch
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
extension ConversationManager {

    func stopActiveExecution(notify address: ChannelAddress? = nil) async {
        // 1. Cut off and persist FIRST (mid-turn early wake §3.9.1): the
        //    stop marker names every unsettled agent-started item, the
        //    stopped turn's trigger and every queued pre-stop user message,
        //    before anything is cancelled. Repeated /stop appends an entry.
        //    A failed write never refuses the stop.
        //
        //    The registry cutoffs are awaits; main-actor work can interleave
        //    at them (an idle drain may start a turn, the running turn may
        //    end). So the cutoff repeats until the run it closed admission
        //    for is still the active run afterwards — the marker's trigger
        //    and the cancelled task then describe the SAME run (Codex 1a R3).
        //    Subagents: one actor step returns running runs AND finished
        //    runs whose completion is still queued.
        var closedRun = activeRunId
        var items = await BackgroundProcessRegistry.shared.stopCutoff(turnRunId: closedRun)
        // Subagents (1b): the same cutoff closes launch admission for the
        // stopped turn (a racing detach commit or background launch is
        // refused) and names recorded runs by their durable job ids.
        var subagentCut = await SubagentBackgroundRegistry.shared.stopCutoff(turnRunId: closedRun)
        var stoppedSubagents = subagentCut.handles
        var stoppedSubagentJobs = subagentCut.jobIds
        if let interleave = Self.stopCutoffInterleaveForTesting { await interleave() }
        var passes = 0
        while activeRunId != closedRun && passes < 8 {
            passes += 1
            closedRun = activeRunId
            items = await BackgroundProcessRegistry.shared.stopCutoff(turnRunId: closedRun)
            subagentCut = await SubagentBackgroundRegistry.shared.stopCutoff(turnRunId: closedRun)
            stoppedSubagents.formUnion(subagentCut.handles)
            stoppedSubagentJobs.formUnion(subagentCut.jobIds)
        }
        let wasRunning = activeRunId != nil
        // From here to the turn cancellation below there is NO suspension
        // point: the running turn cannot drain a held message into its next
        // request between the snapshot and the cancel.
        //
        // /stop visibility (§3.1): capture the running task and its run —
        // pure reads, nothing awaited, nothing changed.
        let stoppedTask = wasRunning ? activeProcessingTask : nil
        let stoppedRun = wasRunning ? activeRunId : nil
        let stoppedTrigger = wasRunning ? activeTurnTriggerMessage?.id : nil
        var affected = items.jobUUIDs.union(stoppedSubagentJobs)
        if let records = try? DetachedJobStore.load() {
            affected.formUnion(records.filter { $0.completion == .owed }.map(\.jobId))
        }
        // While history is unreadable the held state includes the durable
        // queue of earlier processes (synchronous read, no suspension).
        var heldQueueUnreadable = false
        if historyLoadFailure != nil {
            if !hydrateHeldQueueFromDisk() { heldQueueUnreadable = true }
        } else if heldQueueFileProblem != nil {
            // Healthy history, unreadable held-message file (1a round 6):
            // every message in it predates this /stop — conservative hold.
            heldQueueUnreadable = true
        }
        let held = pendingMidTurnMessages.filter { $0.kind == .userText }.map(\.id)
        var trigger = wasRunning ? activeTurnTriggerMessage?.id : nil
        // No run: an interrupted turn preserved for resume (e.g. while
        // history is unreadable) is stopped too. Its marker is read, not
        // the history; an unreadable marker gets a conservative stop.
        var stoppedPendingTurn = false
        var turnMarkerUnreadable = false
        if !wasRunning {
            switch readActiveTurnMarkerState() {
            case .absent: break
            case .readable(let marker): trigger = marker.triggerMessageId; stoppedPendingTurn = true
            case .unreadable: turnMarkerUnreadable = true; stoppedPendingTurn = true
            }
        }
        var markerFailure: String? = nil
        if !affected.isEmpty || !held.isEmpty || trigger != nil || heldQueueUnreadable || turnMarkerUnreadable {
            let entry = StopEntry(stopId: UUID(), at: Date(), stoppedTurnTriggerId: trigger,
                                  heldQueueMessageIds: held, heldNoteMessageId: UUID(),
                                  affectedJobIds: affected.sorted { $0.uuidString < $1.uuidString },
                                  affectedWatchMatchIds: items.watchMatchIds,
                                  stoppedUnreadableTurnMarker: turnMarkerUnreadable ? true : nil,
                                  heldUnreadableQueue: heldQueueUnreadable ? true : nil)
            stopEntries.append(entry)
            do { try StopMarkerStore.append(entry) } catch {
                markerFailure = error.localizedDescription
                showMaintenanceNotice("Could not save the /stop marker: \(error.localizedDescription)")
            }
            // 2. Per-item disposition in each crash record (an optimisation:
            //    the marker's sets are authoritative even if this fails).
            do {
                try DetachedJobStore.mutate("stop") { records in
                    for i in records.indices where affected.contains(records[i].jobId) && records[i].stopId == nil {
                        records[i].stopId = entry.stopId
                    }
                }
            } catch {
                print("[ConversationManager] /stop could not stamp crash records: \(error.localizedDescription)")
            }
        }
        // /stop visibility: a repeated /stop for a request that is still
        // finishing is matched by its run id (envelope checkpoint owner:
        // the run is still active) or by its trigger (the interrupted-turn
        // marker branch, F2). Otherwise a newly captured task gets ONE entry
        // and ONE watcher. Synchronous; no suspension.
        var repeatRun: UUID? = nil
        if let run = stoppedRun, stoppedRunsFinishing[run]?.ended == nil, stoppedRunsFinishing[run] != nil {
            repeatRun = run
        } else if stoppedPendingTurn, let trigger,
                  let match = stoppedRunsFinishing.values.first(where: { $0.triggerMessageId == trigger && $0.ended == nil }) {
            repeatRun = match.runId
        }
        if repeatRun == nil, let run = stoppedRun, let task = stoppedTask {
            registerStoppedRun(run, task: task, triggerMessageId: stoppedTrigger)
        }
        let observedRun = repeatRun ?? (stoppedTask != nil ? stoppedRun : nil)
        // A repeat for an ALREADY-ANNOUNCED run reserves its place in that
        // run's ordered notices now, before any await (Codex impl review
        // R1): if the run ends during the grace wait below, its completion
        // queues BEHIND this reply instead of the reply escaping through
        // ordinary delivery. Synchronous; no suspension.
        let repeatSlot = repeatRun.flatMap { reserveRepeatSlot(run: $0, address: address) }

        // Stopped items never start work until settled — across turns (a
        // new user message never clears this) and restarts (the marker).
        stoppedJobIds.formUnion(affected)
        stoppedSubagentHandles.formUnion(stoppedSubagents)

        // 3–4. Cancel: the turn, every background subagent, EVERY
        //    main-owned bash job from any turn including long-lived ones
        //    (owner decision B1) and their watches, and registered processes.
        activeProcessingTask?.cancel()
        let hasCheckpointOwner = activeRunId.flatMap { activeTurnCheckpoints[$0]?.isEnvelope } == true
        if !hasCheckpointOwner { activeProcessingTask = nil; activeRunId = nil }
        currentTurnLogIsActive = false
        turnActivity = nil
        await TurnWakeCenter.shared.disarm()

        // (In-flight archiving / user-context extraction are deliberately NOT
        // cancelled here; they run on detached tasks that continue to
        // completion so we don't lose summaries or fact extraction.)
        // BGPRUNE{ A-STOP1
        if backgroundPruneEngaged {
            backgroundPruneStopNote = backgroundPruneStopPass()
        }
        // }BGPRUNE
        let cancelledSubagents = await SubagentBackgroundRegistry.shared.cancelAllReturningIds()
        stoppedSubagentHandles.formUnion(cancelledSubagents)
        let killedBackgroundSubagents = cancelledSubagents.count
        let stoppedBash = await BackgroundProcessRegistry.shared.stopAllMainOwned()

        await toolExecutor.cancelAllRunningProcesses()
        ToolExecutor.clearPendingToolOutputs()

        // 5. Confirm up to 3 s (actual exits, not just signals sent) — and,
        //    as an independent predicate, observe for at most 2.5 s whether
        //    the captured turn task ended (§3.3). The turn side only reads a
        //    flag set by the run's watcher; it never awaits the task.
        let unconfirmed = await Self.observeStopGrace(
            bashJobs: Set(stoppedBash.map(\.jobUUID)),
            isSettled: { job in await BackgroundProcessRegistry.shared.settlementInfo(uuid: job).settled },
            turnEnded: observedRun.map { run in { [weak self] in self?.stoppedRunHasEnded(run) ?? true } }
        )

        // 6. Reply: "stopped" only for confirmed exits. Decided ONCE, here,
        //    synchronously: either the captured run ended (today's text) or
        //    it is announced as still finishing (§2 R1/R4).
        let stillFinishing = observedRun.flatMap { stoppedRunHasEnded($0) ? nil : $0 }
        var text: String
        if let run = stillFinishing {
            let lead = repeatRun != nil ? "⛔ Already stopping." : "⛔ Stop requested."
            text = "\(lead) The request is still finishing: \(describeStillFinishing(runId: run)). I'll notify you when it ends."
        } else if repeatRun != nil {
            // The repeat entered while the stopped request was still
            // finishing and it ended during this command's wait: never the
            // fresh-stop or interrupted-request wording. With a reserved slot
            // the run's completion notice follows this reply on the same
            // surface; otherwise say it here.
            text = repeatSlot != nil ? Self.repeatEndedWithCompletionLead : Self.repeatEndedLead
        } else {
            text = wasRunning ? "⛔ I stopped the current work."
                : stoppedPendingTurn ? "⛔ I stopped the interrupted request; it won't resume."
                : (stoppedBash.isEmpty ? "I'm not doing anything at the moment." : "⛔ Stopped.")
        }
        // BGPRUNE{ A-STOP2
        if backgroundPruneEngaged {
            if let note = backgroundPruneStopNote, let line = backgroundPruneStopLine(note) {
                text += " " + line
            }
            backgroundPruneStopNote = nil
        }
        // }BGPRUNE
        if killedBackgroundSubagents > 0 {
            text += " Also stopped \(killedBackgroundSubagents) background assistant\(killedBackgroundSubagents == 1 ? "" : "s")."
        }
        let confirmed = stoppedBash.filter { !unconfirmed.contains($0.jobUUID) }
        if !confirmed.isEmpty {
            let list = confirmed.prefix(5).map { job in
                let command = job.command.count > 40 ? String(job.command.prefix(40)) + "…" : job.command
                return "\(job.handle) (\(command), running \(Self.formatShortDuration(job.runningForSeconds)))"
            }
            text += " Stopped \(confirmed.count) background command\(confirmed.count == 1 ? "" : "s"), including long-running ones: \(list.joined(separator: ", "))\(confirmed.count > 5 ? ", …" : "")."
        }
        if !unconfirmed.isEmpty {
            text += " Cancellation requested for \(unconfirmed.count) more command\(unconfirmed.count == 1 ? "" : "s"); still shutting down."
        }
        if !held.isEmpty {
            text += held.count == 1
                ? " I kept the message you sent before /stop for your next request."
                : " I kept the \(held.count) messages you sent before /stop for your next request."
        }
        if heldQueueUnreadable {
            text += " I couldn't read the saved held messages; they'll be kept without being answered."
        }
        if markerFailure != nil {
            text += " (I couldn't save the stop to disk — if Briglia restarts in the next moments it may resume the stopped request.)"
        }
        if let run = stillFinishing {
            // Ordered delivery (§4): the reply heads (or joins) the run's
            // notice series; the stop path does not wait for its retries.
            deliverStillFinishingReply(text, run: run, address: address, slot: repeatSlot)
            Self.afterStopDecisionForTesting?(self, run)
        } else if let repeatSlot, fillRepeatSlot(repeatSlot, text: text) {
            // Delivered in its reserved place, ahead of the completion.
        } else {
            // The reserved place vanished (series invalidated or gave up):
            // no completion follows here, so the reply says it ended.
            if repeatRun != nil, repeatSlot != nil, text.hasPrefix(Self.repeatEndedWithCompletionLead) {
                text = Self.repeatEndedLead + text.dropFirst(Self.repeatEndedWithCompletionLead.count)
            }
            try? await sendText(text, to: address)
            // F1: a local stop's reply is visible on the terminal and app.
            if address?.kind == .app, Self.commandCapture?.isOpen != true {
                stopNoticeEvents.send(text)
            }
        }

        statusMessage = wasRunning ? "Cancelled" : "Listening... (Last check: \(formattedTime()))"
    }

    nonisolated static func monotonicSeconds() -> TimeInterval {
        TimeInterval(StageMarkers.monotonicNanos()) / 1_000_000_000
    }

    /// The /stop confirmation window (§3.3): two INDEPENDENT predicates.
    /// Bash exits are confirmed for up to 3 s exactly as before; the
    /// captured turn is observed for at most 2.5 s, only when there is one,
    /// by reading a flag (never awaiting the task). Ends as soon as both
    /// sides are done. Returns the Bash jobs still unconfirmed.
    static func observeStopGrace(
        bashJobs: Set<UUID>,
        isSettled: (UUID) async -> Bool,
        turnEnded: (() -> Bool)?,
        now: () -> TimeInterval = monotonicSeconds,
        pause: () async -> Void = { try? await Task.sleep(nanoseconds: 50_000_000) }
    ) async -> Set<UUID> {
        var unconfirmed = bashJobs
        let start = now()
        let bashDeadline = start + stopBashConfirmSeconds
        let turnDeadline = start + stopTurnObserveSeconds
        while true {
            let bashOpen = !unconfirmed.isEmpty && now() < bashDeadline
            let turnOpen = turnEnded.map { !$0() } == true && now() < turnDeadline
            if !bashOpen && !turnOpen { break }
            if bashOpen {
                for job in unconfirmed where await isSettled(job) {
                    unconfirmed.remove(job)
                }
            }
            if !unconfirmed.isEmpty || turnOpen { await pause() }
        }
        return unconfirmed
    }

    /// One entry and one watcher per captured run (§3.1). Only the watcher
    /// sets `ended`; nothing on the stop path awaits the task.
    private func registerStoppedRun(_ run: UUID, task: Task<Void, Never>, triggerMessageId: UUID?) {
        guard stoppedRunsFinishing[run] == nil, stoppedRunWatchers[run] == nil else { return }
        stoppedRunsFinishing[run] = StoppedRunFinishing(runId: run, triggerMessageId: triggerMessageId, stoppedAt: Date())
        stoppedRunWatchers[run] = Task { @MainActor [weak self] in
            await task.value
            self?.stoppedRunEnded(run)
        }
    }

    private func stoppedRunHasEnded(_ run: UUID) -> Bool {
        guard let entry = stoppedRunsFinishing[run] else { return true }
        return entry.ended != nil
    }

    /// The watcher: the captured turn task has ended. Status surfaces drop
    /// the run at once, whatever happens to delivery; an announced run gets
    /// its one completion notice, appended BEHIND every earlier notice of
    /// each of its series (terminal: nothing may follow it).
    func stoppedRunEnded(_ run: UUID) {
        stoppedRunWatchers[run] = nil
        guard var entry = stoppedRunsFinishing[run] else { return }
        entry.ended = Date()
        if entry.announced && !entry.completionQueued {
            entry.completionQueued = true
            let after = Self.stopDuration(Int(Date().timeIntervalSince(entry.stoppedAt)))
            let text = "✅ The stopped request has ended. (it ended \(after) after /stop)"
            for id in entry.series.values {
                noticeSeriesRegistry[id]?.append(text, terminal: true)
            }
        }
        gaveUpNoticeSeries.subtract(entry.series.values)
        stoppedRunsFinishing.removeValue(forKey: run)
    }

    /// "2m 10s"-style durations for the visibility texts.
    static func stopDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    /// What a stopped request is still doing — ONLY from its own run-keyed
    /// phase record (§3.2). Process-wide maintenance is never attributed.
    func describeStillFinishing(runId: UUID, now: Date = Date()) -> String {
        func running(_ since: Date) -> String { "(running \(Self.stopDuration(Int(now.timeIntervalSince(since)))))" }
        switch runPhases[runId] {
        // BGPRUNE{ A-ARM
        case .pruneWait(let since):
            return "waiting for a background prune to finish \(running(since))"
        // }BGPRUNE
        case .archiveWait(let since):
            return "memory archiving continues \(running(since))"
        case .tools(let callIds, let labels, let since):
            let shown = labels.prefix(3).joined(separator: ", ") + (labels.count > 3 ? " (+\(labels.count - 3) more)" : "")
            if let refined = refinedToolStage(callIds: callIds) {
                return "\(shown) — \(refined) \(running(since))"
            }
            return "\(shown) \(running(since))"
        case .model(let since):
            return "last seen waiting for the model's reply \(running(since))"
        case nil:
            return "finishing the stopped request"
        }
    }

    /// Refines a tool batch label with open stage markers that are
    /// POSITIVELY tied to that batch: entries whose call id belongs to it,
    /// with exactly one open `tool.execute` per call id. Any ambiguity, no
    /// open stage, or markers disabled → nil (the batch label alone).
    private func refinedToolStage(callIds: [String]) -> String? {
        let stages = (Self.openStagesProviderForTesting ?? StageMarkers.openStages)()
        guard !stages.isEmpty else { return nil }
        var parts: [String] = []
        for id in callIds {
            let mine = stages.filter { $0.callId == id }
            let executions = mine.filter { $0.stage == "tool.execute" }.count
            if executions > 1 { return nil }   // ambiguous: maybe another run's call
            guard executions == 1 else { continue }
            if let known = mine.sorted(by: { $0.elapsedMs < $1.elapsedMs })
                .lazy.compactMap({ Self.stageDescription($0.stage) }).first,
               !parts.contains(known) {
                parts.append(known)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func stageDescription(_ stage: String) -> String? {
        if stage.hasPrefix("git.") { return "saving a git checkpoint" }
        if stage == "fs.diff" { return "computing a file diff" }
        if stage.hasPrefix("fs.write") { return "writing a file" }
        if stage == "lsp.diagnostics" { return "checking diagnostics" }
        return nil
    }

    /// Delivers a "still finishing" reply (§4): the captured command window
    /// keeps the reply in its lines (as today) and holds later items until
    /// the caller handed the result to its client; a local stop emits on the
    /// undeduplicated local stream; a wire stop heads (or joins) the run's
    /// ordered series for that chat. Synchronous with the decision.
    private func deliverStillFinishingReply(_ text: String, run: UUID, address: ChannelAddress?, slot: RepeatSlot? = nil) {
        guard stoppedRunsFinishing[run] != nil else { return }
        stoppedRunsFinishing[run]?.announced = true
        if let slot, fillRepeatSlot(slot, text: text) { return }
        if let capture = Self.commandCapture, capture.isOpen, address == nil || address?.kind == .app {
            _ = capture.append(text)
            if let series = runNoticeSeries(run, target: .local, awaitingCapture: true) {
                capture.onDelivered { [weak series] in series?.releaseCapture() }
            }
            return
        }
        if address?.kind == .app {
            runNoticeSeries(run, target: .local, awaitingCapture: false)?.append(text)
            return
        }
        guard let destination = address ?? replyAddress, destination.kind != .app else { return }
        runNoticeSeries(run, target: .wire(destination), awaitingCapture: false)?.append(text)
    }

    /// Reserves, synchronously and before the grace wait, where a repeated
    /// /stop's reply goes in its run's ordered notices (Codex impl review
    /// R1). Only for a run whose "still finishing" reply was already issued
    /// and whose completion is not queued yet; a first stop keeps today's
    /// behaviour. nil when no place can be reserved (e.g. a series that gave
    /// up — no new retry lifetime, D2).
    private func reserveRepeatSlot(run: UUID, address: ChannelAddress?) -> RepeatSlot? {
        guard let entry = stoppedRunsFinishing[run], entry.announced,
              entry.ended == nil, !entry.completionQueued else { return nil }
        if let capture = Self.commandCapture, capture.isOpen, address == nil || address?.kind == .app {
            guard let series = runNoticeSeries(run, target: .local, awaitingCapture: true) else { return nil }
            capture.onDelivered { [weak series] in series?.releaseCapture() }
            return .capture
        }
        let target: NoticeSeries.Target
        if address?.kind == .app {
            target = .local
        } else {
            guard let destination = address ?? replyAddress, destination.kind != .app else { return nil }
            target = .wire(destination)
        }
        guard let series = runNoticeSeries(run, target: target, awaitingCapture: false),
              let reservation = series.reserve() else { return nil }
        return .series(series, reservation)
    }

    /// Puts the decided reply into its reserved place; false when the place
    /// is gone (series invalidated or given up meanwhile) — the caller then
    /// uses the unreserved path.
    private func fillRepeatSlot(_ slot: RepeatSlot, text: String) -> Bool {
        switch slot {
        case .capture:
            guard let capture = Self.commandCapture, capture.isOpen else { return false }
            return capture.append(text)
        case .series(let series, let reservation):
            return series.resolve(reservation, text: text)
        }
    }

    /// The run's series for `target`: the open one (repeat replies join it),
    /// or a new one when there is none or the earlier one was invalidated by
    /// intentional clearing. A series that GAVE UP is never replaced: no new
    /// retry lifetime for the same failed delivery (Codex round 3).
    private func runNoticeSeries(_ run: UUID, target: NoticeSeries.Target, awaitingCapture: Bool) -> NoticeSeries? {
        if let id = stoppedRunsFinishing[run]?.series[target] {
            if gaveUpNoticeSeries.contains(id) { return nil }
            if let existing = noticeSeriesRegistry[id], !existing.isClosed, !existing.terminalQueued {
                if awaitingCapture { existing.holdForCapture() }
                return existing
            }
        }
        guard let series = makeNoticeSeries(target: target, awaitingCapture: awaitingCapture) else { return nil }
        stoppedRunsFinishing[run]?.series[target] = series.id
        return series
    }

    /// A new ordered series. Wire: nil when no channel is registered for
    /// the address (nothing is sent). The channel generation is captured
    /// now and re-checked before every attempt — and, for Telegram, again
    /// inside the actor at credential capture.
    func makeNoticeSeries(target: NoticeSeries.Target, awaitingCapture: Bool) -> NoticeSeries? {
        let series: NoticeSeries
        switch target {
        case .local:
            series = NoticeSeries(localEmit: { [weak self] text in self?.stopNoticeEvents.send(text) },
                                  awaitingCapture: awaitingCapture)
        case .wire(let address):
            guard channels[address.kind] != nil else { return nil }
            let kind = address.kind
            let generation = NoticeChannelGenerations.current(kind)
            series = NoticeSeries(
                wire: address, generation: generation,
                attempt: { [weak self] text in
                    guard let self, let channel = self.channels[kind] else { throw NoticeTransportError.credentialsChanged }
                    if let telegram = channel as? TelegramBotService {
                        try await telegram.sendNoticeText(chatId: address.chatId, text: text, expectedGeneration: generation)
                    } else {
                        try await channel.sendText(chatId: address.chatId, text: text)
                    }
                },
                isCurrent: { [weak self] in
                    NoticeChannelGenerations.current(kind) == generation && self?.channels[kind] != nil
                },
                afterDelivery: { [weak self] in await self?.flushParkedOutbound() }
            )
        }
        series.log = { print("[ConversationManager] \($0)") }
        series.onFinished = { [weak self] finished in
            self?.noticeSeriesRegistry.removeValue(forKey: finished.id)
            if finished.gaveUp { self?.gaveUpNoticeSeries.insert(finished.id) }
        }
        noticeSeriesRegistry[series.id] = series
        return series
    }

    /// Intentional clearing: pending items and waiting retries dropped,
    /// nothing re-sent. Status observation continues.
    func invalidateNoticeSeries(kind: ChannelKind) {
        for series in Array(noticeSeriesRegistry.values) {
            if case .wire(let address) = series.target, address.kind == kind { series.invalidate() }
        }
    }

    private func invalidateAllNoticeSeries() {
        for series in Array(noticeSeriesRegistry.values) { series.invalidate() }
    }

    /// /deleteuserdata: pending visibility notices are dropped with the rest
    /// of the outbound state (nothing re-sent); every channel generation
    /// moves on.
    func retireVisibilityNoticesForWipe() {
        for kind in ChannelKind.allCases { NoticeChannelGenerations.bump(kind) }
        invalidateAllNoticeSeries()
        durabilityStallSeries = nil
        durabilityStallPauseOwed = false
    }

    /// /status lines (§4.3, R3): each stopped-but-finishing request, then —
    /// separately and only alongside them — process-wide maintenance, never
    /// attributed to a stopped request.
    func stoppedRunStatusLines(now: Date = Date()) -> [String] {
        let finishing = stoppedRunsFinishing.values.filter { $0.ended == nil }.sorted { $0.stoppedAt < $1.stoppedAt }
        var lines = finishing.map {
            "⛔ Stopped \(Self.stopDuration(Int(now.timeIntervalSince($0.stoppedAt)))) ago, still finishing: \(describeStillFinishing(runId: $0.runId, now: now))"
        }
        if !lines.isEmpty, !maintenanceActivities.isEmpty {
            let parts = maintenanceActivities.map {
                "\(Self.maintenanceLabel($0.kind)) (\(Self.stopDuration(Int(now.timeIntervalSince($0.startedAt)))))"
            }
            lines.append("Also running: " + parts.joined(separator: ", "))
        }
        return lines
    }

    /// The app socket's composed activity suffix: present whether or not a
    /// newer turn is active; no stage label while privacy mode is on.
    func stoppedRunActivitySuffix(privacy: Bool, now: Date = Date()) -> String? {
        guard let oldest = stoppedRunsFinishing.values.filter({ $0.ended == nil }).min(by: { $0.stoppedAt < $1.stoppedAt }) else { return nil }
        let age = Self.stopDuration(Int(now.timeIntervalSince(oldest.stoppedAt)))
        if privacy { return "stopped request still finishing (\(age))" }
        return "stopped request still finishing: \(describeStillFinishing(runId: oldest.runId, now: now))"
    }

    static func maintenanceLabel(_ kind: MaintenanceActivity.Kind) -> String {
        switch kind {
        case .summarizingHistory: return "memory archiving — summarizing older conversation"
        case .consolidating: return "memory archiving — merging memory chunks"
        case .userContext: return "memory archiving — updating the user profile"
        case .pruning: return "compressing old tool outputs"
        }
    }

    /// Mind import / wipe: drop crash records, the stop marker and the
    /// snapshot settlement evidence of the replaced history (checked), and
    /// every in-memory disposition. The legacy list is recreated from the
    /// snapshots now present.
    func resetEarlyWakeStateForReplacedHistory() throws {
        // Charge evidence is never discarded with the replaced history
        // (§3.6.4 Stage B, belt and braces: Stage A already settled every
        // pending charge): a record still carrying an unrecorded charge (or
        // an unregistered unknown amount) stays, with nothing owed, until
        // the idle retry records it.
        if FileManager.default.fileExists(atPath: DetachedJobStore.fileURL.path),
           let records = try? DetachedJobStore.load(),
           records.contains(where: { !$0.chargeSettled }) {
            try DetachedJobStore.mutate("reset-keep-charges") { records in
                records.removeAll { $0.chargeSettled }
                for i in records.indices {
                    records[i].completion = .notOwed
                    records[i].stopId = nil
                }
            }
            if FileManager.default.fileExists(atPath: StopMarkerStore.fileURL.path) {
                try FileManager.default.removeItem(at: StopMarkerStore.fileURL)
                try PrivateStorage.fsyncDirectory(StopMarkerStore.fileURL.deletingLastPathComponent().path)
            }
            try SettlementEvidence.resetForReplacedHistory()
            stoppedJobIds.removeAll(); stopEntries.removeAll(); stoppedSubagentHandles.removeAll()
            stopIntent = .none; pendingCompletionAcks.removeAll(); pendingSubagentAcks.removeAll(); recoveredWakeTrigger = nil
            midTurnGeneration.removeAll(); roundDeliveryReservations.removeAll(); roundDeliveryRecordRetries.removeAll()
            return
        }
        for url in [DetachedJobStore.fileURL, StopMarkerStore.fileURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try PrivateStorage.fsyncDirectory(url.deletingLastPathComponent().path)
        }
        try SettlementEvidence.resetForReplacedHistory()
        stoppedJobIds.removeAll(); stopEntries.removeAll(); stoppedSubagentHandles.removeAll()
        stopIntent = .none; pendingCompletionAcks.removeAll(); pendingSubagentAcks.removeAll(); recoveredWakeTrigger = nil
        midTurnGeneration.removeAll(); roundDeliveryReservations.removeAll(); roundDeliveryRecordRetries.removeAll()
    }

    // MARK: - Startup: stop intent and job reconciliation (§3.9.3, §3.10.4)

    func loadStopIntent() {
        stopIntent = StopMarkerStore.load()
        switch stopIntent {
        case .none: break
        case .known(let entries):
            stopEntries = entries
            stoppedJobIds.formUnion(stopIntent.stoppedJobIds)
        case .unknown(let reason):
            showMaintenanceNotice("The /stop record could not be read (\(reason)). Nothing recovered will start work until you check it — send a new message to continue.")
        }
    }

    /// Startup stop pass (in startPolling, before queue recovery and turn
    /// resume): held messages still in the queue file reach history followed
    /// by their note (both id-deduplicated) and leave the queue file only
    /// after a checked save; a stopped turn's marker is cleared; records of
    /// affected jobs are stamped. Settled entries retire.
    func applyPersistedStopMarker() {
        guard case .known(let entries) = stopIntent else { return }
        let holdsAny = entries.contains { !$0.heldQueueMessageIds.isEmpty || $0.heldUnreadableQueue == true }
        // Held messages reach history only once it loads (they stay in the
        // queue file meanwhile — no write may replace unreadable history).
        if holdsAny, historyLoadFailure == nil, let data = try? Data(contentsOf: pendingMidTurnFileURL),
           let queued = try? JSONDecoder().decode([Message].self, from: data) {
            let held = queued.filter { m in entries.contains { $0.holds(m) } }
            if !held.isEmpty {
                for message in held where !messages.contains(where: { $0.id == message.id }) { messages.append(message) }
                appendHeldPreStopNotes(for: held)
                if saveConversation() {
                    let remainder = queued.filter { m in !entries.contains { $0.holds(m) } }
                    if remainder.isEmpty { try? FileManager.default.removeItem(at: pendingMidTurnFileURL) }
                    else if let encoded = try? JSONEncoder().encode(remainder) {
                        try? PrivateStorage.writeAtomically(encoded, to: pendingMidTurnFileURL)
                    }
                }
            }
        }
        if case .readable(let marker) = readActiveTurnMarkerState(),
           entries.contains(where: { $0.coversInterruptedTurn(triggerId: marker.triggerMessageId, startedAt: marker.startedAt) }) {
            clearActiveTurnMarker()
        }
        let affected = stopIntent.stoppedJobIds
        try? DetachedJobStore.mutate("stop-stamp") { records in
            for i in records.indices where affected.contains(records[i].jobId) && records[i].stopId == nil {
                records[i].stopId = entries.first(where: { $0.affectedJobIds.contains(records[i].jobId) })?.stopId
            }
        }
        retireSettledStopEntries(unsettledLiveJobs: [])
    }

    /// Job pass (§3.10.4): records of a previous process (their registry
    /// state is gone). Deferred while canonical recovery is unresolved or
    /// recovery evidence (salvage file, unpublished checkpoint) could still
    /// carry a result — the publication gate. Per record, using durable
    /// history only (as loaded, plus what canonical recovery saved):
    /// - its notice already in history (same id) → delivered;
    /// - a durable receiptObserved binding → nothing owed (receipt rule);
    /// - moved/absent → the notice is owed: the persisted real result when
    ///   the job settled before the restart, else one lost-job note;
    /// - unverifiable → obligation retained, reported, retried next start.
    /// Notes of stopped jobs (marker or record) or under an unreadable
    /// marker are appended without waking. One checked save for the pass.
    func reconcileJobRecords() {
        guard FileManager.default.fileExists(atPath: DetachedJobStore.fileURL.path) else { return }
        // An unreadable history proves nothing absent (Codex 1a round 2):
        // no publication, no retirement — records stay owed until a
        // successful reread.
        guard historyLoadFailure == nil else {
            print("[ConversationManager] Job reconciliation deferred: conversation history unreadable")
            return
        }
        // Background results are new work: they stay owed while the
        // held-message file can't be read (1a round 6), as they do while
        // history is unreadable.
        guard heldQueueFileProblem == nil else {
            print("[ConversationManager] Job reconciliation deferred: the held-message file can't be read")
            return
        }
        let records: [DetachedJobRecord]
        do { records = try DetachedJobStore.load() }
        catch {
            showMaintenanceNotice("Background-job crash records could not be read (\(error.localizedDescription)); they are kept for inspection.")
            return
        }
        let foreign = records.filter { $0.instanceId != DetachedJobStore.instanceId && $0.completion == .owed }
        guard !foreign.isEmpty else {
            // Delivered jobs of the previous process may still lack their
            // unknown-spend incident (charge only in memory at the restart).
            if records.contains(where: { $0.instanceId != DetachedJobStore.instanceId && $0.needsUnknownSpendIncident }) {
                ToolChargeLedger.registerUnknownSpendForPreviousProcesses()
                try? DetachedJobStore.retireSettled()
            }
            return
        }
        guard !recoveryBlocked, !activeTurnCheckpoints.values.contains(where: { $0.pendingRecovery }),
              !FileManager.default.fileExists(atPath: turnSalvageFileURL.path) else {
            print("[ConversationManager] Job reconciliation deferred until turn recovery resolves")
            return
        }
        var delivered: Set<UUID> = []
        var notOwed: Set<UUID> = []
        var realSettled: Set<UUID> = []
        var unverifiable: [UUID: String] = [:]
        var disposition: [UUID: DetachedJobRecord.Disposition] = [:]
        var lastWaking: Message? = nil
        var needsSave = false
        // Evidence is read from the COMMITTED view only (Codex 1a R1): a
        // notice appended by an earlier pass whose save failed is in
        // `messages` but proves nothing until a save carrying it succeeds.
        let committed = committedMessages
        for record in foreign {
            if lastSavedMessageIDs.contains(record.completionMessageId) {
                delivered.insert(record.jobId); continue
            }
            let stopped = stopIntent.isUnknown || record.stopId != nil || stoppedJobIds.contains(record.jobId)
            if let pending = messages.first(where: { $0.id == record.completionMessageId }) {
                // Appended by an earlier pass whose save failed: retry the
                // save (never a second copy); delivered only once it lands.
                needsSave = true
                delivered.insert(record.jobId)
                if !stopped { lastWaking = pending }
                continue
            }
            let outcome = SettlementEvidence.locate(record, history: committed)
            // Round delivery (v3 §2.7): a saved tool result (inline, or in a
            // reachable snapshot's sidecar) that typed-carries this
            // completion means the model already received it mid-turn —
            // delivered, nothing appended, no wake.
            let delivery = SettlementEvidence.locateDelivery(record, history: committed)
            switch outcome {
            case .bound(.receiptObserved):
                notOwed.insert(record.jobId); continue
            case .bound(.real):
                // A subagent that finished while its detach was committed:
                // the durable real result is its outcome (nothing owed).
                realSettled.insert(record.jobId); continue
            default: break
            }
            if delivery == .delivered { delivered.insert(record.jobId); continue }
            switch outcome {
            case .unverifiable(let reason):
                unverifiable[record.jobId] = reason; continue
            case .bound, .absent:
                // Delivery data that could not be verified (e.g. a malformed
                // sidecar delivery list) retains the obligation too.
                if case .unverifiable(let reason) = delivery {
                    unverifiable[record.jobId] = reason; continue
                }
                // An evidence route removed while it was unverifiable (the
                // removal gate recorded it): the obligation stays retained.
                if let reason = record.routeRemovedWhileUnverifiable {
                    unverifiable[record.jobId] = reason; continue
                }
            }
            if case .absent = outcome { disposition[record.jobId] = .orphanedMoved }
            if record.completionBody == nil { disposition[record.jobId] = .lost }
            var body = record.completionBody.map { $0 + "\n\n[Recovered after a restart — this job finished before Briglia stopped.]" }
                ?? (record.isSubagent ? SubagentCompletionNotice.lostNote(for: record) : BashCompletionNotice.lostNote(for: record))
            if stopped { body += BashCompletionNotice.stoppedNote }
            let message = Message(id: record.completionMessageId, role: .user, content: body,
                                  kind: record.isSubagent ? .subagentComplete : .bashComplete)
            messages.append(message)
            needsSave = true
            delivered.insert(record.jobId)
            if !stopped { lastWaking = message }
        }
        if needsSave {
            guard saveConversation() else {
                // Nothing is marked; the appended notices stay in memory
                // under their pre-minted ids (never a second copy) and the
                // next pass — this process or the next — retries the save.
                print("[ConversationManager] Job reconciliation save failed — records kept for the next pass")
                return
            }
        }
        do {
            try DetachedJobStore.mutate("reconcile") { records in
                for i in records.indices {
                    let job = records[i].jobId
                    if let reason = unverifiable[job] {
                        records[i].unverifiableReason = reason
                        records[i].unverifiableSince = records[i].unverifiableSince ?? Date()
                        continue
                    }
                    if let d = disposition[job] { records[i].disposition = d }
                    if delivered.contains(job) { records[i].completion = .delivered; records[i].deliveredAt = Date() }
                    if notOwed.contains(job) { records[i].completion = .notOwed; records[i].certifiedKind = .receiptObserved }
                    if realSettled.contains(job) { records[i].completion = .notOwed; records[i].certifiedKind = .real }
                }
                records.removeAll { $0.isSettled }
            }
        } catch {
            print("[ConversationManager] Could not update reconciled records: \(error.localizedDescription) (ids in history keep them idempotent)")
        }
        // Jobs of the previous process that ended without a captured charge
        // (lost subagents, charges that were only in memory): their unknown
        // amounts become durable spend incidents before the records retire.
        let spendProblems = ToolChargeLedger.registerUnknownSpendForPreviousProcesses()
        if !spendProblems.isEmpty {
            print("[ConversationManager] Unknown-spend incidents not yet recorded (records kept): \(spendProblems.joined(separator: "; "))")
        }
        try? DetachedJobStore.retireSettled()
        if !unverifiable.isEmpty {
            showMaintenanceNotice("\(unverifiable.count) background job result\(unverifiable.count == 1 ? "" : "s") could not be verified after a restart; kept for inspection (see /status).")
        }
        if let lastWaking { recoveredWakeTrigger = lastWaking }
        retireSettledStopEntries()
    }

    // MARK: - Crash-record gate before history removal (§3.10.3 step 5)

    /// Before messages leave `messages` (prune strips their rounds, archive
    /// removes them): every owed crash record whose settlement evidence is
    /// reachable through the COMMITTED history — inline bindings, and
    /// snapshot-backed evidence (active-turn compaction chains, pending
    /// recovery and interrupted outcomes, prune-archive references) reached
    /// from the roots that still exist — is settled with a checked write
    /// FIRST (Codex 1a R2): a receipt → nothing owed; moved/real → the
    /// certificate is upgraded; a delivered notice leaving history →
    /// delivered. Once the owning root is gone a restart could no longer
    /// discover that evidence, so the record itself must carry it.
    /// A route that is UNVERIFIABLE while its root is removed is recorded
    /// on the record (retained obligation, never delivered as absent).
    /// Conservative 1a rule: if the write fails the removal is REFUSED.
    /// Messages when no record is owed pass without touching the file.
    func settleJobEvidenceBeforeRemoval(of removed: [Message]) throws {
        if let historyLoadFailure { throw HistoryUnreadable(reason: historyLoadFailure) }
        var inlineBound = false
        for message in removed {
            for round in message.toolInteractions {
                for result in round.results where result.outcomeBinding?.kind.carriesJob == true && result.outcomeBinding?.jobId != nil {
                    inlineBound = true
                }
                // A round carrying mid-turn delivery evidence (round delivery
                // v3 §2.7) is gated like a bound result.
                for result in round.results where !result.deliveredCompletions.isEmpty { inlineBound = true }
            }
        }
        let removedIDs = Set(removed.map(\.id))
        guard FileManager.default.fileExists(atPath: DetachedJobStore.fileURL.path) || inlineBound else { return }
        let records: [DetachedJobRecord]
        do { records = try DetachedJobStore.load() }
        catch {
            // Unreadable records: nothing can be settled, so nothing whose
            // removal could hide evidence may leave (inline bindings, or any
            // snapshot route from a removed root). A completion notice is
            // evidence too (Codex 1a round 2): if its record's delivered-state
            // write failed, the notice's pre-minted id in history is the ONLY
            // deduplication proof, and which notices are record-backed cannot
            // be told while the records are unreadable — so every possible
            // carrier (.bashComplete, and since 1b .subagentComplete) stays.
            let carriesRoute = removed.contains { !$0.pruneArchiveReferences.isEmpty || $0.activeTurnCompaction != nil }
            let carriesNotice = removed.contains { $0.kind == .bashComplete || $0.kind == .subagentComplete }
            guard !inlineBound && !carriesRoute && !carriesNotice else {
                throw PruneArchiveStore.Failure("Crash records unreadable (\(error.localizedDescription)); results of background jobs stay in history until they can be settled")
            }
            return
        }
        let owed = records.filter { $0.completion == .owed }
        guard !owed.isEmpty else { return }
        // The carriers must be durable before a certificate may name them.
        if !removedIDs.isSubset(of: lastSavedMessageIDs) {
            guard saveConversation() else {
                throw PruneArchiveStore.Failure("Could not save history before settling background-job records; nothing was removed")
            }
        }
        let committed = committedMessages
        let remaining = committed.filter { !removedIDs.contains($0.id) }
        var certify: [UUID: OutcomeBinding.Kind] = [:]
        var deliveredJobs: Set<UUID> = []
        var routeLost: [UUID: String] = [:]
        for record in owed {
            if removedIDs.contains(record.completionMessageId), lastSavedMessageIDs.contains(record.completionMessageId) {
                deliveredJobs.insert(record.jobId)
            }
            // Delivered mid-turn as tool output (typed evidence reachable
            // while the removed roots still exist): settle it now, before
            // its carrier leaves history.
            switch SettlementEvidence.locateDelivery(record, history: committed) {
            case .delivered: deliveredJobs.insert(record.jobId)
            case .unverifiable(let reason):
                if record.routeRemovedWhileUnverifiable == nil,
                   SettlementEvidence.locateDelivery(record, history: remaining) != .unverifiable(reason) {
                    routeLost[record.jobId] = reason
                }
            case .absent: break
            }
            // Resolved while the removed roots still exist.
            switch SettlementEvidence.locate(record, history: committed) {
            case .bound(let kind):
                if Self.certificateRank(kind) > Self.certificateRank(record.certifiedKind) { certify[record.jobId] = kind }
            case .unverifiable(let reason):
                if record.routeRemovedWhileUnverifiable == nil,
                   SettlementEvidence.locate(record, history: remaining) != .unverifiable(reason) {
                    routeLost[record.jobId] = reason
                }
            case .absent:
                break
            }
        }
        guard !certify.isEmpty || !deliveredJobs.isEmpty || !routeLost.isEmpty else { return }
        do {
            try DetachedJobStore.mutate("settle-before-removal") { records in
                for i in records.indices where records[i].completion == .owed {
                    let job = records[i].jobId
                    if deliveredJobs.contains(job) {
                        records[i].completion = .delivered
                        records[i].deliveredAt = Date()
                    }
                    if let kind = certify[job], Self.certificateRank(kind) > Self.certificateRank(records[i].certifiedKind) {
                        records[i].certifiedKind = kind
                        records[i].certifiedAt = Date()
                        if kind == .receiptObserved || kind == .real { records[i].completion = .notOwed }
                    }
                    if let reason = routeLost[job], records[i].completion == .owed {
                        records[i].routeRemovedWhileUnverifiable = reason
                        records[i].unverifiableReason = reason
                        records[i].unverifiableSince = records[i].unverifiableSince ?? Date()
                    }
                }
                records.removeAll { $0.isSettled }
            }
        } catch {
            throw PruneArchiveStore.Failure("Could not settle background-job records (\(error.localizedDescription)); nothing was removed")
        }
        let observed = Set(certify.filter { $0.value == .receiptObserved }.keys)
        if !observed.isEmpty { Task { await BackgroundProcessRegistry.shared.acknowledgeDelivered(jobUUIDs: observed) } }
    }

    /// Append the "sent before /stop" note after held messages (one per
    /// stop entry, id-deduplicated with its pre-minted id). User text is
    /// never modified. Returns the held ids found in `batch`.
    @discardableResult
    func appendHeldPreStopNotes(for batch: [Message]) -> Set<UUID> {
        let entries = allStopEntries
        let held = Set(batch.filter { m in entries.contains { $0.holds(m) } }.map(\.id))
        guard !held.isEmpty else { return [] }
        for entry in entries where batch.contains(where: { held.contains($0.id) && entry.holds($0) }) {
            guard !messages.contains(where: { $0.id == entry.heldNoteMessageId }) else { continue }
            messages.append(Message(id: entry.heldNoteMessageId, role: .user,
                                    content: "[Harness note] The message(s) above were sent before /stop; Briglia stopped without acting on them.",
                                    kind: .bashComplete))
        }
        return held
    }

    /// Retire every stop entry whose items are all durably settled
    /// (§3.9.3): held messages durable and out of the queue, their note
    /// durable, the stopped turn not resumable, and every affected job
    /// settled (record retired/settled, nothing queued or running).
    func retireSettledStopEntries() {
        guard !stopEntries.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let unsettled = await BackgroundProcessRegistry.shared.unsettledMainOwnedItems().jobUUIDs
            await MainActor.run { self.retireSettledStopEntries(unsettledLiveJobs: unsettled) }
        }
    }

    func retireSettledStopEntries(unsettledLiveJobs: Set<UUID>) {
        guard !stopEntries.isEmpty, historyLoadFailure == nil else { return }
        let records: [DetachedJobRecord]
        do { records = try DetachedJobStore.load() } catch { return }  // keep entries: cannot prove settlement
        let openRecords = Set(records.filter { !$0.completionSettled }.map(\.jobId))
        let queued = Set(pendingMidTurnMessages.map(\.id))
        let markerState = readActiveTurnMarkerState()
        let queueFile = readHeldQueueFile()
        var remaining: [StopEntry] = []
        for entry in stopEntries {
            var heldSettled = entry.heldQueueMessageIds.allSatisfy { lastSavedMessageIDs.contains($0) && !queued.contains($0) }
                && (entry.heldQueueMessageIds.isEmpty || lastSavedMessageIDs.contains(entry.heldNoteMessageId))
            if entry.heldUnreadableQueue == true {
                // Settled once the queue file reads and no message it holds
                // is still queued, and its note (if appended) is durable.
                switch queueFile {
                case .unreadable: heldSettled = false
                case .absent, .readable:
                    var onDisk: [Message] = []
                    if case .readable(let list) = queueFile { onDisk = list }
                    let stillQueued = (onDisk + pendingMidTurnMessages).contains { entry.holds($0) }
                    let noteDurable = !messages.contains(where: { $0.id == entry.heldNoteMessageId })
                        || lastSavedMessageIDs.contains(entry.heldNoteMessageId)
                    heldSettled = heldSettled && !stillQueued && noteDurable
                }
            }
            // An entry that depends on the turn marker (a named trigger or
            // the conservative disposition) settles only on the CURRENT
            // marker state proving it: known absent, or readable and not
            // covered. An unreadable marker proves nothing (1a round 6),
            // whatever it was when /stop was issued.
            var turnSettled = true
            if entry.stoppedTurnTriggerId != nil || entry.stoppedUnreadableTurnMarker == true {
                switch markerState {
                case .absent: break
                case .unreadable: turnSettled = false
                case .readable(let marker):
                    if entry.coversInterruptedTurn(triggerId: marker.triggerMessageId, startedAt: marker.startedAt) { turnSettled = false }
                }
                if let trigger = entry.stoppedTurnTriggerId, trigger == activeTurnTriggerMessage?.id { turnSettled = false }
            }
            let jobsSettled = entry.affectedJobIds.allSatisfy { !openRecords.contains($0) && !unsettledLiveJobs.contains($0) }
            if !(heldSettled && turnSettled && jobsSettled) { remaining.append(entry) }
        }
        guard remaining.count != stopEntries.count else { return }
        do {
            try StopMarkerStore.replace(remaining)
            let retired = stopEntries.filter { e in !remaining.contains(where: { $0.stopId == e.stopId }) }
            stopEntries = remaining
            let stillAffected = Set(remaining.flatMap(\.affectedJobIds))
            for job in retired.flatMap(\.affectedJobIds) where !stillAffected.contains(job) {
                stoppedJobIds.remove(job)
            }
            if case .known = stopIntent { stopIntent = remaining.isEmpty ? .none : .known(entries: remaining) }
        } catch {
            print("[ConversationManager] Could not retire settled /stop entries: \(error.localizedDescription)")
        }
    }

    func increaseSpendLimitIfNeeded(by amountUSD: Double) async {
        let status = currentSpendLimitStatus(referenceDate: Date())
        let applyToDaily = status.dailyExceeded && status.dailyBaseLimitUSD != nil
        let applyToMonthly = status.monthlyExceeded && status.monthlyBaseLimitUSD != nil

        let message: String
        if applyToDaily || applyToMonthly {
            KeychainHelper.addOpenRouterSpendLimitIncrease(
                amountUSD,
                applyToDaily: applyToDaily,
                applyToMonthly: applyToMonthly
            )

            let updatedStatus = currentSpendLimitStatus(referenceDate: Date())
            if applyToDaily, applyToMonthly {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to both reached spend limits.
                New daily limit: $\(formatUSD(updatedStatus.effectiveDailyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.todaySpentUSD)))
                New monthly limit: $\(formatUSD(updatedStatus.effectiveMonthlyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.monthSpentUSD)))
                """
            } else if applyToDaily {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to today's spend limit.
                New daily limit: $\(formatUSD(updatedStatus.effectiveDailyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.todaySpentUSD)))
                """
            } else {
                message = """
                ✅ Added $\(formatUSD(amountUSD)) to this month's spend limit.
                New monthly limit: $\(formatUSD(updatedStatus.effectiveMonthlyLimitUSD ?? 0)) (spent: $\(formatUSD(updatedStatus.monthSpentUSD)))
                """
            }
        } else if status.unverifiable {
            // A raised limit cannot make an unknown total known (§3.6.3).
            message = "No limit is reached, but today's spend can't be verified, so paid work stays paused: \((status.accounting.incidents.map(ToolChargeLedger.describe) + status.accounting.unidentified).joined(separator: "; ")). `/more1`, `/more5` and `/more10` can't fix that — repair the file (see `briglia doctor`) or send `/spend accept-unknown`."
        } else {
            message = "No daily or monthly spend limit is currently reached. `/more1`, `/more5`, and `/more10` only work after a daily or monthly cap has been hit."
        }

        try? await sendText(message)

        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }
}
