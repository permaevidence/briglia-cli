import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct ResponsesCacheSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "__responses-cache-selftest", shouldDisplay: false)
    @Option(name: .long) var ledgerWorker: String?

    func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-cache-test-\(UUID())")
        for (key, dir) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
            setenv(key, root.appendingPathComponent(dir).path, 1)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        if let ledgerWorker {
            let store = ResponsesUsageStore(directory: URL(fileURLWithPath: ledgerWorker))
            for _ in 0..<10 { _ = try store.begin(record()) }
            return
        }
        let c = ResponsesSelftest.Checks()
        try PrivateStorage.ensureDirectory(root)
        let context = subscription()
        let state = context.responsesTurn
        c.check("new turn has no routing state", state.value(for: context.responsesScope) == nil)
        state.receive("first", scope: context.responsesScope)
        state.receive("second", scope: context.responsesScope)
        c.check("first state wins across context copies", context.responsesTurn.value(for: context.responsesScope) == "first")
        var foreign = subscription(key: "account-b")
        foreign.responsesTurn = state
        c.check("account generation cannot inherit routing", foreign.responsesTurn.value(for: foreign.responsesScope) == nil)
        let otherModel = ResponsesScope(endpoint: SubscriptionEndpoint.inference, profile: "chatgpt", model: "other", credentialFingerprint: context.responsesScope.credentialFingerprint)
        c.check("model change cannot inherit routing", state.value(for: otherModel) == nil)
        let api = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "fixture", model: "fixture", lane: .main)
        c.check("API endpoint cannot inherit subscription routing", state.value(for: api.responsesScope) == nil)
        c.check("maintenance has independent owner and same affinity", context.forOperation(.pruneSummary).responsesTurn.id != state.id && context.forOperation(.pruneSummary).affinityKey == context.affinityKey)
        state.close(); state.receive("late", scope: context.responsesScope)
        c.check("closed turn discards state and ignores late headers", state.value(for: context.responsesScope) == nil)
        for invalid in ["", "bad\r\nheader", String(repeating: "a", count: 8193)] {
            let fresh = ResponsesTurn(); fresh.receive(invalid, scope: context.responsesScope)
            c.check("invalid header ignored", fresh.value(for: context.responsesScope) == nil)
        }
        let fresh = ResponsesTurn()
        DispatchQueue.concurrentPerform(iterations: 50) { i in fresh.receive("state-\(i)", scope: context.responsesScope) }
        let winner = fresh.value(for: context.responsesScope)
        fresh.receive("replace", scope: context.responsesScope)
        c.check("concurrent headers retain one first value", winner != nil && winner == fresh.value(for: context.responsesScope))
        try probes(c, root: root)
        try await transport(c)
        try await webUsage(c)
        try ledger(c, root: root)
        print("Responses cache selftest: \(c.total - c.failures)/\(c.total)")
        if c.failures > 0 { throw ValidationError("Cache/routing checks failed") }
    }

    private func probes(_ c: ResponsesSelftest.Checks, root: URL) throws {
        let directory = root.appendingPathComponent("untouched-probe")
        let store = ResponsesUsageStore(directory: directory)
        var probe = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "fixture", model: "fixture", lane: .probe(UUID()))
        c.check("probe lane creates no receipt", try store.begin(context: probe, requestID: UUID(), attempt: 1, sentRoutingState: false) == nil)
        probe = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "fixture", model: "fixture", lane: .main)
        probe.responsesOperation = .probe
        c.check("probe operation creates no receipt", try store.begin(context: probe, requestID: UUID(), attempt: 1, sentRoutingState: false) == nil)
        _ = try store.diagnostic()
        c.check("probes and fresh diagnostics create no directory or lock", !FileManager.default.fileExists(atPath: directory.path))
    }

    private func subscription(key: String = "account-a") -> ProviderExecutionContext {
        var context = ProviderExecutionContext.responsesAPI(baseURL: SubscriptionEndpoint.inference, key: key, model: "fixture", lane: .main)
        context.subscriptionGeneration = key; context.profileIdentity = "chatgpt"
        return context
    }
    private func record() -> ResponsesUsageStore.Record {
        ResponsesUsageStore.record(context: subscription(), requestID: UUID(), attempt: 1, sentRoutingState: false)
    }

    private func transport(_ c: ResponsesSelftest.Checks) async throws {
        let server = try CaptureServer(); defer { server.stop() }
        // Only synthetic HTTP fixtures; the production transport still refuses redirects.
        server.contentTypeOverride = "application/json\r\nx-codex-turn-state: synthetic-state"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/responses")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        let context = subscription()
        server.script(["{}"])
        let first = ResponsesHTTPTransport(routingContext: context)
        _ = try await first.send(request, overallTimeout: 5)
        c.check("HTTP 200 routing header captured", first.usageStatus == 200 && first.receivedRoutingState && context.responsesTurn.value(for: context.responsesScope) == "synthetic-state")
        let refused = subscription()
        for status in [401, 500] {
            server.script(["{}"], statuses: [status])
            do { _ = try await ResponsesHTTPTransport(routingContext: refused).send(request, overallTimeout: 5) } catch {}
            c.check("HTTP error cannot seed routing state", refused.responsesTurn.value(for: refused.responsesScope) == nil)
        }
        let api = ProviderExecutionContext.responsesAPI(baseURL: "https://api.openai.com/v1", key: "fixture", model: "fixture", lane: .main)
        server.script(["{}"])
        let apiTransport = ResponsesHTTPTransport(routingContext: api)
        _ = try await apiTransport.send(request, overallTimeout: 5)
        c.check("API ignores routing response header", !apiTransport.receivedRoutingState)
        let incomplete = subscription()
        server.script(["data: {invalid}\n\n"])
        do { _ = try await ResponsesHTTPTransport(routingContext: incomplete).send(request, overallTimeout: 5, subscription: true) } catch {}
        c.check("successful headers survive failed stream for same-turn retry", incomplete.responsesTurn.value(for: incomplete.responsesScope) == "synthetic-state")
        c.check("routing never persists into a fresh turn", subscription().responsesTurn.value(for: context.responsesScope) == nil)
    }

    private func webUsage(_ c: ResponsesSelftest.Checks) async throws {
        let server = try CaptureServer(); defer { server.stop() }
        server.script(["{}", #"{"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":80}}}"#], statuses: [500, 200])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/responses")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        let record = ResponsesUsageStore.Record(requestID: UUID(), operationID: UUID(), provider: .openaiAPI,
            model: "fixture", lane: "ephemeral", operation: .webResearch, attempt: 1)
        _ = try await httpDataWithRetry(request: request, label: "cache-selftest", usageRecord: record)
        let rows = try ResponsesUsageStore().read()!.records
        c.check("web Responses records failed and successful attempts", rows.count == 2 && rows.map { $0.attempt } == [1, 2] && rows.first?.httpStatus == 500 && rows.last?.counts.cachedInput == 80)
        c.check("web retry shares request and operation without duplicate record ids", rows[0].requestID == rows[1].requestID && rows[0].operationID == rows[1].operationID && rows[0].id != rows[1].id)
        try PrivateStorage.writeAtomically(Data("malformed".utf8), to: ResponsesUsageStore().file)
        server.script(["{}"])
        _ = try await httpDataWithRetry(request: request, label: "cache-selftest", usageRecord: record)
        c.check("unavailable diagnostics never prevent a model request", server.completeRequests.count == 3)
    }

    private func ledger(_ c: ResponsesSelftest.Checks, root: URL) throws {
        let store = ResponsesUsageStore(directory: root)
        c.check("fresh read does not create a ledger", try store.read() == nil && !FileManager.default.fileExists(atPath: store.file.path))
        let counts = ResponsesUsageCounts.parse(Data(#"{"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":20},"output_tokens":30,"output_tokens_details":{"reasoning_tokens":25}}}"#.utf8))
        c.check("cache zero distinguished from missing", counts.cachedInput == 0 && ResponsesUsageCounts.parse(Data("{}".utf8)).cachedInput == nil)
        c.check("cache write and reasoning subsets parsed", counts.cacheWriteInput == 20 && counts.reasoningOutput == 25)
        let ticket = try store.begin(record())
        try store.finish(ticket, outcome: .completed, status: 200, durationMs: 10, counts: counts, receivedRoutingState: true)
        c.check("usage survives new store instance", try ResponsesUsageStore(directory: root).read()?.records.first?.counts.input == 100)
        c.check("report discloses measured coverage", try store.summary().contains("cache data 1/1"))
        let bytes = try Data(contentsOf: store.file)
        c.check("ledger excludes credentials and routing payload", !String(decoding: bytes, as: UTF8.self).contains("account-a") && !String(decoding: bytes, as: UTF8.self).contains("synthetic-state"))
        let pending = try store.begin(record())
        try store.clearForWipe()
        try store.finish(pending, outcome: .completed, status: 200, durationMs: 1, counts: counts, receivedRoutingState: false)
        c.check("late completion cannot recreate wiped ledger", try store.read() == nil)
        _ = try store.begin(record())
        try store.finish(pending, outcome: .completed, status: 200, durationMs: 1, counts: counts, receivedRoutingState: false)
        c.check("old completion cannot affect new ledger generation", try store.read()?.records.first?.outcome == .pending)
        var seeded = ResponsesUsageStore.State()
        seeded.records = (0..<ResponsesUsageStore.capacity).map { _ in record() }
        try PrivateStorage.writeAtomically(JSONEncoder().encode(seeded), to: store.file)
        _ = try store.begin(record())
        c.check("ledger retains bounded last 1000 attempts", try store.read()?.records.count == 1000 && store.read()?.records.first?.id == seeded.records[1].id)
        try store.clearForWipe()
        let children = try (0..<2).map { _ -> Process in
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["__responses-cache-selftest", "--ledger-worker", root.path]
            try child.run(); return child
        }
        children.forEach { $0.waitUntilExit() }
        c.check("two-process recording has no lost entries", try children.allSatisfy { $0.terminationStatus == 0 } && store.read()?.records.count == 20)
        // A sibling holding the lock for file I/O on a loaded machine must not
        // cost a record: the old 100 ms budget did (CI reruns 2026-09-07/08).
        let holder = open(store.lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        c.check("contention fixture holds the ledger lock", holder >= 0 && flock(holder, LOCK_EX) == 0)
        let release = Thread { usleep(400_000); flock(holder, LOCK_UN); close(holder) }
        let started = ProcessInfo.processInfo.systemUptime
        release.start()
        _ = try store.begin(record())
        let waited = ProcessInfo.processInfo.systemUptime - started
        c.check("recording waits out a briefly held lock instead of failing", waited >= 0.3 && waited < 5)
        let impatient = ResponsesUsageStore(directory: root, lockWaitSeconds: 0.2)
        let blocker = open(store.lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        c.check("bounded-wait fixture holds the ledger lock", blocker >= 0 && flock(blocker, LOCK_EX) == 0)
        let began = ProcessInfo.processInfo.systemUptime
        c.rejects("lock wait stays bounded while the lock is held", { _ = try impatient.begin(record()) })
        let gaveUp = ProcessInfo.processInfo.systemUptime - began
        c.check("bounded wait gives up near its budget", gaveUp >= 0.2 && gaveUp < 2)
        flock(blocker, LOCK_UN); close(blocker)
        c.check("recording resumes once the lock is released", try store.read()?.records.count == 21 && (try? store.begin(record())) != nil)
        try PrivateStorage.writeAtomically(Data("malformed sentinel".utf8), to: store.file)
        c.check("doctor reports corruption without changing bytes", try store.diagnostic().contains("damaged") && Data(contentsOf: store.file) == Data("malformed sentinel".utf8))
        let recovered = try store.begin(record())
        let parked = try store.quarantinedFiles()
        c.check("corrupt ledger bytes preserved in quarantine", try parked.count == 1 && Data(contentsOf: parked[0]) == Data("malformed sentinel".utf8))
        c.check("corruption recovery starts a fresh generation", try recovered.generation != ticket.generation && store.read()?.records.count == 1)
        try store.finish(ticket, outcome: .completed, status: 200, durationMs: 1, counts: counts, receivedRoutingState: false)
        c.check("pre-recovery receipt cannot update regenerated state", try store.read()?.records.first?.outcome == .pending)
        try store.finish(recovered, outcome: .completed, status: 200, durationMs: 1, counts: counts, receivedRoutingState: false)
        c.check("recording resumes after corruption", try store.read()?.records.first?.counts.input == 100)
        try PrivateStorage.writeAtomically(Data(#"{"version":2}"#.utf8), to: store.file)
        c.rejects("future ledger version is never reset", { _ = try store.begin(record()) })
        c.check("future ledger bytes preserved", try Data(contentsOf: store.file) == Data(#"{"version":2}"#.utf8))
        try store.clearForWipe()
        c.check("wipe removes quarantined diagnostic data", try store.quarantinedFiles().isEmpty)
        let target = root.appendingPathComponent("target")
        try PrivateStorage.writeAtomically(Data("target sentinel".utf8), to: target)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        c.rejects("symlink ledger refused", { _ = try store.begin(record()) })
        c.check("unsafe object never quarantined", try store.quarantinedFiles().isEmpty)
        try store.clearForWipe()
        c.check("wipe removes link without touching target", try Data(contentsOf: target) == Data("target sentinel".utf8))
        _ = try store.begin(record()); chmod(store.file.path, 0o644)
        c.rejects("wide ledger permissions refused", { _ = try store.read() })
        c.rejects("wide ledger not reset by recording", { _ = try store.begin(record()) })
    }
}
