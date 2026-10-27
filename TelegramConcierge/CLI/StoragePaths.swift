import Foundation

/// Canonical on-disk locations for Briglia CLI.
///
/// The CLI deliberately does NOT use Ada.app's paths (`~/Library/Application
/// Support/Ada` and `~/Ada`) so both products can coexist on the same Mac.
/// XDG-style paths are used on macOS too, which makes them valid unchanged on
/// Linux.
///
/// Roots are RESOLVED lazily but never CREATED by resolution (rename plan
/// §4.2): a diagnostic command (`--version`, `bundle-check`, `doctor`,
/// `setup-api status`, `service status`, `migrate --status`) must not
/// materialize empty `~/.config/briglia` / `~/.local/share/briglia`
/// directories — an empty new root would mask the "old install present,
/// new roots absent" detection that gates the explicit `briglia migrate`.
/// Mutating entry points call `ensureRoots()` first; the secret store
/// creates its own parent on write.
enum StoragePaths {
    /// The product directory name under the XDG bases.
    static let productDirName = "briglia"

    /// State and caches (sessions, archives, ledger, logs, attachments,
    /// projects): `$XDG_DATA_HOME/briglia`, default `~/.local/share/briglia`.
    /// An extra assistant profile (MULTI_ASSISTANT_PLAN §3) uses
    /// `$XDG_DATA_HOME/briglia-profiles/<name>` instead; the selection is made
    /// by `ProfileBootstrap` before this static is first read.
    static let dataRoot: URL = AssistantProfile.selectedDataRoot()

    /// User-editable configuration (mcp.json, mcp-routing.json, agents/,
    /// skills/, agent-turns.json): `$XDG_CONFIG_HOME/briglia`, default
    /// `~/.config/briglia`.
    static let configRoot: URL = AssistantProfile.selectedConfigRoot()

    /// Human-readable equivalents for prompts and user-facing messages
    /// (today's literals for the default profile, byte for byte).
    static let dataRootDisplay = AssistantProfile.dataRootDisplay
    static let configRootDisplay = AssistantProfile.configRootDisplay

    /// Pure resolution (no filesystem effects), also used by the identity
    /// migration to compute the OLD product's roots under the same XDG rules.
    static func resolveDataRoot(productDirName name: String = productDirName,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        xdgBase(env: "XDG_DATA_HOME", fallback: ".local/share",
                environment: environment, home: home)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func resolveConfigRoot(productDirName name: String = productDirName,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        xdgBase(env: "XDG_CONFIG_HOME", fallback: ".config",
                environment: environment, home: home)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Create both roots (idempotent). Called by every entry point that is
    /// allowed to write state; never by diagnostics.
    static func ensureRoots() {
        try? ensureRootsChecked()
    }

    /// Same, but a root that cannot be created or tightened (it exists as a
    /// regular file, a FIFO, a link to nowhere, …) is reported: mutating
    /// entry points that would otherwise run against a broken root call
    /// this and stop.
    static func ensureRootsChecked() throws {
        for root in [configRoot, dataRoot] {
            // Both roots are owner-only (0700): with a 0700 parent no mode
            // inside can make a child reachable by another account.
            try PrivateStorage.ensureDirectory(root, mode: 0o700)
        }
    }

    private static func xdgBase(env: String, fallback: String,
                                environment: [String: String], home: URL) -> URL {
        if let value = environment[env], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }
}
