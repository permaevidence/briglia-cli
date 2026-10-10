import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// Hidden battery for EXIF orientation when images are converted (HEIC,
/// TIFF, …) or resized for the model budget (v0.2.53 plan §1 with the
/// review's mirrored-orientation rows):
///
/// - O0  characterisation of the v0.2.52 functions (verbatim copies) on
///       orientation-6 inputs: printed, always passes.
/// - O1  conversion, orientations 2–8: oriented dimensions, every corner
///       where EXIF puts it, output untagged (or 1).
/// - O2  over-budget JPEG resize, orientations 2–8: target from the display
///       dimensions, corners upright, untagged.
/// - O3  orientation absent / 1: outputs byte-identical to v0.2.52.
/// - O4  in-budget tagged JPEG: passes through untouched.
/// - O5  conversion then resize (read_file and the tool-image path): upright
///       exactly once.
/// - O6  no orientation probe / (Linux) no ImageMagick: outcomes as today.
/// - O8  ImageMagick orientation names → EXIF codes.
///
/// Fixtures are generated in memory: four saturated quadrants (stored TL
/// red, TR green, BL blue, BR yellow) so every rotation and reflection is
/// distinguishable. Isolation: re-executes itself in a private scratch home
/// under a differently named hard link, like the image-rejection battery.
struct ImageOrientationSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__image-orientation-selftest",
        abstract: "Internal: verify EXIF orientation handling when converting or resizing images.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false

    static let linkName = "briglia-mw-imgorient"
    static let rootPrefix = "briglia-image-orientation-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(); return }
        let data = StoragePaths.dataRoot.path
        guard data.contains(Self.rootPrefix), ProcessInfo.processInfo.processName == Self.linkName else {
            print("✖ refusing to run outside the isolated scratch home (data root \(data))")
            throw ExitCode(1)
        }
        let h = OrientHarness()
        await h.runAll()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) image orientation check(s) FAILED (\(h.skipped) skipped)")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) image orientation checks passed (\(h.skipped) skipped)")
    }

    static func reexecIsolated() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(rootPrefix + UUID().uuidString)
        for sub in ["home", "home/.config", "home/.local/share", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__image-orientation-selftest", "--child"]
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Check bookkeeping plus the rows (extensions in the +Rows / +Legacy files).
final class OrientHarness {
    var total = 0
    var failures = 0
    var skipped = 0

    func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok {
            print("  ✔ \(label)")
        } else {
            failures += 1
            let d = detail()
            print("  ✖ \(label)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    func skip(_ label: String, _ reason: String) {
        skipped += 1
        print("  – \(label) skipped: \(reason)")
    }

    func note(_ line: String) { print("  · \(line)") }

    /// Whether this host can build fixtures and convert (macOS ImageIO, or
    /// ImageMagick on Linux).
    var toolchain: Bool {
        #if canImport(ImageIO)
        return true
        #else
        return OrientFixture.imageMagick("convert") != nil
        #endif
    }

    var heicSupported: Bool {
        #if canImport(ImageIO)
        return OrientFixture.make(.heic, w: 16, h: 8, orientation: nil) != nil
        #else
        return false
        #endif
    }

    func runAll() async {
        ModelImageCache.shared.removeAll()
        print("O8 ImageMagick orientation names")
        rowO8()
        guard toolchain else {
            print("O0–O5 need an image toolchain")
            for row in ["O0", "O1", "O2", "O3", "O4", "O5"] { skip(row, "ImageMagick is not installed") }
            print("O6 no ImageMagick (real)")
            rowO6NoImageMagick()
            return
        }
        print("O0 characterisation of v0.2.52 (always passes)")
        rowO0()
        print("O1 conversion, orientations 2–8")
        rowO1()
        print("O2 over-budget JPEG resize, orientations 2–8")
        rowO2()
        print("O3 orientation absent / 1: byte-identical to v0.2.52")
        rowO3()
        print("O4 in-budget tagged JPEG passes through")
        rowO4()
        print("O5 conversion then resize, applied once")
        await rowO5()
        print("O6 without an orientation probe / ImageMagick")
        rowO6ProbeDisabled()
        #if canImport(ImageIO)
        skip("O6 no ImageMagick", "Linux only (macOS decodes in process)")
        #else
        rowO6NoImageMagick()
        #endif
        ModelImageCache.shared.removeAll()
    }
}

// MARK: - Fixtures

enum OrientFixture {
    enum Kind { case jpeg, tiff, heic }

    /// Displayed TL/TR/BL/BR for stored TL=R TR=G BL=B BR=Y, per EXIF code
    /// (1 identity, 2 mirror horizontal, 3 rotate 180, 4 mirror vertical,
    /// 5 transpose, 6 rotate 90° CW, 7 transverse, 8 rotate 90° CCW).
    static let displayed: [Int: String] = [
        1: "RGBY", 2: "GRYB", 3: "YBGR", 4: "BYRG",
        5: "RBGY", 6: "BRYG", 7: "YGBR", 8: "GYRB",
    ]
    static let imageMagickName: [Int: String] = [
        1: "TopLeft", 2: "TopRight", 3: "BottomRight", 4: "BottomLeft",
        5: "LeftTop", 6: "RightTop", 7: "RightBottom", 8: "LeftBottom",
    ]

    /// Display dimensions for a stored w×h with this orientation.
    static func oriented(_ w: Int, _ h: Int, _ code: Int?) -> (Int, Int) {
        if let code, (5...8).contains(code) { return (h, w) }
        return (w, h)
    }

    /// Packed RGB, four saturated quadrants.
    static func rgb(_ w: Int, _ h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let top = y < h / 2, left = x < w / 2
                let c: (UInt8, UInt8, UInt8) = top ? (left ? (255, 0, 0) : (0, 255, 0))
                                                   : (left ? (0, 0, 255) : (255, 255, 0))
                let i = (y * w + x) * 3
                out[i] = c.0; out[i + 1] = c.1; out[i + 2] = c.2
            }
        }
        return out
    }

    /// Minimal big-endian EXIF APP1 holding only an Orientation tag,
    /// inserted after SOI (and after a JFIF APP0 when present).
    static func spliceExifOrientation(jpeg: Data, code: Int) -> Data {
        var b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return jpeg }
        var at = 2
        if b[2] == 0xFF, b[3] == 0xE0, b.count > 6 {
            at = 4 + (Int(b[4]) << 8 | Int(b[5]))
        }
        let tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
                             0x00, 0x01,
                             0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, UInt8(code), 0x00, 0x00,
                             0x00, 0x00, 0x00, 0x00]
        let payload: [UInt8] = Array("Exif".utf8) + [0, 0] + tiff
        let length = payload.count + 2
        let segment: [UInt8] = [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
        b.insert(contentsOf: segment, at: at)
        return Data(b)
    }

    /// Nearest of R/G/B/Y for a 5×5 average around (x, y); "?" when far.
    static func letter(_ px: [UInt8], _ w: Int, _ h: Int, _ x: Int, _ y: Int) -> Character {
        var sum = (0, 0, 0), n = 0
        for dy in -2...2 {
            for dx in -2...2 {
                let xx = min(max(x + dx, 0), w - 1), yy = min(max(y + dy, 0), h - 1)
                let i = (yy * w + xx) * 3
                sum.0 += Int(px[i]); sum.1 += Int(px[i + 1]); sum.2 += Int(px[i + 2]); n += 1
            }
        }
        let c = (sum.0 / n, sum.1 / n, sum.2 / n)
        let refs: [(Character, (Int, Int, Int))] = [("R", (255, 0, 0)), ("G", (0, 255, 0)),
                                                    ("B", (0, 0, 255)), ("Y", (255, 255, 0))]
        var best: (Character, Int) = ("?", Int.max)
        for (ch, r) in refs {
            let d = (c.0 - r.0) * (c.0 - r.0) + (c.1 - r.1) * (c.1 - r.1) + (c.2 - r.2) * (c.2 - r.2)
            if d < best.1 { best = (ch, d) }
        }
        return best.1 <= 3 * 90 * 90 ? best.0 : "?"
    }

    /// Stored pixels (no orientation applied) → dimensions + TL/TR/BL/BR.
    static func corners(_ data: Data) -> (w: Int, h: Int, letters: String)? {
        guard let (w, h, px) = decode(data), w >= 4, h >= 4 else { return nil }
        let pts = [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)]
        return (w, h, String(pts.map { letter(px, w, h, $0.0, $0.1) }))
    }

    /// One-line outcome for an output derived from a stored w×h image with
    /// orientation `code`.
    static func describe(_ out: Data?, storedW: Int, storedH: Int, code: Int) -> String {
        guard let out else { return "no output (nil)" }
        guard let c = corners(out) else { return "output not decodable" }
        let tag = PlatformImage.orientation(data: out)
        let (ow, oh) = oriented(storedW, storedH, code)
        let shapeOriented = (c.w >= c.h) == (ow >= oh)
        var verdict: String
        if c.letters == displayed[code] {
            verdict = shapeOriented ? "upright" : "upright but squashed (stored aspect)"
        } else if c.letters == displayed[1] {
            verdict = shapeOriented && ow != storedW ? "unrotated pixels squashed into display aspect"
                                                       : "unrotated pixels (sideways as stored)"
        } else if let k = displayed.first(where: { $0.value == c.letters })?.key {
            verdict = "pixels laid out as orientation \(k)" + (shapeOriented ? "" : ", stored aspect")
        } else {
            verdict = "unrecognised corners"
        }
        let tagText: String
        switch tag {
        case .some(let t) where t == code: tagText = "tag \(t) kept (a viewer honouring it would turn it further)"
        case .some(let t) where t == 1: tagText = "tag dropped/1"
        case .some(let t): tagText = "tag \(t)"
        case .none: tagText = "tag unreadable"
        }
        return "\(c.w)×\(c.h), corners \(c.letters) → \(verdict); \(tagText)"
    }

    #if canImport(ImageIO)

    static func make(_ kind: Kind, w: Int, h: Int, orientation code: Int?) -> Data? {
        let src = rgb(w, h)
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4] = src[i * 3]; rgba[i * 4 + 1] = src[i * 3 + 1]; rgba[i * 4 + 2] = src[i * 3 + 2]
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = ctx.makeImage() else { return nil }
        let type: String
        switch kind {
        case .jpeg: type = "public.jpeg"
        case .tiff: type = "public.tiff"
        case .heic: type = "public.heic"
        }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if kind != .tiff { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        if let code { props[kCGImagePropertyOrientation] = code }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest), output.length > 0 else { return nil }
        return output as Data
    }

    static func decode(_ data: Data) -> (Int, Int, [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return (w, h, rgb)
    }

    #else

    /// Same resolution rule as PlatformImage (v7 `magick <tool>`, v6 tool).
    static func imageMagick(_ tool: String) -> (path: String, prefix: [String])? {
        if let magick = PlatformBinary.find("magick") { return (magick, [tool]) }
        if let direct = PlatformBinary.find(tool) { return (direct, []) }
        return nil
    }

    private static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func make(_ kind: Kind, w: Int, h: Int, orientation code: Int?) -> Data? {
        guard kind != .heic, let (bin, prefix) = imageMagick("convert") else { return nil }
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ppm = dir.appendingPathComponent("in.ppm")
        var bytes = Data("P6\n\(w) \(h)\n255\n".utf8)
        bytes.append(contentsOf: rgb(w, h))
        do { try bytes.write(to: ppm) } catch { return nil }
        switch kind {
        case .tiff:
            let out = dir.appendingPathComponent("out.tif")
            var args = prefix + [ppm.path]
            if let code, let name = imageMagickName[code] { args += ["-orient", name] }
            guard PlatformBinary.run(bin, args + [out.path]) != nil else { return nil }
            return try? Data(contentsOf: out)
        case .jpeg:
            let out = dir.appendingPathComponent("out.jpg")
            guard PlatformBinary.run(bin, prefix + [ppm.path, "-quality", "90", out.path]) != nil,
                  let jpeg = try? Data(contentsOf: out) else { return nil }
            return code.map { spliceExifOrientation(jpeg: jpeg, code: $0) } ?? jpeg
        case .heic:
            return nil
        }
    }

    static func decode(_ data: Data) -> (Int, Int, [UInt8])? {
        guard let (bin, prefix) = imageMagick("convert") else { return nil }
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("img")
        do { try data.write(to: file) } catch { return nil }
        guard let out = PlatformBinary.run(bin, prefix + [file.path + "[0]", "-depth", "8", "ppm:-"]) else { return nil }
        let b = [UInt8](out)
        // "P6" ws width ws height ws maxval single-ws pixels
        var fields: [Int] = [], i = 2, cur = ""
        while i < b.count, fields.count < 3 {
            let ch = b[i]
            if ch == 0x23 { while i < b.count, b[i] != 0x0A { i += 1 }; continue }
            if ch == 0x20 || ch == 0x0A || ch == 0x0D || ch == 0x09 {
                if !cur.isEmpty { fields.append(Int(cur) ?? 0); cur = "" }
            } else { cur.append(Character(UnicodeScalar(ch))) }
            i += 1
        }
        guard b.starts(with: [0x50, 0x36]), fields.count == 3, fields[2] == 255 else { return nil }
        let w = fields[0], h = fields[1]
        guard w > 0, h > 0, b.count - i >= w * h * 3 else { return nil }
        return (w, h, Array(b[i..<(i + w * h * 3)]))
    }

    #endif
}
