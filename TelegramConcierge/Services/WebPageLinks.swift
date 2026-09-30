import Foundation

/// Markdown links and images of a fetched page: a bracket/paren parser (shared
/// with `web_fetch`) and the in-place numbering used by `extract.excerpts`.
///
/// History (2026-09-29/30): a separate `extract.assets` request chose links
/// from a list it could not see in context (the first 50 = the site menu,
/// URLs JSON-escaped, titles glued onto URLs), while the excerpts request saw
/// the links in context but was not asked for them — and retyped its quotes,
/// the slow and expensive part. Now there is ONE request per chunk and the
/// model writes no text: the page is split into structural blocks numbered in
/// place (`⟨P12⟩`), every link and image inside carries a page-wide number
/// (`[Stereo Hybrid 140]⟨L12⟩`, `![caption]⟨I3⟩`); the model answers with
/// block numbers/ranges and link/image numbers. Briglia copies the selected
/// blocks verbatim from the original markdown and maps numbers to exact URLs.
/// Nothing is dropped by category and there is no candidate limit: a menu or
/// footer link ("Dealers", "Returns", "Contact") can be exactly what a
/// question needs. Only exact duplicates (same URL → same number), links to
/// the page itself, `#` anchors, `javascript:` and obvious tracking links go
/// unnumbered.
enum WebPageLinks {
    struct Link: Equatable {
        let text: String
        let url: String
        /// UTF-16 offset of the link markup in the page.
        let offset: Int
    }
    struct Image: Equatable {
        /// Raw alt text / caption, as the reader produced it.
        let caption: String
        let url: String?
        let offset: Int
    }
    struct Parsed {
        var links: [Link] = []
        /// Markdown images (`![alt](url)`, including those nested in links), page order.
        var images: [Image] = []
        /// Reader captions without a URL (`Image [n]: caption`), page order.
        var captionOnlyImages: [Image] = []
    }

    // MARK: Scanner primitives

    static let lb = UInt16(UInt8(ascii: "[")), rb = UInt16(UInt8(ascii: "]"))
    static let lp = UInt16(UInt8(ascii: "(")), rp = UInt16(UInt8(ascii: ")"))
    static let bang = UInt16(UInt8(ascii: "!")), bslash = UInt16(UInt8(ascii: "\\"))
    static let nl = UInt16(UInt8(ascii: "\n")), quote = UInt16(UInt8(ascii: "\""))
    static let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))

    /// A markdown link/image at `i` (the `[`): (close bracket, target text, index of the closing `)`).
    static func markup(_ u: [UInt16], _ i: Int, _ to: Int) -> (close: Int, target: String, end: Int)? {
        guard u[i] == lb, i == 0 || u[i - 1] != bslash,
              let close = matchBracket(u, i, to), close + 1 < to, u[close + 1] == lp,
              let (target, end) = parseTarget(u, close + 2, to) else { return nil }
        return (close, target, end)
    }

    /// Index of the `]` closing the `[` at `open` (nested brackets counted,
    /// backslash escapes skipped); nil past a blank line or a long span.
    static func matchBracket(_ u: [UInt16], _ open: Int, _ to: Int) -> Int? {
        var depth = 0, j = open
        let limit = min(to, open + 4000)
        while j < limit {
            let c = u[j]
            if c == bslash { j += 2; continue }
            if c == nl, j + 1 < limit, u[j + 1] == nl { return nil }
            if c == lb { depth += 1 } else if c == rb { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }

    /// The `(...)` target starting at `start` (just after `(`): balanced
    /// parentheses, a quoted title may contain anything; stops at a newline.
    static func parseTarget(_ u: [UInt16], _ start: Int, _ to: Int) -> (String, Int)? {
        var depth = 1, j = start, inQuote = false
        let limit = min(to, start + 4000)
        while j < limit {
            let c = u[j]
            if c == nl { return nil }
            if inQuote {
                if c == quote { inQuote = false }
            } else if c == quote, j > start, u[j - 1] == space || u[j - 1] == tab {
                inQuote = true
            } else if c == lp {
                depth += 1
            } else if c == rp {
                depth -= 1
                if depth == 0 { return (String(decoding: u[start..<j], as: UTF16.self), j) }
            }
            j += 1
        }
        return nil
    }

    /// The URL token of a link target (`url`, `url "title"`, `<url>`).
    static func targetURL(_ target: String) -> String {
        var t = target.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<"), let close = t.firstIndex(of: ">") { t = String(t[t.index(after: t.startIndex)..<close]) }
        return String(t.prefix { !$0.isWhitespace })
    }

    /// The URL part of a link target, when http(s).
    static func httpURL(_ target: String) -> String? {
        let url = targetURL(target)
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), url.count > 8 else { return nil }
        return url
    }

    static func cleanText(_ text: String) -> String {
        let noEmphasis = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return noEmphasis.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `Image 27: A black …` → `A black …` (the reader's numbering prefix).
    static func cleanCaption(_ caption: String) -> String {
        var c = cleanText(caption)
        if c.hasPrefix("Image "), let colon = c.firstIndex(of: ":"),
           c[c.index(c.startIndex, offsetBy: 6)..<colon].allSatisfy(\.isNumber) {
            c = String(c[c.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return c
    }

    /// Link text with every nested `![alt](url)` removed; the nested images'
    /// alt texts when nothing else remains.
    static func linkText(_ inner: String) -> String {
        let u = Array(inner.utf16)
        var out: [UInt16] = []
        var alts: [String] = []
        var i = 0
        while i < u.count {
            if u[i] == bang, i + 1 < u.count, let m = markup(u, i + 1, u.count) {
                alts.append(cleanCaption(String(decoding: u[(i + 2)..<m.close], as: UTF16.self)))
                i = m.end + 1
                continue
            }
            out.append(u[i]); i += 1
        }
        let text = cleanText(String(decoding: out, as: UTF16.self))
        return text.isEmpty ? cleanText(alts.joined(separator: " ")) : text
    }

    private static func readerCaptions(_ markdown: String) -> [(caption: String, lineEnd: Int, offset: Int)] {
        guard let regex = try? NSRegularExpression(pattern: #"Image \[(\d+)\]: ([^\n]+)"#) else { return [] }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.matches(in: markdown, range: range).compactMap { match in
            guard let r = Range(match.range(at: 2), in: markdown) else { return nil }
            return (String(markdown[r]), match.range.location + match.range.length, match.range.location)
        }
    }

    // MARK: web_fetch (page order, parse fixed)

    /// Every http(s) markdown link and image, in page order.
    static func parse(_ markdown: String) -> Parsed {
        let u = Array(markdown.utf16)
        var out = Parsed()
        func scan(_ from: Int, _ to: Int, nested: Bool) {
            var i = from
            while i < to {
                guard let m = markup(u, i, to) else { i += 1; continue }
                let isImage = i > 0 && u[i - 1] == bang
                let inner = String(decoding: u[(i + 1)..<m.close], as: UTF16.self)
                if let url = httpURL(m.target) {
                    if isImage {
                        out.images.append(Image(caption: inner, url: url, offset: i - 1))
                    } else {
                        scan(i + 1, m.close, nested: true)   // images nested in the link text
                        if !nested { out.links.append(Link(text: linkText(inner), url: url, offset: i)) }
                    }
                }
                i = m.end + 1
            }
        }
        scan(0, u.count, nested: false)
        out.captionOnlyImages = readerCaptions(markdown).map { Image(caption: $0.caption, url: nil, offset: $0.offset) }
        return out
    }

    /// `web_fetch` keeps its page-order lists (first 50 links, first 20
    /// images: markdown images, then reader captions) — only the parse is fixed.
    static func pageOrder(_ markdown: String) -> (links: [ExtractedLink], images: [ExtractedImage]) {
        let parsed = parse(markdown)
        let links = parsed.links.prefix(50).map { ExtractedLink(text: $0.text, url: $0.url) }
        let images = (parsed.images + parsed.captionOnlyImages).prefix(20).map { ExtractedImage(caption: $0.caption, url: $0.url) }
        return (links, images)
    }

    // MARK: In-place numbering (extract.excerpts)

    static let open: Character = "⟨", close: Character = "⟩"
    static func linkMarker(_ n: Int) -> String { "⟨L\(n)⟩" }
    static func imageMarker(_ n: Int) -> String { "⟨I\(n)⟩" }
    static func blockMarker(_ n: Int) -> String { "⟨P\(n)⟩" }

    /// Largest block (UTF-16 units of the original markdown) before a block
    /// is split; nil = natural blocks only. Chosen from the 2026-09-30 size
    /// sweep (see the review notes). Test seam.
    nonisolated(unsafe) static var maxBlockChars: Int? = 1_500

    static func urlKey(_ url: String) -> String {
        var s = url
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    private static let trackingHosts = ["doubleclick.net", "googleadservices.com", "google-analytics.com", "googletagmanager.com",
                                        "googlesyndication.com", "facebook.com/tr", "bat.bing.com", "ads.linkedin.com",
                                        "analytics.twitter.com", "scorecardresearch.com", "adservice.google."]

    /// An obvious tracker/ad beacon (never a page a researcher would read).
    static func isTracking(_ url: String) -> Bool {
        let lower = url.lowercased()
        return trackingHosts.contains { lower.contains($0) }
    }

    /// The page as the model sees it: structural blocks numbered in place
    /// (`⟨P12⟩`), every link and image numbered inside them. The model
    /// selects blocks by number; Briglia copies them from the ORIGINAL
    /// markdown, so an excerpt is verbatim by construction.
    struct Annotated {
        /// The page text the model sees.
        let text: String
        /// Link `L(n)` is `links[n - 1]` (text of its first occurrence).
        let links: [ExtractedLink]
        /// Image `I(n)` is `images[n - 1]` (URL nil for reader captions).
        let images: [ExtractedImage]
        /// Block `P(n)` is `blocks[n - 1]`: a UTF-16 range of the original.
        let blocks: [Range<Int>]
        let original: [UInt16]
        /// Original offsets of every occurrence of each link / image number.
        let linkOffsets: [[Int]]
        let imageOffsets: [[Int]]

        /// The selected blocks as excerpts: sorted, adjacent or overlapping
        /// block runs merged, each run the original slice from its first
        /// block's start to its last block's end (exact substring).
        func excerpts(for numbers: Set<Int>) -> [String] {
            let sorted = numbers.filter { $0 >= 1 && $0 <= blocks.count }.sorted()
            var runs: [ClosedRange<Int>] = []
            for n in sorted {
                if let last = runs.last, n == last.upperBound + 1 { runs[runs.count - 1] = last.lowerBound...n } else { runs.append(n...n) }
            }
            return runs.map { run in
                String(decoding: original[blocks[run.lowerBound - 1].lowerBound..<blocks[run.upperBound - 1].upperBound], as: UTF16.self)
            }
        }

        /// True when an occurrence of the offsets lies inside a selected block.
        func covered(_ offsets: [Int], by numbers: Set<Int>) -> Bool {
            offsets.contains { o in numbers.contains { n in n >= 1 && n <= blocks.count && blocks[n - 1].contains(o) } }
        }
    }

    // Line model for block building.
    private enum LineKind: Equatable { case blank, heading, fence, table, list, imageOnly, linkOnly, text }

    /// Top-level markup spans (`[`…`)`, with a leading `!` for images) and
    /// whether each is an image.
    private static func markupSpans(_ u: [UInt16]) -> [(range: Range<Int>, image: Bool)] {
        var spans: [(Range<Int>, Bool)] = []
        var i = 0
        while i < u.count {
            if let m = markup(u, i, u.count) {
                let image = i > 0 && u[i - 1] == bang
                spans.append(((image ? i - 1 : i)..<(m.end + 1), image))
                i = m.end + 1
            } else { i += 1 }
        }
        return spans
    }

    /// The structural blocks of `u`: paragraphs (between blank lines),
    /// headings, list items, table rows, image lines, code blocks; consecutive
    /// link-only lines (menus, footers) merge into one block; blocks longer
    /// than `maxChars` split at a line break, else a sentence end, else a
    /// space before the limit (never inside a word or a link/image markup).
    static func blocks(_ u: [UInt16], maxChars: Int?) -> [Range<Int>] {
        let spans = markupSpans(u)
        func insideMarkup(_ p: Int) -> Bool {
            var lo = 0, hi = spans.count
            while lo < hi { let mid = (lo + hi) / 2; if spans[mid].range.upperBound <= p { lo = mid + 1 } else { hi = mid } }
            return lo < spans.count && spans[lo].range.lowerBound < p
        }
        // Lines.
        var lines: [Range<Int>] = []
        var start = 0
        for (i, c) in u.enumerated() where c == nl { lines.append(start..<i); start = i + 1 }
        lines.append(start..<u.count)
        func kind(_ r: Range<Int>) -> LineKind {
            var s = r.lowerBound
            while s < r.upperBound, u[s] == space || u[s] == tab { s += 1 }
            if s >= r.upperBound { return .blank }
            // Thematic breaks (`* * *`, `---`, `___`) separate blocks like a blank line.
            let whole = String(decoding: u[s..<r.upperBound], as: UTF16.self).filter { !$0.isWhitespace }
            if whole.count >= 3, Set(whole).count == 1, let ch = whole.first, "*-_".contains(ch) { return .blank }
            let head = String(decoding: u[s..<min(r.upperBound, s + 8)], as: UTF16.self)
            if head.hasPrefix("```") || head.hasPrefix("~~~") { return .fence }
            if head.hasPrefix("#") { let h = head.prefix { $0 == "#" }.count; if h <= 6, head.dropFirst(h).first == " " { return .heading } }
            if head.hasPrefix("|") { return .table }
            // Link/image-only line: nothing but markups, whitespace and bullets.
            var p = s, links = 0, images = 0, other = false
            var k = spans.firstIndex { $0.range.upperBound > s } ?? spans.count
            while p < r.upperBound {
                if k < spans.count, spans[k].range.lowerBound == p {
                    if spans[k].image { images += 1 } else { links += 1 }
                    p = spans[k].range.upperBound; k += 1; continue
                }
                let c = u[p]
                if !(c == space || c == tab || c == UInt16(UInt8(ascii: "*")) || c == UInt16(UInt8(ascii: "-")) || c == UInt16(UInt8(ascii: "|")) || c == 0x00B7) { other = true; break }
                p += 1
            }
            if !other && links > 0 { return .linkOnly }
            if !other && images > 0 { return .imageOnly }
            if head.hasPrefix("* ") || head.hasPrefix("- ") || head.hasPrefix("+ ") { return .list }
            let digits = head.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 3, let d = head.dropFirst(digits.count).first, d == "." || d == ")",
               head.dropFirst(digits.count + 1).first == " " { return .list }
            return .text
        }
        // Group lines.
        var raw: [(range: Range<Int>, kind: LineKind)] = []
        var current: (range: Range<Int>, kind: LineKind)?
        var inFence = false
        func close() { if let c = current { raw.append(c) }; current = nil }
        for line in lines {
            let k = kind(line)
            if inFence {
                current = (current!.range.lowerBound..<line.upperBound, .fence)
                if k == .fence { inFence = false; close() }
                continue
            }
            if insideMarkup(line.lowerBound), let c = current {   // a link text wrapping onto this line
                current = (c.range.lowerBound..<line.upperBound, c.kind); continue
            }
            switch k {
            case .blank: close()
            case .fence: close(); current = (line, .fence); inFence = true
            case .heading, .table, .imageOnly: close(); raw.append((line, k))
            case .list: close(); current = (line, .list)
            case .linkOnly:
                if let c = current, c.kind == .linkOnly { current = (c.range.lowerBound..<line.upperBound, .linkOnly) }
                else { close(); current = (line, .linkOnly) }
            case .text:
                if let c = current, c.kind == .text || c.kind == .list { current = (c.range.lowerBound..<line.upperBound, c.kind) }
                else if let c = current, c.kind == .linkOnly, line.count <= 160 {
                    // A menu entry's one-line caption stays with its link.
                    current = (c.range.lowerBound..<line.upperBound, .linkOnly)
                }
                else { close(); current = (line, .text) }
            }
        }
        close()
        // Merge runs of link-only blocks (menus, footers: blank lines between
        // items) together with the short one-line labels among them ("BIKES",
        // "E-BIKES"): one block for the whole run; each link keeps its number.
        func short(_ b: (range: Range<Int>, kind: LineKind)) -> Bool {
            b.kind == .text && b.range.count <= 40 && !u[b.range].contains(nl)
        }
        var merged: [(range: Range<Int>, kind: LineKind)] = []
        for b in raw {
            if let last = merged.last, (last.kind == .linkOnly || short(last)), (b.kind == .linkOnly || short(b)) {
                let kind: LineKind = (last.kind == .linkOnly || b.kind == .linkOnly) ? .linkOnly : .text
                merged[merged.count - 1] = (last.range.lowerBound..<b.range.upperBound, kind)
            } else { merged.append(b) }
        }
        // Split oversized blocks.
        guard let maxChars, maxChars > 0 else { return merged.map(\.range) }
        func isWS(_ c: UInt16) -> Bool { c == space || c == tab || c == nl }
        var out: [Range<Int>] = []
        for b in merged.map(\.range) {
            var s = b.lowerBound
            while b.upperBound - s > maxChars {
                let limit = s + maxChars
                var cut: Int?
                // 1) a line break before the limit (cut after it)
                var p = limit
                while p > s + 1 { if u[p - 1] == nl, !insideMarkup(p) { cut = p; break }; p -= 1 }
                // 2) a sentence end (". ", "! ", "? ") before the limit
                if cut == nil {
                    p = limit
                    while p > s + 2 {
                        let c = u[p - 2]
                        if isWS(u[p - 1]), c == UInt16(UInt8(ascii: ".")) || c == UInt16(UInt8(ascii: "!")) || c == UInt16(UInt8(ascii: "?")), !insideMarkup(p) { cut = p; break }
                        p -= 1
                    }
                }
                // 3) a space before the limit; 4) else the next space after it
                if cut == nil {
                    p = limit
                    while p > s + 1 { if isWS(u[p - 1]), !insideMarkup(p) { cut = p; break }; p -= 1 }
                }
                if cut == nil {
                    p = limit
                    while p < b.upperBound { if isWS(u[p - 1]), !insideMarkup(p) { cut = p; break }; p += 1 }
                }
                guard let c = cut, c > s, c < b.upperBound else { break }
                out.append(s..<c)
                s = c
            }
            out.append(s..<b.upperBound)
        }
        return out
    }

    /// Number every block, link and image of `markdown` in place.
    static func annotate(_ markdown: String, pageURL: String, maxBlockChars: Int?? = nil) -> Annotated {
        let u = Array(markdown.utf16)
        let blockRanges = blocks(u, maxChars: maxBlockChars ?? Self.maxBlockChars)
        var pageKeys: Set<String> = [urlKey(pageURL)]
        if let sourceLine = markdown.prefix(2000).split(separator: "\n").first(where: { $0.hasPrefix("URL Source: ") }) {
            pageKeys.insert(urlKey(String(sourceLine.dropFirst("URL Source: ".count)).trimmingCharacters(in: .whitespaces)))
        }
        let base = URL(string: pageURL)
        var out: [UInt16] = []
        out.reserveCapacity(u.count + blockRanges.count * 8)
        var links: [ExtractedLink] = [], linkOffsets: [[Int]] = [], linkNumber: [String: Int] = [:]
        var images: [ExtractedImage] = [], imageOffsets: [[Int]] = [], imageNumber: [String: Int] = [:]
        // Insertions at original offsets: block markers and reader captions.
        var inserts: [(at: Int, text: String)] = blockRanges.enumerated().map { ($0.element.lowerBound, blockMarker($0.offset + 1) + " ") }
        for cap in readerCaptions(markdown) {
            let key = "caption:" + cap.caption
            let n = imageNumber[key] ?? {
                images.append(ExtractedImage(caption: cap.caption, url: nil)); imageOffsets.append([])
                imageNumber[key] = images.count; return images.count
            }()
            imageOffsets[n - 1].append(cap.offset)
            inserts.append((cap.lineEnd, " " + imageMarker(n)))
        }
        inserts.sort { $0.at < $1.at }
        var nextInsert = 0

        /// The link's resolved URL, or nil when it is not numbered.
        func linkURL(_ target: String) -> String? {
            let raw = targetURL(target)
            let lower = raw.lowercased()
            if raw.isEmpty || raw.hasPrefix("#") || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") { return nil }
            var url = raw
            if !(lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:")) {
                guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL.absoluteString,
                      resolved.lowercased().hasPrefix("http") else { return nil }
                url = resolved
            }
            if url.lowercased().hasPrefix("http"), pageKeys.contains(urlKey(url)) || isTracking(url) { return nil }
            return url
        }

        func walk(_ from: Int, _ to: Int, topLevel: Bool) {
            var i = from, copyStart = from
            func flush(_ upTo: Int) { if upTo > copyStart { out.append(contentsOf: u[copyStart..<upTo]) }; copyStart = upTo }
            while i <= to {
                if topLevel, nextInsert < inserts.count, inserts[nextInsert].at <= i {
                    let at = inserts[nextInsert].at
                    if at >= copyStart { flush(at); out.append(contentsOf: inserts[nextInsert].text.utf16) }
                    nextInsert += 1
                    continue
                }
                guard i < to else { break }
                guard let m = markup(u, i, to) else { i += 1; continue }
                let isImage = i > 0 && u[i - 1] == bang
                flush(i + 1)                     // through the `[`
                walk(i + 1, m.close, topLevel: false)
                out.append(rb)
                let inner = String(decoding: u[(i + 1)..<m.close], as: UTF16.self)
                if isImage {
                    if let url = httpURL(m.target), !isTracking(url) {
                        let n = imageNumber[url] ?? {
                            images.append(ExtractedImage(caption: inner, url: url)); imageOffsets.append([])
                            imageNumber[url] = images.count; return images.count
                        }()
                        imageOffsets[n - 1].append(i - 1)
                        out.append(contentsOf: imageMarker(n).utf16)
                    } else if !targetURL(m.target).lowercased().hasPrefix("data:") {
                        out.append(contentsOf: u[(m.close + 1)...m.end])
                    }
                } else if let url = linkURL(m.target) {
                    let text = linkText(inner)
                    let n: Int
                    if let known = linkNumber[url] {
                        n = known
                        if links[n - 1].text.isEmpty, !text.isEmpty { links[n - 1] = ExtractedLink(text: text, url: url) }
                    } else {
                        links.append(ExtractedLink(text: text, url: url)); linkOffsets.append([])
                        linkNumber[url] = links.count; n = links.count
                    }
                    linkOffsets[n - 1].append(i)
                    out.append(contentsOf: linkMarker(n).utf16)
                }
                // Self link, anchor, javascript:, tracking: text stays, target goes.
                i = m.end + 1
                copyStart = i
            }
            flush(to)
        }
        walk(0, u.count, topLevel: true)
        return Annotated(text: String(decoding: out, as: UTF16.self), links: links, images: images, blocks: blockRanges,
                         original: u, linkOffsets: linkOffsets, imageOffsets: imageOffsets)
    }

    // MARK: Mapping the model's numbers

    /// Map picks to links/images: 1-based numbers (`L3`/`I2`/"3" accepted),
    /// or a `{url}` equal to a known URL. Out-of-range/unknown picks are
    /// counted in `dropped`; duplicates kept once; pick order; no cap.
    static func map(_ picks: [PagePick], in table: [ExtractedLink]) -> (items: [ExtractedLink], numbers: [Int], dropped: Int) {
        resolve(picks, table.map(\.url), table)
    }
    static func map(_ picks: [PagePick], in table: [ExtractedImage]) -> (items: [ExtractedImage], numbers: [Int], dropped: Int) {
        resolve(picks, table.map(\.url), table)
    }
    private static func resolve<T>(_ picks: [PagePick], _ urls: [String?], _ table: [T]) -> (items: [T], numbers: [Int], dropped: Int) {
        var used = Set<Int>(), items: [T] = [], numbers: [Int] = [], dropped = 0
        for pick in picks {
            let index: Int?
            switch pick {
            case .number(let n): index = n >= 1 && n <= table.count ? n - 1 : nil
            case .url(let u): index = urls.firstIndex { $0 == u }
            }
            guard let index else { dropped += 1; continue }
            if used.insert(index).inserted { items.append(table[index]); numbers.append(index + 1) }
        }
        return (items, numbers, dropped)
    }
}

/// One pick in the model's `links`/`images` lists. Decoding is lenient for
/// gateways that ignore the schema (OpenCode): numbers, whole doubles, "3",
/// "L3"/"I2", "⟨L3⟩", `{number|n}` or `{url}` objects.
enum PagePick: Equatable, Decodable {
    case number(Int)
    case url(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .number(n); return }
        if let d = try? c.decode(Double.self), d.rounded() == d, abs(d) < 1e9 { self = .number(Int(d)); return }
        if let s = try? c.decode(String.self) {
            let t = s.trimmingCharacters(in: .whitespaces)
            let digits = t.filter { !"⟨⟩#LlIi".contains($0) }
            if let n = Int(digits) { self = .number(n); return }
            if t.lowercased().hasPrefix("http") { self = .url(t); return }
        }
        struct Object: Decodable { let url: String?; let number: Int?; let n: Int? }
        if let o = try? c.decode(Object.self) {
            if let n = o.number ?? o.n { self = .number(n); return }
            if let u = o.url { self = .url(u.trimmingCharacters(in: .whitespaces)); return }
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a pick")
    }
}

/// One block pick: `P12`, a range `P12-P15` (`–`, `—`, `..` and "to"
/// accepted, markers and a missing `P` tolerated), or a bare number.
struct BlockPick: Equatable, Decodable {
    let first: Int
    let last: Int
    init(first: Int, last: Int) { self.first = first; self.last = last }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self.init(first: n, last: n); return }
        guard let s = try? c.decode(String.self), let pick = BlockPick.parse(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a block pick")
        }
        self = pick
    }
    static func parse(_ raw: String) -> BlockPick? {
        var t = raw.replacingOccurrences(of: "⟨", with: "").replacingOccurrences(of: "⟩", with: "")
        for sep in ["–", "—", "..", " to "] { t = t.replacingOccurrences(of: sep, with: "-") }
        let parts = t.split(separator: "-", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).drop { $0 == "P" || $0 == "p" }
        }
        guard (1...2).contains(parts.count), let a = Int(parts[0]) else { return nil }
        let b = parts.count == 2 ? Int(parts[1]) : a
        guard let b else { return nil }
        return BlockPick(first: min(a, b), last: max(a, b))
    }
}

/// The extraction stage's answer: selected blocks plus the numbers of other
/// pertinent links and images. The model never writes text or URLs. Elements
/// that decode to no pick are skipped (counted by the caller as malformed).
struct BlockPicksOut: Decodable {
    let blocks: [BlockPick]
    let links: [PagePick]
    let images: [PagePick]
    /// Elements present in the reply that were not valid picks.
    let malformed: Int
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
    enum CodingKeys: String, CodingKey { case blocks, links, images }
    init(blocks: [BlockPick], links: [PagePick] = [], images: [PagePick] = [], malformed: Int = 0) {
        self.blocks = blocks; self.links = links; self.images = images; self.malformed = malformed
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let b = try c.decode([Lenient<BlockPick>].self, forKey: .blocks)
        let l = ((try? c.decodeIfPresent([Lenient<PagePick>].self, forKey: .links)) ?? nil) ?? []
        let i = ((try? c.decodeIfPresent([Lenient<PagePick>].self, forKey: .images)) ?? nil) ?? []
        blocks = b.compactMap(\.value); links = l.compactMap(\.value); images = i.compactMap(\.value)
        malformed = (b.count - blocks.count) + (l.count - links.count) + (i.count - images.count)
    }
}
