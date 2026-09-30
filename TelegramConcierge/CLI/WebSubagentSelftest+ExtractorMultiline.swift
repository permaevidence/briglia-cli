import Foundation

// Group 22, multi-line markup rows (2026-09-30). A link or image whose markup
// wraps onto the next line used to be split between two blocks when its first
// line was a heading, table row or image line (those closed their block at
// once): the second block got no visible marker, and selecting the first one
// returned half an image — no URL — while the image itself was suppressed from
// the image list because its START sat in a selected block. Now a markup never
// crosses a block boundary, no insertion is ever dropped, and an image/link is
// left out of the lists only when its WHOLE markup is in the returned excerpt.
extension WebSubagentSelftest {
    /// Every block marker visible exactly once and in order; every numbered
    /// link/image occurrence inside ONE block. Returns a failure note or nil.
    static func multilineInvariantFailure(_ page: String, maxBlockChars: Int?) -> String? {
        let a = WebPageLinks.annotate(page, pageURL: "https://ml.test/page", maxBlockChars: .some(maxBlockChars))
        var from = a.text.startIndex
        for n in 1...max(1, a.blocks.count) where !a.blocks.isEmpty {
            let marker = WebPageLinks.blockMarker(n)
            guard let r = a.text.range(of: marker, range: from..<a.text.endIndex) else { return "marker \(marker) missing" }
            if a.text.components(separatedBy: marker + " ").count != 2 { return "marker \(marker) not exactly once" }
            from = r.upperBound
        }
        for (kind, spans) in [("L", a.linkSpans), ("I", a.imageSpans)] {
            for (i, occurrences) in spans.enumerated() {
                for span in occurrences where !span.isEmpty {
                    guard let first = a.blockIndex(containing: span.lowerBound), let last = a.blockIndex(containing: span.upperBound - 1) else {
                        return "\(kind)\(i + 1) outside every block"
                    }
                    if first != last { return "\(kind)\(i + 1) crosses P\(first + 1)–P\(last + 1)" }
                }
            }
        }
        return nil
    }

    static func runExtractorMultilineRows(_ kit: LoopKit) async throws {
        let url = "https://example.test/connector.jpg"
        let multiline = "![A product photo\nshowing the correct connector](\(url))"
        let singleLine = "![A product photo showing the correct connector](\(url))"
        // Codex's reproduction: the image first, padding to 12,286 characters.
        func padded(_ head: String) -> String {
            var page = head + "\n\n"
            while page.utf16.count < 12_286 { page += "This is padding to exercise the large-page extraction route. " }
            return String(page.utf16.prefix(12_286))!
        }
        let codexPage = padded(multiline), controlPage = padded(singleLine)
        let reply = "{\"blocks\":[\"P1\"],\"links\":[],\"images\":[1]}"

        func run(_ page: String, _ reply: String, _ tag: String) async -> ScrapedDoc? {
            kit.scripts.reset()
            kit.scripts.push("excerpts", kit.envelope(reply, "stop", "stop", "gen-ml-\(tag)", 0.0003))
            return await kit.extract(page, "which connector is correct").0?.docs.first
        }
        let codexAnn = WebPageLinks.annotate(codexPage, pageURL: "https://example.test/any")
        let codex = await run(codexPage, reply, "codex")
        let control = await run(controlPage, reply, "control")
        let imageOnly = await run(codexPage, "{\"blocks\":[\"P2\"],\"links\":[],\"images\":[1]}", "img")
        kit.check("22.9e Codex reproduction (12,286-char page starting with an image whose caption wraps): every ⟨Pn⟩ is visible, the whole image markup is block P1; the model picking P1 (and I1) returns the COMPLETE caption and URL in the excerpt; picking only I1 lists the image with its URL",
                  codexPage.utf16.count == 12_286 && multilineInvariantFailure(codexPage, maxBlockChars: 1_500) == nil
                  && codexAnn.text.hasPrefix("⟨P1⟩ ![A product photo\nshowing the correct connector]⟨I1⟩\n\n⟨P2⟩ ")
                  && codex?.excerpts.first == multiline && codex?.images.isEmpty == true
                  && imageOnly?.images.map(\.url) == [url] && imageOnly?.excerpts.first?.contains(url) == false,
                  "\(String(codexAnn.text.prefix(90))) → \(codex?.excerpts.first.map { String($0.prefix(80)) } ?? "nil") images \(codex?.images.map(\.url) ?? [])")
        kit.check("22.9f single-line control: the same page with a one-line caption gives the same result (P1 is the whole image, the excerpt holds caption and URL)",
                  multilineInvariantFailure(controlPage, maxBlockChars: 1_500) == nil && control?.excerpts.first == singleLine && control?.images.isEmpty == true,
                  "\(control?.excerpts.first.map { String($0.prefix(80)) } ?? "nil")")

        // Wrapped markup in every line kind, each on a page past the small-page bypass.
        let filler = "\n\n" + String(repeating: "Unrelated filler sentence for size. ", count: 260)
        let kinds: [(name: String, head: String, markup: String)] = [
            ("heading", "# [A product\nmanual](https://ml.test/manual) for X", "[A product\nmanual](https://ml.test/manual)"),
            ("table row", "| [cell\nlink](https://ml.test/cell) | b |\n| c | d |", "[cell\nlink](https://ml.test/cell)"),
            ("list item", "* [wrapped\nitem](https://ml.test/item) end\n* next", "[wrapped\nitem](https://ml.test/item)"),
            ("link-only line", "[Dealer\nlocator](https://ml.test/dealers)\n\n[Returns](https://ml.test/returns)", "[Dealer\nlocator](https://ml.test/dealers)"),
            ("paragraph", "See the [spec\nsheet](https://ml.test/spec) here.", "[spec\nsheet](https://ml.test/spec)"),
            ("image line, nested link", "![Image 1: [nested](https://ml.test/a)\ncaption](https://ml.test/image.jpg)", "![Image 1: [nested](https://ml.test/a)\ncaption](https://ml.test/image.jpg)"),
            ("image in a link", "[![logo\nwide](https://ml.test/logo.png)\nHome](https://ml.test/home)", "[![logo\nwide](https://ml.test/logo.png)\nHome](https://ml.test/home)"),
            ("heading, image", "## ![Chart\nof sales](https://ml.test/chart.png)", "![Chart\nof sales](https://ml.test/chart.png)"),
        ]
        var failures: [String] = []
        for k in kinds {
            let page = "Intro line.\n\n" + k.head + filler
            for size in [nil, 1_500, 40] as [Int?] {
                if let f = multilineInvariantFailure(page, maxBlockChars: size) { failures.append("\(k.name)/\(size.map(String.init) ?? "natural"): \(f)") }
            }
            // The block holding the markup copies it back whole.
            let a = WebPageLinks.annotate(page, pageURL: "https://ml.test/page", maxBlockChars: .some(1_500))
            guard let o = page.range(of: k.markup)?.lowerBound.utf16Offset(in: page), let b = a.blockIndex(containing: o) else { failures.append("\(k.name): markup not found"); continue }
            let excerpt = a.excerpts(for: [b + 1]).first ?? ""
            if !excerpt.contains(k.markup) { failures.append("\(k.name): excerpt P\(b + 1) lacks the full markup") }
        }
        kit.check("22.9g wrapped links and images in every line kind (heading, table row, list item, link-only line, paragraph, image line with a nested link, an image inside a link, an image in a heading): natural, 1,500 and 40-char limits — all block markers visible, every markup inside one block, the block's excerpt holds the full markup",
                  failures.isEmpty, failures.joined(separator: "; "))

        // Completeness rule for suppression, independent of the block builder:
        // a markup straddling two blocks is "in the excerpt" only when both are selected.
        let text = "![cap\nline two](https://ml.test/x.jpg)\n\nTail."
        let u = Array(text.utf16)
        let nl = u.firstIndex(of: WebPageLinks.nl)!, end = text.range(of: ")")!.upperBound.utf16Offset(in: text)
        let straddling = WebPageLinks.Annotated(text: "", links: [], images: [ExtractedImage(caption: "cap\nline two", url: "https://ml.test/x.jpg")],
                                                blocks: [0..<nl, (nl + 1)..<end, (end + 2)..<u.count], original: u,
                                                linkSpans: [], imageSpans: [[0..<end]])
        let firstOnly = WebOrchestrator.resolvePicks(page: straddling, blocks: [BlockPick(first: 1, last: 1)], links: [], images: [.number(1)])
        let both = WebOrchestrator.resolvePicks(page: straddling, blocks: [BlockPick(first: 1, last: 2)], links: [], images: [.number(1)])
        let split = WebOrchestrator.resolvePicks(page: straddling, blocks: [BlockPick(first: 1, last: 1), BlockPick(first: 3, last: 3)], links: [], images: [.number(1)])
        kit.check("22.9h a picked image is left out of the image list only when its WHOLE markup is in the excerpt: start-only (P1 of a straddling image) → listed with its URL; P1–P2 → not repeated; P1 + P3 (gap) → listed",
                  firstOnly.images.map(\.url) == ["https://ml.test/x.jpg"] && both.images.isEmpty && both.excerpts.first?.contains("](https://ml.test/x.jpg)") == true
                  && split.images.map(\.url) == ["https://ml.test/x.jpg"],
                  "firstOnly \(firstOnly.images.count) both \(both.images.count) split \(split.images.count)")

        // A reader caption line ending inside a wrapped link: its marker is emitted, not dropped.
        let captionPage = "Image [4]: a photo with [a wrapped\nlink](https://ml.test/w) inside\n\nMore text."
        let cap = WebPageLinks.annotate(captionPage, pageURL: "https://ml.test/page")
        kit.check("22.9i a reader caption whose line ends inside a wrapped link keeps its ⟨I1⟩ marker (emitted right after the link), every block marker visible",
                  cap.images.count == 1 && cap.text.components(separatedBy: WebPageLinks.imageMarker(1)).count == 2
                  && multilineInvariantFailure(captionPage, maxBlockChars: 1_500) == nil,
                  cap.text)

        // Seeded mix of every line kind with wrapped markup: the invariants hold.
        var rng = SplitMix64(seed: 0x9E3779B97F4A7C15)
        var fuzzFailures: [String] = []
        for round in 0..<300 {
            var page = ""
            for _ in 0..<Int(rng.next() % 12 + 3) {
                let word = ["alpha", "beta\ngamma", "delta epsilon", "zeta\neta theta"][Int(rng.next() % 4)]
                let markup = rng.next() % 2 == 0 ? "[\(word)](https://f.test/\(rng.next() % 50))" : "![\(word)](https://f.test/i\(rng.next() % 30).png)"
                let prefix = ["# ", "| ", "* ", "1. ", "", "Some text ", "## ", "- "][Int(rng.next() % 8)]
                page += prefix + markup + (rng.next() % 3 == 0 ? " tail" : "") + (rng.next() % 2 == 0 ? "\n\n" : "\n")
            }
            for size in [nil, 1_500, 25] as [Int?] {
                if let f = multilineInvariantFailure(page, maxBlockChars: size) { fuzzFailures.append("round \(round)/\(size.map(String.init) ?? "natural"): \(f)"); break }
            }
            if fuzzFailures.count >= 3 { break }
        }
        kit.check("22.9j 300 seeded pages mixing every line kind with wrapped links/images (natural, 1,500, 25-char limits): every block marker visible once, no markup ever crosses a block boundary",
                  fuzzFailures.isEmpty, fuzzFailures.joined(separator: "; "))
    }
}

/// Deterministic generator for the seeded rows.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
