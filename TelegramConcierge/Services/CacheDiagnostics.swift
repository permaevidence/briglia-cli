import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Prompt-cache diagnosis (private-docs CACHE_KEY_AND_IMAGE_REJECTION_PLAN
/// v2 §1.4–§1.5, Codex round 2 answers 3 and 5). Two parts:
///
/// 1. `observe`: every serialized model request of both protocols is offered
///    here with its lane, the number of documented tail items (tail system
///    message, tail user message, ambient status) and the transitions the
///    caller recorded since the lane's previous request. With
///    `BRIGLIA_CACHE_DIAGNOSTICS=1` (default off) a bounded, owner-only,
///    rotating log under `<data root>/logs/` gets one line per request:
///    sizes, allowlisted settings, keyed hashes (HMAC-SHA256 with a random
///    per-install key kept beside the log, never exported) of the system
///    text, of each ordered input item and of each tool definition, and the
///    first difference against the lane's previous request. Never logged:
///    raw content, tool arguments/results, credentials, headers, image or
///    file bytes. Nothing here can fail or alter a request: the body is only
///    read, every error is swallowed and counted.
/// 2. `PrefixCheck`: the Step 0 rule, a pure function over captured
///    requests. Class A — no transition between two requests of a lane: the
///    system text, the tools (in order), the settings and every input item
///    before the previous request's documented tail are identical by
///    position. Class B — at a recorded transition the change must stay in
///    that transition's scope (a label never excuses an unrelated change to
///    tools or system text).
enum CacheDiagnostics {
    static let environmentKey = "BRIGLIA_CACHE_DIAGNOSTICS"

    /// One serialized request as offered to `observe`.
    struct Request {
        let lane: String
        let protocolName: String
        let body: Data
        let tailCount: Int
        let transitions: [String]
    }

    // Test seams (selftests run in private scratch roots).
    nonisolated(unsafe) static var captureForTesting: ((Request) -> Void)?
    nonisolated(unsafe) static var enabledOverrideForTesting: Bool?
    nonisolated(unsafe) static var maxLogBytesForTesting: Int?
    nonisolated(unsafe) static var writeFaultForTesting: (() throws -> Void)?

    static let maxLogBytes = 5 * 1024 * 1024
    /// Per-lane bytes kept for byte offsets; beyond it only hashes remain
    /// and the offset is reported as unavailable.
    static var maxRetainedBytesPerLane: Int { maxRetainedBytesOverrideForTesting ?? 8 * 1024 * 1024 }
    nonisolated(unsafe) static var maxRetainedBytesOverrideForTesting: Int?
    static let maxLanes = 8

    private static let envEnabled = ProcessInfo.processInfo.environment[environmentKey] == "1"
    static var enabled: Bool { enabledOverrideForTesting ?? envEnabled }
    /// Whether anything consumes observations (callers skip extra work otherwise).
    static var active: Bool { enabled || captureForTesting != nil }

    static var logURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("cache-diagnostics.log")
    }
    static var keyURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("cache-diagnostics.key")
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var pending: [String: [String]] = [:]
        /// The lane's previous request; items are full HMACs (not the raw
        /// items) when it was too large to keep, then offsets are unknown.
        var previous: [String: Retained] = [:]
        /// Every stream with any state (previous request, pending reasons,
        /// eviction count), least recently used first; all three
        /// dictionaries are trimmed together to `maxLanes` streams.
        var laneOrder: [String] = []
        var evicted: [String: Int] = [:]
        var key: SymmetricKey?
        var writeFailures = 0
    }
    private static let state = State()

    static var writeFailures: Int { state.lock.lock(); defer { state.lock.unlock() }; return state.writeFailures }

    /// The caller recorded an intended prefix transition on `lane`
    /// (turn-start, prune, compaction, archive-commit, tool-exposure,
    /// system-refresh, image-rejection); it applies to the lane's next request.
    static func noteTransition(_ reason: String, lane: AffinityLane) {
        guard active else { return }
        state.lock.lock(); defer { state.lock.unlock() }
        touchLocked(lane.laneId)
        if state.pending[lane.laneId]?.contains(reason) != true { state.pending[lane.laneId, default: []].append(reason) }
    }

    /// Mark `label` most recently used; drop every kind of state of the
    /// least recently used streams beyond `maxLanes` (caller holds the lock).
    private static func touchLocked(_ label: String) {
        state.laneOrder.removeAll { $0 == label }
        state.laneOrder.append(label)
        while state.laneOrder.count > maxLanes {
            let oldest = state.laneOrder.removeFirst()
            state.previous.removeValue(forKey: oldest)
            state.pending.removeValue(forKey: oldest)
            state.evicted.removeValue(forKey: oldest)
        }
    }

    /// Retained-state size (tests): bytes kept for comparisons and the
    /// number of streams in each dictionary.
    static var retainedStats: (bytes: Int, previous: Int, pending: Int, evicted: Int) {
        state.lock.lock(); defer { state.lock.unlock() }
        return (state.previous.values.reduce(0) { $0 + $1.bytes }, state.previous.count, state.pending.count, state.evicted.count)
    }

    /// Responses native-replay bound (Codex round 2, answer 5): eviction of
    /// older native rounds at the replay-byte bound is an intended
    /// transition; it is recorded when the evicted count grows.
    static func noteNativeReplayEviction(_ evictedRounds: Int, context: ProviderExecutionContext) {
        guard active else { return }
        let label = streamLabel(context)
        state.lock.lock(); defer { state.lock.unlock() }
        touchLocked(label)
        let previous = state.evicted[label] ?? 0
        state.evicted[label] = evictedRounds
        if evictedRounds > previous, state.pending[label]?.contains("native-replay-eviction") != true {
            state.pending[label, default: []].append("native-replay-eviction")
        }
    }

    /// The request stream a request belongs to: its lane, plus the
    /// maintenance operation when it is not an ordinary conversation request
    /// (bounded compaction summaries never share the conversation prefix, so
    /// they are compared among themselves, not with the agent's requests).
    static func streamLabel(_ context: ProviderExecutionContext) -> String {
        context.lane.laneId + (context.responsesOperation == .conversation ? "" : "#" + context.responsesOperation.rawValue)
    }

    /// Offer one serialized request. Never throws, never changes `body`.
    static func observe(context: ProviderExecutionContext, protocolName: String, body: Data?, tailCount: Int) {
        guard active, let body else { return }
        let label = streamLabel(context)
        state.lock.lock()
        let transitions = state.pending.removeValue(forKey: label) ?? []
        touchLocked(label)
        state.lock.unlock()
        let request = Request(lane: label, protocolName: protocolName, body: body, tailCount: tailCount, transitions: transitions)
        captureForTesting?(request)
        guard enabled else { return }
        do { try writeLine(for: request) } catch {
            state.lock.lock(); state.writeFailures += 1; state.lock.unlock()
        }
    }

    /// Clears in-memory state (tests, /deleteuserdata).
    static func reset() {
        state.lock.lock(); defer { state.lock.unlock() }
        state.pending = [:]; state.previous = [:]; state.laneOrder = []; state.evicted = [:]; state.key = nil; state.writeFailures = 0
    }

    // MARK: Parsing (shared by the log and the Step 0 check)

    struct Parsed {
        var system: Data
        var items: [Data]
        var tools: [Data]
        var settings: [String: Data]
        var tailCount: Int
        var totalBytes: Int
    }

    static func canonical(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    }

    /// Chat Completions: `messages[0]` is the system message. Responses:
    /// `instructions` (subscription) or `input[0]` with role system.
    static func parse(_ request: Request) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return nil }
        var items = (root["messages"] as? [Any]) ?? (root["input"] as? [Any]) ?? []
        var system = Data()
        if let instructions = root["instructions"] { system = canonical(instructions) }
        else if let first = items.first as? [String: Any], first["role"] as? String == "system" {
            system = canonical(first); items.removeFirst()
        }
        var settings: [String: Data] = [:]
        for (key, value) in root where !["messages", "input", "tools", "instructions"].contains(key) {
            settings[key] = canonical(value)
        }
        return Parsed(system: system, items: items.map(canonical), tools: ((root["tools"] as? [Any]) ?? []).map(canonical),
                      settings: settings, tailCount: min(request.tailCount, items.count), totalBytes: request.body.count)
    }

    /// What a stream keeps of its previous request, within
    /// `maxRetainedBytesPerLane` counting EVERY component (system, tools,
    /// settings, items). Raw when it fits; otherwise all components as
    /// 32-byte HMACs (offsets then unavailable); when even the hashes do
    /// not fit, only a prefix of the tool and item hashes is kept and a
    /// comparison past it is reported as partial, never guessed.
    struct Retained {
        var parsed: Parsed
        var hashed: Bool
        var itemLimit: Int?
        var toolLimit: Int?
        /// Even the hashed system text and settings did not fit: nothing
        /// is compared against this request.
        var dropped = false
        var bytes: Int { CacheDiagnostics.retainedBytes(parsed) }
    }

    static func retainedBytes(_ p: Parsed) -> Int {
        p.system.count + p.tools.reduce(0) { $0 + $1.count } + p.settings.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
            + p.items.reduce(0) { $0 + $1.count }
    }

    struct Difference: Equatable {
        enum Component: String { case system, tools, settings, input }
        let component: Component
        /// Item index (input), tool index (tools) or settings key.
        let position: String
        /// addition / removal / reordering / change.
        let kind: String
        /// Byte offset inside the first differing item, when known.
        let byteOffset: Int?
    }

    /// Every component that changed between two requests of a lane; the
    /// input is compared by position over the previous request's non-tail
    /// items (appending after them is not a change).
    static func differences(previous: Parsed, current: Parsed) -> [Difference] {
        var result: [Difference] = []
        if previous.system != current.system {
            result.append(Difference(component: .system, position: "system", kind: "change",
                                     byteOffset: firstByteDifference(previous.system, current.system)))
        }
        if previous.tools != current.tools {
            let index = Array(zip(previous.tools, current.tools)).firstIndex { $0.0 != $0.1 } ?? min(previous.tools.count, current.tools.count)
            let kind = previous.tools.count == current.tools.count && Set(previous.tools) == Set(current.tools) ? "reordering"
                : current.tools.count > previous.tools.count ? "addition" : current.tools.count < previous.tools.count ? "removal" : "change"
            result.append(Difference(component: .tools, position: "tool \(index)", kind: kind, byteOffset: nil))
        }
        for key in Set(previous.settings.keys).union(current.settings.keys).sorted() where previous.settings[key] != current.settings[key] {
            result.append(Difference(component: .settings, position: key, kind: "change", byteOffset: nil)); break
        }
        let stable = previous.items.count - previous.tailCount
        for index in 0..<stable {
            guard index < current.items.count else {
                result.append(Difference(component: .input, position: "item \(index)", kind: "removal", byteOffset: nil)); break
            }
            guard previous.items[index] != current.items[index] else { continue }
            let kind: String
            if index + 1 < stable, current.items[index] == previous.items[index + 1] { kind = "removal" }
            else if index + 1 < current.items.count, current.items[index + 1] == previous.items[index] { kind = "addition" }
            else if Set(previous.items[index..<stable]) == Set(current.items[index..<min(stable, current.items.count)]) { kind = "reordering" }
            else { kind = "change" }
            result.append(Difference(component: .input, position: "item \(index)", kind: kind,
                                     byteOffset: firstByteDifference(previous.items[index], current.items[index])))
            break
        }
        return result
    }

    static func firstByteDifference(_ a: Data, _ b: Data) -> Int? {
        let x = [UInt8](a), y = [UInt8](b)
        for i in 0..<min(x.count, y.count) where x[i] != y[i] { return i }
        return x.count == y.count ? nil : min(x.count, y.count)
    }

    // MARK: Step 0 check

    /// What a recorded transition may change (Class B scope).
    static let transitionScope: [String: Set<Difference.Component>] = [
        "turn-start": [.input],
        "prune": [.input, .system],
        "compaction": [.input],
        "archive-commit": [.input, .system],
        "tool-exposure": [.tools, .system],
        "native-replay-eviction": [.input],
        "system-refresh": [.system],
        "image-rejection": [.input],
    ]

    struct Finding: CustomStringConvertible {
        let lane: String
        let request: Int
        let klass: String
        let detail: String
        var description: String { "\(lane) request \(request): Class \(klass) — \(detail)" }
    }

    struct CheckResult {
        var findings: [Finding] = []
        var classAPairs = 0
        var classBTransitions: [(lane: String, request: Int, reasons: [String], first: String)] = []
    }

    /// The Step 0 rule over a sequence of captured requests (any lanes, in
    /// send order).
    static func check(_ requests: [Request]) -> CheckResult {
        var result = CheckResult()
        var last: [String: (Parsed, Int)] = [:]
        for (number, request) in requests.enumerated() {
            guard let current = parse(request) else {
                result.findings.append(Finding(lane: request.lane, request: number, klass: "A", detail: "unparsable body")); continue
            }
            defer { last[request.lane] = (current, number) }
            guard let (previous, _) = last[request.lane] else { continue }
            let diffs = differences(previous: previous, current: current)
            let describe = { (d: Difference) in "\(d.component.rawValue) \(d.position) \(d.kind)\(d.byteOffset.map { " at byte \($0)" } ?? "")" }
            if request.transitions.isEmpty {
                result.classAPairs += 1
                if let first = diffs.first {
                    result.findings.append(Finding(lane: request.lane, request: number, klass: "A",
                                                   detail: "prefix changed without a transition: " + describe(first)))
                }
            } else {
                let allowed = request.transitions.reduce(into: Set<Difference.Component>()) { $0.formUnion(transitionScope[$1] ?? []) }
                result.classBTransitions.append((request.lane, number, request.transitions, diffs.first.map(describe) ?? "no change"))
                for diff in diffs where !allowed.contains(diff.component) {
                    result.findings.append(Finding(lane: request.lane, request: number, klass: "B",
                        detail: "\(request.transitions.joined(separator: "+")) changed \(describe(diff)) outside its scope"))
                }
            }
        }
        return result
    }

    // MARK: Log

    private static func hmac(_ data: Data, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func loadKey() throws -> SymmetricKey {
        if let key = state.key { return key }
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            state.key = SymmetricKey(data: data); return state.key!
        }
        try PrivateStorage.ensureDirectory(keyURL.deletingLastPathComponent())
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        try PrivateStorage.writeAtomically(Data(bytes), to: keyURL)
        state.key = SymmetricKey(data: Data(bytes))
        return state.key!
    }

    /// Settings whose VALUE may be logged; every other key is hashed.
    static let loggedSettings: Set<String> = ["model", "store", "stream", "truncation", "tool_choice", "parallel_tool_calls",
                                              "reasoning_effort", "max_output_tokens", "service_tier"]

    private static func writeLine(for request: Request) throws {
        try writeFaultForTesting?()
        guard let parsed = parse(request) else { return }
        state.lock.lock(); defer { state.lock.unlock() }
        let key = try loadKey()
        var settings: [String: Any] = [:]
        for (name, value) in parsed.settings {
            if loggedSettings.contains(name), let plain = try? JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed]),
               plain is String || plain is NSNumber {
                settings[name] = plain
            } else if name == "reasoning", let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
                      let effort = object["effort"] as? String {
                settings["reasoning.effort"] = effort
            } else {
                settings[name] = "hmac:" + hmac(value, key: key)
            }
        }
        let itemHashes = parsed.items.map { hmac($0, key: key) }
        let toolHashes = parsed.tools.map { hmac($0, key: key) }
        var line: [String: Any] = [
            "t": ISO8601DateFormatter().string(from: Date()),
            "lane": request.lane, "protocol": request.protocolName,
            "items": parsed.items.count, "bytes": parsed.totalBytes, "tools": parsed.tools.count, "tail": parsed.tailCount,
            "transitions": request.transitions, "settings": settings,
            "system": hmac(parsed.system, key: key),
        ]
        func full(_ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: key)) }
        func hashedAll(_ p: Parsed) -> Parsed {
            var copy = p
            copy.system = full(p.system)
            copy.tools = p.tools.map(full)
            copy.items = p.items.map(full)
            copy.settings = p.settings.mapValues(full)
            return copy
        }
        func limited(_ p: Parsed, items: Int?, tools: Int?) -> Parsed {
            var copy = p
            if let items { copy.items = Array(p.items.prefix(items)) }
            if let tools { copy.tools = Array(p.tools.prefix(tools)) }
            return copy
        }
        if let previous = state.previous[request.lane], previous.dropped {
            line["first_difference"] = NSNull()
            line["comparison"] = "unavailable: previous request beyond the retained bound"
        } else if let previous = state.previous[request.lane] {
            var current = previous.hashed ? hashedAll(parsed) : parsed
            current = limited(current, items: previous.itemLimit, tools: previous.toolLimit)
            let partial = (previous.itemLimit.map { parsed.items.count > $0 } ?? false) || (previous.toolLimit.map { parsed.tools.count > $0 } ?? false)
            if let first = differences(previous: previous.parsed, current: current).first {
                var diff: [String: Any] = ["component": first.component.rawValue, "position": first.position, "kind": first.kind]
                if previous.hashed && first.component != .tools && first.component != .settings { diff["byte_offset"] = "unavailable" }
                else { diff["byte_offset"] = first.byteOffset.map { $0 as Any } ?? NSNull() }
                line["first_difference"] = diff
            } else {
                line["first_difference"] = NSNull()
            }
            if partial { line["comparison"] = "partial: beyond the retained bound" }
        }
        // Keep this request within the per-stream bound, every component
        // counted (implementation review R2).
        let bound = maxRetainedBytesPerLane
        var kept = Retained(parsed: parsed, hashed: false, itemLimit: nil, toolLimit: nil)
        if retainedBytes(parsed) > bound {
            kept = Retained(parsed: hashedAll(parsed), hashed: true, itemLimit: nil, toolLimit: nil)
            if kept.bytes > bound {
                let fixed = kept.parsed.system.count + kept.parsed.settings.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
                let toolRoom = max(0, (bound - fixed) / 2 / 32)
                let toolLimit = min(kept.parsed.tools.count, toolRoom)
                let itemRoom = max(0, (bound - fixed - toolLimit * 32) / 32)
                kept.toolLimit = toolLimit
                kept.itemLimit = min(kept.parsed.items.count, itemRoom)
                kept.parsed = limited(kept.parsed, items: kept.itemLimit, tools: kept.toolLimit)
                if kept.bytes > bound {   // system/settings alone exceed the bound
                    kept.parsed.settings = [:]; kept.parsed.system = Data(); kept.toolLimit = 0; kept.itemLimit = 0
                    kept.parsed.tools = []; kept.parsed.items = []; kept.dropped = true
                }
            }
        }
        state.previous[request.lane] = kept
        touchLocked(request.lane)
        // Bounded line: hash lists are cut to fit `maxLineBytes` with an
        // explicit omitted count; the request itself is never touched.
        let lineCap = maxLineBytes
        func encoded(items: Int, tools: Int) throws -> Data {
            var copy = line
            copy["item_hashes"] = Array(itemHashes.prefix(items))
            copy["tool_hashes"] = Array(toolHashes.prefix(tools))
            if items < itemHashes.count { copy["item_hashes_omitted"] = itemHashes.count - items }
            if tools < toolHashes.count { copy["tool_hashes_omitted"] = toolHashes.count - tools }
            var data = try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])
            data.append(0x0A)
            return data
        }
        var itemCount = itemHashes.count, toolCount = toolHashes.count
        var data = try encoded(items: itemCount, tools: toolCount)
        while data.count > lineCap && (itemCount > 0 || toolCount > 0) {
            if itemCount > 0 { itemCount /= 2 } else { toolCount /= 2 }
            data = try encoded(items: itemCount, tools: toolCount)
        }
        guard data.count <= lineCap else { return }   // even the fixed fields do not fit: skip the line
        try append(data)
    }

    /// One log line never exceeds this, so the current log never exceeds
    /// the rotation limit.
    static var maxLineBytes: Int { min(64 * 1024, max(1024, (maxLogBytesForTesting ?? maxLogBytes) / 2)) }

    private static func append(_ data: Data) throws {
        let url = logURL
        try PrivateStorage.ensureDirectory(url.deletingLastPathComponent())
        let limit = maxLogBytesForTesting ?? maxLogBytes
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size + data.count > limit, size > 0 {
            let rotated = url.deletingLastPathComponent().appendingPathComponent("cache-diagnostics.log.1")
            try? FileManager.default.removeItem(at: rotated)
            try FileManager.default.moveItem(at: url, to: rotated)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try PrivateStorage.writeAtomically(data, to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
