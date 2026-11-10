import Foundation

/// Protected-path checks shared by the legacy `apply_patch` (`ApplyPatch`)
/// and the GPT engine (`CodexPatch`) — GPT_APPLY_PATCH_PLAN §6.4. A
/// behaviour-preserving extraction: the legacy engine's texts and decisions
/// are unchanged.
enum EditProtections {

    /// Sign in with ChatGPT files (SIWC plan §3.8): never written, deleted or
    /// moved by a file tool, as source or destination.
    static func siwcRefusal(_ paths: [String]) -> String? {
        paths.contains(where: { SIWCProtectedFiles.isProtected($0) }) ? SIWCProtectedFiles.refusal : nil
    }

    static func isSecretStore(_ path: String) -> Bool { HarnessSecretStore.isSecretStore(path) }

    /// The secret store's hunk refusal for a CodexPatch update: every
    /// non-context line of every chunk, in patch order (removed lines before
    /// added lines within a chunk, as the patch lists them).
    static func secretStoreChunkRefusal(_ chunks: [CodexPatch.Chunk]) -> String? {
        var changed: [(added: Bool, text: String)] = []
        for chunk in chunks {
            let oldContext = Set(chunk.contextLineIndices.map(\.old))
            let newContext = Set(chunk.contextLineIndices.map(\.new))
            for (i, line) in chunk.oldLines.enumerated() where !oldContext.contains(i) { changed.append((added: false, text: line)) }
            for (i, line) in chunk.newLines.enumerated() where !newContext.contains(i) { changed.append((added: true, text: line)) }
        }
        return HarnessSecretStore.patchRefusal(changedLines: changed)
    }

    /// Pre-release review S1: the exact placeholders tool output can show in
    /// this process — `[REDACTED:<label>]` for every label of the live
    /// redaction environment (the Telegram bot token, the ChatGPT sign-in
    /// tokens and the user's service keys) and for every `service_key_env`
    /// alias a bash command used (Codex round 1: bash merges a command's
    /// aliases into its redactor). Never the bare `[REDACTED:` prefix: files
    /// such as Briglia's own sources legitimately contain it.
    static func currentRedactionPlaceholders() -> [String] {
        Set(KeychainHelper.redactionEnvironment().keys)
            .union(BashTools.RedactionAliases.shared.labels)
            .sorted().map { "[REDACTED:\($0)]" }
    }

    /// The first placeholder of `placeholders` that `text` contains, or nil.
    static func placeholder(in text: String, _ placeholders: [String]) -> String? {
        guard text.contains("[REDACTED:") else { return nil }
        return placeholders.first { text.contains($0) }
    }

    /// Runs `body` under the sidecar lock of the MCP routing/config file when
    /// `path` is one of them (forward path and rollback alike).
    static func withConfigFileLock<T>(_ path: String, _ body: () throws -> T) throws -> T {
        try MCPAgentRouting.withLockIfRoutingFile(path, body)
    }
}
