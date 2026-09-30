import Foundation

// Group 22, one-pass rows (2026-09-30): blocks, links and images numbered in
// place, one request per chunk, selection by number, verbatim copy-back.
extension WebSubagentSelftest {
    static func runExtractorOnePassRows(_ kit: LoopKit, shopRequests: [WebFixtureServer.Request]) async throws {
        let ann = WebPageLinks.annotate(loopShopPage, pageURL: "https://example.test/any")
        func linkNumber(_ url: String) -> Int { (ann.links.firstIndex { $0.url == url } ?? -1) + 1 }
        func imageNumber(_ url: String) -> Int { (ann.images.firstIndex { $0.url == url } ?? -1) + 1 }
        func block(containing needle: String) -> Int {
            guard let r = loopShopPage.range(of: needle) else { return 0 }
            let o = r.lowerBound.utf16Offset(in: loopShopPage)
            return (ann.blocks.firstIndex { $0.contains(o) } ?? -1) + 1
        }
        func original(_ n: Int) -> String { String(decoding: ann.original[ann.blocks[n - 1]], as: UTF16.self) }

        // 22.3 One request, the whole page numbered in place.
        let stages = shopRequests.compactMap(kit.stageOf)
        let request = shopRequests.first { kit.stageOf($0) == "excerpts" }
        let content = request.map(kit.userContent) ?? ""
        let schema = ((request.map { kit.body($0)["response_format"] as? [String: Any] } ?? nil)?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        let itemType = { (k: String) in ((props?[k] as? [String: Any])?["items"] as? [String: Any])?["type"] as? String }
        kit.check("22.3 one extraction request per page (no assets request): the TEXT is the page split into numbered blocks with every link/image numbered inside (no URL left); the strict schema asks for block strings and integer links/images, never text",
                  stages == ["excerpts"] && content.contains(ann.text) && !ann.text.contains("](http") && ann.text.hasPrefix("⟨P1⟩ ")
                  && (1...ann.blocks.count).allSatisfy { ann.text.contains(WebPageLinks.blockMarker($0) + " ") }
                  && itemType("blocks") == "string" && itemType("links") == "integer" && itemType("images") == "integer"
                  && (schema?["required"] as? [String]).map(Set.init) == ["blocks", "links", "images"] && props?["excerpts"] == nil,
                  String(content.prefix(300)))
        let menu = block(containing: "[MENU1]"), menuEnd = block(containing: "[MENU60]")
        kit.check("22.4 numbering: the 60-link menu (blank lines between items) is one block run with each link numbered; heading and paragraphs are their own blocks; the same URL keeps one number; the page itself, #anchors and javascript: stay unnumbered; no candidate limit (all 69 links numbered)",
                  menu > 0 && menuEnd >= menu && menuEnd - menu <= 1 && block(containing: "# Widget X100 Pro") != menu
                  && ann.text.contains("[manual again]⟨L\(linkNumber("https://shop.test/p/x100-1"))⟩") && ann.text.contains("[Skip to content]\n")
                  && ann.text.contains("[the top] or [js].") && ann.links.count == 69
                  && ["https://shop.test/login", "https://instagram.com/shop", "https://shop.test/privacy", "https://shop.test/returns"].allSatisfy { linkNumber($0) > 0 },
                  "menu P\(menu)–P\(menuEnd), \(ann.links.count) links, \(ann.blocks.count) blocks")

        // 22.5 Small page: no model request at all.
        let small = "# Small\n\nSee [the spec](https://example.test/spec) and ![a chart](https://example.test/c.png)."
        let (smallOut, smallReqs) = await kit.extract(small, "small")
        kit.check("22.5 a page of ≤ 8,000 characters makes no model request: its raw text (links inline) is the excerpt, no separate link/image lists",
                  smallReqs.filter { kit.stageOf($0) != nil }.isEmpty && smallOut?.docs.first?.excerpts == [small]
                  && smallOut?.docs.first?.links.isEmpty == true && smallOut?.docs.first?.images.isEmpty == true,
                  "\(smallReqs.count) requests")

        // 22.6 Mapping end to end.
        let wallBlock = block(containing: "[Wall mount for X100"), heading = block(containing: "# Widget X100 Pro")
        let returns = linkNumber("https://shop.test/returns"), login = linkNumber("https://shop.test/login")
        let wall = linkNumber("https://shop.test/p/x100-2")
        let reply: [String: Any] = ["blocks": ["P\(wallBlock)-P\(wallBlock + 1)", "P\(heading)", "P99999", "junk"],
                                    "links": [returns, 99_999, returns, wall, login],
                                    "images": [imageNumber("https://cdn.shop.test/x100-front.jpg"), 500]]
        kit.scripts.reset()
        kit.scripts.push("excerpts", kit.envelope(String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self), "stop", "stop", "gen-map", 0.0003))
        let (mapOut, _) = await kit.extract(loopShopPage, "Widget X100 returns and wall mount")
        let doc = mapOut?.docs.first
        let run = String(decoding: ann.original[ann.blocks[wallBlock - 1].lowerBound..<ann.blocks[wallBlock].upperBound], as: UTF16.self)
        kit.check("22.6 mapping: selected blocks come back verbatim from the original markdown in page order (a range is one excerpt, links/images restored in place, no markers); picks map to exact URLs in pick order (footer Returns and Login), duplicates once, a link inside a selected block not repeated; out-of-range and malformed picks dropped and logged",
                  doc?.excerpts == [original(heading), run] && doc?.excerpts.allSatisfy({ loopShopPage.contains($0) && !$0.contains("⟨") }) == true
                  && run.contains("](https://shop.test/p/x100-2 \"Wall mount for X100\")")
                  && doc?.links.map(\.url) == ["https://shop.test/returns", "https://shop.test/login"]
                  && doc?.images.map(\.url) == ["https://cdn.shop.test/x100-front.jpg"]
                  && kit.logText().contains("extract.excerpts picks: dropped 4 (out of range or malformed; page has \(ann.blocks.count) blocks, 69 links"),
                  "\(doc?.excerpts.map { String($0.prefix(40)) } ?? []) \(doc?.links.map(\.url) ?? [])")

        // 22.7 Resolver: union over chunks, overlap/adjacency merge, reversed ranges.
        let merged = WebOrchestrator.resolvePicks(page: ann, blocks: [BlockPick.parse("P3-P5")!, BlockPick.parse("P7-P4")!, BlockPick.parse("P9")!, BlockPick.parse("P8")!,
                                                                      BlockPick(first: 0, last: 2)],
                                                  links: [.number(returns), .number(login), .number(login)], images: [])
        let expected = String(decoding: ann.original[ann.blocks[2].lowerBound..<ann.blocks[8].upperBound], as: UTF16.self)
        kit.check("22.7 picks from several chunks union: overlapping (P3-P5, P4-P7) and adjacent (P8, P9) blocks merge into ONE excerpt equal to the original slice P3…P9; a reversed range is read in order; a range starting at 0 is dropped whole",
                  merged.excerpts == [expected] && merged.dropped == 1 && merged.links.map(\.url) == ["https://shop.test/returns", "https://shop.test/login"], "")
        runExtractorParserRows(kit)
        runExtractorBlockRows(kit)
    }

    /// 22.8: the parser behind web_fetch's lists.
    static func runExtractorParserRows(_ kit: LoopKit) {
        let parsed = WebPageLinks.parse("""
        [MOUNTAINBIKE](https://www.cube.eu/bikes/mountainbike "MOUNTAINBIKE")
        [![Image 2: Go to homepage](https://file.cube.eu/logo.svg?ts=1)](https://www.cube.eu/ "Go to homepage")
        [Trunk Bag PRO 10 RILink ![Image 45: ACID Trunk Bag PRO 10 RILink](https://file.cube.eu/93131.png?ts=1790653877) Details](https://www.cube.eu/acid-trunk-bag-pro-10-rilink/93131 "ACID Trunk Bag PRO 10 RILink")
        [Colosseo](https://it.wikipedia.org/wiki/Colosseo_(metropolitana_di_Roma))
        [Angle](<https://example.test/a b>) \\[not](https://example.test/escaped) [mail](mailto:x@example.test) [rel](/relative)
        """)
        kit.check("22.8 parser (web_fetch lists): no title glued onto a URL; image-wrapped link → link URL with alt text; a link wrapping an image keeps its URL and text; balanced parentheses; <url>; escaped/mailto/relative not in the http list; web_fetch keeps page order, first 50",
                  parsed.links.map(\.url) == ["https://www.cube.eu/bikes/mountainbike", "https://www.cube.eu/", "https://www.cube.eu/acid-trunk-bag-pro-10-rilink/93131",
                                              "https://it.wikipedia.org/wiki/Colosseo_(metropolitana_di_Roma)", "https://example.test/a"]
                  && parsed.links.map(\.text) == ["MOUNTAINBIKE", "Go to homepage", "Trunk Bag PRO 10 RILink Details", "Colosseo", "Angle"]
                  && parsed.images.map(\.url) == ["https://file.cube.eu/logo.svg?ts=1", "https://file.cube.eu/93131.png?ts=1790653877"]
                  && WebPageLinks.pageOrder(loopShopPage).links.count == 50 && WebPageLinks.pageOrder(loopShopPage).links[1].url == "https://shop.test/menu/1",
                  "\(parsed.links.map(\.url))")
    }
}
