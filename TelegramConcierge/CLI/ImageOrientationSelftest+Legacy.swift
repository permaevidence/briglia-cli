import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// Same-process copies of the v0.2.52 (ab30bcf) image functions, verbatim
/// apart from their names: the golden reference for O0 (characterisation)
/// and O3/O6 (byte identity of the unchanged path).
enum LegacyImage {

    #if canImport(AppKit)

    static func dimensions(data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

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

    /// v0.2.52 `FilesystemTools.downscaledForModelBudget` (stored dimensions).
    static func downscaledForModelBudget(_ data: Data) -> (data: Data, mimeType: String)? {
        guard let dims = dimensions(data: data) else { return nil }
        let (w, h) = dims

        let estimatedTokens = (w * h) / 750
        let longSide = max(w, h)
        guard estimatedTokens > FilesystemTools.imageMaxTokens || longSide > FilesystemTools.imageMaxLongSide else { return nil }

        let scale = Double(FilesystemTools.imageMaxLongSide) / Double(longSide)
        let targetSize = CGSize(width: Int(Double(w) * scale), height: Int(Double(h) * scale))
        guard let resized = resizeToJPEG(
            data: data, targetSize: targetSize, quality: FilesystemTools.imageDownscaleQuality
        ) else { return nil }
        return (resized, "image/jpeg")
    }
}

extension OrientHarness {

    static let quality = FilesystemTools.imageDownscaleQuality

    /// O0: what v0.2.52 does with orientation-6 inputs (recorded first).
    func rowO0() {
        let platform: String = {
            #if canImport(AppKit)
            return "macOS"
            #else
            return "Linux"
            #endif
        }()
        func report(_ label: String, _ out: Data?, _ w: Int, _ h: Int) {
            let text = OrientFixture.describe(out, storedW: w, storedH: h, code: 6)
            print("  ◦ O0 \(platform) v0.2.52 \(label): \(text)")
            check("O0 \(label) characterised", true)
        }
        if heicSupported, let heic = OrientFixture.make(.heic, w: 120, h: 60, orientation: 6) {
            report("HEIC o6 120×60 → JPEG conversion",
                   LegacyImage.convertFirstFrame(data: heic, toJPEG: true, quality: Self.quality), 120, 60)
        } else {
            skip("O0 HEIC o6 conversion", "no HEIC encoder on this host")
        }
        if let tiff = OrientFixture.make(.tiff, w: 120, h: 60, orientation: 6) {
            report("TIFF o6 120×60 → PNG conversion",
                   LegacyImage.convertFirstFrame(data: tiff, toJPEG: false, quality: Self.quality), 120, 60)
        } else {
            check("O0 TIFF o6 fixture", false, "could not build the TIFF fixture")
        }
        if let jpeg = OrientFixture.make(.jpeg, w: 3200, h: 1600, orientation: 6) {
            report("JPEG o6 3200×1600 over-budget resize",
                   LegacyImage.downscaledForModelBudget(jpeg)?.data, 3200, 1600)
        } else {
            check("O0 JPEG o6 fixture", false, "could not build the JPEG fixture")
        }
    }

    /// Byte comparison against the legacy copy. PNG outputs, and outputs the
    /// legacy function cannot reproduce byte-for-byte on this host, are
    /// compared as decoded pixels and say so.
    func compareGolden(_ label: String, new: () -> Data?, legacy: () -> Data?) {
        let n = new(), l1 = legacy()
        guard let n, let l1 else {
            check(label, n == nil && l1 == nil, "new \(n?.count ?? -1) bytes, legacy \(l1?.count ?? -1) bytes")
            return
        }
        if n == l1 { check("\(label) (bytes)", true); return }
        // PNG output: ImageMagick embeds creation/modification dates (tIME /
        // tEXt date:*) at one-second resolution, so two runs a second apart
        // differ in bytes only. PNG is lossless: compare decoded pixels.
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if n.prefix(8) == pngSignature && l1.prefix(8) == pngSignature {
            let pn = OrientFixture.decode(n), pl = OrientFixture.decode(l1)
            check("\(label) (PNG pixels; date chunks ignored)",
                  pn != nil && pn?.0 == pl?.0 && pn?.1 == pl?.1 && pn?.2 == pl?.2,
                  "new \(n.count) bytes, legacy \(l1.count) bytes")
            return
        }
        let l2 = legacy()
        if l2 == l1 {
            check("\(label) (bytes)", false, "new \(n.count) bytes ≠ legacy \(l1.count) bytes (legacy is deterministic)")
            return
        }
        let pn = OrientFixture.decode(n), pl = OrientFixture.decode(l1)
        check("\(label) (pixels; legacy output not byte-deterministic here)",
              pn != nil && pn?.0 == pl?.0 && pn?.1 == pl?.1 && pn?.2 == pl?.2)
    }

    /// O3: orientation absent and 1 keep today's exact path.
    func rowO3() {
        for code in [nil, 1] as [Int?] {
            let tagText = code.map { "tag \($0)" } ?? "no tag"
            if let tiff = OrientFixture.make(.tiff, w: 120, h: 60, orientation: code) {
                compareGolden("O3 TIFF \(tagText) convertFirstFrame → PNG",
                              new: { PlatformImage.convertFirstFrame(data: tiff, toJPEG: false, quality: Self.quality) },
                              legacy: { LegacyImage.convertFirstFrame(data: tiff, toJPEG: false, quality: Self.quality) })
            } else { check("O3 TIFF \(tagText) fixture", false) }
            if heicSupported, let heic = OrientFixture.make(.heic, w: 120, h: 60, orientation: code) {
                compareGolden("O3 HEIC \(tagText) convertFirstFrame → JPEG",
                              new: { PlatformImage.convertFirstFrame(data: heic, toJPEG: true, quality: Self.quality) },
                              legacy: { LegacyImage.convertFirstFrame(data: heic, toJPEG: true, quality: Self.quality) })
            }
            if let jpeg = OrientFixture.make(.jpeg, w: 3200, h: 1600, orientation: code) {
                let target = CGSize(width: 1568, height: 784)
                compareGolden("O3 JPEG \(tagText) resizeToJPEG 1568×784",
                              new: { PlatformImage.resizeToJPEG(data: jpeg, targetSize: target, quality: Self.quality) },
                              legacy: { LegacyImage.resizeToJPEG(data: jpeg, targetSize: target, quality: Self.quality) })
                compareGolden("O3 JPEG \(tagText) downscaledForModelBudget",
                              new: { FilesystemTools.downscaledForModelBudget(jpeg)?.data },
                              legacy: { LegacyImage.downscaledForModelBudget(jpeg)?.data })
            } else { check("O3 JPEG \(tagText) fixture", false) }
        }
        // A PNG (never tagged): the rendered-page path is unchanged too.
        if let tiff = OrientFixture.make(.tiff, w: 2400, h: 1200, orientation: nil),
           let png = LegacyImage.convertFirstFrame(data: tiff, toJPEG: false, quality: Self.quality) {
            compareGolden("O3 PNG recompressedRenderedPage",
                          new: { FilesystemTools.recompressedRenderedPage(png).data },
                          legacy: {
                              let down = LegacyImage.downscaledForModelBudget(png)
                              return down.map { $0.data.count < png.count ? $0.data : png }
                          })
        } else { check("O3 PNG fixture", false) }
    }
}
