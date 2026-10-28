import ArgumentParser
import Foundation

/// `briglia worktree add <repo> <topic>` / `integrate <target>` / `list`
/// (MULTI_ASSISTANT_PLAN §7.2): each assistant edits a shared repository in
/// its own worktree on its own branch, so two assistants never write the
/// same checkout; integration is a fast-forward under the repository lock
/// or a hand-off to the user. Only while several assistants exist.
struct WorktreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktree",
        abstract: "Your own git worktree for a shared repository (several assistants only).",
        shouldDisplay: false,
        subcommands: [Add.self, Integrate.self, List.self]
    )

    static func requireMulti() throws -> MultiAssistant.Paths {
        guard let doc = (try? AssistantRegistry.read(.live)) ?? nil, doc.records.filter({ $0.state == "active" }).count >= 2 else {
            print("✖ Worktrees through Briglia exist only while several assistants are set up on this computer; use `git worktree` directly.")
            throw ExitCode(2)
        }
        return .live
    }

    // MARK: git

    struct GitResult { var ok: Bool; var out: String; var detail: String }

    static func git(_ args: [String], in dir: String, timeout: Int = 120) -> GitResult {
        let r = ProcessRunner.runBlockingProcess(executable: "/usr/bin/env", args: ["git", "-C", dir] + args, timeoutSeconds: timeout)
        if let out = r.stdout { return GitResult(ok: true, out: out.trimmingCharacters(in: .whitespacesAndNewlines), detail: "") }
        return GitResult(ok: false, out: "", detail: r.failureDetail ?? "git failed")
    }

    static func sh(_ command: String, in dir: String, timeout: Int) -> GitResult {
        let r = ProcessRunner.runBlockingProcess(executable: "/bin/sh", args: ["-c", "cd \"$1\" && eval \"$2\"", "sh", dir, command], timeoutSeconds: timeout)
        if let out = r.stdout { return GitResult(ok: true, out: out, detail: "") }
        return GitResult(ok: false, out: "", detail: r.failureDetail ?? "the command failed")
    }

    static func withRepoLock<T>(_ paths: MultiAssistant.Paths, commonDir: String, _ body: () throws -> T) throws -> T {
        try MultiAssistant.ensure(paths.gitDir)
        switch ProfileFileLock.take(paths.repoLock(commonDir: commonDir), waitSeconds: 30) {
        case .acquired(let lock):
            defer { lock.release() }
            return try body()
        case .busy:
            print("✖ Another assistant is changing this repository's worktrees right now; try again in a minute.")
            throw ExitCode(1)
        case .failed(let why):
            print("✖ \(why)")
            throw ExitCode(1)
        }
    }

    static func validTopic(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.allSatisfy { ($0.isLetter && $0.isASCII && $0.isLowercase) || $0.isNumber || $0 == "-" }
            && !s.hasPrefix("-")
    }

    /// Repository name for the worktree folder.
    static func repoName(_ loc: BoardGit.Location) -> String {
        let root = BoardGit.repoDisplay(loc.commonDir)
        let raw = URL(fileURLWithPath: root).lastPathComponent
        let cleaned = raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
        return String(cleaned).isEmpty ? "repo" : String(cleaned)
    }

    // MARK: add

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Create or reuse your worktree of <repo> on branch briglia/<you>/<topic>.")

        @Argument(help: "Any path inside the repository.") var repo: String
        @Argument(help: "Short topic: lower-case letters, digits and -.") var topic: String

        func run() throws {
            let paths = try WorktreeCommand.requireMulti()
            guard WorktreeCommand.validTopic(topic) else {
                print("✖ The topic must be lower-case letters, digits and -, up to 40 characters."); throw ExitCode(2)
            }
            let profile = AssistantProfile.selectedName
            guard let loc = BoardGit.locate(MultiAssistant.canonical(repo)) else {
                print("✖ \(repo) is not inside a git repository."); throw ExitCode(2)
            }
            let branch = "briglia/\(profile)/\(topic)"
            let home = MultiAssistant.canonical(LandingZone.root.path)
            let target = (home as NSString).appendingPathComponent("worktrees/\(WorktreeCommand.repoName(loc))-\(profile)")
            let main = BoardGit.repoDisplay(loc.commonDir)
            try WorktreeCommand.withRepoLock(paths, commonDir: loc.commonDir) {
                if FileManager.default.fileExists(atPath: target) {
                    guard let there = BoardGit.locate(target), there.commonDir == loc.commonDir, there.worktree == MultiAssistant.canonical(target) else {
                        print("✖ \(MultiAssistant.display(target)) exists but is not a worktree of this repository; move it away first.")
                        throw ExitCode(1)
                    }
                    if there.branch != branch {
                        let status = WorktreeCommand.git(["status", "--porcelain"], in: target)
                        guard status.ok, status.out.isEmpty else {
                            print("✖ Your worktree \(MultiAssistant.display(target)) has uncommitted changes on \(there.branch ?? "a detached HEAD"); commit or stash them, then try again.")
                            throw ExitCode(1)
                        }
                        let exists = WorktreeCommand.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: target).ok
                        let sw = WorktreeCommand.git(exists ? ["switch", branch] : ["switch", "-c", branch], in: target)
                        guard sw.ok else { print("✖ git switch failed: \(sw.detail)"); throw ExitCode(1) }
                    }
                } else {
                    try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    let exists = WorktreeCommand.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: main).ok
                    let add = WorktreeCommand.git(exists ? ["worktree", "add", target, branch] : ["worktree", "add", "-b", branch, target], in: main)
                    guard add.ok else { print("✖ git worktree add failed: \(add.detail)"); throw ExitCode(1) }
                }
                let canonicalTarget = MultiAssistant.canonical(target)
                try WorktreeRegistry.update(paths) { records in
                    records.removeAll { $0.path == canonicalTarget }
                    records.append(.init(profile: profile, commonDir: loc.commonDir, path: canonicalTarget, branch: branch, createdAt: Date()))
                }
            }
            print("✔ Your worktree: \(target)")
            print("  branch: \(branch)")
            print("  Edit files there. To merge back (only when the user asked): cd \(target) && \(AssistantProfile.commandPrefix) worktree integrate <target-branch>")
        }
    }

    // MARK: integrate

    struct Integrate: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "integrate", abstract: "Rebase your worktree branch onto <target> and fast-forward <target>, or hand off.")

        @Argument(help: "The branch to integrate into (e.g. main).") var target: String
        @Option(name: .customLong("worktree"), help: "Your worktree (default: the current directory).") var worktree: String?
        @Option(name: .customLong("test"), help: "Command to run in the worktree after the rebase; integration stops if it fails.") var test: String?

        func run() throws {
            let paths = try WorktreeCommand.requireMulti()
            let profile = AssistantProfile.selectedName
            let start = MultiAssistant.canonical(worktree ?? FileManager.default.currentDirectoryPath)
            guard let loc = BoardGit.locate(start) else { print("✖ \(start) is not inside a git worktree."); throw ExitCode(2) }
            guard WorktreeRegistry.load(paths).contains(where: { $0.profile == profile && $0.path == loc.worktree }) else {
                print("✖ \(MultiAssistant.display(loc.worktree)) is not one of your Briglia worktrees (create it with `\(AssistantProfile.commandPrefix) worktree add`).")
                throw ExitCode(2)
            }
            guard let branch = loc.branch else { print("✖ Your worktree is on a detached HEAD."); throw ExitCode(2) }
            guard branch != target, !target.hasPrefix("-"), WorktreeCommand.git(["check-ref-format", "--branch", target], in: loc.worktree).ok else {
                print("✖ ‘\(target)’ is not a valid target branch."); throw ExitCode(2)
            }
            let dir = loc.worktree
            for attempt in 1...3 {
                let status = WorktreeCommand.git(["status", "--porcelain"], in: dir)
                guard status.ok, status.out.isEmpty else { print("✖ Commit your changes first (the worktree is not clean)."); throw ExitCode(1) }
                let old = WorktreeCommand.git(["rev-parse", "--verify", "refs/heads/\(target)"], in: dir)
                guard old.ok else { print("✖ The branch ‘\(target)’ does not exist."); throw ExitCode(1) }
                let rebase = WorktreeCommand.git(["rebase", old.out], in: dir, timeout: 600)
                if !rebase.ok {
                    _ = WorktreeCommand.git(["rebase", "--abort"], in: dir)
                    print("✖ Rebasing \(branch) onto \(target) hit conflicts; nothing was integrated. Resolve them in your worktree (git rebase \(target)), commit, and run integrate again.")
                    throw ExitCode(1)
                }
                if let test {
                    let t = WorktreeCommand.sh(test, in: dir, timeout: 3600)
                    guard t.ok else { print("✖ The tests failed after the rebase (\(t.detail)); \(target) was not changed."); throw ExitCode(1) }
                }
                guard let new = Optional(WorktreeCommand.git(["rev-parse", "HEAD"], in: dir)), new.ok else { print("✖ cannot read HEAD"); throw ExitCode(1) }
                let outcome: String? = try WorktreeCommand.withRepoLock(paths, commonDir: loc.commonDir) {
                    let now = WorktreeCommand.git(["rev-parse", "--verify", "refs/heads/\(target)"], in: dir)
                    guard now.ok, now.out == old.out else { return nil }    // moved: rebase again
                    // S3-3: a failed enumeration never counts as "not checked out".
                    let list = WorktreeCommand.git(["worktree", "list", "--porcelain"], in: dir)
                    guard list.ok, list.out.hasPrefix("worktree ") else {
                        return "✖ Briglia could not list the checkouts of this repository (\(list.ok ? "unexpected output" : list.detail)); \(target) was not changed."
                    }
                    var checkedOut: [String] = []
                    var current: String?
                    for line in list.out.split(separator: "\n").map(String.init) {
                        if line.hasPrefix("worktree ") { current = String(line.dropFirst(9)) }
                        if line == "branch refs/heads/\(target)", let c = current { checkedOut.append(MultiAssistant.canonical(c)) }
                    }
                    if checkedOut.isEmpty {
                        let u = WorktreeCommand.git(["update-ref", "refs/heads/\(target)", new.out, old.out], in: dir)
                        guard u.ok else { return "✖ git update-ref failed: \(u.detail)" }
                        return "✔ \(target) fast-forwarded to \(String(new.out.prefix(12))) (\(branch))."
                    }
                    let owned = WorktreeRegistry.load(paths).filter { $0.profile == profile }.map(\.path)
                    let wtStatus = checkedOut.first.map { WorktreeCommand.git(["status", "--porcelain"], in: $0) }
                    let wtHead = checkedOut.first.map { WorktreeCommand.git(["rev-parse", "HEAD"], in: $0) }
                    if checkedOut.count == 1, let wt = checkedOut.first, owned.contains(wt),
                       let st = wtStatus, st.ok, st.out.isEmpty, let hd = wtHead, hd.ok, hd.out == old.out {
                        let m = WorktreeCommand.git(["merge", "--ff-only", branch], in: wt)
                        guard m.ok else { return "✖ git merge --ff-only failed: \(m.detail)" }
                        return "✔ \(target) fast-forwarded in your worktree \(MultiAssistant.display(wt))."
                    }
                    let place = checkedOut.first.map(MultiAssistant.display) ?? "?"
                    return "↪ \(target) is checked out in \(place) (yours to keep clean, or another checkout), so Briglia did not merge. Your branch \(branch) is rebased onto \(target) and ready. To merge it there:\n  cd \(place) && git merge --ff-only \(branch)"
                }
                if let outcome { print(outcome); if outcome.hasPrefix("✖") { throw ExitCode(1) }; return }
                print("· \(target) moved while integrating (attempt \(attempt)); rebasing again…")
            }
            print("✖ \(target) kept moving; try again later.")
            throw ExitCode(1)
        }
    }

    // MARK: list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List the Briglia worktrees on this computer.")
        func run() throws {
            let paths = try WorktreeCommand.requireMulti()
            let records = WorktreeRegistry.load(paths)
            if records.isEmpty { print("No Briglia worktrees."); return }
            for r in records.sorted(by: { ($0.profile, $0.path) < ($1.profile, $1.path) }) {
                print("\(r.profile)\t\(r.branch)\t\(MultiAssistant.display(r.path))\t(repo \(MultiAssistant.display(BoardGit.repoDisplay(r.commonDir))))")
            }
        }
    }
}
