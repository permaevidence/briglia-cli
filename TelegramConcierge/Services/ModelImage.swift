import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// One classifier for every image that can reach a model request
/// (CACHE_KEY_AND_IMAGE_REJECTION_PLAN v2 §2.3). Providers accept only JPEG,
/// PNG, WebP and still GIF, and they sniff the bytes, so a wrong extension or
/// declared MIME does not help. The outcomes keep "the bytes are broken"
/// separate from "this machine cannot convert them":
///
/// - `.supported`: JPEG/PNG/WebP/still GIF not shown to be malformed. The
///   bytes are passed on UNCHANGED, with the sniffed MIME (which corrects a
///   lying extension). `validation` says how much was checked.
/// - `.converted`: an unsupported format (BMP, TIFF, HEIC/HEIF/AVIF, ICO,
///   animated GIF, unrecognised) decoded and re-encoded; the original file is
///   never modified.
/// - `.malformed`: positive evidence of invalid bytes (a failed structural
///   check, or the in-process macOS image decoder rejecting them).
/// - `.needsConversionUnavailable`: an unsupported format this machine cannot
///   convert (Linux without ImageMagick, or a missing delegate). A missing
///   tool is never reported as corruption.
///
/// Supported formats never need ImageMagick: the built-in structural checks
/// below run everywhere (pure Swift, bounded walks, checked arithmetic). On
/// macOS ImageIO additionally decodes the pixels (`.decoded`). Anything that
/// still slips through is caught by provider-rejection recovery
/// (`ProviderImageRejection`).
enum ModelImage {

    enum Format: String {
        case jpeg, png, webp, gif, bmp, tiff, heic, avif, ico, unknown

        var isProviderSupported: Bool { [.jpeg, .png, .webp, .gif].contains(self) }
        var mime: String {
            switch self {
            case .jpeg: return "image/jpeg"
            case .png: return "image/png"
            case .webp: return "image/webp"
            case .gif: return "image/gif"
            case .bmp: return "image/bmp"
            case .tiff: return "image/tiff"
            case .heic: return "image/heic"
            case .avif: return "image/avif"
            case .ico: return "image/x-icon"
            case .unknown: return "application/octet-stream"
            }
        }
        var label: String { self == .unknown ? "unrecognized" : rawValue.uppercased() }
    }

    enum Validation: String, Equatable {
        /// Pixels decoded by an in-process decoder (macOS ImageIO).
        case decoded
        /// The built-in structural check completed and found nothing wrong.
        case structural
        /// The structural parser could not interpret this variant; passed on.
        case unchecked
    }

    enum Outcome: Equatable {
        case supported(data: Data, mime: String, validation: Validation)
        case converted(data: Data, mime: String, from: String)
        case malformed(format: String, reason: String)
        case needsConversionUnavailable(format: String)

        var attachable: (data: Data, mime: String)? {
            switch self {
            case .supported(let data, let mime, _), .converted(let data, let mime, _): return (data, mime)
            case .malformed, .needsConversionUnavailable: return nil
            }
        }

        /// Plain, honest reason for a refusal (nil when attachable).
        var refusalReason: String? {
            switch self {
            case .supported, .converted: return nil
            case .malformed(let format, let reason):
                return "the file is not a valid \(format) image (\(reason))"
            case .needsConversionUnavailable(let format):
                return "\(format) images are not accepted by the model provider and this machine could not convert it"
            }
        }

        var formatLabel: String {
            switch self {
            case .supported(_, let mime, _), .converted(_, let mime, _): return mime
            case .malformed(let format, _), .needsConversionUnavailable(let format): return format
            }
        }
    }

    // MARK: - Sniffing

    static func sniff(_ data: Data) -> Format {
        let b = [UInt8](data.prefix(16))
        func at(_ i: Int, _ bytes: [UInt8]) -> Bool {
            guard i + bytes.count <= b.count else { return false }
            return Array(b[i..<(i + bytes.count)]) == bytes
        }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if at(0, [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if at(0, Array("GIF87a".utf8)) || at(0, Array("GIF89a".utf8)) { return .gif }
        if at(0, Array("RIFF".utf8)) && at(8, Array("WEBP".utf8)) { return .webp }
        if at(0, Array("BM".utf8)) { return .bmp }
        if at(0, [0x49, 0x49, 0x2A, 0x00]) || at(0, [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if at(0, [0x00, 0x00, 0x01, 0x00]) { return .ico }
        if at(4, Array("ftyp".utf8)), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if brand.hasPrefix("avi") { return .avif }
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"].contains(brand) { return .heic }
        }
        return .unknown
    }

    // MARK: - Structural checks (pure Swift, bounded)

    enum Structure: Equatable {
        case valid(frames: Int)
        case invalid(String)
        case inconclusive
    }

    static func structure(_ data: Data, format: Format) -> Structure {
        let bytes = [UInt8](data)
        switch format {
        case .png: return png(bytes)
        case .jpeg: return jpeg(bytes)
        case .gif: return gif(bytes)
        case .webp: return webp(bytes)
        default: return .inconclusive
        }
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }
    private static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    /// Signature, IHDR first with nonzero dimensions, every chunk length
    /// inside the file, IEND present.
    private static func png(_ b: [UInt8]) -> Structure {
        guard b.count >= 8 + 25 else { return .invalid("truncated before the image header") }
        guard be32(b, 8) == 13, String(decoding: b[12..<16], as: UTF8.self) == "IHDR" else {
            return .invalid("missing image header")
        }
        guard be32(b, 16) > 0, be32(b, 20) > 0 else { return .invalid("zero width or height") }
        var pos = 8
        while true {
            guard pos <= b.count - 12 else { return .invalid("truncated: no end chunk") }
            let length = be32(b, pos)
            let (end, overflow) = pos.addingReportingOverflow(12 + length)
            guard !overflow, length >= 0, end <= b.count else { return .invalid("truncated chunk") }
            if String(decoding: b[(pos + 4)..<(pos + 8)], as: UTF8.self) == "IEND" { return .valid(frames: 1) }
            pos = end
        }
    }

    /// SOI, segment lengths inside the file, a frame header with nonzero
    /// width, then an end-of-image marker after the scan data. Unusual but
    /// possibly valid layouts are inconclusive, never malformed.
    private static func jpeg(_ b: [UInt8]) -> Structure {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return .invalid("missing start marker") }
        var pos = 2
        var sawFrame = false
        while pos < b.count {
            guard b[pos] == 0xFF else { return .inconclusive }
            var markerPos = pos + 1
            while markerPos < b.count && b[markerPos] == 0xFF { markerPos += 1 }
            guard markerPos < b.count else { return .invalid("truncated: no end-of-image marker") }
            let marker = b[markerPos]
            pos = markerPos + 1
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
            if marker == 0xD8 { return .inconclusive }
            if marker == 0xD9 { return .invalid("ends before the image data") }
            guard pos + 2 <= b.count else { return .invalid("truncated segment") }
            let length = (Int(b[pos]) << 8) | Int(b[pos + 1])
            guard length >= 2, pos + length <= b.count else { return .invalid("truncated segment") }
            if (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard length >= 7 else { return .invalid("short frame header") }
                let height = (Int(b[pos + 3]) << 8) | Int(b[pos + 4])
                let width = (Int(b[pos + 5]) << 8) | Int(b[pos + 6])
                guard width > 0 else { return .invalid("zero width") }
                if height == 0 { return .inconclusive }
                sawFrame = true
            }
            if marker == 0xDA {
                guard sawFrame else { return .invalid("scan data before any frame header") }
                var i = pos + length
                while i + 1 < b.count {
                    if b[i] == 0xFF && b[i + 1] == 0xD9 { return .valid(frames: 1) }
                    i += 1
                }
                return .invalid("truncated: no end-of-image marker")
            }
            pos += length
        }
        return .invalid("truncated: no image data")
    }

    /// Header, logical screen, block walk counting frames (more than one =
    /// animated), trailer present.
    private static func gif(_ b: [UInt8]) -> Structure {
        guard b.count >= 13 else { return .invalid("truncated header") }
        var pos = 13
        if b[10] & 0x80 != 0 { pos += 3 * (1 << (Int(b[10] & 0x07) + 1)) }
        var frames = 0
        func skipSubBlocks(_ p: inout Int) -> Bool {
            while true {
                guard p < b.count else { return false }
                let size = Int(b[p]); p += 1
                if size == 0 { return true }
                p += size
            }
        }
        while true {
            guard pos < b.count else { return .invalid("truncated: no trailer") }
            switch b[pos] {
            case 0x3B:
                return frames == 0 ? .invalid("no image frame") : .valid(frames: frames)
            case 0x21:
                pos += 2
                guard skipSubBlocks(&pos) else { return .invalid("truncated extension") }
            case 0x2C:
                guard pos + 10 <= b.count else { return .invalid("truncated frame header") }
                let flags = b[pos + 9]
                pos += 10
                if flags & 0x80 != 0 { pos += 3 * (1 << (Int(flags & 0x07) + 1)) }
                pos += 1
                guard skipSubBlocks(&pos) else { return .invalid("truncated frame data") }
                frames += 1
            default:
                return .inconclusive
            }
        }
    }

    /// RIFF/WEBP header with the declared RIFF size inside the file and a
    /// VP8/VP8L/VP8X first chunk.
    private static func webp(_ b: [UInt8]) -> Structure {
        guard b.count >= 16 else { return .invalid("truncated header") }
        let riff = le32(b, 4)
        let (end, overflow) = riff.addingReportingOverflow(8)
        guard !overflow, end <= b.count else { return .invalid("truncated: shorter than its declared size") }
        let chunk = String(decoding: b[12..<16], as: UTF8.self)
        guard ["VP8 ", "VP8L", "VP8X"].contains(chunk) else { return .invalid("no image chunk") }
        return .valid(frames: 1)
    }

    // MARK: - Classification

    /// Selftest seam: behave like a Linux host without ImageMagick (no
    /// in-process decoder, no converter) on any platform.
    nonisolated(unsafe) static var simulateNoPlatformDecoderForTesting = false

    /// Whether an in-process pixel decoder exists (macOS ImageIO).
    static var platformDecoderAvailable: Bool {
        #if canImport(ImageIO)
        return !simulateNoPlatformDecoderForTesting
        #else
        return false
        #endif
    }

    static func classify(data: Data, declaredMime: String? = nil) -> Outcome {
        let format = sniff(data)
        if format.isProviderSupported {
            let structure = structure(data, format: format)
            if case .invalid(let reason) = structure { return .malformed(format: format.label, reason: reason) }
            if format == .gif, case .valid(let frames) = structure, frames > 1 {
                return convert(data, from: format, animated: true)
            }
            #if canImport(ImageIO)
            if platformDecoderAvailable {
                guard decodes(data) else {
                    return .malformed(format: format.label, reason: "the image decoder could not read it")
                }
                return .supported(data: data, mime: format.mime, validation: .decoded)
            }
            #endif
            if case .valid = structure { return .supported(data: data, mime: format.mime, validation: .structural) }
            return .supported(data: data, mime: format.mime, validation: .unchecked)
        }
        return convert(data, from: format, animated: false)
    }

    /// PNG for lossless sources and first frames, JPEG for camera formats.
    private static func convert(_ data: Data, from format: Format, animated: Bool) -> Outcome {
        let lossy = format == .heic || format == .avif
        let label = animated ? "animated GIF" : format.label
        if !simulateNoPlatformDecoderForTesting,
           let converted = PlatformImage.convertFirstFrame(data: data, toJPEG: lossy, quality: FilesystemTools.imageDownscaleQuality) {
            return .converted(data: converted, mime: lossy ? "image/jpeg" : "image/png", from: animated ? "image/gif (animated)" : format.mime)
        }
        // With the in-process decoder present (macOS), a failure is the
        // decoder rejecting the bytes, not a missing tool. Elsewhere it is a
        // missing converter or delegate, never reported as corruption.
        if platformDecoderAvailable { return .malformed(format: label, reason: "the image decoder could not read it") }
        return .needsConversionUnavailable(format: label)
    }

    #if canImport(ImageIO)
    /// Forces a pixel decode (a small thumbnail rendered immediately).
    static func decodes(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }
    #endif

    // MARK: - Memoized entry points

    /// Classification memoized by content hash (request assembly re-inlines
    /// the same images on every request).
    static func classifyCached(data: Data, declaredMime: String? = nil) -> Outcome {
        let key = ModelImageCache.key(for: data)
        if let hit = ModelImageCache.shared.outcome(forKey: key) { return hit }
        let outcome = classify(data: data, declaredMime: declaredMime)
        ModelImageCache.shared.store(outcome, forKey: key)
        return outcome
    }

    /// Text shown in a tool result when an image cannot be attached.
    static func refusalText(_ outcome: Outcome, path: String) -> String {
        "cannot attach image \(path): \(outcome.refusalReason ?? "unknown reason"). "
            + "Convert it to PNG or JPEG first (for example with ImageMagick: convert input output.png, or on macOS: sips -s format png input --out output.png), then read the converted file."
    }

    /// Provider-boundary note for an image that is not sent (serialization guard).
    static func notSentNote(_ outcome: Outcome, path: String) -> String {
        "[image not sent: \(outcome.refusalReason ?? "unknown reason") — \(path)]"
    }

    /// Note that replaces an image excluded during image-rejection recovery.
    static func rejectedNote(path: String) -> String {
        "[image removed: the provider rejected it — \(path)]"
    }
}

/// Process-wide memo of image classifications keyed by content hash.
/// Converted outputs count toward a byte budget; verdicts are small.
final class ModelImageCache: @unchecked Sendable {
    static let shared = ModelImageCache()
    private let lock = NSLock()
    private var entries: [String: ModelImage.Outcome] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let maxBytes = 64 * 1024 * 1024
    private let maxEntries = 1024

    static func key(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func cost(_ outcome: ModelImage.Outcome) -> Int {
        if case .converted(let data, _, _) = outcome { return data.count + 128 }
        return 128
    }

    func outcome(forKey key: String) -> ModelImage.Outcome? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = entries[key] else { return nil }
        if let index = order.firstIndex(of: key) { order.remove(at: index); order.append(key) }
        return hit
    }

    func store(_ outcome: ModelImage.Outcome, forKey key: String) {
        let cost = Self.cost(outcome)
        guard cost <= maxBytes else { return }
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { bytes -= Self.cost(old); order.removeAll { $0 == key } }
        entries[key] = outcome; order.append(key); bytes += cost
        while (bytes > maxBytes || order.count > maxEntries), let oldest = order.first {
            order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) { bytes -= Self.cost(evicted) }
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]; order = []; bytes = 0
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}
