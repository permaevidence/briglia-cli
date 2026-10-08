import Foundation
#if canImport(Glibc)
import Glibc
#endif

extension FloodRow {
    /// F6: secret redaction + watches through a newline-free flood.
    static func secretsAndWatches(bytes: Int, budget: Double,
                                  check: (String, Bool, String) -> Void) async -> Int {
        var failed = 0
        func c(_ l: String, _ ok: Bool, _ d: String) { check(l, ok, d); if !ok { failed += 1 } }
        // Synthetic token shape only (never a real credential in fixtures).
        let token = "123456789:AAFloodSelftestSyntheticTokenValue_0123456"
        do {
            try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: token)
        } catch {
            c("F6 setup: seed synthetic token", false, "\(error)")
            return failed
        }
        defer { try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey) }

        // Token repeated inside the giant line (awk's 4KB stdio blocks split
        // some occurrences across pipe chunks), then a short marker line,
        // then the token again as the very last bytes.
        // 4093-byte records (not a power of two) so token positions drift
        // across stdio/pipe chunk boundaries and some occurrences straddle.
        let record = 4093
        let reps = max(1, bytes / record)
        let cmd = "sleep 0.5; LC_ALL=C awk 'BEGIN{t=\"\(token)\"; for(i=0;i<\(reps);i++){ printf \"%s\", t; for(k=0;k<\(record - token.utf8.count - 7);k++) printf \"x\"; printf \"pad%04d\", i % 10000 }; printf \"\\nFLOODMARK done\\n\"; printf \"%s\", t }'"
        let t0 = Date()
        let started = await BashTools.runBackground(command: cmd, description: "flood selftest secrets")
        let sp = (try? JSONSerialization.jsonObject(with: Data(started.content.utf8))) as? [String: Any] ?? [:]
        let handle = sp["handle"] as? String ?? ""
        let w1 = await BackgroundProcessRegistry.shared.registerWatch(handle: handle, pattern: "^FLOODMARK", limit: 5)
        let w2 = await BackgroundProcessRegistry.shared.registerWatch(handle: handle, pattern: "pad0001", limit: 5)
        var w1id = "", w2id = ""
        if case .success(let id) = w1 { w1id = id }
        if case .success(let id) = w2 { w2id = id }
        c("F6 watches registered", !w1id.isEmpty && !w2id.isEmpty, "w1=\(w1) w2=\(w2)")
        _ = await BackgroundProcessRegistry.shared.awaitSettlement(handleId: handle, timeoutNanos: 600_000_000_000)
        // Watch evaluation runs in detached Tasks — give them a moment.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let out = await BashTools.output(handle: handle)
        let wall = Date().timeIntervalSince(t0)
        let p = (try? JSONSerialization.jsonObject(with: Data(out.content.utf8))) as? [String: Any] ?? [:]
        let shown = p["stdout"] as? String ?? ""
        let expectedTotal = reps * record + "\nFLOODMARK done\n".utf8.count + token.utf8.count
        let total = p["stdout_total_bytes"] as? Int ?? -1
        c("F6 settled + output in bounded time", wall < budget, String(format: "wall=%.1fs", wall))
        // The completion notice is rendered from the rolling buffer on the
        // registry actor: the carry window must have been flushed into it.
        var notice = ""
        if let facts = await BackgroundProcessRegistry.shared.jobFacts(handleId: handle) {
            notice = await BackgroundProcessRegistry.shared.pendingCompletionBody(jobUUID: facts.jobUUID) ?? ""
        }
        c("F6 completion notice tail: complete and redacted",
          notice.contains("FLOODMARK done") && notice.contains(HarnessSecretStore.tokenPlaceholder)
          && !notice.contains(token)
          && notice.range(of: "FLOODMARK done\n" + HarnessSecretStore.tokenPlaceholder) != nil,
          "notice tail='\(notice.suffix(120))'")
        c("F6 live view: token redacted, tail intact",
          !shown.contains(token) && shown.hasSuffix(HarnessSecretStore.tokenPlaceholder)
          && shown.contains("FLOODMARK done"),
          "rawLeak=\(shown.contains(token)) tail='\(shown.suffix(60))'")
        let placeholderDelta = HarnessSecretStore.tokenPlaceholder.utf8.count - token.utf8.count
        // Total is in redacted bytes: every token became the placeholder.
        c("F6 byte accounting (redacted stream)",
          total == expectedTotal + (reps + 1) * placeholderDelta,
          "total=\(total) expected=\(expectedTotal + (reps + 1) * placeholderDelta)")
        if let spill = p["stdout_full_output_path"] as? String {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: spill))) ?? Data()
            let leak = data.range(of: Data(token.utf8)) != nil
            c("F6 spill file has no raw token", !leak && data.count == total, "leak=\(leak) size=\(data.count)")
            try? FileManager.default.removeItem(atPath: spill)
        } else {
            c("F6 spill file has no raw token", false, "no spill path")
        }
        let matches = await BackgroundProcessRegistry.shared.drainWatchMatches()
        // Exit teardown events (stream "system") are not line matches.
        let lineMatches = matches.filter { $0.stream != "system" }
        let m1 = lineMatches.filter { $0.watchId == w1id }
        let m2 = lineMatches.filter { $0.watchId == w2id }
        c("F6 marker-line watch fired once with the exact line",
          m1.count == 1 && m1.first?.line == "FLOODMARK done",
          "matches=\(m1.map { $0.line.prefix(40) })")
        let giant = m2.first?.line ?? ""
        c("F6 giant-line watch: line capped, redacted, marked",
          m2.count == 1
          && giant.hasPrefix(HarnessSecretStore.tokenPlaceholder)
          && !giant.contains(token)
          && giant.hasSuffix(BackgroundProcessRegistry.watchLineTruncationMarker)
          && giant.utf8.count <= BackgroundProcessRegistry.watchLineCapBytes
             + BackgroundProcessRegistry.watchLineTruncationMarker.utf8.count,
          "count=\(m2.count) len=\(giant.utf8.count) head='\(giant.prefix(30))'")
        return failed
    }

    /// F7: live output of a running job includes the redacted carry window.
    static func liveCarryView(check: (String, Bool, String) -> Void) async -> Int {
        var failed = 0
        func c(_ l: String, _ ok: Bool, _ d: String) { check(l, ok, d); if !ok { failed += 1 } }
        let token = "123456789:AAFloodSelftestSyntheticTokenValue_0123456"
        do {
            try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: token)
        } catch {
            c("F7 setup: seed synthetic token", false, "\(error)")
            return failed
        }
        defer { try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey) }
        let started = await BashTools.runBackground(
            command: "printf 'ready-%s|' \"$$\"; printf '%s' '\(token)'; printf ' tail'; sleep 4",
            description: "flood selftest live carry")
        let sp = (try? JSONSerialization.jsonObject(with: Data(started.content.utf8))) as? [String: Any] ?? [:]
        let handle = sp["handle"] as? String ?? ""
        var live = ""
        var status = ""
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 3 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let p = (try? JSONSerialization.jsonObject(
                with: Data(await BashTools.output(handle: handle).content.utf8))) as? [String: Any] ?? [:]
            live = p["stdout"] as? String ?? ""
            status = p["status"] as? String ?? ""
            if live.hasSuffix(" tail") { break }
        }
        c("F7 running job: newest bytes visible, secret redacted",
          status == "running" && live.hasPrefix("ready-") && live.hasSuffix("|" + HarnessSecretStore.tokenPlaceholder + " tail")
          && !live.contains(token),
          "status=\(status) live='\(live)'")
        _ = await BackgroundProcessRegistry.shared.awaitSettlement(handleId: handle, timeoutNanos: 30_000_000_000)
        return failed
    }

    /// Unit rows: line splitter and bounded-text helpers.
    static func units(check: (String, Bool, String) -> Void) -> Int {
        var failed = 0
        func c(_ l: String, _ ok: Bool, _ d: String = "") { check(l, ok, d); if !ok { failed += 1 } }

        func plain() -> WatchLineAccumulator {
            WatchLineAccumulator(capBytes: BackgroundProcessRegistry.watchLineCapBytes, redactionEnvironment: [:])
        }
        var a1 = plain()
        var lines = a1.feed("ab")
        lines += a1.feed("c\nde\n\nf")
        c("U1 lines split across chunks", lines == ["abc", "de", ""] && a1.pendingBytes == 1, "\(lines)")

        var a2 = plain()
        let cl = a2.feed("one\r\ntwo\r") + a2.feed("\nthr")
        c("U2 CRLF lines split and stripped (also across chunks)", cl == ["one", "two"] && a2.pendingBytes == 3, "\(cl)")

        var a3 = WatchLineAccumulator(capBytes: 10_001, redactionEnvironment: [:])
        for _ in 0..<100 { _ = a3.feed(String(repeating: "é", count: 1000)) }
        let done = a3.feed("TAIL\nnext")
        let marker = WatchLineAccumulator.truncationMarker
        c("U3 multibyte line capped on a scalar boundary, marked",
          done.count == 1 && done[0].hasSuffix(marker)
          && done[0].utf8.count == 10_000 + marker.utf8.count
          && !done[0].contains("\u{FFFD}") && !done[0].contains("TAIL") && a3.pendingBytes == 4,
          "bytes=\(done.first?.utf8.count ?? -1)")

        // Time bound: 32MB in 4KB chunks without a newline must be linear.
        var a4 = plain()
        let chunk = String(repeating: "z", count: 4096)
        let t0 = Date()
        for _ in 0..<8192 { _ = a4.feed(chunk) }
        let dt = Date().timeIntervalSince(t0)
        c("U4 32MB newline-free line in bounded time and memory",
          dt < 5 && a4.pendingBytes == BackgroundProcessRegistry.watchLineCapBytes,
          String(format: "%.2fs pending=%d", dt, a4.pendingBytes))

        failed += codexR1Rows(check: check)
        c("U5 BoundedText.suffix keeps scalars whole",
          BoundedText.suffix("aé€🐕", maxBytes: 5) == "🐕" && BoundedText.suffix("aé€🐕", maxBytes: 7) == "€🐕"
          && BoundedText.suffix("abc", maxBytes: 9) == "abc")
        c("U6 BoundedText.prefix keeps scalars whole",
          BoundedText.prefix("aé€🐕", maxBytes: 2) == "a" && BoundedText.prefix("aé€🐕", maxBytes: 6) == "aé€"
          && BoundedText.prefix("abc", maxBytes: 0) == "")

        let secret = "SECRET_ABCDEFGH_1234567"
        let r = StreamingRedactor(environment: ["K": secret])
        let emitted = r.process("head " + secret + " mid " + String(secret.prefix(6)))
        let pending = r.pendingRedacted()
        let view = emitted + pending
        let rest = r.process(String(secret.dropFirst(6)) + " end") + r.flush()
        c("U7 live view = emitted + redacted carry; carry survives peeking",
          view == "head [REDACTED:K] mid " + String(secret.prefix(6))
          && emitted + rest == "head [REDACTED:K] mid [REDACTED:K] end",
          "view='\(view)' final='\(emitted + rest)'")
        return failed
    }

    /// Codex R1 (review of 97aa924): dense secrets before a token crossing
    /// the old raw cutoff. Redaction must happen BEFORE any cut, so no token
    /// fragment can reach a watch, and every cut must be disclosed.
    static func codexR1Rows(check: (String, Bool, String) -> Void) -> Int {
        var failed = 0
        func c(_ l: String, _ ok: Bool, _ d: String = "") { check(l, ok, d); if !ok { failed += 1 } }
        let token = "123456789:AAFloodSelftestSyntheticTokenValue_0123456"
        let env = ["telegram_bot_token": token]
        let full = BashTools.SecretRedactor(environment: env)
        let cap = BackgroundProcessRegistry.watchLineCapBytes
        let marker = WatchLineAccumulator.truncationMarker
        let fragment = String(token.prefix(20))

        // Codex's exact shape: 69,632 raw bytes of dense tokens + padding,
        // then a token crossing the old raw cutoff, then " ACTUAL_END".
        let rawCap = cap + 4096
        let repeats = rawCap / token.utf8.count
        let padding = rawCap - repeats * token.utf8.count - 30
        let body = String(repeating: token, count: repeats - 1)
            + String(repeating: "x", count: padding + token.utf8.count) + token + " ACTUAL_END"
        let expected = full.redact(body)
        for (label, size) in [("one piece", Int.max), ("4 KiB chunks", 4096), ("7-byte chunks", 7)] {
            var acc = WatchLineAccumulator(capBytes: cap, redactionEnvironment: env)
            var got: [String] = []
            let bytes = Array((body + "\n").utf8)
            var off = 0
            while off < bytes.count {
                let end = size == Int.max ? bytes.count : min(off + size, bytes.count)
                got += acc.feed(String(decoding: bytes[off..<end], as: UTF8.self))
                off = end
            }
            c("U8 Codex R1 (\(label)): watch line == whole-line redaction, no fragment, nothing cut",
              got.count == 1 && got[0] == expected && !got[0].contains(fragment) && !got[0].hasSuffix(marker),
              "len=\(got.first?.utf8.count ?? -1) expected=\(expected.utf8.count) fragment=\(got.first?.contains(fragment) ?? false)")
        }

        // A REAL cut: redacted line longer than the cap with a token crossing
        // the cut point — marker present, no fragment, placeholder whole.
        for shift in [0, 5, 17, 28, 40, 51] {
            let lead = String(repeating: "y", count: cap - 10 - shift)
            let line = lead + token + String(repeating: "z", count: 5000)
            var acc = WatchLineAccumulator(capBytes: cap, redactionEnvironment: env)
            var got: [String] = []
            for piece in stride(from: 0, to: line.utf8.count, by: 4093) {
                let b = Array(line.utf8)
                got += acc.feed(String(decoding: b[piece..<min(piece + 4093, b.count)], as: UTF8.self))
            }
            got += acc.feed("\n")
            let w = got.first ?? ""
            let kept = w.hasSuffix(marker) ? String(w.dropLast(marker.count)) : w
            let opened = kept.components(separatedBy: "[REDACTED:").count - 1
            let closed = kept.components(separatedBy: "telegram_bot_token]").count - 1
            c("U9 cut through a token region (shift \(shift)): marked, no fragment, placeholder never split",
              got.count == 1 && w.hasSuffix(marker) && !w.contains(fragment) && !w.contains("123456789:")
              && opened == closed && kept.utf8.count <= cap,
              "len=\(w.utf8.count) opened=\(opened) closed=\(closed)")
        }

        // Replay path (input already redacted): cut is still marked.
        var replay = WatchLineAccumulator(capBytes: 100, redactionEnvironment: nil)
        let r = replay.feed(String(repeating: "q", count: 300) + "\nok\n")
        c("U10 replay accumulator marks a cut and keeps later lines",
          r.count == 2 && r[0] == String(repeating: "q", count: 100) + marker && r[1] == "ok", "\(r.map { $0.count })")

        // EOF: an unterminated tail is never delivered, and holds no raw token.
        var eof = WatchLineAccumulator(capBytes: cap, redactionEnvironment: env)
        let none = eof.feed("partial " + token)
        c("U11 unterminated tail not delivered; pending stays bounded",
          none.isEmpty && eof.pendingBytes <= "partial ".utf8.count + token.utf8.count, "pending=\(eof.pendingBytes)")
        return failed
    }
}
