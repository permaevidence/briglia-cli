import Foundation

extension LocalToolsSelftest {
    static func rejects(_ t: Tally, _ label: String, _ raw: Data, policy: AdvisoryPolicy = LTF.policy,
                        now: Date = LTF.now, contains: String) {
        do {
            _ = try LocalAdvisory.verify(raw, policy: policy, now: now)
            t.check(label, false, "accepted")
        } catch {
            let d = error.localizedDescription
            t.check(label, d.contains(contains), d)
        }
    }

    static func verifyGroup(_ t: Tally) {
        let base = LTF.payload(coverage: LTF.covAll("deb:debian:12:ffmpeg"), entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"])])])
        do {
            let v = try LocalAdvisory.verify(LTF.envelope(base), policy: LTF.policy, now: LTF.now)
            t.check("verify: a well-formed signed list verifies", v.document.sequence == 100 && v.document.entries.count == 1)
            t.check("verify: contentId is SHA-256 of the exact payload", v.contentId.count == 64)
        } catch {
            t.check("verify: a well-formed signed list verifies", false, "\(error)")
        }
        rejects(t, "verify: tampered signature rejected", LTF.envelope(base, tamper: true), contains: "bad signature")
        rejects(t, "verify: other key (not pinned) rejected", LTF.envelope(base, seed: LTF.otherSeed), contains: "unknown key")
        rejects(t, "verify: wrong domain-separation string rejected", LTF.envelope(base, domain: "briglia-release-envelope-v1"), contains: "wrong domain")
        rejects(t, "verify: wrong envelope format rejected", LTF.envelope(base, format: "ada-release-envelope-v1"), contains: "format")
        // A signature made for another domain does not verify even if the
        // envelope claims the right one.
        do {
            let other = LTF.envelope(base, domain: "other-domain")
            var o = try JSONSerialization.jsonObject(with: other) as! [String: String]
            o["domain"] = LocalAdvisory.domainString
            rejects(t, "verify: signature bound to its domain string", try JSONSerialization.data(withJSONObject: o), contains: "bad signature")
        } catch { t.check("verify: signature bound to its domain string", false, "\(error)") }
        let placeholder = AdvisoryPolicy(keys: AdvisoryKeys.active, domain: LocalAdvisory.domainString, url: LTF.policy.url)
        t.check("keys: the compiled set is a placeholder that verifies nothing", AdvisoryKeys.active.isEmpty && !AdvisoryPolicy.production.isProvisioned)
        t.check("keys: the placeholder key ID is refused as a key", AdvisoryKeys.parse(keyId: AdvisoryKeys.placeholderKeyId, hex: String(repeating: "0", count: 64)) == nil)
        rejects(t, "verify: not provisioned → refused before parsing", LTF.envelope(base), policy: placeholder, contains: "not provisioned")
        rejects(t, "verify: validity > 72 h rejected", LTF.envelope(LTF.payload(validity: 72 * 3600 + 1, coverage: [], entries: [])), contains: "72 h")
        rejects(t, "verify: published > now + 1 h rejected",
                LTF.envelope(LTF.payload(published: LTF.now.addingTimeInterval(3601), coverage: [], entries: [])), contains: "future")
        rejects(t, "verify: expired list rejected",
                LTF.envelope(LTF.payload(published: LTF.now.addingTimeInterval(-73 * 3600), validity: 72 * 3600, coverage: [], entries: [])),
                contains: "expired")
        rejects(t, "verify: sequence ≥ 2^53 rejected", LTF.envelope(LTF.payload(seq: 1 << 53, coverage: [], entries: [])), contains: "sequence")
        let big = LTF.payload(coverage: [], entries: [], extra: ["padding": String(repeating: "x", count: LocalAdvisory.maxPayloadBytes)])
        rejects(t, "verify: oversized envelope/payload rejected", LTF.envelope(big), contains: "bytes")
        do {
            var o = try JSONSerialization.jsonObject(with: LTF.envelope(base)) as! [String: String]
            o["payload"] = o["payload"]!.replacingOccurrences(of: "=", with: "") + "\n"
            rejects(t, "verify: non-canonical base64 rejected", try JSONSerialization.data(withJSONObject: o), contains: "base64")
        } catch { t.check("verify: non-canonical base64 rejected", false, "\(error)") }
    }

    static func parseFails(_ t: Tally, _ label: String, _ payload: Data, contains: String) {
        do { _ = try LocalAdvisory.parseDocument(payload); t.check(label, false, "parsed") }
        catch { t.check(label, error.localizedDescription.contains(contains), error.localizedDescription) }
    }

    static func parseGroup(_ t: Tally) {
        let cov = LTF.covAll("deb:debian:12:ffmpeg")
        parseFails(t, "parse: two entries for one identity rejected",
                   LTF.payload(coverage: cov, entries: [LTF.debEntry([]), LTF.debEntry([])]), contains: "two entries")
        parseFails(t, "parse: more than 64 identities rejected",
                   LTF.payload(coverage: [], entries: (0..<65).map { LTF.debEntry("pkg\($0)", []) }), contains: "64")
        parseFails(t, "parse: more than 64 advisories per identity rejected",
                   LTF.payload(coverage: cov, entries: [LTF.debEntry((0..<65).map { LTF.adv(["CVE-2099-\(1000 + $0)"]) })]), contains: "64")
        parseFails(t, "parse: more than 16 IDs per advisory rejected",
                   LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv((0..<17).map { "CVE-2099-\(2000 + $0)" })])]), contains: "16")
        parseFails(t, "parse: malformed advisory ID rejected",
                   LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv(["<script>"])])]), contains: "ID pattern")
        parseFails(t, "parse: string over 512 bytes rejected",
                   LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"], events: [["introduced": "0"], ["fixed": String(repeating: "1", count: 600)]])])]),
                   contains: "512")
        parseFails(t, "parse: a source name that is not a valid name rejected",
                   LTF.payload(coverage: cov, entries: [LTF.debEntry("ff mpeg; rm -rf", [])]), contains: "valid name")
        parseFails(t, "parse: an event with two keys rejected",
                   LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"], events: [["introduced": "0", "fixed": "1"]])])]),
                   contains: "exactly one key")
        parseFails(t, "parse: declared ecosystem with no sources rejected",
                   LTF.payload(declared: ["deb:debian:12": []], coverage: cov, entries: []), contains: "declared sources")
        let unknownStatus = LTF.doc(LTF.payload(coverage: [LTF.cov("deb:debian:12:ffmpeg", "osv:Debian:12", "maybe")], entries: []))
        t.check("parse: an unknown coverage status is kept as 'not ok' (nil)", unknownStatus.coverage.first?.status == nil)
        let gitRange = LTF.doc(LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"],
            affected: ["ranges": [["type": "GIT", "events": [["introduced": "abc123"]]]]])])]))
        if let r = gitRange.entries.first?.advisories.first?.affected.ranges {
            t.check("parse: unsupported range type → that range is unsupported (advisory unknown)", r.first?.unsupported == true)
        } else { t.check("parse: unsupported range type → that range is unsupported (advisory unknown)", false) }
        let oddEvent = LTF.doc(LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"], events: [["introduced": "0"], ["mystery": "1"]])])]))
        if let r = oddEvent.entries.first?.advisories.first?.affected.ranges {
            t.check("parse: unknown event kind → range unsupported", r.first?.unsupported == true)
        } else { t.check("parse: unknown event kind → range unsupported", false) }
        let additive = LTF.doc(LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"])])],
                                           extra: ["support": ["future": "floor data"]]))
        t.check("parse: unknown additive fields are ignored (the §9.5.8 floor seam)", additive.entries.count == 1)
        let unknownKind = LTF.payload(coverage: [], entries: [["identity": ["kind": "rpm", "name": "x"], "scheme": "rpm", "advisories": []]])
        parseFails(t, "parse: an unknown identity kind rejects the document (never silently skipped)", unknownKind, contains: "kind")
        let ids = LTF.doc(LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv(["cve-2099-0001", "CVE-2099-0001", "DSA-9999-1"])])]))
        t.check("parse: IDs upper-cased and deduplicated", ids.entries[0].advisories[0].ids == ["CVE-2099-0001", "DSA-9999-1"])
        t.check("parse: primary ID prefers the CVE", ids.entries[0].advisories[0].primaryId == "CVE-2099-0001")
    }

    static func observationGroup(_ t: Tally) {
        let domain = LTF.policy.trustDomain
        var s = LocalAdvisoryStore.ObservationState()
        let v100 = LTF.verified(LTF.payload(seq: 100, coverage: [], entries: []))
        let v101 = LTF.verified(LTF.payload(seq: 101, coverage: [], entries: []))
        let v100b = LTF.verified(LTF.payload(seq: 100, coverage: [], entries: [LTF.debEntry([])]))
        t.check("observe: first list recorded", LocalAdvisoryStore.observe(&s, v100, domain: domain, now: LTF.now) == .first)
        t.check("observe: same bytes again is a confirmation", LocalAdvisoryStore.observe(&s, v100, domain: domain, now: LTF.now) == .renewal)
        t.check("observe: same sequence, different content → conflict", LocalAdvisoryStore.observe(&s, v100b, domain: domain, now: LTF.now) == .conflict)
        t.check("observe: conflict keeps the earlier document", s.domain(domain)?.contentId == v100.contentId && s.domain(domain)?.conflictSince != nil)
        t.check("observe: conflict blocks messages", !LocalToolsService.messagingAllowed(s, policy: LTF.policy, contentId: v100.contentId, now: LTF.now))
        t.check("observe: a higher sequence replaces and clears the conflict",
                LocalAdvisoryStore.observe(&s, v101, domain: domain, now: LTF.now) == .newer && s.domain(domain)?.conflictSince == nil)
        t.check("observe: a lower sequence is ignored (never regresses)",
                LocalAdvisoryStore.observe(&s, v100, domain: domain, now: LTF.now) == .lower && s.domain(domain)?.sequence == 101)
        t.check("observe: lower sequence recorded for attention", s.domain(domain)?.lastLowerSequence == 100)
        // Replay of an older "nothing found" list cannot clear an affected state.
        var r = LocalAdvisoryStore.ObservationState()
        let affected = LTF.verified(LTF.payload(seq: 200, coverage: LTF.covAll("deb:debian:12:ffmpeg"),
                                                entries: [LTF.debEntry([LTF.adv(["CVE-2099-0001"])])]))
        let clean = LTF.verified(LTF.payload(seq: 150, coverage: LTF.covAll("deb:debian:12:ffmpeg"), entries: []))
        LocalAdvisoryStore.observe(&r, affected, domain: domain, now: LTF.now)
        LocalAdvisoryStore.observe(&r, clean, domain: domain, now: LTF.now)
        let (doc, _) = LocalToolsService.currentList(r, policy: LTF.policy, now: LTF.now)
        let report = doc.map { LocalTools.match(LTF.debInstance(), list: $0, now: LTF.now) }
        t.check("observe: a replayed older clean list cannot clear an affected state", report?.state == .affectedFixInstallable)
        let (expiredDoc, rec) = LocalToolsService.currentList(r, policy: LTF.policy, now: LTF.now.addingTimeInterval(80 * 3600))
        t.check("observe: expired record → no document (every state unknown)", expiredDoc == nil && rec != nil)
        let other = AdvisoryPolicy(keys: [LTF.signer(LTF.otherSeed).1], domain: LocalAdvisory.domainString, url: LTF.policy.url)
        t.check("observe: a rotated key set is a new trust domain (record starts afresh)",
                other.trustDomain != LTF.policy.trustDomain && LocalToolsService.currentList(r, policy: other, now: LTF.now).0 == nil)
        var many = LocalAdvisoryStore.ObservationState()
        for i in 0..<6 { LocalAdvisoryStore.observe(&many, v100, domain: "d\(i)", now: LTF.now.addingTimeInterval(Double(i))) }
        t.check("observe: at most 4 trust domains, oldest dropped", many.domains.count == 4 && many.domain("d0") == nil)
    }
}
