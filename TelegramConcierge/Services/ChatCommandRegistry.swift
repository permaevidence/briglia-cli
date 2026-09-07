import Foundation

/// Single source of truth for the PUBLIC chat command catalog.
///
/// Three surfaces derive from this one table so they can never drift again:
/// the Telegram "/" menu (`menuCommands`), the `/commands` listing
/// (`commandsListText`), and the shared block of the terminal `/help`
/// screen (`terminalHelpLines`).
///
/// Deliberately ABSENT from this table: the power/owner commands — /spend,
/// /more1|5|10, /hide, /show, /transcribe_local, /transcribe_openai — and
/// the /pulisci and /riavvia aliases. They keep working (this table controls
/// visibility, not dispatch) but stay out of `/commands` on purpose: the
/// listing is for regular users, and those were never meant for the menu.
struct ChatCommand {
    let name: String        // without the leading slash
    let description: String // shown in the Telegram menu and /commands
    let usage: String?      // argument hint for the terminal /help column
    let inMenu: Bool        // include in the trimmed Telegram "/" menu
    let category: String
}

enum ChatCommandRegistry {
    /// Grouping order for the /commands listing.
    static let categories = ["Control", "Models", "System", "Account"]

    static let commands: [ChatCommand] = [
        ChatCommand(name: "stop", description: "Stop the current work immediately",
                    usage: nil, inMenu: true, category: "Control"),
        ChatCommand(name: "status", description: "Show what Briglia is doing right now",
                    usage: nil, inMenu: true, category: "Control"),
        ChatCommand(name: "prune", description: "Free up Briglia's working memory",
                    usage: nil, inMenu: true, category: "Control"),
        ChatCommand(name: "continue", description: "Show the rest of a long reply",
                    usage: nil, inMenu: false, category: "Control"),
        ChatCommand(name: "model", description: "Show or switch the main model",
                    usage: "[id]", inMenu: true, category: "Models"),
        ChatCommand(name: "provider", description: "Show or switch the LLM provider",
                    usage: "[name]", inMenu: true, category: "Models"),
        ChatCommand(name: "effort", description: "Show or set the reasoning effort",
                    usage: "[level]", inMenu: true, category: "Models"),
        ChatCommand(name: "websearch", description: "Show or switch the web research backend",
                    usage: "[name]", inMenu: false, category: "Models"),
        ChatCommand(name: "subagentmodels", description: "Show or set the cheap subagent model lanes",
                    usage: nil, inMenu: false, category: "Models"),
        ChatCommand(name: "subagents", description: "Turn the Agent delegation tools on or off",
                    usage: "[on|off]", inMenu: false, category: "Models"),
        ChatCommand(name: "upgrade", description: "Update Briglia to the latest release",
                    usage: nil, inMenu: true, category: "System"),
        ChatCommand(name: "restart", description: "Restart Briglia (reloads mcp.json and skills)",
                    usage: nil, inMenu: false, category: "System"),
        ChatCommand(name: "commands", description: "List standard Briglia commands",
                    usage: nil, inMenu: true, category: "System"),
        ChatCommand(name: "subscription", description: "Connect or disconnect your ChatGPT subscription",
                    usage: "[login|cancel|logout|status]", inMenu: false, category: "Account"),
        ChatCommand(name: "setname", description: "Set or change your name (asks for confirmation)",
                    usage: "[name]", inMenu: false, category: "Account"),
        ChatCommand(name: "deleteuserdata", description: "Erase all memory and user data (asks for confirmation)",
                    usage: nil, inMenu: false, category: "Account"),
        ChatCommand(name: "exportmind", description: "Save a memory backup (.mind) to this computer (add 'lite' to skip files)",
                    usage: "[lite]", inMenu: false, category: "Account"),
        ChatCommand(name: "importmind", description: "Restore a memory backup (asks for confirmation)",
                    usage: "[path]", inMenu: false, category: "Account"),
        ChatCommand(name: "rotateaffinity", description: "Present a new session identity to OpenCode/OpenRouter from the next request (no data change)",
                    usage: nil, inMenu: false, category: "Account"),
        ChatCommand(name: "resumewatcher", description: "Review and re-arm watchers quarantined by a memory import",
                    usage: "[id]", inMenu: false, category: "Account"),
        ChatCommand(name: "switchbot", description: "Move Briglia to a different Telegram bot (guided, asks for confirmation)",
                    usage: "[token]", inMenu: false, category: "Account"),
    ]

    /// Telegram "/" menu order (owner, 2026-09-07): /status first, then the
    /// three switches that now answer with tap buttons, the everyday
    /// maintenance commands, /commands as the index to the rest, and /stop
    /// LAST so it is never the accidental first tap.
    static let menuOrder = ["status", "provider", "model", "effort", "prune", "upgrade", "commands", "stop"]

    /// The trimmed Telegram "/" menu: only the everyday commands a regular
    /// user needs (`inMenu`), in `menuOrder`. A command flagged inMenu but
    /// missing from menuOrder (or vice versa) is a registry bug the
    /// command-menu selftest catches.
    static var menuCommands: [(command: String, description: String)] {
        menuOrder.compactMap { name in
            commands.first { $0.name == name && $0.inMenu }.map { ($0.name, $0.description) }
        }
    }

    /// Body of the /commands reply: every public command, grouped.
    static func commandsListText() -> String {
        var lines = ["Briglia commands:"]
        for category in categories {
            let members = commands.filter { $0.category == category }
            guard !members.isEmpty else { continue }
            lines.append("")
            lines.append("\(category):")
            for cmd in members {
                lines.append("/\(cmd.name) — \(cmd.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Shared block of the terminal /help screen; TerminalSession appends
    /// its terminal-only commands (/attach, /quit) and the power commands.
    static func terminalHelpLines() -> [String] {
        commands.map { cmd in
            var invocation = "/" + cmd.name
            if let usage = cmd.usage { invocation += " " + usage }
            let padded = invocation.count < 18
                ? invocation + String(repeating: " ", count: 18 - invocation.count)
                : invocation + "  "
            return "  " + padded + cmd.description
        }
    }
}
