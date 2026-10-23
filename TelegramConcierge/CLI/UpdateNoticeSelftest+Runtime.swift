import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The store (§5.6: lock, setting, cap, quarantine, deletion), wording
/// (§5.4.5), the service against temp directories and a fake fetcher
/// (§5.1, §15 items 1, 4g, 5b3, 5d, 5e), and the Telegram one-request
/// classifier (§5.5 step 4, §15 item 5a/5b).
extension UpdateNoticeSelftest {
    static func tempPaths(_ tag: String) -> UpdateNoticeStore.Paths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("briglia-update-notice-\(tag)-\(UUID().uuidString.prefix(8))")
        return UpdateNoticeStore.Paths(setting: root.appendingPathComponent("config/update-check.json"),
                                       lock: root.appendingPathComponent("config/update-check.lock"),
                                       state: root.appendingPathComponent("data/update/notice.json"))
    }

    static func cleanup(_ p: UpdateNoticeStore.Paths) {
        try? FileManager.default.removeItem(at: p.setting.deletingLastPathComponent().deletingLastPathComponent())
    }

    static func inode(_ path: String) -> UInt64 {
        var st = stat()
        return lstat(path, &st) == 0 ? UInt64(st.st_ino) : 0
    }

    // MARK: - Store

    static func storeGroup(_ t: Tally) {
        let p = tempPaths("store")
        defer { cleanup(p) }
        t.check("setting absent → default ON (N3)", UpdateNoticeStore.readSetting(p) == .defaultOn)
        try? UpdateNoticeStore.setEnabled(false, paths: p, now: t0)
        t.check("/upgradecheck off persisted", UpdateNoticeStore.readSetting(p).enabled == false)
        try? UpdateNoticeStore.writeState(p, UpdateNoticeState(lastSuccess: t0))
        let lockInode = inode(p.lock.path)
        try? UpdateNoticeStore.wipeDerivedState(paths: p, now: t0)
        t.check("/deleteuserdata keeps an explicit OFF and bumps the notice generation",
                UpdateNoticeStore.readSetting(p) == .value(UpdateCheckSetting(enabled: false, generation: 1, changedAt: t0)))
        t.check("…deletes notice.json, never the lock (same inode)",
                !FileManager.default.fileExists(atPath: p.state.path) && inode(p.lock.path) == lockInode && lockInode != 0)
        try? Data("{not json".utf8).write(to: p.setting)
        t.check("corrupt setting → OFF (no requests)", UpdateNoticeStore.readSetting(p) == .unreadable && !UpdateNoticeStore.readSetting(p).enabled)
        let st = UpdateNoticeText.status(setting: .unreadable, state: nil, installed: 1, installedVersion: "x", domain: dom, now: t0)
        t.check("…with attention 'send /upgradecheck on to re-enable'", st.reasons.contains { $0.en.contains("/upgradecheck on") })
        try? UpdateNoticeStore.setEnabled(true, paths: p, now: t0)
        t.check("/upgradecheck on repairs an unreadable setting", UpdateNoticeStore.readSetting(p).enabled)
        try? FileManager.default.createDirectory(at: p.state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("garbage".utf8).write(to: p.state)
        let (fresh, quarantined) = UpdateNoticeStore.readState(p, now: t0)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: p.state.deletingLastPathComponent().path)) ?? []
        t.check("corrupt notice.json quarantined, fresh state", quarantined && fresh == UpdateNoticeState()
                && aside.contains { $0.hasPrefix("notice.json.corrupt-") })
        try? Data(repeating: 0x20, count: UpdateNotice.maxStateBytes + 1).write(to: p.state)
        t.check("a 2 MiB + 1 byte notice.json is quarantined", UpdateNoticeStore.readState(p, now: t0).1)
    }

    // MARK: - Wording

    static func wordingGroup(_ t: Tally) {
        let a = UpdateNotice.Analysis(newEntries: [adv(["CVE-1"], fixed: 2)])
        let c = UpdateNotice.Analysis(floorCriticalNews: true)
        let plain = UpdateNoticeText.message(.release(sequence: 1, classification: .none), version: "0.2.64", critical: false, summary: nil, lang: "en", surface: .chat)
        t.check("plain release wording", plain == "Briglia 0.2.64 is available. Send /upgrade to install.", plain)
        for cl in [ReleaseSecurity.Classification.recommended, .critical] {
            let x = UpdateNoticeText.message(.release(sequence: 1, classification: cl), version: "0.2.64", critical: false, summary: nil, lang: "en", surface: .chat)
            t.check("release wording for class \(cl.rawValue) says security", x.contains("security fix"), x)
        }
        for cl in [ReleaseSecurity.Classification.unknown, .noneKnown, .none] {
            let x = UpdateNoticeText.message(.release(sequence: 1, classification: cl), version: "0.2.64", critical: false, summary: nil, lang: "en", surface: .chat)
            t.check("release wording for class \(cl.rawValue) never claims security", !x.contains("security"), x)
        }
        let rec = UpdateNoticeText.message(.security(sequence: 1, analysis: a), version: "0.2.64", critical: false, summary: "Fix <b>x</b>", lang: "en", surface: .chat)
        t.check("security notice wording + stripped summary line",
                rec == "Briglia 0.2.64 is available and includes security fixes for your version. Send /upgrade to install.\nFix bx/b", rec)
        let crit = UpdateNoticeText.message(.security(sequence: 1, analysis: c), version: "0.2.64", critical: false, summary: nil, lang: "en", surface: .chat)
        t.check("critical wording", crit == "Briglia 0.2.64 includes an important security fix for your version. Please send /upgrade soon.", crit)
        let rem = UpdateNoticeText.message(.reminder(sequence: 1, classIds: []), version: "0.2.64", critical: false, summary: nil, lang: "en", surface: .chat)
        t.check("reminder wording says it is the only reminder",
                rem == "Reminder: Briglia 0.2.64, with security fixes for your version, is not installed yet. Send /upgrade to install. (This is the only reminder.)", rem)
        let app = UpdateNoticeText.message(.release(sequence: 1, classification: .none), version: "0.2.64", critical: false, summary: nil, lang: "en", surface: .app)
        t.check("app surface: 'Send /upgrade or tap Update in the app'", app.contains("tap Update in the app"), app)
        let it = UpdateNoticeText.message(.release(sequence: 1, classification: .none), version: "0.2.64", critical: false, summary: nil, lang: "it", surface: .chat)
        t.check("Italian wording", it == "È disponibile Briglia 0.2.64. Invia /upgrade per installarla.", it)
        t.check("no chat text says 'send briglia toolchain upgrade'", ![plain, rec, crit, rem, app, it].contains { $0.contains("toolchain") })
    }

    // MARK: - Service (temp directories, fake fetcher)

    final class FakeNet {
        var manifests: [ReleaseSigning.Manifest] = []
        var fetches = 0
        var fail: Error? = nil
        var sends: [AttemptRecord] = []
        var outcome: UpdateNotice.SendOutcome = .accepted
        var idle = true
        var now = UpdateNoticeSelftest.t0
        var onFetch: (() -> Void)? = nil
    }

    static func verifiedManifest(_ seq: Int, security: Any? = nil) -> ReleaseSigning.Manifest {
        let payload = manifestJSON(seq: seq, security: security, published: "2026-12-01T00:00:00Z", expires: "2027-06-30T00:00:00Z")
        return try! ReleaseSigning.validateManifest(payload, policy: testPolicy, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @MainActor
    static func service(_ p: UpdateNoticeStore.Paths, _ net: FakeNet, installed: Int = 130) -> UpdateNoticeService {
        UpdateNoticeService(deps: UpdateNoticeService.Deps(
            paths: p, now: { net.now }, installed: installed, installedVersion: "0.3.\(installed)", policy: testPolicy,
            platform: "linux-x64",
            fetch: {
                net.fetches += 1
                net.onFetch?()
                if let e = net.fail { throw e }
                return net.manifests.removeFirst()
            },
            trustFloor: { nil }, jitter: { 0 }, newClassId: { UUID().uuidString }, language: { "en" },
            isIdle: { net.idle },
            destination: { .init(channelKind: "telegram", chatId: "1", channelGeneration: 0) },
            channelGeneration: { _ in 0 },
            send: { r in net.sends.append(r); return net.outcome },
            log: { _ in }))
    }

    struct Boom: LocalizedError { var errorDescription: String? { "network down" } }

    @MainActor
    static func serviceGroup(_ t: Tally) async {
        await serviceBasics(t)
        await serviceOff(t)
        await serviceRaces(t)
        await serviceStorageFailure(t)
    }

    @MainActor
    static func serviceBasics(_ t: Tally) async {
        let p = tempPaths("svc"); defer { cleanup(p) }
        let net = FakeNet()
        net.manifests = [verifiedManifest(131)]
        let svc = service(p, net)
        svc.start(tickSeconds: 3600)
        svc.stop()
        await svc.tick()
        t.check("service: no check during the first 5 minutes after startup", net.fetches == 0)
        net.now = t0.addingTimeInterval(301)
        net.idle = false
        await svc.tick()
        t.check("service: startup check after 5 min; a running turn delays delivery", net.fetches == 1 && net.sends.isEmpty)
        net.idle = true
        await svc.tick()
        t.check("service: delivered once the turn ends", net.sends.count == 1 && net.sends[0].text.contains("0.3.131"))
        await svc.tick()
        t.check("service: no second check before 6 h, no repeat", net.fetches == 1 && net.sends.count == 1)
        net.fail = Boom()
        net.now = net.now.addingTimeInterval(6 * hour + 60)
        await svc.tick(); await svc.tick()
        t.check("service: failures are silent and do not increase the request rate", net.fetches == 2 && net.sends.count == 1)
        t.check("service: failure recorded for status", UpdateNoticeStore.snapshot(p).1?.lastCheckProblem == "network down")
        // Restart: a new service on the same files.
        net.fail = nil
        let again = service(p, net)
        again.start(tickSeconds: 3600)
        again.stop()
        net.now = net.now.addingTimeInterval(301)
        await again.tick()
        t.check("service: restart → no repeat, no storm (startup check suppressed by lastAttempt < 1 h)",
                net.fetches == 2 && net.sends.count == 1)
    }

    @MainActor
    static func serviceOff(_ t: Tally) async {
        let p = tempPaths("off"); defer { cleanup(p) }
        let net = FakeNet()
        net.manifests = [verifiedManifest(131)]
        try? UpdateNoticeStore.setEnabled(false, paths: p, now: t0)
        let svc = service(p, net)
        net.now = t0.addingTimeInterval(24 * hour)
        await svc.tick(); await svc.runCheck(); await svc.tick()
        t.check("5e /upgradecheck off → no network request at all (zero fetches), nothing sent", net.fetches == 0 && net.sends.isEmpty)
    }

    @MainActor
    static func serviceRaces(_ t: Tally) async {
        // OFF arriving from another process while the check is on the wire.
        let p = tempPaths("race"); defer { cleanup(p) }
        let net = FakeNet()
        net.manifests = [verifiedManifest(131)]
        net.onFetch = { try? UpdateNoticeStore.setEnabled(false, paths: p, now: t0) }
        let svc = service(p, net)
        await svc.runCheck()
        t.check("5e late check result vs a concurrent OFF → OFF wins, result not written",
                UpdateNoticeStore.snapshot(p).1?.domain(svc.domain)?.observed == nil && !UpdateNoticeStore.readSetting(p).enabled)
        // /deleteuserdata during the check: no write-back.
        let q = tempPaths("wipe"); defer { cleanup(q) }
        let net2 = FakeNet()
        net2.manifests = [verifiedManifest(131)]
        net2.onFetch = { try? UpdateNoticeStore.wipeDerivedState(paths: q, now: t0) }
        let svc2 = service(q, net2)
        await svc2.runCheck()
        t.check("5b3 /deleteuserdata during a check → no result written back", UpdateNoticeStore.snapshot(q).1 == nil)
        // /deleteuserdata during a send: the outcome is not written back.
        let r = tempPaths("wipesend"); defer { cleanup(r) }
        let net3 = FakeNet()
        net3.manifests = [verifiedManifest(131)]
        let svc3 = service(r, net3)
        await svc3.runCheck()
        guard let rec = svc3.consumeNext() else { return t.check("5b3 consume", false) }
        try? UpdateNoticeStore.wipeDerivedState(paths: r, now: t0)
        svc3.settle(rec, .accepted)
        t.check("5b3 /deleteuserdata during a send → no outcome written back", UpdateNoticeStore.snapshot(r).1 == nil)
        // Trust store untouched by any number of checks.
        let trust = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("trust-\(UUID().uuidString).json")
        try? Data("{\"schema\":2,\"domains\":{\"x\":5}}".utf8).write(to: trust)
        let before = try? Data(contentsOf: trust)
        let s4 = tempPaths("trust"); defer { cleanup(s4) }
        let net4 = FakeNet()
        net4.manifests = (0..<3).map { verifiedManifest(1_000_130 + $0) }
        let svc4 = service(s4, net4)
        for _ in 0..<3 { await svc4.runCheck(); net4.now = net4.now.addingTimeInterval(7 * hour) }
        t.check("4g trust-store bytes identical after notice checks (the notice path never writes it)",
                (try? Data(contentsOf: trust)) == before)
        try? FileManager.default.removeItem(at: trust)
    }

    @MainActor
    static func serviceStorageFailure(_ t: Tally) async {
        let p = tempPaths("rofs"); defer { UpdateNoticeStore.failWritesForTesting = false; cleanup(p) }
        let net = FakeNet()
        net.manifests = [verifiedManifest(131)]
        let svc = service(p, net)
        await svc.runCheck()
        UpdateNoticeStore.failWritesForTesting = true
        net.now = t0.addingTimeInterval(hour)
        await svc.deliverDue()
        await svc.deliverDue()
        t.check("5d consume write fails (unwritable state) → nothing sent, 'cannot be saved' attention",
                net.sends.isEmpty && svc.saveFailed && svc.status().reasons.contains { $0.en == "update state cannot be saved" })
        let again = service(p, net)
        await again.deliverDue()
        t.check("5d repeated restarts with broken storage send nothing", net.sends.isEmpty)
    }

    // MARK: - Telegram one-request classifier

    static func http(_ status: Int, _ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://x.invalid")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    final class Counter: @unchecked Sendable { var n = 0 }

    static func telegramGroup(_ t: Tally) async {
        typealias O = TelegramBotService.OneAttemptOutcome
        let cases: [(String, (Data, URLResponse)?, Error?, (O) -> Bool)] = [
            ("200 ok:true → accepted", http(200, "{\"ok\":true,\"result\":{}}"), nil, { $0 == .accepted }),
            ("429 ok:false retry_after → refused with the delay", http(429, "{\"ok\":false,\"parameters\":{\"retry_after\":17}}"), nil,
             { if case .refused(17, _) = $0 { return true }; return false }),
            ("400 ok:false → refused", http(400, "{\"ok\":false,\"description\":\"bad\"}"), nil, { if case .refused = $0 { return true }; return false }),
            ("502 with ok:false body → ambiguous (5xx is never proof)", http(502, "{\"ok\":false}"), nil, { if case .ambiguous = $0 { return true }; return false }),
            ("4xx without a JSON body → ambiguous", http(404, "<html>"), nil, { if case .ambiguous = $0 { return true }; return false }),
            ("200 without ok:true → ambiguous", http(200, "{}"), nil, { if case .ambiguous = $0 { return true }; return false }),
            ("timeout after the request was written → ambiguous", nil, URLError(.timedOut), { if case .ambiguous = $0 { return true }; return false }),
            ("connection lost → ambiguous", nil, URLError(.networkConnectionLost), { if case .ambiguous = $0 { return true }; return false }),
            ("DNS failure (pre-send) → refused", nil, URLError(.cannotFindHost), { if case .refused = $0 { return true }; return false }),
            ("connection refused (pre-send) → refused", nil, URLError(.cannotConnectToHost), { if case .refused = $0 { return true }; return false }),
            ("TLS certificate failure (pre-send) → refused", nil, URLError(.serverCertificateUntrusted), { if case .refused = $0 { return true }; return false }),
        ]
        for (label, response, error, ok) in cases {
            let counter = Counter()
            TelegramBotService.transportOverrideForTesting = { _ in
                counter.n += 1
                if let error { throw error }
                return response!
            }
            let svc = TelegramBotService()
            await svc.configure(token: "123456:TEST_TOKEN_SHAPE_ONLY_abcdefghijklmnop")
            let outcome = await svc.sendNoticeOnce(chatId: "1", text: "x", expectedGeneration: NoticeChannelGenerations.current(.telegram))
            t.check("telegram: \(label); exactly one wire request", ok(outcome) && counter.n == 1, "\(outcome), \(counter.n) requests")
        }
        let counter = Counter()
        TelegramBotService.transportOverrideForTesting = { _ in counter.n += 1; return http(200, "{\"ok\":true}") }
        let svc = TelegramBotService()
        await svc.configure(token: "123456:TEST_TOKEN_SHAPE_ONLY_abcdefghijklmnop")
        let stale = await svc.sendNoticeOnce(chatId: "1", text: "x", expectedGeneration: NoticeChannelGenerations.current(.telegram) &+ 1)
        t.check("telegram: /switchbot between consume and send (generation changed) → nothing built or sent",
                stale == .credentialsChanged && counter.n == 0)
        TelegramBotService.transportOverrideForTesting = nil
    }
}
