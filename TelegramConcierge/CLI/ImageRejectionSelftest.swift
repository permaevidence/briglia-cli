import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// Hidden battery for rejected/unsupported images (private-docs plan
/// CACHE_KEY_AND_IMAGE_REJECTION_PLAN v2 §2.5 and Codex round 2): the image
/// classifier (supported formats pass unchanged without any toolchain,
/// unsupported ones are converted or refused honestly), the provider
/// rejection recogniser, and the bounded recovery that marks, persists and
/// resends (R1–R12 plus the round-2 persistence rows).
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_CONFIG_HOME, XDG_DATA_HOME, CFFIXED_USER_HOME, TMPDIR) under a
/// differently named hard link, like the round-delivery battery.
struct ImageRejectionSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__image-rejection-selftest",
        abstract: "Internal: verify image classification and provider-rejection recovery.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false
    @Option(name: .long, help: .hidden) var only: String?

    static let linkName = "briglia-mw-imgrej"
    static let rootPrefix = "briglia-image-rejection-"

    @MainActor func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(only: only); return }
        let h = MidturnHarness(only: only)
        try await h.runImageRejection()
        if h.failures > 0 {
            print("\n\(h.failures) of \(h.total) image rejection check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll \(h.total) image rejection checks passed")
    }

    static func reexecIsolated(only: String?) throws {
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
        env.removeValue(forKey: ForceDetach.environmentKey)
        env.removeValue(forKey: RoundDelivery.environmentKey)
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__image-rejection-selftest", "--child"] + (only.map { ["--only", $0] } ?? [])
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }
}

/// Synthetic fixtures only (generated images, reconstructed provider error
/// bodies shaped like the ones recorded on 2026-10-09; no real data).
enum IRFixtures {
    static let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDiKKKK+aP20//Z")!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGO8IyfHgA0wYRUdtBIA4FYBKCgCg6AAAAAASUVORK5CYII=")!
    static let webp = Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvB8ABAAdQj3LXo/+BiOh/AAA=")!
    static let gif = Data(base64Encoded: "R0lGODdhCAAIAIEAAMwAAP8AAMwzM/8zMywAAAAACAAIAAAIJAAFABBIcGAAAQMADBBw8KBCgwIXKmRI8WFFiQghWnQocWGAgAA7")!
    static let animatedGIF = Data(base64Encoded: "R0lGODlhCAAIAIEAANweHgAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAACAAIAAAIDwABCBxIsKDBgwgTKkwYEAAh+QQBCgABACwAAAAACAAIAIEe3B4AAAAAAAAAAAAIDwABCBxIsKDBgwgTKkwYEAA7")!
    static let tiff = Data(base64Encoded: "SUkqAAgAAAAKAAABBAABAAAACAAAAAEBBAABAAAACAAAAAIBAwADAAAAhgAAAAMBAwABAAAAAQAAAAYBAwABAAAAAgAAABEBBAABAAAAjAAAABUBAwABAAAAAwAAABYBBAABAAAACAAAABcBBAABAAAAwAAAABwBAwABAAAAAQAAAAAAAAAIAAgACADcHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh7cHh4=")!

    /// The benchmark case: a 24-bit uncompressed BMP (bottom-up rows padded
    /// to 4 bytes), a color gradient so pixel comparisons mean something.
    static func bmp(width: Int = 320, height: Int = 200) -> Data {
        let rowBytes = (width * 3 + 3) & ~3
        let pixels = rowBytes * height
        var data = Data()
        func le16(_ v: Int) { data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF)) }
        func le32(_ v: Int) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((v >> shift) & 0xFF)) } }
        data.append(contentsOf: Array("BM".utf8)); le32(54 + pixels); le16(0); le16(0); le32(54)
        le32(40); le32(width); le32(height); le16(1); le16(24); le32(0); le32(pixels); le32(2835); le32(2835); le32(0); le32(0)
        for y in 0..<height {
            var row = [UInt8]()
            for x in 0..<width { row += [UInt8(y % 256), UInt8((x + y) % 256), UInt8(x % 256)] }  // B, G, R
            row += [UInt8](repeating: 0, count: rowBytes - width * 3)
            data.append(contentsOf: row)
        }
        return data
    }

    static var truncatedPNG: Data { png.prefix(png.count - 12) }       // IEND chunk cut off
    static var truncatedJPEG: Data { jpeg.prefix(jpeg.count / 2) }      // cut inside the header/scan

    /// A minimal one-page PDF (valid cross-reference offsets), rendered by
    /// PDFKit on macOS and poppler on Linux.
    static func pdf() -> Data {
        let content = "0 0 1 rg 20 20 160 160 re f"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// HEIC encoded by ImageIO (macOS only; nil elsewhere or if the encoder
    /// is unavailable).
    static func heic() -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
        #else
        return nil
        #endif
    }

    // Provider rejection bodies, shaped like the 2026-10-09 recordings.
    static let openAIResponsesBMP = #"{"error":{"message":"The image data you provided does not represent a valid image. Please check your input and try again with one of the supported image formats: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].","type":"invalid_request_error","param":"input","code":"invalid_value"}}"#
    static let openAIResponsesCorrupt = #"{"error":{"message":"The image data you provided does not represent a valid image. Please check your input and try again.","type":"invalid_request_error","param":"input","code":"invalid_value"}}"#
    static let openAIChatBMP = #"{"error":{"message":"You uploaded an unsupported image. Please make sure your image has of one the following formats: ['png', 'jpeg', 'gif', 'webp'].","type":"invalid_request_error","param":null,"code":"invalid_image_format"}}"#
    static let openAIChatCorrupt = #"{"error":{"message":"You uploaded an unsupported image. Please make sure your image is valid.","type":"invalid_request_error","param":null,"code":"image_parse_error"}}"#
    static func openRouterWrapped(_ upstream: String) -> String {
        let raw = String(data: try! JSONEncoder().encode(upstream), encoding: .utf8)!
        return #"{"error":{"message":"Provider returned error","code":400,"metadata":{"raw":""# + raw.dropFirst().dropLast() + #"","provider_name":"OpenAI","provider_error_code":"invalid_value"}},"user_id":"user_synthetic"}"#
    }
}

extension MidturnHarness {

    func runImageRejection() async throws {
        let data = StoragePaths.dataRoot.path
        guard data.contains(ImageRejectionSelftest.rootPrefix),
              ProcessInfo.processInfo.processName == ImageRejectionSelftest.linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            failures += 1; return
        }
        TurnWakeCenter.graceSecondsForTesting = 0.6
        MidturnWakeSignal.forcedDelaySecondsForTesting = 0.8
        server = try CaptureServer()
        defer { server.stop() }
        try configureProvider()
        if section("classifier") { irClassifierSection() }
        if section("structure") { irStructureSection() }
        if section("readfile") { await irReadFileSection() }
        if section("recognizer") { irRecognizerSection() }
        if section("transport") { try await irTransportSection() }
        if section("recovery") { try await irRecoverySection() }
        if section("widen") { try await irWidenSection() }
        if section("durability") { try await irDurabilitySection() }
        if section("restart") { try await irRestartSection() }
        if section("races") { try await irRaceSection() }
        if section("subagent") { try await irSubagentSection() }
        if section("ingest") { try await irIngestSection() }
    }

    // MARK: Shared helpers

    /// A fresh manager with a recording channel (notices are observed).
    func irFresh(history: [Message] = []) async -> (ConversationManager, SVRecordingChannel) {
        irResetSeams()
        let channel = SVRecordingChannel(kind: .telegram)
        let manager = await freshManager(history: history)
        manager._svRegisterChannel(channel)
        manager._svSetLastUserAddress(ChannelAddress(kind: .telegram, chatId: "1234567"))
        return (manager, channel)
    }

    func irResetSeams() {
        ModelImage.simulateNoPlatformDecoderForTesting = false
        ModelImageCache.shared.removeAll()
        ConversationManager.imageRejectionBoundaryForTesting = nil
        ConversationManager.plainSalvageFaultForTesting = nil
        ConversationManager.historyWriteFaultForTesting = nil
        ConversationManager.checkpointWriteFaultForTesting = nil
        ConversationManager.responsesSalvageFaultForTesting = nil
        SubagentSessionRegistry.imageRejectionPersistFaultForTesting = nil
        server.requestObserver = nil
        server.routedStatus = nil
        ImageRejectionRecovery.beforeCommitForTesting = nil
        ToolExecutor.detachEligibilityOverrideForTesting = nil
    }

    /// Writes `data` as a scratch file and returns its path.
    func irFile(_ name: String, _ data: Data) -> String {
        let dir = StoragePaths.dataRoot.appendingPathComponent("ir-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url)
        return url.path
    }

    /// Seeds a user image into the images directory and returns its name.
    func irUserImage(_ name: String, _ data: Data) -> String {
        let dir = StoragePaths.dataRoot.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name))
        return name
    }

    func irBase64(_ data: Data) -> String { data.base64EncodedString() }

    func irRequestBodies() -> [String] { requestBodies().map { $0.replacingOccurrences(of: "\\/", with: "/") } }

    func irNotices(_ channel: SVRecordingChannel) -> [String] { channel.delivered.filter { $0.hasPrefix("⚠️ The provider rejected an image") } }

    func irSavedConversation() -> String {
        (try? String(contentsOf: StoragePaths.dataRoot.appendingPathComponent("conversation.json"), encoding: .utf8)) ?? ""
    }

    /// A scripted 400 for the active protocol.
    static func irRejection(responses: Bool) -> String {
        responses ? IRFixtures.openAIResponsesBMP : IRFixtures.openAIChatBMP
    }
}
