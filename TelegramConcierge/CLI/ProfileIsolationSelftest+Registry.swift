import Foundation

extension ProfileHarness {
    typealias Reg = AssistantRegistry

    func tempRegistry(_ label: String) -> Reg.Paths {
        Reg.Paths(root: root.appendingPathComponent("reg-\(label)", isDirectory: true))
    }

    func seed(_ paths: Reg.Paths, defaultBot: String? = "100:A", extras: [String] = ["work", "health"]) {
        var doc = Reg.Document(version: 1, records: [Reg.newRecord(name: "default", displayName: "Bree")])
        if let defaultBot { doc.records[0].bot.current = Reg.digest(.bot, defaultBot) }
        for e in extras { doc.records.append(Reg.newRecord(name: e, displayName: e.capitalized)) }
        try? PrivateStorage.ensureDirectory(paths.root, mode: 0o700)
        try? Reg.write(doc, paths)
    }

    func record(_ paths: Reg.Paths, _ name: String) -> Reg.Record? { (try? Reg.read(paths))??.record(name) }

    func registrySection() {
        check("bot normalised to its id", Reg.normalize(.bot, " 123:AAA ") == "123" && Reg.digest(.bot, "123:AAA") == Reg.digest(.bot, "123:BBB"))
        check("non-token bot value rejected", Reg.digest(.bot, "abc:def") == nil && Reg.digest(.bot, ":x") == nil)
        check("inbox normalised case-insensitively", Reg.digest(.inbox, "Bree@Example.test ") == Reg.digest(.inbox, "bree@example.test"))
        check("bot and inbox digests never collide", Reg.digest(.bot, "1:x") != Reg.digest(.inbox, "1@x"))
        let absent = tempRegistry("absent")
        check("no registry → exists() false", !Reg.exists(absent))
        check("no registry → reconciliation is a no-op", Reg.reconcile(profile: "default", kind: .bot, read: { "100:A" }, paths: absent) == .noRegistry)
        check("…and creates nothing", !FileManager.default.fileExists(atPath: absent.root.path))
        let p = tempRegistry("names")
        seed(p)
        let doc = (try? Reg.read(p)) ?? nil
        check("display names unique case-insensitively", doc.map { Reg.displayNameTaken("WORK", in: $0) && !Reg.displayNameTaken("Coder", in: $0) } == true)
        check("a record may keep its own name", doc.map { !Reg.displayNameTaken("Work", in: $0, excluding: "work") } == true)
        let bad = tempRegistry("bad")
        try? PrivateStorage.ensureDirectory(bad.root, mode: 0o700)
        try? Data("{not json".utf8).write(to: bad.registry)
        if case .conflict = Reg.reconcile(profile: "default", kind: .bot, read: { "100:A" }, paths: bad) {
            check("a damaged registry fails closed (no polling)", true)
        } else { check("a damaged registry fails closed (no polling)", false) }
        check("a damaged registry is never rewritten", (try? Data(contentsOf: bad.registry)) == Data("{not json".utf8))
    }

    func transactionSection() {
        let p = tempRegistry("tx")
        seed(p)
        // Value held by default → refused before any network use.
        do { _ = try Reg.begin(profile: "work", kind: .bot, rawValue: "100:OTHER", paths: p); check("default's bot refused", false) }
        catch { check("default's bot refused (same id, rotated token)", "\(error)".contains("‘Bree’"), "\(error)") }
        check("unregistered profile refused", (try? Reg.begin(profile: "ghost", kind: .bot, rawValue: "5:X", paths: p)) == nil)
        guard let tx = try? Reg.begin(profile: "work", kind: .bot, rawValue: "200:W", paths: p) else {
            check("begin work 200", false); return
        }
        check("pending + activeTx(reserving) published", record(p, "work")?.bot.pending == .init(value: Reg.digest(.bot, "200:W")!, txId: tx.txId)
              && record(p, "work")?.activeTx["bot"]?.phase == "reserving")
        check("a second change of the same kind is refused while the writer lives",
              (try? Reg.begin(profile: "work", kind: .bot, rawValue: "201:W", paths: p)) == nil)
        check("another assistant cannot take a pending bot",
              (try? Reg.begin(profile: "health", kind: .bot, rawValue: "200:Z", paths: p)) == nil)
        check("an inbox change is independent", {
            guard let t = try? Reg.begin(profile: "work", kind: .inbox, rawValue: "w@x.test", paths: p) else { return false }
            t.abort(); return record(p, "work")?.inbox == Reg.Slot() && record(p, "work")?.activeTx["inbox"] == nil
        }())
        var wrote = false
        do { try tx.commit { wrote = true } } catch { check("commit", false, "\(error)") }
        check("commit writes the secret under the lock", wrote)
        check("commit: current set, pending cleared, phase cutover",
              record(p, "work")?.bot.current == Reg.digest(.bot, "200:W") && record(p, "work")?.bot.pending == nil
              && record(p, "work")?.activeTx["bot"]?.phase == "cutover")
        try? tx.finish()
        check("finish clears activeTx and the writer lease file",
              record(p, "work")?.activeTx["bot"] == nil && !FileManager.default.fileExists(atPath: p.txLease(tx.txId).path))

        // Replacing a bot keeps the old one reserved through cutover.
        guard let swap = try? Reg.begin(profile: "work", kind: .bot, rawValue: "300:W", paths: p) else { check("begin swap", false); return }
        try? swap.commit {}
        check("old bot kept as releasing (tagged with the txId)", record(p, "work")?.bot.releasing == .init(value: Reg.digest(.bot, "200:W")!, txId: swap.txId))
        check("the old bot cannot be taken during cutover", (try? Reg.begin(profile: "health", kind: .bot, rawValue: "200:H", paths: p)) == nil)
        try? swap.finish()
        if let t = try? Reg.begin(profile: "health", kind: .bot, rawValue: "200:H", paths: p) {
            check("after the cutover the old bot is free", true); t.abort()
        } else { check("after the cutover the old bot is free", false) }

        // Commit refuses when the reservation was lost; nothing is written.
        guard let lost = try? Reg.begin(profile: "health", kind: .bot, rawValue: "400:H", paths: p) else { check("begin lost", false); return }
        _ = try? Reg.withLock(p) { doc in
            guard var d = doc, let i = d.index("health") else { return }
            d.records[i].activeTx["bot"] = .init(txId: "someone-else", phase: "reserving")
            doc = d
        }
        var lostWrote = false
        let lostCommitted = (try? lost.commit { lostWrote = true }) != nil
        check("commit with a foreign txId refuses and writes no secret", !lostCommitted && !lostWrote)
        lost.abort()
        check("abort leaves another transaction's activeTx alone", record(p, "health")?.activeTx["bot"]?.txId == "someone-else")

        // Dead writers: entries whose lease is free are cleaned; a live
        // writer's entries never expire by age.
        let dead = UUID().uuidString.lowercased()
        _ = try? Reg.withLock(p) { doc in
            guard var d = doc, let i = d.index("health") else { return }
            d.records[i].activeTx["bot"] = .init(txId: dead, phase: "reserving")
            d.records[i].bot.pending = .init(value: Reg.digest(.bot, "500:H")!, txId: dead)
            doc = d
        }
        if let t = try? Reg.begin(profile: "work", kind: .inbox, rawValue: "q@x.test", paths: p) { t.abort() }
        check("a dead writer's pending entry is cleaned at the next transaction",
              record(p, "health")?.bot.pending == nil && record(p, "health")?.activeTx["bot"] == nil)
        guard let live = try? Reg.begin(profile: "health", kind: .bot, rawValue: "600:H", paths: p) else { check("begin live", false); return }
        // Age the reservation artificially: still protected while the lease is held.
        for _ in 0..<3 {
            if let t = try? Reg.begin(profile: "work", kind: .inbox, rawValue: "r@x.test", paths: p) { t.abort() }
        }
        check("a live writer's pending entry is never expired", record(p, "health")?.bot.pending?.txId == live.txId)
        check("…and still blocks others", (try? Reg.begin(profile: "work", kind: .bot, rawValue: "600:W", paths: p)) == nil)
        live.abort()
        check("abort removes only its own pending", record(p, "health")?.bot.pending == nil)
    }

    func reconcileSection() {
        let p = tempRegistry("rec")
        seed(p)
        check("startup: own current value → allowed", Reg.reconcile(profile: "default", kind: .bot, read: { "100:A" }, paths: p) == .allowed)
        check("startup: a free new value is adopted", Reg.reconcile(profile: "work", kind: .bot, read: { "700:W" }, paths: p) == .allowed
              && record(p, "work")?.bot.current == Reg.digest(.bot, "700:W"))
        if case .conflict(let m) = Reg.reconcile(profile: "health", kind: .bot, read: { "700:H" }, paths: p) {
            check("startup: a bot another assistant holds is refused (no polling)", m.contains("‘Work’") && m.contains("BotFather"), m)
        } else { check("startup: a bot another assistant holds is refused (no polling)", false) }
        check("startup: health's record unchanged after the refusal", record(p, "health")?.bot.current == nil)
        check("startup: an emptied value frees the reservation", Reg.reconcile(profile: "work", kind: .bot, read: { nil }, paths: p) == .allowed
              && record(p, "work")?.bot.current == nil)
        check("…which another assistant may then use", Reg.reconcile(profile: "health", kind: .bot, read: { "700:H" }, paths: p) == .allowed)
        check("inbox adopted and duplicate refused", Reg.reconcile(profile: "work", kind: .inbox, read: { "W@X.test" }, paths: p) == .allowed
              && { if case .conflict = Reg.reconcile(profile: "health", kind: .inbox, read: { "w@x.TEST" }, paths: p) { return true }; return false }())
        if case .conflict = Reg.reconcile(profile: "ghost", kind: .bot, read: { "9:G" }, paths: p) {
            check("an unregistered extra may not poll", true)
        } else { check("an unregistered extra may not poll", false) }
        // Own live transaction with the same value → wait, not adopt.
        guard let tx = try? Reg.begin(profile: "health", kind: .inbox, rawValue: "h@x.test", paths: p) else { check("begin inbox", false); return }
        if case .busy = Reg.reconcile(profile: "health", kind: .inbox, read: { "h@x.test" }, paths: p) {
            check("startup waits for its own live change", true)
        } else { check("startup waits for its own live change", false) }
        tx.abort()
        // A dead writer that already wrote the secret: adopted.
        let dead = UUID().uuidString.lowercased()
        _ = try? Reg.withLock(p) { doc in
            guard var d = doc, let i = d.index("health") else { return }
            d.records[i].activeTx["inbox"] = .init(txId: dead, phase: "reserving")
            d.records[i].inbox.pending = .init(value: Reg.digest(.inbox, "z@x.test")!, txId: dead)
            doc = d
        }
        check("a crashed writer's committed secret is adopted at startup",
              Reg.reconcile(profile: "health", kind: .inbox, read: { "z@x.test" }, paths: p) == .allowed
              && record(p, "health")?.inbox.current == Reg.digest(.inbox, "z@x.test") && record(p, "health")?.activeTx["inbox"] == nil)
        // Default without a record (registry made by hand): recreated, never refused.
        let q = tempRegistry("nodefault")
        try? PrivateStorage.ensureDirectory(q.root, mode: 0o700)
        try? Reg.write(.init(version: 1, records: [Reg.newRecord(name: "work", displayName: "Work")]), q)
        check("default without a record is recreated", Reg.reconcile(profile: "default", kind: .bot, read: { "1:D" }, paths: q) == .allowed
              && record(q, "default")?.displayName == "Bree")
    }

    func signInSection() {
        let url = root.appendingPathComponent("signin-test.lock")
        guard let first = try? SubscriptionLogin.takeSignInLock(url: url) else { check("first sign-in takes the lock", false); return }
        check("first sign-in takes the lock", true)
        do { _ = try SubscriptionLogin.takeSignInLock(url: url); check("second concurrent sign-in refused", false) }
        catch { check("second concurrent sign-in refused with the message", "\(error)".contains("Another assistant is signing in"), "\(error)") }
        first.release()
        check("free again after the first ends", (try? SubscriptionLogin.takeSignInLock(url: url)) != nil)
        // Across processes: a child holding the machine lock makes us busy.
        check("probe: held lease is live, free lease is dead", {
            guard case .acquired(let l) = ProfileFileLock.take(url) else { return false }
            let live = ProfileFileLock.probe(url) == .live
            l.release()
            return live && ProfileFileLock.probe(url) == .dead
                && ProfileFileLock.probe(root.appendingPathComponent("missing.lock")) == .dead
        }())
    }
}
