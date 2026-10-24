import Foundation

/// Mutable clock / channel for the service traces.
@MainActor
final class LTWorld {
    var now = LTF.now
    var list: Data
    var resolutions: [LocalTools.Resolution]
    var outcome: UpdateNotice.SendOutcome = .accepted
    var sent: [String] = []
    var fetches = 0
    var idle = true
    var fetchError = false
    var duringFetch: (() -> Void)?
    /// Changes the inventory between derivation and the pre-send probe.
    var afterFirstInventory: (() -> Void)?
    private var inventoryCalls = 0
    let root: URL
    let paths: LocalAdvisoryStore.Paths

    init(_ name: String, list: Data, resolutions: [LocalTools.Resolution]) {
        root = LTF.tempDir(name)
        paths = LTF.paths(root)
        self.list = list
        self.resolutions = resolutions
    }

    func service(policy: AdvisoryPolicy = LTF.policy) -> LocalToolsService {
        LocalToolsService(deps: LocalToolsService.Deps(
            paths: paths, now: { self.now }, policy: policy,
            fetch: {
                self.fetches += 1
                if let f = self.duringFetch { f() }
                if self.fetchError { throw URLError(.notConnectedToInternet) }
                return self.list
            },
            inventory: {
                self.inventoryCalls += 1
                let r = self.resolutions
                if self.inventoryCalls == 1, let f = self.afterFirstInventory { f(); self.afterFirstInventory = nil }
                return r
            },
            language: { "en" }, isIdle: { self.idle },
            destination: { UpdateNotice.Destination(channelKind: "telegram", chatId: "1", channelGeneration: 0) },
            channelGeneration: { _ in 0 },
            send: { _, _, _, text in self.sent.append(text); return self.outcome },
            log: { _ in }))
    }

    func vuln() -> LocalVulnState? { LocalAdvisoryStore.snapshot(paths).1 }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

extension LocalToolsSelftest {
    static var affectedList: Data {
        LTF.envelope(LTF.payload(coverage: LTF.covAll("deb:debian:12:ffmpeg"), entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"])])]))
    }

    static func storeGroup(_ t: Tally) {
        let root = LTF.tempDir("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = LTF.paths(root)
        do {
            try LocalAdvisoryStore.transaction(p, now: LTF.now) { _, obs, v in
                obs.lastAttempt = LTF.now
                v.rows = []
                v.saturated = Saturation(since: LTF.now, droppedCount: 1)
            }
            let (o, v) = LocalAdvisoryStore.snapshot(p)
            t.check("store: both files written under update/ (mode 0600)",
                    o?.lastAttempt != nil && v?.saturated != nil
                        && ((try? FileManager.default.attributesOfItem(atPath: p.localvuln.path))?[.posixPermissions] as? Int) == 0o600)
            LocalAdvisoryStore.failWritesForTesting = true
            var threw = false
            do { try LocalAdvisoryStore.transaction(p, now: LTF.now) { _, _, v in v.saturated = nil } } catch { threw = true }
            LocalAdvisoryStore.failWritesForTesting = false
            t.check("store: a failed write throws (callers send nothing)", threw && LocalAdvisoryStore.snapshot(p).1?.saturated != nil)
            try Data("{not json".utf8).write(to: p.localvuln)
            try LocalAdvisoryStore.transaction(p, now: LTF.now) { _, _, _ in }
            let aside = (try? FileManager.default.contentsOfDirectory(atPath: p.localvuln.deletingLastPathComponent().path))?
                .contains { $0.hasPrefix("localvuln.json.corrupt-") } ?? false
            t.check("store: a corrupt localvuln.json is quarantined, fresh state", aside)
            var huge = LocalVulnState()
            huge.report = LocalToolsSnapshot(evaluatedAt: LTF.now, listSequence: 1, listContentId: "c",
                                             reports: (0..<3000).map { _ in report() })
            t.check("store: writer refuses above the 512 KiB cap",
                    (try? LocalAdvisoryStore.write(huge, to: p.localvuln, maxBytes: LocalAdvisoryStore.maxLocalVulnBytes)) == nil)
            // /deleteuserdata: notice.json, localvuln.json and the observation file.
            try PrivateStorage.ensureDirectoryScoped(p.notice.state.deletingLastPathComponent())
            try Data("{}".utf8).write(to: p.notice.state)
            try LocalAdvisoryStore.transaction(p, now: LTF.now) { _, obs, _ in obs.lastSuccess = LTF.now }
            try UpdateNoticeStore.setEnabled(false, paths: p.notice, now: LTF.now)
            try UpdateNoticeStore.wipeDerivedState(paths: p.notice, now: LTF.now)
            let fm = FileManager.default
            t.check("wipe: deletes notice.json, localvuln.json and advisory-list.json",
                    !fm.fileExists(atPath: p.notice.state.path) && !fm.fileExists(atPath: p.localvuln.path) && !fm.fileExists(atPath: p.observation.path))
            let setting = UpdateNoticeStore.readSetting(p.notice)
            t.check("wipe: bumps the shared generation and keeps an explicit OFF", setting.generation == 1 && !setting.enabled)
        } catch {
            t.check("store: transactions", false, "\(error)")
        }
    }

    @MainActor
    static func serviceGroup(_ t: Tally) async {
        // Not provisioned: nothing fetched.
        let np = LTWorld("np", list: affectedList, resolutions: [.present(LTF.debInstance())])
        let placeholder = AdvisoryPolicy(keys: AdvisoryKeys.active, domain: LocalAdvisory.domainString, url: LTF.policy.url)
        let nps = np.service(policy: placeholder)
        await nps.tick(afterCheck: true)
        t.check("service: placeholder key → no fetch, no evaluation, no message", np.fetches == 0 && np.sent.isEmpty && nps.evaluations == 0)
        let npStatus = LocalToolsText.status(setting: .defaultOn, policy: placeholder, observation: nil, vuln: nil, now: LTF.now)
        t.check("service: placeholder key → status 'not available yet', no attention", npStatus.part.contains("not available yet") && npStatus.reasons.isEmpty)
        np.cleanup()

        // Happy path: one fetch inside the check window, one message, then silence.
        let w = LTWorld("happy", list: affectedList, resolutions: [.present(LTF.debInstance()), .absent(toolId: "pandoc")])
        let s = w.service()
        await s.tick(afterCheck: false)
        t.check("service: no fetch outside the update-check window", w.fetches == 0)
        await s.tick(afterCheck: true)
        t.check("service: one fetch in the window → one message", w.fetches == 1 && w.sent.count == 1, "\(w.fetches) \(w.sent)")
        t.check("service: message names the tool and the local command", w.sent.first?.contains("sudo apt-get install --only-upgrade ffmpeg libavcodec59") == true)
        await s.tick(afterCheck: true)
        t.check("service: fetched at most once a day", w.fetches == 1)
        w.now = w.now.addingTimeInterval(7 * 3600)
        await s.tick(afterCheck: false)
        t.check("service: re-evaluation of an unchanged version is silent", w.sent.count == 1)
        w.now = w.now.addingTimeInterval(24 * 3600)
        w.resolutions = [.present(LTF.debInstance(asOf: w.now)), .absent(toolId: "pandoc")]
        await s.tick(afterCheck: true)
        t.check("service: next day one more fetch, still no repeat", w.fetches == 2 && w.sent.count == 1)
        let st = LocalToolsText.status(setting: .defaultOn, policy: LTF.policy, observation: LocalAdvisoryStore.snapshot(w.paths).0,
                                       vuln: w.vuln(), now: w.now)
        t.check("status: affected tool → attention with the command",
                st.reasons.contains { $0.en.contains("apt-get install --only-upgrade ffmpeg") }, "\(st)")
        w.cleanup()

        // OFF: no fetch, no message.
        let off = LTWorld("off", list: affectedList, resolutions: [.present(LTF.debInstance())])
        try? UpdateNoticeStore.setEnabled(false, paths: off.paths.notice, now: LTF.now)
        await off.service().tick(afterCheck: true)
        t.check("service: /upgradecheck off → no request, no message", off.fetches == 0 && off.sent.isEmpty)
        off.cleanup()

        // The request is the same for every client: no inventory input reaches it.
        let a = LTWorld("same-a", list: affectedList, resolutions: [])
        await a.service().tick(afterCheck: true)
        t.check("privacy: the fetch takes no package-dependent input (one fixed GET)", a.fetches == 1)
        a.cleanup()

        // Recheck before send: the version changed after derivation → no send.
        let rc = LTWorld("recheck", list: affectedList, resolutions: [.present(LTF.debInstance())])
        rc.afterFirstInventory = { rc.resolutions = [.present(LTF.debInstance(version: "7:5.1.7-0+deb12u1"))] }
        await rc.service().tick(afterCheck: true)
        t.check("service: a version change found by the pre-send probe drops the intent", rc.sent.isEmpty && (rc.vuln()?.rows.isEmpty ?? true))
        rc.cleanup()

        // Consume write failure → nothing sent.
        let wf = LTWorld("writefail", list: affectedList, resolutions: [.present(LTF.debInstance())])
        let wfs = wf.service()
        _ = await wfs.runFetch(); await wfs.evaluate()
        LocalAdvisoryStore.failWritesForTesting = true
        await wfs.deliver()
        LocalAdvisoryStore.failWritesForTesting = false
        t.check("service: consume write failure → nothing sent", wf.sent.isEmpty && wfs.saveFailed)
        wf.cleanup()

        // Ambiguous: never retried, also not after restart.
        let am = LTWorld("ambiguous", list: affectedList, resolutions: [.present(LTF.debInstance())])
        am.outcome = .ambiguous
        await am.service().tick(afterCheck: true)
        am.now = am.now.addingTimeInterval(120)
        let am2 = am.service(); am2.start()
        await am2.tick(afterCheck: false)
        t.check("service: ambiguous outcome never retried (also after restart)", am.sent.count == 1)
        am.cleanup()

        // Refused: retried after retry_after with revalidation; ≤ 3.
        let rf = LTWorld("refused", list: affectedList, resolutions: [.present(LTF.debInstance())])
        rf.outcome = .refused(retryAfter: 30)
        let rfs = rf.service()
        await rfs.tick(afterCheck: true)
        await rfs.tick(afterCheck: false)
        t.check("service: refused → not retried before retry_after", rf.sent.count == 1)
        rf.now = rf.now.addingTimeInterval(31); rf.outcome = .accepted
        await rfs.tick(afterCheck: false)
        t.check("service: refused → retried once, the stored text", rf.sent.count == 2 && rf.sent[0] == rf.sent[1])
        await rfs.tick(afterCheck: false)
        t.check("service: accepted retry ends the attempt", rf.sent.count == 2 && rf.vuln()?.attempt == nil)
        rf.cleanup()

        // R4: refused, then the candidate stops fixing it (still messageable
        // as KEV without a fix): the stored fix command is never resent.
        let kevList = LTF.envelope(LTF.payload(coverage: LTF.covAll("deb:debian:12:ffmpeg"),
                                               entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"], kev: true)])]))
        let r4 = LTWorld("r4", list: kevList, resolutions: [.present(LTF.debInstance())])
        r4.outcome = .refused(retryAfter: 1)
        let r4s = r4.service()
        await r4s.tick(afterCheck: true)
        r4.now = r4.now.addingTimeInterval(2)
        r4.resolutions = [.present(LTF.debInstance(candidate: "7:5.1.6-0+deb12u1", asOf: r4.now))]
        r4.outcome = .accepted
        await r4s.tick(afterCheck: false)
        t.check("R4: a refused notice whose fix is gone is dropped, its command never resent",
                r4.sent.count == 1 && r4.vuln()?.attempt == nil, "\(r4.sent)")
        r4.cleanup()

        // Refused, then the version changed: the retry is dropped.
        let rv = LTWorld("refused-changed", list: affectedList, resolutions: [.present(LTF.debInstance())])
        rv.outcome = .refused(retryAfter: 1)
        let rvs = rv.service()
        await rvs.tick(afterCheck: true)
        rv.now = rv.now.addingTimeInterval(5)
        rv.resolutions = [.present(LTF.debInstance(version: "7:5.1.7-0+deb12u1"))]
        await rvs.tick(afterCheck: false)
        t.check("service: retry revalidation drops a changed key", rv.sent.count == 1 && rv.vuln()?.attempt == nil)
        rv.cleanup()

        // Crash after consume (attempt left in flight) → lost, never resent.
        let cr = LTWorld("crash", list: affectedList, resolutions: [.present(LTF.debInstance())])
        let crs = cr.service()
        _ = await crs.runFetch(); await crs.evaluate()
        _ = try? LocalAdvisoryStore.transaction(cr.paths, now: cr.now) { _, _, v in
            let lines = LocalVuln.proposals(v, reports: v.report!.reports).lines
            LocalVuln.consume(&v, lines, text: "x", listContentId: v.report!.listContentId!, noticeGeneration: 0, destination: dest, now: cr.now)
        }
        let crs2 = cr.service(); crs2.start()
        await crs2.tick(afterCheck: false)
        t.check("service: crash after consume → lost, nothing resent", cr.sent.isEmpty && cr.vuln()?.lastOutcome?.outcome == .lost)
        cr.cleanup()

        // Busy turn: wait; conflict and expiry block messages.
        let busy = LTWorld("busy", list: affectedList, resolutions: [.present(LTF.debInstance())])
        busy.idle = false
        await busy.service().tick(afterCheck: true)
        t.check("service: a running turn defers the message", busy.sent.isEmpty)
        busy.idle = true
        await busy.service().tick(afterCheck: false)
        t.check("service: sent once the turn ended", busy.sent.count == 1)
        busy.cleanup()

        let cf = LTWorld("conflict", list: affectedList, resolutions: [.present(LTF.debInstance())])
        let cfs = cf.service()
        _ = await cfs.runFetch()
        cf.list = LTF.envelope(LTF.payload(coverage: LTF.covAll("deb:debian:12:ffmpeg"), entries: [LTF.debEntry([LTF.adv(["CVE-2099-0009"])])]))
        cf.now = cf.now.addingTimeInterval(25 * 3600 - 7200)
        _ = await cfs.runFetch()
        await cfs.evaluate(); await cfs.deliver()
        t.check("service: same-sequence conflicting list → no message", cf.sent.isEmpty)
        cf.cleanup()

        let ex = LTWorld("expired", list: affectedList, resolutions: [.present(LTF.debInstance())])
        let exs = ex.service()
        _ = await exs.runFetch()
        ex.now = ex.now.addingTimeInterval(80 * 3600)
        ex.fetchError = true
        await exs.tick(afterCheck: true)
        t.check("service: expired list → no message, states unknown",
                ex.sent.isEmpty && ex.vuln()?.report?.reports.first?.state == .unknown)
        ex.cleanup()

        // Deletion while a fetch is in flight: the result is not written back.
        let del = LTWorld("delete", list: affectedList, resolutions: [.present(LTF.debInstance())])
        del.duringFetch = { try? UpdateNoticeStore.wipeDerivedState(paths: del.paths.notice, now: del.now) }
        let recorded = await del.service().runFetch()
        t.check("service: /deleteuserdata during a fetch → its result is not written back",
                !recorded && LocalAdvisoryStore.snapshot(del.paths).0?.lastSuccess == nil)
        del.cleanup()
    }
}
