import Foundation

extension OrientHarness {

    /// Checks one output: display dimensions (± `slack` px), corners where
    /// EXIF `code` puts them, and no orientation tag (or 1) left behind.
    func checkUpright(_ label: String, _ out: Data?, expectW: Int, expectH: Int, code: Int, slack: Int = 0) {
        guard let out, let c = OrientFixture.corners(out) else {
            check(label, false, out == nil ? "no output" : "output not decodable"); return
        }
        let tag = PlatformImage.orientation(data: out)
        let dimsOK = abs(c.w - expectW) <= slack && abs(c.h - expectH) <= slack
        let want = OrientFixture.displayed[code] ?? "?"
        check(label, dimsOK && c.letters == want && tag == 1,
              "got \(c.w)×\(c.h) corners \(c.letters) tag \(tag.map(String.init) ?? "nil"); want \(expectW)×\(expectH) corners \(want) tag 1")
    }

    /// O1: conversion of HEIC (macOS) and TIFF, orientations 2–8.
    func rowO1() {
        for code in 2...8 {
            let (ow, oh) = OrientFixture.oriented(120, 60, code)
            if heicSupported {
                if let heic = OrientFixture.make(.heic, w: 120, h: 60, orientation: code) {
                    check("O1 HEIC o\(code) fixture tagged \(code)", PlatformImage.orientation(data: heic) == code)
                    if case .converted(let out, let mime, _) = ModelImage.classify(data: heic) {
                        checkUpright("O1 HEIC o\(code) → \(mime)", out, expectW: ow, expectH: oh, code: code)
                    } else { check("O1 HEIC o\(code) converted", false, "classifier did not convert") }
                } else { check("O1 HEIC o\(code) fixture", false) }
            }
            if let tiff = OrientFixture.make(.tiff, w: 120, h: 60, orientation: code) {
                check("O1 TIFF o\(code) fixture tagged \(code)", PlatformImage.orientation(data: tiff) == code)
                if case .converted(let out, let mime, _) = ModelImage.classify(data: tiff) {
                    checkUpright("O1 TIFF o\(code) → \(mime)", out, expectW: ow, expectH: oh, code: code)
                } else { check("O1 TIFF o\(code) converted", false, "classifier did not convert") }
            } else { check("O1 TIFF o\(code) fixture", false) }
        }
        if !heicSupported { skip("O1 HEIC rows", "no HEIC encoder on this host") }
    }

    /// O2: over-budget JPEG resize, orientations 2–8 (stored 3200×1600).
    func rowO2() {
        for code in 2...8 {
            guard let jpeg = OrientFixture.make(.jpeg, w: 3200, h: 1600, orientation: code) else {
                check("O2 JPEG o\(code) fixture", false); continue
            }
            let (tw, th) = OrientFixture.oriented(1568, 784, code)
            let down = FilesystemTools.downscaledForModelBudget(jpeg)
            check("O2 JPEG o\(code) resized as image/jpeg", down?.mimeType == "image/jpeg")
            checkUpright("O2 JPEG o\(code) 3200×1600 → \(tw)×\(th)", down?.data, expectW: tw, expectH: th, code: code, slack: 1)
        }
    }

    /// O4: an in-budget tagged JPEG is attached untouched (tag and all).
    func rowO4() {
        guard let jpeg = OrientFixture.make(.jpeg, w: 120, h: 60, orientation: 6) else {
            check("O4 fixture", false); return
        }
        if case .supported(let data, let mime, _) = ModelImage.classify(data: jpeg) {
            check("O4 JPEG o6 in budget → supported, original bytes", data == jpeg && mime == "image/jpeg")
        } else { check("O4 JPEG o6 in budget → supported", false) }
        check("O4 JPEG o6 in budget → no resize", FilesystemTools.downscaledForModelBudget(jpeg) == nil)
        check("O4 JPEG o6 keeps its tag", PlatformImage.orientation(data: jpeg) == 6)
    }

    /// O5: converted then resized, through read_file and the tool-image
    /// path: upright exactly once (a second rotation fails the corners).
    func rowO5() async {
        var kinds: [(OrientFixture.Kind, String)] = [(.tiff, "tif")]
        if heicSupported { kinds.insert((.heic, "heic"), at: 0) } else { skip("O5 HEIC rows", "no HEIC encoder on this host") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orient-o5-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (kind, ext) in kinds {
            for code in [6, 5] {
                let name = "\(ext.uppercased()) o\(code)"
                guard let image = OrientFixture.make(kind, w: 3200, h: 1600, orientation: code) else {
                    check("O5 \(name) fixture", false); continue
                }
                let (tw, th) = OrientFixture.oriented(1568, 784, code)
                let path = dir.appendingPathComponent("photo-o\(code).\(ext)").path
                do { try image.write(to: URL(fileURLWithPath: path)) } catch { check("O5 \(name) write", false); continue }

                ModelImageCache.shared.removeAll()
                let read = await FilesystemTools.shared.readFile(path: path)
                check("O5 \(name) read_file: converted and resized",
                      read.content.contains("\"converted\"") && read.content.contains("\"resized\""), read.content)
                checkUpright("O5 \(name) read_file attachment", read.attachments.first?.data,
                             expectW: tw, expectH: th, code: code, slack: 1)

                ModelImageCache.shared.removeAll()
                let outcome = ModelImage.classifyCached(data: image)
                var data = outcome.attachable?.data
                if let attached = data, let down = FilesystemTools.downscaledForModelBudget(attached) { data = down.data }
                checkUpright("O5 \(name) tool-image path", data, expectW: tw, expectH: th, code: code, slack: 1)
            }
        }
        ModelImageCache.shared.removeAll()
    }

    /// O6 (both platforms): with no orientation probe, every image takes the
    /// v0.2.52 path — outputs equal the legacy copies even for tagged inputs.
    func rowO6ProbeDisabled() {
        guard let tiff = OrientFixture.make(.tiff, w: 120, h: 60, orientation: 6),
              let jpeg = OrientFixture.make(.jpeg, w: 3200, h: 1600, orientation: 6) else {
            check("O6 fixtures", false); return
        }
        PlatformImage.orientationProbeDisabledForTesting = true
        defer { PlatformImage.orientationProbeDisabledForTesting = false }
        check("O6 probe disabled → orientation nil", PlatformImage.orientation(data: tiff) == nil
              && PlatformImage.orientation(data: jpeg) == nil)
        compareGolden("O6 TIFF o6 convertFirstFrame as v0.2.52",
                      new: { PlatformImage.convertFirstFrame(data: tiff, toJPEG: false, quality: Self.quality) },
                      legacy: { LegacyImage.convertFirstFrame(data: tiff, toJPEG: false, quality: Self.quality) })
        compareGolden("O6 JPEG o6 downscaledForModelBudget as v0.2.52",
                      new: { FilesystemTools.downscaledForModelBudget(jpeg)?.data },
                      legacy: { LegacyImage.downscaledForModelBudget(jpeg)?.data })
    }

    /// O6 (Linux): no ImageMagick at all — no probe, no dimensions, no
    /// conversion; supported formats still pass byte-identical. Embedded
    /// fixtures only, so it also runs where ImageMagick is really missing.
    func rowO6NoImageMagick() {
        let jpeg = OrientFixture.spliceExifOrientation(jpeg: IRFixtures.jpeg, code: 6)
        let tiff = IRFixtures.tiff
        PlatformImage.simulateNoImageMagickForTesting = true
        ModelImage.simulateNoPlatformDecoderForTesting = true
        ModelImageCache.shared.removeAll()
        defer {
            PlatformImage.simulateNoImageMagickForTesting = false
            ModelImage.simulateNoPlatformDecoderForTesting = false
            ModelImageCache.shared.removeAll()
        }
        check("O6 no ImageMagick → orientation nil", PlatformImage.orientation(data: jpeg) == nil)
        check("O6 no ImageMagick → dimensions nil", PlatformImage.dimensions(data: jpeg) == nil
              && PlatformImage.orientedDimensions(data: jpeg) == nil)
        if case .needsConversionUnavailable = ModelImage.classify(data: tiff) {
            check("O6 no ImageMagick → TIFF needs conversion (unavailable)", true)
        } else { check("O6 no ImageMagick → TIFF needs conversion (unavailable)", false) }
        if case .supported(let data, _, _) = ModelImage.classify(data: jpeg) {
            check("O6 no ImageMagick → tagged JPEG supported, same bytes", data == jpeg)
        } else { check("O6 no ImageMagick → tagged JPEG supported", false) }
        check("O6 no ImageMagick → no resize", FilesystemTools.downscaledForModelBudget(jpeg) == nil)
    }

    /// O8: ImageMagick `%[orientation]` names → EXIF codes (Linux probe).
    func rowO8() {
        for (code, name) in OrientFixture.imageMagickName.sorted(by: { $0.key < $1.key }) {
            check("O8 \(name) → \(code)", PlatformImage.orientationCode(forImageMagickName: name) == code)
        }
        check("O8 Undefined / empty / unknown → 1",
              PlatformImage.orientationCode(forImageMagickName: "Undefined") == 1
              && PlatformImage.orientationCode(forImageMagickName: "") == 1
              && PlatformImage.orientationCode(forImageMagickName: "Sideways") == 1)
        check("O8 surrounding whitespace ignored", PlatformImage.orientationCode(forImageMagickName: " RightTop\n") == 6)
        if toolchain {
            let spliced = OrientFixture.spliceExifOrientation(jpeg: IRFixtures.jpeg, code: 6)
            check("O8 fixture EXIF splice reads as orientation 6", PlatformImage.orientation(data: spliced) == 6)
        }
    }
}
