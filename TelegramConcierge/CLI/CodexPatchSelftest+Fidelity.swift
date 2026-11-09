import Foundation

/// §14.1 source fidelity: every `#[test]` of the pinned `parser.rs`,
/// `streaming_parser.rs`, `seek_sequence.rs`, `file_update_tests.rs` and
/// `lib.rs`, ported as Swift expectations. Each check carries a
/// `rust:<module>::<test>` tag; `scripts/codex_patch_fidelity_check.py`
/// fails when a Rust test has neither a tagged check nor a recorded
/// exemption (`fidelity-exemptions.txt`).
extension CodexPatchSelftest {
    typealias H = CodexPatch.Hunk
    typealias C = CodexPatch.Chunk
    typealias PE = CodexPatch.ParseError

    static func expectParse(_ t: CPTest, _ label: String, _ text: String, _ mode: CodexPatch.ParseMode, hunks: [H]) {
        do {
            let args = try CodexPatch.parsePatchText(text, mode: mode)
            t.check(label, args.hunks == hunks, "got \(args.hunks)")
        } catch { t.check(label, false, "threw \(error)") }
    }

    static func expectParseError(_ t: CPTest, _ label: String, _ text: String, _ mode: CodexPatch.ParseMode, _ expected: PE) {
        do {
            let args = try CodexPatch.parsePatchText(text, mode: mode)
            t.check(label, false, "parsed \(args.hunks)")
        } catch let e as PE { t.check(label, e == expected, "got \(e)") } catch { t.check(label, false, "threw \(error)") }
    }

    static let firstLineError = PE.invalidPatch("The first line of the patch must be '*** Begin Patch'")
    static let lastLineError = PE.invalidPatch("The last line of the patch must be '*** End Patch'")

    // MARK: parser.rs

    static func fidelityParser(_ t: CPTest) async {
        let tag = "rust:parser::test_parse_patch"
        expectParseError(t, "F.1a \(tag) bad first line", "bad", .strict, firstLineError)
        expectParseError(t, "F.1b \(tag) missing end", "*** Begin Patch\nbad", .strict, lastLineError)
        expectParse(t, "F.1c \(tag) padded markers", "*** Begin Patch \n*** Add File: foo\n+hi\n *** End Patch", .strict, hunks: [.add("foo", "hi\n")])
        expectParseError(t, "F.1d \(tag) empty update", "*** Begin Patch\n*** Update File: test.py\n*** End Patch", .strict,
                         .invalidHunk(message: "Update file hunk for path 'test.py' is empty", lineNumber: 2))
        expectParse(t, "F.1e \(tag) zero hunks", "*** Begin Patch\n*** End Patch", .strict, hunks: [])
        expectParse(t, "F.1f \(tag) add/delete/update+move",
                    "*** Begin Patch\n*** Add File: path/add.py\n+abc\n+def\n*** Delete File: path/delete.py\n*** Update File: path/update.py\n*** Move to: path/update2.py\n@@ def f():\n-    pass\n+    return 123\n*** End Patch",
                    .strict, hunks: [.add("path/add.py", "abc\ndef\n"), .delete("path/delete.py"),
                                     .update("path/update.py", move: "path/update2.py", [C(changeContext: "def f():", oldLines: ["    pass"], newLines: ["    return 123"])])])
        expectParse(t, "F.1g \(tag) update then add",
                    "*** Begin Patch\n*** Update File: file.py\n@@\n+line\n*** Add File: other.py\n+content\n*** End Patch",
                    .strict, hunks: [.update("file.py", [C(newLines: ["line"])]), .add("other.py", "content\n")])
        expectParse(t, "F.1h \(tag) first chunk without @@",
                    "*** Begin Patch\n*** Update File: file2.py\n import foo\n+bar\n*** End Patch",
                    .strict, hunks: [.update("file2.py", [C(oldLines: ["import foo"], newLines: ["import foo", "bar"], contextLineIndices: [.init(old: 0, new: 0)])])])

        do {
            let tag2 = "rust:parser::test_parse_patch_preserves_end_of_file_marker"
            let patch = "*** Begin Patch\n*** Update File: file.txt\n@@\n+quux\n*** End of File\n\n*** End Patch"
            let args = try CodexPatch.parsePatch(patch)
            let expected = CodexPatch.Args(hunks: [.update("file.txt", [C(newLines: ["quux"], isEndOfFile: true)])], patch: patch, environmentID: nil)
            t.check("F.2 \(tag2)", args == expected, "got \(args)")
        } catch { t.check("F.2 rust:parser::test_parse_patch_preserves_end_of_file_marker", false, "threw \(error)") }

        let abs = t.dir("f3")
        expectParse(t, "F.3 rust:parser::test_parse_patch_accepts_relative_and_absolute_hunk_paths",
                    "*** Begin Patch\n*** Add File: relative-add.py\n+content\n*** Delete File: \(abs)/absolute-delete.py\n*** Update File: \(abs)/absolute-update.py\n@@\n-old\n+new\n*** End Patch",
                    .strict, hunks: [.add("relative-add.py", "content\n"), .delete("\(abs)/absolute-delete.py"),
                                     .update("\(abs)/absolute-update.py", [C(oldLines: ["old"], newLines: ["new"])])])
        // test_hunk_resolve_path_accepts_relative_and_absolute_paths is exempt
        // (Briglia has no cwd, D2); its Briglia analogue: relative refused,
        // absolute accepted (engine path tests E.P*).

        let patch = "*** Begin Patch\n*** Update File: file2.py\n import foo\n+bar\n*** End Patch"
        let expectedHunks: [H] = [.update("file2.py", [C(oldLines: ["import foo"], newLines: ["import foo", "bar"], contextLineIndices: [.init(old: 0, new: 0)])])]
        let lt = "rust:parser::test_parse_patch_lenient"
        for (i, (open, name)) in [("<<EOF", "bare"), ("<<'EOF'", "single"), ("<<\"EOF\"", "double")].enumerated() {
            let heredoc = "\(open)\n\(patch)\nEOF\n"
            expectParseError(t, "F.4\(["a", "b", "c"][i]) \(lt) \(name) heredoc strict", heredoc, .strict, firstLineError)
            do {
                let args = try CodexPatch.parsePatchText(heredoc, mode: .lenient)
                t.check("F.4\(["d", "e", "f"][i]) \(lt) \(name) heredoc lenient", args == CodexPatch.Args(hunks: expectedHunks, patch: patch, environmentID: nil), "got \(args)")
            } catch { t.check("F.4\(["d", "e", "f"][i]) \(lt) \(name) heredoc lenient", false, "threw \(error)") }
        }
        let mismatched = "<<\"EOF'\n\(patch)\nEOF\n"
        expectParseError(t, "F.4g \(lt) mismatched quotes strict", mismatched, .strict, firstLineError)
        expectParseError(t, "F.4h \(lt) mismatched quotes lenient", mismatched, .lenient, firstLineError)
        let missingClose = "<<EOF\n*** Begin Patch\n*** Update File: file2.py\nEOF\n"
        expectParseError(t, "F.4i \(lt) missing end strict", missingClose, .strict, firstLineError)
        expectParseError(t, "F.4j \(lt) missing end lenient", missingClose, .lenient, lastLineError)

        let et = "rust:parser::test_parse_patch_environment_id_preamble"
        do {
            let text = "*** Begin Patch\n*** Environment ID: remote\n*** Add File: hello.txt\n+hello\n*** End Patch"
            let args = try CodexPatch.parsePatchText(text, mode: .strict)
            t.check("F.5a \(et)", args == CodexPatch.Args(hunks: [.add("hello.txt", "hello\n")], patch: text, environmentID: "remote"), "got \(args)")
        } catch { t.check("F.5a \(et)", false, "threw \(error)") }
        expectParseError(t, "F.5b \(et) empty id", "*** Begin Patch\n*** Environment ID:   \n*** Add File: hello.txt\n+hello\n*** End Patch",
                         .strict, .invalidPatch("apply_patch environment_id cannot be empty"))
    }

    /// §14.1 explicit vectors beyond the Rust tests.
    static func fidelityExtraVectors(_ t: CPTest) {
        expectParse(t, "F.6a CRLF patch input through parse_patch (lines() drops one \\r, the parser another)",
                    "*** Begin Patch\r\n*** Update File: a.txt\r\n@@\r\n-old\r\r\n+new\r\n*** End Patch\r\n", .lenient,
                    hunks: [.update("a.txt", [C(oldLines: ["old"], newLines: ["new"])])])
        expectParse(t, "F.6b an empty Add (header, no + lines) parses", "*** Begin Patch\n*** Add File: e.txt\n*** End Patch", .lenient, hunks: [.add("e.txt", "")])
        expectParse(t, "F.6c a final End Patch without newline after a bare @@-less chunk",
                    "*** Begin Patch\n*** Update File: f\n x\n+y\n*** End Patch", .lenient,
                    hunks: [.update("f", [C(oldLines: ["x"], newLines: ["x", "y"], contextLineIndices: [.init(old: 0, new: 0)])])])
        expectParseError(t, "F.6d empty input reports the End Patch error (no first line)", "   \n ", .lenient, lastLineError)
        expectParseError(t, "F.6e a heredoc needs at least 4 lines", "<<EOF\n*** Begin Patch\nEOF", .lenient, firstLineError)
        expectParse(t, "F.6f markers padded with Unicode whitespace (em space) are recognised",
                    "\u{2003}*** Begin Patch\n*** Add File: u.txt\n+u\n*** End Patch\u{2003}", .lenient, hunks: [.add("u.txt", "u\n")])
        expectParseError(t, "F.6g an EOF chunk followed by a non-@@ line",
                         "*** Begin Patch\n*** Update File: f\n@@\n-a\n+b\n*** End of File\n-c\n*** End Patch", .lenient,
                         .invalidHunk(message: "Expected update hunk to start with a @@ context marker, got: '-c'", lineNumber: 7))
    }

    // MARK: streaming_parser.rs

    static func push(_ p: inout CodexPatch.StreamingParser, _ s: String) -> Swift.Result<[H], Error> {
        do { return .success(try p.pushDelta(s)) } catch { return .failure(error) }
    }

    static func same(_ r: Swift.Result<[H], Error>, _ hunks: [H]) -> Bool {
        if case .success(let h) = r { return h == hunks }
        return false
    }

    static func sameError(_ r: Swift.Result<[H], Error>, _ e: PE) -> Bool {
        if case .failure(let err as PE) = r { return err == e }
        return false
    }

    static func fidelityStreaming(_ t: CPTest) async {
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_streams_complete_lines_before_end_patch"
            var p = CodexPatch.StreamingParser()
            t.check("F.10a \(tag)", same(push(&p, "*** Begin Patch\n*** Add File: src/hello.txt\n+hello\n+wor"), [.add("src/hello.txt", "hello\n")]))
            t.check("F.10b \(tag)", same(push(&p, "ld\n"), [.add("src/hello.txt", "hello\nworld\n")]))
            p = CodexPatch.StreamingParser()
            t.check("F.10c \(tag)", same(push(&p, "*** Begin Patch\n*** Update File: src/old.rs\n*** Move to: src/new.rs\n@@\n-old\n+new\n"),
                                         [.update("src/old.rs", move: "src/new.rs", [C(oldLines: ["old"], newLines: ["new"])])]))
            p = CodexPatch.StreamingParser()
            t.check("F.10d \(tag)", same(push(&p, "*** Begin Patch\n*** Delete File: gone.txt"), []))
            t.check("F.10e \(tag)", same(push(&p, "\n"), [.delete("gone.txt")]))
            p = CodexPatch.StreamingParser()
            t.check("F.10f \(tag)", same(push(&p, "*** Begin Patch\n*** Add File: src/one.txt\n+one\n*** Delete File: src/two.txt\n"),
                                         [.add("src/one.txt", "one\n"), .delete("src/two.txt")]))
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_environment_id_mode"
            var p = CodexPatch.StreamingParser()
            t.check("F.11a \(tag)", same(push(&p, "*** Begin Patch\n*** Environment ID: remote\n*** Add File: src/hello.txt\n+hello\n*** End Patch\n"),
                                         [.add("src/hello.txt", "hello\n")]) && p.environmentID == "remote")
            p = CodexPatch.StreamingParser()
            t.check("F.11b \(tag)", sameError(push(&p, "*** Begin Patch\n*** Environment ID: first\n*** Environment ID: second\n"),
                                              .invalidPatch("apply_patch environment_id cannot be specified more than once")))
            p = CodexPatch.StreamingParser()
            t.check("F.11c \(tag)", sameError(push(&p, "*** Begin Patch\n*** Environment ID:   \n"), .invalidPatch("apply_patch environment_id cannot be empty")))
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_large_patch_split_by_character"
            let patch = """
            *** Begin Patch
            *** Add File: docs/release-notes.md
            +# Release notes
            +
            +## CLI
            +- Surface apply_patch progress while arguments stream.
            +- Keep final patch application gated on the completed tool call.
            +- Include file summaries in the progress event payload.
            *** Update File: src/config.rs
            @@ impl Config
            -    pub apply_patch_progress: bool,
            +    pub stream_apply_patch_progress: bool,
                 pub include_diagnostics: bool,
            @@ fn default_progress_interval()
            -    Duration::from_millis(500)
            +    Duration::from_millis(250)
            *** Delete File: src/legacy_patch_progress.rs
            *** Update File: crates/cli/src/main.rs
            *** Move to: crates/cli/src/bin/codex.rs
            @@ fn run()
            -    let args = Args::parse();
            -    dispatch(args)
            +    let cli = Cli::parse();
            +    dispatch(cli)
            *** Add File: tests/fixtures/apply_patch_progress.json
            +{
            +  "type": "apply_patch_progress",
            +  "hunks": [
            +    { "operation": "add", "path": "docs/release-notes.md" },
            +    { "operation": "update", "path": "src/config.rs" }
            +  ]
            +}
            *** Update File: README.md
            @@ Development workflow
             Build the Rust workspace before opening a pull request.
            +When touching streamed tool calls, include parser coverage for partial input.
            +Prefer tests that exercise the exact event payload shape.
            *** Delete File: docs/old-apply-patch-progress.md
            *** End Patch
            """
            var p = CodexPatch.StreamingParser()
            var maxCount = 0, saw: [Int] = [], hunks: [H] = [], monotonic = true, threw = false
            for scalar in patch.unicodeScalars {
                guard case .success(let updated) = push(&p, String(scalar)) else { threw = true; break }
                if !updated.isEmpty {
                    if updated.count < maxCount { monotonic = false }
                    if updated.count > maxCount { saw.append(updated.count); maxCount = updated.count }
                    hunks = updated
                }
            }
            let kinds = hunks.map { h -> String in
                switch h.kind { case .add: return "add"; case .delete: return "delete"; case .update: return h.movePath == nil ? "update" : "move-update" }
            }
            t.check("F.12 \(tag)", !threw && monotonic && saw == [1, 2, 3, 4, 5, 6, 7] && hunks.count == 7
                    && kinds == ["add", "update", "delete", "move-update", "add", "update", "delete"], "saw \(saw) kinds \(kinds)")
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_keeps_indented_update_markers_as_context_lines"
            var p = CodexPatch.StreamingParser()
            t.check("F.13 \(tag)", same(push(&p, "*** Begin Patch\n*** Update File: a.txt\n@@\n-old a\n+new a\n *** Update File: b.txt\n@@\n-old b\n+new b\n*** End Patch\n"),
                                        [.update("a.txt", [C(oldLines: ["old a", "*** Update File: b.txt"], newLines: ["new a", "*** Update File: b.txt"], contextLineIndices: [.init(old: 1, new: 1)]),
                                                           C(oldLines: ["old b"], newLines: ["new b"])])]))
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_preserves_bare_empty_update_lines"
            var p = CodexPatch.StreamingParser()
            t.check("F.14 \(tag)", same(push(&p, "*** Begin Patch\n*** Update File: file.txt\n@@\n context before\n\n context after\n*** End Patch\n"),
                                        [.update("file.txt", [C(oldLines: ["context before", "", "context after"], newLines: ["context before", "", "context after"],
                                                                contextLineIndices: [.init(old: 0, new: 0), .init(old: 1, new: 1), .init(old: 2, new: 2)])])]))
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_ignores_empty_lines_after_end_of_file"
            var p = CodexPatch.StreamingParser()
            t.check("F.15 \(tag)", same(push(&p, "*** Begin Patch\n*** Update File: file.txt\n@@\n+quux\n*** End of File\n\n*** End Patch\n"),
                                        [.update("file.txt", [C(newLines: ["quux"], isEndOfFile: true)])]))
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_matches_line_ending_behavior"
            var p = CodexPatch.StreamingParser()
            t.check("F.16a \(tag)", same(push(&p, "*** Begin Patch\r\n*** Update File: file.txt\r\n@@\r\n-old\r\n+new\r\n*** End Patch\r\n"),
                                         [.update("file.txt", [C(oldLines: ["old"], newLines: ["new"])])]))
            p = CodexPatch.StreamingParser()
            t.check("F.16b \(tag)", same(push(&p, "*** Begin Patch\r\n*** Update File: file.txt\r\n@@\r\n-old\r\r\n+new\r\n*** End Patch\r\n"),
                                         [.update("file.txt", [C(oldLines: ["old\r"], newLines: ["new"])])]))
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_finish_processes_final_line_without_newline"
            var p = CodexPatch.StreamingParser()
            let a = same(push(&p, "*** Begin Patch\n*** Add File: file.txt\n+hello\n*** End Patch"), [.add("file.txt", "hello\n")])
            let b = (try? p.finish()) == [.add("file.txt", "hello\n")]
            t.check("F.17a \(tag)", a && b)
            p = CodexPatch.StreamingParser()
            let expected: [H] = [.update("file.txt", [C(oldLines: ["old"], newLines: ["new"])])]
            let c = same(push(&p, "*** Begin Patch\n*** Update File: file.txt\n@@\n-old\n+new\n *** End Patch"), expected)
            let d = (try? p.finish()) == expected
            t.check("F.17b \(tag)", c && d)
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_finish_requires_end_patch"
            var p = CodexPatch.StreamingParser()
            let a = same(push(&p, "*** Begin Patch\n*** Add File: file.txt\n+hello\n"), [.add("file.txt", "hello\n")])
            var finished: Swift.Result<[H], Error>
            do { finished = .success(try p.finish()) } catch { finished = .failure(error) }
            t.check("F.18 \(tag)", a && sameError(finished, lastLineError))
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_rejects_content_after_end_patch"
            var p = CodexPatch.StreamingParser()
            t.check("F.19a \(tag)", sameError(push(&p, "*** Begin Patch\n*** Add File: file.txt\n+hello\n*** End Patch\nextra\n"), lastLineError))
            p = CodexPatch.StreamingParser()
            t.check("F.19b \(tag)", same(push(&p, "*** Begin Patch\n*** Add File: file.txt\n+hello\n*** End Patch\n \t\n"), [.add("file.txt", "hello\n")]))
        }
        do {
            let tag = "rust:streaming_parser::test_streaming_patch_parser_returns_errors"
            let header = "is not a valid hunk header. Valid hunk headers: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'"
            var p = CodexPatch.StreamingParser()
            t.check("F.20a \(tag)", sameError(push(&p, "bad\n"), firstLineError))
            p = CodexPatch.StreamingParser()
            let ok0 = same(push(&p, "*** Begin Patch\n"), [])
            t.check("F.20b \(tag)", ok0 && sameError(push(&p, "bad\n"), .invalidHunk(message: "'bad' \(header)", lineNumber: 2)))
            p = CodexPatch.StreamingParser()
            t.check("F.20c \(tag)", sameError(push(&p, "*** Begin Patch\n*** Add File: file.txt\nbad\n"), .invalidHunk(message: "'bad' \(header)", lineNumber: 3)))
            p = CodexPatch.StreamingParser()
            t.check("F.20d \(tag)", sameError(push(&p, "*** Begin Patch\n*** Delete File: file.txt\nbad\n"), .invalidHunk(message: "'bad' \(header)", lineNumber: 3)))
            p = CodexPatch.StreamingParser()
            t.check("F.20e \(tag)", sameError(push(&p, "*** Begin Patch\n*** Update File: file.txt\n*** End Patch\n"),
                                              .invalidHunk(message: "Update file hunk for path 'file.txt' is empty", lineNumber: 2)))
            p = CodexPatch.StreamingParser()
            t.check("F.20f \(tag)", sameError(push(&p, "*** Begin Patch\n*** Update File: old.txt\n*** Move to: new.txt\n*** Delete File: other.txt\n"),
                                              .invalidHunk(message: "Update file hunk for path 'old.txt' is empty", lineNumber: 2)))
            p = CodexPatch.StreamingParser()
            t.check("F.20g \(tag)", sameError(push(&p, "*** Begin Patch\n*** Update File: file.txt\n@@\n*** End Patch\n"),
                                              .invalidHunk(message: "Update hunk does not contain any lines", lineNumber: 4)))
            p = CodexPatch.StreamingParser()
            t.check("F.20h \(tag)", sameError(push(&p, "*** Begin Patch\n*** Update File: file.txt\n@@\n*** End of File\n"),
                                              .invalidHunk(message: "Update hunk does not contain any lines", lineNumber: 4)))
            let unexpected = "Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)"
            p = CodexPatch.StreamingParser()
            t.check("F.20i \(tag)", sameError(push(&p, "*** Begin Patch\n*** Update File: file.txt\n@@\n@@\n"),
                                              .invalidHunk(message: "Unexpected line found in update hunk: '@@'. \(unexpected)", lineNumber: 4)))
            p = CodexPatch.StreamingParser()
            t.check("F.20j \(tag)", sameError(push(&p, "*** Begin Patch\n*** Update File: file.txt\n@@\n-old\nbad\n"),
                                              .invalidHunk(message: "Expected update hunk to start with a @@ context marker, got: 'bad'", lineNumber: 5)))
            p = CodexPatch.StreamingParser()
            t.check("F.20k \(tag)", sameError(push(&p, "*** Begin Patch\n*** Update File: file.txt\n@@\n*** Update File: other.txt\n"),
                                              .invalidHunk(message: "Unexpected line found in update hunk: '*** Update File: other.txt'. \(unexpected)", lineNumber: 4)))
        }
    }

    // MARK: seek_sequence.rs

    static func fidelitySeek(_ t: CPTest) {
        t.check("F.30 rust:seek_sequence::test_exact_match_finds_sequence", CodexPatch.seekSequence(["foo", "bar", "baz"], ["bar", "baz"], start: 0, eof: false) == 1)
        t.check("F.31 rust:seek_sequence::test_rstrip_match_ignores_trailing_whitespace", CodexPatch.seekSequence(["foo   ", "bar\t\t"], ["foo", "bar"], start: 0, eof: false) == 0)
        t.check("F.32 rust:seek_sequence::test_trim_match_ignores_leading_and_trailing_whitespace", CodexPatch.seekSequence(["    foo   ", "   bar\t"], ["foo", "bar"], start: 0, eof: false) == 0)
        t.check("F.33 rust:seek_sequence::test_pattern_longer_than_input_returns_none", CodexPatch.seekSequence(["just one line"], ["too", "many", "lines"], start: 0, eof: false) == nil)
    }

    // MARK: file_update_tests.rs (contents; unified-diff text exempt)

    static func derive(_ original: String, _ patch: String) -> String? {
        guard let args = try? CodexPatch.parsePatch(patch), let h = args.hunks.first, h.kind == .update,
              let d = try? CodexPatch.deriveNewContents(original: Data(original.utf8), path: h.path, chunks: h.chunks) else { return nil }
        return String(decoding: d.newContents, as: UTF8.self)
    }

    static func fidelityFileUpdate(_ t: CPTest) async {
        let wrap = t.wrap
        t.check("F.40 rust:file_update_tests::test_unified_diff (contents)",
                derive("foo\nbar\nbaz\nqux\n", wrap("*** Update File: multi.txt\n@@\n foo\n-bar\n+BAR\n@@\n baz\n-qux\n+QUX")) == "foo\nBAR\nbaz\nQUX\n")
        t.check("F.41 rust:file_update_tests::test_unified_diff_first_line_replacement (contents)",
                derive("foo\nbar\nbaz\n", wrap("*** Update File: first.txt\n@@\n-foo\n+FOO\n bar\n")) == "FOO\nbar\nbaz\n")
        t.check("F.42 rust:file_update_tests::test_unified_diff_last_line_replacement (contents)",
                derive("foo\nbar\nbaz\n", wrap("*** Update File: last.txt\n@@\n foo\n bar\n-baz\n+BAZ\n")) == "foo\nbar\nBAZ\n")
        t.check("F.43 rust:file_update_tests::test_unified_diff_insert_at_eof (contents)",
                derive("foo\nbar\nbaz\n", wrap("*** Update File: insert.txt\n@@\n+quux\n*** End of File\n")) == "foo\nbar\nbaz\nquux\n")
        let interleaved = wrap("*** Update File: %@\n@@\n a\n-b\n+B\n@@\n d\n-e\n+E\n@@\n f\n+g\n*** End of File")
        t.check("F.44a rust:file_update_tests::test_unified_diff_interleaved_changes (contents)",
                derive("a\nb\nc\nd\ne\nf\n", interleaved.replacingOccurrences(of: "%@", with: "interleaved.txt")) == "a\nB\nc\nd\nE\nf\ng\n")
        let d = t.dir("f44")
        let path = d + "/interleaved.txt"
        t.write(path, "a\nb\nc\nd\ne\nf\n")
        let r = await t.apply(interleaved.replacingOccurrences(of: "%@", with: path))
        t.check("F.44b rust:file_update_tests::test_unified_diff_interleaved_changes (apply)", r.outcome.status == .applied && t.read(path) == "a\nB\nc\nd\nE\nf\ng\n", r.text)
    }

    // MARK: lib.rs (Briglia applies absolute paths; divergences noted)

    static func fidelityLib(_ t: CPTest) async {
        do {
            let d = t.dir("f50"); let path = d + "/add.txt"
            let r = await t.apply(t.wrap("*** Add File: \(path)\n+ab\n+cd"))
            t.check("F.50 rust:lib::test_add_file_hunk_creates_file_with_contents",
                    r.text == "Success. Updated the following files:\nA \(path)" && t.read(path) == "ab\ncd\n", r.text)
        }
        do {
            // Absolute half ported; the relative half is refused (D2).
            let d = t.dir("f51")
            t.write(d + "/absolute-delete.txt", "delete absolute\n")
            t.write(d + "/absolute-update.txt", "absolute old\n")
            await t.seed(d + "/absolute-delete.txt")
            let r = await t.apply(t.wrap("*** Add File: \(d)/absolute-add.txt\n+absolute add\n*** Delete File: \(d)/absolute-delete.txt\n*** Update File: \(d)/absolute-update.txt\n@@\n-absolute old\n+absolute new"))
            t.check("F.51a rust:lib::test_apply_patch_hunks_accept_relative_and_absolute_paths (absolute)",
                    r.text == "Success. Updated the following files:\nA \(d)/absolute-add.txt\nM \(d)/absolute-update.txt\nD \(d)/absolute-delete.txt"
                    && t.read(d + "/absolute-add.txt") == "absolute add\n" && !t.exists(d + "/absolute-delete.txt")
                    && t.read(d + "/absolute-update.txt") == "absolute new\n", r.text)
            let rel = await t.apply(t.wrap("*** Add File: relative-add.txt\n+relative add"))
            t.check("F.51b rust:lib::test_apply_patch_hunks_accept_relative_and_absolute_paths (relative refused, D2)",
                    rel.outcome.status == .refused && rel.outcome.category == .path && rel.text.contains("is not an absolute path"), rel.text)
        }
        do {
            let d = t.dir("f52"); let path = d + "/del.txt"
            t.write(path, "x")
            await t.seed(path)
            let r = await t.apply(t.wrap("*** Delete File: \(path)"))
            t.check("F.52 rust:lib::test_delete_file_hunk_removes_file", r.text == "Success. Updated the following files:\nD \(path)" && !t.exists(path), r.text)
        }
        do {
            let d = t.dir("f53"); let path = d + "/update.txt"
            t.write(path, "foo\nbar\n")
            let r = await t.apply(t.wrap("*** Update File: \(path)\n@@\n foo\n-bar\n+baz"))
            t.check("F.53 rust:lib::test_update_file_hunk_modifies_content", r.text == "Success. Updated the following files:\nM \(path)" && t.read(path) == "foo\nbaz\n", r.text)
        }
        do {
            let d = t.dir("f54"); let src = d + "/src.txt", dest = d + "/dst.txt"
            t.write(src, "line\n")
            let r = await t.apply(t.wrap("*** Update File: \(src)\n*** Move to: \(dest)\n@@\n-line\n+line2"))
            t.check("F.54 rust:lib::test_update_file_hunk_can_move_file", r.text == "Success. Updated the following files:\nM \(dest)" && !t.exists(src) && t.read(dest) == "line2\n", r.text)
        }
        do {
            // Codex leaves the destination written; Briglia rolls it back (divergence §6.9, scenario 015 class).
            let d = t.dir("f55")
            let locked = d + "/locked", out = d + "/out"
            try? FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            t.write(locked + "/src.txt", "line\n")
            chmod(locked, 0o555)
            let r = await t.apply(t.wrap("*** Update File: \(locked)/src.txt\n*** Move to: \(out)/dst.txt\n@@\n-line\n+line2"))
            chmod(locked, 0o755)
            let rootCanWrite = getuid() == 0
            t.check("F.55 rust:lib::test_failed_move_returns_committed_destination_delta (Briglia: rolled back)",
                    rootCanWrite || (r.outcome.status == .rolledBack && t.read(locked + "/src.txt") == "line\n" && !t.exists(out + "/dst.txt")
                                     && r.outcome.restored == ["\(out)/dst.txt"]), r.text)
        }
        do {
            let d = t.dir("f56"); let path = d + "/multi.txt"
            t.write(path, "foo\nbar\nbaz\nqux\n")
            let r = await t.apply(t.wrap("*** Update File: \(path)\n@@\n foo\n-bar\n+BAR\n@@\n baz\n-qux\n+QUX"))
            t.check("F.56 rust:lib::test_multiple_update_chunks_apply_to_single_file", r.text == "Success. Updated the following files:\nM \(path)" && t.read(path) == "foo\nBAR\nbaz\nQUX\n", r.text)
        }
        do {
            let d = t.dir("f57"); let path = d + "/interleaved.txt"
            t.write(path, "a\nb\nc\nd\ne\nf\n")
            let r = await t.apply(t.wrap("*** Update File: \(path)\n@@\n a\n-b\n+B\n@@\n c\n d\n-e\n+E\n@@\n f\n+g\n*** End of File"))
            t.check("F.57 rust:lib::test_update_file_hunk_interleaved_changes", r.text == "Success. Updated the following files:\nM \(path)" && t.read(path) == "a\nB\nc\nd\nE\nf\ng\n", r.text)
        }
        do {
            let d = t.dir("f58"); let path = d + "/panic.txt"
            t.write(path, "line1\nline2\nline3\n")
            let r = await t.apply(t.wrap("*** Update File: \(path)\n@@\n+after-context\n+second-line\n@@\n line1\n-line2\n-line3\n+line2-replacement"))
            t.check("F.58 rust:lib::test_pure_addition_chunk_followed_by_removal", t.read(path) == "line1\nline2-replacement\nafter-context\nsecond-line\n", r.text)
        }
        do {
            let d = t.dir("f59"); let path = d + "/unicode.py"
            t.write(path, "import asyncio  # local import \u{2013} avoids top\u{2011}level dep\n")
            let r = await t.apply(t.wrap("*** Update File: \(path)\n@@\n-import asyncio  # local import - avoids top-level dep\n+import asyncio  # HELLO"))
            // Briglia appends a fuzz note after Codex's summary (divergence: output).
            t.check("F.59 rust:lib::test_update_line_with_unicode_dash",
                    t.read(path) == "import asyncio  # HELLO\n"
                    && r.text == "Success. Updated the following files:\nM \(path)\nnote: matched ignoring typographic punctuation in \(path)", r.text)
        }
        do {
            let d = t.dir("f60"); let locked = d + "/locked"
            try? FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            chmod(locked, 0o555)
            let r = await t.apply(t.wrap("*** Add File: \(locked)/new.txt\n+after"))
            chmod(locked, 0o755)
            t.check("F.60 rust:lib::test_apply_patch_fails_on_write_error (Briglia: failed, nothing left)",
                    getuid() == 0 || (r.outcome.status == .rolledBack && !t.exists(locked + "/new.txt")
                                      && (try? FileManager.default.contentsOfDirectory(atPath: locked))?.isEmpty == true), r.text)
        }
        do {
            // Codex's "inexact delta" has no Briglia counterpart; the behaviour
            // ported is that overwriting an undecodable existing file succeeds
            // (Add / Move onto it) — once it is fresh (D3).
            let d = t.dir("f61")
            t.write(d + "/source.txt", "before\n")
            t.write(d + "/binary.dat", Data([0xff, 0xfe, 0xfd]))
            await t.seed(d + "/binary.dat")
            let a = await t.apply(t.wrap("*** Add File: \(d)/binary.dat\n+text"))
            t.write(d + "/binary.dat", Data([0xff, 0xfe, 0xfd]))
            await t.seed(d + "/binary.dat")
            let b = await t.apply(t.wrap("*** Update File: \(d)/source.txt\n*** Move to: \(d)/binary.dat\n@@\n-before\n+after"))
            t.check("F.61 rust:lib::test_unreadable_destinations_return_inexact_delta",
                    a.outcome.status == .applied && b.outcome.status == .applied && t.read(d + "/binary.dat") == "after\n", a.text + " | " + b.text)
        }
        do {
            // Codex deletes the link; Briglia refuses Delete of a symlink (§6.4).
            let d = t.dir("f62")
            t.write(d + "/target.txt", "target\n")
            symlink(d + "/target.txt", d + "/link.txt")
            let r = await t.apply(t.wrap("*** Delete File: \(d)/link.txt"))
            t.check("F.62 rust:lib::test_delete_symlink_returns_inexact_delta (Briglia: refused)",
                    r.outcome.status == .refused && r.text.contains("is a symbolic link") && t.exists(d + "/link.txt") && t.read(d + "/target.txt") == "target\n", r.text)
        }
    }
}
