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
    private struct CorruptState: Error {
        let device: dev_t
        let inode: ino_t
    }
    let directory: URL
    /// Upper bound on waiting for a sibling process's ledger update. The lock
    /// only ever covers local file I/O, never network work, so a few seconds is
    /// a ceiling for a loaded machine, not an expected wait.
    let lockWaitSeconds: TimeInterval
    init(directory: URL = StoragePaths.dataRoot, lockWaitSeconds: TimeInterval = 5) {
        self.directory = directory
        self.lockWaitSeconds = lockWaitSeconds
    }
    var file: URL { directory.appendingPathComponent("responses_usage.json") }
    var lockFile: URL { directory.appendingPathComponent("responses_usage.lock") }
    static let capacity = 1000
    static let maxBytes = 2 * 1024 * 1024
    static let corruptPrefix = "responses_usage.json.corrupt-"

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
        guard let state = try? JSONDecoder().decode(State.self, from: data) else {
            // Inspect unknown schema versions only after decoding fails. Valid
            // ledgers take a single decode on the frequent recording path.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? NSNumber, version != 1 { throw Failure() }
            throw CorruptState(device: info.st_dev, inode: info.st_ino)
        }
        // Never reset a future format written by a newer Briglia installation.
        guard state.version == 1 else { throw Failure() }
        guard state.records.count <= Self.capacity,
              state.records.allSatisfy({ record in
                  record.model.utf8.count <= 512 && record.lane.utf8.count <= 32 &&
                  [record.counts.input, record.counts.cachedInput, record.counts.cacheWriteInput,
                   record.counts.output, record.counts.reasoningOutput].allSatisfy { $0 == nil || (0...1_000_000_000).contains($0!) }
              }) else { throw CorruptState(device: info.st_dev, inode: info.st_ino) }
        return state
    }

    /// Only real recording recovers corruption. Read-only diagnostics and probes
    /// do not create, quarantine or replace files. Unsafe filesystem objects fail.
    private func loadForRecording() throws -> State {
        do { return try read() ?? State() }
        catch let corrupt as CorruptState {
            var current = stat()
            guard lstat(file.path, &current) == 0,
                  current.st_dev == corrupt.device, current.st_ino == corrupt.inode,
                  current.st_mode & S_IFMT == S_IFREG else { throw Failure() }
            let parked = directory.appendingPathComponent(Self.corruptPrefix + UUID().uuidString)
            try FileManager.default.moveItem(at: file, to: parked)
            try PrivateStorage.fsyncDirectory(directory.path)
            print("[Cache statistics] Damaged statistics preserved in \(parked.lastPathComponent); starting a new ledger.")
            return State()
        }
    }

    func quarantinedFiles() throws -> [URL] {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT { return [] }
            throw Failure()
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(Self.corruptPrefix) }
    }

    func diagnostic() throws -> String {
        let state: State?
        do { state = try read() }
        catch is CorruptState {
            return "Cache statistics are damaged; the next recorded model request will preserve the damaged file and start fresh statistics."
        }
        let parked = try quarantinedFiles().count
        return "Responses cache statistics: \(state?.records.count ?? 0) attempts, \(parked) preserved damaged file(s)."
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try PrivateStorage.ensureDirectory(directory)
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw Failure() }
        // The lock is held only for local reads/writes of a small file; waiting a
        // bounded few seconds beats dropping a record on a loaded machine.
        let deadline = ProcessInfo.processInfo.systemUptime + lockWaitSeconds
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
            var state = try loadForRecording()
            var record = record
            record.id = UUID()
            state.records.append(record)
            state.records = Array(state.records.suffix(Self.capacity))
            try write(state)
            return Ticket(generation: state.generation, recordID: record.id)
        }
    }

    func begin(context: ProviderExecutionContext, requestID: UUID, attempt: Int,
               sentRoutingState: Bool) throws -> Ticket? {
        if case .probe = context.lane { return nil }
        guard context.responsesOperation != .probe else { return nil }
        return try begin(Self.record(context: context, requestID: requestID,
            attempt: attempt, sentRoutingState: sentRoutingState))
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
            for parked in try quarantinedFiles() {
                if unlink(parked.path) != 0 && errno != ENOENT { throw Failure() }
            }
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
