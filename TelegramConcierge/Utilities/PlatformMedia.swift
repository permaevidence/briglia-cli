import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-platform PDF handling
//
// Every PDF operation the services need (page count, per-page text, page-range
// slicing, page rasterization) goes through AdaPDF. On macOS it wraps PDFKit —
// byte-for-byte the behavior Ada.app has always had. On Linux it shells out to
// poppler-utils (pdfinfo / pdftotext / pdfseparate / pdfunite / pdftoppm),
// which the setup wizard installs. When poppler is missing, initializers fail
// and callers degrade exactly like they do for a corrupt PDF.

final class AdaPDF {

    #if canImport(PDFKit)

    private let document: PDFDocument

    init?(data: Data) {
        guard let document = PDFDocument(data: data) else { return nil }
        self.document = document
    }

    init?(url: URL) {
        guard let document = PDFDocument(url: url) else { return nil }
        self.document = document
    }

    var pageCount: Int { document.pageCount }

    /// Extracted text of a 0-indexed page, nil when the page has no text layer.
    func pageText(at index: Int) -> String? {
        document.page(at: index)?.string
    }

    /// A new PDF containing only the given 1-indexed inclusive page range.
    func sliceData(pages range: ClosedRange<Int>) -> Data? {
        let sliced = PDFDocument()
        var idx = 0
        for pageNum in range {
            if let page = document.page(at: pageNum - 1) {
                sliced.insert(page, at: idx)
                idx += 1
            }
        }
        return idx > 0 ? sliced.dataRepresentation() : nil
    }

    /// Render every page to PNG at `scale`× the page's natural 72-dpi size.
    func rasterizePagesToPNG(scale: CGFloat = 2.0) -> [Data] {
        var pages: [Data] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            if let tiffData = thumbnail.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                pages.append(pngData)
            }
        }
        return pages
    }

    #else

    // Linux: poppler-utils over a temp copy of the document. The temp
    // directory lives as long as the AdaPDF instance and is removed on deinit.

    private let workDir: URL
    private let fileURL: URL
    let pageCount: Int
    private var cachedPageTexts: [String]?

    private init?(fileURL: URL, workDir: URL) {
        guard let pdfinfo = PlatformBinary.find("pdfinfo"),
              let output = PlatformBinary.run(pdfinfo, [fileURL.path]),
              let text = String(data: output, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: workDir)
            return nil
        }
        var pages = 0
        for line in text.split(separator: "\n") where line.hasPrefix("Pages:") {
            pages = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard pages > 0 else {
            try? FileManager.default.removeItem(at: workDir)
            return nil
        }
        self.workDir = workDir
        self.fileURL = fileURL
        self.pageCount = pages
    }

    convenience init?(data: Data) {
        guard let workDir = AdaPDF.makeWorkDir() else { return nil }
        let fileURL = workDir.appendingPathComponent("document.pdf")
        do { try data.write(to: fileURL) } catch {
            try? FileManager.default.removeItem(at: workDir)
            return nil
        }
        self.init(fileURL: fileURL, workDir: workDir)
    }

    convenience init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let workDir = AdaPDF.makeWorkDir() else { return nil }
        let fileURL = workDir.appendingPathComponent("document.pdf")
        do { try FileManager.default.copyItem(at: url, to: fileURL) } catch {
            try? FileManager.default.removeItem(at: workDir)
            return nil
        }
        self.init(fileURL: fileURL, workDir: workDir)
    }

    deinit {
        try? FileManager.default.removeItem(at: workDir)
    }

    private static func makeWorkDir() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-pdf-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    func pageText(at index: Int) -> String? {
        guard index >= 0, index < pageCount else { return nil }
        if cachedPageTexts == nil {
            guard let pdftotext = PlatformBinary.find("pdftotext"),
                  let output = PlatformBinary.run(pdftotext, ["-enc", "UTF-8", fileURL.path, "-"]),
                  let text = String(data: output, encoding: .utf8) else {
                cachedPageTexts = []
                return nil
            }
            // pdftotext separates pages with form feeds.
            cachedPageTexts = text.components(separatedBy: "\u{0C}")
        }
        guard let texts = cachedPageTexts, index < texts.count else { return nil }
        let pageText = texts[index]
        return pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pageText
    }

    func sliceData(pages range: ClosedRange<Int>) -> Data? {
        guard range.lowerBound >= 1, range.upperBound <= pageCount,
              let pdfseparate = PlatformBinary.find("pdfseparate") else { return nil }
        let sliceDir = workDir.appendingPathComponent("slice-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sliceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sliceDir) }

        let pattern = sliceDir.appendingPathComponent("page-%09d.pdf").path
        guard PlatformBinary.run(pdfseparate,
                                 ["-f", String(range.lowerBound), "-l", String(range.upperBound),
                                  fileURL.path, pattern]) != nil else { return nil }
        let pageFiles = range.map {
            sliceDir.appendingPathComponent(String(format: "page-%09d.pdf", $0))
        }
        guard pageFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }

        if pageFiles.count == 1 {
            return try? Data(contentsOf: pageFiles[0])
        }
        guard let pdfunite = PlatformBinary.find("pdfunite") else { return nil }
        let merged = sliceDir.appendingPathComponent("merged.pdf")
        guard PlatformBinary.run(pdfunite, pageFiles.map(\.path) + [merged.path]) != nil else { return nil }
        return try? Data(contentsOf: merged)
    }

    func rasterizePagesToPNG(scale: CGFloat = 2.0) -> [Data] {
        guard let pdftoppm = PlatformBinary.find("pdftoppm") else { return [] }
        let rasterDir = workDir.appendingPathComponent("raster-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: rasterDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rasterDir) }

        // PDFKit renders at scale × 72 dpi; match it.
        let dpi = max(36, Int(72.0 * scale))
        let prefix = rasterDir.appendingPathComponent("page").path
        guard PlatformBinary.run(pdftoppm, ["-png", "-r", String(dpi), fileURL.path, prefix],
                                 timeout: 300) != nil else { return [] }

        let files = (try? FileManager.default.contentsOfDirectory(atPath: rasterDir.path)) ?? []
        return files
            .filter { $0.hasSuffix(".png") }
            .sorted()  // pdftoppm zero-pads page numbers, so name order == page order
            .compactMap { try? Data(contentsOf: rasterDir.appendingPathComponent($0)) }
    }

    #endif
}

// MARK: - Cross-platform image handling

/// Image inspection and resizing. macOS: ImageIO/AppKit (unchanged from
/// Ada.app). Linux: ImageMagick (`magick`/`identify`/`convert`), installed by
/// the setup wizard. All functions fail soft (nil) so callers keep their
/// existing "use the original data" fallbacks.
enum PlatformImage {

    #if canImport(AppKit)

    static func dimensions(data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Resize to exactly `targetSize` (matching NSImage draw-into-rect
    /// semantics) and encode as JPEG at `quality` (0–1).
    static func resizeToJPEG(data: Data, targetSize: CGSize, quality: Double) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        guard let tiffData = newImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: quality]
              ) else {
            return nil
        }
        return jpegData
    }

    /// First frame decoded with ImageIO and re-encoded as PNG (or JPEG at
    /// `quality`). Used to convert formats model providers refuse (BMP,
    /// TIFF, HEIC, ICO, animated GIF); nil when the decoder cannot read it.
    static func convertFirstFrame(data: Data, toJPEG: Bool, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        let type = (toJPEG ? "public.jpeg" : "public.png") as CFString
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, 1, nil) else { return nil }
        let properties: [CFString: Any] = toJPEG ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    #else

    /// ImageMagick entry point: v7 ships a single `magick` binary, v6 (still
    /// the Ubuntu default) ships `identify`/`convert`. Returns (binary,
    /// argument prefix) for the requested classic tool name.
    private static func magick(_ tool: String) -> (path: String, prefix: [String])? {
        if let magick = PlatformBinary.find("magick") { return (magick, [tool]) }
        if let direct = PlatformBinary.find(tool) { return (direct, []) }
        return nil
    }

    static func dimensions(data: Data) -> (width: Int, height: Int)? {
        guard let (bin, prefix) = magick("identify") else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try data.write(to: tmp) } catch { return nil }
        // [0] → first frame only (animated GIFs report one line per frame).
        guard let output = PlatformBinary.run(bin, prefix + ["-format", "%w %h", tmp.path + "[0]"]),
              let text = String(data: output, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count >= 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return (parts[0], parts[1])
    }

    static func resizeToJPEG(data: Data, targetSize: CGSize, quality: Double) -> Data? {
        guard let (bin, prefix) = magick("convert") else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-img-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        let dst = dir.appendingPathComponent("dst.jpg")
        do { try data.write(to: src) } catch { return nil }
        let geometry = "\(Int(targetSize.width))x\(Int(targetSize.height))!"
        let q = String(max(1, min(100, Int(quality * 100))))
        guard PlatformBinary.run(bin, prefix + [src.path + "[0]", "-resize", geometry,
                                                "-quality", q, dst.path]) != nil else { return nil }
        return try? Data(contentsOf: dst)
    }

    /// First frame converted by ImageMagick to PNG (or JPEG at `quality`).
    /// nil when ImageMagick is missing, lacks the format delegate, or fails:
    /// callers report that as "conversion not available", never as corrupt.
    static func convertFirstFrame(data: Data, toJPEG: Bool, quality: Double) -> Data? {
        guard let (bin, prefix) = magick("convert") else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-img-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src")
        let dst = dir.appendingPathComponent(toJPEG ? "dst.jpg" : "dst.png")
        do { try data.write(to: src) } catch { return nil }
        var arguments = prefix + [src.path + "[0]"]
        if toJPEG { arguments += ["-quality", String(max(1, min(100, Int(quality * 100))))] }
        guard PlatformBinary.run(bin, arguments + [dst.path]) != nil,
              let out = try? Data(contentsOf: dst), !out.isEmpty else { return nil }
        return out
    }

    #endif

    /// Convenience used by attachment token budgeting: dimensions from a file.
    static func dimensions(url: URL) -> (width: Int, height: Int)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return dimensions(data: data)
    }
}
