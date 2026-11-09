import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The GPT `apply_patch` engine (GPT_APPLY_PATCH_PLAN §6): parse (Codex
/// port), preflight every operation before any mutation, then a journaled
/// transaction with per-operation revalidation and conflict-aware rollback.
/// Not exposed to any model until stage S2 wires it in.
extension CodexPatch {

    struct Limits {
        var maxInputBytes = 1 << 20
        var maxOperations = 100
        var maxChunks = 10_000
        var maxImageBytes = 16 << 20
        var maxTotalBytes = 64 << 20
        static let standard = Limits()
    }

    struct Request {
        var input: String
        /// Last absolute `workdir` the model used this run (D2 hint).
        var lastWorkdir: String? = nil
        /// Checked once, at the end of preflight, before the first mutation.
        var isCancelled: @Sendable () -> Bool = { false }
        var limits: Limits = .standard
        init(input: String, lastWorkdir: String? = nil, isCancelled: @escaping @Sendable () -> Bool = { false }, limits: Limits = .standard) {
            self.input = input
            self.lastWorkdir = lastWorkdir
            self.isCancelled = isCancelled
            self.limits = limits
        }
    }

    // MARK: - Planned operations

    struct PlannedWrite {
        var display: String
        /// Where the bytes go (the resolved target for an Update through a link).
        var target: String
        var inScope: Bool
        var pre: CodexPatchTransaction.PreImage?
        var data: Data
        var finalMode: mode_t?
        var fuzz: FuzzLevel = .exact
        /// For an Update through a symlink: the link and the target it
        /// resolved to at preflight; a retargeted link is a conflict.
        var linkGuard: CodexPatchTransaction.LinkGuard? = nil
    }

    struct PlannedRemove {
        var display: String
        var target: String
        var pre: CodexPatchTransaction.PreImage
    }

    enum PlannedOp {
        case add(PlannedWrite)
        case update(PlannedWrite)
        case move(PlannedWrite, PlannedRemove)
        case delete(PlannedRemove)
        case secretStore(display: String, preText: String, postText: String)
    }

    struct Refusal: Error {
        let category: Category
        let text: String
    }

    // MARK: - Entry point

    static func apply(_ request: Request) async -> Result {
        let parseToken = StageMarkers.enter("fs.patch_parse")
        guard request.input.utf8.count <= request.limits.maxInputBytes else {
            StageMarkers.exit(parseToken, .error)
            return refused(.parse, verificationFailure("the patch is \(request.input.utf8.count) bytes; apply_patch accepts up to 1 MiB per call — split it into several patches"))
        }
        let args: Args
        do {
            args = try parsePatch(request.input)
            StageMarkers.exit(parseToken, .ok)
        } catch let e as ParseError {
            StageMarkers.exit(parseToken, .error)
            return refused(.parse, verificationFailure(e.description))
        } catch {
            StageMarkers.exit(parseToken, .error)
            return refused(.parse, verificationFailure("\(error)"))
        }
        if args.environmentID != nil {
            return refused(.parse, verificationFailure("*** Environment ID is not supported in Briglia (there is one environment); remove that line"))
        }
        if args.hunks.isEmpty {
            return refused(.parse, verificationFailure("No files were modified."))
        }
        if args.hunks.count > request.limits.maxOperations {
            return refused(.parse, verificationFailure("the patch has \(args.hunks.count) file operations; the limit is \(request.limits.maxOperations) per call"))
        }
        let chunkCount = args.hunks.reduce(0) { $0 + $1.chunks.count }
        if chunkCount > request.limits.maxChunks {
            return refused(.parse, verificationFailure("the patch has \(chunkCount) hunks; the limit is \(request.limits.maxChunks) per call"))
        }

        let preflightToken = StageMarkers.enter("fs.patch_preflight", detail: "files=\(args.hunks.count)")
        let ops: [PlannedOp]
        do {
            ops = try await preflight(args.hunks, request: request)
            StageMarkers.exit(preflightToken, .ok)
        } catch let r as Refusal {
            StageMarkers.exit(preflightToken, .error)
            return refused(r.category, r.text)
        } catch {
            StageMarkers.exit(preflightToken, .error)
            return refused(.io, verificationFailure("\(error)"))
        }
        // Plan §12.2: the only cancellation point, before any mutation.
        if request.isCancelled() {
            return refused(.cancelled, "apply_patch was cancelled before any file was changed.")
        }
        return await commit(ops, hunks: args.hunks)
    }

    static func refused(_ category: Category, _ text: String) -> Result {
        Result(text: text, outcome: .refused(category))
    }

    // MARK: - Paths

    /// Trimmed, `~` expanded (the same normalisation the claims use).
    static func normalizePath(_ raw: String) -> String { FilesystemTools.normalizePath(raw) }

    struct ResolvedPath {
        let display: String
        /// Parents resolved, leaf as named.
        let leaf: String
        let leafID: FileIdentity?
        /// Identity key: the resolved target for a link, else the leaf.
        let key: String
        let resolvedTarget: String?
        let resolvedID: FileIdentity?
    }

    static func resolve(_ raw: String, request: Request) throws -> ResolvedPath {
        let display = normalizePath(raw)
        // Foundation would percent-encode a NUL into the name: refuse it.
        if display.unicodeScalars.contains("\u{0}") {
            throw Refusal(category: .path, text: verificationFailure("a path contains a NUL character; paths must be plain text"))
        }
        guard display.hasPrefix("/") else {
            var hint = ""
            if let wd = request.lastWorkdir, wd.hasPrefix("/") {
                let joined = URL(fileURLWithPath: wd).appendingPathComponent(display).standardizedFileURL.path
                hint = " Your last workdir in this run was \(wd); did you mean \(joined)?"
            }
            throw Refusal(category: .path, text: verificationFailure("\(display.isEmpty ? "(empty path)" : display) is not an absolute path. Paths in apply_patch must be absolute (for example /Users/…/repo/src/x.py); Briglia has no working directory.\(hint)"))
        }
        let standardized = URL(fileURLWithPath: display).standardizedFileURL.path
        let leaf = PrivateStorage.canonical(standardized)
        let leafID: FileIdentity?
        do { leafID = try FileIdentity.lstatPath(leaf) } catch {
            throw Refusal(category: .io, text: verificationFailure("cannot inspect \(display): \(error)"))
        }
        var key = leaf
        var resolvedTarget: String? = nil
        var resolvedID: FileIdentity? = nil
        if leafID?.kind == .symlink {
            if let chain = try? PrivateStorage.resolveChain(leaf) {
                let target = PrivateStorage.canonical(chain)
                resolvedTarget = target
                resolvedID = try? FileIdentity.lstatPath(target)
                key = target
            }
        }
        return ResolvedPath(display: display, leaf: leaf, leafID: leafID, key: key, resolvedTarget: resolvedTarget, resolvedID: resolvedID)
    }

    /// The GPT evidence key of a path: canonical, with a link at the leaf
    /// resolved to its target (what an Update through it would write).
    static func evidenceKey(_ path: String) -> String {
        let leaf = PrivateStorage.canonical(URL(fileURLWithPath: normalizePath(path)).standardizedFileURL.path)
        if (try? FileIdentity.lstatPath(leaf))??.kind == .symlink, let chain = try? PrivateStorage.resolveChain(leaf) {
            return PrivateStorage.canonical(chain)
        }
        return leaf
    }

    static func symlinkRefusal(_ display: String) -> Refusal {
        Refusal(category: .path, text: verificationFailure("\(display) is a symbolic link; use bash for this operation"))
    }

    /// Whether a write to `leaf` follows the private-storage policy (the
    /// standard tools' rule, `PrivateStorage.fileToolPathIsInScope`).
    static func writeScope(_ r: ResolvedPath) -> Bool { PrivateStorage.fileToolPathIsInScope(r.leaf) }

    // MARK: - Preflight

    static func preflight(_ hunks: [Hunk], request: Request) async throws -> [PlannedOp] {
        var seen: [String: String] = [:]
        var ops: [PlannedOp] = []
        var totalBytes = 0
        let limits = request.limits

        func claimKey(_ r: ResolvedPath) throws {
            if seen[r.key] != nil {
                throw Refusal(category: .parse, text: verificationFailure(ParseError.invalidPatch("multiple operations target \(r.display)").description))
            }
            seen[r.key] = r.display
        }
        func account(_ n: Int, _ display: String) throws {
            if n > limits.maxImageBytes {
                throw Refusal(category: .io, text: verificationFailure("\(display) would be \(n) bytes; apply_patch handles files up to \(limits.maxImageBytes / (1 << 20)) MiB"))
            }
            totalBytes += n
            if totalBytes > limits.maxTotalBytes {
                throw Refusal(category: .io, text: verificationFailure("this patch reads and writes more than \(limits.maxTotalBytes / (1 << 20)) MiB in total; split it into several patches"))
            }
        }
        func readPre(_ path: String, _ display: String) throws -> CodexPatchTransaction.PreImage {
            do {
                let observed = try CodexPatchFS.readObserved(path, limit: limits.maxImageBytes)
                try account(observed.data.count, display)
                return CodexPatchTransaction.PreImage(data: observed.data, identity: observed.identity, hash: CodexPatchFS.sha256(observed.data))
            } catch let r as Refusal { throw r
            } catch let e as CodexPatchFS.SizeLimit {
                throw Refusal(category: .io, text: verificationFailure(e.description))
            } catch {
                throw Refusal(category: .io, text: verificationFailure("cannot read \(display): \(error)"))
            }
        }
        func requireFresh(_ r: ResolvedPath, id: FileIdentity, message: String) async throws {
            if case .fresh = await GPTEvidence.freshness(key: r.key, current: id) { return }
            throw Refusal(category: .knowledge, text: verificationFailure(message))
        }
        func protectedCheck(_ displays: [String]) throws {
            if let refusal = EditProtections.siwcRefusal(displays) {
                throw Refusal(category: .protected, text: verificationFailure(refusal))
            }
        }
        /// The harness-state symlink rules of `PrivateStorage.writeAtomically`.
        func harnessLinkCheck(_ r: ResolvedPath) throws {
            guard r.leafID?.kind == .symlink, writeScope(r) else { return }
            if PrivateStorage.classify(r.leaf) == .harnessState || r.resolvedTarget.map({ PrivateStorage.classify($0) == .harnessState }) == true {
                throw Refusal(category: .protected, text: verificationFailure("refusing to write \(r.display): it is a symlink involving harness-owned state; a link at this path is not expected — run `briglia doctor`"))
            }
        }
        func newFileMode(_ r: ResolvedPath) -> mode_t? { writeScope(r) ? 0o600 : nil }
        func existingMode(_ r: ResolvedPath, targetIsInScope: Bool, _ mode: mode_t) -> mode_t {
            targetIsInScope ? (mode & ~PrivateStorage.groupOtherBits) : mode
        }

        for hunk in hunks {
            switch hunk.kind {
            case .add:
                let r = try resolve(hunk.path, request: request)
                try claimKey(r)
                try protectedCheck([r.display])
                if EditProtections.isSecretStore(r.display) {
                    throw Refusal(category: .protected, text: verificationFailure(HarnessSecretStore.wholeFileRewriteRefusal))
                }
                let data = Data(hunk.contents.utf8)
                try account(data.count, r.display)
                var write = PlannedWrite(display: r.display, target: r.leaf, inScope: writeScope(r), pre: nil, data: data, finalMode: newFileMode(r))
                switch r.leafID?.kind {
                case nil: break
                case .regular?:
                    // D3: Add over an existing file only when fresh — checked
                    // against the identity of the pre-image actually read.
                    let pre = try readPre(r.leaf, r.display)
                    try await requireFresh(r, id: pre.identity, message: "\(r.display) already exists — read it first, or use *** Update File")
                    write.pre = pre
                    write.finalMode = existingMode(r, targetIsInScope: write.inScope, pre.identity.mode)
                case .symlink?: throw symlinkRefusal(r.display)
                case .directory?: throw Refusal(category: .path, text: verificationFailure("\(r.display) is a directory"))
                case .other?: throw Refusal(category: .path, text: verificationFailure("\(r.display) is not a regular file"))
                }
                ops.append(.add(write))

            case .delete:
                let r = try resolve(hunk.path, request: request)
                try claimKey(r)
                try protectedCheck([r.display])
                if EditProtections.isSecretStore(r.display) {
                    throw Refusal(category: .protected, text: verificationFailure(HarnessSecretStore.deleteOrMoveRefusal))
                }
                switch r.leafID?.kind {
                case nil: throw Refusal(category: .path, text: verificationFailure("Failed to read \(r.display): \(CodexPatchFS.rustOSError(ENOENT))"))
                case .directory?: throw Refusal(category: .path, text: verificationFailure("Failed to read \(r.display): \(CodexPatchFS.rustOSError(EISDIR))"))
                case .symlink?: throw symlinkRefusal(r.display)
                case .other?: throw Refusal(category: .path, text: verificationFailure("\(r.display) is not a regular file"))
                case .regular?: break
                }
                let pre = try readPre(r.leaf, r.display)
                try await requireFresh(r, id: pre.identity, message: "read \(r.display) before deleting it")
                ops.append(.delete(PlannedRemove(display: r.display, target: r.leaf, pre: pre)))

            case .update:
                let r = try resolve(hunk.path, request: request)
                try claimKey(r)
                var destination: ResolvedPath? = nil
                if let move = hunk.movePath {
                    let d = try resolve(move, request: request)
                    try claimKey(d)
                    destination = d
                }
                try protectedCheck([r.display] + (destination.map { [$0.display] } ?? []) + (r.resolvedTarget.map { [$0] } ?? []))
                let isStore = EditProtections.isSecretStore(r.display)
                if isStore {
                    if destination != nil { throw Refusal(category: .protected, text: verificationFailure(HarnessSecretStore.deleteOrMoveRefusal)) }
                    if let refusal = EditProtections.secretStoreChunkRefusal(hunk.chunks) {
                        throw Refusal(category: .protected, text: verificationFailure(refusal))
                    }
                } else if let d = destination, EditProtections.isSecretStore(d.display) {
                    throw Refusal(category: .protected, text: verificationFailure(HarnessSecretStore.wholeFileRewriteRefusal))
                }
                // Source: a regular file, or a link to one (written through).
                let sourcePath: String
                switch r.leafID?.kind {
                case nil: throw Refusal(category: .path, text: verificationFailure("Failed to read file to update \(r.display): \(CodexPatchFS.rustOSError(ENOENT))"))
                case .directory?: throw Refusal(category: .path, text: verificationFailure("Failed to read file to update \(r.display): \(CodexPatchFS.rustOSError(EISDIR))"))
                case .other?: throw Refusal(category: .path, text: verificationFailure("\(r.display) is not a regular file"))
                case .symlink?:
                    guard destination == nil else { throw symlinkRefusal(r.display) }
                    guard let target = r.resolvedTarget, r.resolvedID?.kind == .regular else { throw symlinkRefusal(r.display) }
                    try harnessLinkCheck(r)
                    sourcePath = target
                case .regular?:
                    sourcePath = r.leaf
                }
                let pre = try readPre(sourcePath, r.display)
                let derived: DerivedUpdate
                do {
                    derived = try deriveNewContents(original: pre.data, path: r.display, chunks: hunk.chunks)
                } catch let e as ComputeError {
                    var text = verificationFailure(e.message)
                    if e.kind != .overlap, !isStore, let file = try? SourceFile.decode(pre.data) {
                        if let hint = nearestLinesHint(fileLines: file.lineTexts, missed: e.missedLines) { text += "\n" + hint }
                        if let escape = EditStrategies.escapeMismatchHint(source: file.text(), oldString: e.missedLines.joined(separator: "\n")) {
                            text += escape
                        }
                    }
                    if case .stale(let at) = await GPTEvidence.freshness(key: r.key, current: pre.identity) {
                        let f = DateFormatter(); f.dateFormat = "HH:mm"
                        text += "\nnote: \(r.display) changed since you last read it at \(f.string(from: at))"
                    }
                    throw Refusal(category: .context, text: text)
                } catch let e as SourceFile.DecodeError {
                    throw Refusal(category: .io, text: verificationFailure("cannot patch \(r.display): \(e.description)"))
                }
                try account(derived.newContents.count, r.display)
                if isStore {
                    let preText = String(decoding: pre.data, as: UTF8.self)
                    let postText = String(decoding: derived.newContents, as: UTF8.self)
                    if let violation = HarnessSecretStore.tokenInvariantViolation(original: preText, updated: postText) {
                        throw Refusal(category: .protected, text: verificationFailure(violation))
                    }
                    ops.append(.secretStore(display: r.display, preText: preText, postText: postText))
                    continue
                }
                let sourceScope: Bool = {
                    if r.leafID?.kind == .symlink, writeScope(r), let t = r.resolvedTarget { return PrivateStorage.classify(t) != .outside }
                    return writeScope(r)
                }()
                if let d = destination {
                    var write = PlannedWrite(display: d.display, target: d.leaf, inScope: writeScope(d), pre: nil,
                                             data: derived.newContents, finalMode: newFileMode(d), fuzz: derived.fuzz)
                    switch d.leafID?.kind {
                    case nil: break
                    case .regular?:
                        let destPre = try readPre(d.leaf, d.display)
                        try await requireFresh(d, id: destPre.identity, message: "\(d.display) already exists — read it first, or use *** Update File")
                        write.pre = destPre
                        write.finalMode = existingMode(d, targetIsInScope: write.inScope, destPre.identity.mode)
                    case .symlink?: throw symlinkRefusal(d.display)
                    case .directory?: throw Refusal(category: .path, text: verificationFailure("\(d.display) is a directory"))
                    case .other?: throw Refusal(category: .path, text: verificationFailure("\(d.display) is not a regular file"))
                    }
                    ops.append(.move(write, PlannedRemove(display: r.display, target: sourcePath, pre: pre)))
                } else {
                    var write = PlannedWrite(display: r.display, target: sourcePath, inScope: sourceScope, pre: pre,
                                             data: derived.newContents,
                                             finalMode: existingMode(r, targetIsInScope: sourceScope, pre.identity.mode),
                                             fuzz: derived.fuzz)
                    if r.leafID?.kind == .symlink, let id = r.leafID {
                        write.linkGuard = CodexPatchTransaction.LinkGuard(path: r.leaf, identity: id)
                    }
                    ops.append(.update(write))
                }
            }
        }
        return ops
    }

    // MARK: - Commit

    static func commit(_ ops: [PlannedOp], hunks: [Hunk]) async -> Result {
        let token = StageMarkers.enter("fs.patch_commit", detail: "ops=\(ops.count)")
        let journal = CodexPatchTransaction.Journal()
        // Order (§6.5 step 3): Adds, Updates, Moves, Deletes.
        func rank(_ op: PlannedOp) -> Int {
            switch op { case .add: return 0; case .update, .secretStore: return 1; case .move: return 2; case .delete: return 3 }
        }
        let ordered = ops.enumerated().sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }.map(\.element)
        var failure: CodexPatchTransaction.StepError? = nil
        do {
            for op in ordered {
                switch op {
                case .add(let w), .update(let w):
                    try write(w, journal: journal)
                case .move(let w, let r):
                    try write(w, journal: journal)
                    try CodexPatchTransaction.remove(r.target, display: r.display, pre: r.pre, journal: journal)
                case .delete(let r):
                    try CodexPatchTransaction.remove(r.target, display: r.display, pre: r.pre, journal: journal)
                case .secretStore(let display, let preText, let postText):
                    let outcome = await SettingsAgentEdit.commit(originalText: preText, updatedText: postText, label: "secrets.json patch")
                    switch outcome {
                    case .refused(let why): throw CodexPatchTransaction.StepError.conflict(why)
                    case .unchanged: break
                    case .applied: journal.record(.secretStore(display: display, preText: preText, postText: postText))
                    }
                }
            }
        } catch let e as CodexPatchTransaction.StepError {
            failure = e
        } catch {
            failure = .io("\(error)")
        }
        if let failure {
            StageMarkers.exit(token, .error)
            let rollbackToken = StageMarkers.enter("fs.patch_rollback")
            let report = await CodexPatchTransaction.rollback(journal)
            StageMarkers.exit(rollbackToken, report.conflicts.isEmpty && report.stillChanged.isEmpty ? .ok : .error)
            var outcome = EditOutcome(status: .rolledBack, changed: report.stillChanged, restored: report.restored,
                                      conflicts: report.conflicts, category: failure.kind == .conflict ? .conflict : .io)
            if !report.conflicts.isEmpty || !report.stillChanged.isEmpty { outcome.status = .partial }
            var text = transactionFailureText(reason: failure.message, outcome: outcome)
            if !report.leftoverTemps.isEmpty {
                text += "\nTemporary files that could not be removed or checked: \(report.leftoverTemps.joined(separator: ", "))"
            }
            return Result(text: text, outcome: outcome)
        }
        StageMarkers.exit(token, .ok)
        var result = successResult(ops, journal: journal)
        // Any temp a step could not remove (its receipt survived) is cleaned
        // now, or named.
        var leftover = CodexPatchTransaction.RollbackReport()
        CodexPatchTransaction.cleanTemps(journal, &leftover)
        if !leftover.leftoverTemps.isEmpty {
            result.text += "\nnote: temporary files that could not be removed or checked: \(leftover.leftoverTemps.joined(separator: ", "))"
        }
        return result
    }

    static func write(_ w: PlannedWrite, journal: CodexPatchTransaction.Journal) throws {
        try CodexPatchTransaction.ensureParent(of: w.target, inScope: w.inScope, journal: journal)
        let staged = try CodexPatchTransaction.stage(w.data, forTarget: w.target, finalMode: w.finalMode, journal: journal)
        let expected: CodexPatchTransaction.Expected = w.pre.map { .state($0.identity, hash: $0.hash) } ?? .absent
        try CodexPatchTransaction.revalidateAndReplace(staged, target: w.target, display: w.display, expected: expected, pre: w.pre,
                                                       linkGuard: w.linkGuard, journal: journal)
    }

    static func successResult(_ ops: [PlannedOp], journal: CodexPatchTransaction.Journal) -> Result {
        var added: [String] = [], modified: [String] = [], deleted: [String] = [], changed: [String] = []
        var notes: [String] = []
        var written: [(path: String, text: String)] = []
        var forget: [String] = []
        for op in ops {
            switch op {
            case .add(let w):
                added.append(w.display); changed.append(w.display)
                written.append((w.display, String(decoding: w.data, as: UTF8.self)))
            case .update(let w):
                modified.append(w.display); changed.append(w.display)
                if let n = fuzzNote(w.fuzz, path: w.display) { notes.append(n) }
                written.append((w.display, String(decoding: w.data, as: UTF8.self)))
            case .move(let w, let r):
                modified.append(w.display); changed.append(r.display); changed.append(w.display)
                if let n = fuzzNote(w.fuzz, path: w.display) { notes.append(n) }
                written.append((w.display, String(decoding: w.data, as: UTF8.self)))
                forget.append(PrivateStorage.canonical(r.target))
            case .delete(let r):
                deleted.append(r.display); changed.append(r.display)
                forget.append(PrivateStorage.canonical(r.target))
            case .secretStore(let display, _, _):
                // Never handed on (LSP, logs): the store holds the real token.
                modified.append(display); changed.append(display)
            }
        }
        // `.gptPatch` evidence from the transaction's own committed post-image
        // receipts (never from a later stat, §7 / P52).
        var evidence: [GPTEvidence.Receipt] = []
        for receipt in journal.receipts {
            switch receipt {
            case .replaced(let path, _, _, let post?), .created(let path, _, let post?):
                evidence.append(GPTEvidence.Receipt(key: PrivateStorage.canonical(path), identity: post.identity, source: .gptPatch))
            default: break
            }
        }
        let text = successText(added: added, modified: modified, deleted: deleted, notes: notes)
        return Result(text: text, outcome: EditOutcome(status: .applied, changed: changed),
                      writtenFiles: written, evidence: evidence, forget: forget)
    }

    /// Publishes a delivered result's evidence (§7): a receipt is published
    /// only while the path still matches it; deleted paths are forgotten.
    /// Callers invoke this only after the result reached the model.
    static func settleEvidence(_ result: Result) async {
        for key in result.forget { await FileTimeTracker.shared.forgetGPT(key: key) }
        for receipt in result.evidence {
            guard let now = try? FileIdentity.lstatPath(receipt.key), now.sameState(as: receipt.identity) else { continue }
            await FileTimeTracker.shared.publishGPT(receipt)
        }
    }
}
