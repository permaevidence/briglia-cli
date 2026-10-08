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

        var buf = ""
        var lines = BackgroundProcessRegistry.extractCompleteLines(newChunk: "ab", buffer: &buf)
        lines += BackgroundProcessRegistry.extractCompleteLines(newChunk: "c\nde\n\nf", buffer: &buf)
        c("U1 lines split across chunks", lines == ["abc", "de", ""] && buf == "f", "\(lines) buf=\(buf)")

        var crlf = ""
        let cl = BackgroundProcessRegistry.extractCompleteLines(newChunk: "one\r\ntwo\r\nthr", buffer: &crlf)
        c("U2 CRLF lines split and stripped", cl == ["one", "two"] && crlf == "thr", "\(cl) buf=\(crlf)")

        var capped = ""
        for _ in 0..<100 {
            _ = BackgroundProcessRegistry.extractCompleteLines(
                newChunk: String(repeating: "é", count: 1000), buffer: &capped, maxLineBytes: 10_001)
        }
        let done = BackgroundProcessRegistry.extractCompleteLines(newChunk: "TAIL\nnext", buffer: &capped,
                                                                  maxLineBytes: 10_001)
        c("U3 partial line capped on a scalar boundary",
          done.count == 1 && done[0].utf8.count == 10_001 && !done[0].contains("\u{FFFD}")
          && done[0].hasSuffix("éT") && capped == "next",
          "bytes=\(done.first?.utf8.count ?? -1) buf=\(capped)")

        // Time bound: 32MB in 4KB chunks without a newline must be linear.
        var big = ""
        let chunk = String(repeating: "z", count: 4096)
        let t0 = Date()
        for _ in 0..<8192 {
            _ = BackgroundProcessRegistry.extractCompleteLines(newChunk: chunk, buffer: &big,
                                                               maxLineBytes: 70_000)
        }
        let dt = Date().timeIntervalSince(t0)
        c("U4 32MB newline-free line splits in bounded time", dt < 5 && big.utf8.count == 70_000,
          String(format: "%.2fs buf=%d", dt, big.utf8.count))

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
}
