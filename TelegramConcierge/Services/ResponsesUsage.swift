import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct ResponsesUsageCounts: Codable {
    var input: Int?
    var cachedInput: Int?
    var cacheWriteInput: Int?
    var output: Int?
    var reasoningOutput: Int?

    static func parse(_ bytes: Data) -> Self {
        let object = (try? JSONDecoder().decode(JSONValue.self, from: bytes))?.responsesObject
        let usage = object?["usage"]?.responsesObject
        var counts = Self(input: usage?["input_tokens"]?.responsesInt,
            cachedInput: usage?["input_tokens_details"]?.responsesObject?["cached_tokens"]?.responsesInt,
            cacheWriteInput: usage?["input_tokens_details"]?.responsesObject?["cache_write_tokens"]?.responsesInt,
            output: usage?["output_tokens"]?.responsesInt,
            reasoningOutput: usage?["output_tokens_details"]?.responsesObject?["reasoning_tokens"]?.responsesInt)
        func bounded(_ value: Int?) -> Int? { guard let value, value <= 1_000_000_000 else { return nil }; return value }
        counts.input = bounded(counts.input); counts.cachedInput = bounded(counts.cachedInput)
        counts.cacheWriteInput = bounded(counts.cacheWriteInput); counts.output = bounded(counts.output)
        counts.reasoningOutput = bounded(counts.reasoningOutput)
        return counts
    }
}

/// A bounded diagnostic ledger, not billing or a second conversation store.
/// Unknown counters remain nil. A wipe changes/removes the generation so late
/// completions cannot recreate pre-wipe records. Logging failures never fail LLM work.
struct ResponsesUsageStore {
    enum Provider: String, Codable { case subscription, openaiAPI, customAPI }
    enum Outcome: String, Codable { case pending, completed, failed, cancelled }
    struct Record: Codable {
        var id = UUID()
        let requestID: UUID
        let operationID: UUID
        var timestamp = Date()
        let provider: Provider
        let model: String
        let lane: String
        let operation: ResponsesOperation
        var attempt: Int
        var outcome: Outcome = .pending
        var httpStatus: Int?
        var durationMs: Int?
        var counts = ResponsesUsageCounts()
        var sentRoutingState = false
        var receivedRoutingState = false
    }
    struct State: Codable {
        var version = 1
        var generation = UUID()
        var records: [Record] = []
    }
    struct Ticket { let generation: UUID; let recordID: UUID }
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "Cache statistics unavailable: cannot safely read or write the local usage ledger." }
    }
    let directory: URL
    init(directory: URL = StoragePaths.dataRoot) { self.directory = directory }
    var file: URL { directory.appendingPathComponent("responses_usage.json") }
    var lockFile: URL { directory.appendingPathComponent("responses_usage.lock") }
    static let capacity = 1000
    static let maxBytes = 2 * 1024 * 1024

    func read() throws -> State? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw Failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size <= Self.maxBytes else { throw Failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: min(16384, Self.maxBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maxBytes else { throw Failure() }
        }
        guard let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1,
              state.records.count <= Self.capacity,
              state.records.allSatisfy({ record in
                  record.model.utf8.count <= 512 && record.lane.utf8.count <= 32 &&
                  [record.counts.input, record.counts.cachedInput, record.counts.cacheWriteInput,
                   record.counts.output, record.counts.reasoningOutput].allSatisfy { $0 == nil || (0...1_000_000_000).contains($0!) }
              }) else { throw Failure() }
        return state
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try PrivateStorage.ensureDirectory(directory)
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw Failure() }
        // Diagnostics must not stall a turn behind another process's network work.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard [EWOULDBLOCK, EAGAIN, EINTR].contains(errno),
                  ProcessInfo.processInfo.systemUptime < deadline else { throw Failure() }
            usleep(1000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func write(_ state: State) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(state)
        guard bytes.count <= Self.maxBytes else { throw Failure() }
        try PrivateStorage.writeAtomically(bytes, to: file)
    }

    func begin(_ record: Record) throws -> Ticket {
        try locked {
            var state = try read() ?? State()
            var record = record
            record.id = UUID()
            state.records.append(record)
            state.records = Array(state.records.suffix(Self.capacity))
            try write(state)
            return Ticket(generation: state.generation, recordID: record.id)
        }
    }

    func finish(_ ticket: Ticket, outcome: Outcome, status: Int?, durationMs: Int,
                counts: ResponsesUsageCounts, receivedRoutingState: Bool) throws {
        try locked {
            guard var state = try read(), state.generation == ticket.generation,
                  let index = state.records.firstIndex(where: { $0.id == ticket.recordID }) else { return }
            state.records[index].outcome = outcome
            state.records[index].httpStatus = status
            state.records[index].durationMs = durationMs
            state.records[index].counts = counts
            state.records[index].receivedRoutingState = receivedRoutingState
            try write(state)
        }
    }

    func clearForWipe() throws {
        try locked {
            // No decoding needed: even a malformed ledger must be removable.
            if unlink(file.path) != 0 && errno != ENOENT { throw Failure() }
            try PrivateStorage.fsyncDirectory(directory.path)
        }
    }

    static func record(context: ProviderExecutionContext, requestID: UUID, attempt: Int, sentRoutingState: Bool) -> Record {
        let provider: Provider = context.subscriptionGeneration != nil ? .subscription
            : (URL(string: context.endpoint)?.host?.lowercased() == "api.openai.com" ? .openaiAPI : .customAPI)
        let lane: String
        switch context.lane {
        case .main: lane = "main"
        case .archive: lane = "archive"
        case .subagent: lane = "subagent"
        case .ephemeral: lane = "ephemeral"
        case .probe: lane = "probe"
        }
        var record = Record(requestID: requestID, operationID: context.responsesTurn.id, provider: provider,
            model: String(context.model.prefix(128)), lane: lane, operation: context.responsesOperation, attempt: attempt)
        record.sentRoutingState = sentRoutingState
        return record
    }

    private static let warningLock = NSLock()
    private static var warned = false
    static func warn() {
        warningLock.lock(); defer { warningLock.unlock() }
        guard !warned else { return }; warned = true
        print("[Cache statistics] Local usage recording unavailable; requests continue. Check briglia cache-stats.")
    }

    func summary() throws -> String {
        let records = try read()?.records ?? []
        guard !records.isEmpty else { return "No Responses cache statistics recorded yet. Earlier requests cannot be reconstructed." }
        var lines = ["Responses cache statistics — last \(records.count) attempts (maximum \(Self.capacity))."]
        for provider in [Provider.subscription, .openaiAPI, .customAPI] {
            let group = records.filter { $0.provider == provider }
            guard !group.isEmpty else { continue }
            let measured = group.filter { $0.counts.input != nil && $0.counts.cachedInput != nil }
            let input = measured.reduce(0.0) { $0 + Double($1.counts.input!) }
            let cached = measured.reduce(0.0) { $0 + Double($1.counts.cachedInput!) }
            let ratio = input > 0 ? String(format: "%.1f%%", 100 * cached / input) : "unknown"
            lines.append("\(provider.rawValue): \(group.count) attempts, cache data \(measured.count)/\(group.count); cached \(Int(cached))/\(Int(input)) input tokens (\(ratio)).")
            let output = group.compactMap { $0.counts.output }.reduce(0.0) { $0 + Double($1) }
            let reasoning = group.compactMap { $0.counts.reasoningOutput }.reduce(0.0) { $0 + Double($1) }
            let reasoningCoverage = group.filter { $0.counts.reasoningOutput != nil }.count
            lines.append("Recorded output \(Int(output)) tokens; reasoning subset \(Int(reasoning)) (reported on \(reasoningCoverage)/\(group.count) attempts).")
        }
        lines.append("Pending/failed attempts may lack usage. Cached tokens are part of input; reasoning tokens are part of output. These are token statistics, not subscription credits or a bill.")
        return lines.joined(separator: "\n")
    }
}
