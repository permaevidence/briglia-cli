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

    /// Runs `body` under the sidecar lock of the MCP routing/config file when
    /// `path` is one of them (forward path and rollback alike).
    static func withConfigFileLock<T>(_ path: String, _ body: () throws -> T) throws -> T {
        try MCPAgentRouting.withLockIfRoutingFile(path, body)
    }
}
