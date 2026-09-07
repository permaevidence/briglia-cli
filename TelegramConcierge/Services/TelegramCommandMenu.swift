import Foundation

/// Inline-keyboard menus for `/provider`, `/model` and `/effort` on Telegram
/// (owner request 2026-09-07). Pure: builds each menu's text and button rows
/// and encodes/decodes the button payload. ConversationManager turns a
/// decoded tap into the exact typed command ("/effort high") and runs the
/// ordinary handler, so a tap can never do anything typing couldn't — the
/// idle guard, validation and profile receipts stay in one place.
///
/// Button policy (owner): provider buttons for every configured profile;
/// model buttons ONLY for the OpenCode Go catalog (`OpenCodeGo.choices`, so
/// the buttons follow catalog edits automatically) and for the ChatGPT
/// subscription (`ResponsesAdapter.subscriptionModelChoices`), each with a
/// final "type a model name" button; every other provider stays text-only.
/// Non-Telegram channels always receive the plain text.
enum TelegramCommandMenu {
    struct Button: Equatable {
        let label: String
        /// callback_data — see `encode`.
        let data: String
    }

    struct Menu: Equatable {
        let text: String
        /// Empty when the menu has no buttons (send as plain text).
        let rows: [[Button]]
    }

    enum Action: Equatable {
        case provider(String)
        case model(String)
        /// "Type a model name…" — informational, no state change.
        case modelTyped
        case effort(String)
    }

    /// Versioned prefix: a keyboard left over from an older build decodes as
    /// unknown rather than as some other command.
    static let dataPrefix = "bm1"
    /// Telegram's hard cap on callback_data.
    static let maxDataBytes = 64
    static let typedModelMarker = "?"
    static let maxArgumentLength = 48
    private static let argumentScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")

    /// Arguments are restricted to the id charset used by profiles, model ids
    /// and effort levels — nothing a tap decodes to can carry whitespace or a
    /// second command.
    static func isValidArgument(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maxArgumentLength
            && value.unicodeScalars.allSatisfy { argumentScalars.contains($0) }
    }

    /// nil when the argument can't be carried (charset or 64-byte cap).
    static func encode(_ action: Action) -> String? {
        let code: String
        let argument: String
        switch action {
        case .provider(let value): code = "p"; argument = value
        case .model(let value): code = "m"; argument = value
        case .modelTyped: code = "m"; argument = typedModelMarker
        case .effort(let value): code = "e"; argument = value
        }
        guard argument == typedModelMarker || isValidArgument(argument) else { return nil }
        let data = "\(dataPrefix):\(code):\(argument)"
        guard data.utf8.count <= maxDataBytes else { return nil }
        return data
    }

    static func decode(_ data: String) -> Action? {
        guard data.utf8.count <= maxDataBytes else { return nil }
        let parts = data.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == dataPrefix else { return nil }
        let argument = String(parts[2])
        switch parts[1] {
        case "p": return isValidArgument(argument) ? .provider(argument) : nil
        case "m":
            if argument == typedModelMarker { return .modelTyped }
            return isValidArgument(argument) ? .model(argument) : nil
        case "e": return isValidArgument(argument) ? .effort(argument) : nil
        default: return nil
        }
    }

    /// The typed command a tap stands for; nil for the informational button.
    static func commandText(for action: Action) -> String? {
        switch action {
        case .provider(let value): return "/provider \(value)"
        case .model(let value): return "/model \(value)"
        case .modelTyped: return nil
        case .effort(let value): return "/effort \(value)"
        }
    }

    // MARK: - /provider

    struct ProviderChoice: Equatable {
        let id: String
        let displayName: String
        let active: Bool
    }

    /// `statusLines` is the same listing the typed command prints; the
    /// buttons cover the CONFIGURED profiles only (two per row).
    static func providerMenu(statusLines: [String], configured: [ProviderChoice]) -> Menu {
        var lines = ["Providers — tap one to switch, or /provider <name>:"]
        lines.append(contentsOf: statusLines)
        lines.append("Add or edit providers with `briglia setup` or `briglia quicksetup` in a terminal.")
        let buttons = configured.compactMap { choice -> Button? in
            guard let data = encode(.provider(choice.id)) else { return nil }
            return Button(label: (choice.active ? "✓ " : "") + choice.displayName, data: data)
        }
        return Menu(text: lines.joined(separator: "\n"), rows: chunk(buttons, perRow: 2))
    }

    // MARK: - /model

    struct ModelChoice: Equatable {
        let id: String
        let label: String
        let textOnly: Bool
    }

    enum ModelCatalog: Equatable {
        case opencode([ModelChoice])
        case chatgpt
    }

    static var chatGPTChoices: [ModelChoice] {
        ResponsesAdapter.subscriptionModelChoices.map { ModelChoice(id: $0.id, label: $0.label, textOnly: false) }
    }

    /// One button per catalog entry (the active one ticked, text-only ones
    /// tagged) plus the "type a model name" button; the text keeps the
    /// typed-command hint so nothing is lost for users who prefer typing.
    static func modelMenu(catalog: ModelCatalog, current: String) -> Menu {
        let choices: [ModelChoice]
        let heading: String
        switch catalog {
        case .opencode(let list): choices = list; heading = "OpenCode Go catalog — tap a model:"
        case .chatgpt: choices = chatGPTChoices; heading = "ChatGPT subscription models — tap a model:"
        }
        var lines = ["Current model: \(current.isEmpty ? "(not set)" : current)", heading]
        var rows: [[Button]] = []
        for choice in choices {
            guard let data = encode(.model(choice.id)) else { continue }
            var label = (choice.id == current ? "✓ " : "") + choice.label
            if choice.textOnly { label += " · text-only" }
            rows.append([Button(label: label, data: data)])
        }
        if let typed = encode(.modelTyped) {
            rows.append([Button(label: "Type a model name…", data: typed)])
        }
        lines.append("Or /model <model-id> — takes effect from the next message.")
        return Menu(text: lines.joined(separator: "\n"), rows: rows)
    }

    // MARK: - /effort

    /// `levels` in the order the provider accepts them; `offAllowed` adds the
    /// "endpoint default" button (`/effort off`).
    static func effortMenu(levels: [String], current: String, currentDescription: String, offAllowed: Bool) -> Menu {
        var lines = ["Current reasoning effort: \(currentDescription)", "Tap a level, or /effort <level>:"]
        var rows = chunk(levels.compactMap { level -> Button? in
            guard let data = encode(.effort(level)) else { return nil }
            return Button(label: (level == current ? "✓ " : "") + level, data: data)
        }, perRow: 3)
        if offAllowed, let data = encode(.effort("off")) {
            rows.append([Button(label: (current.isEmpty ? "✓ " : "") + "Endpoint default (off)", data: data)])
            lines.append("\"Endpoint default\" sends no effort field (/effort off).")
        }
        lines.append("Takes effect from the next message.")
        return Menu(text: lines.joined(separator: "\n"), rows: rows)
    }

    // MARK: - Helpers

    static func chunk(_ buttons: [Button], perRow: Int) -> [[Button]] {
        guard perRow > 0, !buttons.isEmpty else { return [] }
        return stride(from: 0, to: buttons.count, by: perRow).map { Array(buttons[$0..<min($0 + perRow, buttons.count)]) }
    }

    /// Wire form of a menu's rows.
    static func keyboard(for menu: Menu) -> TelegramInlineKeyboardMarkup? {
        guard !menu.rows.isEmpty else { return nil }
        return TelegramInlineKeyboardMarkup(inlineKeyboard: menu.rows.map { row in
            row.map { TelegramInlineKeyboardButton(text: $0.label, callbackData: $0.data) }
        })
    }

    /// Text a frozen menu shows after a tap: the original menu plus the
    /// choice, keyboard gone.
    static func frozenText(original: String, note: String) -> String {
        original.isEmpty ? note : "\(original)\n\n\(note)"
    }
}
