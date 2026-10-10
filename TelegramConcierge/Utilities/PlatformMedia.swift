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

    /// Selftest seam: the orientation probe reports "unknown" (nil), so every
    /// image takes the pre-0.2.53 path (as on a Linux host without ImageMagick).
    nonisolated(unsafe) static var orientationProbeDisabledForTesting = false

    /// Selftest seam (Linux): behave as if ImageMagick were not installed.
    nonisolated(unsafe) static var simulateNoImageMagickForTesting = false

    /// EXIF/TIFF orientation code for an ImageMagick `%[orientation]` name.
    /// `Undefined`, `TopLeft` and anything unrecognised are 1 (upright).
    static func orientationCode(forImageMagickName name: String) -> Int {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "TopRight": return 2
        case "BottomRight": return 3
        case "BottomLeft": return 4
        case "LeftTop": return 5
        case "RightTop": return 6
        case "RightBottom": return 7
        case "LeftBottom": return 8
        default: return 1
        }
    }

    /// Display dimensions: the stored ones, swapped when the orientation tag
    /// (5–8) turns the image a quarter turn. Resize targets use these so a
    /// portrait photo stored landscape keeps its proportions.
    static func orientedDimensions(data: Data) -> (width: Int, height: Int)? {
        guard let stored = dimensions(data: data) else { return nil }
        if let code = orientation(data: data), (5...8).contains(code) {
            return (stored.height, stored.width)
        }
        return stored
    }

    #if canImport(AppKit)

    static func dimensions(data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Orientation of the first frame (1…8): 1 when the tag is absent or out
    /// of range, nil when ImageIO cannot read the image.
    static func orientation(data: Data) -> Int? {
        if orientationProbeDisabledForTesting { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        guard let code = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
              (2...8).contains(code) else { return 1 }
        return code
    }

    /// First frame with its orientation applied to the pixels (ImageIO
    /// thumbnail with transform; long side at most `maxPixelSize`, the full
    /// size when nil), re-encoded with no orientation property: the output
    /// is upright and untagged, so it is never rotated a second time.
    private static func orientedReencode(data: Data, maxPixelSize: Int?, exactSize: CGSize? = nil,
                                         toJPEG: Bool, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let stored = dimensions(data: data) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? max(stored.width, stored.height),
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // resizeToJPEG promises exactly `targetSize`: the thumbnail keeps the
        // aspect ratio, so redraw only when it is off (rounding).
        if let exactSize {
            let w = max(1, Int(exactSize.width)), h = max(1, Int(exactSize.height))
            if image.width != w || image.height != h {
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let exact = ctx.makeImage() else { return nil }
                image = exact
            }
        }
        let output = NSMutableData()
        let type = (toJPEG ? "public.jpeg" : "public.png") as CFString
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type, 1, nil) else { return nil }
        let properties: [CFString: Any] = toJPEG ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    /// Resize to exactly `targetSize` (matching NSImage draw-into-rect
    /// semantics) and encode as JPEG at `quality` (0–1). An image tagged
    /// with orientation 2–8 is rotated/mirrored upright first (`targetSize`
    /// is then in display orientation, see `orientedDimensions`).
    static func resizeToJPEG(data: Data, targetSize: CGSize, quality: Double) -> Data? {
        if let code = orientation(data: data), code != 1 {
            let longSide = Int(max(targetSize.width, targetSize.height).rounded())
            return orientedReencode(data: data, maxPixelSize: max(1, longSide), exactSize: targetSize,
                                    toJPEG: true, quality: quality)
        }
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
    /// Tagged with orientation 2–8: rotated/mirrored upright, untagged.
    /// Absent/1: today's path, unchanged.
    static func convertFirstFrame(data: Data, toJPEG: Bool, quality: Double) -> Data? {
        if let code = orientation(data: data), code != 1 {
            return orientedReencode(data: data, maxPixelSize: nil, toJPEG: toJPEG, quality: quality)
        }
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
        if simulateNoImageMagickForTesting { return nil }
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

    /// Orientation of the first frame (1…8) from `identify %[orientation]`:
    /// 1 when undefined or unrecognised, nil without ImageMagick or when it
    /// cannot read the image.
    static func orientation(data: Data) -> Int? {
        if orientationProbeDisabledForTesting { return nil }
        guard let (bin, prefix) = magick("identify") else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try data.write(to: tmp) } catch { return nil }
        guard let output = PlatformBinary.run(bin, prefix + ["-format", "%[orientation]", tmp.path + "[0]"]),
              let text = String(data: output, encoding: .utf8) else { return nil }
        return orientationCode(forImageMagickName: text)
    }

    /// An image tagged with orientation 2–8 is rotated/mirrored upright
    /// (`-auto-orient`, which also resets the tag) before resizing;
    /// `targetSize` is then in display orientation (`orientedDimensions`).
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
        var arguments = prefix + [src.path + "[0]"]
        if let code = orientation(data: data), code != 1 { arguments.append("-auto-orient") }
        guard PlatformBinary.run(bin, arguments + ["-resize", geometry,
                                                   "-quality", q, dst.path]) != nil else { return nil }
        return try? Data(contentsOf: dst)
    }

    /// First frame converted by ImageMagick to PNG (or JPEG at `quality`),
    /// rotated/mirrored upright when tagged with orientation 2–8. nil when ImageMagick is missing, lacks the format delegate, or fails:
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
        if let code = orientation(data: data), code != 1 { arguments.append("-auto-orient") }
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
