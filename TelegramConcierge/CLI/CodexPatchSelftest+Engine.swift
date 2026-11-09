import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// §14.2 engine unit tests: text model, matching, paths and symlinks, limits.
extension CodexPatchSelftest {

    static func engineText(_ t: CPTest) async {
        do {
            let d = t.dir("e1"); let p = d + "/crlf.txt"
            t.write(p, "one\r\ntwo\r\nthree\r\n")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-one\n+ONE\n two\n+between\n three"))
            t.check("E.T1 CRLF file: unchanged lines keep CRLF, new lines get CRLF", t.read(p) == "ONE\r\ntwo\r\nbetween\r\nthree\r\n", r.text + " got \(t.read(p)?.debugDescription ?? "nil")")
        }
        do {
            let d = t.dir("e2"); let p = d + "/cr.txt"
            t.write(p, "a\rb\rc")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n a\n-b\n+B"))
            t.check("E.T2 CR-only file: CR kept, the unterminated last line gains CR", t.read(p) == "a\rB\rc\r", r.text + " got \(t.read(p)?.debugDescription ?? "nil")")
        }
        do {
            let d = t.dir("e3"); let p = d + "/mixed.txt"
            t.write(p, "one\ntwo\r\nthree\nfour\r\n")
            _ = await t.apply(t.wrap("*** Update File: \(p)\n@@\n one\n two\n-three\n+THREE\n+added\n four"))
            t.check("E.T3 mixed endings: unchanged keep theirs, new lines use the first seen (LF)", t.read(p) == "one\ntwo\r\nTHREE\nadded\nfour\r\n", t.read(p)?.debugDescription ?? "nil")
        }
        do {
            let d = t.dir("e4"); let p = d + "/bom.txt"
            t.write(p, Data([0xEF, 0xBB, 0xBF] + Array("first\nsecond\n".utf8)))
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-first\n+FIRST\n second"))
            t.check("E.T4 BOM: stripped for matching line 1, restored on write (divergence)",
                    r.outcome.status == .applied && t.bytes(p) == Data([0xEF, 0xBB, 0xBF] + Array("FIRST\nsecond\n".utf8)), r.text)
        }
        do {
            let d = t.dir("e5"); let p = d + "/nonl.txt"
            t.write(p, "a\nb")
            _ = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-a\n+A"))
            t.check("E.T5 no final newline: the untouched last line gains the ending (scenario 014 rule)", t.read(p) == "A\nb\n", t.read(p)?.debugDescription ?? "nil")
        }
        do {
            let d = t.dir("e6"); let p = d + "/empty.txt"
            t.write(p, "")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n+hello"))
            t.check("E.T6 empty file: a pure insertion appends", r.outcome.status == .applied && t.read(p) == "hello\n", r.text)
        }
        do {
            let d = t.dir("e7"); let p = d + "/bad.txt"
            t.write(p, Data([0x61, 0x0A, 0xC3, 0x28, 0x0A]))
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-a\n+b"))
            t.check("E.T7 invalid UTF-8 is refused, file untouched", r.outcome.status == .refused && r.text.contains("not valid UTF-8") && t.bytes(p) == Data([0x61, 0x0A, 0xC3, 0x28, 0x0A]), r.text)
            let q = d + "/nul.bin"
            t.write(q, Data([0x61, 0x00, 0x0A]))
            let r2 = await t.apply(t.wrap("*** Update File: \(q)\n@@\n-a\n+b"))
            t.check("E.T8 a NUL in the first 8 KiB is refused as binary", r2.outcome.status == .refused && r2.text.contains("binary"), r2.text)
        }
        do {
            let d = t.dir("e9"); let p = d + "/new.txt"
            _ = await t.apply(t.wrap("*** Add File: \(p)\n+line one\n+line two"))
            t.check("E.T9 Add writes every line followed by LF (final newline kept)", t.read(p) == "line one\nline two\n", t.read(p)?.debugDescription ?? "nil")
            let e = d + "/empty-add.txt"
            let r = await t.apply(t.wrap("*** Add File: \(e)"))
            t.check("E.T10 an empty Add creates an empty file", r.outcome.status == .applied && t.read(e) == "", r.text)
            let b = d + "/literal-bom.txt"
            _ = await t.apply(t.wrap("*** Add File: \(b)\n+\u{FEFF}x"))
            t.check("E.T11 a literal U+FEFF in added content is kept as content", t.bytes(b) == Data([0xEF, 0xBB, 0xBF, 0x78, 0x0A]))
        }
        do {
            // Scalar comparison: precomposed é in the file, decomposed in the patch.
            let d = t.dir("e12"); let p = d + "/nfc.txt"
            t.write(p, "caf\u{E9}\n")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-cafe\u{301}\n+x"))
            t.check("E.T12 canonical equivalence never broadens Rust's exact comparison", r.outcome.status == .refused && r.outcome.category == .context && t.read(p) == "caf\u{E9}\n", r.text)
            let q = d + "/emspace.txt"
            t.write(q, "\u{2003}\u{2003}indented\n")
            let r2 = await t.apply(t.wrap("*** Update File: \(q)\n@@\n-indented\n+done"))
            t.check("E.T13 trim uses Unicode White_Space (em space)", r2.outcome.status == .applied && t.read(q) == "done\n", r2.text)
        }
    }

    static func engineMatching(_ t: CPTest) async {
        t.check("E.M1 EOF search starts at len - pattern.len with no fallback to start",
                CodexPatch.seekSequence(["x", "y", "a"], ["x"], start: 0, eof: true) == nil
                && CodexPatch.seekSequence(["a", "b", "a", "b"], ["a", "b"], start: 0, eof: true) == 2)
        do {
            let d = t.dir("m2"); let p = d + "/cursor.txt"
            t.write(p, "a\nX\na\nX\n")
            _ = await t.apply(t.wrap("*** Update File: \(p)\n@@\n a\n-X\n+Y\n@@\n a\n-X\n+Z"))
            t.check("E.M2 the cursor moves forward between chunks", t.read(p) == "a\nY\na\nZ\n", t.read(p) ?? "nil")
        }
        do {
            let d = t.dir("m3"); let p = d + "/pass.txt"
            t.write(p, "  foo\nfoo  \n")
            _ = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-foo\n+bar"))
            t.check("E.M3 the trim_end pass runs before the trim pass", t.read(p) == "  foo\nbar\n", t.read(p) ?? "nil")
        }
        do {
            let d = t.dir("m4"); let p = d + "/ctx.txt"
            t.write(p, "class A:\n    x = 1\nclass B:\n    x = 1\n")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@ class B:\n-    x = 1\n+    x = 2"))
            t.check("E.M4 @@ context narrows the location", t.read(p) == "class A:\n    x = 1\nclass B:\n    x = 2\n", r.text)
            let r2 = await t.apply(t.wrap("*** Update File: \(p)\n@@ class C:\n-    x = 1\n+    x = 3"))
            t.check("E.M5 a missing @@ context fails with Codex's text (then the nearest lines)",
                    r2.text.hasPrefix("apply_patch verification failed: Failed to find context 'class C:' in \(p)\nNearest lines in the file:"), r2.text)
        }
        do {
            let d = t.dir("m6"); let p = d + "/miss.txt"
            t.write(p, "alpha beta gamma\nunrelated\n")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n-alpha beta gamna\n+x"))
            t.check("E.M6 a context miss: Codex's message plus the nearest lines",
                    r.text.hasPrefix("apply_patch verification failed: Failed to find expected lines in \(p):\nalpha beta gamna")
                    && r.text.contains("Nearest lines in the file:\n1: alpha beta gamma") && r.outcome.category == .context, r.text)
        }
        do {
            let d = t.dir("m7"); let p = d + "/trail.txt"
            t.write(p, "a\nb\n")
            let r = await t.apply(t.wrap("*** Update File: \(p)\n@@\n a\n-b\n+B\n "))
            t.check("E.M7 a trailing empty context line is retried without it", r.outcome.status == .applied && t.read(p) == "a\nB\n", r.text)
        }
        let overlap = CodexPatch.overlapError([.init(start: 0, oldLength: 3, newLines: []), .init(start: 1, oldLength: 1, newLines: [])], path: "/x")
        t.check("E.M8 overlapping replacements are refused (divergence)", overlap?.message == "overlapping hunks in /x")
    }

    static func enginePaths(_ t: CPTest) async {
        do {
            let r = await t.apply(t.wrap("*** Add File: src/x.py\n+x"), workdir: "/Users/me/repo")
            t.check("E.P1 a relative path is refused with the last-workdir hint",
                    r.outcome.status == .refused && r.outcome.category == .path && r.text.contains("did you mean /Users/me/repo/src/x.py?"), r.text)
        }
        do {
            let expanded = CodexPatch.normalizePath("~/cp-tilde.txt")
            let home = NSHomeDirectory()
            t.check("E.P2 ~ is expanded to the home directory", expanded == home + "/cp-tilde.txt", expanded)
            if expanded.hasPrefix(t.base.deletingLastPathComponent().path) || expanded.hasPrefix(ProcessInfo.processInfo.environment["HOME"] ?? "/nonexistent") {
                let r = await t.apply(t.wrap("*** Add File: ~/cp-tilde.txt\n+t"))
                t.check("E.P3 a ~ path is applied at its expansion", r.outcome.status == .applied && t.read(expanded) == "t\n", r.text)
                unlink(expanded)
            }
        }
        do {
            let d = t.dir("p4")
            t.write(d + "/a.txt", "a\n")
            let r = await t.apply(t.wrap("*** Update File: \(d)/a.txt\n@@\n-a\n+b\n*** Update File: \(d)/sub/../a.txt\n@@\n-a\n+c"))
            t.check("E.P4 the same file named twice (through ..) is one target", r.outcome.status == .refused && r.text.contains("multiple operations target") && t.read(d + "/a.txt") == "a\n", r.text)
            try? FileManager.default.createDirectory(atPath: d + "/real", withIntermediateDirectories: true)
            symlink(d + "/real", d + "/alias")
            t.write(d + "/real/f.txt", "f\n")
            let r2 = await t.apply(t.wrap("*** Update File: \(d)/real/f.txt\n@@\n-f\n+g\n*** Delete File: \(d)/alias/f.txt"))
            t.check("E.P5 aliases through a symlinked directory are one target", r2.outcome.status == .refused && r2.text.contains("multiple operations target"), r2.text)
            let r3 = await t.apply(t.wrap("*** Add File: \(d)/n.txt\n+1\n*** Update File: \(d)/a.txt\n*** Move to: \(d)/n.txt\n@@\n-a\n+b"))
            t.check("E.P6 a move destination colliding with an Add is refused", r3.outcome.status == .refused && r3.text.contains("multiple operations target") && !t.exists(d + "/n.txt"), r3.text)
            let r4 = await t.apply(t.wrap("*** Update File: \(d)/a.txt\n*** Move to: \(d)/a.txt\n@@\n-a\n+b"))
            t.check("E.P7 a move onto itself is refused (Codex would delete the file)", r4.outcome.status == .refused && t.read(d + "/a.txt") == "a\n", r4.text)
        }
        do {
            let d = t.dir("p8")
            t.write(d + "/target.txt", "one\n")
            symlink(d + "/target.txt", d + "/link.txt")
            let r = await t.apply(t.wrap("*** Update File: \(d)/link.txt\n@@\n-one\n+two"))
            let linkStill = (try? FileIdentity.lstatPath(d + "/link.txt"))??.kind == .symlink
            t.check("E.P8 Update through a symlink writes the target and keeps the link", r.outcome.status == .applied && t.read(d + "/target.txt") == "two\n" && linkStill, r.text)
            await t.seed(d + "/link.txt")
            let r2 = await t.apply(t.wrap("*** Add File: \(d)/link.txt\n+x"))
            t.check("E.P9 Add onto a symlink is refused", r2.outcome.status == .refused && r2.text.contains("is a symbolic link"), r2.text)
            t.write(d + "/src.txt", "s\n")
            let r3 = await t.apply(t.wrap("*** Update File: \(d)/src.txt\n*** Move to: \(d)/link.txt\n@@\n-s\n+t"))
            t.check("E.P10 Move onto a symlink is refused", r3.outcome.status == .refused && r3.text.contains("is a symbolic link") && t.read(d + "/src.txt") == "s\n", r3.text)
            symlink(d + "/nowhere.txt", d + "/dangling.txt")
            let r4 = await t.apply(t.wrap("*** Update File: \(d)/dangling.txt\n@@\n+x"))
            t.check("E.P11 Update of a dangling link is refused", r4.outcome.status == .refused && r4.text.contains("is a symbolic link") && !t.exists(d + "/nowhere.txt"), r4.text)
            try? FileManager.default.createDirectory(atPath: d + "/dir", withIntermediateDirectories: true)
            let r5 = await t.apply(t.wrap("*** Delete File: \(d)/dir"))
            let r6 = await t.apply(t.wrap("*** Add File: \(d)/dir\n+x"))
            let r7 = await t.apply(t.wrap("*** Update File: \(d)/dir\n@@\n+x"))
            t.check("E.P12 directories as targets are refused (scenario 012)",
                    [r5, r6, r7].allSatisfy { $0.outcome.status == .refused } && r5.text.contains("Is a directory") && r7.text.contains("Is a directory"),
                    [r5, r6, r7].map(\.text).joined(separator: " | "))
        }
        do {
            let d = t.dir("p13")
            t.write(d + "/m.txt", "m\n")
            let r = await t.apply(t.wrap("*** Update File: \(d)/m.txt\n*** Move to: \(d)/deep/er/m.txt\n@@\n-m\n+n"))
            t.check("E.P13 a move creates missing destination directories", r.outcome.status == .applied && t.read(d + "/deep/er/m.txt") == "n\n" && !t.exists(d + "/m.txt"), r.text)
            let r2 = await t.apply(t.wrap("*** Update File: \(d)/missing.txt\n@@\n-a\n+b"))
            t.check("E.P14 Update of a missing file: Codex's read error text",
                    r2.text == "apply_patch verification failed: Failed to read file to update \(d)/missing.txt: \(CodexPatchFS.rustOSError(ENOENT))", r2.text)
            let r3 = await t.apply(t.wrap("*** Delete File: \(d)/missing.txt"))
            t.check("E.P15 Delete of a missing file is refused", r3.outcome.status == .refused && r3.text.contains("Failed to read \(d)/missing.txt"), r3.text)
        }
        do {
            let r = await t.apply(t.wrap("*** Environment ID: remote\n*** Add File: /tmp/never-\(UUID().uuidString).txt\n+x"))
            t.check("E.P16 *** Environment ID parses as Codex, then is refused", r.outcome.status == .refused && r.text.contains("Environment ID is not supported"), r.text)
            let r2 = await t.apply("*** Begin Patch\n*** End Patch")
            t.check("E.P17 zero hunks: 'No files were modified.' (scenario 005)", r2.text == "apply_patch verification failed: No files were modified.", r2.text)
        }
    }

    static func engineLimits(_ t: CPTest) async {
        do {
            let big = String(repeating: "x", count: (1 << 20) + 1)
            let r = await t.apply(big)
            t.check("E.L1 input over 1 MiB is refused before parsing", r.outcome.status == .refused && r.text.contains("1 MiB"), String(r.text.prefix(200)))
        }
        do {
            let d = t.dir("l2")
            let body = (0..<101).map { "*** Add File: \(d)/f\($0).txt\n+x" }.joined(separator: "\n")
            let r = await t.apply(t.wrap(body))
            t.check("E.L2 more than 100 operations are refused", r.outcome.status == .refused && r.text.contains("limit is 100") && (try? FileManager.default.contentsOfDirectory(atPath: d))?.isEmpty == true, r.text)
        }
        do {
            let d = t.dir("l3")
            var limits = CodexPatch.Limits.standard
            limits.maxImageBytes = 64
            limits.maxTotalBytes = 100
            t.write(d + "/a.txt", String(repeating: "a", count: 50) + "\n")
            let r = await CodexPatch.apply(.init(input: t.wrap("*** Update File: \(d)/a.txt\n@@\n+" + String(repeating: "b", count: 40)), limits: limits))
            t.check("E.L3 a post-image above the per-file bound is refused", r.outcome.status == .refused && r.text.contains("MiB"), r.text)
            t.write(d + "/b.txt", String(repeating: "b", count: 40) + "\n")
            t.write(d + "/c.txt", String(repeating: "c", count: 40) + "\n")
            let r2 = await CodexPatch.apply(.init(input: t.wrap("*** Update File: \(d)/b.txt\n@@\n+1\n*** Update File: \(d)/c.txt\n@@\n+2"), limits: limits))
            t.check("E.L4 the aggregate bound counts pre- and post-images", r2.outcome.status == .refused && r2.text.contains("in total") && t.read(d + "/b.txt")?.hasSuffix("b\n") == true, r2.text)
            let r3 = await CodexPatch.apply(.init(input: t.wrap("*** Add File: \(d)/big.txt\n+" + String(repeating: "z", count: 80)), limits: limits))
            t.check("E.L5 an Add above the per-file bound is refused", r3.outcome.status == .refused && !t.exists(d + "/big.txt"), r3.text)
        }
        do {
            let d = t.dir("l6")
            t.write(d + "/a.txt", "a\n")
            let r = await CodexPatch.apply(.init(input: t.wrap("*** Update File: \(d)/a.txt\n@@\n-a\n+b"), isCancelled: { true }))
            t.check("E.L6 cancellation at the end of preflight: nothing changed, outcome cancelled",
                    r.outcome.status == .refused && r.outcome.category == .cancelled && t.read(d + "/a.txt") == "a\n", r.text)
        }
    }

    static func extractionTests(_ t: CPTest) async {
        // EditProtections is a behaviour-preserving extraction: the legacy
        // hunk refusal and the engine-neutral form agree.
        typealias LH = ApplyPatch.Hunk
        let placeholder = HarnessSecretStore.placeholderPrefix + "x]"
        let a = HarnessSecretStore.patchRefusal(hunks: [LH(context: [], anchor: nil, diff: [(.context, "c"), (.added, "\"k\": \"\(placeholder)\"")])])
        let b = HarnessSecretStore.patchRefusal(changedLines: [(added: true, text: "\"k\": \"\(placeholder)\"")])
        t.check("X.1 legacy hunk refusal = engine-neutral refusal (placeholder)", a != nil && a == b, "\(a ?? "nil") vs \(b ?? "nil")")
        let field = "\"\(KeychainHelper.telegramBotTokenKey)\": \"1\""
        let c = HarnessSecretStore.patchRefusal(hunks: [LH(context: [], anchor: nil, diff: [(.removed, field)])])
        let e = EditProtections.secretStoreChunkRefusal([CodexPatch.Chunk(oldLines: [field], newLines: [])])
        t.check("X.2 token-field refusal is the same through both engines", c != nil && c == e, "\(c ?? "nil") vs \(e ?? "nil")")
        let ctxOnly = EditProtections.secretStoreChunkRefusal([CodexPatch.Chunk(oldLines: [field, "x"], newLines: [field, "y"], contextLineIndices: [.init(old: 0, new: 0)])])
        t.check("X.3 a context line touching the token field is not a change", ctxOnly == nil, ctxOnly ?? "")
        t.check("X.4 SIWC refusal text unchanged", EditProtections.siwcRefusal(["/definitely/not/protected"]) == nil)
    }
}
