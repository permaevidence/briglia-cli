import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension MidturnHarness {

    // MARK: Scanner

    func riScannerSection(_ scratch: URL) {
        let real = scratch.appendingPathComponent("real-data/briglia/whatsapp-bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: real.appendingPathComponent("index.js").path, contents: Data("1".utf8))
        let alias = scratch.appendingPathComponent("alias-data")
        try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: scratch.appendingPathComponent("real-data"))
        let resolve: (String) -> String? = { path in
            guard let p = realpath(path, nil) else { return nil }
            defer { free(p) }
            return String(cString: p)
        }
        let script = real.appendingPathComponent("index.js").path
        let aliasScript = alias.appendingPathComponent("briglia/whatsapp-bridge/index.js").path
        let target = BridgeScanner.Target(configured: aliasScript, canonical: resolve(script))

        func run(_ rows: [BridgeScanner.Proc], configure: (RIUnits.Table) -> Void = { _ in }) -> (BridgeOutcome, RIUnits.Table) {
            let t = RIUnits.Table(); t.rows = rows; configure(t)
            return (t.scanner(resolve: resolve).stopBridges(target: target), t)
        }
        var (o, t) = run([])
        check("S1 empty table → clear, no signal", o == .clear && t.signals.isEmpty)
        (o, t) = run([RIUnits.proc(10, ["/usr/bin/node", script])]) { $0.dieOnTerm = [10] }
        check("S2 node form (canonical spelling) → SIGTERM only, clear", o == .clear && t.signals.map(\.1) == [SIGTERM])
        (o, t) = run([RIUnits.proc(11, ["/opt/homebrew/bin/node", aliasScript])]) { $0.dieOnTerm = [11] }
        check("S3 symlinked-ancestor spelling is the same bridge → stopped", o == .clear && t.signals.first?.0 == 11)
        (o, t) = run([RIUnits.proc(12, ["/x/briglia", "__setsid-exec", "--", "/usr/local/bin/node", script])])
        check("S4 shim form → SIGTERM then SIGKILL when it ignores TERM, clear",
              o == .clear && t.signals.map(\.1) == [SIGTERM, SIGKILL])
        // Another install's bridge (Ada.app, LocalAgent) resolves to a different file.
        let ada = scratch.appendingPathComponent("Ada/whatsapp-bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: ada, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: ada.appendingPathComponent("index.js").path, contents: Data("2".utf8))
        (o, t) = run([RIUnits.proc(13, ["tail", "-f", script]), RIUnits.proc(14, ["/usr/bin/node", "/other/app.js", script]),
                      RIUnits.proc(15, ["vim", script]), RIUnits.proc(16, ["/usr/bin/node", ada.appendingPathComponent("index.js").path])])
        check("S5 a reader, another node program carrying the path, an editor, and Ada.app's bridge are never signalled",
              o == .clear && t.signals.isEmpty)
        (o, t) = run([RIUnits.proc(17, ["/usr/bin/node", script], uid: 0), RIUnits.proc(18, ["/usr/bin/node", script], zombie: true)])
        check("S6 other-uid and zombie processes are ignored", o == .clear && t.signals.isEmpty)
        (o, t) = run([]) { $0.unreadable = true }
        check("S7 unreadable table → unknown, nothing signalled", { if case .unknown = o { return true }; return false }() && t.signals.isEmpty)
        (o, t) = run([RIUnits.proc(19, nil)])
        check("S8 unreadable same-uid argv → unknown", { if case .unknown = o { return true }; return false }() && t.signals.isEmpty)
        (o, t) = run([RIUnits.proc(20, ["/usr/bin/node", "/gone/briglia/whatsapp-bridge/index.js"])])
        check("S9 a bridge-looking script that cannot be resolved → unknown (identity not established)",
              { if case .unknown = o { return true }; return false }() && t.signals.isEmpty)
        (o, t) = run([RIUnits.proc(21, ["/usr/bin/node", script])]) { $0.immortal = [21] }
        check("S10 a bridge that survives SIGKILL → unknown", { if case .unknown = o { return true }; return false }())
        (o, t) = run([RIUnits.proc(22, ["/usr/bin/node", script])]) {
            $0.replaceAfterTerm = [22: RIUnits.proc(22, ["/bin/zsh"])]
        }
        check("S11 pid reused by a non-bridge after SIGTERM → never SIGKILLed",
              o == .clear && t.signals.map(\.1) == [SIGTERM])
        check("S12 shape rules: exact arities only",
              BridgeScanner.scriptArgument(["node", "a", "b"]) == nil && BridgeScanner.scriptArgument(["node"]) == nil
                && BridgeScanner.scriptArgument(["/b", "__setsid-exec", "--", "node", "s", "extra"]) == nil
                && BridgeScanner.scriptArgument(["nodejs", "s"]) == "s")
    }

    // MARK: Remover

    func riRemoverSection(_ scratch: URL) {
        let root = scratch.appendingPathComponent("remover-root", isDirectory: true)
        let fm = FileManager.default
        func fresh() -> URL {
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root.appendingPathComponent("whatsapp-bridge/a/b"), withIntermediateDirectories: true)
            fm.createFile(atPath: root.appendingPathComponent("whatsapp-bridge/index.js").path, contents: Data("x".utf8))
            fm.createFile(atPath: root.appendingPathComponent("whatsapp-bridge/a/b/f").path, contents: Data("x".utf8))
            return root.appendingPathComponent("whatsapp-bridge")
        }
        let outside = scratch.appendingPathComponent("remover-outside", isDirectory: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        fm.createFile(atPath: outside.appendingPathComponent("precious").path, contents: Data("p".utf8))
        func precious() -> Bool { fm.fileExists(atPath: outside.appendingPathComponent("precious").path) }
        var live = BridgeFolderRemover.Seams.live
        #if os(Linux)
        live.mountPoints = { ["/"] }   // the scratch tree is not a mount point
        #endif
        var kinds: [BridgeFolderRemover.TopKind] = []
        func remove(_ seams: BridgeFolderRemover.Seams, allow: Bool = true) -> FolderOutcome {
            kinds = []
            return BridgeFolderRemover.remove(name: "whatsapp-bridge", under: root, seams: seams) { kinds.append($0); return allow }
        }

        var dir = fresh()
        try? fm.createSymbolicLink(at: dir.appendingPathComponent("a/out"), withDestinationURL: outside)
        var out = remove(live)
        check("R1 tree with an inner symlink pointing outside → removed, the outside target survives, kind recorded first",
              out == .removed(linkOnly: false) && !fm.fileExists(atPath: dir.path) && precious() && kinds == [.dir])
        dir = fresh(); try? fm.removeItem(at: dir)
        try? fm.createSymbolicLink(at: dir, withDestinationURL: outside)
        out = remove(live)
        check("R2 top-level symlink → only the link removed", out == .removed(linkOnly: true) && precious() && kinds == [.link])
        dir = fresh(); try? fm.removeItem(at: dir)
        try? fm.createSymbolicLink(atPath: dir.path, withDestinationPath: scratch.appendingPathComponent("nowhere").path)
        out = remove(live)
        check("R3 dangling top-level symlink → link removed", out == .removed(linkOnly: true))
        try? fm.removeItem(at: root); try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        check("R4 nothing there → absent, no record callback", remove(live) == .absent && kinds.isEmpty)
        dir = fresh()
        out = remove(live, allow: false)
        check("R5 the record write fails → nothing removed", { if case .failed = out { return true }; return false }() && fm.fileExists(atPath: dir.appendingPathComponent("index.js").path))
        dir = fresh()
        var different = live; different.deviceOverride = { $0 == "whatsapp-bridge/a" ? 9999 : nil }
        out = remove(different)
        check("R6 a different device below → stopped before entering it; files inside kept",
              { if case .failed = out { return true }; return false }() && fm.fileExists(atPath: dir.appendingPathComponent("a/b/f").path))
        // Same-device mount: Linux by mount table, macOS by file-system identity.
        for level in ["whatsapp-bridge", "whatsapp-bridge/a"] {
            dir = fresh()
            var seams = live
            let canonicalRoot = root.resolvingSymlinksInPath().path
            #if os(Linux)
            seams.mountPoints = { ["/", canonicalRoot + "/" + level] }
            #else
            var st = stat(); _ = stat(root.appendingPathComponent(level).path, &st)
            let inode = st.st_ino
            seams.fsIdentity = { fd in
                var s = stat(); _ = fstat(fd, &s)
                return s.st_ino == inode ? "mounted:" + canonicalRoot : BridgeFolderRemover.liveFSIdentity(fd)
            }
            #endif
            out = remove(seams)
            check("R7 same-device mount at \(level) → refused, nothing inside it unlinked",
                  { if case .failed = out { return true }; return false }() && fm.fileExists(atPath: dir.appendingPathComponent("a/b/f").path))
        }
        dir = fresh()
        var unreadable = live
        #if os(Linux)
        unreadable.mountPoints = { nil }
        #else
        unreadable.fsIdentity = { _ in nil }
        #endif
        out = remove(unreadable)
        check("R8 mount boundary undeterminable → nothing removed", { if case .failed = out { return true }; return false }()
              && fm.fileExists(atPath: dir.appendingPathComponent("index.js").path))
        check("R8b malformed mountinfo fails closed",
              BridgeFolderRemover.parseMountInfo("garbage\n") == nil
                && BridgeFolderRemover.parseMountInfo("36 35 98:0 /mnt1 /mnt\\040x rw - ext3 /dev/root rw\n") == ["/mnt x"])
        dir = fresh()
        mkfifo(dir.appendingPathComponent("a/fifo").path, 0o600)
        out = remove(live)
        check("R9 a FIFO inside → refused, left in place", { if case .failed = out { return true }; return false }()
              && fm.fileExists(atPath: dir.appendingPathComponent("a").path))
        try? fm.removeItem(at: dir.appendingPathComponent("a/fifo"))
        check("R9b retry after the obstacle is gone → removed", remove(live) == .removed(linkOnly: false))
        dir = fresh()
        var swap = live
        swap.afterOpen = { rel in
            guard rel == "whatsapp-bridge/a" else { return }
            try? fm.removeItem(at: dir.appendingPathComponent("a/b"))
            try? fm.createSymbolicLink(at: dir.appendingPathComponent("a/b"), withDestinationURL: outside)
        }
        out = remove(swap)
        check("R10 a directory swapped for a symlink during the walk → the link is removed, its target untouched",
              precious())
        dir = fresh()
        let saved = BridgeFolderRemover.maxEntries
        BridgeFolderRemover.maxEntries = 2
        out = remove(live)
        BridgeFolderRemover.maxEntries = saved
        check("R11 entry bound exceeded → stopped, pending, retried", { if case .failed = out { return true }; return false }())
        check("R11b next attempt within bounds finishes", remove(live) == .removed(linkOnly: false))
        try? fm.removeItem(at: root)
    }

    // MARK: Alerts

    func riAlertsSection() {
        func doc(_ episodes: [String], _ queue: [String]) -> Data {
            let e = Dictionary(uniqueKeysWithValues: episodes.map { ($0, ["firstFailureAt": 0, "lastFailureAt": 0, "failureCount": 1,
                                                                        "lastError": "x", "escalationCount": 0] as [String: Any]) })
            return try! JSONSerialization.data(withJSONObject: ["episodes": e, "undelivered": queue])
        }
        func purged(_ d: Data) -> (Set<String>, [String]) {
            guard let out = MaintenanceAlertCenter._testPurgeRetired(d),
                  let o = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else { return ([], ["<decode failed>"]) }
            return (Set((o["episodes"] as? [String: Any] ?? [:]).keys), o["undelivered"] as? [String] ?? [])
        }
        let gwsEntry = "⚠️ Maintenance issue: Google Workspace (gws) access is failing. Error: x. Email alerts…"
        let waEsc = "⚠️ Still failing: WhatsApp bridge — failing for 2h, 3 failed attempts. Latest error: y."
        let waRec = "✅ Recovered: WhatsApp bridge is working again (was failing for 1h, 2 failed attempts)."
        let unrelated = "⚠️ Maintenance issue: web search (serper.dev) is failing. Error: gws WhatsApp mentioned in text."
        var (keys, queue) = purged(doc(["googleWorkspace", "whatsappBridge", "webSearch"], [gwsEntry, waEsc, unrelated]))
        check("A1 episodes + queued entry/escalation for both retired names dropped; unrelated alert and episode kept",
              keys == ["webSearch"] && queue == [unrelated])
        (keys, queue) = purged(doc([], [waRec, unrelated]))
        check("A2 queue-only: a queued recovery without its episode dropped", keys.isEmpty && queue == [unrelated])
        check("A3 the six prefixes match what the alert builders write",
              MaintenanceAlertCenter.retiredAlertPrefixes.count == 6
                && MaintenanceAlertCenter.retiredAlertPrefixes.contains("⚠️ Maintenance issue: Google Workspace (gws) access is failing."))
    }

    // MARK: Notice state machine

    func riNoticeStateSection(_ scratch: URL) {
        let env = RIUnits.env(root: scratch)
        RIUnits.resetStore(env)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let dest = RetiredIntegrations.Attempt(channelKind: "telegram", chatId: "42", channelGeneration: 3, at: now)
        func seed(_ g: RetiredIntegrations.NoticeState, conversion: RetiredIntegrations.Step = .done) {
            try? RetiredIntegrations.save(RetiredIntegrations.State(version: 1, evaluated: true,
                gws: .init(legacyUnset: false, conversion: conversion, notice: g), whatsapp: nil), to: env.stateURL)
        }
        seed(.pending, conversion: .pending)
        check("N1 not due while conversion is pending", RetiredIntegrations.dueNotices(RIUnits.state(env)!, now: now).isEmpty)
        seed(.pending)
        RetiredIntegrations.saveFaultForTesting = { _ in true }
        check("N2 a failed consume write sends nothing and keeps pending",
              RetiredIntegrations.consume(.gws, destination: dest, language: "en", env: env) == nil
                && RIUnits.state(env)?.gws?.notice == .pending)
        RetiredIntegrations.saveFaultForTesting = nil
        let text = RetiredIntegrations.consume(.gws, destination: dest, language: "en", env: env)
        check("N3 consume → attempted with the destination captured, EN text",
              text?.contains("Google email via gws has been removed from Briglia") == true
                && RIUnits.state(env)?.gws?.notice == .attempted && RIUnits.state(env)?.gws?.attempt == dest)
        check("N4 a second consume (crash after attempted) never repeats",
              RetiredIntegrations.consume(.gws, destination: dest, language: "en", env: env) == nil)
        RetiredIntegrations.settle(.gws, .retry(now.addingTimeInterval(120)), env: env)
        check("N5 refused → pending with a persisted retryAt; not due before it",
              RIUnits.state(env)?.gws?.notice == .pending && RetiredIntegrations.dueNotices(RIUnits.state(env)!, now: now).isEmpty
                && RetiredIntegrations.dueNotices(RIUnits.state(env)!, now: now.addingTimeInterval(121)) == [.gws])
        _ = RetiredIntegrations.consume(.gws, destination: dest, language: "it", env: env)
        RetiredIntegrations.settle(.gws, .done, env: env)
        check("N6 accepted/ambiguous → done, never due again",
              RIUnits.state(env)?.gws?.notice == .done && RetiredIntegrations.dueNotices(RIUnits.state(env)!, now: now.addingTimeInterval(9999)).isEmpty)
        check("N7 IT text", RetiredIntegrations.text(.gws, state: RIUnits.state(env)!, language: "it", dataRoot: env.dataRoot)
                .contains("L'email Google tramite gws è stata rimossa da Briglia"))
        RetiredIntegrations.settle(.gws, .retry(now), env: env)
        check("N8 a late settle after done changes nothing", RIUnits.state(env)?.gws?.notice == .done)
        RIUnits.resetStore(env)
    }
}
