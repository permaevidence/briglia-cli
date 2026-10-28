import Foundation

/// The stage-3 layer around every tool call (MULTI_ASSISTANT_PLAN §7.3,
/// §8.1, §8.4, A2). `before` returns nil at once without a multi-assistant
/// context, so a single-assistant Briglia runs exactly today's path.
enum MultiAssistantHooks {
    static let editTools: Set<String> = ["write_file", "edit_file", "apply_patch"]
    static let touchTools: Set<String> = ["write_file", "edit_file", "apply_patch", "read_file", "grep", "glob", "list_dir", "bash", "lsp"]

    struct Pending {
        var ctx: MultiAssistant.Context
        var opId: String?
        var locked: [String] = []
        var stampsBefore: [String: Tripwire.Stamp] = [:]
        var tripwire: Tripwire.Snapshot?
    }

    enum Before {
        case proceed(Pending)
        case refuse(String)
    }

    // MARK: Paths

    /// Every file an edit tool will touch (all patch operations, both move
    /// endpoints), canonical.
    static func editPaths(toolName: String, argumentsJSON: String) -> [String] {
        Array(Set(ProjectInstructionsTracker.touchedPaths(toolName: toolName, argumentsJSON: argumentsJSON)
            .map(MultiAssistant.canonical))).sorted()
    }

    /// Paths a tool call touches, for heads-ups and the board's folders.
    static func touchedPaths(toolName: String, argumentsJSON: String) -> [String] {
        var raw = ProjectInstructionsTracker.touchedPaths(toolName: toolName, argumentsJSON: argumentsJSON)
        if toolName == "bash", let destructive = GitCheckpointTracker.destructiveBashPaths(argumentsJSON: argumentsJSON) {
            raw += destructive.filter { $0.hasPrefix("/") || $0.hasPrefix("~") }
        }
        if toolName == "lsp" || toolName == "glob",
           let data = argumentsJSON.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["path", "file_path", "file"] {
                if let p = obj[key] as? String, p.hasPrefix("/") || p.hasPrefix("~") { raw.append(p) }
            }
        }
        var seen = Set<String>()
        return raw.map(MultiAssistant.canonical).filter { $0.hasPrefix("/") && seen.insert($0).inserted }.prefix(16).map { $0 }
    }

    // MARK: Before

    static func before(toolName: String, argumentsJSON: String) async -> Before? {
        guard let ctx = MultiAssistant.context() else { return nil }
        // A2: "active" = any tool call in the last 30 minutes.
        guard touchTools.contains(toolName) || toolName == "board" else {
            BoardWriter.shared.noteActivity(ctx, touched: [])
            return nil
        }
        var pending = Pending(ctx: ctx)
        if editTools.contains(toolName) {
            let paths = editPaths(toolName: toolName, argumentsJSON: argumentsJSON)
            guard !paths.isEmpty else { return .proceed(pending) }
            guard await ClaimPathLocks.shared.acquire(paths) else {
                return .refuse("edit refused: another of your edits on this file is still running; try again in a moment. Nothing was changed.")
            }
            let opId = UUID().uuidString.lowercased()
            do {
                try FileClaims.reserve(ctx, paths: paths, opId: opId)
            } catch let r as FileClaims.Refusal {
                ClaimPathLocks.shared.release(paths)
                return .refuse(r.message)
            } catch {
                ClaimPathLocks.shared.release(paths)
                return .refuse("edit refused: the file claim could not be recorded (\(error)); nothing was changed.")
            }
            pending.opId = opId
            pending.locked = paths
            for p in paths { pending.stampsBefore[p] = Tripwire.stamp(p) }
        } else if toolName == "bash" {
            pending.tripwire = await Tripwire.snapshot(ctx)
        }
        return .proceed(pending)
    }

    static func refusalContent(_ message: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: After

    /// Text appended to the tool result ("" when nothing applies).
    static func after(toolName: String, argumentsJSON: String, resultContent: String, pending: Pending) async -> String {
        let ctx = pending.ctx
        var appended = ""
        if let opId = pending.opId {
            let succeeded = !resultContent.contains("\"error\"")
            let changed = succeeded || pending.locked.contains { Tripwire.stamp($0) != pending.stampsBefore[$0] }
            let scopes = await ClaimScopes.shared.scopesForEdit(opId: opId)
            settleWithRetry(ctx, opId: opId, changed: changed, scopes: scopes)
            ClaimPathLocks.shared.release(pending.locked)
        }
        if let snap = pending.tripwire {
            appended += await Tripwire.shared.afterCommand(ctx, snap)
        }
        let touched = touchedPaths(toolName: toolName, argumentsJSON: argumentsJSON)
        BoardWriter.shared.noteActivity(ctx, touched: toolName == "board" ? [] : touched)
        appended += headsUp(ctx, toolName: toolName, touched: touched)
        return appended
    }

    /// §7.3 step 4: a settlement that cannot take the lock is retried in the
    /// background (the entries stay `reserved`, still protective).
    static func settleWithRetry(_ ctx: MultiAssistant.Context, opId: String, changed: Bool, scopes: [String]) {
        do { try FileClaims.settle(ctx, opId: opId, changed: changed, scopes: scopes); return } catch {}
        Task.detached {
            for attempt in 0..<600 {
                try? await Task.sleep(nanoseconds: UInt64(min(5.0, 0.2 * Double(attempt + 1)) * 1_000_000_000))
                if (try? FileClaims.settle(ctx, opId: opId, changed: changed, scopes: scopes)) != nil { return }
            }
        }
    }

    // MARK: Heads-up (§8.4)

    static func headsUp(_ ctx: MultiAssistant.Context, toolName: String, touched: [String]) -> String {
        guard !touched.isEmpty else { return "" }
        let now = MultiAssistant.now
        let states = AssistantBoard.peers(ctx, now: now).filter(\.active)
        guard !states.isEmpty else { return "" }
        let worktrees = WorktreeRegistry.load(ctx.paths)
        let myLocations = touched.compactMap(BoardGit.locate)
        var lines: [String] = []
        for s in states {
            guard let e = s.entry else { continue }
            var area: String?
            let claimed = FileClaims.claims(of: s.peer, ctx).map(\.path)
            for path in touched {
                if let c = claimed.first(where: { $0 == path || MultiAssistant.isInside($0, path) }) { area = "claim:" + c; break }
                if let w = e.worktree, MultiAssistant.isInside(path, w), e.repo != nil { area = "worktree:" + w; break }
                if let f = e.folders.first(where: { MultiAssistant.isInside(path, $0) }) { area = "folder:" + f; break }
            }
            if area == nil {
                for loc in myLocations {
                    if let r = e.repo, r == loc.commonDir, let b = e.branch, b == loc.branch { area = "branch:" + r + "#" + b; break }
                    if worktrees.contains(where: { $0.profile == s.peer.profile && $0.commonDir == loc.commonDir && $0.path != loc.worktree }) {
                        area = "repo:" + loc.commonDir; break
                    }
                }
            }
            guard let key = area, ClaimScopes.shared.firstAnnouncement(s.peer.profile + "|" + key) else { continue }
            var line = "[Board] \(MultiAssistant.q(s.peer.displayName, 40)) is active here"
            if let t = e.task, !t.isEmpty { line += ": task " + MultiAssistant.q(t, 80) }
            if let b = e.branch { line += ", branch " + MultiAssistant.q(b, 60) }
            line += ", last tool call \(MultiAssistant.clock(e.lastActiveAt)) (\(MultiAssistant.minutesAgo(e.lastActiveAt, now: now)))."
            if key.hasPrefix("claim:") { line += " It is editing " + MultiAssistant.q(MultiAssistant.display(String(key.dropFirst(6))), 120) + "." }
            if key.hasPrefix("repo:") || key.hasPrefix("branch:") {
                line += " Work in your own worktree (`\(AssistantProfile.commandPrefix) worktree add <repo> <topic>`)."
            }
            if toolName == "bash" { line += " Bash is not checked against claims." }
            lines.append(line)
        }
        return lines.isEmpty ? "" : "\n\n" + lines.joined(separator: "\n")
    }

    // MARK: The board tool (§8.5)

    static func executeBoardTool(argumentsJSON: String) -> String {
        guard let ctx = MultiAssistant.context() else {
            return refusalContent("the board exists only while several assistants are set up on this computer")
        }
        let obj = (argumentsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let action = (obj["action"] as? String ?? "read").lowercased()
        switch action {
        case "read":
            return AssistantBoard.fullBoard(ctx)
        case "post":
            guard let task = obj["task"] as? String, !AmbientStatus.normalize(task).isEmpty else {
                return refusalContent("board action=post requires 'task' (up to \(BoardEntry.maxTaskCharacters) characters)")
            }
            BoardWriter.shared.post(ctx, task: task)
            return "Posted your task on the board: " + MultiAssistant.q(String(AmbientStatus.normalize(task).prefix(BoardEntry.maxTaskCharacters)), BoardEntry.maxTaskCharacters)
        case "clear":
            BoardWriter.shared.post(ctx, task: nil)
            return "Your task was cleared from the board."
        case "release":
            do {
                let (released, reserved) = try FileClaims.releaseHeld(ctx)
                var text = "Released \(released) claimed file\(released == 1 ? "" : "s")."
                if reserved > 0 { text += " \(reserved) file\(reserved == 1 ? " is" : "s are") being edited right now and stay\(reserved == 1 ? "s" : "") protected until that edit finishes." }
                return text
            } catch let r as FileClaims.Refusal {
                return refusalContent(r.message)
            } catch {
                return refusalContent("\(error)")
            }
        default:
            return refusalContent("board action must be one of: read, post, clear, release")
        }
    }

    /// The system-prompt section, present only together with the tool.
    static let promptSection = """


    **Other assistants on this computer** — you are one of several Briglia assistants on this computer, each with its own user chat, memory and settings. The `[Ambient status]` note lists the ones that made a tool call in the last 30 minutes; the `board` tool shows all of them and lets you post what you are working on. When you edit a file with write_file/edit_file/apply_patch it is claimed until your turn (and the jobs it started) ends; another assistant's claimed file is refused to those tools — work on a copy, choose another file, or tell the user. Before editing a git repository outside your own home folder, create or reuse your own worktree with `\(AssistantProfile.commandPrefix) worktree add <repo> <topic>` and edit there; merge back with `\(AssistantProfile.commandPrefix) worktree integrate <target>` only when the user asked you to. Never edit another assistant's memory or settings.
    """
}

// MARK: - Worktree ownership records (§7.2)

enum WorktreeRegistry {
    struct Record: Codable, Equatable {
        var profile: String
        var commonDir: String
        var path: String
        var branch: String
        var createdAt: Date
    }

    struct Document: Codable, Equatable {
        var version: Int = 1
        var worktrees: [Record]
    }

    static func load(_ paths: MultiAssistant.Paths) -> [Record] {
        guard let data = MultiAssistant.readSmall(paths.worktreesFile, max: 2 * 1024 * 1024),
              let doc = try? MultiAssistant.decoder.decode(Document.self, from: data), doc.version == 1 else { return [] }
        return doc.worktrees
    }

    /// Read-modify-write under `git/worktrees.lock`.
    static func update(_ paths: MultiAssistant.Paths, _ change: (inout [Record]) -> Void) throws {
        try MultiAssistant.ensure(paths.gitDir)
        switch ProfileFileLock.take(paths.worktreesLock, waitSeconds: 10) {
        case .acquired(let lock):
            defer { lock.release() }
            var records = load(paths)
            change(&records)
            _ = try PrivateStorage.writeAtomically(try MultiAssistant.encoder.encode(Document(worktrees: records)),
                                                   to: paths.worktreesFile, mode: 0o600)
        case .busy: throw FileClaims.Refusal(message: "the worktree records are busy; try again in a moment")
        case .failed(let why): throw FileClaims.Refusal(message: why)
        }
    }
}
