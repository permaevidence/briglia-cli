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

    /// `/model` — show the active main-agent model (and the OpenCode Go
    /// catalog when applicable), or switch it. The model key is read from
    /// storage on every request, so a switch applies from the next round —
    /// historical reasoning is already tagged per model, so replay stays safe.
    func handleModelCommand(argument: String) async {
        let provider = LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey))
        let modelKey: String
        switch provider {
        case .openRouter: modelKey = KeychainHelper.openRouterModelKey
        case .lmStudio: modelKey = KeychainHelper.lmStudioModelKey
        case .openAICompatible: modelKey = KeychainHelper.openAICompatibleModelKey
        }
        let current = KeychainHelper.load(key: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseURL = KeychainHelper.load(key: KeychainHelper.openAICompatibleBaseURLKey) ?? ""
        let isOpenCode = provider == .openAICompatible && SessionAffinity.isOpenCodeBaseURL(baseURL)

        guard !argument.isEmpty else {
            // Telegram gets buttons for the two curated catalogs (OpenCode
            // Go, ChatGPT subscription); every other provider, and every
            // other channel, gets the text listing below.
            if replyAddress?.kind == .telegram, Self.commandCapture?.isOpen != true,
               let active = ProviderProfiles.activeProfile() {
                let catalog: TelegramCommandMenu.ModelCatalog?
                if isOpenCode, active == .opencode {
                    catalog = .opencode(OpenCodeGo.choices.map {
                        TelegramCommandMenu.ModelChoice(id: $0.id, label: $0.label, textOnly: $0.textOnly)
                    })
                } else if active == .chatgpt {
                    catalog = .chatgpt
                } else if active == .openrouter, provider == .openRouter {
                    catalog = .openrouter(Self.openRouterRows(store: KeychainHelper.loadSnapshot()))
                } else {
                    catalog = nil
                }
                if let catalog {
                    await sendCommandMenu(TelegramCommandMenu.modelMenu(catalog: catalog, profile: active.rawValue, current: current))
                    return
                }
            }
            if provider == .openRouter {
                let store = KeychainHelper.loadSnapshot()
                let effective = OpenRouterPinMap.effectiveORModel(store) ?? current
                var lines = ["Current model: \(effective.isEmpty ? "(not set)" : effective)", "OpenRouter presets (each model remembers its own host):"]
                for (index, row) in Self.openRouterRows(store: store).enumerated() {
                    lines.append("• \(row.id) — \(row.label)\(index == 0 ? " (default)" : "")\(row.id == effective ? "  ← active" : "")\n  \(row.hostClause)")
                }
                lines.append("Switch with /model <model-id> — any OpenRouter model id works (no host pinned automatically for other models). Takes effect from the next message.")
                try? await sendText(lines.joined(separator: "\n"))
                return
            }
            var lines = ["Current model: \(current.isEmpty ? "(not set)" : current)"]
            if isOpenCode {
                lines.append("OpenCode Go catalog:")
                for choice in OpenCodeGo.choices {
                    let tag = choice.textOnly ? "text-only" : "vision"
                    let marker = choice.id == current ? "  ← active" : ""
                    lines.append("• \(choice.id) (\(tag))\(marker)")
                }
            }
            lines.append("Switch with /model <model-id> — takes effect from the next message.")
            try? await sendText(lines.joined(separator: "\n"))
            return
        }

        // Idle guard (same shape as /provider hops): a mid-turn model switch
        // would make the turn's next round replay this turn's reasoning
        // against a different model. Showing the model stays allowed anytime.
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /model \(argument) again when Briglia is idle (or /stop first).")
            return
        }

        if provider == .openRouter {
            await switchOpenRouterModel(argument.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }

        var stored = argument
        var note = ""
        var knownTextOnly: Bool? = nil
        // Capability lookup over the WHOLE known catalog (curated + retired
        // + legacy aliases), not the picker: a retired text-only id typed
        // here still turns OCR preprocessing on, and a legacy alias is
        // stored under its canonical id (Codex R2, 2026-09-19).
        var changes: [String: String?] = [modelKey: stored]
        if isOpenCode, let match = OpenCodeGo.catalogEntry(for: argument) {
            stored = match.id
            changes[modelKey] = stored
            knownTextOnly = match.textOnly
            if match.textOnly {
                changes[KeychainHelper.textOnlyModelEnabledKey] = "true"
                note = " Text-only model: images and scans go through the OCR preprocessor."
            } else {
                changes[KeychainHelper.textOnlyModelEnabledKey] = String?.none
                note = " Vision model: images flow natively."
            }
            if match.id.lowercased() != argument.lowercased() {
                note += " (\"\(argument)\" is the legacy alias; stored as \(match.id).)"
            }
        } else {
            // No catalog for this model: the stored vision flag is kept as-is,
            // so say which image mode stays in effect instead of staying silent.
            note = KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true"
                ? " Text-only mode stays on (images go through the OCR preprocessor); rerun the provider setup to change it."
                : " Vision mode stays on (images flow natively)."
        }
        // OpenCode Go: the protocol follows the model (GPT ids → Responses),
        // so the runtime protocol slot flips in the SAME write as the model,
        // and a stored effort the new transport rejects is replaced rather
        // than left to fail the next request (v0.2.31).
        // Gated on the SAME profile identification the request resolver uses
        // (named OpenCode profile, host inference only pre-profile): a custom
        // profile pointed at an OpenCode host keeps its explicit protocol and
        // its effort untouched (Codex R2, 2026-09-21).
        var adjustedEffort: String?? = nil
        if ProviderProfiles.isOpenCodeRuntime(stored: KeychainHelper.loadSnapshot()) {
            let responses = OpenCodeGo.usesResponses(stored)
            changes[ProviderProfiles.runtimeProtocolKey] = responses ? ProviderWireProtocol.responses.rawValue : String?.none
            if responses { note += " Served over the Responses API." }
            // Same rule every request applies at build time (OpenCodeGo.
            // compatibleEffort); here the stored value is rewritten visibly so
            // /effort shows what actually runs.
            let effort = KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let compatible = OpenCodeGo.compatibleEffort(effort, for: stored)?.lowercased()
            if !effort.isEmpty, compatible != effort {
                changes[KeychainHelper.openAICompatibleReasoningEffortKey] = compatible
                adjustedEffort = .some(compatible)
                if responses {
                    note += compatible.map { " Reasoning effort \"\(effort)\" isn't available on \(stored); set to \($0)." }
                        ?? " Reasoning effort \"\(effort)\" isn't available on \(stored); cleared (endpoint default)."
                } else {
                    note += " Reasoning effort \"\(effort)\" only exists on the Responses API; cleared (endpoint default)."
                }
            }
        }
        // ChatGPT subscription (v0.2.44): the model sets which efforts the
        // endpoint accepts (GPT-6.1 Sol has no none/minimal), so a stored
        // effort the new model rejects is replaced visibly here instead of
        // failing the next request.
        if ProviderProfiles.activeProfile() == .chatgpt {
            let effort = KeychainHelper.load(key: KeychainHelper.openAICompatibleReasoningEffortKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let compatible = ResponsesAdapter.compatibleEffort(effort, model: stored)
            if !effort.isEmpty, compatible != effort {
                changes[KeychainHelper.openAICompatibleReasoningEffortKey] = compatible
                adjustedEffort = .some(compatible)
                note += compatible.map { " Reasoning effort \"\(effort)\" isn't available on \(stored); set to \($0)." }
                    ?? " Reasoning effort \"\(effort)\" isn't available on \(stored); cleared (endpoint default)."
            }
        }
        try? KeychainHelper.saveBatch(changes)
        modelRoutingGeneration += 1
        // Remember the switch in the active provider profile so /provider
        // hops away and back restore it.
        ProviderProfiles.recordModelChange(stored, textOnly: knownTextOnly)
        if let adjustedEffort { ProviderProfiles.recordEffortChange(adjustedEffort) }
        try? await sendText("✅ Model switched to \(stored) — takes effect from the next message.\(note)")
    }

    /// D11 (owner, 2026-10-18): OpenRouter also takes `max` (its validator
    /// lists max|xhigh|high|medium|low|minimal|none); other providers keep
    /// their lists. Sent verbatim as `reasoning.effort`.
    static func effortLevels(for provider: LLMProvider) -> [String] {
        provider == .openRouter && !OpenRouterPinMap.broken(31) ? validReasoningEfforts + ["max"] : validReasoningEfforts
    }

    /// `/effort` — show or set the main agent's reasoning effort.
    func handleEffortCommand(argument: String) async {
        let provider = LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey))
        let effortKey: String
        let defaultDescription: String
        switch provider {
        case .openRouter:
            effortKey = KeychainHelper.openRouterReasoningEffortKey
            defaultDescription = "high (default)"
        case .openAICompatible:
            effortKey = KeychainHelper.openAICompatibleReasoningEffortKey
            defaultDescription = "not sent (endpoint default)"
        case .lmStudio:
            try? await sendText("The local-endpoint provider doesn't take a reasoning-effort setting.")
            return
        }
        let current = KeychainHelper.load(key: effortKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if argument.isEmpty, replyAddress?.kind == .telegram, Self.commandCapture?.isOpen != true,
           let active = ProviderProfiles.activeProfile() {
            let levels = ProviderProfiles.usesResponses
                ? ResponsesAdapter.allowedEfforts(model: KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) ?? "")
                : Self.effortLevels(for: provider)
            await sendCommandMenu(TelegramCommandMenu.effortMenu(
                levels: levels,
                context: TelegramCommandMenu.effortContext(profile: ProviderProfiles.menuContextIdentity() ?? active.rawValue, model: currentMainModel()),
                current: current,
                currentDescription: current.isEmpty ? defaultDescription : current,
                offAllowed: provider == .openAICompatible))
            return
        }
        if argument.isEmpty && ProviderProfiles.usesResponses {
            let allowed = ResponsesAdapter.allowedEfforts(model: KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) ?? "")
            try? await sendText("Current reasoning effort: \(current.isEmpty ? defaultDescription : current)\nSet with /effort \(allowed.joined(separator: "|")), or /effort off to use the endpoint default.")
            return
        }
        guard !argument.isEmpty else {
            try? await sendText("""
                Current reasoning effort: \(current.isEmpty ? defaultDescription : current)
                Set with /effort \(Self.effortLevels(for: provider).joined(separator: "|"))\(provider == .openAICompatible ? ", or /effort off to send none" : "")
                """)
            return
        }

        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("A turn is running — change /effort when Briglia is idle, or /stop first.")
            return
        }

        let requested = argument.lowercased()
        if requested == "off", provider == .openAICompatible {
            try? KeychainHelper.delete(key: effortKey)
            ProviderProfiles.recordEffortChange(nil)
            try? await sendText("✅ Reasoning effort cleared — the endpoint's default applies from the next message.")
            return
        }
        let allowedEfforts = ProviderProfiles.usesResponses
            ? ResponsesAdapter.allowedEfforts(model: KeychainHelper.load(key: KeychainHelper.openAICompatibleModelKey) ?? "")
            : Self.effortLevels(for: provider)
        guard allowedEfforts.contains(requested) else {
            let message = ProviderProfiles.usesResponses
                ? "Unknown effort \"\(argument)\" — use \(allowedEfforts.joined(separator: ", "))."
                : "Unknown effort \"\(argument)\" — use \(allowedEfforts.dropLast().joined(separator: ", ")) or \(allowedEfforts.last ?? "high")."
            try? await sendText(message)
            return
        }
        try? KeychainHelper.save(key: effortKey, value: requested)
        ProviderProfiles.recordEffortChange(requested)
        try? await sendText("✅ Reasoning effort set to \(requested) — takes effect from the next message.")
    }

    /// `/subagentmodels` — show or configure the cheap subagent model lanes
    /// for the ACTIVE provider (each provider keeps its own picks). The main
    /// agent's Agent tool then offers 'inherit' plus exactly the configured
    /// lanes; either lane alone is fine.
    ///   /subagentmodels                       → status + catalog + usage
    ///   /subagentmodels vision <model-id>     → set the cheap vision lane
    ///   /subagentmodels text <model-id>       → set the cheap text-only lane
    ///   /subagentmodels vision|text off       → clear one lane
    ///   /subagentmodels off                   → clear both lanes
    func handleSubagentModelsCommand(argument: String) async {
        let provider = SubagentModelLanes.activeProvider()
        let baseURL = KeychainHelper.load(key: KeychainHelper.openAICompatibleBaseURLKey) ?? ""
        let isOpenCode = provider == .openAICompatible && SessionAffinity.isOpenCodeBaseURL(baseURL)

        let bypassed = SubagentModelLanes.hostPinBypass(provider: provider)
        let bypassNote = "⚠️ Bypassed while the OpenRouter host pin is set (/orprovider): every subagent runs the main model on the pinned host. /orprovider off restores the lanes."
        func laneStatus(_ lane: SubagentModelLane) -> String {
            let model = SubagentModelLanes.storedModel(lane, provider: provider)
            return "• \(lane.rawValue) (\(lane.displayName)): \(model ?? "not set")\(model != nil && bypassed ? " — bypassed" : "")"
        }

        guard !argument.isEmpty else {
            var lines = [
                "Cheap subagent model lanes for \(provider.displayName):",
                laneStatus(.cheapVision),
                laneStatus(.cheapText),
            ]
            if bypassed { lines.append(bypassNote) }
            lines.append(contentsOf: [
                "",
                "The agent sees 'inherit' plus the configured lanes when delegating to subagents (and for watcher triage via triage_model). Configuring even one lane is fine.",
                "Set:   /subagentmodels vision <model-id>  |  /subagentmodels text <model-id>",
                "Clear: /subagentmodels vision off  |  /subagentmodels text off  |  /subagentmodels off"
            ])
            if isOpenCode {
                lines.append("")
                lines.append("OpenCode Go catalog:")
                for choice in OpenCodeGo.choices {
                    lines.append("• \(choice.id) (\(choice.textOnly ? "text-only" : "vision"))")
                }
            }
            try? await sendText(lines.joined(separator: "\n"))
            return
        }

        let parts = argument.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count == 1, parts[0].lowercased() == "off" {
            do {
                try SubagentModelLanes.setModel(.cheapVision, model: nil, provider: provider)
                try SubagentModelLanes.setModel(.cheapText, model: nil, provider: provider)
                try? await sendText("✅ Both cheap lanes cleared for \(provider.displayName) — subagents only inherit your model now.")
            } catch {
                try? await sendText("✖ Could not save the setting: \(error.localizedDescription)")
            }
            return
        }
        guard parts.count == 2 else {
            try? await sendText("Usage: /subagentmodels [vision|text] [<model-id>|off], or /subagentmodels off to clear both.")
            return
        }
        let lane: SubagentModelLane
        switch parts[0].lowercased() {
        case "vision", "cheap-vision": lane = .cheapVision
        case "text", "cheap-text", "textonly", "text-only": lane = .cheapText
        default:
            try? await sendText("Unknown lane \"\(parts[0])\" — use 'vision' or 'text'.")
            return
        }
        let value = parts[1]
        if value.lowercased() == "off" {
            do {
                try SubagentModelLanes.setModel(lane, model: nil, provider: provider)
                try? await sendText("✅ The \(lane.displayName) lane is cleared for \(provider.displayName).")
            } catch {
                try? await sendText("✖ Could not save the setting: \(error.localizedDescription)")
            }
            return
        }

        var stored = value
        var note = bypassed ? " " + bypassNote : ""
        // Whole known catalog (curated + retired + aliases): a retired
        // text-only model stays refused in the vision lane (Codex R2).
        if isOpenCode, let match = OpenCodeGo.catalogEntry(for: value) {
            if lane == .cheapVision && match.textOnly {
                try? await sendText("✖ \(match.id) is text-only on the Go gateway — it can't serve the vision lane. Put it in the text lane (/subagentmodels text \(match.id)) or pick a vision-capable model.")
                return
            }
            stored = match.id
            if lane == .cheapText && !match.textOnly {
                note += " Note: \(match.id) is vision-capable, but the text lane always OCR-preprocesses images — a vision model there works, it just wastes its vision."
            }
        } else if isOpenCode {
            // Outside the known catalog (a newer id the Go gateway serves):
            // accept as typed, exactly like /model does, and say what could
            // not be checked.
            note += lane == .cheapVision
                ? " Not in the OpenCode catalog — make sure the Go gateway serves it and that it accepts images; the vision lane sends them natively."
                : " Not in the OpenCode catalog — make sure the Go gateway serves it."
        } else if lane == .cheapVision {
            note += " Make sure this model actually accepts images — the vision lane sends them natively."
        }
        do {
            try SubagentModelLanes.setModel(lane, model: stored, provider: provider)
            try? await sendText("✅ The \(lane.displayName) lane for \(provider.displayName) is now \(stored) — the agent sees it as '\(lane.rawValue)' from the next message.\(note)")
        } catch {
            try? await sendText("✖ Could not save the setting: \(error.localizedDescription)")
        }
    }

    /// The OpenRouter picker rows (presets + host clause) for one snapshot.
    static func openRouterRows(store: [String: String]) -> [TelegramCommandMenu.OpenRouterRow] {
        OpenRouterPresets.all.map { preset in
            TelegramCommandMenu.OpenRouterRow(key: preset.key, id: preset.id, label: preset.label,
                hostClause: OpenRouterPresets.hostClause(OpenRouterPresets.hostStatus(model: preset.id, store: store)))
        }
    }

    /// Why an OpenRouter routing decision taken before an await may no
    /// longer be committed (early exit; the guarded transaction is the
    /// authoritative check).
    private func openRouterAwaitStaleReason(generation: Int) -> String? {
        if Task.isCancelled { return "the command was cancelled" }
        if activeRunId != nil || activeProcessingTask != nil { return "a turn started while checking OpenRouter's host list" }
        if modelRoutingGeneration != generation { return "the routing settings changed while checking OpenRouter's host list" }
        return nil
    }

    /// `/model <id>` on OpenRouter: host list first (only when the
    /// destination needs it), then ONE guarded write of model + both vision
    /// slots + the destination's per-model host (plan §5).
    private func switchOpenRouterModel(_ destination: String) async {
        guard OpenRouterPinMap.isValidModelID(destination) else {
            try? await sendText("✖ \"\(destination)\" is not an OpenRouter model id (vendor/model, no spaces). Nothing changed.")
            return
        }
        let store = KeychainHelper.loadSnapshot()
        let expected = OpenRouterPinMap.RoutingBasis.of(store)
        if expected.effectiveModel != destination, let pending = OpenRouterPinMap.pendingLegacy(store) {
            try? await sendText("✖ " + (OpenRouterProviderPin.PendingLegacyRefusal(pending: pending).errorDescription ?? ""))
            return
        }
        let generation = modelRoutingGeneration
        let listing: OpenRouterProviderPin.HostListing?
        do {
            listing = try await OpenRouterProviderPin.listingIfNeeded(store: store, newModel: destination,
                                                                      apiKey: store[KeychainHelper.openRouterApiKeyKey], presetHostPin: true)
        } catch {
            try? await sendText("✖ Not switched: the host check was cancelled. Nothing changed — send /model \(destination) again.")
            return
        }
        if let reason = openRouterAwaitStaleReason(generation: generation) {
            try? await sendText("✖ Not switched: \(reason). Nothing changed — send /model \(destination) again.")
            return
        }
        let preset = OpenRouterPresets.preset(forModel: destination)
        let outcome: OpenRouterProviderPin.PinOutcome
        do {
            outcome = try OpenRouterProviderPin.commitModelChange(destination: destination, textOnly: preset != nil ? false : nil,
                                                                 listing: listing, expected: expected)
        } catch let refusal as OpenRouterProviderPin.PendingLegacyRefusal {
            try? await sendText("✖ " + (refusal.errorDescription ?? ""))
            return
        } catch let stale as OpenRouterProviderPin.StaleBasis {
            try? await sendText("✖ Not switched: \(stale.reason). Nothing changed — send /model \(destination) again.")
            return
        } catch {
            try? await sendText("✖ Could not save the setting: \(error.localizedDescription)")
            return
        }
        modelRoutingGeneration += 1
        let visionNote: String
        if preset != nil {
            visionNote = " Vision model: images flow natively."
        } else {
            visionNote = KeychainHelper.load(key: KeychainHelper.textOnlyModelEnabledKey) == "true"
                ? " Text-only mode stays on (images go through the OCR preprocessor); rerun the provider setup to change it."
                : " Vision mode stays on (images flow natively)."
        }
        let same = expected.effectiveModel == destination
        let lead = same ? "✅ \(destination) is already the model in use." : "✅ Model switched to \(destination) — takes effect from the next message."
        var tail = outcome.chatNote
        if same, let host = preset?.autoHostName, OpenRouterPresets.hostStatus(model: destination, store: KeychainHelper.loadSnapshot()).state == .autoUnavailable {
            tail += " \(host) isn't pinned for it yet: /orprovider default applies it."
        }
        try? await sendText(lead + visionNote + tail)
    }

    /// `/orprovider` — show, pin or release the upstream host OpenRouter
    /// routes the CURRENT model to. Since v0.2.56 each OpenRouter model
    /// remembers its own host (`OpenRouterPinMap`); every write is one
    /// guarded transaction against the basis read before any await.
    func handleOrProviderCommand(argument: String) async {
        let provider = LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey))
        var store = KeychainHelper.loadSnapshot()
        guard provider == .openRouter, ProviderProfiles.activeProfile() == .openrouter else {
            let active = ProviderProfiles.activeProfile()?.displayName ?? provider.displayName
            try? await sendText("The OpenRouter host pin only applies to the OpenRouter provider — active provider: \(active). Each OpenRouter model keeps its saved host for when OpenRouter is active again.")
            return
        }
        guard let model = OpenRouterPinMap.effectiveORModel(store) else {
            try? await sendText("No OpenRouter model is set — pick one with /model first.")
            return
        }
        let apiKey = store[KeychainHelper.openRouterApiKeyKey] ?? ""
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = words.first?.lowercased() ?? ""
        let pinned = OpenRouterProviderPin.pinnedSlugs(store: store)
        let clause = OpenRouterPresets.hostClause(OpenRouterPresets.hostStatus(model: model, store: store))

        if trimmed.isEmpty {
            let endpoints: [OpenRouterProviderPin.Endpoint]
            do {
                endpoints = try await OpenRouterProviderPin.fetchEndpoints(model: model, apiKey: apiKey)
            } catch is CancellationError {
                try? await sendText("\(model) — \(clause)\nThe host listing was cancelled — send /orprovider again.")
                return
            } catch {
                try? await sendText("\(model) — \(clause)\nCouldn't list the hosts for \(model): \(error). Pin with /orprovider <slug>, /orprovider off lets OpenRouter choose, /orprovider default returns to Briglia's host.")
                return
            }
            store = KeychainHelper.loadSnapshot()
            guard OpenRouterPinMap.effectiveORModel(store) == model else {
                try? await sendText("The model changed while listing the hosts for \(model) — send /orprovider again.")
                return
            }
            let choices = OpenRouterProviderPin.baseChoices(endpoints)
            let currentPin = OpenRouterProviderPin.pinnedSlugs(store: store)
            if replyAddress?.kind == .telegram, Self.commandCapture?.isOpen != true, !choices.isEmpty {
                let context = TelegramCommandMenu.effortContext(profile: ProviderProfiles.Profile.openrouter.rawValue, model: model)
                await sendCommandMenu(TelegramCommandMenu.orProviderMenu(model: model, choices: choices, context: context, pinned: currentPin))
                return
            }
            var lines = ["\(model) — \(OpenRouterPresets.hostClause(OpenRouterPresets.hostStatus(model: model, store: store)))",
                         "Hosts serving \(model) (cheapest standard endpoint's figures; a base slug allows every endpoint of that host):"]
            for endpoint in choices {
                let isPinned = currentPin.contains { OpenRouterProviderPin.matches(pin: $0, endpoint: endpoint) }
                lines.append("• \(OpenRouterProviderPin.describe(endpoint, pinned: isPinned))")
            }
            let tierOnly = endpoints.filter { OpenRouterProviderPin.tier(of: $0) != nil }.map(\.tag)
            if !tierOnly.isEmpty { lines.append("Service-tier endpoints (pin by full tag only): \(tierOnly.joined(separator: ", "))") }
            if choices.isEmpty { lines.append("• (OpenRouter lists no standard hosts for this model)") }
            lines.append("Pin with /orprovider <slug> (a full tag like deepinfra/turbo targets one variant); /orprovider off lets OpenRouter choose; /orprovider default returns to Briglia's host; /orprovider remembered lists the saved hosts. \(OpenRouterProviderPin.scopeNote) Takes effect from the next message.")
            try? await sendText(lines.joined(separator: "\n"))
            return
        }

        if verb == "remembered" {
            guard let map = OpenRouterPinMap.state(store).map else {
                try? await sendText(OpenRouterPinMap.state(store) == .absent ? "No OpenRouter host choices are saved yet." : clause)
                return
            }
            let rows = map.models.sorted { $0.key < $1.key }.map { id, entry -> String in
                let what = entry.hosts.isEmpty ? (entry.by == .released ? "automatic (\((entry.was ?? []).joined(separator: ", ")) stopped serving it)" : "automatic (your choice)")
                    : "\(entry.hosts.joined(separator: ", ")) (\(entry.by == .preset ? "Briglia's host" : "your choice"))"
                return "• \(id): \(what)\(id == model ? "  ← current" : "")"
            }
            try? await sendText((["Saved OpenRouter hosts (\(map.nonCatalogRememberedCount)/\(OpenRouterPinMap.maxNonCatalogRemembered) non-preset models):"] + (rows.isEmpty ? ["• none"] : rows) + ["Forget one with /orprovider forget <model-id>."]).joined(separator: "\n"))
            return
        }

        // Writes: idle guard (the pin changes where the next round would go).
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /orprovider \(trimmed) again when Briglia is idle (or /stop first).")
            return
        }
        let expected = OpenRouterPinMap.RoutingBasis.of(store)
        let generation = modelRoutingGeneration

        func commit(_ target: String, _ choice: OpenRouterProviderPin.HostChoice, _ listing: OpenRouterProviderPin.HostListing?) async -> OpenRouterProviderPin.HostCommit? {
            if let reason = openRouterAwaitStaleReason(generation: generation) {
                try? await sendText("✖ Not changed: \(reason). Nothing changed — send /orprovider \(trimmed) again.")
                return nil
            }
            do {
                let result = try OpenRouterProviderPin.commitHostChoice(model: target, choice: choice, listing: listing, expected: expected)
                modelRoutingGeneration += 1
                return result
            } catch let stale as OpenRouterProviderPin.StaleBasis {
                try? await sendText("✖ Not changed: \(stale.reason). Nothing changed — send /orprovider \(trimmed) again.")
            } catch {
                try? await sendText("✖ Could not save the setting: \(error.localizedDescription)")
            }
            return nil
        }
        func recoveredNote(_ r: OpenRouterProviderPin.HostCommit) -> String {
            r.recovered ? " (The old saved hosts were unreadable; they were backed up and replaced.)" : ""
        }

        if verb == "forget" {
            let target = words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""
            guard OpenRouterPinMap.isValidModelID(target) else {
                try? await sendText("Usage: /orprovider forget <model-id> (see /orprovider remembered).")
                return
            }
            guard let r = await commit(target, .forget, nil) else { return }
            try? await sendText("✅ Forgot the saved host for \(target)." + recoveredNote(r) + (target == model ? " Briglia's preset rules apply to it from the next model switch." : ""))
            return
        }

        if ["off", "auto", "automatic", "none", "clear"].contains(trimmed.lowercased()) {
            guard let r = await commit(model, .automatic, nil) else { return }
            try? await sendText("✅ OpenRouter chooses the host for \(model) from the next message (remembered for this model; Briglia's own default host for the Gemini default model still applies). Subagent cheap lanes, if configured, are back in use." + recoveredNote(r) + (pinned.isEmpty ? "" : " Released: \(pinned.joined(separator: ", "))."))
            return
        }

        if trimmed.lowercased() == "default" {
            let preset = OpenRouterPresets.preset(forModel: model)
            var listing: OpenRouterProviderPin.HostListing?
            if preset?.autoHost != nil {
                do { listing = try await OpenRouterProviderPin.hostListing(model: model, apiKey: apiKey) } catch {
                    try? await sendText("✖ Not changed: the host check was cancelled. Nothing changed — send /orprovider default again.")
                    return
                }
            }
            guard let r = await commit(model, .reset, listing) else { return }
            let text: String
            switch r.outcome {
            case .pinnedPreset(_, let slug): text = "✅ \(model) runs on \(OpenRouterPresets.hostName(slug)) again (Briglia's host)."
            case .presetSkipped(_, let reason): text = "⚠️ Briglia's host \(preset?.autoHostName ?? "") was NOT pinned (\(reason)), so OpenRouter chooses the host for \(model). Send /orprovider default again later."
            default: text = "✅ \(model) has no saved host now; OpenRouter chooses the host (no Briglia host for this model)."
            }
            try? await sendText(text + recoveredNote(r))
            return
        }

        var slugs: [String] = []
        for item in trimmed.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }) where !item.isEmpty {
            guard let slug = OpenRouterProviderPin.normalizedSlug(item) else {
                try? await sendText("✖ \"\(item)\" is not an OpenRouter provider slug (letters, digits, . _ - and / for a variant, e.g. deepinfra or deepinfra/turbo). Nothing changed.")
                return
            }
            slugs.append(slug)
        }
        guard !slugs.isEmpty, slugs.count <= OpenRouterPinMap.maxHosts else {
            try? await sendText("Usage: /orprovider <slug>[,<slug>] (up to \(OpenRouterPinMap.maxHosts)), /orprovider off, /orprovider default, /orprovider remembered, /orprovider forget <model-id>.")
            return
        }
        var verification = ""
        do {
            let endpoints = try await OpenRouterProviderPin.fetchEndpoints(model: model, apiKey: apiKey)
            var served: [String] = []
            for slug in slugs {
                switch OpenRouterProviderPin.validate(pin: slug, endpoints: endpoints) {
                case .served(let hits):
                    served.append(hits.map(\.tag).joined(separator: ", "))
                case .uncertain(let hits):
                    served.append(hits.map(\.tag).joined(separator: ", ") + " (unverified: service-tier endpoint)")
                case .notServed(let available):
                    try? await sendText("✖ OpenRouter does not serve \(model) from \"\(slug)\". Hosts: \(available.joined(separator: ", ")). Nothing changed.")
                    return
                }
            }
            verification = " Serving \(model) via \(served.joined(separator: "; "))."
        } catch {
            if OpenRouterProviderPin.isCancellation(error) || Task.isCancelled {
                try? await sendText("✖ Not pinned: the host check was cancelled. Nothing changed — send /orprovider \(trimmed) again.")
                return
            }
            verification = " (Couldn't verify against OpenRouter's host list: \(error) — saved anyway.)"
        }
        guard let r = await commit(model, .pin(slugs), nil) else { return }
        let lanes = SubagentModelLanes.storedModel(.cheapVision, provider: .openRouter) != nil
            || SubagentModelLanes.storedModel(.cheapText, provider: .openRouter) != nil
        let laneNote = lanes ? " Your subagent cheap lanes are bypassed while pinned (/subagentmodels shows them)." : ""
        try? await sendText("✅ OpenRouter host for \(model) pinned to \(slugs.joined(separator: ", ")) from the next message — main agent and every subagent, the Web researcher included; other models keep their own host.\(verification) A base slug allows every endpoint of that host (price and caching vary per endpoint); requests fail instead of hopping when the host is unavailable. /orprovider off releases it.\(laneNote)" + recoveredNote(r))
    }

    func startUpgradePresetPass() {
        // A finished loop is restarted by a later call (start() is a no-op
        // while one is in flight).
        if let pass = upgradePresetPass, !OpenRouterPinMap.broken(34) { pass.start(); return }
        guard upgradePresetPass == nil else { return }
        let pass = OpenRouterUpgradePass(isIdle: { [weak self] in
            guard let self else { return false }
            return self.activeRunId == nil && self.activeProcessingTask == nil && !self.isTurnActive && !self.browserSettingsMutation
        }, onCommitted: { [weak self] attempt in
            guard let self else { return }
            self.modelRoutingGeneration += 1
            switch attempt {
            case .pinned(let model, let slug):
                self.pendingHostNotice = "📌 Briglia now pins \(OpenRouterPresets.hostName(slug)) for \(model) (new per-model hosts). /orprovider off lets OpenRouter choose."
            case .notServed(let model, let host):
                self.pendingHostNotice = "Briglia's host \(host) doesn't serve \(model) right now, so OpenRouter keeps choosing. /orprovider default retries."
            default: break
            }
            if let notice = self.pendingHostNotice { print("[ConversationManager] \(notice)") }
        }, onMigrated: { [weak self] in
            self?.modelRoutingGeneration += 1
        })
        upgradePresetPass = pass
        pass.start()
    }


    /// `/provider` — list the configured provider profiles, or hop to one.
    /// Hopping is a storage-level activation (runtime slots + per-profile
    /// model/effort/vision restore) plus the in-process reconfiguration the
    /// old /llm_* switches did for OpenRouter's service-held API key.
    /// Device codes are delivered only to the captured paired private chat;
    /// never added to model history or parked for delivery after expiration.
    func handleSubscriptionCommand(argument: String) async {
        let action = argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if action.isEmpty || action == "status" {
            do {
                let state = try SubscriptionAuthStore().read()
                try? await sendText("ChatGPT subscription: " + (state?.requiresLogin == true ? "sign in again" : state?.credential == nil ? "signed out" : "signed in")
                    + (subscriptionLoginTask == nil ? "" : "; login pending")
                    + ". Quota unknown. Separate API tools keep their own billing. Use /subscription login|cancel|logout, then /provider chatgpt.")
            } catch { try? await sendText(error.localizedDescription) }
            return
        }
        guard action == "login" || action == "cancel" || action == "logout" else {
            try? await sendText("Use /subscription login|cancel|logout|status."); return
        }
        guard let address = replyAddress, address.kind == .telegram,
              let paired = pairedChatId, paired > 0, address.chatId == String(paired),
              let channel = channels[.telegram] else {
            try? await sendText("Use briglia subscription login in a terminal, or the paired private Telegram chat."); return
        }
        if action == "cancel" || action == "logout" {
            subscriptionLoginRunID = nil; subscriptionLoginTask?.cancel(); subscriptionLoginTask = nil
            do {
                if action == "logout" {
                    let sentence = SubscriptionSharing.sharingSentence(signOut: true)
                    try await SubscriptionAuthStore().logout()
                    try? await sendText("ChatGPT signed out locally." + (sentence.map { " " + $0 } ?? ""), to: address)
                } else {
                    let outcome = try await SubscriptionAuthStore().cancelOwnedPending()
                    try? await sendText(outcome == .foreign ? SubscriptionSharing.foreignPendingMessage : "ChatGPT login cancelled.", to: address)
                }
            } catch { try? await sendText(error.localizedDescription, to: address) }
            return
        }
        guard !isRestoringMind else { try? await sendText("Wait until the memory operation finishes before signing in.", to: address); return }
        do { try SubscriptionSetup.checkLoginReplacement() } catch {
            try? await sendText(error.localizedDescription, to: address); return
        }
        guard subscriptionLoginTask == nil else { try? await sendText("Login is already pending; use /subscription cancel first.", to: address); return }
        guard activeRunId == nil, activeProcessingTask == nil else { try? await sendText("Start ChatGPT login when Briglia is idle.", to: address); return }
        let runID = UUID(); subscriptionLoginRunID = runID
        subscriptionLoginTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.subscriptionLoginRunID == runID { self.subscriptionLoginTask = nil; self.subscriptionLoginRunID = nil }
            }
            do {
                _ = try await SubscriptionLogin().device { url, code in
                    guard self.subscriptionLoginRunID == runID, self.pairedChatId == paired else { throw CancellationError() }
                    try await channel.sendText(chatId: address.chatId, text: "Sign in to your own ChatGPT account at " + url + "\nCode: " + code + "\nExpires in 15 minutes. No access or refresh token should be sent in chat.")
                }
                try Task.checkCancellation()
                guard self.subscriptionLoginRunID == runID, self.pairedChatId == paired else { throw CancellationError() }
                try ProviderProfiles.saveProfile(.chatgpt, apiKey: nil, baseURL: nil,
                    model: ProviderProfiles.configuredModel(.chatgpt) ?? ResponsesAdapter.subscriptionDefaultModel,
                    effort: ProviderProfiles.configuredEffort(.chatgpt) ?? "high", textOnly: false)
                try await channel.sendText(chatId: address.chatId, text: "ChatGPT login saved. Send /provider chatgpt when idle to activate this login, including if ChatGPT is already selected. If ChatGPT is already selected, turns will keep failing until you send /provider chatgpt.")
            } catch {
                if !Task.isCancelled, self.subscriptionLoginRunID == runID {
                    try? await channel.sendText(chatId: address.chatId, text: "ChatGPT login failed: " + error.localizedDescription)
                }
            }
        }
    }

    func handleProviderCommand(argument: String) async {
        guard replyAddress != nil else { return }
        ProviderProfiles.ensureMigrated()

        guard !argument.isEmpty else {
            if replyAddress?.kind == .telegram, Self.commandCapture?.isOpen != true {
                await sendCommandMenu(TelegramCommandMenu.providerMenu(
                    statusLines: ProviderProfiles.statusLines(), configured: Self.providerChoices()))
                return
            }
            var lines = ["Providers (hop with /provider <name>; a server by its name):"]
            lines.append(contentsOf: ProviderProfiles.statusLines())
            lines.append("Add or edit providers with `briglia setup` (step 1) in a terminal.")
            try? await sendText(lines.joined(separator: "\n"))
            return
        }

        let target = ProviderServers.resolve(argument)
        if case .server(let serverID)? = target {
            await activateNamedServer(serverID)
            return
        }
        guard case .profile(let profile)? = target else {
            let names = ProviderProfiles.Profile.allCases.filter { $0 != .custom && $0 != .local }.map(\.rawValue)
                + (ProviderServers.list() ?? []).map(\.name)
            try? await sendText("Unknown provider \"\(argument)\" — use one of: \(names.joined(separator: ", ")).")
            return
        }
        if ProviderProfiles.activeProfile() == profile,
           !(profile == .chatgpt && KeychainHelper.load(key: KeychainHelper.openAICompatibleApiKeyKey) != KeychainHelper.load(key: ProviderProfiles.subscriptionGenerationKey)) {
            try? await sendText("\(profile.displayName) is already the active provider.")
            return
        }
        // Idle guard (same shape as /restart and /upgrade): the next model
        // round of a running turn would hit the new gateway with the old
        // gateway's tool/reasoning state mid-flight. Listing stays allowed
        // anytime — only the hop needs idleness.
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /provider \(profile.rawValue) again when Briglia is idle (or /stop first).")
            return
        }
        do {
            try ProviderProfiles.activate(profile)
        } catch {
            try? await sendText("✖ \(ProviderProfiles.describeActivationError(error))")
            return
        }
        modelRoutingGeneration += 1

        // OpenRouterService holds the OpenRouter key in memory (set once at
        // startup) — refresh it so a hop works without a restart.
        if profile == .openrouter {
            let apiKey = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await openRouterService.configure(apiKey: apiKey)
            await archiveService.configure(apiKey: apiKey)
        }
        NotificationCenter.default.post(
            name: .adaLLMProviderDidChange,
            object: nil,
            userInfo: ["provider": LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)).rawValue]
        )

        let model = ProviderProfiles.configuredModel(profile) ?? "?"
        var note = ""
        switch ProviderProfiles.textOnly(profile) {
        case .some(true): note = " Text-only model: images and scans go through the OCR preprocessor."
        case .some(false): note = " Vision model: images flow natively."
        case .none: note = ""
        }
        try? await sendText("✅ Active provider: \(profile.displayName) — model \(model). Takes effect from the next message.\(note)\(Self.missingPageReaderWarning(for: profile))")
    }

    /// Round 4: after a switch to a lane whose web-page reading runs on the
    /// OpenAI key (OpenCode Go, a named server) while the page-reading
    /// backend is OpenAI and no key is saved, say so. A warning, not a
    /// refusal: a CLI-configured install may read pages with another
    /// /websearch backend, and the switch itself only moves stored slots
    /// (no request bytes change).
    static func missingPageReaderWarning(for profile: ProviderProfiles.Profile) -> String {
        guard profile == .opencode || profile == .custom || profile == .local,
              WebSearchBackend.configured == .openai,
              WebSearchBackend.storedKey(for: .openai).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "\n⚠️ No OpenAI API key is saved, and web pages are read with OpenAI on this provider, so web research will fail. Add the key in briglia menu (Voice & images), or pick another page-reading backend with /websearch."
    }

    /// The /provider buttons: every configured built-in profile, then every
    /// named server by its name (the local-server / custom-endpoint profiles
    /// are listed as the servers they carry). A server button carries the
    /// server's stable id, so a rename keeps it valid and a removal makes it
    /// stale (refused in `staleMenuReason`).
    static func providerChoices() -> [TelegramCommandMenu.ProviderChoice] {
        let active = ProviderProfiles.activeProfile()
        let store = KeychainHelper.loadSnapshot()
        let activeServer = ProviderServers.activeServer(store)?.id
        let builtIns = ProviderProfiles.Profile.allCases
            .filter { $0 != .custom && $0 != .local && ProviderProfiles.isConfigured($0) }
            .map { TelegramCommandMenu.ProviderChoice(id: $0.rawValue, displayName: $0.displayName, active: $0 == active) }
        let servers = (ProviderServers.list(store) ?? []).map {
            TelegramCommandMenu.ProviderChoice(id: $0.id, displayName: $0.name, active: $0.id == activeServer)
        }
        return builtIns + servers
    }

    /// `/provider <server>`: the same idle guard and follow-up as a profile
    /// hop; the switch itself is one ProviderServers transaction.
    private func activateNamedServer(_ id: String) async {
        let store = KeychainHelper.loadSnapshot()
        guard let server = ProviderServers.list(store)?.first(where: { $0.id == id }) else {
            try? await sendText("✖ That server no longer exists. Send /provider to see the list.")
            return
        }
        if ProviderServers.activeServer(store)?.id == id {
            try? await sendText("\(server.name) is already the active provider.")
            return
        }
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /provider \(server.name) again when Briglia is idle (or /stop first).")
            return
        }
        do {
            try ProviderServers.use(id)
        } catch {
            try? await sendText("✖ \(ProviderServers.describe(error))")
            return
        }
        modelRoutingGeneration += 1
        NotificationCenter.default.post(
            name: .adaLLMProviderDidChange,
            object: nil,
            userInfo: ["provider": LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)).rawValue]
        )
        let note = server.textOnly ? " Text-only model: images and scans go through the OCR preprocessor." : " Vision model: images flow natively."
        try? await sendText("✅ Active provider: \(server.name) — model \(server.model). Takes effect from the next message.\(note)\(Self.missingPageReaderWarning(for: .local))")
    }

    /// `/websearch` — show or switch the backend that READS web pages for
    /// research: page extraction (web_extract, the legacy loop's
    /// fetch_and_extract) and web_fetch compression. The researcher's own
    /// reasoning — and the legacy loop's agent rounds — run on the main
    /// agent's provider, model and effort (owner decision 2026-09-25).
    /// Separate from /provider, with one exception (owner decision
    /// 2026-09-23): while the main provider is the ChatGPT subscription, web
    /// research follows it automatically; the stored choice serves every
    /// other provider. No usage-limit fallback: the main agent is on the same
    /// allowance, so a fallback would only serve an agent that can't answer.
    func handleWebSearchBackendCommand(argument: String) async {
        guard replyAddress != nil else { return }

        guard !argument.isEmpty else {
            let selection = WebSearchBackend.activeSelection
            let active = selection.backend
            // Derived follows (subscription, OpenRouter main provider) win
            // while they hold; the stored choice serves the other providers.
            let follows = active == .chatgpt || selection.followsMainOpenRouter
            var lines = ["Web page-reading backend — page extraction and web_fetch (research itself runs on your main model; switch with /websearch <name>):"]
            if active == .chatgpt {
                lines.append("▸ chatgpt — \(WebSearchBackend.chatgpt.modelSummary)  [ACTIVE: follows /provider chatgpt]")
            } else if selection.followsMainOpenRouter {
                lines.append("▸ openrouter — \(WebSearchBackend.openRouterFollowSummary)  [ACTIVE: follows /provider openrouter]")
            }
            let servingNote = follows ? "  [used on other providers]" : "  [ACTIVE]"
            for backend in WebSearchBackend.selectable {
                let marker = backend == active && !follows ? "▸" : " "
                let key = WebSearchBackend.storedKey(for: backend).isEmpty ? "no key" : "key ✔"
                let isServing = follows ? backend == WebSearchBackend.configured : backend == active
                let activeSuffix = isServing ? servingNote : ""
                lines.append("\(marker) \(backend.rawValue) — \(backend.modelSummary) (\(key))\(activeSuffix)")
            }
            if WebSearchBackend.explicitlyStored == nil {
                lines.append("No explicit choice saved — the active backend is inferred from configured keys.")
            }
            try? await sendText(lines.joined(separator: "\n"))
            return
        }

        let normalized = argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == WebSearchBackend.chatgpt.rawValue {
            try? await sendText("The ChatGPT subscription can't be picked here: web page reading uses it automatically while /provider is chatgpt. /websearch sets the page-reading backend for other providers (openai, opencode, openrouter).")
            return
        }
        guard let backend = WebSearchBackend.parseSelectable(normalized) else {
            try? await sendText("Unknown backend \"\(argument)\" — use one of: openai, opencode, openrouter.")
            return
        }
        guard !WebSearchBackend.storedKey(for: backend).isEmpty else {
            let hint: String
            switch backend {
            case .openai:     hint = "add an OpenAI key with `briglia setup` (step 2)"
            case .opencode:   hint = "it needs OpenCode Go as the main provider, or a dedicated OpenCode web key"
            case .openrouter: hint = "add an OpenRouter key with `briglia setup` (step 1, openrouter)"
            case .chatgpt:    hint = "it follows /provider chatgpt automatically"
            }
            try? await sendText("✖ No key configured for \(backend.displayName) — \(hint).")
            return
        }
        let followSelection = WebSearchBackend.activeSelection
        let followNote: String
        if followSelection.backend == .chatgpt {
            followNote = " While /provider is chatgpt, web page reading keeps using the subscription; this choice applies on other providers."
        } else if followSelection.followsMainOpenRouter {
            followNote = " While /provider is openrouter, web page reading uses GPT-6 Luna (\(ORModel.openRouterExtractor)) on OpenRouter, OpenAI or Azure host; this choice applies on other providers."
        } else {
            followNote = ""
        }
        if WebSearchBackend.explicitlyStored == backend {
            try? await sendText("\(backend.displayName) is already the saved web page-reading backend.\(followNote)")
            return
        }
        if WebSearchBackend.configured == backend {
            // Same backend, but only by inference (or an unparseable stored
            // value): persist it so the choice survives whatever key changes
            // drove the inference. No behavior change → no idle guard needed.
            Prefs.store.set(backend.rawValue, forKey: WebSearchBackend.selectionKey)
            try? await sendText("\(backend.displayName) was active by inference — now saved as the explicit choice.\(followNote)")
            return
        }
        // Idle guard (same shape as /provider hops): the pipeline re-reads
        // the backend on every LLM call, so flipping it under a running
        // research turn would switch transports mid-transcript — an OpenAI
        // Responses transcript replayed against a chat gateway (or vice
        // versa) fails. Listing stays allowed anytime.
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /websearch \(backend.rawValue) again when Briglia is idle (or /stop first).")
            return
        }
        Prefs.store.set(backend.rawValue, forKey: WebSearchBackend.selectionKey)
        try? await sendText("✅ Web page-reading backend: \(backend.displayName) — \(backend.modelSummary). Takes effect from the next search; the research itself stays on your main model.\(followNote)")
    }

    /// `/subagents` — turn the model-facing delegation tools (Agent +
    /// subagent_manage) on or off. The stored flag is read every time the
    /// tool array is assembled, so a change applies from the next message.
    /// Default is ON for every provider — off exists for setups whose model
    /// can't drive delegation usefully (e.g. a small local model), and this
    /// command is the CLI's only writer of the flag (the key was previously
    /// a read-only vestige of the Ada.app fork). Watcher triage routing is
    /// unaffected: triage subagents are harness-driven, not tool-driven.
    func handleSubagentsCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let enabled = AvailableTools.subagentsEnabled

        let normalized = argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            try? await sendText("""
                Subagents (the Agent + subagent_manage tools): \(enabled ? "ON" : "OFF") (default: on).
                Switch with /subagents on or /subagents off — takes effect from the next message.
                Off removes only the delegation tools; watcher triage routing keeps working.
                """)
            return
        }
        guard normalized == "on" || normalized == "off" else {
            try? await sendText("Usage: /subagents on|off (currently \(enabled ? "on" : "off")).")
            return
        }
        let target = normalized == "on"
        if target == enabled {
            try? await sendText("Subagents are already \(target ? "on" : "off").")
            return
        }
        // Idle guard (same shape as /model): the tool array is part of the
        // prompt-cache prefix and is rebuilt per request — flipping it under
        // a running turn would change the toolset between rounds.
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /subagents \(normalized) again when Briglia is idle (or /stop first).")
            return
        }
        switchDefaults.set(target, forKey: "ada.subagentsEnabled")
        // O5: the Web researcher cannot exist without the Agent tool — turning
        // subagents off turns it off too, and says so.
        var cascade = ""
        if !target, AvailableTools.webSubagentEnabled {
            switchDefaults.set(false, forKey: "ada.webSubagentEnabled")
            cascade = " The Web research subagent was on and is now off too (the legacy web_search tools are back); re-enable it with /websubagent on after /subagents on."
        }
        try? await sendText(target
            ? "✅ Subagents ON — the Agent and subagent_manage tools are available from the next message."
            : "✅ Subagents OFF — the Agent and subagent_manage tools are removed from the next message. Re-enable with /subagents on." + cascade)
    }

    /// The preference store behind the two tool switches (one accessor, so
    /// the lifecycle instrumentation's per-file accounting of standard-defaults
    /// access is unchanged by the second switch).
    var switchDefaults: UserDefaults { Prefs.store }

    /// `/websubagent` — the Web research subagent switch (WEB_SUBAGENT_PLAN
    /// §4.8–4.9; default OFF in R1a/R1b, ON since R2). On: the main agent
    /// loses web_search / web_research_sweep and delegates research to
    /// Agent(subagent_type=Web); web_fetch gains `refresh`. Off: today's
    /// tools, byte for byte. Requires /subagents on (O5). Same idle guard as
    /// /subagents: the tool array is part of the prompt-cache prefix.
    func handleWebSubagentCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let enabled = AvailableTools.webSubagentEnabled
        let webSnapshot = KeychainHelper.loadSnapshot()
        let availability = (KeylessSearchSwitch.resolve(snapshot: webSnapshot) == .none
            ? "Web preset available: no (no search service: add a Serper.dev key or /freesearch on)" : "Web preset available: yes")
            + ". Web services: \(KeylessSearchSwitch.summary(webSnapshot))"

        let normalized = argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            try? await sendText("""
                Web research subagent: \(enabled ? "ON" : "OFF") (default: on). \(availability). Subagents: \(AvailableTools.subagentsEnabled ? "on" : "off").
                On: web research runs in a resumable Web subagent (Agent, subagent_type=Web, deliverable short|standard|report) on the /websearch backend; the main agent keeps only web_fetch (with refresh).
                Off: the legacy web_search and web_research_sweep tools. Switch with /websubagent on or /websubagent off — takes effect from the next message.
                """)
            return
        }
        guard normalized == "on" || normalized == "off" else {
            try? await sendText("Usage: /websubagent on|off (currently \(enabled ? "on" : "off")).")
            return
        }
        let target = normalized == "on"
        if target == enabled {
            try? await sendText("Web research subagent is already \(target ? "on" : "off").")
            return
        }
        if target, !AvailableTools.subagentsEnabled {
            try? await sendText("Subagents are off, so the main agent would have no web capability. Send /subagents on first, then /websubagent on.")
            return
        }
        guard activeRunId == nil, activeProcessingTask == nil else {
            try? await sendText("⏳ A turn is running — send /websubagent \(normalized) again when Briglia is idle (or /stop first).")
            return
        }
        switchDefaults.set(target, forKey: "ada.webSubagentEnabled")
        try? await sendText(target
            ? "✅ Web research subagent ON — from the next message, web research goes through Agent(subagent_type=Web); web_search and web_research_sweep are removed from the main agent and from ordinary subagents (they delegate to Web instead), web_fetch gains refresh. \(availability)."
            : "✅ Web research subagent OFF — the legacy web_search and web_research_sweep tools are back from the next message. Re-enable with /websubagent on.")
    }

    /// `/freesearch on|off|reset` (KEYLESS_WEB plan A.7). A SEARCH switch:
    /// with a Serper key it changes nothing; page reading without a Jina key
    /// is unaffected. The tool list follows from the next turn; a running
    /// turn's searches use the new value at their next call.
    func handleFreeSearchCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let normalized = argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func describe() -> String {
            let snapshot = KeychainHelper.loadSnapshot()
            let stored = KeylessSearchSwitch.stored(snapshot)
            var lines = ["Free web search (Parallel, no key): \(KeylessSearchSwitch.keylessEnabled(snapshot) ? "ON" : "OFF") (default: \(KeylessSearchSwitch.effectiveDefaultOn ? "on" : "off")\(stored == .unset ? ", not changed" : "")).",
                         "Now: \(KeylessSearchSwitch.summary(snapshot))."]
            if KeylessSearchSwitch.effectiveHardDisabled { lines.append("Free search is withdrawn in this version of Briglia.") }
            if KeylessSearchSwitch.environmentForcesOff { lines.append("\(KeylessSearchSwitch.environmentKey)=0 is set in Briglia's environment, so free search stays off.") }
            if case .damaged = ParallelSessionStore.state() {
                lines.append("⚠️ The free-search session file is damaged — send /freesearch reset to repair it.")
            }
            lines.append("Free searches go to Parallel and may be used to train their models; add a Serper.dev key in briglia menu for more private, better search.")
            return lines.joined(separator: "\n")
        }
        switch normalized {
        case "":
            try? await sendText(describe())
        case "on", "off":
            do {
                try KeychainHelper.save(key: KeychainHelper.keylessSearchKey, value: normalized == "on" ? "true" : "false")
                try? await sendText("✅ Free web search \(normalized.uppercased()) — from the next message.\n" + describe())
            } catch {
                try? await sendText("⚠️ Could not save the setting: \(error.localizedDescription)")
            }
        case "reset":
            do {
                try KeychainHelper.delete(key: KeychainHelper.keylessSearchKey)
                let session: String
                switch try ParallelSessionStore.reset() {
                case .kept: session = "The search session is fine and was kept."
                case .minted: session = "A search session was created."
                case .replaced: session = "The damaged search session file was moved aside and a new session created."
                }
                try? await sendText("✅ Free web search is back to the default. \(session)\n" + describe())
            } catch {
                try? await sendText("⚠️ Reset failed: \(error.localizedDescription)")
            }
        default:
            try? await sendText("Usage: /freesearch on|off|reset")
        }
    }

    /// Reply with a chronological snapshot of tool activity in the current
    /// (or most recently completed) turn. Replaces the old always-on
    /// progress-ping model — user pulls the info on demand rather than
    /// being bombarded with one message per tool call.
    func sendTurnStatus() async {
        guard replyAddress != nil else { return }
        let log = currentTurnToolLog

        var contextLine = formatContextGaugeLine() + "\n" + PruneArchiveStore.statusLine()
        if LLMProvider.fromStoredValue(KeychainHelper.load(key: KeychainHelper.llmProviderKey)) == .openRouter,
           let pin = OpenRouterProviderPin.statusLine() {
            contextLine += "\n" + pin
        }
        // Web services (KEYLESS_WEB plan A.8): shown when search or page
        // reading runs without the user's own key (never model-visible).
        let webSnapshot = KeychainHelper.loadSnapshot()
        if (webSnapshot[KeychainHelper.serperApiKeyKey] ?? "").isEmpty || (webSnapshot[KeychainHelper.jinaApiKeyKey] ?? "").isEmpty {
            contextLine += "\nWeb: " + KeylessSearchSwitch.summary(webSnapshot)
        }
        if let notice = pendingHostNotice {
            contextLine += "\n" + notice
            pendingHostNotice = nil
        }
        // /stop visibility (R3): stopped requests still finishing, before
        // the background section.
        let stoppedLines = stoppedRunStatusLines()
        if !stoppedLines.isEmpty { contextLine += "\n" + stoppedLines.joined(separator: "\n") }
        // Mid-turn early wake (§3.11): background work and retained
        // obligations; the hidden test setting announces itself first.
        if let background = await backgroundStatusSection() { contextLine += "\n" + background }
        if let paused = statusSpendPauseLine() { contextLine += "\n" + paused }
        contextLine += "\n" + (await archiveModeStatusLine())
        // Security (auto-update plan, Phase 0): read-only; the host check
        // runs in the background at most every 6 h, /status never waits.
        contextLine += "\n" + SecurityStatusCache.shared.statusLine()
        // Several assistants (§10.3, §25.7): empty with one.
        for line in multiAssistantStatusLines() { contextLine += "\n" + line }
        // BGPRUNE{ A-STATUS
        if backgroundPruneEngaged {
            contextLine += "\n" + backgroundPruneStatusLine()
        }
        // }BGPRUNE
        let testWarning = ForceDetach.active ? "⚠️ test setting: force-detach is ON\n" : ""

        if log.isEmpty {
            let msg = activeRunId != nil
                ? "\(testWarning)⏳ Working on it — no tool calls yet.\n\(contextLine)"
                : "\(testWarning)💤 Idle. No tool activity to report.\n\(contextLine)"
            try? await sendText(msg)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let failedCount = log.filter(\.failed).count
        let failedSuffix = failedCount > 0 ? ", \(failedCount) failed" : ""
        let header = currentTurnLogIsActive
            ? "⚙️ Current turn — \(log.count) tool call\(log.count == 1 ? "" : "s") so far\(failedSuffix):"
            : "\(failedCount > 0 ? "⚠️" : "✅") Last turn — \(log.count) tool call\(log.count == 1 ? "" : "s")\(failedSuffix):"

        var lines: [String] = testWarning.isEmpty ? [header] : [String(testWarning.dropLast()), header]
        for entry in log {
            let emoji = Self.progressEmoji(forToolName: entry.name)
            let time = formatter.string(from: entry.startedAt)
            lines.append("  [\(time)] \(emoji) \(entry.label)\(entry.failed ? " ❌" : "")")
        }
        lines.append("")
        lines.append(contextLine)

        try? await sendText(lines.joined(separator: "\n"))
    }

    /// "Running in the background" for /status (§3.11): main-owned bash
    /// jobs (all stopped by /stop — owner decision B1), background
    /// subagents, and crash-record obligations that could not be verified.
    func backgroundStatusSection() async -> String? {
        var lines: [String] = []
        let jobs = await BackgroundProcessRegistry.shared.runningMainOwnedJobs()
        for job in jobs.prefix(10) {
            let command = job.command.count > 50 ? String(job.command.prefix(50)) + "…" : job.command
            lines.append("  • bash \(job.handle) \"\(command)\" — \(Self.formatShortDuration(job.runningForSeconds))")
        }
        if jobs.count > 10 { lines.append("  • … and \(jobs.count - 10) more") }
        if !jobs.isEmpty { lines.append("  (/stop stops all of these, including long-running ones)") }
        let subagents = await SubagentBackgroundRegistry.shared.runningHandles()
        for handle in subagents.prefix(5) {
            // Wake-detached runs (1b) say so: they were moved out of a turn.
            let moved = handle.detached ? ", moved to the background" : ""
            lines.append("  • subagent \(handle.id) (\(handle.subagentType)) — \(Self.formatShortDuration(Int(Date().timeIntervalSince(handle.startedAt))))\(moved)")
        }
        if subagents.count > 5 { lines.append("  • … and \(subagents.count - 5) more subagents") }
        if let historyLoadFailure {
            lines.append("  ⚠️ conversation history could not be read (\(historyLoadFailure)) — preserved, not overwritten; background results stay owed until it loads")
            lines.append("  ⏸ no new work starts until it loads\(pendingMidTurnMessages.isEmpty ? "" : " — \(pendingMidTurnMessages.count) message\(pendingMidTurnMessages.count == 1 ? "" : "s") held") — repair or move the file aside, then /restart")
        } else if heldQueueFileProblem != nil {
            lines.append("  ⏸ no new work starts until the held-message file reads — repair or move it aside, then /restart")
        }
        if let heldQueueFileProblem {
            lines.append("  ⚠️ the held-message file can't be read (\(heldQueueFileProblem)) — kept as is; new messages are not accepted until it reads")
        }
        if let records = try? DetachedJobStore.load() {
            for record in records where record.unverifiableReason != nil {
                lines.append("  ⚠️ result of \(record.handle) could not be verified after a restart (\(record.unverifiableReason ?? "")) — kept for inspection")
            }
        }
        // Spend incidents are not listed here (owner decision, plan v2 §4):
        // /spend and `briglia doctor` keep the detail; /status shows only
        // the one paused line (statusSpendPauseLine).
        guard !lines.isEmpty else { return nil }
        return "Running in the background:\n" + lines.joined(separator: "\n")
    }

    private func formatContextGaugeLine() -> String {
        let max = configuredMaxContextTokens()
        if let current = lastPromptTokens {
            let currentStr = Self.formatTokenCountCompact(current)
            let maxStr = Self.formatTokenCountCompact(max)
            let pct = Int(round(Double(current) / Double(max) * 100))
            return "📊 Context: \(currentStr)/\(maxStr) (\(pct)%)"
        }
        let maxStr = Self.formatTokenCountCompact(max)
        return "📊 Context: —/\(maxStr)"
    }

    private static func formatTokenCountCompact(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))M"
                : String(format: "%.1fM", value)
        }
        if count >= 1_000 {
            let value = Double(count) / 1_000.0
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))k"
                : String(format: "%.1fk", value)
        }
        return "\(count)"
    }

    /// Whether a tool result payload represents a failure. Tool errors are
    /// JSON objects with a top-level "error" key; for non-JSON payloads fall
    /// back to a prefix check so free-text results mentioning "error" deep in
    /// page content don't count as failures.
    static func toolResultIndicatesError(_ content: String) -> Bool {
        guard content.contains("\"error\"") else { return false }
        if let data = content.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj["error"] != nil
        }
        return content.hasPrefix("{\"error\"")
    }

    /// Display label of one tool call in the per-turn log (/status rows and
    /// the activity line). Agent calls name the subagent by ROLE (WEB_SUBAGENT_PLAN
    /// §16.2): the resolved type's `builtInRole` decides the word — never the
    /// name alone — so a user agent named "Web" reads `Agent (Web): …` and only
    /// the built-in researcher reads `Agent (Web research): …`; Browse reads
    /// `Agent (Browser use): …`; ordinary types show their name. A resume adds
    /// the session id's short form. Unparsable arguments or an unresolvable
    /// type fall back to the bare tool name. Display only: nothing here
    /// touches request bytes. Scope: the main agent's own calls — a nested
    /// Web run launched by a subagent is not logged here (its parent's entry
    /// stands; the run is listed by subagent_manage as "via <parent>").
    nonisolated static func toolLogLabel(name: String, arguments: String,
                             resolve: (String) -> SubagentType? = { SubagentTypes.find(name: $0) }) -> String {
        guard name == "Agent",
              let data = arguments.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let typeName = object["subagent_type"] as? String,
              let type = resolve(typeName) else { return name }
        let role: String
        switch type.builtInRole {
        case .webResearcher: role = "Web research"
        case .browser: role = "Browser use"
        case .ordinary: role = type.name
        }
        var label = "Agent (\(role)"
        if let session = (object["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty {
            label += ", resume \(session.prefix(8))"
        }
        label += ")"
        let description = ((object["description"] as? String) ?? "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { label += ": \(description.prefix(80))" }
        return label
    }

    /// Emoji for a single tool name — used by /status to render each row.
    /// Same palette as `getProgressMessage` but indexed by tool name instead
    /// of batch characterization.
    private static func progressEmoji(forToolName name: String) -> String {
        if name.hasPrefix("mcp__playwright__") { return "🌐" }
        if name.hasPrefix("mcp__nano-banana__") { return "🎨" }
        if name.hasPrefix("mcp__") { return "🔌" }
        switch name {
        case "web_research_sweep": return "🧠🔍"
        case "web_search", "web_query": return "🔍"
        case "web_fetch", "web_extract": return "🌐"
        case "Agent": return "🤖"
        case "subagent_manage": return "🤖"
        case "generate_image": return "🎨"
        case "inspect_media": return "🔍"
        case "manage_reminders": return "⏰"
        case "write_file", "edit_file", "apply_patch": return "✏️"
        case "read_file", "grep", "glob", "list_dir", "list_recent_files": return "🔎"
        case "lsp": return "🔬"
        case "bash", "bash_manage": return "💻"
        case "send_document_to_chat": return "📎"
        case "shortcuts", "run_shortcut", "list_shortcuts": return "⌘"
        case "todo_write": return "📋"
        case "read_chunk_summaries", "list_conversation_chunks": return "🗂"
        default: return "🔧"
        }
    }

    /// Entry point for the app chat's "Libera memoria" button. Runs the same
    /// manual prune as /prune, but routes result text to the app channel
    /// (no-op transport) and surfaces the outcome via the maintenance notice.
    func manualPruneFromApp() async {
        // Parked for an update (Codex stage-2 F2): the terminal's /prune and
        // the app's button reach this without the control-command gate.
        guard !admissionPaused else {
            print("[ConversationManager] /prune refused: parked for an update")
            try? await sendText(Self.updatingRefusal, to: Self.appChannelAddress)
            return
        }
        guard activeRunId == nil else { return }
        await manualPruneToolInteractions(notify: Self.appChannelAddress)
    }

    func manualPruneToolInteractions(notify address: ChannelAddress? = nil, noSnapshot: Bool = false) async {
        // Before any work (maintenance, context reads): parked admission is closed.
        guard !admissionPaused else {
            print("[ConversationManager] /prune refused: parked for an update")
            try? await sendText(Self.updatingRefusal, to: address)
            return
        }
        guard activeRunId == nil, activeProcessingTask == nil, !isRestoringMind,
              maintenanceActivities.isEmpty, archiveRecoveryTask == nil else {
            try? await sendText("Briglia is busy; retry /prune when idle.", to: address)
            return
        }
        // A finished background archive commits at the next message; a prune
        // in between would rewrite messages it already archived.
        guard archiveJob?.outcome != .succeeded else {
            try? await sendText("Archived messages are about to be removed at your next message; retry /prune after it.", to: address)
            return
        }
        // BGPRUNE{ A-PRUNE
        if backgroundPruneEngaged {
            if backgroundPruneJob != nil {
                try? await sendText("A background prune will apply at your next message; retry /prune after it.", to: address)
                return
            }
        }
        // }BGPRUNE
        let pruneActivityId = beginMaintenance(.pruning)
        defer { endMaintenance(pruneActivityId) }
        let targetTokens = configuredTargetContextTokens()
        let providerIsLMStudio = currentProviderIsLMStudio()
        let searchService = KeylessSearchSwitch.current()
        let frozenContext = await getFrozenSystemContext()
        // The same automatic-context rule as a turn (§4.1): rows whose
        // sources are still live are left out of the prune-summary request.
        let pruneView = await captureFreshArchiveView()
        defer { let lease = pruneView.leaseId; Task { await archiveService.releaseLease(lease) } }
        let chunkSummaries = pruneView.items
        let totalChunkCount = pruneView.totalChunkCount
        await MCPAgentRouting.refreshFromRegistry()
        let allMcpTools = await MCPRegistry.shared.allToolDefinitions()
        let mainMcpTools = MCPAgentRouting.filterMcpTools(
            forAgent: "main",
            allTools: allMcpTools,
            fallbackPatterns: nil
        )
        let deferredServerNames = MCPAgentRouting.deferredServers(
            forAgent: "main",
            allTools: allMcpTools,
            fallbackPatterns: nil
        )
        let deferredSummaries = await MCPRegistry.shared.serverSummaries(for: deferredServerNames)
        let nativeTools = AvailableTools.all(
            includeWebSearch: searchService != .none,
            hasDeferredMCPs: !deferredSummaries.isEmpty
        )
        let toolsForSummary = nativeTools + mainMcpTools
        let mandatoryEstimate = try? await openRouterService.activeTurnRequestEstimate(messages: [], rounds: [],
            images: imagesDirectory, documents: documentsDirectory, tools: toolsForSummary,
            calendar: frozenContext.calendar, email: frozenContext.email, summaries: chunkSummaries,
            totalChunks: totalChunkCount, date: currentSystemPromptTimestamp(), deferred: deferredSummaries)

        // Use real prompt_tokens from API when available, fall back to estimation.
        // /keepsummaries §4.4: decide on the composed view; a measurement
        // taken under another composition is ignored.
        let summaryLimit = KeepSummariesSetting.current()
        let decisionView = PruneSummaryRetention.compose(messages, limit: summaryLimit)
        var totalTokens: Int
        if let real = promptMeasurement(for: decisionView) {
            let addedSinceLastPrompt = estimatedTokensAddedSinceLastPrompt(currentUserMessageId: nil, isLMStudio: providerIsLMStudio, in: decisionView.messages)
            totalTokens = real + addedSinceLastPrompt
            print("[ConversationManager] Manual prune using real prompt_tokens: \(real) + ~\(addedSinceLastPrompt) new tokens")
        } else {
            totalTokens = mandatoryEstimate?.tokens ?? estimateSystemPromptTokens(
                calendarContext: frozenContext.calendar, emailContext: frozenContext.email, chunkSummaries: chunkSummaries)
            for message in decisionView.messages {
                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)
                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
            }
            print("[ConversationManager] Manual prune using estimated tokens: \(totalTokens)")
        }

        var prunableToolTokens = 0
        for message in messages {
            if message.role == .assistant
                && (!message.toolInteractions.isEmpty || message.hasFinalReasoningPayload || message.activeTurnCompaction != nil) {
                prunableToolTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)
                    + estimatedFinalReasoningTokens(message)
                    + (message.activeTurnCompaction.map { ActiveTurnBudget.text($0.promptText) } ?? 0)
            }
        }

        guard prunableToolTokens > 0 || messages.contains(where: \.hasUnprunedMedia)
                || !compressibleUserMessageIndices(upToIndex: max(0, messages.count - 1), in: messages).isEmpty else {
            let msg = "Nothing to compact: no tool details, media or synthetic messages are left to summarize."
            showMaintenanceNotice(msg)
            try? await sendText(msg, to: address)
            return
        }

        let beforeTokens = totalTokens



        let plannedSource = messages
        let plan = buildPrunePlan(
            for: plannedSource,
            totalTokens: totalTokens,
            targetTokens: targetTokens,
            protectedIndex: nil,
            providerIsLMStudio: providerIsLMStudio
        )
        let safeBoundary = min(plan.pruningBoundary, max(messages.count - 1, 0))
        let compressedIndices = compressibleUserMessageIndices(upToIndex: safeBoundary, in: messages)

        // Cache preservation: exclude trailing assistant messages so the
        // array boundary matches the previous turn's API request. That
        // request used messagesForLLM (snapshot taken before the assistant
        // responded), so the last cached message is the user's triggering
        // message. Including the assistant response would place Anthropic
        // cache breakpoint 2 on a never-cached message, causing a full
        // cache miss on everything after the system prompt. A trailing
        // assistant message is excluded only when nothing of it is pruned.
        var messagesForSummary = plannedSource
        if let last = messagesForSummary.last, last.role == .assistant,
           !plan.affectedIndices.contains(messagesForSummary.count - 1),
           !compressedIndices.contains(messagesForSummary.count - 1) {
            messagesForSummary.removeLast()
        }

        do {
            let committed = try await commitPrune(plan: plan, compressedIndices: compressedIndices, safeBoundary: safeBoundary,
                source: plannedSource, summarySource: messagesForSummary, trigger: "manual", noSnapshot: noSnapshot) { snapshotForSummary in
                return await generatePrunedContextSummary(
            plan: plan,
            compressedIndices: compressedIndices,
            sourceMessages: snapshotForSummary,
            tools: toolsForSummary,
            calendarContext: frozenContext.calendar,
            emailContext: frozenContext.email,
            chunkSummaries: chunkSummaries,
            totalChunkCount: totalChunkCount,
            currentUserMessageId: nil,
            turnStartDate: currentSystemPromptTimestamp(),
            deferredMCPSummaries: deferredSummaries,
            summaryLimit: summaryLimit
        )
            }
            // Count only the summary/reference delta, so existing notes are
            // not charged twice. Use the committed view, including nil-summary
            // and explicit no-snapshot outcomes.
            func noteTokens(_ history: [Message]) -> Int {
                Self.manualPruneNoteTokens(PruneSummaryRetention.compose(history, limit: summaryLimit).messages)
            }
            totalTokens += noteTokens(committed) - noteTokens(plannedSource)
        } catch {
            let failure = error.localizedDescription
            showMaintenanceNotice(failure)
            try? await sendText(failure, to: address)
            return
        }
        totalTokens -= plan.savedTokens
        let prunedToolCount = plan.toolActionCount
        let prunedMediaCount = plan.mediaActionCount
        refreshSystemPromptTimestamp()
        CacheDiagnostics.noteTransition("prune", lane: .main)
        var msg = (prunedToolCount > 0 || prunedMediaCount > 0 || !compressedIndices.isEmpty)
            ? "✂️ Memory freed: I summarized the details of \(prunedToolCount) task\(prunedToolCount == 1 ? "" : "s") and \(prunedMediaCount) media item\(prunedMediaCount == 1 ? "" : "s"). Working memory: from ~\(beforeTokens / 1000)k down to ~\(totalTokens / 1000)k tokens."
            : "Working memory is already tidy (~\(totalTokens / 1000)k tokens, under the \(targetTokens / 1000)k target): nothing to free."
        if noSnapshot && (!plan.actions.isEmpty || !compressedIndices.isEmpty) {
            msg += " Detailed history was discarded without a new snapshot, as requested by /prune nosnapshot."
            print("[ConversationManager] Explicit /prune nosnapshot committed; no new snapshot saved")
        }
        showMaintenanceNotice(msg)
        try? await sendText(msg, to: address)
    }
    
    func switchVoiceTranscriptionProvider(to provider: VoiceTranscriptionProvider) async {
        // Briglia CLI has no local Whisper (the WhisperKit shim never reports a
        // ready model), so switching to .local would silently break every
        // voice message until the user finds /transcribe_openai. Refuse.
        if provider == .local {
            try? await sendText("❌ Local transcription is not available in Briglia CLI — voice messages use OpenAI cloud transcription. Nothing was changed.")
            if activeRunId == nil {
                statusMessage = "Listening... (Last check: \(formattedTime()))"
            }
            return
        }
        let currentProvider = currentVoiceTranscriptionProvider()
        let providerDisplayName = provider.displayName
        let switchedMessage: String

        if currentProvider == provider {
            switchedMessage = "✅ Voice transcription already set to \(providerDisplayName)."
        } else {
            do {
                try KeychainHelper.save(
                    key: KeychainHelper.voiceTranscriptionProviderKey,
                    value: provider.rawValue
                )
                switchedMessage = "✅ Switched voice transcription to \(providerDisplayName)."
            } catch {
                let errorMessage = "❌ Failed to switch voice transcription to \(providerDisplayName): \(error.localizedDescription)"
                try? await sendText(errorMessage)
                if activeRunId == nil {
                    statusMessage = "Listening... (Last check: \(formattedTime()))"
                }
                return
            }
        }

        var advisoryNotes: [String] = []
        if provider == .openAI {
            if MediaRouting.transcription.viaOpenRouter {
                advisoryNotes.append("ℹ️ No OpenAI key: voice messages are transcribed through your OpenRouter key (gpt-transcribe).")
            } else if openAITranscriptionAPIKey().isEmpty {
                advisoryNotes.append("⚠️ OpenAI API key missing. Run `briglia setup` (section 2) to add it.")
            }
        } else {
            await WhisperKitService.shared.checkModelStatus()
            if !WhisperKitService.shared.isModelReady {
                advisoryNotes.append("⚠️ \(WhisperKitService.shared.statusMessage).")
            }
        }

        let message = ([switchedMessage] + advisoryNotes).joined(separator: "\n")
        try? await sendText(message)

        if activeRunId == nil {
            statusMessage = "Listening... (Last check: \(formattedTime()))"
        }
    }

    /// `/spend` — the snapshot plus every limit; `/spend turn|daily|monthly
    /// <usd|off>` sets or removes one. All three are OFF by default; the only
    /// other way to change them used to be editing secrets.json by hand.
    func handleSpendCommand(argument: String) async {
        defer {
            if activeRunId == nil {
                statusMessage = "Listening... (Last check: \(formattedTime()))"
            }
        }
        guard !argument.isEmpty else {
            try? await sendText(spendSnapshotText())
            return
        }
        if argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "accept-unknown" {
            await acceptUnknownSpend()
            return
        }
        switch SpendLimitCommand.parse(argument) {
        case .failure(let why):
            try? await sendText("✖ \(why.description)\n\(SpendLimitCommand.usage)")
        case .success(let edit):
            let key: String
            switch edit.scope {
            case .turn: key = KeychainHelper.openRouterToolSpendLimitPerTurnUSDKey
            case .daily: key = KeychainHelper.openRouterToolSpendLimitDailyUSDKey
            case .monthly: key = KeychainHelper.openRouterToolSpendLimitMonthlyUSDKey
            }
            do {
                if let usd = edit.limitUSD {
                    try KeychainHelper.save(key: key, value: SpendLimitCommand.storedValue(usd))
                    try? await sendText("✅ \(edit.scope.label) spend limit set to $\(formatUSD(usd)) — applies from the next message.\n\(spendSnapshotText())")
                } else {
                    try KeychainHelper.delete(key: key)
                    try? await sendText("✅ \(edit.scope.label) spend limit removed — no \(edit.scope.noun) cap.\n\(spendSnapshotText())")
                }
            } catch {
                try? await sendText("✖ Could not store the \(edit.scope.noun) spend limit: \(error.localizedDescription)")
            }
        }
    }

    /// `/spend accept-unknown` (hidden owner command, §3.6.3 v7; Codex V7
    /// gate 4): accept EXACTLY the spend incidents open now — their unknown
    /// amounts count as $0; every known charge is kept; later incidents are
    /// not covered. Never automatic, never reachable by the agent. Logged.
    private func acceptUnknownSpend() async {
        let channel = lastUserChannelAddress?.kind.rawValue ?? "unknown"
        let result = ToolChargeLedger.acceptOpenIncidents(referenceDate: Date(), channel: channel)
        let text: String
        if let failure = result.failure {
            text = "✖ \(failure)"
            showMaintenanceNotice("/spend accept-unknown failed: \(failure)")
        } else if result.accepted.isEmpty {
            text = "Nothing to accept — no unknown spend is open."
        } else {
            let lines = result.accepted.map { "• " + ToolChargeLedger.describe($0) }
            text = (["✅ Accepted as $0 (known charges kept):"] + lines + [spendSnapshotText()]).joined(separator: "\n")
            print("[ConversationManager] /spend accept-unknown: \(result.accepted.map(\.id).joined(separator: ", "))")
        }
        try? await sendText(text)
    }

    private func spendSnapshotText() -> String {
        let nativeNotice = ProviderProfiles.usesResponses
            ? ["Responses model costs are not included in these totals or caps. Set a budget in your API provider account; these limits do not cap total Responses spending."] : []
        let status = currentSpendLimitStatus(referenceDate: Date())
        let snapshot = (today: status.todaySpentUSD, month: status.monthSpentUSD)
        let turnCap = configuredToolSpendLimitPerTurnUSD()
        func limitText(_ base: Double?, extra: Double) -> String {
            guard let base else { return "off" }
            return "$\(formatUSD(base + extra))" + (extra > 0 ? " (incl. +$\(formatUSD(extra)) temporary)" : "")
        }
        return (nativeNotice + [
            "💸 API spend (paid tools: image generation, web search, subagent calls billed through the gateway)",
            "Today: $\(formatUSD(snapshot.today)) — daily limit: \(limitText(status.dailyBaseLimitUSD, extra: status.dailyExtraUSD))",
            "This month: $\(formatUSD(snapshot.month)) — monthly limit: \(limitText(status.monthlyBaseLimitUSD, extra: status.monthlyExtraUSD))",
            "Per-turn cap: \(turnCap.map { "$" + formatUSD($0) } ?? "off")",
        ] + spendIncidentLines(status) + [
            SpendLimitCommand.usage,
        ]).joined(separator: "\n")
    }

    /// Open spend incidents (§3.6.3) for /spend and /status.
    /// The only spend line /status ever shows (owner decision, plan v2 §4):
    /// a spending limit is set AND unknown charges are pausing paid work.
    /// Without a limit, unknown charges never appear in /status; /spend and
    /// `briglia doctor` keep every incident.
    private func statusSpendPauseLine() -> String? {
        currentSpendLimitStatus(referenceDate: Date()).unverifiable ? "⏸ Paid work paused — see /spend" : nil
    }

    private func spendIncidentLines(_ status: SpendLimitStatus) -> [String] {
        let problems = status.accounting.incidents.map(ToolChargeLedger.describe) + status.accounting.unidentified
        guard !problems.isEmpty else { return [] }
        var lines = ["⚠️ Spend totals incomplete: " + problems.joined(separator: "; ")]
        if status.unverifiable {
            lines.append("Paid work is paused until the file is repaired (see `briglia doctor`) or you send `/spend accept-unknown`.")
        }
        return lines
    }

    func setPrivacyMode(enabled: Bool) async {
        guard isPrivacyModeEnabled != enabled else {
            let message = enabled
                ? "Privacy mode is already enabled. The on-screen conversation and context viewer stay hidden until you send /show."
                : "Privacy mode is already disabled. The conversation and context viewer are visible again."
            try? await sendText(message)

            if activeRunId == nil {
                statusMessage = "Listening... (Last check: \(formattedTime()))"
            }
            return
        }

        isPrivacyModeEnabled = enabled
        Prefs.store.set(enabled, forKey: privacyModeDefaultsKey)

        let message = enabled
            ? "Privacy mode on. The local session now hides the conversation until you send /show."
            : "Privacy mode off. The local session shows the conversation again."
        try? await sendText(message)

        if activeRunId == nil {
            statusMessage = enabled
                ? "Privacy mode enabled"
                : "Listening... (Last check: \(formattedTime()))"
        }
    }
}
