import Foundation

/// `/gptpatch on|off|status` and the `/status` line (GPT_APPLY_PATCH_PLAN §3.5).
extension ConversationManager {
    /// The editing configuration the next main request would use.
    func currentMainEditing() async -> (model: String, config: EditingConfig) {
        let context = await openRouterService.executionContext(modelOverride: nil, providerOverride: nil,
            reasoningEffortOverride: nil, textOnlyOverride: nil, lane: .main)
        return (context.model, EditingConfig.resolveAtRunStart(context))
    }

    /// `Edit tool: …` only when the main model is a GPT model; nil otherwise.
    func gptPatchStatusLine() async -> String? {
        let current = await currentMainEditing()
        guard GPTModelMatcher.isGPT(current.model) else { return nil }
        guard current.config.isGPT else { return "Edit tool: edit_file (GPT patch off)" }
        return "Edit tool: apply_patch (\(current.config.form == .freeform ? "freeform" : "JSON"))"
    }

    func handleGPTPatchCommand(argument: String) async {
        guard replyAddress != nil else { return }
        let normalized = argument.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "", "status":
            let current = await currentMainEditing()
            var lines = ["GPT patch tool: \(GPTPatchSwitch.storedOn ? "ON" : "OFF") (default: on)."]
            if GPTPatchSwitch.environmentForcesOff { lines.append("BRIGLIA_GPT_PATCH=0 is set, so it is off for this process.") }
            if GPTModelMatcher.isGPT(current.model) {
                lines.append(current.config.isGPT
                    ? "\(current.model) edits with apply_patch (\(current.config.form == .freeform ? "freeform" : "JSON") form)."
                    : "\(current.model) edits with edit_file and write_file.")
            } else {
                lines.append("\(current.model.isEmpty ? "The current model" : current.model) is not a GPT model; it uses edit_file and write_file.")
            }
            let rejections = GPTPatchFormStore.shared.records().filter { $0.value == adaCLIVersion }
            if !rejections.isEmpty { lines.append("Routes that refused the freeform form (JSON used): \(rejections.count).") }
            lines.append("Switch with /gptpatch on or /gptpatch off; it applies from the next request.")
            try? await sendText(lines.joined(separator: "\n"))
        case "on", "off":
            let target = normalized == "on"
            if target { switchDefaults.removeObject(forKey: GPTPatchSwitch.defaultsKey) }
            else { switchDefaults.set(false, forKey: GPTPatchSwitch.defaultsKey) }
            let running = mainRunEditing != nil ? " The running request keeps its current tools." : ""
            try? await sendText(target
                ? "✅ GPT patch tool ON: GPT models edit files with apply_patch from the next request.\(running)"
                : "✅ GPT patch tool OFF: GPT models use edit_file and write_file like other models from the next request.\(running)")
        default:
            try? await sendText("Usage: /gptpatch on|off|status (currently \(GPTPatchSwitch.storedOn ? "on" : "off")).")
        }
    }
}
