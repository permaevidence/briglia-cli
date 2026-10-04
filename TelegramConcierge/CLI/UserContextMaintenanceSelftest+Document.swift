import Foundation

/// Rows P1–P3, A1–A11 (pure document parsing and application) and R1
/// (reply parsing). No I/O.
extension UserContextMaintenanceSelftest {

    static func documentRows(_ h: UCMHarness) async throws {
        // P1: byte round-trip.
        let samples: [(String, String)] = [
            ("LF", "## A\n- one\n- two\n\nplain line\n"),
            ("CRLF", "## A\r\n- one\r\n- two\r\n\r\nplain\r\n"),
            ("mixed", "## A\r\n- one\n- two\r\nplain"),
            ("tabs+emoji+combining", "\t- caf\u{65}\u{301} ☕️ 👩‍👩‍👧\n  * indented\n1) numbered\n2. dotted"),
            ("no trailing newline", "- a\n- b"),
            ("only headings", "# Top\n## Sub\n"),
            ("empty", ""),
            ("single newline", "\n"),
            ("blank runs", "- a\n\n\n- b\n\n"),
        ]
        for (label, text) in samples {
            let document = UserProfileDocument(text)
            h.check("P1 round-trip is byte-identical (\(label))", Array(document.render().utf8) == Array(text.utf8))
            let noop = document.apply(.init())
            h.check("P1 applying no ops changes nothing (\(label))", !noop.changed && Array(noop.text.utf8) == Array(text.utf8))
        }

        // P2: ids, prefixes, LABEL: lines.
        let p2 = UserProfileDocument("# Profile\nNAME: Matteo\n- likes tea\n  * nested fact\n12. numbered fact\n3) paren fact\n-not a marker\n")
        h.check("P2 every non-heading, non-blank line is one fact", p2.factCount == 6, "\(p2.factCount)")
        let prefixes = p2.factLineIndices.map { p2.lines[$0].prefix }
        h.check("P2 prefixes split from content", prefixes == ["", "- ", "  * ", "12. ", "3) ", ""], "\(prefixes)")
        h.check("P2 LABEL: line content kept whole", p2.lines[p2.factLineIndices[0]].content == "NAME: Matteo")

        // P3: listing and status line.
        let listing = p2.numberedListing()
        h.check("P3 listing shows headings verbatim and [id] (length) content",
                listing.hasPrefix("# Profile\n[1] (12 chars) NAME: Matteo\n[2] (9 chars) likes tea"), listing)
        let prompt = UserContextMaintenance.systemPrompt(document: UserProfileDocument(UCMHarness.profile(size: 36_622)),
            assistantName: "Bree", userName: "Matteo", policy: .standard, pass: 1)
        h.check("P3 v6.3 status line: size and facts, aim for about 30,000 and don't go much below it, no quota",
                prompt.contains("Aim for about 30,000 characters. Don't go much below it: removing a lasting fact just to save space is worse than staying near the target.")
                && prompt.contains("facts.") && !prompt.contains("going lower is fine")
                && !prompt.contains("Remove at least") && !prompt.contains("Target:"))
        h.check("P3 v6.2 purpose: lasting facts every turn; one-off research, task details, prices, logistics, version histories do not belong",
                prompt.contains("so the assistant always knows the lasting facts about the user")
                && prompt.contains("results of one-off research, task details, prices, logistics, version histories"))
        h.check("P3 v6.3 keeps people, relationships, life context and preferences; whole finished topics first; no 'best cleanup' push",
                prompt.contains("Keep facts about people, relationships, life context and persistent preferences, even when they are short or old")
                && prompt.contains("Prefer removing whole topics that are finished or tied to one task before trimming single facts")
                && !prompt.contains("Do the best cleanup, not the smallest one"))
        h.check("P3 v6.3 finished one-off work goes entirely (no one-line summary); recurring topics are not finished; upcoming events kept",
                prompt.contains("A finished one-off investigation or task goes entirely: don't keep a one-line summary of it; it stays in the archive.")
                && prompt.contains("A topic that keeps coming back in the summaries because the user is still working on it is not finished.")
                && prompt.contains("Keep upcoming commitments and events until their date has passed;"))
        h.check("P3 v6.2 summaries only to judge what matters; facts and edits only from the PROFILE",
                prompt.contains("use it only to judge what still matters to the user")
                && prompt.contains("Take every fact and edit only from the PROFILE below; never add anything from the summaries"))
        let pass2 = UserContextMaintenance.systemPrompt(document: UserProfileDocument(UCMHarness.profile(size: 36_622)),
            assistantName: "Bree", userName: "Matteo", policy: .standard, pass: 2)
        h.check("P3 v6.3 pass-2 line: above the target of about 30,000, remove more but not much below the target",
                pass2.contains("characters above the target of about 30,000") && pass2.contains("Remove more of what does not serve the profile's purpose, but don't go much below the target."))
        h.check("P3 v6.1 prompt: no 'or it is ignored' length rule, whole-profile emphasis, grouping sentence",
                !prompt.contains("or it is ignored") && prompt.contains("size of the WHOLE profile")
                && prompt.contains("to group several facts, drop them and add one fact that covers them"))
        h.check("P3 prompt is non-prescriptive (no keep/drop category lists)",
                !prompt.contains("WHAT TO") && !prompt.contains("PRESERVE every fact"))

        // A1: drop/edit/add; every untouched line byte-identical.
        let a1Text = "## People\r\n- Brother: Paolo\r\n- Sister: Biba (Rome)\r\n\r\n## Food\r\n- Vegan\r\n- Likes lentils and tofu daily\r\n"
        let a1 = UserProfileDocument(a1Text)
        let r1 = a1.apply(try UserProfileDocument.parseReply("{\"drop\":[1],\"edit\":[{\"id\":4,\"text\":\"Lentils, tofu\"}],\"add\":[{\"text\":\"Eats plants\",\"after\":3}]}", factCount: a1.factCount))
        let expected = "## People\r\n- Sister: Biba (Rome)\r\n\r\n## Food\r\n- Vegan\r\n- Eats plants\r\n- Lentils, tofu\r\n"
        h.check("A1 drop/edit/add applied; untouched lines byte-identical (CRLF kept)", Array(r1.text.utf8) == Array(expected.utf8), r1.text.debugDescription)
        h.check("A1 retired: dropped original and pre-edit original, with \\r and section",
                r1.retired.map(\.line) == ["- Brother: Paolo\r", "- Likes lentils and tofu daily\r"]
                && r1.retired.map(\.op) == [.dropped, .editedBefore] && r1.retired[0].section == "## People")

        // A2: bad ids. A2b: duplicate keys.
        let a2 = try UserProfileDocument.parseReply("{\"drop\":[0, 9, 2.0, 3.5, true, \"1\", null, 1e0, 2]}", factCount: 4)
        h.check("A2 only exact in-range integers are ids (2.0, 3.5, true, \"1\", null, 1e0, 0, 9 ignored)",
                a2.drop == [2] && a2.ignored.count == 8, "\(a2.drop) \(a2.ignored)")
        var a2b = false
        do { _ = try UserProfileDocument.parseReply("{\"drop\":[1],\"drop\":[2]}", factCount: 4) }
        catch UserProfileDocument.ReplyError.duplicateKey { a2b = true } catch {}
        h.check("A2b duplicate JSON keys make the whole reply malformed", a2b)
        var a2c = false
        do { _ = try UserProfileDocument.parseReply("{\"edit\":[{\"id\":1,\"text\":\"a\",\"text\":\"b\"}]}", factCount: 4) }
        catch UserProfileDocument.ReplyError.duplicateKey { a2c = true } catch {}
        h.check("A2b duplicate keys inside an op are malformed too", a2c)

        // A3: duplicates and conflicts.
        let four = UserProfileDocument("- a\n- b\n- c\n- d\n")
        let a3 = four.apply(try UserProfileDocument.parseReply("{\"drop\":[1,1,2],\"edit\":[{\"id\":2,\"text\":\"B\"},{\"id\":3,\"text\":\"x\"},{\"id\":3,\"text\":\"y\"}]}", factCount: 4))
        h.check("A3 duplicate drop deduplicated; drop+edit and two edits on one id void every op on it",
                a3.text == "- b\n- c\n- d\n" && a3.appliedDrops == 1 && a3.appliedEdits == 0, a3.text.debugDescription)

        // A4 (v6.1): no length rule — a longer edit applies, a shorter one too.
        let a4 = four.apply(try UserProfileDocument.parseReply("{\"edit\":[{\"id\":1,\"text\":\"a much longer replacement\"},{\"id\":2,\"text\":\"B\"}]}", factCount: 4))
        h.check("A4 v6.1: edits apply whether longer or shorter (no per-edit length rule)",
                a4.text == "- a much longer replacement\n- B\n- c\n- d\n" && a4.appliedEdits == 2, a4.text.debugDescription)

        // A5: no-op edits and add de-duplication.
        let a5 = four.apply(try UserProfileDocument.parseReply("{\"drop\":[4],\"edit\":[{\"id\":1,\"text\":\"  a \"}],\"add\":[{\"text\":\"b\"},{\"text\":\"e\"},{\"text\":\"e\"},{\"text\":\"d\"}]}", factCount: 4))
        h.check("A5 identical edit is a no-op (not retired); add duplicates of survivors/earlier adds skipped; add equal to a dropped fact kept",
                a5.text == "- a\n- b\n- c\n- e\n- d\n" && a5.retired.count == 1 && a5.appliedAdds == 2, a5.text.debugDescription)

        // A6: anchors, including a grouping add anchored to a dropped fact.
        let a6doc = UserProfileDocument("## S\n  * a\n  * b\n## T\n- c\n")
        let a6 = a6doc.apply(try UserProfileDocument.parseReply("{\"drop\":[1,2],\"add\":[{\"text\":\"ab\",\"after\":2},{\"text\":\"ab2\",\"after\":2},{\"text\":\"end\"},{\"text\":\"bad\",\"after\":77}]}", factCount: 3))
        h.check("A6 add after a dropped anchor sits there with the anchor's prefix; same-anchor order kept; missing/invalid anchor → end with '- '",
                a6.text == "## S\n  * ab\n  * ab2\n## T\n- c\n- end\n- bad\n", a6.text.debugDescription)

        // A7: normalisation.
        let a7 = four.apply(try UserProfileDocument.parseReply("{\"edit\":[{\"id\":1,\"text\":\" line one\\nline two\\r\\nthree \"},{\"id\":2,\"text\":\"   \"},{\"id\":3,\"text\":\"# heading\"}],\"add\":[{\"text\":\"\"}]}", factCount: 4))
        h.check("A7 line breaks → one space, trimmed; empty or #-leading text invalid",
                a7.text == "- line one line two three\n- b\n- c\n- d\n" && a7.appliedEdits == 1 && a7.appliedAdds == 0, a7.text.debugDescription)

        // A8: empty sections and blank collapse.
        let a8doc = UserProfileDocument("## A\n- a1\n\n## B\n- b1\n\n## C\n- c1\n### C.1\n- c2\n\n\n## D (originally empty)\n")
        let a8 = a8doc.apply(try UserProfileDocument.parseReply("{\"drop\":[2,3,4]}", factCount: 4))
        h.check("A8 sections left without facts lose their heading (nested too); created blank runs collapse; originally empty section and original blank run untouched",
                a8.text == "## A\n- a1\n\n\n\n## D (originally empty)\n" || a8.text == "## A\n- a1\n\n## D (originally empty)\n",
                a8.text.debugDescription)
        let a8b = UserProfileDocument("- x\n\n- y\n\n- z\n").apply(try UserProfileDocument.parseReply("{\"drop\":[2]}", factCount: 3))
        h.check("A8 removing a fact between blanks leaves one blank", a8b.text == "- x\n\n- z\n", a8b.text.debugDescription)
        let a8c = UserProfileDocument("- x\n\n- y").apply(try UserProfileDocument.parseReply("{\"drop\":[1]}", factCount: 2))
        h.check("A8 leading blank created by a removal trimmed", a8c.text == "- y", a8c.text.debugDescription)

        // A9: empty profile.
        let a9 = UserProfileDocument("")
        h.check("A9 empty profile has no facts", a9.factCount == 0 && a9.numberedListing().isEmpty)
        let a9r = a9.apply(try UserProfileDocument.parseReply("{\"drop\":[1],\"add\":[{\"text\":\"new\"}]}", factCount: 0))
        h.check("A9 ids on an empty profile ignored; an add still lands", a9r.text == "- new" && a9r.appliedDrops == 0, a9r.text.debugDescription)

        // A10: all-invalid reply = completed no-change.
        let a10 = four.apply(try UserProfileDocument.parseReply("{\"drop\":[99],\"edit\":\"oops\",\"add\":5,\"merge\":[1]}", factCount: 4))
        h.check("A10 all-invalid reply changes nothing; each problem recorded", !a10.changed && a10.ignored.count == 4, "\(a10.ignored)")

        // A11: grouping.
        let a11doc = UserProfileDocument("- Owns a Pixel 3a\n- Owns a OnePlus 6T\n- Owns another Pixel\n- Vegan\n")
        let a11 = a11doc.apply(try UserProfileDocument.parseReply("{\"drop\":[1,2,3],\"add\":[{\"text\":\"Phones: Pixel 3a, OnePlus 6T, another Pixel\",\"after\":3}]}", factCount: 4))
        h.check("A11 grouping: three facts dropped and retired, one covering fact added in their place, size decreases",
                a11.text == "- Phones: Pixel 3a, OnePlus 6T, another Pixel\n- Vegan\n" && a11.retired.count == 3 && a11.sizeAfter < a11.sizeBefore,
                a11.text.debugDescription)
        // A11b: per-line byte identity of every untouched line after real application on a large profile.
        let big = UCMHarness.profile(size: 20_000, lineEnding: "\r\n")
        let bigDoc = UserProfileDocument(big)
        let bigResult = bigDoc.apply(try UserProfileDocument.parseReply("{\"drop\":[3,50,100],\"edit\":[{\"id\":7,\"text\":\"short\"}]}", factCount: bigDoc.factCount))
        let survivors = bigDoc.lines.enumerated().filter { ![3, 50, 100, 7].map { bigDoc.factLineIndices[$0 - 1] }.contains($0.offset) }.map { $0.element.raw }
        let after = UserProfileDocument(bigResult.text).lines.map(\.raw)
        h.check("A1 every untouched line of a 20k CRLF profile is byte-identical after application",
                survivors.allSatisfy { after.contains($0) } && after.count == bigDoc.lines.count - 3)
    }

    static func replyRows(_ h: UCMHarness) async throws {
        // R1: fences / prose / NO_CHANGES / {}.
        let fenced = try UserProfileDocument.parseReply("Here you go:\n```json\n{\"drop\":[2],\"edit\":[{\"id\":1,\"text\":\"has } brace and \\\" quote\"}]}\n```\nDone.", factCount: 3)
        h.check("R1 fence and prose stripped; braces inside strings handled", fenced.drop == [2] && fenced.edit.first?.text == "has } brace and \" quote")
        h.check("R1 NO_CHANGES = no change", try UserProfileDocument.parseReply("  NO_CHANGES \n", factCount: 3).isEmpty)
        h.check("R1 {} = no change", try UserProfileDocument.parseReply("{}", factCount: 3).isEmpty)
        for (label, reply) in [("empty", ""), ("no object", "I'd drop fact 2."), ("truncated", "{\"drop\":[1,2"), ("array", "[1,2]")] {
            var failed = false
            do { _ = try UserProfileDocument.parseReply(reply, factCount: 3) } catch { failed = true }
            h.check("R1 \(label) reply is a failed attempt", failed)
        }
    }
}
