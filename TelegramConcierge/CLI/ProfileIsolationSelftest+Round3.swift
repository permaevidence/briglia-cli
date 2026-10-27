import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Codex stage-1 round 2 (R2, R5): a `/switchbot` discovery excludes the
/// first `profiles add` for its whole lifetime and gates its acknowledgment;
/// a changed-setting refusal never releases a reservation.
extension ProfileHarness {
    func round3Section() {
        discoveryExcludesFirstAdd()
        acknowledgmentIsGated()
        changedSettingKeepsReservation()
    }

    /// Runs an async body to completion from this synchronous harness.
    private func blocking<T>(_ body: @escaping () async -> T) -> T {
        let box = Round3Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = await body(); done.signal() }
        done.wait()
        return box.value!
    }

    private static let codeBatch = #"{"ok":true,"result":[{"update_id":42,"message":{"chat":{"id":10,"type":"private"},"from":{"id":10,"is_bot":false,"first_name":"New"},"text":"123456"}}]}"#

    /// R2 end to end: never-multi default starts discovery of bot 777; while
    /// the first long poll is outstanding a real `briglia profiles add`
    /// process tries to create the registry and reserve 777 for Work, then the
    /// poll returns the code. The add must be refused (no registry, no
    /// competing owner) and discovery finishes normally (acknowledgment sent,
    /// since the install is still never-multi). After the switch drops the
    /// lock, the same add succeeds and default may no longer scan 777.
    private func discoveryExcludesFirstAdd() {
        let data = root.appendingPathComponent("r3-data"), config = root.appendingPathComponent("r3-config")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let childEnv = ["XDG_DATA_HOME": data.path, "XDG_CONFIG_HOME": config.path]
        let machine = data.appendingPathComponent("briglia/machine", isDirectory: true)
        let lockURL = machine.appendingPathComponent("identity-tx.lock")
        let regPaths = Reg.Paths(root: data.appendingPathComponent(AssistantProfile.sharedDirName, isDirectory: true))
        let token = "777:NEWBOT"
        let addArgs = ["profiles", "add", "work", "--name", "Work", "--home", root.appendingPathComponent("r3-home").path,
                       "--bot-token-stdin"]

        var held: ProfileFileLock?
        switch BotSwitchDiscovery.admit(token: token, profile: "default", lockURL: lockURL,
                                        ensureLockDir: { try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true) },
                                        paths: regPaths) {
        case .admitted(let lock): held = lock
        case .refused(let why): check("never-multi default may start discovery", false, why); return
        }
        check("never-multi default holds machine/identity-tx.lock for the switch", held != nil)

        var requests: [String] = []
        var addDuringDiscovery = Run(status: -1, out: "")
        var registryDuringDiscovery = true
        let outcome = blocking { () async -> (BotSwitchFlow.DiscoveredChat?, String?) in
            await BotSwitchDiscovery.run(
                token: token, code: "123456", deadline: Date().addingTimeInterval(30),
                refusal: { AssistantRegistry.telegramDiscoveryRefusal(profile: "default", token: token, paths: regPaths) },
                getUpdates: { _, offset, timeout in
                    requests.append("offset=\(offset)&timeout=\(timeout)")
                    if requests.count == 1 {
                        addDuringDiscovery = self.run(addArgs, extraEnv: childEnv, stdin: token + "\n")
                        registryDuringDiscovery = FileManager.default.fileExists(atPath: regPaths.registry.path)
                        return (200, Data(Self.codeBatch.utf8))
                    }
                    return (200, Data(#"{"ok":true,"result":[]}"#.utf8))
                }, backoffNanoseconds: 1_000_000)
        }
        check("first add during discovery is refused", addDuringDiscovery.status != 0
              && addDuringDiscovery.out.contains("finish the bot or email change"), addDuringDiscovery.out)
        check("…and no registry (no competing owner) was created", !registryDuringDiscovery)
        check("discovery still finds the code (never-multi unchanged)", outcome.0?.chatId == 10, "\(outcome)")
        check("…with exactly the poll and its acknowledgment", requests == ["offset=0&timeout=20", "offset=43&timeout=0"], "\(requests)")
        held?.release(); held = nil                            // the switch ends: the lock is dropped

        let addAfter = run(addArgs, extraEnv: childEnv, stdin: token + "\n")
        check("after the switch ends the same add succeeds", addAfter.status == 0, addAfter.out)
        check("…and Work now holds bot 777", record(regPaths, "work")?.bot.current == Reg.digest(.bot, token)
              || record(regPaths, "work")?.bot.pending?.value == Reg.digest(.bot, token))
        let again = BotSwitchDiscovery.admit(token: token, profile: "default", lockURL: lockURL,
                                             ensureLockDir: {}, paths: regPaths)
        check("default may no longer start discovery of Work's bot", { if case .refused = again { return true }; return false }())
    }

    /// R2: a registry that assigns the bot to another assistant while the
    /// long poll is outstanding stops the acknowledgment (zero further requests).
    private func acknowledgmentIsGated() {
        let p = tempRegistry("ack-gate")
        let token = "888:LATE"
        var requests: [String] = []
        let outcome = blocking { () async -> (BotSwitchFlow.DiscoveredChat?, String?) in
            await BotSwitchDiscovery.run(
                token: token, code: "123456", deadline: Date().addingTimeInterval(30),
                refusal: { AssistantRegistry.telegramDiscoveryRefusal(profile: "default", token: token, paths: p) },
                getUpdates: { _, offset, timeout in
                    requests.append("offset=\(offset)&timeout=\(timeout)")
                    self.seed(p, defaultBot: "100:A", extras: ["work"])
                    var doc = (try? Reg.read(p)) ?? nil
                    if let i = doc?.index("work") { doc?.records[i].bot.current = Reg.digest(.bot, token) }
                    if let doc { try? Reg.write(doc, p) }
                    return (200, Data(Self.codeBatch.utf8))
                }, backoffNanoseconds: 1_000_000)
        }
        check("acknowledgment refused once another assistant holds the bot", requests == ["offset=0&timeout=20"], "\(requests)")
        check("…discovery ends as a refusal naming the owner", outcome.0 == nil && outcome.1?.contains("‘Work’") == true, "\(outcome)")
    }

    /// R5: when the persisted setting changed between the caller's read and
    /// the locked reread, the channel is refused WITHOUT touching this
    /// assistant's reservation, so another assistant is still refused.
    private func changedSettingKeepsReservation() {
        for kind in [Reg.Kind.bot, .inbox] {
            let p = tempRegistry("changed-\(kind.rawValue)")
            seed(p, defaultBot: "100:A", extras: ["work"])
            let held = kind == .bot ? "123:FAKE" : "work@example.test"
            let newer = kind == .bot ? "456:FAKE" : "work2@example.test"
            var doc = (try? Reg.read(p)) ?? nil
            if let i = doc?.index("work") {
                var slot = doc!.records[i].slot(kind); slot.current = Reg.digest(kind, held); doc!.records[i].setSlot(kind, slot)
            }
            if let doc { try? Reg.write(doc, p) }
            let before = FileManager.default.contents(atPath: p.registry.path)
            let allowed = ConversationManager.registryAllowsChannel(kind, value: held, profile: "work", paths: p, load: { _ in newer })
            check("\(kind.rawValue): changed setting refuses the channel", !allowed)
            check("\(kind.rawValue): …and keeps this assistant's reservation", record(p, "work")?.slot(kind).current == Reg.digest(kind, held))
            check("\(kind.rawValue): …registry file unchanged", FileManager.default.contents(atPath: p.registry.path) == before)
            let other = Reg.reconcile(profile: "default", kind: kind, read: { held }, paths: p)
            check("\(kind.rawValue): …another assistant is still refused that value", { if case .conflict = other { return true }; return false }(), "\(other)")
            let same = ConversationManager.registryAllowsChannel(kind, value: held, profile: "work", paths: p, load: { _ in held })
            check("\(kind.rawValue): an unchanged setting is still allowed", same)
        }
    }
}

private final class Round3Box<T> { var value: T? }
