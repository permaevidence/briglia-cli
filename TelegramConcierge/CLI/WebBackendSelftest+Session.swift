import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The conversation search ID (KEYLESS_WEB plan A.5) and keyless Jina (A.6).
extension WebBackendSelftest {
    static func runSessionGroup(_ c: Checker, fake: FakeParallel, root: URL) async throws {
        print("S. Conversation search ID")
        let url = ParallelSessionStore.fileURL
        try? FileManager.default.removeItem(at: url)
        c.check("S.1 absent before the first free search", ParallelSessionStore.state() == .absent)
        let minted = try ParallelSessionStore.idForSearch()
        var st = stat()
        let mode = stat(url.path, &st) == 0 ? st.st_mode & 0o777 : 0
        let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        c.check("S.2 minted only when absent: a v4 UUID in {version:1, parallel_session_id, created}, mode 0600",
                UUID(uuidString: minted) != nil && object["version"] as? Int == 1 && object["parallel_session_id"] as? String == minted
                && object["created"] is String && mode == 0o600, "\(object) mode \(String(mode, radix: 8))")
        c.check("S.3 stable: the next read returns the same ID", (try? ParallelSessionStore.idForSearch()) == minted)
        // Concurrent first use mints one ID.
        try ParallelSessionStore.discard()
        let ids = await withTaskGroup(of: String?.self) { group -> Set<String> in
            for _ in 0..<8 { group.addTask { try? ParallelSessionStore.idForSearch() } }
            var out = Set<String>()
            for await id in group { if let id { out.insert(id) } }
            return out
        }
        c.check("S.4 eight concurrent first uses → exactly one ID", ids.count == 1)
        let stable = ids.first ?? ""
        // link(2) never replaces: a file another process minted wins.
        try ParallelSessionStore.discard()
        let other = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        try Data("{\"version\":1,\"parallel_session_id\":\"\(other)\",\"created\":\"x\"}".utf8).write(to: url)
        c.check("S.5 an ID already on disk is used as is (never overwritten)", (try? ParallelSessionStore.idForSearch()) == other)
        // Damaged: no new ID, a clear error, nothing rewritten.
        for (label, bytes) in [("garbage", "not json"), ("wrong version", "{\"version\":2,\"parallel_session_id\":\"\(other)\"}"),
                               ("not a UUID", "{\"version\":1,\"parallel_session_id\":\"abc\"}"), ("empty", "")] {
            try Data(bytes.utf8).write(to: url)
            let mintsBefore = ParallelSessionStore.mintCountForTesting
            var damagedError = false
            do { _ = try ParallelSessionStore.idForSearch() } catch let e as ParallelSessionStore.Damaged {
                damagedError = (e.errorDescription ?? "").contains("session file is damaged") && (e.errorDescription ?? "").contains("briglia doctor")
            } catch {}
            let after = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
            c.check("S.6 damaged (\(label)): the search fails with the doctor fix, no mint, the file is left as it was",
                    damagedError && ParallelSessionStore.mintCountForTesting == mintsBefore && after == bytes)
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: root.appendingPathComponent("elsewhere").path)
        if case .damaged = ParallelSessionStore.state() { c.check("S.7 a symlink at the path is damaged, never followed", true) }
        else { c.check("S.7 a symlink at the path is damaged", false) }
        try? FileManager.default.removeItem(at: url)
        // Explicit reset.
        try Data("garbage".utf8).write(to: url)
        let reset = try ParallelSessionStore.reset()
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))?.filter { $0.hasPrefix("search-session.json.damaged-") } ?? []
        if case .replaced(let id) = reset {
            c.check("S.8 /freesearch reset on a damaged file: it is moved aside (kept), a new ID minted", aside.count == 1 && (try? ParallelSessionStore.idForSearch()) == id && id != other)
        } else { c.check("S.8 reset on damaged", false, "\(reset)") }
        let current = try ParallelSessionStore.idForSearch()
        c.check("S.9 reset on a valid file keeps the ID (never rotates a working one)", (try? ParallelSessionStore.reset()) == .kept(current))
        // Wipe / import: discard → a new conversation mints a new ID.
        try ParallelSessionStore.discard()
        c.check("S.10 discard (/deleteuserdata, Mind import) removes it; the next free search mints a different ID",
                ParallelSessionStore.state() == .absent && (try? ParallelSessionStore.idForSearch()) != current)
        _ = stable

        // Never rotated on errors or limits: every call of a run of 429s and
        // 5xx carries the same session_id, and the file is unchanged.
        await fresh(fake, limits: { var l = ParallelSearchClient.Limits(); l.defaultBackoff = 0.01; return l }())
        let id = try ParallelSessionStore.idForSearch()
        let fileBefore = try Data(contentsOf: url)
        let orchestrator = WebOrchestrator()
        await orchestrator.configure(openRouterKey: "", serperKey: "", jinaKey: "")
        fake.enqueue([.status(429, headers: ["Retry-After": "0"], body: "{}"), .status(500, headers: [:], body: "{}"),
                      .rpcError(code: -32029, message: "rate limited")])
        _ = try? await orchestrator.executeWebQuery(queries: ["limit one", "limit two"])
        let sent = fake.requests.filter { $0.method == "tools/call" }.compactMap { ((($0.body["params"] as? [String: Any])?["arguments"] as? [String: Any])?["session_id"]) as? String }
        c.check("S.11 never rotated: after 429 / 500 / rate-limit errors every tools/call carried the same conversation ID and the file is byte-identical",
                sent.count >= 3 && Set(sent) == [id] && (try? Data(contentsOf: url)) == fileBefore, "\(sent)")
    }

    static func runJinaGroup(_ c: Checker, reader: WebFixtureServer) async throws {
        print("J. Keyless Jina")
        final class ReaderScript: @unchecked Sendable {
            let lock = NSLock()
            var statuses: [(Int, String)] = []
            func pop() -> (Int, String)? { lock.lock(); defer { lock.unlock() }; return statuses.isEmpty ? nil : statuses.removeFirst() }
            func set(_ s: [(Int, String)]) { lock.lock(); statuses = s; lock.unlock() }
        }
        let script = ReaderScript()
        reader.route = { request in
            if request.path.hasPrefix("/reader/") {
                if let (status, body) = script.pop() { return .init(status: status, contentType: "application/json", body: body) }
                return .init(contentType: "text/plain", body: "# Title\n\n" + String(repeating: "Readable page text. ", count: 30))
            }
            return .init(status: 404, body: "{}")
        }
        await JinaKeylessPacer.shared.configureForTesting()
        let keyed = WebOrchestrator(), keyless = WebOrchestrator()
        await keyed.configure(openRouterKey: "", serperKey: "", jinaKey: "jina_synthetic_key")
        await keyless.configure(openRouterKey: "", serperKey: "", jinaKey: "")
        // web_extract reads with includeImageCaptions: true.
        reader.clear()
        _ = try? await keyed.fetchWithJinaReader(originalURL: "https://site.test/a", includeImageCaptions: true)
        let keyedHeaders = reader.requests.first?.headers ?? [:]
        c.check("J.1 with a key: Authorization Bearer and x-with-generated-alt: true, exactly as before",
                keyedHeaders["authorization"] == "Bearer jina_synthetic_key" && keyedHeaders["x-with-generated-alt"] == "true", "\(keyedHeaders)")
        reader.clear()
        _ = try? await keyless.fetchWithJinaReader(originalURL: "https://site.test/b", includeImageCaptions: true)
        let keylessHeaders = reader.requests.first?.headers ?? [:]
        c.check("J.2 without a key: no Authorization and no x-with-generated-alt (the header keyless Jina refuses)",
                keylessHeaders["authorization"] == nil && keylessHeaders["x-with-generated-alt"] == nil && !reader.requests.isEmpty, "\(keylessHeaders)")

        // Typed anonymous block: keyless only, no health either way.
        let blockBody = "{\"data\":null,\"code\":403,\"name\":\"AbuseAlleviationError\",\"status\":40303,\"message\":\"Anonymous access to domain apnews.com blocked until Thu Oct 30 2026 13:05:12 GMT+0000 (Coordinated Universal Time) due to previous abuse found on https://apnews.com/: DDoS attack suspected: Too many domains\",\"readableMessage\":\"AbuseAlleviationError: Anonymous access to domain apnews.com blocked\"}"
        HealthProbe.clear()
        script.set([(403, blockBody)])
        var blockedText = ""
        do { _ = try await keyless.fetchWithJinaReader(originalURL: "https://apnews.com/article/y", includeImageCaptions: true) } catch { blockedText = error.localizedDescription }
        let fetchEvents = HealthProbe.events(.webFetchFree) + HealthProbe.events(.webFetch)
        c.check("J.3 keyless 403 AbuseAlleviationError → the per-page message naming the domain; no health failure and no health success",
                blockedText.contains("Jina temporarily blocks keyless reading of apnews.com") && blockedText.contains("Jina.ai key in briglia menu") && fetchEvents.isEmpty,
                "\(blockedText) \(fetchEvents)")
        // Truncated body: generic wording.
        let truncated = String(blockBody.prefix(60))
        let classified = JinaKeylessDomainBlocked.classify(HTTPError.badStatus(403, truncated, nil))
        let parsed = JinaKeylessDomainBlocked.classify(HTTPError.badStatus(403, blockBody, nil))
        c.check("J.4 a truncated block body still classifies (domain cut off → \"this site\"); a full one names domain and time",
                classified?.domain == nil && (classified?.errorDescription ?? "").contains("keyless reading of this site")
                && parsed?.domain == "apnews.com" && parsed?.until?.hasPrefix("Thu Oct 30 2026") == true,
                "\(String(describing: classified)) \(String(describing: parsed))")
        // With a key the same 403 is the generic path (deterministic health failure).
        HealthProbe.clear()
        script.set([(403, blockBody)])
        var keyedText = ""
        do { _ = try await keyed.fetchWithJinaReader(originalURL: "https://apnews.com/article/z", includeImageCaptions: true) } catch { keyedText = error.localizedDescription }
        c.check("J.5 the same 403 WITH a key is the generic path: no typed block, an immediate (deterministic) .webFetch failure",
                !keyedText.contains("temporarily blocks keyless") && HealthProbe.events(.webFetch) == [.init(subsystem: "webFetch", success: false, deterministic: true)],
                "\(keyedText) \(HealthProbe.events)")
        // Keyless 401 that is not a block: an ordinary failure, never immediate.
        HealthProbe.clear()
        script.set([(401, "{\"message\":\"Unauthorized\"}")])
        _ = try? await keyless.fetchWithJinaReader(originalURL: "https://site.test/401", includeImageCaptions: true)
        c.check("J.6 keyless 401 (not a block) → ordinary .webFetchFree failure (alerts only after the streak), never deterministic",
                HealthProbe.events(.webFetchFree) == [.init(subsystem: "webFetchFree", success: false, deterministic: false)], "\(HealthProbe.events)")
        c.check("J.7 the keyless health texts name the free service and the fix",
                MaintenanceAlertCenter.Subsystem.webFetchFree.entryDetail.contains("Free page reading (Jina, no key) is failing — add a Jina.ai key in briglia menu")
                && MaintenanceAlertCenter.Subsystem.webSearchFree.displayName == "free web search (Parallel)")

        // Pacing: every attempt (retries included) takes a slot.
        await JinaKeylessPacer.shared.configureForTesting()
        script.set([(503, "{}"), (503, "{}")])
        _ = try? await keyless.fetchWithJinaReader(originalURL: "https://site.test/retry", includeImageCaptions: true)
        let charged = await JinaKeylessPacer.shared.charged
        c.check("J.8 pacing charges every HTTP attempt: two 503 retries + success = 3 slots", charged == 3, "\(charged)")
        _ = try? await keyed.fetchWithJinaReader(originalURL: "https://site.test/keyed-no-pacing", includeImageCaptions: true)
        let chargedAfterKeyed = await JinaKeylessPacer.shared.charged
        c.check("J.9 keyed reads are never paced", chargedAfterKeyed == 3)
        let clock = MutableClock()
        await JinaKeylessPacer.shared.configureForTesting(window: 60, maxAttempts: 18, maxWait: 45, clock: { clock.now })
        var immediate = 0
        for _ in 0..<18 { if (try? await JinaKeylessPacer.shared.acquire()) != nil { immediate += 1 } }
        var refused = false
        do { try await JinaKeylessPacer.shared.acquire() } catch is JinaKeylessRateLimited { refused = true } catch {}
        c.check("J.10 18 attempts per rolling 60 s; the 19th, whose slot is 60 s away (> the 45 s wait bound), fails at once with the rate-limit text",
                immediate == 18 && refused && (JinaKeylessRateLimited().errorDescription ?? "").contains("Free page reading is at its rate limit"))
        clock.advance(61)
        let rolled = (try? await JinaKeylessPacer.shared.acquire()) != nil
        c.check("J.11 the window rolls: after 60 s a slot is free again", rolled)
        await JinaKeylessPacer.shared.configureForTesting(window: 2, maxAttempts: 1, maxWait: 30)
        try await JinaKeylessPacer.shared.acquire()
        let waiter = Task { () -> Bool in
            do { try await JinaKeylessPacer.shared.acquire(); return false } catch is CancellationError { return true } catch { return false }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelAt = Date()
        waiter.cancel()
        let wasCancelled = await waiter.value
        c.check("J.12 a pacing wait is cancellable (returns at once on cancel)", wasCancelled && Date().timeIntervalSince(cancelAt) < 1)
        await JinaKeylessPacer.shared.configureForTesting()
    }
}

// Durable publication of the search ID (Codex r1 finding 4) and the
// cross-process mint race.
extension WebBackendSelftest {
    static func runSessionDurabilityGroup(_ c: Checker, root: URL) async throws {
        print("SD. Search ID durability")
        struct Injected: Error {}
        let url = ParallelSessionStore.fileURL
        defer { ParallelSessionStore.fsyncDirectoryForTesting = nil }
        try? ParallelSessionStore.discard()
        // Post-link barrier failure: the ID is not used, the file stays.
        ParallelSessionStore.fsyncDirectoryForTesting = { _ in throw Injected() }
        let mints = ParallelSessionStore.mintCountForTesting
        var notDurable = false
        do { _ = try ParallelSessionStore.idForSearch() } catch is ParallelSessionStore.NotDurable { notDurable = true } catch {}
        let visible: String? = { if case .valid(let id) = ParallelSessionStore.state() { return id }; return nil }()
        c.check("S.12 a failed post-link directory barrier fails the search (NotDurable) and keeps the published file",
                notDurable && visible != nil && ParallelSessionStore.mintCountForTesting == mints + 1)
        // Retry confirms the SAME id, never re-mints.
        ParallelSessionStore.fsyncDirectoryForTesting = nil
        let retried = try? ParallelSessionStore.idForSearch()
        c.check("S.13 the next call confirms and uses the SAME id (no new mint)", retried == visible && ParallelSessionStore.mintCountForTesting == mints + 1)
        // A file published by another process is confirmed before first use.
        try ParallelSessionStore.discard()
        let foreign = "12345678-9abc-4def-8123-456789abcdef"
        try Data("{\"version\":1,\"parallel_session_id\":\"\(foreign)\",\"created\":\"x\"}".utf8).write(to: url)
        ParallelSessionStore.fsyncDirectoryForTesting = { _ in throw Injected() }
        var refused = false
        do { _ = try ParallelSessionStore.idForSearch() } catch is ParallelSessionStore.NotDurable { refused = true } catch {}
        ParallelSessionStore.fsyncDirectoryForTesting = nil
        c.check("S.14 an id found on disk (another process's mint) is used only after its directory entry is confirmed",
                refused && (try? ParallelSessionStore.idForSearch()) == foreign)
        // Discard durability.
        ParallelSessionStore.fsyncDirectoryForTesting = { _ in throw Injected() }
        var discardFailed = false
        do { try ParallelSessionStore.discard() } catch { discardFailed = true }
        ParallelSessionStore.fsyncDirectoryForTesting = nil
        c.check("S.15 a discard whose directory barrier fails reports the failure (wipe/import never claim a non-durable removal)",
                discardFailed && ParallelSessionStore.state() == .absent)
        // Pre-link failure: nothing published, no ID.
        let locked = root.appendingPathComponent("locked-dir")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o500)
        ParallelSessionStore.fileURLOverrideForTesting = locked.appendingPathComponent("search-session.json")
        var preLinkFailed = false
        do { _ = try ParallelSessionStore.idForSearch() } catch { preLinkFailed = true }
        let lockedState = ParallelSessionStore.state()
        chmod(locked.path, 0o700)
        ParallelSessionStore.fileURLOverrideForTesting = url
        c.check("S.16 a failure before publication (temp file can't be created) returns no ID and publishes nothing",
                preLinkFailed && lockedState == .absent)

        // Cross-process mint race: six processes, one file, one ID.
        let raceFile = root.appendingPathComponent("race-\(UUID().uuidString.prefix(6)).json")
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var processes: [(Process, Pipe)] = []
        for _ in 0..<6 {
            let p = Process()
            p.executableURL = binary
            p.arguments = ["__web-backend-selftest", "--mint-session-at", raceFile.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            processes.append((p, pipe))
        }
        for (p, _) in processes { try p.run() }
        var ids: [String] = []
        for (p, pipe) in processes {
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            ids.append(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let onDisk = (try? JSONSerialization.jsonObject(with: Data(contentsOf: raceFile)) as? [String: Any])?["parallel_session_id"] as? String
        c.check("S.17 six processes minting at once on one file all get the same ID, the one on disk (link never replaces)",
                Set(ids).count == 1 && ids.first == onDisk && UUID(uuidString: ids.first ?? "") != nil, "\(ids)")
    }
}
