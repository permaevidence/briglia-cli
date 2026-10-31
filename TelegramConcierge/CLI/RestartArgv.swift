import Foundation

/// The command line a self-restart re-executes (`/upgrade`, `/restart`, the
/// barrier's `reexecIfOlder`). Normally the process's own argv, unchanged.
///
/// A terminal chat that began life as `briglia menu` (Start) or
/// `briglia quicksetup` ("Start Briglia now?") on macOS keeps that original
/// argv, and re-executing it reopens the menu / quick setup instead of the
/// assistant (2026-10-31: the menu image refused during the committed update
/// with exit 75 and the assistant never came back). The promotion to an
/// assistant therefore switches the restart command to `briglia chat`,
/// keeping argv[0] and a leading global `--profile` exactly as typed; the
/// environment (`BRIGLIA_PROFILE`, `BRIGLIA_EXPERIMENTAL_PROFILES`, …) is
/// inherited by the exec as before.
enum RestartArgv {
    nonisolated(unsafe) private static var override: [String]?

    /// What a self-restart passes to `execv`.
    static var current: [String] { override ?? CommandLine.arguments }

    /// Pure: `original` (full argv, argv[0] included) turned into the chat
    /// entry. Only the leading global profile flag survives (ProfileBootstrap
    /// accepts it only as the first argument); the menu/quick-setup
    /// subcommand and its own options are dropped.
    static func chatArguments(from original: [String]) -> [String] {
        guard let argv0 = original.first else { return ["briglia", "chat"] }
        var out = [argv0]
        let rest = Array(original.dropFirst())
        if let first = rest.first {
            if first == "--profile", rest.count >= 2 {
                out += [first, rest[1]]
            } else if first.hasPrefix("--profile=") {
                out.append(first)
            }
        }
        out.append("chat")
        return out
    }

    /// Called when this process becomes the terminal chat (menu Start, quick
    /// setup). Idempotent.
    static func switchToChat() {
        override = chatArguments(from: CommandLine.arguments)
    }

    /// Selftests only.
    static func resetForTesting() { override = nil }
}
