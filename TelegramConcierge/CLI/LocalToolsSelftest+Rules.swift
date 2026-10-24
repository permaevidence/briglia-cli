import Foundation

extension LocalToolsSelftest {
    static func report(_ tool: String = "ffmpeg", version: String = "7:5.1.6-0+deb12u1", severity: ReleaseSecurity.Level = .recommended,
                       kev: Bool = false, fix: LocalTools.FixState = .installable, ids: [String] = ["CVE-2099-0001"]) -> LocalTools.ToolReport {
        var r = LocalTools.ToolReport(toolId: tool, identityKey: "deb:debian:12:\(tool)", installedVersion: version,
                                      state: fix == .installable ? .affectedFixInstallable : .affectedNoFix)
        r.affected = [LocalTools.AdvisoryResult(ids: ids, primaryId: ids[0], severity: severity, kev: kev,
                                                fixedVersion: "7:5.1.7-0+deb12u1", fix: fix)]
        if fix == .installable { r.action = .apt([tool]) }
        return r
    }

    static let dest = UpdateNotice.Destination(channelKind: "telegram", chatId: "1", channelGeneration: 0)

    static func consumeAll(_ s: inout LocalVulnState, _ reports: [LocalTools.ToolReport], now: Date = LTF.now) -> [LocalVuln.Proposal] {
        let lines = LocalVuln.proposals(s, reports: reports).lines
        if !lines.isEmpty {
            LocalVuln.consume(&s, lines, text: LocalToolsText.message(lines, lang: "en"), listContentId: "c1",
                              noticeGeneration: 0, destination: dest, now: now)
            LocalVuln.recordOutcome(&s, .accepted, now: now)
        }
        return lines
    }

    static func rulesGroup(_ t: Tally) {
        var s = LocalVulnState()
        t.check("V5: a new messaged (identity, version) → one initial line", consumeAll(&s, [report()]).map(\.kind) == [.initial])
        t.check("V5: the next unchanged check is silent", consumeAll(&s, [report()]).isEmpty)
        t.check("V5: same version, new advisory of the same severity → silent",
                consumeAll(&s, [report(ids: ["CVE-2099-0002"])]).isEmpty)
        t.check("V5: recommended → critical is the one escalation", consumeAll(&s, [report(severity: .critical)]).map(\.kind) == [.escalation])
        t.check("V5: a second higher condition (KEV) after the escalation → silent", consumeAll(&s, [report(severity: .critical, kev: true)]).isEmpty)
        // KEV without a fix, then a fix: one follow-up, never a second.
        var k = LocalVulnState()
        _ = consumeAll(&k, [report(kev: true, fix: .noFix(.notYet))])
        t.check("V4/V5: KEV without a fix → recorded kevNoFix", k.rows.first?.communicated.kevNoFix == true)
        t.check("V5 exception: fix becomes installable → one follow-up", consumeAll(&k, [report(kev: true)]).map(\.kind) == [.followUp])
        t.check("V5 exception: never a second follow-up", consumeAll(&k, [report(kev: true)]).isEmpty && k.rows.first?.fixFollowUpSent == true)
        // First warning lost after consume: the follow-up is still eligible.
        var lost = LocalVulnState()
        let l1 = LocalVuln.proposals(lost, reports: [report(kev: true, fix: .noFix(.notYet))]).lines
        LocalVuln.consume(&lost, l1, text: "x", listContentId: "c1", noticeGeneration: 0, destination: dest, now: LTF.now)
        t.check("crash after consume: the in-flight attempt becomes lost, never resent", LocalVuln.settleCrashed(&lost, now: LTF.now) && lost.attempt == nil)
        t.check("crash after consume: the key is not proposed again", LocalVuln.proposals(lost, reports: [report(kev: true, fix: .noFix(.notYet))]).lines.isEmpty)
        t.check("lost first warning: exactly one follow-up still eligible",
                LocalVuln.proposals(lost, reports: [report(kev: true)]).lines.map(\.kind) == [.followUp])
        // Rows leave only on positive evidence.
        var r = LocalVulnState()
        _ = consumeAll(&r, [report()])
        let inst = LTF.debInstance(version: "7:5.1.6-0+deb12u1")
        LocalVuln.reconcile(&r, [.unknown(toolId: "ffmpeg", reason: LocalTools.Text("x", "x"))])
        t.check("rows: a failed probe keeps the row", r.rows.count == 1)
        LocalVuln.reconcile(&r, [.present(inst)])
        t.check("rows: same identity and version keeps the row", r.rows.count == 1)
        var changed = inst
        changed.installedVersion = "7:5.1.7-0+deb12u1"
        LocalVuln.reconcile(&r, [.present(changed)])
        t.check("rows: a changed installed version removes the row", r.rows.isEmpty)
        t.check("V5: the changed version is a new key when still messaged",
                consumeAll(&r, [report(version: "7:5.1.7-0+deb12u1")]).map(\.kind) == [.initial])
        LocalVuln.reconcile(&r, [.absent(toolId: "ffmpeg")])
        t.check("rows: positively absent removes the row", r.rows.isEmpty)
        // R6: two tools share one identity (curl and libcurl from `curl`).
        func curlInst(_ tool: String, _ v: String) -> LocalTools.Instance {
            var i = LTF.debInstance(tool: tool, source: "curl", version: v, binaries: [tool])
            i.toolId = tool
            return i
        }
        var sh = LocalVulnState()
        let both = [report("curl", version: "8.0.0-1"), { var r = report("libcurl", version: "8.0.0-1"); r.identityKey = "deb:debian:12:curl"; return r }()]
        var curlR = both[0]; curlR.identityKey = "deb:debian:12:curl"
        t.check("R6: two tools at one identity/version → one line", consumeAll(&sh, [curlR, both[1]]).count == 1)
        LocalVuln.reconcile(&sh, [.present(curlInst("curl", "8.0.0-1")), .present(curlInst("libcurl", "8.0.0-1"))])
        t.check("R6: the row records both tools", sh.rows.first?.toolIds.sorted() == ["curl", "libcurl"])
        LocalVuln.reconcile(&sh, [.absent(toolId: "curl"), .present(curlInst("libcurl", "8.0.0-1"))])
        t.check("R6: one tool gone while the other still runs that version → row kept", sh.rows.count == 1)
        t.check("R6: …and no second initial notice", consumeAll(&sh, [both[1]]).isEmpty)
        LocalVuln.reconcile(&sh, [.present(curlInst("curl", "8.1.0-1")), .present(curlInst("libcurl", "8.0.0-1"))])
        t.check("R6: partial upgrade of one tool → row kept for the other", sh.rows.count == 1)
        LocalVuln.reconcile(&sh, [.present(curlInst("curl", "8.1.0-1")), .unknown(toolId: "libcurl", reason: LocalTools.Text("x", "x"))])
        t.check("R6: a member unknown → row kept", sh.rows.count == 1)
        LocalVuln.reconcile(&sh, [.present(curlInst("curl", "8.1.0-1")), .absent(toolId: "libcurl")])
        t.check("R6: every member gone or upgraded → row removed", sh.rows.isEmpty)
        // R4: a refused attempt whose fix stopped being installable is dropped.
        var r4 = LocalVulnState()
        let r4l = LocalVuln.proposals(r4, reports: [report(kev: true)]).lines
        LocalVuln.consume(&r4, r4l, text: "x", listContentId: "c1", noticeGeneration: 0, destination: dest, now: LTF.now)
        var stale = report(kev: true, fix: .notInstallable(LocalTools.Text("x", "x")))
        stale.action = nil
        t.check("R4: the stored condition no longer holds (fix gone, still messageable) → retry invalid",
                stale.messageable && !LocalVuln.linesStillValid(r4.attempt!, reports: [stale]))
        // R5: another advisory's fix is not a follow-up for the KEV one.
        var r5 = LocalVulnState()
        func mixed(_ kevFix: LocalTools.FixState, _ otherFix: LocalTools.FixState) -> LocalTools.ToolReport {
            var r = report(kev: true, fix: kevFix)
            r.affected.append(LocalTools.AdvisoryResult(ids: ["CVE-2099-0002"], primaryId: "CVE-2099-0002", severity: .recommended,
                                                        kev: false, fixedVersion: "7:5.1.7-0+deb12u1", fix: otherFix))
            r.action = (kevFix == .installable || otherFix == .installable) ? .apt(["ffmpeg"]) : nil
            return r
        }
        _ = consumeAll(&r5, [mixed(.noFix(.notYet), .noFix(.notYet))])
        let onlyOther = LocalVuln.proposals(r5, reports: [mixed(.noFix(.notYet), .installable)]).lines
        t.check("R5: only the non-KEV advisory gained a fix → no 'fix now available' follow-up",
                !onlyOther.contains { $0.kind == .followUp })
        let real = LocalVuln.proposals(r5, reports: [mixed(.installable, .noFix(.notYet))]).lines
        t.check("R5: the KEV advisory gained a fix → one follow-up", real.map(\.kind) == [.followUp])
        let followText = LocalToolsText.message(real, lang: "en")
        t.check("R5: the follow-up names the KEV advisory it fixes", followText.contains("problem CVE-2099-0001 in ffmpeg"), followText)
        var twoKev = mixed(.installable, .noFix(.notYet)); twoKev.affected[1].kev = true
        let twoText = LocalToolsText.message([LocalVuln.Proposal(key: "k", kind: .followUp, report: twoKev)], lang: "en")
        t.check("R5: a still-unfixed KEV advisory keeps its mitigation in the follow-up",
                twoText.contains("CVE-2099-0002 is also actively exploited") && twoText.contains("avoid processing untrusted files"), twoText)
        let esc = LocalToolsText.message([LocalVuln.Proposal(key: "k", kind: .escalation, report: twoKev)], lang: "en")
        t.check("N16-3: an escalation with a fix still carries the outstanding KEV mitigation",
                esc.contains("apt-get") && esc.contains("avoid processing untrusted files"), esc)
        let initMixed = LocalToolsText.message([LocalVuln.Proposal(key: "k", kind: .initial, report: mixed(.noFix(.notYet), .installable))], lang: "en")
        t.check("N16-3: initial message scopes the fix to the advisory it fixes and keeps the KEV mitigation",
                initMixed.contains("To fix CVE-2099-0002, run:") && initMixed.contains("CVE-2099-0001 is also actively exploited"), initMixed)
        // Not messaged states.
        var unknownRow = report()
        unknownRow.state = .unknown
        unknownRow.affected = []
        unknownRow.reason = LocalTools.Text("x", "x")
        t.check("V4: an unknown state is never proposed", LocalVuln.proposals(LocalVulnState(), reports: [unknownRow]).lines.isEmpty)
        t.check("V4: recommended without a fix is never proposed",
                LocalVuln.proposals(LocalVulnState(), reports: [report(fix: .noFix(.noDsa))]).lines.isEmpty)
        var statusOnly = report()
        statusOnly.statusOnly = LocalTools.Text("ota", "ota")
        t.check("V4: status-only instances (UT rootfs) are never proposed", LocalVuln.proposals(LocalVulnState(), reports: [statusOnly]).lines.isEmpty)
        // Quiet overflow at 256 rows.
        var full = LocalVulnState()
        for i in 0..<256 {
            full.rows.append(LocalVulnRow(key: "k\(i)", identityKey: "x\(i)", toolIds: ["t\(i)"], installedVersion: "1", firstAt: LTF.now,
                                          communicated: LocalVulnCommunicated(floor: false, level: .recommended, kev: false, kevNoFix: false),
                                          escalationUsed: false, fixFollowUpSent: false))
        }
        let over = LocalVuln.proposals(full, reports: [report()])
        t.check("overflow: a 257th key is not proposed and is counted (quiet)", over.lines.isEmpty && over.overflow == 1)
        // Retry policy.
        var a = LocalVulnState()
        let al = LocalVuln.proposals(a, reports: [report()]).lines
        LocalVuln.consume(&a, al, text: "x", listContentId: "c1", noticeGeneration: 0, destination: dest, now: LTF.now)
        var amb = a
        LocalVuln.recordOutcome(&amb, .ambiguous, now: LTF.now)
        t.check("delivery: ambiguous outcome is terminal (no retry)", amb.attempt == nil && amb.lastOutcome?.outcome == .ambiguous)
        LocalVuln.recordOutcome(&a, .refused(retryAfter: 30), now: LTF.now)
        let gen: (String?) -> UInt64 = { _ in 0 }
        t.check("delivery: refused → not yet before retry_after",
                LocalVuln.retryDecision(a, now: LTF.now.addingTimeInterval(10), noticeGeneration: 0, channelGeneration: gen, listContentId: "c1") == .notYet)
        t.check("delivery: refused → retry after retry_after",
                LocalVuln.retryDecision(a, now: LTF.now.addingTimeInterval(31), noticeGeneration: 0, channelGeneration: gen, listContentId: "c1") == .retry)
        t.check("delivery: retry dropped after the notice generation changed (wipe/OFF)",
                LocalVuln.retryDecision(a, now: LTF.now.addingTimeInterval(31), noticeGeneration: 1, channelGeneration: gen, listContentId: "c1") == .drop)
        t.check("delivery: retry dropped when the list changed",
                LocalVuln.retryDecision(a, now: LTF.now.addingTimeInterval(31), noticeGeneration: 0, channelGeneration: gen, listContentId: "c2") == .drop)
        t.check("delivery: retry dropped after the 1 h window",
                LocalVuln.retryDecision(a, now: LTF.now.addingTimeInterval(3601), noticeGeneration: 0, channelGeneration: gen, listContentId: "c1") == .drop)
        LocalVuln.markRetryInFlight(&a); LocalVuln.recordOutcome(&a, .refused(retryAfter: 1), now: LTF.now)
        LocalVuln.markRetryInFlight(&a); LocalVuln.recordOutcome(&a, .refused(retryAfter: 1), now: LTF.now)
        t.check("delivery: at most 3 attempts", a.attempt == nil)
        var v = LocalVulnState()
        let vl = LocalVuln.proposals(v, reports: [report()]).lines
        LocalVuln.consume(&v, vl, text: "x", listContentId: "c1", noticeGeneration: 0, destination: dest, now: LTF.now)
        t.check("retry revalidation: lines valid for the same version", LocalVuln.linesStillValid(v.attempt!, reports: [report()]))
        t.check("retry revalidation: a changed version invalidates the lines",
                !LocalVuln.linesStillValid(v.attempt!, reports: [report(version: "7:5.1.7-0+deb12u1")]))
        t.check("consume: rows and the attempt record change in the same state value",
                v.rows.count == 1 && v.attempt?.state == .inFlight && v.attempt?.lines.first?.key == v.rows.first?.key)
    }

    static func wordingGroup(_ t: Tally) {
        let deb = LocalVuln.Proposal(key: "k", kind: .initial, report: { var r = report(); r.action = .apt(["ffmpeg", "libavcodec59:amd64"]); return r }())
        let text = LocalToolsText.message([deb], lang: "en")
        t.check("wording: deb command built from local binary names",
                text.contains("`sudo apt-get install --only-upgrade ffmpeg libavcodec59:amd64`") && text.contains("CVE-2099-0001"), text)
        t.check("wording: says Briglia does not update it", text.contains("Briglia does not update it for you"))
        var b = report(); b.action = .brew("ffmpeg")
        t.check("wording: brew command", LocalToolsText.message([.init(key: "k", kind: .initial, report: b)], lang: "en").contains("`brew upgrade ffmpeg`"))
        var c = report(); c.action = .cask("libreoffice")
        t.check("wording: cask command", LocalToolsText.message([.init(key: "k", kind: .initial, report: c)], lang: "en").contains("`brew upgrade --cask libreoffice`"))
        var vd = report("node"); vd.action = .vendor(vendor: "nodejs.org", product: "node", minimum: "22.21.1")
        let vt = LocalToolsText.message([.init(key: "k", kind: .initial, report: vd)], lang: "en")
        t.check("wording: vendor build → 'update from vendor', no command", vt.contains("Update Node.js from nodejs.org (version 22.21.1 or later)") && !vt.contains("`"), vt)
        let kev = LocalToolsText.message([.init(key: "k", kind: .initial, report: report(kev: true, fix: .noFix(.notYet)))], lang: "en")
        t.check("wording: KEV without a fix → exploited + compiled mitigation, no command",
                kev.contains("actively exploited") && kev.contains("avoid processing untrusted files with ffmpeg") && !kev.contains("apt-get"), kev)
        var bad = report(); bad.action = .apt(["ffmpeg; rm -rf /"])
        t.check("wording: an invalid local name never reaches a command",
                !LocalToolsText.message([.init(key: "k", kind: .initial, report: bad)], lang: "en").contains("rm -rf"))
        let many = (0..<7).map { i in LocalVuln.Proposal(key: "k\(i)", kind: .initial, report: report(["ffmpeg", "poppler", "pandoc", "git", "curl", "tar", "zip"][i])) }
        let batch = LocalToolsText.message(many, lang: "en")
        t.check("wording: batched: ≤ 5 named lines, then 'and N more: see /status'",
                batch.components(separatedBy: "\n• ").count == 6 && batch.contains("…and 2 more: see /status."), batch)
        let it = LocalToolsText.message([deb], lang: "it")
        t.check("wording: Italian", it.contains("ha un problema di sicurezza noto") && it.contains("Per correggerlo, esegui"), it)
        let follow = LocalToolsText.message([.init(key: "k", kind: .followUp, report: report(kev: true))], lang: "en")
        t.check("wording: follow-up names the fix", follow.contains("A fix is now available") && follow.contains("apt-get"), follow)
        let all = [text, kev, follow, batch, it, vt] + [LocalTools.State.noKnownIssue].map { _ in
            LocalToolsText.stateText(LocalTools.ToolReport(toolId: "ffmpeg", state: .noKnownIssue, checkedAt: LTF.now), lang: "en") }
        t.check("wording: never 'safe'", !all.contains { $0.lowercased().contains("safe") })
        t.check("wording: 'no known security issues in this tool (checked <date>)'",
                LocalToolsText.stateText(LocalTools.ToolReport(toolId: "ffmpeg", state: .noKnownIssue, checkedAt: LTF.now), lang: "en")
                    .hasPrefix("no known security issues in this tool (checked 2026-10-"))
        // A list entry carrying a crafted binary name: the command still
        // uses only the names read from dpkg.
        let crafted = LTF.listFor([LTF.debEntry([{ var a = LTF.adv(["CVE-2099-0001"]); a["binaries"] = ["notinstalled"]; return a }()])])
        let rep = LocalTools.match(LTF.debInstance(), list: crafted, now: LTF.now)
        t.check("wording: binaries named by the list are not used; only local ones", rep.action == .apt(["ffmpeg", "libavcodec59"]))
        let upgradeOn = ConversationManager.upgradeCheckOnText
        t.check("/upgradecheck: reply describes both checks and never installing",
                upgradeOn.contains("known security problems in the tools it uses") && upgradeOn.contains("never installs anything by itself"))
    }

    static func toolchainGroup(_ t: Tally) {
        let trixie = LocalTools.OSRelease(id: "debian", versionId: "13", codename: "trixie")
        let doc = LTF.doc(LTF.payload(declared: ["deb:debian:13": ["osv:Debian:13"]],
            coverage: [LTF.cov("deb:debian:13:ffmpeg", "osv:Debian:13")],
            entries: [LTF.debEntry("ffmpeg", release: "13", [LTF.adv(["CVE-2099-0101", "DEBIAN-CVE-2099-0101"], fixed: "7:7.1.2-1")]),
                      LTF.debEntry("poppler", release: "12", [LTF.adv(["CVE-2099-0102"])])]))
        let inputs = LocalTools.toolchainInputs(doc, base: trixie)
        t.check("toolchain: inputs only for the device's base release (non-noble fixture)", inputs.count == 1 && inputs[0].source == "ffmpeg")
        let manifest = [ReleaseSecurity.ComponentAdvisory(ecosystem: "deb", identity: ["distro": "debian", "release": "13", "arch": "arm64", "sourcePackage": "ffmpeg"],
                                                          minimumSafe: "7:7.1.1-2", advisories: ["CVE-2099-0101"], level: .recommended)]
        let a = LocalTools.mergeToolchainClasses(existing: [], manifest: manifest, list: inputs, base: trixie)
        let b = LocalTools.mergeToolchainClasses(existing: LocalTools.mergeToolchainClasses(existing: [], manifest: [], list: inputs, base: trixie),
                                                 manifest: manifest, list: [], base: trixie)
        t.check("toolchain: manifest + list sharing an ID → one class", a.count == 1 && a[0].inManifest && a[0].inList)
        t.check("toolchain: list first, then manifest → still one class", b.count == 1)
        t.check("toolchain: conflicting fixed versions → the higher one", a[0].fixedVersion == "7:7.1.2-1")
        let omitted = LocalTools.mergeToolchainClasses(existing: a, manifest: [], list: [], base: trixie)
        t.check("toolchain: a source omitting the class never erases it", omitted.count == 1)
        var withdrawnInput = inputs[0]; withdrawnInput.withdrawn = true
        t.check("toolchain: withdrawn in the list and carried by no release source → removed",
                LocalTools.mergeToolchainClasses(existing: a, manifest: [], list: [withdrawnInput], base: trixie).isEmpty)
        t.check("toolchain: withdrawn in the list but still in the manifest → kept",
                LocalTools.mergeToolchainClasses(existing: a, manifest: manifest, list: [withdrawnInput], base: trixie).count == 1)
    }
}
