import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Full-chunk archive summaries (owner decision 2026-10-01): the chunk
/// summarizer (temporary and consolidated) and the user-fact extraction
/// receive the WHOLE chunk text. A fixed 100,000-character prefix used to
/// hide the last ~40% of every consolidated chunk (4 x chunk size).
///
/// Drives the REAL `ConversationArchiveService.archiveMessages` path —
/// temporary summary, fact extraction, and the consolidation it triggers at
/// six temporary chunks — against a loopback fixture, and asserts on the
/// HTTP bodies actually sent. Sentinels sit at the very end of each chunk,
/// past the old 100,000-character mark.
///
/// Isolation: re-executes itself in a private scratch home (HOME,
/// XDG_CONFIG_HOME, XDG_DATA_HOME, CFFIXED_USER_HOME, TMPDIR) under a
/// differently named hard link with a reserved test prefix, so it never
/// touches a real install's state or preference domain.
struct ArchiveFullChunkSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__archive-full-chunk-selftest",
        abstract: "Internal: verify archive summaries and fact extraction see the full chunk.",
        shouldDisplay: false
    )

    @Flag(name: .long, help: .hidden) var child = false

    static let linkName = "briglia-mw-fullchunk-selftest"
    static let rootPrefix = "briglia-full-chunk-"
    /// The cut this battery guards against. Every sentinel row also checks
    /// that its sentinel really sits beyond this offset, so the rows cannot
    /// pass vacuously on a too-small fixture.
    static let formerCut = 100_000

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else {
            print("✖ development build required"); throw ExitCode(1)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard child else { try Self.reexecIsolated(); return }
        let failures = try await Self.battery()
        if failures > 0 { throw ExitCode(1) }
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
        for key in env.keys where key.hasPrefix("BRIGLIA_") || key.hasPrefix("ADA_") { env.removeValue(forKey: key) }
        env["HOME"] = home
        env["CFFIXED_USER_HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["XDG_DATA_HOME"] = home + "/.local/share"
        env["XDG_STATE_HOME"] = home + "/.local/state"
        env["XDG_CACHE_HOME"] = home + "/.cache"
        env["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        let linked = root.appendingPathComponent(linkName)
        if link(source.path, linked.path) != 0 { try fm.copyItem(at: source, to: linked) }
        let process = Process()
        process.executableURL = linked
        process.arguments = ["__archive-full-chunk-selftest", "--child"]
        process.environment = env
        try process.run()
        process.waitUntilExit()
        TestPrefsDomains.purge(linkName)
        TestPrefsDomains.finalSweep()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }

    /// One message of roughly `size` characters whose LAST characters are
    /// `sentinel`.
    static func filler(_ label: String, size: Int, sentinel: String) -> String {
        let line = "\(label): ordinary archived conversation text about the project, decisions and files.\n"
        var text = ""
        while text.count + line.count + sentinel.count < size { text += line }
        return text + sentinel
    }

    /// A temporary chunk: `count` messages, alternating roles, the last one
    /// ending with `sentinel`.
    static func chunk(_ label: String, start: Date, count: Int, messageSize: Int, sentinel: String) -> [Message] {
        (0..<count).map { index in
            let last = index == count - 1
            return Message(role: index % 2 == 0 ? .user : .assistant,
                           content: filler("\(label)-\(index)", size: messageSize,
                                           sentinel: last ? sentinel : "end of \(label)-\(index)."),
                           timestamp: start.addingTimeInterval(TimeInterval(index * 60)))
        }
    }

    /// The archive user message (the source segment) of a request body.
    static func userContent(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return "" }
        return messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
    }

    static func systemContent(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return "" }
        return messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n")
    }

    static let extractionMarker = "extract NEW durable user-profile facts"
    static let summaryMarker = "You are summarizing a specific segment"

    static func battery() async throws -> Int {
        var total = 0, failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            total += 1
            if !ok { failures += 1 }
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(String(detail.prefix(400)))")")
        }
        let data = StoragePaths.dataRoot.path
        guard data.contains(rootPrefix), ProcessInfo.processInfo.processName == linkName else {
            print("✖ refusing to run outside the isolated scratch home / private preference domain (data root \(data))")
            return 1
        }

        let server = try WebFixtureServer()
        defer { server.stop() }
        let summaryText = (["Fixture summary of the archived segment."] + Array(repeating: "detail", count: 140)).joined(separator: " ")
        server.route = { request in
            if systemContent(request.body).contains(extractionMarker) {
                return .init(body: WebFixtureServer.chatBody("NO_CHANGES"))
            }
            return .init(body: WebFixtureServer.chatBody(summaryText))
        }
        let settings = [
            KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
            KeychainHelper.openAICompatibleBaseURLKey: "http://127.0.0.1:\(server.port)/v1",
            KeychainHelper.openAICompatibleApiKeyKey: "sk-fixture-full-chunk-0000000000",
            KeychainHelper.openAICompatibleModelKey: "glm-5.3",
            KeychainHelper.assistantNameKey: "Fixture Assistant",
        ]
        for (key, value) in settings { try KeychainHelper.save(key: key, value: value) }

        let archive = ConversationArchiveService()
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        // FC1-FC3: one temporary chunk well past the former cut (~124k chars).
        let tempSentinel = "SENTINEL-TEMP-END-7f3a"
        let first = chunk("t1", start: base, count: 4, messageSize: 31_000, sentinel: tempSentinel)
        server.clear()
        _ = try await archive.archiveMessages(first)
        let firstRequests = server.requests
        let tempSummary = firstRequests.first { systemContent($0.body).contains(summaryMarker) }
        let extraction = firstRequests.first { systemContent($0.body).contains(extractionMarker) }
        let tempUser = tempSummary.map { userContent($0.body) } ?? ""
        let tempOffset = tempUser.range(of: tempSentinel).map { tempUser.distance(from: tempUser.startIndex, to: $0.lowerBound) } ?? -1
        check("FC1 temporary-chunk summary request carries the chunk's final sentinel",
              tempOffset >= 0, "summary request found: \(tempSummary != nil), user content \(tempUser.count) chars")
        check("FC2 that sentinel sits beyond the former 100,000-character cut (row is not vacuous)",
              tempOffset > formerCut, "offset \(tempOffset)")
        let extractionUser = extraction.map { userContent($0.body) } ?? ""
        let extractionOffset = extractionUser.range(of: tempSentinel).map { extractionUser.distance(from: extractionUser.startIndex, to: $0.lowerBound) } ?? -1
        check("FC3 user-fact extraction request carries the same final sentinel past the former cut",
              extractionOffset > formerCut, "extraction request found: \(extraction != nil), offset \(extractionOffset)")

        // Five more temporary chunks: the sixth triggers consolidation of the
        // oldest four (~124k + 3 x ~31k characters).
        var sentinels = [tempSentinel]
        for index in 2...6 {
            let sentinel = "SENTINEL-CHUNK\(index)-END-\(UUID().uuidString.prefix(6))"
            sentinels.append(sentinel)
            let start = base.addingTimeInterval(TimeInterval(index * 3600))
            if index == 6 { server.clear() }
            _ = try await archive.archiveMessages(chunk("t\(index)", start: start, count: 2, messageSize: 15_500, sentinel: sentinel))
        }
        let consolidation = server.requests.last { request in
            let user = userContent(request.body)
            // Identified by its FIRST chunk's sentinel only, so a cut tail
            // fails the content rows below, not the identification.
            return systemContent(request.body).contains(summaryMarker) && user.contains(sentinels[0])
        }
        let consUser = consolidation.map { userContent($0.body) } ?? ""
        check("FC4 consolidation sent one summary request covering the four oldest chunks",
              consolidation != nil, "\(server.requests.count) request(s) after the sixth chunk")
        let lastOffset = consUser.range(of: sentinels[3]).map { consUser.distance(from: consUser.startIndex, to: $0.lowerBound) } ?? -1
        check("FC5 consolidated-chunk summary request carries the LAST chunk's final sentinel",
              lastOffset >= 0, "user content \(consUser.count) chars")
        check("FC6 that sentinel sits beyond the former 100,000-character cut (row is not vacuous)",
              lastOffset > formerCut, "offset \(lastOffset)")
        check("FC7 every consolidated chunk's final sentinel is present, in chronological order",
              sentinels[0...3].map { s in consUser.range(of: s)?.lowerBound }.compactMap { $0 }.count == 4
              && zip(sentinels[0...2], sentinels[1...3]).allSatisfy { a, b in
                  guard let ra = consUser.range(of: a), let rb = consUser.range(of: b) else { return false }
                  return ra.lowerBound < rb.lowerBound
              })
        check("FC8 the consolidated segment ends with the last message's content (nothing after it was cut)",
              consUser.contains(sentinels[3] + "\n"), "tail: \(String(consUser.suffix(200)))")
        let chunks = await archive.getAllChunks()
        check("FC9 the consolidated chunk was committed (4 temporaries replaced by one consolidated)",
              chunks.filter { $0.type == .consolidated }.count == 1 && chunks.filter { $0.type == .temporary }.count == 2,
              chunks.map { $0.type.rawValue }.joined(separator: ","))

        print("Archive full-chunk selftest: \(total - failures)/\(total) passed")
        return failures
    }
}
