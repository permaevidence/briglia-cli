import Foundation

/// The `.gpt` tool surface (GPT_APPLY_PATCH_PLAN §4). `.standard` lists are
/// never touched: `applyEditing(_, .standard)` returns its input unchanged.
extension AvailableTools {

    // MARK: apply_patch (§4.2)

    /// Freeform description, verbatim from the pinned Codex commit
    /// (`apply_patch_spec.rs` at 4e4767f; Apache-2.0).
    static let gptApplyPatchFreeformDescription = "The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON."

    /// JSON description: Codex's last JSON-tool description (`apply_patch_spec.rs`
    /// at cf941ede, vendored in scripts/fixtures/codex-apply-patch/json-spec,
    /// Apache-2.0) with exactly `gptApplyPatchJSONSubstitutions` applied
    /// (absolute paths, §4.2).
    static let gptApplyPatchJSONDescription = "Use the `apply_patch` tool to edit files.\nYour patch language is a stripped‑down, file‑oriented diff format designed to be easy to parse and safe to apply. You can think of it as a high‑level envelope:\n\n*** Begin Patch\n[ one or more file sections ]\n*** End Patch\n\nWithin that envelope, you get a sequence of file operations.\nYou MUST include a header to specify the action you are taking.\nEach operation starts with one of three headers:\n\n*** Add File: <path> - create a new file. Every following line is a + line (the initial contents).\n*** Delete File: <path> - remove an existing file. Nothing follows.\n*** Update File: <path> - patch an existing file in place (optionally with a rename).\n\nMay be immediately followed by *** Move to: <new path> if you want to rename the file.\nThen one or more “hunks”, each introduced by @@ (optionally followed by a hunk header).\nWithin a hunk each line starts with:\n\nFor instructions on [context_before] and [context_after]:\n- By default, show 3 lines of code immediately above and 3 lines immediately below each change. If a change is within 3 lines of a previous change, do NOT duplicate the first change’s [context_after] lines in the second change’s [context_before] lines.\n- If 3 lines of context is insufficient to uniquely identify the snippet of code within the file, use the @@ operator to indicate the class or function to which the snippet belongs. For instance, we might have:\n@@ class BaseClass\n[3 lines of pre-context]\n- [old_code]\n+ [new_code]\n[3 lines of post-context]\n\n- If a code block is repeated so many times in a class or function such that even a single `@@` statement and 3 lines of context cannot uniquely identify the snippet of code, you can use multiple `@@` statements to jump to the right context. For instance:\n\n@@ class BaseClass\n@@ \t def method():\n[3 lines of pre-context]\n- [old_code]\n+ [new_code]\n[3 lines of post-context]\n\nThe full grammar definition is below:\nPatch := Begin { FileOp } End\nBegin := \"*** Begin Patch\" NEWLINE\nEnd := \"*** End Patch\" NEWLINE\nFileOp := AddFile | DeleteFile | UpdateFile\nAddFile := \"*** Add File: \" path NEWLINE { \"+\" line NEWLINE }\nDeleteFile := \"*** Delete File: \" path NEWLINE\nUpdateFile := \"*** Update File: \" path NEWLINE [ MoveTo ] { Hunk }\nMoveTo := \"*** Move to: \" newPath NEWLINE\nHunk := \"@@\" [ header ] NEWLINE { HunkLine } [ \"*** End of File\" NEWLINE ]\nHunkLine := (\" \" | \"-\" | \"+\") text NEWLINE\n\nA full patch can combine several operations:\n\n*** Begin Patch\n*** Add File: /Users/me/project/hello.txt\n+Hello world\n*** Update File: /Users/me/project/src/app.py\n*** Move to: /Users/me/project/src/main.py\n@@ def greet():\n-print(\"Hi\")\n+print(\"Hello, world!\")\n*** Delete File: /Users/me/project/obsolete.txt\n*** End Patch\n\nIt is important to remember:\n\n- You must include a header with your intended action (Add/Delete/Update)\n- You must prefix new lines with `+` even when creating a new file\n- File references must be absolute paths, NEVER RELATIVE.\n"

    /// (Codex text, Briglia text) pairs applied to the vendored description.
    static let gptApplyPatchJSONSubstitutions: [(String, String)] = [
        ("*** Add File: hello.txt", "*** Add File: /Users/me/project/hello.txt"),
        ("*** Update File: src/app.py", "*** Update File: /Users/me/project/src/app.py"),
        ("*** Move to: src/main.py", "*** Move to: /Users/me/project/src/main.py"),
        ("*** Delete File: obsolete.txt", "*** Delete File: /Users/me/project/obsolete.txt"),
        ("- File references can only be relative, NEVER ABSOLUTE.", "- File references must be absolute paths, NEVER RELATIVE.")
    ]

    /// The one internal definition of the GPT `apply_patch` (§4.2): a
    /// required `input` string. The Responses adapter renders it as Codex's
    /// freeform grammar tool when the run's form is `.freeform`.
    static let applyPatchGPT = ToolDefinition(
        function: FunctionDefinition(
            name: "apply_patch",
            description: gptApplyPatchJSONDescription,
            parameters: FunctionParameters(
                properties: ["input": ParameterProperty(type: "string", description: "The entire contents of the apply_patch command")],
                required: ["input"]
            )
        )
    )

    // MARK: Rewritten descriptions (§4.3)

    /// The bash note of a GPT run that can patch (pre-release review S1: plus
    /// the one sentence about redaction placeholders).
    static let gptReadNote = "Reading files with `cat`, `sed -n`, `nl -ba` or `rg` is fine. Edit files with the apply_patch tool, not with shell redirection or `sed -i`. Registered secrets in bash output appear as `[REDACTED:…]` placeholders, which are not the files' real text: never copy one into a patch."
    /// The bash note of a GPT run without apply_patch (a read-only child with
    /// bash, e.g. Browse): nothing about editing (pre-release review S2).
    static let gptReadOnlyNote = "Reading files with `cat`, `sed -n`, `nl -ba` or `rg` is fine."

    /// (tool name, standard text, GPT text). Each pair must match exactly
    /// once in the standard description (selftest).
    static let gptDescriptionRewrites: [(tool: String, from: String, to: String)] = [
        ("read_file", "IMPORTANT: when passing content back to edit_file as old_string, DO NOT include the line-number prefix — it is display-only, not part of the file.",
                      "The line-number prefix is display-only and never part of the file; never copy it into a patch."),
        ("read_file", "- Do NOT re-read a file you just edited to verify — edit_file/write_file would have errored if the change failed, and the harness tracks file state for you.",
                      "- Do NOT re-read a file you just patched to verify — apply_patch would have errored if the change failed."),
        ("grep", "- ALWAYS use grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The grep tool has been optimized for correct permissions, ignore lists, and output shaping — the Bash equivalents bypass all of that.",
                 "- Use this tool or `rg` in bash, whichever is simpler."),
        ("grep", "never build edit_file old_string or write_file content from a redacted grep line;",
                 "never copy a redacted grep line into a patch;"),
        ("glob", "- Use instead of bash find/ls — the glob tool has optimized permissions and output.",
                 "- Use this tool or `find`/`ls` in bash, whichever is simpler."),
        ("bash", "Prefer glob, grep, read_file, edit_file, and write_file for file operations, and reply directly instead of using echo/printf for communication.",
                 gptReadNote + " Reply directly instead of using echo/printf for communication."),
        ("bash", "Prefer dedicated file/search tools when applicable.", gptReadNote),
        ("bash", "Prefer the dedicated file/search/edit tools when applicable.", gptReadNote),
    ]

    /// The `.gpt` variant of one definition (identity for tools §4.3 does
    /// not name). Bash variants are told apart by their own text, so the
    /// main, managed-subagent and foreground-only `bash` all get the note;
    /// a run whose list has no apply_patch (`canPatch` false) gets the
    /// read-only note (pre-release review S2).
    static func gptVariant(_ tool: ToolDefinition, canPatch: Bool = true) -> ToolDefinition {
        let rewrites = gptDescriptionRewrites.filter { $0.tool == tool.function.name }
        guard !rewrites.isEmpty else { return tool }
        var description = tool.function.description
        for rewrite in rewrites where description.contains(rewrite.from) {
            description = description.replacingOccurrences(of: rewrite.from, with: rewrite.to)
        }
        if !canPatch { description = description.replacingOccurrences(of: gptReadNote, with: gptReadOnlyNote) }
        return ToolDefinition(function: FunctionDefinition(name: tool.function.name, description: description,
                                                           parameters: tool.function.parameters))
    }

    /// §4.1: the tool list for `editing`. `.standard` returns `tools`
    /// unchanged (I1). `.gpt` removes `edit_file`, `write_file` and any
    /// legacy `apply_patch`, puts the GPT `apply_patch` in the slot the
    /// first of them held (only if one was present: a list without file
    /// edit tools gains none), and rewrites the §4.3 descriptions.
    static func applyEditing(_ tools: [ToolDefinition], _ editing: EditingConfig) -> [ToolDefinition] {
        guard editing.isGPT else { return tools }
        let canPatch = tools.contains { gptPatchGrantingNames.contains($0.function.name) }
        var out: [ToolDefinition] = []
        var inserted = false
        for tool in tools {
            switch tool.function.name {
            case "edit_file", "write_file", "apply_patch":
                if !inserted { out.append(applyPatchGPT); inserted = true }
            default:
                out.append(gptVariant(tool, canPatch: canPatch))
            }
        }
        return out
    }

    /// `all(includeWebSearch:hasDeferredMCPs:)` for a run's editing configuration.
    static func all(includeWebSearch: Bool, hasDeferredMCPs: Bool = false, editing: EditingConfig) -> [ToolDefinition] {
        applyEditing(all(includeWebSearch: includeWebSearch, hasDeferredMCPs: hasDeferredMCPs), editing)
    }

    /// Names that grant the GPT `apply_patch` in a `.gpt` child's whitelist (§3.3).
    static let gptPatchGrantingNames: Set<String> = ["edit_file", "write_file", "apply_patch"]
}
