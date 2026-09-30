import Foundation

// Group 22, block rows (2026-09-30): block structure and size limit, the
// copy-back property, numbering rules on a tricky page, pick decoding.
extension WebSubagentSelftest {
    static func runExtractorBlockRows(_ kit: LoopKit) {
        let tricky = """
        URL Source: https://t.test/page
        Intro [A](https://t.test/a "Title (a)") and [![Image 1: logo](https://t.test/l.svg)](https://t.test/) then [B ![Image 2: b](https://t.test/b.png) more](https://t.test/b).
        Image [3]: a reader caption line

        # Heading one

        * item one with [Wiki](https://w.test/X_(y))
        * item two [mail](mailto:m@t.test)

        | a | b |
        | [rel](/docs/x) | [self](https://t.test/page#s) |

        [ad](https://ad.doubleclick.net/x)

        [A again](https://t.test/a)

        [C](https://t.test/c)
        * * *
        ```
        code [x](https://t.test/code) line

        still code
        ```
        ![data](data:image/png;base64,AAAA) Unicode: café ✓ [Ü](https://t.test/ü) end
        """
        // Every block is an exact slice, blocks are ordered and disjoint, each
        // marker appears once in order, and any adjacent run is an exact slice.
        func blocksHold(_ text: String, max: Int?) -> (ok: Bool, count: Int, largest: Int) {
            let a = WebPageLinks.annotate(text, pageURL: "https://t.test/page", maxBlockChars: .some(max))
            var ok = true, previousEnd = 0
            for (i, b) in a.blocks.enumerated() {
                ok = ok && b.lowerBound >= previousEnd && !b.isEmpty && b.upperBound <= a.original.count
                previousEnd = b.upperBound
                let slice = String(decoding: a.original[b], as: UTF16.self)
                ok = ok && text.contains(slice)
                if i + 1 < a.blocks.count {
                    let run = a.excerpts(for: [i + 1, i + 2])
                    ok = ok && run.count == 1 && text.contains(run[0])
                }
                // A cut never lands inside a word: a block starting mid-line
                // follows whitespace.
                if b.lowerBound > 0, a.original[b.lowerBound - 1] != WebPageLinks.nl {
                    ok = ok && [WebPageLinks.space, WebPageLinks.tab].contains(a.original[b.lowerBound - 1])
                }
            }
            var searchFrom = a.text.startIndex
            for n in 1...Swift.max(1, a.blocks.count) where !a.blocks.isEmpty {
                guard let r = a.text.range(of: WebPageLinks.blockMarker(n) + " ", range: searchFrom..<a.text.endIndex) else { ok = false; break }
                searchFrom = r.upperBound
            }
            return (ok, a.blocks.count, a.blocks.map(\.count).max() ?? 0)
        }
        let t = WebPageLinks.annotate(tricky, pageURL: "https://t.test/page", maxBlockChars: .some(nil))
        let codeBlock = t.blocks.first { String(decoding: t.original[$0], as: UTF16.self).hasPrefix("```") }.map { String(decoding: t.original[$0], as: UTF16.self) }
        let natural = blocksHold(tricky, max: nil), tight = blocksHold(tricky, max: 30)
        let shop = blocksHold(loopShopPage, max: 600), shopNatural = blocksHold(loopShopPage, max: nil)
        kit.check("22.9 blocks: every block and every adjacent run is an exact slice of the original, blocks are ordered and disjoint, each ⟨Pn⟩ appears once in order, cuts never fall mid-word or inside a link — natural and with small limits (tricky page, shop page); a fenced code block (blank line inside) stays one block; thematic breaks separate blocks",
                  natural.ok && tight.ok && shop.ok && shopNatural.ok && tight.count > natural.count && shop.count >= shopNatural.count
                  && codeBlock?.hasSuffix("```") == true && codeBlock?.contains("still code") == true
                  && !t.blocks.contains { String(decoding: t.original[$0], as: UTF16.self).trimmingCharacters(in: .whitespaces) == "* * *" },
                  "natural \(natural) tight \(tight) shop \(shop)/\(shopNatural)")
        kit.check("22.9a numbering on the tricky page: one number per URL, mailto numbered, relative resolved, self/tracking/data unnumbered (text kept), the reader caption numbered at its line end",
                  t.links.map(\.url) == ["https://t.test/a", "https://t.test/", "https://t.test/b", "https://w.test/X_(y)", "mailto:m@t.test",
                                         "https://t.test/docs/x", "https://t.test/c", "https://t.test/code", "https://t.test/ü"]
                  && t.images.map { $0.url ?? "caption" } == ["caption", "https://t.test/l.svg", "https://t.test/b.png"]
                  && t.text.contains("Image [3]: a reader caption line ⟨I1⟩") && t.text.contains("[A again]⟨L1⟩") && t.text.contains("[ad]\n")
                  && t.text.contains("[self] |") && t.text.contains("![data] Unicode"),
                  "\(t.links.map(\.url)) \(t.images.map { $0.url ?? "caption" })")

        // Size limit: a long paragraph splits at sentence ends before the limit.
        let sentence = "This sentence is about the widget and it has several words in it. "
        let paragraph = String(repeating: sentence, count: 80)   // ~5,300 chars, one line
        let split = WebPageLinks.annotate(paragraph, pageURL: "https://t.test/p", maxBlockChars: .some(1_500))
        let pieces = split.blocks.map { String(decoding: split.original[$0], as: UTF16.self) }
        kit.check("22.9c size limit 1,500: a 5,300-char one-line paragraph becomes 4 consecutive blocks of ≤ 1,500 chars cut after sentence ends, whose concatenation is the paragraph",
                  pieces.count == 4 && pieces.allSatisfy { $0.utf16.count <= 1_500 } && pieces.dropLast().allSatisfy { $0.hasSuffix(". ") }
                  && pieces.joined() == paragraph && WebPageLinks.maxBlockChars == 1_500,
                  "\(pieces.map(\.utf16.count))")

        let picks = try? JSONDecoder().decode(BlockPicksOut.self, from: Data("{\"blocks\":[\"P12\",\"P12-P15\",\"12-15\",\"P15–P12\",\"⟨P7⟩\",9,\"P3..P4\",\"abc\",\"P\",null],\"links\":[1,\"L3\",\"junk\"]}".utf8))
        kit.check("22.9d block picks decode leniently (\"P12\", ranges with -, –, .., bare numbers, markers, reversed ranges); malformed elements (\"abc\", \"P\", null, \"junk\") are counted, not fatal; missing images list is empty",
                  picks?.blocks == [BlockPick(first: 12, last: 12), BlockPick(first: 12, last: 15), BlockPick(first: 12, last: 15), BlockPick(first: 12, last: 15),
                                    BlockPick(first: 7, last: 7), BlockPick(first: 9, last: 9), BlockPick(first: 3, last: 4)]
                  && picks?.links == [.number(1), .number(3)] && picks?.images == [] && picks?.malformed == 4,
                  "\(String(describing: picks?.blocks)) malformed \(picks?.malformed ?? -1)")
    }
}
