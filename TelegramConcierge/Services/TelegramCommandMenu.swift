import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

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
///
/// Context binding (Codex R1, 2026-09-07): a keyboard outlives the state it
/// was built for — the user can hop providers and tap an old menu later. So
/// a model button carries the profile it was built for and an effort button
/// an opaque profile+model context; ConversationManager refuses a tap whose
/// context no longer matches the active state instead of applying it to
/// whatever is active now. Provider buttons name their destination and need
/// no binding.
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
        /// `profile`: the provider profile the menu was built for.
        case model(profile: String, id: String)
        /// "Type a model name…" — informational, no state change.
        case modelTyped
        /// `context`: `effortContext(profile:model:)` at menu time.
        case effort(context: String, level: String)
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

    /// Opaque, compact binding of an effort menu to the state it was built
    /// for: 8 hex chars of SHA-256(profile ⊕ model). Any model id fits (custom
    /// endpoints use slashes and capitals that the argument charset refuses),
    /// and the payload stays well under 64 bytes.
    static func effortContext(profile: String, model: String) -> String {
        let digest = SHA256.hash(data: Data("\(profile)\u{0}\(model)".utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidContext(_ value: String) -> Bool {
        value.count == 8 && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Payloads: `bm1:p:<profile>`, `bm1:m:<profile>:<model-id>`, `bm1:m:?`,
    /// `bm1:e:<context>:<level>`. nil when a field can't be carried (charset
    /// or the 64-byte cap).
    static func encode(_ action: Action) -> String? {
        let data: String
        switch action {
        case .provider(let value):
            guard isValidArgument(value) else { return nil }
            data = "\(dataPrefix):p:\(value)"
        case .model(let profile, let id):
            guard isValidArgument(profile), isValidArgument(id) else { return nil }
            data = "\(dataPrefix):m:\(profile):\(id)"
        case .modelTyped:
            data = "\(dataPrefix):m:\(typedModelMarker)"
        case .effort(let context, let level):
            guard isValidContext(context), isValidArgument(level) else { return nil }
            data = "\(dataPrefix):e:\(context):\(level)"
        }
        guard data.utf8.count <= maxDataBytes else { return nil }
        return data
    }

    static func decode(_ data: String) -> Action? {
        guard data.utf8.count <= maxDataBytes else { return nil }
        let parts = data.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == dataPrefix else { return nil }
        switch (parts[1], parts.count) {
        case ("p", 3):
            return isValidArgument(parts[2]) ? .provider(parts[2]) : nil
        case ("m", 3):
            return parts[2] == typedModelMarker ? .modelTyped : nil
        case ("m", 4):
            return isValidArgument(parts[2]) && isValidArgument(parts[3]) ? .model(profile: parts[2], id: parts[3]) : nil
        case ("e", 4):
            return isValidContext(parts[2]) && isValidArgument(parts[3]) ? .effort(context: parts[2], level: parts[3]) : nil
        default:
            return nil
        }
    }

    /// The typed command a tap stands for; nil for the informational button.
    static func commandText(for action: Action) -> String? {
        switch action {
        case .provider(let value): return "/provider \(value)"
        case .model(_, let id): return "/model \(id)"
        case .modelTyped: return nil
        case .effort(_, let level): return "/effort \(level)"
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
    /// `profile` is the provider the menu is built for — bound into every
    /// model button.
    static func modelMenu(catalog: ModelCatalog, profile: String, current: String) -> Menu {
        let choices: [ModelChoice]
        let heading: String
        switch catalog {
        case .opencode(let list): choices = list; heading = "OpenCode Go catalog — tap a model:"
        case .chatgpt: choices = chatGPTChoices; heading = "ChatGPT subscription models — tap a model:"
        }
        var lines = ["Current model: \(current.isEmpty ? "(not set)" : current)", heading]
        var rows: [[Button]] = []
        for choice in choices {
            guard let data = encode(.model(profile: profile, id: choice.id)) else { continue }
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
    /// "endpoint default" button (`/effort off`); `context` is
    /// `effortContext(profile:model:)` for the state the menu is built for.
    static func effortMenu(levels: [String], context: String, current: String, currentDescription: String, offAllowed: Bool) -> Menu {
        var lines = ["Current reasoning effort: \(currentDescription)", "Tap a level, or /effort <level>:"]
        var rows = chunk(levels.compactMap { level -> Button? in
            guard let data = encode(.effort(context: context, level: level)) else { return nil }
            return Button(label: (level == current ? "✓ " : "") + level, data: data)
        }, perRow: 3)
        if offAllowed, let data = encode(.effort(context: context, level: "off")) {
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
