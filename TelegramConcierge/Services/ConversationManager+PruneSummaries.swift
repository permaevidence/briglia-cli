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

    /// Runs the pass at the next main-actor turn (coalesced), so a trigger
    /// inside a transition sees that transition completed first.
    func scheduleSummaryRetentionIdlePass() {
        guard Self.summaryRetentionIdlePassEnabled, !summaryRetentionPassScheduled else { return }
        summaryRetentionPassScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.summaryRetentionPassScheduled = false
            self.summaryRetentionIdlePass()
        }
    }

    /// The safe idle point (§5.2): nothing that reads or rewrites the
    /// history, its measurement or the snapshot directory may be running.
    var summaryRetentionIdleBlocker: String? {
        if activeRunId != nil || activeProcessingTask != nil { return "turn" }
        if backgroundPruneJob != nil { return "background prune" }
        if archiveJob != nil { return "archive job" }
        if archiveRecoveryTask != nil { return "archive recovery" }
        if !maintenanceActivities.isEmpty { return "maintenance" }
        if isRestoringMind { return "mind restore" }
        if historyLoadFailure != nil || checkpointWriteFailure != nil || recoveryBlocked || inboundDurabilityFailure {
            return "persistence stall"
        }
        return nil
    }

    /// One legacy record, no current summary, complete recorded coverage.
    private static func isRestoreCandidate(_ message: Message) -> Bool {
        guard message.prunedContextSummary == nil, message.demotedPruneSummaries.count == 1,
              let coverage = message.demotedPruneSummaries[0].coverage else { return false }
        return coverage.complete && coverage.isValid
    }

    private static func restoreAttemptKey(_ message: Message) -> String {
        message.id.uuidString + "|" + (message.demotedPruneSummaries.first?.snapshot.id.uuidString ?? "")
    }

    private static func stubRepairKey(_ message: Message) -> String {
        message.id.uuidString + "|" + PruneSummaryStub.digest(message.prunedContextSummary ?? "")
    }

    /// Repairs missing, stale or broken stubs and restores the provably
    /// exact legacy pointers. Synchronous on the main actor from the
    /// precondition check to the checked history write; snapshot I/O is
    /// bounded by the per-file and per-pass budgets.
    @discardableResult
    func summaryRetentionIdlePass() -> SummaryRetentionPassReport {
        var report = SummaryRetentionPassReport()
        if let blocker = summaryRetentionIdleBlocker { report.blocked = blocker; return report }
        // The completeness scan (startup, Mind import, wipe) stays pending
        // until every broken pointer it finds has been durably replaced or
        // is known unsupported (R2): a failed or deferred repair is retried
        // at the next idle point, not forgotten.
        let scan = summaryRetentionScanPending
        let history = messages
        var repairs: [Int] = []
        var restores: [Int] = []
        for index in history.indices {
            let message = history[index]
            if PruneSummaryRetention.isFullAnchor(message) {
                guard !summaryStubRepairUnsupported.contains(Self.stubRepairKey(message)) else { continue }
                if let stub = message.prunedContextSummaryStub, stub.isUsable(for: message.prunedContextSummary) {
                    // Broken snapshots are found by the startup/import scan,
                    // not only by digest.
                    if scan && !PruneArchiveStore.isCompleteSnapshot(stub.record.snapshot) { repairs.append(index) }
                } else {
                    repairs.append(index)
                }
            } else if Self.isRestoreCandidate(message), !summaryRestoreAttempts.contains(Self.restoreAttemptKey(message)) {
                restores.append(index)
            }
        }
        guard !repairs.isEmpty || !restores.isEmpty else { summaryRetentionScanPending = false; return report }
        var budget = PruneSummaryRestore.maxPassBytes
        var candidate = history
        var pinned: [PruneArchiveReference] = []
        defer { pinned.forEach { PruneArchiveStore.release($0) } }

        // Restores: grouped by snapshot file, files in a fixed order, each
        // read and indexed once. A file that would exceed the remaining
        // budget is not started; everything not reached stays untouched.
        var restored: [Int] = []
        let groups = Dictionary(grouping: restores) { history[$0].demotedPruneSummaries[0].snapshot.id }
        let references = groups.keys.compactMap { id in restores.lazy.map { history[$0].demotedPruneSummaries[0].snapshot }.first { $0.id == id } }
        for reference in references.sorted(by: { $0.basename < $1.basename }) {
            let indices = groups[reference.id] ?? []
            func refuse() { for i in indices { summaryRestoreAttempts.insert(Self.restoreAttemptKey(history[i])) }; report.refused += indices.count }
            guard let size = PruneSummaryRestore.fileSize(reference) else { refuse(); continue }
            guard size <= PruneSummaryRestore.maxFileBytes else { refuse(); continue }
            guard size <= budget else { report.deferred += indices.count; continue }
            budget -= size; report.bytes += size
            switch PruneSummaryRestore.index(reference) {
            case .failure(let refusal):
                print("[KeepSummaries] snapshot \(reference.basename) not restorable: \(refusal.reason)")
                refuse()
            case .success(let indexed):
                for i in indices {
                    let record = history[i].demotedPruneSummaries[0]
                    guard let coverage = record.coverage else {
                        summaryRestoreAttempts.insert(Self.restoreAttemptKey(history[i])); report.refused += 1; continue
                    }
                    let text: String
                    switch PruneSummaryRestore.recover(messageID: history[i].id, coverage: coverage, from: indexed) {
                    case .success(let recovered): text = recovered
                    case .failure(let refusal):
                        print("[KeepSummaries] summary of \(history[i].id) stays a pointer: \(refusal.reason)")
                        summaryRestoreAttempts.insert(Self.restoreAttemptKey(history[i])); report.refused += 1; continue
                    }
                    var message = history[i]
                    message.prunedContextSummary = text
                    message.prunedContextSummaryCoverage = coverage
                    message.demotedPruneSummaries = []
                    // The stub reuses the record: same line, same snapshot.
                    message.prunedContextSummaryStub = PruneSummaryStub(summary: text, record: record)
                    if let measured = message.measuredTokens {
                        message.measuredTokens = PruneSummaryRetention.saturatingMeasured(measured,
                            delta: text.count / 4 - PruneSummaryRetention.wrapper(record.line).count / 4)
                    }
                    candidate[i] = message
                    restored.append(i)
                }
            }
        }

        // Stub repairs: one pinned snapshot per anchor, its output capped
        // by the remaining budget WHILE it is written. Every byte written is
        // charged, including staging output that is then discarded (R1), so
        // the snapshot reads and writes of one pass never exceed its budget
        // (other disk writes, such as the history save, are not counted). The first
        // failure ends the pass's repair work; the rest is deferred.
        var stopped = false
        var outstanding = false
        for index in repairs {
            guard !stopped, budget > 0 else { report.deferred += 1; outstanding = true; continue }
            let fresh = budget == PruneSummaryRestore.maxPassBytes
            let meter = PruneArchiveStore.ByteMeter()
            defer { budget -= min(meter.bytes, budget); report.bytes += meter.bytes }
            do {
                let reference = try PruneArchiveStore.write(messages: [candidate[index]], trigger: "automatic",
                    removedIDs: [candidate[index].id], leadNote: PruneSummaryRetention.snapshotLeadNote, pin: true,
                    maxBytes: budget, meter: meter)
                pinned.append(reference)
                if let stub = PruneSummaryRetention.makeStub(for: candidate, anchor: index, snapshot: reference) {
                    candidate[index].prunedContextSummaryStub = stub
                    report.stubsRepaired += 1
                } else {
                    summaryStubRepairUnsupported.insert(Self.stubRepairKey(candidate[index]))
                }
            } catch is PruneArchiveStore.OverBudget {
                // Too big even for a fresh pass: unsupported in this history
                // (stays in full / keeps its pointer, never retried). Otherwise
                // only deferred to a later idle point.
                if fresh { summaryStubRepairUnsupported.insert(Self.stubRepairKey(candidate[index])) } else { outstanding = true }
                report.deferred += 1
                stopped = true
            } catch {
                // Transient: never cached; retried at a later idle point.
                print("[KeepSummaries] stub repair snapshot failed: \(error.localizedDescription)")
                report.deferred += 1
                outstanding = true
                stopped = true
            }
        }

        // R3-2: no restored text is published unless the cached measurement
        // was durably cleared first. A failure keeps the restores retryable.
        if !restored.isEmpty {
            do { try clearPromptMeasurementDurably() }
            catch {
                print("[KeepSummaries] measurement could not be cleared; restore retried later: \(error.localizedDescription)")
                report.measurementClearFailed = true
                for i in restored { candidate[i] = history[i] }
                restored = []
            }
        }
        report.restored = restored.count
        guard report.stubsRepaired > 0 || !restored.isEmpty else {
            if scan { summaryRetentionScanPending = outstanding }
            return report
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        do { try writeHistoryFile(try encoder.encode(candidate)) }
        catch {
            // Memory unchanged; the disk may hold the old or new copy, as
            // with prune commits. Parsed restores stay retryable.
            print("[KeepSummaries] history write failed: \(error.localizedDescription)")
            report.historyWriteFailed = true
            report.restored = 0; report.stubsRepaired = 0
            return report // a pending scan stays pending
        }
        messages = candidate
        committedMessages = candidate
        if scan { summaryRetentionScanPending = outstanding }
        print("[KeepSummaries] idle pass: \(report.stubsRepaired) stub(s) prepared, \(report.restored) summary(ies) restored, \(report.refused) left as pointers")
        return report
    }

    /// One checked, durable write of a cleared usage snapshot (file fsync,
    /// rename, parent fsync), observers suppressed so nothing else writes.
    private func clearPromptMeasurementDurably() throws {
        let now = Date()
        let snapshot = ContextUsageSnapshot(lastPromptTokens: nil, lastCompletionTokens: nil, updatedAt: now, lastPromptRenderKey: nil)
        let data = try JSONEncoder().encode(snapshot)
        try Self.usageClearFaultForTesting?("before-write")
        try PrivateStorage.writeAtomically(data, to: contextUsageFileURL)
        try Self.usageClearFaultForTesting?("after-rename")
        isRestoringContextUsageSnapshot = true
        lastPromptRenderKey = PruneSummaryRetention.emptyRenderKey
        lastPromptTokens = nil
        lastCompletionTokens = nil
        isRestoringContextUsageSnapshot = false
    }

    private func appendPrunedContextSummary(_ summary: String, toMessageAt index: Int) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, messages.indices.contains(index) else { return }

        if let existing = messages[index].prunedContextSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            messages[index].prunedContextSummary = existing + "\n\n" + trimmed
        } else {
            messages[index].prunedContextSummary = trimmed
        }
    }

    func pruneSummaryAnchorIndex(plan: PrunePlan, compressedIndices: [Int], messageCount: Int) -> Int? {
        let affected = plan.affectedIndices + compressedIndices
        guard let maxAffected = affected.max(), maxAffected >= 0, maxAffected < messageCount else { return nil }
        return maxAffected
    }

    func notifyAutomaticPruningStarted(
        plan: PrunePlan,
        compressedCount: Int,
        totalTokens: Int,
        targetTokens: Int,
        isMidLoop: Bool
    ) async {
        guard replyAddress != nil else { return }

        statusMessage = "Summarizing older context before pruning..."

        var pieces: [String] = []
        if plan.toolActionCount > 0 {
            pieces.append("tools from \(plan.toolActionCount) turn\(plan.toolActionCount == 1 ? "" : "s")")
        }
        if plan.mediaActionCount > 0 {
            pieces.append("media from \(plan.mediaActionCount) message\(plan.mediaActionCount == 1 ? "" : "s")")
        }
        if compressedCount > 0 {
            pieces.append("\(compressedCount) system update\(compressedCount == 1 ? "" : "s")")
        }

        let scope = pieces.isEmpty ? "older context" : pieces.joined(separator: ", ")
        let intro = isMidLoop ? "Context filled up while I was working." : "Context is getting full."
        let text = "\(intro) ✂️ Summarizing and compacting \(scope) so I can keep going. This can take a few minutes on a local model. (~\(totalTokens / 1000)K → target ~\(targetTokens / 1000)K tokens)"
        try? await sendText(text)
    }

    func applyPrunePlan(_ plan: PrunePlan, to targetMessages: inout [Message], clearTrackers: Bool = false) {
        for action in plan.actions {
            switch action {
            case .toolInteractions(let index, let savedTokens):
                guard targetMessages.indices.contains(index) else { continue }
                // Project instructions (AGENTS.md/CLAUDE.md) ride inside tool
                // results; once their carrying interaction leaves context, the
                // next tool touching that project must re-inject them.
                for interaction in (clearTrackers ? targetMessages[index].toolInteractions : []) {
                    for result in interaction.results {
                        let foreground = RoundDelivery.foregroundContent(of: result)
                        for path in ProjectInstructionsTracker.markerPaths(in: foreground) {
                            toolExecutor.projectInstructions.clearLoaded(instructionFilePath: path)
                        }
                        for root in ProjectInstructionsTracker.verificationMarkerRoots(in: foreground) {
                            toolExecutor.projectInstructions.clearVerification(root: root)
                        }
                        for root in GitCheckpointTracker.markerRoots(in: foreground) {
                            toolExecutor.gitCheckpoints.clearCheckpoint(root: root)
                        }
                    }
                }
                // Generate the compact log now — before clearing interactions —
                // so the agent retains a lightweight summary of what tools ran.
                if targetMessages[index].compactToolLog == nil, !targetMessages[index].toolInteractions.isEmpty {
                    targetMessages[index].compactToolLog = buildCompactToolExecutionLog(
                        from: targetMessages[index].toolInteractions
                    )
                }
                if let active = targetMessages[index].activeTurnCompaction {
                    targetMessages[index].pruneArchiveReferences.append(active.latestSnapshotReference)
                    targetMessages[index].activeTurnCompaction = nil
                }
                targetMessages[index].toolInteractions = []
                targetMessages[index].finalReasoning = nil
                targetMessages[index].finalReasoningDetails = nil
                targetMessages[index].finalReasoningModel = nil
                targetMessages[index].responsesReplay = nil
                targetMessages[index].measuredToolTokens = nil
                if let m = targetMessages[index].measuredTokens {
                    targetMessages[index].measuredTokens = max(m - savedTokens, 0)
                }
            case .media(let index, let savedTokens):
                guard targetMessages.indices.contains(index) else { continue }
                targetMessages[index].mediaPruned = true
                if let m = targetMessages[index].measuredTokens {
                    targetMessages[index].measuredTokens = max(m - savedTokens, 0)
                }
            }
        }
    }

    func pruneSummaryManifest(
        plan: PrunePlan,
        compressedIndices: [Int],
        sourceMessages: [Message]
    ) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .medium
        timeFormatter.timeStyle = .short

        var sections: [String] = []
        for index in (plan.affectedIndices + compressedIndices).sorted() {
            guard sourceMessages.indices.contains(index) else { continue }
            let message = sourceMessages[index]
            var lines: [String] = []
            let role = message.role == .user ? "user" : "assistant"
            lines.append("Turn \(index + 1) (\(role), \(timeFormatter.string(from: message.timestamp)))")
            if let active = message.activeTurnCompaction {
                lines.append("Also transfer this earlier active-turn summary: " + MarkerNeutralizer.escape(active.summaryText))
            }

            if compressedIndices.contains(index) {
                lines.append("Prune synthetic user-message body for kind: \(message.kind.rawValue)")
            }

            for action in plan.actions where action.index == index {
                switch action {
                case .toolInteractions:
                    let toolNames = message.toolInteractions.flatMap { interaction in
                        interaction.assistantMessage.toolCalls.map { $0.function.name }
                    }
                    if !toolNames.isEmpty {
                        lines.append("Prune tool interactions: \(toolNames.joined(separator: ", "))")
                    } else if message.hasFinalReasoningPayload {
                        lines.append("Prune assistant reasoning for this turn")
                    } else {
                        lines.append("Prune tool interactions")
                    }

                    let referencedFiles = message.toolInteractions.flatMap { interaction in
                        interaction.results.flatMap { result in
                            result.fileAttachmentReferences.map(\.filename)
                        }
                    }
                    if !referencedFiles.isEmpty {
                        lines.append("Pruned tool attachment references: \(Array(Set(referencedFiles)).sorted().joined(separator: ", "))")
                    }
                case .media:
                    let files = message.imageFileNames + message.documentFileNames
                        + message.referencedImageFileNames + message.referencedDocumentFileNames
                    if !files.isEmpty {
                        lines.append("Prune inline media bytes; keep text hints/descriptions for: \(files.joined(separator: ", "))")
                    } else {
                        lines.append("Prune inline media bytes")
                    }
                }
            }

            sections.append(lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    func generatePrunedContextSummary(
        plan: PrunePlan,
        compressedIndices: [Int],
        sourceMessages: [Message],
        currentTurnInteractions: [ToolInteraction]? = nil,
        tools: [ToolDefinition],
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem],
        totalChunkCount: Int,
        currentUserMessageId: UUID?,
        turnStartDate: Date,
        deferredMCPSummaries: [(name: String, description: String, toolCount: Int)],
        execution: ProviderExecutionContext? = nil,
        persona: PromptPersona? = nil,
        summaryLimit: KeepSummariesLimit
    ) async -> String? {
        guard !plan.isEmpty || !compressedIndices.isEmpty else { return nil }
        // /keepsummaries: the decision's composition, for every attempt
        // (retries and tool-refusal replies included). The canonical source
        // still drives the manifest and the fallback.
        let requestMessages = PruneSummaryRetention.compose(sourceMessages, limit: summaryLimit).messages

        // Only the newly unprotected oversized newest tool turn takes the
        // bounded path. Ordinary historical-prune request bytes stay unchanged.
        if let newest = sourceMessages.lastIndex(where: { !$0.toolInteractions.isEmpty }),
           plan.affectedIndices.contains(newest),
           sourceMessages[newest].toolInteractions.reduce(0, { $0 + ActiveTurnBudget.round($1) }) > ActiveTurnBudget(maximum: configuredMaxContextTokens()).inputCeiling {
            let affected = Array(Set(plan.affectedIndices + compressedIndices)).sorted()
            guard affected.allSatisfy({ sourceMessages.indices.contains($0) }) else {
                return fallbackPrunedContextSummary(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages)
            }
            do {
                return try await summarizeActivePrefix(affected.flatMap { sourceMessages[$0].toolInteractions }, previous: nil,
                    execution: execution, date: turnStartDate, contextMessages: requestMessages, persona: persona)
            } catch {
                print("[ActiveCompaction] Oversized historical summary unavailable: \(error.localizedDescription)")
                return fallbackPrunedContextSummary(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages)
            }
        }

        let manifest = pruneSummaryManifest(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages)
        guard !manifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let tail = """
        [PRUNE SUMMARY REQUEST - system maintenance]
        Tool use is disabled for this maintenance pass. Do NOT call tools. Do not emit tool calls. Return plain text only.
        The manifest below identifies the exact earlier turn content that is about to be pruned. The actual content is already present in the conversation above; do not expect it to be repeated here.
        Summarize ONLY the identified soon-to-be-pruned parts of the conversation above:
        - tool calls, tool outputs, and assistant reasoning for listed tool-interaction turns
        - media/file relevance for listed media turns
        - useful facts from listed synthetic message bodies
        Do not summarize unlisted turns or stable visible chat text that is not being pruned.
        Keep durable details: user goals, decisions, findings, errors, commands, file paths, filenames, IDs, URLs, tool outcomes, and unresolved next steps. This summary's purpose is to let you continue to work without missing important information once this content is pruned. View it as a baton exchange to a future version of you that will not see this pruned content.
        For each file created or edited in the pruned turns: state what changed and the most recent verification outcome for that change (build/test for code; audit/preview for documents). If a change was never verified, say so explicitly.
        For research or web lookups in the pruned turns: keep each key finding paired with the source URL that supports it, so work can continue without re-fetching sources.
        Quote error messages, exact identifiers, commit SHAs, and other precise strings verbatim - do not paraphrase text you may need to match or reuse later.
        Omit routine noise, duplicated logs, and low-value progress chatter.
        Length: up to ~1000 words for small prunes, up to ~2000 words when many turns are being pruned. Allocate words by usefulness to your future self, NOT by chronology or turn count: unresolved and recent work deserves the most detail; early exploration that was later superseded gets one line or nothing; dead ends only their conclusion. Chronological order is a fine default for the narrative, but it must not imply equal coverage per turn.
        This is internal memory, not a user-facing reply.

        PRUNE MANIFEST:
        \(manifest)
        [END PRUNE SUMMARY REQUEST]
        """

        let selected: ProviderExecutionContext
        if let execution { selected = execution }
        else { selected = await openRouterService.executionContext(modelOverride: nil,
            providerOverride: nil, reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main) }
        let summaryExecution = selected.wireProtocol == .responses ? selected.forOperation(.pruneSummary) : nil
        defer { summaryExecution?.responsesTurn.close() }
        let summaryStart = Date()
        DebugTelemetry.log(
            .info,
            summary: "prune summary started",
            detail: manifest
        )

        // Every prune-summary reply is charged through the normal spend path.
        func recordPruneSummarySpend(_ spend: Double?) {
            guard let spend, spend.isFinite, spend > 0 else { return }
            KeychainHelper.recordOpenRouterSpend(spend)
        }
        // Empty, cut-off and no-text replies share one budget across the plain
        // request and the tool-refusal retries: the original attempt plus one
        // retry, then the programmatic fallback. Every rejected reply is charged.
        var rejection: CompactionSummaryPolicy.Rejection?
        var rejectedAttempts = 0
        func acceptPruneText(_ content: String, _ finish: String?, _ label: String) -> String? {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if CompactionSummaryPolicy.isCutOff(finish) {
                rejection = .truncated("finish_reason: \(finish!)")
            } else if trimmed.isEmpty {
                rejection = .empty
            } else {
                return String(trimmed.prefix(14000))
            }
            rejectedAttempts += 1
            print("[ConversationManager] Prune summary \(label) rejected (\(rejectedAttempts)/\(CompactionSummaryPolicy.attempts)): \(rejection!.reason)")
            return nil
        }
        /// A decode-layer rejection (no-text or incomplete reply): charged and
        /// counted. Returns false for a request failure, which is not a reply.
        func rejectThrownReply(_ error: Error, _ label: String) -> Bool {
            guard let reason = CompactionSummaryPolicy.rejection(for: error) else { return false }
            recordPruneSummarySpend(CompactionSummaryPolicy.spend(for: error))
            rejection = reason
            rejectedAttempts += 1
            print("[ConversationManager] Prune summary \(label) rejected (\(rejectedAttempts)/\(CompactionSummaryPolicy.attempts)): \(reason.reason)")
            return true
        }
        func rejectedFallback() -> String? {
            let reason = rejection?.reason ?? "no usable reply"
            print("[ConversationManager] Prune summary rejected after \(CompactionSummaryPolicy.attempts) attempts (\(reason)); falling back to compact log summary")
            DebugTelemetry.log(
                .info,
                summary: "prune summary fallback: reply rejected",
                detail: "Prune summary rejected after \(CompactionSummaryPolicy.attempts) attempts: \(reason)",
                durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000),
                isError: true
            )
            return fallbackPrunedContextSummary(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages)
        }
        do {
            while rejectedAttempts < CompactionSummaryPolicy.attempts {
                let attempt = rejectedAttempts + 1
                let response: LLMResponse
                do {
                    response = try await openRouterService.generateResponse(
                        messages: requestMessages,
                        imagesDirectory: imagesDirectory,
                        documentsDirectory: documentsDirectory,
                        tools: summaryExecution == nil ? tools : [],
                        toolResultMessages: currentTurnInteractions,
                        calendarContext: calendarContext,
                        emailContext: emailContext,
                        chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                        totalChunkCount: totalChunkCount,
                        currentUserMessageId: currentUserMessageId,
                        turnStartDate: turnStartDate,
                        tailUserMessage: tail,
                        deferredMCPSummaries: deferredMCPSummaries.isEmpty ? nil : deferredMCPSummaries,
                        execution: summaryExecution, lane: .main, persona: persona
                    )
                } catch {
                    guard rejectThrownReply(error, "attempt \(attempt)") else { throw error }
                    continue
                }
                recordPruneSummarySpend(spendUSD(from: response))
                switch response {
                case .text(let content, _, _, _, _, _, _, let finish):
                    if let summary = acceptPruneText(content, finish, "attempt \(attempt)") {
                        DebugTelemetry.log(
                            .info,
                            summary: "prune summary completed",
                            detail: "chars: \(summary.count), attempt: \(attempt)",
                            durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000)
                        )
                        return summary
                    }
                    continue
                case .toolCalls(let assistantMessage, let calls, _, _, _):
                    var retryInteractions = (currentTurnInteractions ?? []) + [
                        disabledMaintenanceToolInteraction(
                            assistantMessage: assistantMessage,
                            calls: calls,
                            reason: "Tool calls are disabled during the prune-summary maintenance pass. This tool was not executed. Return the requested prune summary as plain text only."
                        )
                    ]

                    for attempt in 1...4 {
                        // The shared reply budget is spent: no further request.
                        guard rejectedAttempts < CompactionSummaryPolicy.attempts else { break }
                        let retryTail = """
                        [PRUNE SUMMARY RETRY \(attempt)/4 - system maintenance]
                        The tool call(s) you requested were not executed because this is an internal pruning summary pass.
                        Tool use remains disabled for this maintenance pass. Return plain text only.
                        Produce the requested prune summary now, using only the conversation context already present above and the prune manifest.
                        [END PRUNE SUMMARY RETRY]
                        """

                        do {
                            let retryResponse = try await openRouterService.generateResponse(
                                messages: requestMessages,
                                imagesDirectory: imagesDirectory,
                                documentsDirectory: documentsDirectory,
                                tools: summaryExecution == nil ? tools : [],
                                toolResultMessages: retryInteractions,
                                calendarContext: calendarContext,
                                emailContext: emailContext,
                                chunkSummaries: chunkSummaries.isEmpty ? nil : chunkSummaries,
                                totalChunkCount: totalChunkCount,
                                currentUserMessageId: currentUserMessageId,
                                turnStartDate: turnStartDate,
                                tailUserMessage: retryTail,
                                deferredMCPSummaries: deferredMCPSummaries.isEmpty ? nil : deferredMCPSummaries,
                                execution: summaryExecution, lane: .main, persona: persona
                            )
                            recordPruneSummarySpend(spendUSD(from: retryResponse))
                            switch retryResponse {
                            case .text(let content, _, _, _, _, _, _, let finish):
                                // Empty or cut-off text is a rejected reply, never a summary.
                                guard let summary = acceptPruneText(content, finish, "retry \(attempt) after tool refusal") else { continue }
                                DebugTelemetry.log(
                                    .info,
                                    summary: "prune summary completed after tool refusal",
                                    detail: "attempt: \(attempt), chars: \(summary.count)",
                                    durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000)
                                )
                                return summary
                            case .toolCalls(let retryAssistant, let retryCalls, _, _, _):
                                retryInteractions.append(
                                    disabledMaintenanceToolInteraction(
                                        assistantMessage: retryAssistant,
                                        calls: retryCalls,
                                        reason: "Tool calls are disabled during the prune-summary maintenance pass. This tool was not executed. Return the requested prune summary as plain text only."
                                    )
                                )
                            }
                        } catch {
                            if !rejectThrownReply(error, "retry \(attempt) after tool refusal") {
                                print("[ConversationManager] Prune summary retry \(attempt) failed after refusing tool calls: \(error)")
                            }
                        }
                    }

                    if rejectedAttempts >= CompactionSummaryPolicy.attempts { return rejectedFallback() }
                    print("[ConversationManager] Prune summary request kept returning tool calls after retries; falling back to compact log summary")
                    DebugTelemetry.log(
                        .info,
                        summary: "prune summary fallback: model returned tool calls",
                        detail: manifest,
                        durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000),
                        isError: true
                    )
                    return fallbackPrunedContextSummary(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages)
                }
            }
            return rejectedFallback()
        } catch {
            print("[ConversationManager] Failed to generate prune summary: \(error)")
            DebugTelemetry.log(
                .info,
                summary: "prune summary fallback: request failed",
                detail: "\(error)",
                durationMs: Int(Date().timeIntervalSince(summaryStart) * 1000),
                isError: true
            )
            return fallbackPrunedContextSummary(plan: plan, compressedIndices: compressedIndices, sourceMessages: sourceMessages)
        }
    }

    func disabledMaintenanceToolInteraction(
        assistantMessage: AssistantToolCallMessage,
        calls: [ToolCall],
        reason: String
    ) -> ToolInteraction {
        let escaped = reason
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // A refusal is a result the model actually receives: it carries the
        // delivery time like any executed batch, and the round its receipt time.
        let refusedAt = HarnessClock.now()
        var issued = assistantMessage
        issued.issuedAt = refusedAt
        let results = calls.map { call in
            var result = ToolResultMessage(
                toolCallId: call.id,
                content: "{\"error\":\"\(escaped)\"}"
            )
            result.completedAt = refusedAt
            return result
        }
        return ToolInteraction(assistantMessage: issued, results: results)
    }

    func fallbackPrunedContextSummary(
        plan: PrunePlan,
        compressedIndices: [Int],
        sourceMessages: [Message]
    ) -> String? {
        var lines: [String] = []
        for index in plan.affectedIndices {
            guard sourceMessages.indices.contains(index) else { continue }
            let message = sourceMessages[index]
            let tools = message.toolInteractions.flatMap { $0.assistantMessage.toolCalls.map { $0.function.name } }
            if !tools.isEmpty {
                lines.append("Turn \(index + 1): pruned tool interactions: \(tools.joined(separator: ", ")).")
            }
            if message.hasUnprunedMedia {
                let files = message.imageFileNames + message.documentFileNames
                    + message.referencedImageFileNames + message.referencedDocumentFileNames
                if !files.isEmpty {
                    lines.append("Turn \(index + 1): pruned inline media: \(files.joined(separator: ", ")).")
                }
            }
        }
        for index in compressedIndices {
            guard sourceMessages.indices.contains(index) else { continue }
            lines.append("Turn \(index + 1): compressed synthetic \(sourceMessages[index].kind.rawValue) message.")
        }
        guard !lines.isEmpty else { return nil }
        return "[Fallback prune summary]\n" + lines.joined(separator: "\n")
    }

    /// Prune stored tool interactions from oldest turns to stay under context budget.
    /// Every historical turn is eligible, newest last; the running turn is not in
    /// `messages`' replay here and is compacted separately only when this cannot help.
    /// Returns true if any pruning occurred (cache was broken).
    func pruneToolInteractionsIfNeeded(
        currentUserMessageId: UUID?,
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem],
        totalChunkCount: Int,
        turnStartDate: Date,
        tools: [ToolDefinition],
        deferredMCPSummaries: [(name: String, description: String, toolCount: Int)],
        execution: ProviderExecutionContext? = nil,
        persona: PromptPersona? = nil
    ) async throws -> Bool {
        let maxTokens = configuredMaxContextTokens()
        let targetTokens = configuredTargetContextTokens()
        let mandatoryEstimate = try await openRouterService.activeTurnRequestEstimate(messages: [], rounds: [],
            images: imagesDirectory, documents: documentsDirectory, tools: tools,
            calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
            totalChunks: totalChunkCount, date: turnStartDate, deferred: deferredMCPSummaries,
            persona: persona)
        let providerIsLMStudio = currentProviderIsLMStudio()

        // Use real prompt_tokens from API when available, fall back to estimation
        // (§4.4: only a measurement taken under this composition).
        let summaryLimit = KeepSummariesSetting.current()
        let decisionView = PruneSummaryRetention.compose(messages, limit: summaryLimit)
        var totalTokens: Int
        if let real = promptMeasurement(for: decisionView) {
            let addedSinceLastPrompt = estimatedTokensAddedSinceLastPrompt(currentUserMessageId: currentUserMessageId, isLMStudio: providerIsLMStudio, in: decisionView.messages)
            totalTokens = real + addedSinceLastPrompt
            print("[ConversationManager] Using real prompt_tokens: \(real) + ~\(addedSinceLastPrompt) new tokens")
        } else {
            totalTokens = mandatoryEstimate.tokens
            for message in decisionView.messages {
                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)
                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
            }
            print("[ConversationManager] Using estimated tokens: \(totalTokens)")
        }

        // Calculate prunable savings — use measured data when available
        var prunableToolTokens = 0
        var prunableMediaTokens = 0
        for message in messages {
            if message.role == .assistant
                && (!message.toolInteractions.isEmpty || message.hasFinalReasoningPayload || message.activeTurnCompaction != nil) {
                prunableToolTokens += toolTokensForMessage(message, isLMStudio: providerIsLMStudio)
                    + estimatedFinalReasoningTokens(message)
                    + (message.activeTurnCompaction.map { ActiveTurnBudget.text($0.promptText) } ?? 0)
            }
            if message.hasUnprunedMedia {
                prunableMediaTokens += mediaSavingsForMessage(message, isLMStudio: providerIsLMStudio)
            }
        }

        guard totalTokens > maxTokens else {
            print("[ConversationManager] Context budget OK: ~\(totalTokens) tokens <= \(maxTokens)")
            return false
        }

        // Skip if nothing is prunable
        guard prunableToolTokens > 0 || prunableMediaTokens > 0 || !compressibleUserMessageIndices(upToIndex: max(0, messages.count - 1), in: messages).isEmpty else {
            print("[ConversationManager] Context budget exceeded (~\(totalTokens) > \(maxTokens)) but nothing prunable — skipping")
            return false
        }

        print("[ConversationManager] Context budget exceeded: ~\(totalTokens) tokens > \(maxTokens). Pruning to ~\(targetTokens)...")

        let pruneActivityId = beginMaintenance(.pruning)
        defer { endMaintenance(pruneActivityId) }

        let plannedSource = messages
        let plan = buildPrunePlan(
            for: plannedSource,
            totalTokens: totalTokens,
            targetTokens: targetTokens,
            protectedIndex: nil,
            providerIsLMStudio: providerIsLMStudio
        )

        // Compress synthetic messages up to the same boundary the pruning loop
        // reached, but never the triggering message — it will be compressed on
        // the next pruning event after the model has seen and responded to it.
        let safeBoundary = min(plan.pruningBoundary, max(messages.count - 1, 0))
        let compressedIndices = compressibleUserMessageIndices(upToIndex: safeBoundary, in: messages)

        await notifyAutomaticPruningStarted(
            plan: plan,
            compressedCount: compressedIndices.count,
            totalTokens: totalTokens,
            targetTokens: targetTokens,
            isMidLoop: false
        )

        _ = try await commitPrune(plan: plan, compressedIndices: compressedIndices, safeBoundary: safeBoundary,
                source: plannedSource, trigger: "automatic") { snapshotForSummary in
                await generatePrunedContextSummary(
            plan: plan,
            compressedIndices: compressedIndices,
            sourceMessages: snapshotForSummary,
            tools: tools,
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries,
            totalChunkCount: totalChunkCount,
            currentUserMessageId: currentUserMessageId,
            turnStartDate: turnStartDate,
            deferredMCPSummaries: deferredMCPSummaries, execution: execution,
            persona: persona, summaryLimit: summaryLimit
        )
            }
        return !plan.actions.isEmpty || !compressedIndices.isEmpty
    }

    /// Mid-loop variant: prunes stored tool interactions from historical turns when the
    /// current turn's growing context would exceed the budget. Only touches historical
    /// messages (messagesForLLM), never the current turn's in-memory toolInteractions.
    /// Every historical turn is eligible, oldest first; the previous turn goes before
    /// the running turn's own rounds are compacted (see compactActiveTurn).
    func pruneStoredToolInteractionsMidLoop(
        messagesForLLM: inout [Message],
        currentTurnInteractions: [ToolInteraction],
        calendarContext: String?,
        emailContext: String?,
        chunkSummaries: [ArchivedSummaryItem],
        totalChunkCount: Int,
        currentUserMessageId: UUID?,
        turnStartDate: Date,
        tools: [ToolDefinition],
        deferredMCPSummaries: [(name: String, description: String, toolCount: Int)],
        execution: ProviderExecutionContext? = nil,
        persona: PromptPersona? = nil
    ) async throws -> MidLoopPruneResult {
        let maxTokens = configuredMaxContextTokens()
        let targetTokens = configuredTargetContextTokens()
        let mandatoryEstimate = try await openRouterService.activeTurnRequestEstimate(messages: [], rounds: [],
            images: imagesDirectory, documents: documentsDirectory, tools: tools,
            calendar: calendarContext, email: emailContext, summaries: chunkSummaries,
            totalChunks: totalChunkCount, date: turnStartDate, deferred: deferredMCPSummaries,
            persona: persona)
        let providerIsLMStudio = currentProviderIsLMStudio()

        // Use real prompt_tokens when available, fall back to estimation
        // (§4.4: only a measurement taken under this composition).
        let summaryLimit = KeepSummariesSetting.current()
        let decisionView = PruneSummaryRetention.compose(messagesForLLM, limit: summaryLimit)
        var totalTokens: Int
        if let real = promptMeasurement(for: decisionView) {
            let unsentInteractionTokens = currentTurnInteractions.last.map { currentTurnInteractionTokens($0, isLMStudio: providerIsLMStudio) } ?? 0
            totalTokens = real + unsentInteractionTokens
        } else {
            totalTokens = mandatoryEstimate.tokens
            for message in decisionView.messages {
                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)
                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
            }
            totalTokens += currentTurnInteractions.reduce(0) { $0 + currentTurnInteractionTokens($1, isLMStudio: providerIsLMStudio) }
        }
        var prunableToolTokens = 0
        var prunableMediaTokens = 0
        for message in messagesForLLM {
            if message.role == .assistant
                && (!message.toolInteractions.isEmpty || message.hasFinalReasoningPayload || message.activeTurnCompaction != nil) {
                prunableToolTokens += toolTokensForMessage(message, isLMStudio: providerIsLMStudio)
                    + estimatedFinalReasoningTokens(message)
                    + (message.activeTurnCompaction.map { ActiveTurnBudget.text($0.promptText) } ?? 0)
            }
            if message.hasUnprunedMedia {
                prunableMediaTokens += mediaSavingsForMessage(message, isLMStudio: providerIsLMStudio)
            }
        }

        guard totalTokens > maxTokens else { return .underBudget }
        guard prunableToolTokens > 0 || prunableMediaTokens > 0 || !compressibleUserMessageIndices(upToIndex: max(0, messagesForLLM.count - 1), in: messagesForLLM).isEmpty else {
            print("[ConversationManager] Mid-loop context exceeded (~\(totalTokens) > \(maxTokens)) but nothing prunable — exhausted")
            return .exhausted
        }

        print("[ConversationManager] Mid-loop context exceeded: ~\(totalTokens) > \(maxTokens). Pruning...")

        let pruneActivityId = beginMaintenance(.pruning)
        defer { endMaintenance(pruneActivityId) }

        let plannedSource = messagesForLLM
        let plan = buildPrunePlan(
            for: plannedSource,
            totalTokens: totalTokens,
            targetTokens: targetTokens,
            protectedIndex: nil,
            providerIsLMStudio: providerIsLMStudio
        )

        // Compress synthetic messages up to the same boundary the pruning loop
        // reached, but never the triggering message — it will be compressed on
        // the next pruning event after the model has seen and responded to it.
        let safeBoundary = min(plan.pruningBoundary, max(messages.count - 1, 0))
        let compressedIndices = compressibleUserMessageIndices(upToIndex: safeBoundary, in: messagesForLLM)

        await notifyAutomaticPruningStarted(
            plan: plan,
            compressedCount: compressedIndices.count,
            totalTokens: totalTokens,
            targetTokens: targetTokens,
            isMidLoop: true
        )

        let oldMetadataTokens = decisionView.messages.reduce(0) { $0 + prunedContextSummaryTokens(for: $1) + $1.renderedPruneArchiveReferences.reduce(0) { $0 + $1.promptText.count / 4 } }
        messagesForLLM = try await commitPrune(plan: plan, compressedIndices: compressedIndices, safeBoundary: safeBoundary,
                source: plannedSource, currentRounds: currentTurnInteractions, trigger: "mid-turn") { snapshotForSummary in
                await generatePrunedContextSummary(
            plan: plan,
            compressedIndices: compressedIndices,
            sourceMessages: snapshotForSummary,
            currentTurnInteractions: currentTurnInteractions,
            tools: tools,
            calendarContext: calendarContext,
            emailContext: emailContext,
            chunkSummaries: chunkSummaries,
            totalChunkCount: totalChunkCount,
            currentUserMessageId: currentUserMessageId,
            turnStartDate: turnStartDate,
            deferredMCPSummaries: deferredMCPSummaries, execution: execution,
            persona: persona, summaryLimit: summaryLimit
        )
            }
        totalTokens -= plan.savedTokens
        totalTokens += PruneSummaryRetention.compose(messagesForLLM, limit: summaryLimit).messages.reduce(0) { $0 + prunedContextSummaryTokens(for: $1) + $1.renderedPruneArchiveReferences.reduce(0) { $0 + $1.promptText.count / 4 } } - oldMetadataTokens
        let anyPruned = !plan.actions.isEmpty || !compressedIndices.isEmpty
        // If we pruned but context is STILL over budget, report exhausted so the
        // caller can force a response rather than looping indefinitely.
        if totalTokens > maxTokens {
            print("[ConversationManager] Mid-loop pruning insufficient: ~\(totalTokens) still > \(maxTokens) — exhausted")
            return .exhausted
        }

        return anyPruned ? .pruned : .underBudget
    }

    /// Deletes snapshotted tool-output bytes that are no longer referenced by the
    /// active conversation. This never follows `sourcePath` and never removes
    /// anything outside Briglia's managed `tool_attachments` cache directory.
    func cleanupOrphanedToolAttachmentSnapshots(additionalLiveInteractions: [ToolInteraction] = []) {
        let fm = FileManager.default
        let dir = toolAttachmentsDirectory
        guard let snapshotFiles = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let liveSnapshotPaths = liveToolAttachmentSnapshotPaths(additionalLiveInteractions: additionalLiveInteractions)
        var removedCount = 0

        for url in snapshotFiles {
            guard isManagedToolAttachmentSnapshot(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }

            let path = url.standardizedFileURL.path
            guard !liveSnapshotPaths.contains(path) else { continue }

            do {
                try fm.removeItem(at: url)
                removedCount += 1
            } catch {
                print("[ConversationManager] Failed to remove orphaned tool attachment snapshot \(url.path): \(error)")
            }
        }

        if removedCount > 0 {
            print("[ConversationManager] Removed \(removedCount) orphaned tool attachment snapshot(s)")
        }
    }

    private func liveToolAttachmentSnapshotPaths(additionalLiveInteractions: [ToolInteraction] = []) -> Set<String> {
        var paths = Set<String>()

        for message in messages {
            for interaction in message.toolInteractions {
                collectLiveSnapshotPaths(from: interaction, into: &paths)
            }
        }

        for interaction in additionalLiveInteractions {
            collectLiveSnapshotPaths(from: interaction, into: &paths)
        }

        return paths
    }

    private func collectLiveSnapshotPaths(from interaction: ToolInteraction, into paths: inout Set<String>) {
        for result in interaction.results {
            for reference in result.fileAttachmentReferences {
                guard let snapshotPath = reference.snapshotPath else { continue }
                let url = URL(fileURLWithPath: snapshotPath)
                guard isManagedToolAttachmentSnapshot(url) else { continue }
                paths.insert(url.standardizedFileURL.path)
            }
        }
    }

    private func isManagedToolAttachmentSnapshot(_ url: URL) -> Bool {
        let directoryPath = toolAttachmentsDirectory.standardizedFileURL.path
        let snapshotPath = url.standardizedFileURL.path
        return snapshotPath.hasPrefix(directoryPath + "/")
    }
}
