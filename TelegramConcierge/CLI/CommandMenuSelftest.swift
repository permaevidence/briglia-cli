import ArgumentParser
import Foundation

/// Hidden deterministic test pinning the chat command catalog contract
/// (owner, 2026-08-21; order + the three switches added 2026-09-07): the
/// Telegram "/" menu stays trimmed to the everyday commands, /commands lists every public command and NONE of the
/// power/owner commands, and the terminal /help block derives from the same
/// table. Pure static checks on ChatCommandRegistry — no storage touched.
struct CommandMenuSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__command-menu-selftest",
        abstract: "Internal: verify the chat command registry, Telegram menu and /commands listing.",
        shouldDisplay: false
    )

    func run() throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let commands = ChatCommandRegistry.commands
        let names = commands.map(\.name)

        // 1. The trimmed menu: exactly the five everyday commands, in order,
        // with /commands as the discoverable index to the rest.
        let menu = ChatCommandRegistry.menuCommands.map(\.command)
        check("menu is exactly status, provider, model, effort, prune, upgrade, commands, stop — in that order (owner 2026-09-07)",
              menu == ["status", "provider", "model", "effort", "prune", "upgrade", "commands", "stop"],
              menu.joined(separator: ", "))
        check("menu order and inMenu flags agree (no command flagged inMenu is left out, none listed is unflagged)",
              Set(commands.filter(\.inMenu).map(\.name)) == Set(ChatCommandRegistry.menuOrder)
              && ChatCommandRegistry.menuOrder.count == menu.count)
        check("/stop is the LAST menu entry, /status the first",
              menu.first == "status" && menu.last == "stop")
        check("deleteuserdata is NOT one tap away in the menu",
              !menu.contains("deleteuserdata"))
        check("menu descriptions are non-empty",
              ChatCommandRegistry.menuCommands.allSatisfy { !$0.description.isEmpty })

        // 2. Registry hygiene: no duplicates, every category renders.
        check("no duplicate command names", Set(names).count == names.count)
        check("every command's category is in the rendered category list",
              commands.allSatisfy { ChatCommandRegistry.categories.contains($0.category) })
        check("every category has at least one member",
              ChatCommandRegistry.categories.allSatisfy { cat in
                  commands.contains { $0.category == cat }
              })

        // 3. /commands lists every public command exactly once.
        let listing = ChatCommandRegistry.commandsListText()
        for name in names {
            check("/commands lists /\(name)", listing.contains("/\(name) — "))
        }

        // 4. …and none of the power/owner commands (decided 2026-08-21:
        // they keep working but stay out of the regular-user listing).
        for hidden in ["/spend", "/more1", "/more5", "/more10", "/hide", "/show",
                       "/transcribe", "/riavvia", "/pulisci", "/llm", "/attach", "/quit"] {
            check("/commands does not reveal \(hidden)", !listing.contains(hidden))
        }

        // 4b. /spend <scope> <usd|off> parsing (limits are OFF by default;
        // this is the only supported way to set them from chat).
        typealias SLC = SpendLimitCommand
        func parsed(_ text: String) -> SLC.Edit? { try? SLC.parse(text).get() }
        check("/spend turn 0.50 parses", parsed("turn 0.50") == SLC.Edit(scope: .turn, limitUSD: 0.5))
        check("/spend daily $5 parses (dollar sign, integer)", parsed("daily $5") == SLC.Edit(scope: .daily, limitUSD: 5))
        check("/spend monthly 12,5 parses (comma decimal)", parsed("monthly 12,5") == SLC.Edit(scope: .monthly, limitUSD: 12.5))
        check("/spend turn off removes the limit", parsed("turn off") == SLC.Edit(scope: .turn, limitUSD: nil))
        check("/spend daily 0 removes the limit", parsed("daily 0") == SLC.Edit(scope: .daily, limitUSD: nil))
        check("/spend weekly 5 is refused (unknown scope)", parsed("weekly 5") == nil)
        check("/spend turn abc is refused (not an amount)", parsed("turn abc") == nil)
        check("/spend turn 0.0001 is refused (below the minimum)", parsed("turn 0.0001") == nil)
        check("/spend turn is refused (missing value)", parsed("turn") == nil)
        check("/spend turn 1 2 is refused (extra token)", parsed("turn 1 2") == nil)
        check("stored value is plain decimal text", SLC.storedValue(0.5) == "0.5" && SLC.storedValue(5) == "5" && SLC.storedValue(12.345) == "12.345")

        // 5. Terminal /help derives one line per public command, carrying
        // both the invocation and the description.
        let helpLines = ChatCommandRegistry.terminalHelpLines()
        check("terminal help has one line per command", helpLines.count == commands.count)
        check("terminal help lines carry invocation + description",
              zip(helpLines, commands).allSatisfy { line, cmd in
                  line.contains("/\(cmd.name)") && line.contains(cmd.description)
              })

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
