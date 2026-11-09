import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// GPT-only evidence a delivered result earned (GPT_APPLY_PATCH_PLAN §7).
/// Published by the run that owns the result once the result is committed to
/// its history; a receipt is published only while its path still holds the
/// observed version (an intervening replacement leaves no record, and an
/// older record is never refreshed from an unseen version, §21 note 3).
struct GPTEvidenceSettlement {
    var receipts: [GPTEvidence.Receipt] = []
    var forget: [String] = []

    var isEmpty: Bool { receipts.isEmpty && forget.isEmpty }

    /// Stops at the first operation the tracker refuses because the owning
    /// task was cancelled (admission is checked inside the tracker, in the
    /// same actor step as the write).
    func publish() async {
        for key in forget {
            guard await FileTimeTracker.shared.forgetGPTIfAdmitted(key: key) else { return }
        }
        for receipt in receipts {
            guard let now = try? FileIdentity.lstatPath(receipt.key), now.sameState(as: receipt.identity) else { continue }
            guard await FileTimeTracker.shared.publishGPTIfAdmitted(receipt) else { return }
        }
    }

    /// Publishes the evidence of every result in `results` (the round just
    /// committed to a run's history).
    /// Publishes nothing once the owning task is cancelled (Codex S2 R2:
    /// a cancelled round earns no evidence, even after its last check).
    static func publish(_ results: [ToolResultMessage]) async {
        for result in results {
            guard !Task.isCancelled else { return }
            if let evidence = result.gptEvidence { await evidence.publish() }
        }
    }
}

/// `/stop` settlement for a GPT patch (§12.2, Codex S2 R2/R4): once the
/// first mutation can happen, the transaction runs to commit or rollback in
/// a worker cancellation does not reach. Its real result is kept here, keyed
/// by the owning run or lane (`scope`) and the call id, until the owner's
/// history and notices have consumed it; a cancelled owner joins the worker
/// and records that result instead of a synthetic one.
final class GPTPatchSettlement: @unchecked Sendable {
    static let shared = GPTPatchSettlement()

    struct Settled: Equatable {
        let text: String
        let outcome: CodexPatch.EditOutcome
    }

    /// Completed scopes kept for late consumers (a stopped run's completion
    /// notice); entries of a scope with a running call are never dropped.
    static let retainedScopes = 16

    private let lock = NSLock()
    private var running: [String: Set<String>] = [:]
    private var settled: [String: [String: Settled]] = [:]
    /// Consumers that still need a scope's results (the running owner, a
    /// `/stop` reply in its grace wait, a pending completion notice). A
    /// pinned scope is never evicted (Codex S2 round 2).
    private var pins: [String: Int] = [:]
    private var scopeOrder: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private static func key(_ scope: String, _ callID: String) -> String { scope + "\u{1}" + callID }

    func begin(scope: String, callID: String) {
        lock.lock()
        running[scope, default: []].insert(callID)
        settled[scope]?.removeValue(forKey: callID)
        touch(scope)
        lock.unlock()
    }

    func finish(scope: String, callID: String, _ result: Settled) {
        lock.lock()
        running[scope]?.remove(callID)
        if running[scope]?.isEmpty == true { running.removeValue(forKey: scope) }
        settled[scope, default: [:]][callID] = result
        touch(scope)
        evict()
        let resume = waiters.removeValue(forKey: Self.key(scope, callID)) ?? []
        lock.unlock()
        resume.forEach { $0.resume() }
    }

    private func touch(_ scope: String) {
        scopeOrder.removeAll { $0 == scope }
        scopeOrder.append(scope)
    }

    /// Only released scopes (no consumer pin, no running worker) are
    /// bounded; an outcome still owed is never dropped.
    private func evict() {
        while scopeOrder.count > Self.retainedScopes,
              let index = scopeOrder.firstIndex(where: { running[$0] == nil && (pins[$0] ?? 0) == 0 }) {
            let old = scopeOrder.remove(at: index)
            settled.removeValue(forKey: old)
        }
    }

    /// A consumer starts needing `scope`'s results.
    func pin(scope: String) {
        lock.lock(); pins[scope, default: 0] += 1; touch(scope); lock.unlock()
    }

    /// A consumer is done. The last release of a scope with no running
    /// worker retires it (its results were consumed).
    func unpin(scope: String) {
        lock.lock()
        let left = max(0, (pins[scope] ?? 0) - 1)
        if left == 0 { pins.removeValue(forKey: scope) } else { pins[scope] = left }
        if left == 0, running[scope] == nil {
            settled.removeValue(forKey: scope)
            scopeOrder.removeAll { $0 == scope }
        }
        lock.unlock()
    }

    /// Owner exit without a pin of its own (kept for callers that never pinned).
    func retire(scope: String) { unpin(scope: scope) }

    func isCommitting(scope: String, callID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return running[scope]?.contains(callID) == true
    }
    var isCommitting: Bool { lock.lock(); defer { lock.unlock() }; return !running.isEmpty }
    func outcome(scope: String, callID: String) -> CodexPatch.EditOutcome? {
        lock.lock(); defer { lock.unlock() }; return settled[scope]?[callID]?.outcome
    }
    func result(scope: String, callID: String) -> Settled? {
        lock.lock(); defer { lock.unlock() }; return settled[scope]?[callID]
    }

    /// Waits (cancellation does not interrupt it) until none of `callIDs` is
    /// still committing in `scope`, then returns the settled results.
    func settle(scope: String, callIDs: [String]) async -> [String: Settled] {
        for id in callIDs {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if running[scope]?.contains(id) == true {
                    waiters[Self.key(scope, id), default: []].append(c)
                    lock.unlock()
                } else {
                    lock.unlock()
                    c.resume()
                }
            }
        }
        lock.lock(); defer { lock.unlock() }
        var out: [String: Settled] = [:]
        for id in callIDs { if let r = settled[scope]?[id] { out[id] = r } }
        return out
    }

    /// Calls that run the GPT engine (direct, or an intercepted heredoc).
    static func isGPTPatchCall(_ call: ToolCall) -> Bool {
        (call.function.name == "apply_patch" && call.editing?.isGPT == true) || GPTShellIntercept.effectiveCall(call) != nil
    }

    /// The round to record for a batch interrupted by cancellation, a
    /// timeout or an error, or nil when it ran no GPT patch: each settled
    /// patch keeps its real result (no evidence: an interrupted batch earns
    /// none), every other call the typed "outcome unknown" placeholder.
    static func interruptedRound(_ assistant: AssistantToolCallMessage, settled: [String: Settled],
                                 placeholder: String) -> ToolInteraction? {
        guard !settled.isEmpty else { return nil }
        let at = HarnessClock.now()
        let results = assistant.toolCalls.map { call -> ToolResultMessage in
            if let s = settled[call.id] {
                var r = ToolResultMessage(toolCallId: call.id, content: MarkerNeutralizer.escape(s.text))
                r.editOutcome = s.outcome
                r.completedAt = at
                return r
            }
            var p = ToolResultMessage(toolCallId: call.id, content: placeholder)
            p.outcomeBinding = OutcomeBinding(kind: .interruptedIntent)
            p.completedAt = at
            return p
        }
        return ToolInteraction(assistantMessage: assistant, results: results)
    }

    /// One plain sentence for a `/stop` reply or completion notice.
    static func describe(_ outcome: CodexPatch.EditOutcome) -> String {
        switch outcome.status {
        case .applied: return "the file edit was applied to \(outcome.changed.count) file\(outcome.changed.count == 1 ? "" : "s")"
        case .refused: return outcome.category == .cancelled ? "the file edit was stopped before any file changed" : "the file edit was refused; nothing changed"
        case .rolledBack: return "the file edit failed and was rolled back"
        case .partial:
            let paths = (outcome.conflicts + outcome.changed).joined(separator: ", ")
            return "the file edit failed and could not restore \(paths)"
        }
    }

    static func mainScope(_ runId: UUID) -> String { "main:" + runId.uuidString }
}

extension ToolResultMessage {
    /// GPT_APPLY_PATCH_PLAN §9.1 (F5): the one failure classification for
    /// the tool stage, telemetry and the `/status` log. A result with a typed
    /// outcome is classified from it, never from its text; every other
    /// result keeps the caller's existing text check.
    func indicatesFailure(textCheck: (String) -> Bool) -> Bool {
        editOutcome.map { $0.status != .applied } ?? textCheck(content)
    }
}

/// Thread-safe flag set by the caller's cancellation handler.
final class GPTCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

extension ToolExecutor {

    // MARK: Dispatch (§3.4)

    /// The refusal for an `apply_patch` call with no editing stamp (never
    /// executed from disk; defensive, fails closed).
    static let unstampedPatchRefusal = "{\"error\": \"apply_patch could not be dispatched: this call has no editing configuration (it did not come from a model response of this run). Nothing was changed.\"}"

    /// Executes a GPT-stamped `apply_patch` (or the effective call of an
    /// intercepted heredoc) through the Codex engine.
    func executeGPTApplyPatch(_ call: ToolCall) async -> ToolResultMessage {
        let object = call.function.arguments.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        guard let input = object?["input"] as? String else {
            var result = ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"apply_patch requires 'input' (the whole patch as one string)\"}")
            result.editOutcome = .refused(.parse)
            return result
        }
        let form = call.editing?.form?.rawValue ?? "json"
        let token = StageMarkers.enter("fs.apply_patch", detail: "gpt \(form)")
        let request = CodexPatch.Request(input: input, lastWorkdir: gptLastWorkdir)
        let applied = await Self.runGPTPatchSettled(request: request, scope: gptSettlementScope, callID: call.id)
        var result = ToolResultMessage(toolCallId: call.id, content: applied.text)
        result.editOutcome = applied.outcome
        result.gptEvidence = applied.evidence
        StageMarkers.exit(token, applied.outcome.status == CodexPatch.EditOutcome.Status.applied ? StageMarkers.Outcome.ok : StageMarkers.Outcome.error)
        return result
    }

    struct GPTPatchApplied {
        var text: String
        var outcome: CodexPatch.EditOutcome
        var evidence: GPTEvidenceSettlement
    }

    /// Test seam: runs inside the commit worker after the engine returns.
    nonisolated(unsafe) static var gptPatchWorkerHookForTesting: (@Sendable () async -> Void)?

    /// §12.2: the engine checks the caller's cancellation once, at the end of
    /// preflight. The work runs in an unstructured task (a structured child
    /// would inherit cancellation) that the caller awaits; ledger, stats and
    /// LSP side effects record the actual outcome inside the same worker, so
    /// a committed patch is never relabelled after a `/stop`.
    static func runGPTPatchSettled(request: CodexPatch.Request, scope: String, callID: String) async -> GPTPatchApplied {
        let flag = GPTCancelFlag()
        var req = request
        req.isCancelled = { flag.isSet }
        let engineRequest = req
        GPTPatchSettlement.shared.begin(scope: scope, callID: callID)
        // The handler is installed before the worker exists, so a caller
        // already cancelled sets the flag before preflight can finish.
        return await withTaskCancellationHandler {
            let worker = Task<GPTPatchApplied, Never> {
                let result = await CodexPatch.apply(engineRequest)
                if let hook = gptPatchWorkerHookForTesting { await hook() }
                let applied = await recordGPTPatchSideEffects(result, diagnostics: !flag.isSet)
                GPTPatchSettlement.shared.finish(scope: scope, callID: callID, .init(text: applied.text, outcome: applied.outcome))
                return applied
            }
            return await worker.value
        } onCancel: {
            flag.set()
        }
    }

    /// FilesLedger, EditToolStats and LSP from the typed outcome (§6.5 step
    /// 7, §9.1); never from the text.
    /// `diagnostics`: false once the caller was stopped — the outcome is
    /// still recorded, but a stopped run is not held by a language server.
    static func recordGPTPatchSideEffects(_ result: CodexPatch.Result, diagnostics: Bool = true) async -> GPTPatchApplied {
        var text = result.text
        let outcome = result.outcome
        if outcome.status == .applied {
            let added = Set(result.addedPaths)
            for path in result.removedPaths { await FilesLedger.shared.remove(path: path) }
            for (path, _) in result.writtenFiles where !EditProtections.isSecretStore(path) {
                await FilesLedger.shared.record(path: path, origin: added.contains(path) ? .generated : .edited, description: nil)
            }
        }
        EditToolStats.log(tool: "apply_patch_gpt", success: outcome.status == .applied)
        EditToolStats.log(tool: "apply_patch_gpt." + (outcome.status == .applied ? "applied" : (outcome.category?.rawValue ?? outcome.status.rawValue)), success: outcome.status == .applied)
        if diagnostics, outcome.status == .applied, !result.writtenFiles.isEmpty {
            let files = result.writtenFiles.filter { !EditProtections.isSecretStore($0.path) }
            if let diagnostics = await gptDiagnosticsText(files) { text += "\n" + diagnostics }
        }
        let evidence = GPTEvidenceSettlement(receipts: result.evidence, forget: result.forget)
        return GPTPatchApplied(text: text, outcome: outcome, evidence: evidence)
    }

    /// `Diagnostics:` with LSP errors only, ≤ 20 lines per file, ≤ 5 files (§6.6).
    static func gptDiagnosticsText(_ files: [(path: String, text: String)]) async -> String? {
        guard !files.isEmpty else { return nil }
        var batch: [String: Any] = [:]
        await LSPDiagnosticsReporter.attachBatch(to: &batch, files: files)
        guard let byFile = batch["diagnostics_by_file"] as? [String: Any] else { return nil }
        var lines: [String] = []
        var filesShown = 0
        for file in files {
            guard filesShown < 5, let entry = byFile[file.path] as? [String: Any],
                  let diagnostics = entry["diagnostics"] as? [[String: Any]] else { continue }
            let errors = diagnostics.filter { ($0["severity"] as? String) == "error" }
            guard !errors.isEmpty else { continue }
            filesShown += 1
            lines.append(file.path + ":")
            for d in errors.prefix(20) {
                lines.append("  \(d["line"] ?? "?"):\(d["column"] ?? "?") \(d["message"] ?? "")")
            }
            if errors.count > 20 { lines.append("  … \(errors.count - 20) more") }
            if let note = entry["diagnostics_note"] as? String { lines.append("  note: \(note)") }
        }
        return lines.isEmpty ? nil : (["Diagnostics:"] + lines).joined(separator: "\n")
    }

    // MARK: read_file receipt (§7 R3-1, §21 note 1, Codex S2 R1)

    /// The receipt for a completed GPT `read_file`, or nil. The text bytes
    /// came from the observation's own descriptor; its identity before and
    /// after the read must agree, the path must resolve to the same key
    /// before the open and after the read, that key's current identity must
    /// be the descriptor's, and the result must have delivered ≥ 1 line.
    static func gptReadReceipt(_ observation: GPTReadObservation, path rawPath: String, resultContent: String) -> GPTEvidence.Receipt? {
        guard let observed = observation.observed, observed.before.sameState(as: observed.after) else { return nil }
        let path = FilesystemTools.normalizePath(rawPath)
        guard CodexPatch.evidenceKey(path) == observation.keyBefore,
              let current = (try? FileIdentity.lstatPath(observation.keyBefore)) ?? nil,
              current.sameState(as: observed.before) else { return nil }
        guard let data = resultContent.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["success"] as? Bool == true,
              let returned = object["returned_lines"] as? Int, returned >= 1 else { return nil }
        return GPTEvidence.Receipt(key: observation.keyBefore, identity: observed.before, source: .gptReadFile)
    }
}

/// One GPT `read_file` observation (§7, Codex S2 R1): the requested path's
/// resolution captured before the open; the bytes the result is built from
/// read through one descriptor, with that descriptor's identity taken before
/// and after the read. Images and PDFs never use it (no GPT record in v1).
final class GPTReadObservation: @unchecked Sendable {
    struct Observed { let before: FileIdentity; let after: FileIdentity }
    let keyBefore: String
    private let lock = NSLock()
    private var _observed: Observed?
    var observed: Observed? { lock.lock(); defer { lock.unlock() }; return _observed }
    /// Test seam: runs between the open and the read.
    nonisolated(unsafe) static var afterOpenHookForTesting: ((String) -> Void)?

    init(path rawPath: String) {
        keyBefore = CodexPatch.evidenceKey(FilesystemTools.normalizePath(rawPath))
    }

    /// The file's bytes, from one descriptor (what `Data(contentsOf:)`
    /// returned before; errors are thrown the same way to the caller).
    func readAll(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        defer { close(fd) }
        let before = try FileIdentity.fstatFD(fd)
        Self.afterOpenHookForTesting?(path)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path]) }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        let after = try FileIdentity.fstatFD(fd)
        lock.lock(); _observed = Observed(before: before, after: after); lock.unlock()
        return data
    }
}

// MARK: - Shell reads (§7, narrow v1)

enum GPTShellRead {
    /// Splits a command into words: plain words, or one single- or
    /// double-quoted word without expansions. nil on anything else.
    static func words(_ stage: String) -> [String]? {
        var out: [String] = []
        var i = stage.unicodeScalars.startIndex
        let s = stage.unicodeScalars
        while i < s.endIndex {
            let c = s[i]
            if c == " " || c == "\t" { i = s.index(after: i); continue }
            if c == "'" || c == "\"" {
                let quote = c
                var j = s.index(after: i)
                var word = String.UnicodeScalarView()
                while j < s.endIndex, s[j] != quote {
                    if quote == "\"" && (s[j] == "$" || s[j] == "`" || s[j] == "\\") { return nil }
                    word.append(s[j]); j = s.index(after: j)
                }
                guard j < s.endIndex else { return nil }
                out.append(String(word))
                i = s.index(after: j)
                if i < s.endIndex, s[i] != " " && s[i] != "\t" { return nil }
                continue
            }
            var word = String.UnicodeScalarView()
            while i < s.endIndex, s[i] != " ", s[i] != "\t" {
                if "'\"\\$`;&|<>(){}*?[]~!#".unicodeScalars.contains(s[i]) { return nil }
                word.append(s[i]); i = s.index(after: i)
            }
            out.append(String(word))
        }
        return out
    }

    static func isSedPrint(_ script: String) -> Bool {
        let parts = script.dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard script.hasSuffix("p"), (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && Int($0).map { $0 >= 1 } == true }
    }

    static func positiveInt(_ s: String) -> Bool { Int(s).map { $0 >= 1 } == true && s.allSatisfy { $0.isASCII && $0.isNumber } }

    /// The single file operand of a recognised reader stage, or nil.
    static func readerOperand(_ w: [String]) -> String? {
        guard let tool = w.first else { return nil }
        var i = 1
        var operands: [String] = []
        var endOfOptions = false
        switch tool {
        case "cat":
            while i < w.count {
                let a = w[i]; i += 1
                if !endOfOptions && a == "--" { endOfOptions = true; continue }
                if !endOfOptions && a == "-n" { continue }
                if !endOfOptions && a.hasPrefix("-") { return nil }
                operands.append(a)
            }
        case "nl":
            while i < w.count {
                let a = w[i]; i += 1
                if !endOfOptions && a == "--" { endOfOptions = true; continue }
                if !endOfOptions && a == "-ba" { continue }
                if !endOfOptions && a.hasPrefix("-") { return nil }
                operands.append(a)
            }
        case "head", "tail":
            while i < w.count {
                let a = w[i]; i += 1
                if !endOfOptions && a == "--" { endOfOptions = true; continue }
                if !endOfOptions && a == "-n" {
                    guard i < w.count, positiveInt(w[i]) else { return nil }
                    i += 1; continue
                }
                if !endOfOptions && a.hasPrefix("-") {
                    guard positiveInt(String(a.dropFirst())) else { return nil }
                    continue
                }
                operands.append(a)
            }
        case "sed":
            guard w.count == 4, w[1] == "-n", isSedPrint(w[2]) else { return nil }
            operands = [w[3]]
        default:
            return nil
        }
        return operands.count == 1 ? operands[0] : nil
    }

    static func isFilterStage(_ w: [String]) -> Bool {
        (w.count == 3 && w[0] == "head" && w[1] == "-n" && positiveInt(w[2]))
            || w == ["nl", "-ba"]
            || (w.count == 3 && w[0] == "sed" && w[1] == "-n" && isSedPrint(w[2]))
    }

    /// The absolute path a recognised v1 single-file shell read reads, or
    /// nil. Recognition only; crediting has further conditions (§7).
    static func target(command: String, workdir: String?) -> String? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !cmd.contains("\n"), !cmd.contains("\r") else { return nil }
        // Pipes split stages; no `||` (rejected by `words` anyway).
        let stages = cmd.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let first = stages.first, let firstWords = words(first) else { return nil }
        guard let operand = readerOperand(firstWords) else { return nil }
        for stage in stages.dropFirst() {
            guard let w = words(stage), isFilterStage(w) else { return nil }
        }
        let path: String
        if operand.hasPrefix("/") {
            path = operand
        } else {
            guard let wd = workdir.map(FilesystemTools.normalizePath), wd.hasPrefix("/") else { return nil }
            path = URL(fileURLWithPath: wd).appendingPathComponent(operand).standardizedFileURL.path
        }
        guard let id = (try? FileIdentity.lstatPath(path)) ?? nil, id.kind == .regular else { return nil }
        return path
    }

    /// Whether the command is plain `cat FILE` (the empty-file case).
    static func isPlainCat(_ command: String) -> Bool {
        guard let w = words(command.trimmingCharacters(in: .whitespacesAndNewlines)), w.count == 2 else { return false }
        return w[0] == "cat"
    }

    /// The receipt for a completed recognised read, or nil (§7): exit 0 and
    /// status `exited` (a command still running or moved to the background
    /// has neither), non-empty delivered stdout (or an empty file read whole
    /// with plain `cat`), identity unchanged around the command.
    static func receipt(path: String, before: FileIdentity, command: String, resultContent: String) -> GPTEvidence.Receipt? {
        guard let data = resultContent.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["exit_code"] as? Int == 0, object["status"] as? String == "exited" else { return nil }
        let stdout = object["stdout"] as? String ?? ""
        guard !stdout.isEmpty || (before.size == 0 && isPlainCat(command)) else { return nil }
        guard let after = (try? FileIdentity.lstatPath(path)) ?? nil, after.sameState(as: before) else { return nil }
        return GPTEvidence.Receipt(key: CodexPatch.evidenceKey(path), identity: after, source: .shellRead)
    }
}

// MARK: - Heredoc interception (§8)

enum GPTShellIntercept {
    /// The patch body of a command that is exactly an `apply_patch`
    /// heredoc (optionally after `cd <abs> && `), or nil.
    static func patchBody(command: String) -> (body: String, cdPath: String?)? {
        var s = Substring(command.trimmingCharacters(in: .whitespacesAndNewlines))
        var cdPath: String? = nil
        if s.hasPrefix("cd ") {
            s = s.dropFirst(3).drop(while: { $0 == " " })
            guard let (path, rest) = parsePathWord(s), path.hasPrefix("/") else { return nil }
            var r = rest.drop(while: { $0 == " " })
            guard r.hasPrefix("&&") else { return nil }
            r = r.dropFirst(2).drop(while: { $0 == " " })
            s = r
            cdPath = path
        }
        let name: String
        if s.hasPrefix("apply_patch") { name = "apply_patch" }
        else if s.hasPrefix("applypatch") { name = "applypatch" }
        else { return nil }
        s = s.dropFirst(name.count).drop(while: { $0 == " " })
        guard s.hasPrefix("<<"), !s.hasPrefix("<<<"), !s.hasPrefix("<<-") else { return nil }
        s = s.dropFirst(2).drop(while: { $0 == " " })
        var quoted = false
        var word = ""
        if let q = s.first, q == "'" || q == "\"" {
            s = s.dropFirst()
            guard let end = s.firstIndex(of: q) else { return nil }
            word = String(s[..<end]); s = s[s.index(after: end)...]
            quoted = true
        } else {
            let w = s.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            word = String(w); s = s.dropFirst(w.count)
        }
        guard let firstScalar = word.unicodeScalars.first,
              (firstScalar.properties.isAlphabetic && firstScalar.isASCII) || firstScalar == "_",
              word.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_") })
        else { return nil }
        s = s.drop(while: { $0 == " " || $0 == "\t" })
        // Then a newline (LF or CRLF; Swift treats "\r\n" as one Character).
        guard let nl = s.first, nl == "\n" || nl == "\r\n" else { return nil }
        s = s.dropFirst()
        // UTF-16 splitting: a CRLF ending is one Swift Character, so
        // Character-level splitting would never see the "\n" in it.
        let lines = String(s).components(separatedBy: "\n")
        var body: [String] = []
        var found = false
        var index = 0
        while index < lines.count {
            var line = lines[index]
            if line.hasSuffix("\r") { line.removeLast() }
            if line == word { found = true; break }
            body.append(lines[index]); index += 1
        }
        guard found else { return nil }
        let after = lines[(index + 1)...].joined(separator: "\n")
        guard after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bodyText = body.joined(separator: "\n")
        if !quoted, bodyText.contains("$") || bodyText.contains("`") || bodyText.contains("\\") { return nil }
        return (bodyText + "\n", cdPath)
    }

    /// One absolute path word: unquoted (no metacharacters) or single /
    /// double quoted without expansions.
    static func parsePathWord(_ s: Substring) -> (String, Substring)? {
        guard let first = s.first else { return nil }
        if first == "'" || first == "\"" {
            let rest = s.dropFirst()
            guard let end = rest.firstIndex(of: first) else { return nil }
            let path = String(rest[..<end])
            if first == "\"" && (path.contains("$") || path.contains("`") || path.contains("\\")) { return nil }
            return (path, rest[rest.index(after: end)...])
        }
        let word = s.prefix { $0 != " " }
        guard !word.contains(where: { "'\"\\$`;&|<>(){}*?[]~!#".contains($0) }) else { return nil }
        return (String(word), s.dropFirst(word.count))
    }

    /// The effective call (§8): `apply_patch {"input": body}` with the
    /// original id, routing and editing stamp, or nil.
    static func effectiveCall(_ call: ToolCall) -> ToolCall? {
        guard call.function.name == "bash", call.editing?.isGPT == true,
              let data = call.function.arguments.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = object["command"] as? String,
              let parsed = patchBody(command: command) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let args = try? encoder.encode(["input": parsed.body]) else { return nil }
        var effective = ToolCall(id: call.id, type: call.type, function: FunctionCall(name: "apply_patch", arguments: String(decoding: args, as: UTF8.self)))
        effective.routing = call.routing
        effective.editing = call.editing
        return effective
    }

    static let notAShellCommandNote = "note: apply_patch is a tool, not a shell command; call the apply_patch tool directly"
}

extension ToolExecutor {
    static func bashCommand(_ call: ToolCall) -> String? {
        guard let data = call.function.arguments.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["command"] as? String
    }

    /// A GPT-stamped bash call (not an intercepted heredoc): records the
    /// absolute workdir for the D2 hint, credits a recognised single-file
    /// read (§7), and adds the 127 note for `apply_patch` used as a command.
    func executeGPTBash(_ call: ToolCall) async -> ToolResultMessage {
        let object = (call.function.arguments.data(using: .utf8)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let command = object["command"] as? String ?? ""
        let workdir = object["workdir"] as? String
        if let wd = workdir.map(FilesystemTools.normalizePath), wd.hasPrefix("/") { gptLastWorkdir = wd }
        let target = GPTShellRead.target(command: command, workdir: workdir)
        let before = target.flatMap { (try? FileIdentity.lstatPath($0)) ?? nil }
        var result = await executeBash(call)
        if let target, let before,
           let receipt = GPTShellRead.receipt(path: target, before: before, command: command, resultContent: result.content) {
            result.gptEvidence = GPTEvidenceSettlement(receipts: [receipt])
        }
        if let data = result.content.data(using: .utf8),
           let out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           out["exit_code"] as? Int == 127, (out["stderr"] as? String ?? "").contains("apply_patch") {
            result.content += "\n" + GPTShellIntercept.notAShellCommandNote
        }
        return result
    }
}

extension String {
    /// First letter uppercased (notice sentences).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
