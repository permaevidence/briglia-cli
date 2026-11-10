import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Pre-release review fixes in the engine (2026-11-09): fixed-length temp
/// names, long file names, the mode of a moved file, same-file moves,
/// UTF-16/UTF-32 and non-UTF-8 messages, cancellation inside long searches.
extension CodexPatchSelftest {

    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    static func reviewEngineTests(_ t: CPTest) async {
        await reviewTempNameTests(t)
        await reviewMoveTests(t)
        await reviewDecodeTests(t)
        await reviewCancellationTests(t)
    }

    static func leftoverTemps(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter(CodexPatchTransaction.isTempName)
    }

    // MARK: Temp names and long file names (engine S1)

    static func reviewTempNameTests(_ t: CPTest) async {
        let names = (0..<1000).map { _ in CodexPatchTransaction.tempName() }
        t.check("V.1 temp names have a fixed length of 24 bytes and are recognised",
                names.allSatisfy { $0.utf8.count == 24 && CodexPatchTransaction.isTempName($0) }, names.first ?? "")
        t.check("V.1b 1,000 temp names are distinct", Set(names).count == names.count)
        t.check("V.1c ordinary names are not temp names",
                !CodexPatchTransaction.isTempName(".f.txt.tmp-\(UUID().uuidString)") && !CodexPatchTransaction.isTempName("notes.tmp")
                && !CodexPatchTransaction.isTempName(".bp-ABCDEF0123456789.tmp") && !CodexPatchTransaction.isTempName(".bp-0123.tmp"))
        // A name the old temp scheme could not stage (> 213 bytes).
        let d = t.dir("v2")
        let long = String(repeating: "n", count: 230) + ".txt"
        let r = await t.apply(t.wrap("*** Add File: \(d)/\(long)\n+one"))
        t.check("V.2 a 234-byte file name can be added (review: the old temp name overflowed NAME_MAX)",
                long.utf8.count == 234 && r.outcome.status == .applied && t.read(d + "/" + long) == "one\n", r.text)
        let r2 = await t.apply(t.wrap("*** Update File: \(d)/\(long)\n@@\n-one\n+two"))
        t.check("V.2b …and patched", r2.outcome.status == .applied && t.read(d + "/" + long) == "two\n" && leftoverTemps(d).isEmpty, r2.text)
        let max = String(repeating: "m", count: 251) + ".txt"
        let r3 = await t.apply(t.wrap("*** Add File: \(d)/\(max)\n+x"))
        t.check("V.2c a 255-byte name (NAME_MAX) works too", max.utf8.count == 255 && r3.outcome.status == .applied && t.read(d + "/" + max) == "x\n", r3.text)
        // A failed write leaves no new-style temp behind.
        let e = t.dir("v2d")
        t.write(e + "/a.txt", "a\n")
        CodexPatchTransaction.faultInjector = { p, path in p == .rename && path.hasSuffix("/a.txt") }
        let r4 = await t.apply(t.wrap("*** Update File: \(e)/a.txt\n@@\n-a\n+b"))
        CodexPatchTransaction.faultInjector = nil
        t.check("V.2d a failed replace cleans its fixed-length temp", r4.outcome.status != .applied && t.read(e + "/a.txt") == "a\n" && leftoverTemps(e).isEmpty, r4.text)
    }

    // MARK: Moves (engine L1, L2)

    static func reviewMoveTests(_ t: CPTest) async {
        let d = t.dir("v4")
        t.write(d + "/run.sh", "#!/bin/sh\necho old\n"); chmod(d + "/run.sh", 0o755)
        let r = await t.apply(t.wrap("*** Update File: \(d)/run.sh\n*** Move to: \(d)/bin/run2.sh\n@@\n-echo old\n+echo new"))
        t.check("V.4 a moved script keeps its mode (0755), as mv would (review L2)",
                r.outcome.status == .applied && t.mode(d + "/bin/run2.sh") == 0o755 && !t.exists(d + "/run.sh"),
                "mode \(String(t.mode(d + "/bin/run2.sh") ?? 0, radix: 8)) \(r.text)")
        let inside = StoragePaths.dataRoot.appendingPathComponent("documents/cp-mv-\(UUID().uuidString.prefix(6))").path
        t.write(d + "/tool.sh", "#!/bin/sh\n"); chmod(d + "/tool.sh", 0o755)
        let r2 = await t.apply(t.wrap("*** Update File: \(d)/tool.sh\n*** Move to: \(inside)/tool.sh\n@@\n+echo hi"))
        t.check("V.4b into Briglia's roots the private-storage policy still applies (0755 → 0700)",
                r2.outcome.status == .applied && t.mode(inside + "/tool.sh") == 0o700, "mode \(String(t.mode(inside + "/tool.sh") ?? 0, radix: 8)) \(r2.text)")
        // Same-file move: a hard link (portable) and, on a case-insensitive
        // volume, a rename that only changes letter case.
        let s = t.dir("v5")
        t.write(s + "/a.txt", "x\n")
        link(s + "/a.txt", s + "/b.txt")
        let r3 = await t.apply(t.wrap("*** Update File: \(s)/a.txt\n*** Move to: \(s)/b.txt\n@@\n-x\n+y"))
        t.check("V.5 a move onto the same file (a hard link of it) is refused plainly, nothing changed (review L1)",
                r3.outcome.status == .refused && r3.outcome.category == .path && r3.text.contains("are the same file")
                && r3.text.contains("Rename it with `mv`") && t.read(s + "/a.txt") == "x\n" && t.read(s + "/b.txt") == "x\n", r3.text)
        t.write(s + "/Foo.txt", "f\n")
        let caseInsensitive = t.exists(s + "/foo.txt")
        if caseInsensitive {
            let r4 = await t.apply(t.wrap("*** Update File: \(s)/Foo.txt\n*** Move to: \(s)/foo.txt\n@@\n-f\n+g"))
            t.check("V.5b a case-only rename on a case-insensitive volume is refused with the mv hint, file untouched",
                    r4.outcome.status == .refused && r4.text.contains("are the same file") && t.read(s + "/Foo.txt") == "f\n", r4.text)
        } else {
            t.check("V.5b (case-sensitive volume: a case-only rename is an ordinary move)", true)
        }
    }

    // MARK: Encodings (engine L8)

    static func reviewDecodeTests(_ t: CPTest) async {
        let d = t.dir("v6")
        func utf16(_ s: String, bigEndian: Bool, bom: Bool) -> Data {
            var out = Data()
            if bom { out.append(contentsOf: bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) }
            for unit in s.utf16 {
                let hi = UInt8(unit >> 8), lo = UInt8(unit & 0xFF)
                out.append(contentsOf: bigEndian ? [hi, lo] : [lo, hi])
            }
            return out
        }
        let cases: [(String, Data, String)] = [
            ("le-bom.txt", utf16("alpha\nbeta\n", bigEndian: false, bom: true), "UTF-16LE"),
            ("be-bom.txt", utf16("alpha\nbeta\n", bigEndian: true, bom: true), "UTF-16BE"),
            ("le-nobom.txt", utf16("alpha\nbeta\ngamma\n", bigEndian: false, bom: false), "UTF-16LE"),
            ("cjk-bom.txt", utf16("日本語\n", bigEndian: false, bom: true), "UTF-16LE"),
            ("u32.txt", Data([0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00]), "UTF-32LE"),
        ]
        for (name, data, encoding) in cases {
            t.write(d + "/" + name, data)
            let r = await t.apply(t.wrap("*** Update File: \(d)/\(name)\n@@\n-alpha\n+ALPHA"))
            t.check("V.6 \(name) is refused as \(encoding) text with the script hint, not as binary (review L8)",
                    r.outcome.status == .refused && r.text.contains("\(encoding) text, not UTF-8") && r.text.contains("with a script in bash")
                    && !r.text.contains("binary") && t.bytes(d + "/" + name) == data, r.text)
        }
        t.write(d + "/latin1.txt", Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
        let r = await t.apply(t.wrap("*** Update File: \(d)/latin1.txt\n@@\n-x\n+y"))
        t.check("V.6b invalid UTF-8 (Latin-1) says so and suggests a script", r.text.contains("not valid UTF-8") && r.text.contains("with a script in bash"), r.text)
        t.write(d + "/real.bin", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]))
        let r2 = await t.apply(t.wrap("*** Update File: \(d)/real.bin\n@@\n-x\n+y"))
        t.check("V.6c a real binary (PNG header) is still refused as binary", r2.text.contains("binary file"), r2.text)
    }

    // MARK: Cancellation inside long searches (engine L3)

    static func reviewCancellationTests(_ t: CPTest) async {
        let d = t.dir("v7")
        let lines = Array(repeating: "x", count: 50_000) + ["tail"]
        t.write(d + "/big.txt", lines.joined(separator: "\n") + "\n")
        // The probe answers "not cancelled" three times, then "cancelled": a
        // search that never polls asks once (at the end of preflight), sees
        // "not cancelled" and reports a context miss instead. The missed
        // lines are shorter than 3 characters, so the nearest-lines hint
        // (which polls too) never runs: only the search can poll.
        let probe = CallCounter()
        var request = CodexPatch.Request(input: t.wrap("*** Update File: \(d)/big.txt\n@@\n x\n x\n-zz\n+found"))
        request.isCancelled = { probe.hit() > 3 }
        let r = await CodexPatch.apply(request)
        t.check("V.7 a stop during a long search is seen inside the search and reported as a cancellation (review L3)",
                r.outcome.category == .cancelled && probe.count >= 4 && r.text == CodexPatch.cancelledText, "calls \(probe.count): \(r.text.prefix(200))")
        t.check("V.7b …and nothing changed", t.read(d + "/big.txt")?.hasSuffix("tail\n") == true)
        // Uncancelled, the same search still answers with the Codex miss.
        let r2 = await t.apply(t.wrap("*** Update File: \(d)/big.txt\n@@\n x\n x\n-zz\n+found"))
        t.check("V.7c without a stop the search ends with the usual context miss", r2.outcome.category == .context, r2.text.prefix(200).description)
        // The relaxed passes compare each line's transform once (same matches).
        let file = CodexPatch.SeekLines(["  a  ", "b\t", "\u{2013}c"])
        t.check("V.8 relaxed passes on precomputed transforms keep Codex's results",
                CodexPatch.seekWithLevel(file, ["a"], start: 0, eof: false)?.level == .trim
                && CodexPatch.seekWithLevel(file, ["b"], start: 0, eof: false)?.level == .trimEnd
                && CodexPatch.seekWithLevel(file, ["-c"], start: 0, eof: false)?.level == .punctuation
                && CodexPatch.seekWithLevel(file, ["  a  "], start: 0, eof: false)?.level == .exact)
    }
}
