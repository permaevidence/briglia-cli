import Foundation

/// Owner decision L1 (Matteo, 2026-10-24; security plan §9.5.3): the list's
/// limits were raised to 2 MiB / 128 identities / 512 advisories per
/// identity / 128 IDs per advisory / 1024 coverage rows, and every file that
/// holds a copy of the list (or a report derived from it) was sized to match.
/// These rows exercise each bound at its edge and the cost of a full list.
extension LocalToolsSelftest {
    /// A structurally valid payload of exactly `bytes` bytes, padded with an
    /// ignored key: as many full identities (512 advisories of 3 IDs) as fit.
    static func fullPayload(bytes: Int) -> (Data, Int)? {
        func build(_ identities: Int, pad: Int) -> Data {
            let entries: [[String: Any]] = (0..<identities).map { i in
                LTF.debEntry("pkg\(i)", (0..<512).map { j in
                    LTF.adv((0..<3).map { k in "CVE-2099-\(100000 + i * 10000 + j * 10 + k)" })
                })
            }
            let cov = (0..<identities).flatMap { LTF.covAll("deb:debian:12:pkg\($0)") }
            // "ÿ" (C3 BF) makes "/" appear in the base64 (the slash-escaping row).
            return LTF.payload(coverage: cov, entries: entries,
                               extra: ["padding": String(repeating: " ", count: pad), "slashes": String(repeating: "ÿ", count: 3000)])
        }
        for identities in stride(from: 16, through: 1, by: -1) {
            let bare = build(identities, pad: 0)
            if bare.count <= bytes { return (build(identities, pad: bytes - bare.count), identities * 512) }
        }
        return nil
    }

    static func limitsGroup(_ t: Tally) {
        t.check("L1: list limits are 2 MiB payload / 2,880 KiB envelope / 128 identities / 512 advisories / 128 IDs / 1024 rows",
                LocalAdvisory.maxPayloadBytes == 2 * 1024 * 1024 && LocalAdvisory.maxEnvelopeBytes == 2_880 * 1024
                    && LocalAdvisory.maxIdentities == 128 && LocalAdvisory.maxAdvisoriesPerIdentity == 512
                    && LocalAdvisory.maxIdsPerAdvisory == 128 && LocalAdvisory.maxCoverageRows == 1024)
        t.check("L1: the envelope cap holds the base64 of a maximal payload plus its fields",
                (LocalAdvisory.maxPayloadBytes + 2) / 3 * 4 + 4096 <= LocalAdvisory.maxEnvelopeBytes)
        let cov = LTF.covAll("deb:debian:12:ffmpeg")
        // Exactly at each structural bound: accepted.
        do {
            let atIds = LTF.payload(coverage: cov, entries: [LTF.debEntry([LTF.adv((0..<128).map { "CVE-2099-\(3000 + $0)" })])])
            let atAdv = LTF.payload(coverage: cov, entries: [LTF.debEntry((0..<512).map { LTF.adv(["CVE-2099-\(4000 + $0)"]) })])
            let atIdent = LTF.payload(coverage: [], entries: (0..<128).map { LTF.debEntry("pkg\($0)", []) })
            let rows = (0..<512).flatMap { LTF.covAll("deb:debian:12:pkg\($0)") }
            let atRows = LTF.payload(coverage: rows, entries: [])
            let docs = try [atIds, atAdv, atIdent, atRows].map { try LocalAdvisory.parseDocument($0) }
            t.check("L1: 128 IDs, 512 advisories, 128 identities and 1024 coverage rows are each accepted",
                    docs[0].entries[0].advisories[0].ids.count == 128 && docs[1].entries[0].advisories.count == 512
                        && docs[2].entries.count == 128 && docs[3].coverage.count == 1024)
        } catch { t.check("L1: 128 IDs, 512 advisories, 128 identities and 1024 coverage rows are each accepted", false, "\(error)") }
        parseFails(t, "L1: 1025 coverage rows rejected",
                   LTF.payload(coverage: (0..<513).flatMap { LTF.covAll("deb:debian:12:pkg\($0)") }, entries: []), contains: "1024")
        // A full-size signed list: accepted at exactly 2 MiB, refused one byte above, before parsing.
        guard let (full, expected) = fullPayload(bytes: LocalAdvisory.maxPayloadBytes),
              let (over, _) = fullPayload(bytes: LocalAdvisory.maxPayloadBytes + 1) else {
            t.check("L1: a full-size list can be built", false)
            return
        }
        let started = Date()
        do {
            let v = try LocalAdvisory.verify(LTF.envelope(full), policy: LTF.policy, now: LTF.now)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let n = v.document.entries.reduce(0) { $0 + $1.advisories.count }
            print("    · verify + parse of a \(full.count)-byte list (\(n) advisories): \(ms) ms")
            t.check("L1: a signed list of exactly 2 MiB verifies and parses (full) well under 10 s",
                    v.payload.count == LocalAdvisory.maxPayloadBytes && n == expected && n >= 4096 && ms < 10_000, "\(ms) ms")
            // Matching against it is bounded too: one instance of a full identity.
            let inst = LTF.debInstance(tool: "ffmpeg", source: "pkg3", version: "7:5.1.6-0+deb12u1")
            let m0 = Date()
            let r = LocalTools.match(.present(inst), list: v.document, now: LTF.now)
            let mms = Int(Date().timeIntervalSince(m0) * 1000)
            t.check("L1: matching one installed tool against a 512-advisory identity stays fast",
                    r.affected.count == 512 && mms < 5_000, "\(r.affected.count) affected, \(mms) ms")
            // The observation file holds maxDomains copies of the payload.
            let root = LTF.tempDir("limits")
            defer { try? FileManager.default.removeItem(at: root) }
            let p = LTF.paths(root)
            var obs = LocalAdvisoryStore.ObservationState()
            for d in 0..<LocalAdvisoryStore.maxDomains {
                LocalAdvisoryStore.observe(&obs, v, domain: "domain-\(d)", now: LTF.now)
            }
            var wrote = true
            do { try LocalAdvisoryStore.write(obs, to: p.observation, maxBytes: LocalAdvisoryStore.maxObservationBytes) }
            catch { wrote = false }
            let size = ((try? FileManager.default.attributesOfItem(atPath: p.observation.path))?[.size] as? Int) ?? 0
            let back = LocalAdvisoryStore.read(LocalAdvisoryStore.ObservationState.self, at: p.observation,
                                               maxBytes: LocalAdvisoryStore.maxObservationBytes, quarantine: false, now: LTF.now)
            let raw = (try? Data(contentsOf: p.observation)) ?? Data()
            t.check("L1: stored payloads are base64 without escaped slashes (the size bound assumes it)",
                    !raw.isEmpty && raw.range(of: Data("\\/".utf8)) == nil)
            t.check("L1: the observation file holds \(LocalAdvisoryStore.maxDomains) full-size domains and reads back",
                    wrote && size <= LocalAdvisoryStore.maxObservationBytes && back?.domains.count == LocalAdvisoryStore.maxDomains
                        && back?.domains.allSatisfy { $0.payload == full } == true, "\(size) bytes")
            // A report per watched tool, each a full identity of maximal IDs: fits localvuln.json.
            let maxIds = (0..<LocalTools.maxReportIds).map { "ID-" + String(repeating: "\($0 % 10)", count: 61) }
            var rep = report(ids: maxIds)
            rep.affected = Array(repeating: rep.affected[0], count: LocalAdvisory.maxAdvisoriesPerIdentity)
            var state = LocalVulnState()
            state.report = LocalToolsSnapshot(evaluatedAt: LTF.now, listSequence: 1, listContentId: String(repeating: "c", count: 64),
                                              reports: Array(repeating: rep, count: LocalTools.watchlist.count))
            var vw = true
            do { try LocalAdvisoryStore.write(state, to: p.localvuln, maxBytes: LocalAdvisoryStore.maxLocalVulnBytes) }
            catch { vw = false }
            let vsize = ((try? FileManager.default.attributesOfItem(atPath: p.localvuln.path))?[.size] as? Int) ?? 0
            t.check("L1: a maximal report for every watched tool fits localvuln.json", vw, "\(vsize) bytes")
        } catch {
            t.check("L1: a signed list of exactly 2 MiB verifies and parses (full) well under 10 s", false, "\(error)")
        }
        do {
            _ = try LocalAdvisory.verify(LTF.envelope(over), policy: LTF.policy, now: LTF.now)
            t.check("L1: one byte over 2 MiB is refused before parsing", false, "accepted")
        } catch {
            t.check("L1: one byte over 2 MiB is refused before parsing",
                    error.localizedDescription.contains("payload is \(LocalAdvisory.maxPayloadBytes + 1) bytes"), error.localizedDescription)
        }
        var bigEnvelope = LTF.envelope(full)
        bigEnvelope.append(Data(repeating: 0x20, count: LocalAdvisory.maxEnvelopeBytes + 1 - bigEnvelope.count))
        do {
            _ = try LocalAdvisory.verify(bigEnvelope, policy: LTF.policy, now: LTF.now)
            t.check("L1: an envelope over 2,880 KiB is refused before decoding", false, "accepted")
        } catch {
            t.check("L1: an envelope over 2,880 KiB is refused before decoding",
                    error.localizedDescription.contains("envelope is"), error.localizedDescription)
        }
        // The persisted report keeps at most 16 IDs per advisory; matching is unaffected.
        let ids = (0..<128).map { "CVE-2099-\(5000 + $0)" }
        let d = LTF.listFor([LTF.debEntry([LTF.adv(ids)])])
        let listed = d.entries[0].advisories[0]
        let r = LocalTools.match(.present(LTF.debInstance()), list: d, now: LTF.now)
        t.check("L1: a 128-ID advisory still matches; its persisted report keeps the first 16 IDs and the primary ID",
                listed.ids.count == 128 && r.affected.count == 1 && r.affected[0].ids == Array(listed.ids.prefix(16))
                    && r.affected[0].primaryId == listed.primaryId)
    }
}
