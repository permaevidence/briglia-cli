import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ProjectsZipAutoExtractor {
    static let shared = ProjectsZipAutoExtractor()
    static let invalidRootFilesDetectedNotification = Notification.Name("ProjectsZipAutoExtractor.invalidRootFilesDetected")

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.telegramconcierge.projects-zip-auto-extractor", qos: .utility)
    private let minimumArchiveAge: TimeInterval = 2
    private let retryAfterFailure: TimeInterval = 10

    #if canImport(Darwin)
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFileDescriptor: CInt = -1
    #endif
    private var isStarted = false
    private var isProcessing = false
    private var hasPendingScan = false
    private var scanWorkItem: DispatchWorkItem?
    private var restartWorkItem: DispatchWorkItem?
    private var failureTimestamps: [String: Date] = [:]
    private var lastInvalidRootFilePaths: Set<String> = []

    private init() {}

    func start() {
        queue.async { [weak self] in
            self?.startIfNeeded()
        }
    }

    private var projectsDirectory: URL {
        let folder = StoragePaths.dataRoot.appendingPathComponent("projects", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func startIfNeeded() {
        guard !isStarted else { return }
        #if canImport(Darwin)
        startWatchingProjectsFolder()
        #else
        // Linux libdispatch has no file-system object sources (kqueue API);
        // a 5-second polling loop gives the same "drop a ZIP, it extracts"
        // behavior at negligible cost.
        isStarted = true
        schedulePollingLoop()
        #endif
        scheduleScan(delay: 0.5)
    }

    #if !canImport(Darwin)
    private func schedulePollingLoop() {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.scanForArchives()
            self.schedulePollingLoop()
        }
    }
    #endif

    #if canImport(Darwin)
    private func startWatchingProjectsFolder() {
        let path = projectsDirectory.path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleWatcherRestart(delay: 2)
            return
        }

        watchedFileDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.handleWatcherEvent()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.watchedFileDescriptor >= 0 {
                close(self.watchedFileDescriptor)
                self.watchedFileDescriptor = -1
            }
        }

        watcher = source
        isStarted = true
        source.resume()
    }

    private func handleWatcherEvent() {
        let events = watcher?.data ?? []
        if events.contains(.rename) || events.contains(.delete) {
            restartWatcher()
            return
        }
        scheduleScan(delay: 0.6)
    }

    private func restartWatcher() {
        watcher?.cancel()
        watcher = nil
        isStarted = false
        scheduleWatcherRestart(delay: 1)
    }

    private func scheduleWatcherRestart(delay: TimeInterval) {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.startIfNeeded()
        }
        restartWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
    #endif

    private func scheduleScan(delay: TimeInterval) {
        scanWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.scanForArchives()
        }
        scanWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scanForArchives() {
        if isProcessing {
            hasPendingScan = true
            return
        }

        isProcessing = true
        defer {
            isProcessing = false
            if hasPendingScan {
                hasPendingScan = false
                scheduleScan(delay: 0.5)
            }
        }

        let now = Date()
        let discovery = discoverEligibleArchives(now: now)
        handleInvalidRootFiles(discovery.invalidRootFiles)
        for archiveURL in discovery.archives {
            extractAndRemoveArchive(at: archiveURL)
        }

        if discovery.sawTooRecentArchive {
            scheduleScan(delay: minimumArchiveAge)
        }
    }

    private func discoverEligibleArchives(now: Date) -> (archives: [URL], sawTooRecentArchive: Bool, invalidRootFiles: [URL]) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], false, [])
        }

        var archives: [URL] = []
        var sawTooRecentArchive = false
        var invalidRootFiles: [URL] = []

        for url in entries {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }

            guard url.pathExtension.lowercased() == "zip" else {
                invalidRootFiles.append(url)
                continue
            }

            let path = url.path
            if let lastFailure = failureTimestamps[path],
               now.timeIntervalSince(lastFailure) < retryAfterFailure {
                continue
            }

            if let modifiedDate = values?.contentModificationDate,
               now.timeIntervalSince(modifiedDate) < minimumArchiveAge {
                sawTooRecentArchive = true
                continue
            }

            archives.append(url)
        }

        archives.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        invalidRootFiles.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        return (archives, sawTooRecentArchive, invalidRootFiles)
    }

    private func handleInvalidRootFiles(_ invalidRootFiles: [URL]) {
        let currentInvalidPaths = Set(invalidRootFiles.map(\.path))
        guard currentInvalidPaths != lastInvalidRootFilePaths else { return }
        lastInvalidRootFilePaths = currentInvalidPaths

        guard !invalidRootFiles.isEmpty else { return }

        let filenames = invalidRootFiles.map(\.lastPathComponent)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.invalidRootFilesDetectedNotification,
                object: nil,
                userInfo: ["filenames": filenames]
            )
        }
    }

    private func extractAndRemoveArchive(at archiveURL: URL) {
        do {
            try Self.unzipArchive(archiveURL: archiveURL, destinationURL: projectsDirectory)
            try fileManager.removeItem(at: archiveURL)
            failureTimestamps.removeValue(forKey: archiveURL.path)
            print("[ProjectsZipAutoExtractor] Extracted and removed \(archiveURL.lastPathComponent)")
        } catch {
            failureTimestamps[archiveURL.path] = Date()
            print("[ProjectsZipAutoExtractor] Failed to process \(archiveURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Backstop for one unzip run (listing or extraction). Only a broken or
    /// stuck unzip comes near it: extracting several GB takes minutes. On
    /// expiry unzip is killed and reaped and the archive fails like any other
    /// unzip error (kept in place, retried later).
    static let unzipTimeout: TimeInterval = 30 * 60

    static func unzipArchive(
        archiveURL: URL,
        destinationURL: URL,
        unzipPath: String = "/usr/bin/unzip",
        timeout: TimeInterval = unzipTimeout
    ) throws {
        let entries = try listArchiveEntries(archiveURL: archiveURL, unzipPath: unzipPath, timeout: timeout)
        guard !entries.isEmpty else {
            throw NSError(
                domain: "ProjectsZipAutoExtractor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ZIP archive is empty."]
            )
        }

        guard entries.allSatisfy({ isSafeArchiveEntryPath($0) }) else {
            throw NSError(
                domain: "ProjectsZipAutoExtractor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ZIP archive contains unsafe paths."]
            )
        }

        _ = try runProcess(
            executablePath: unzipPath,
            arguments: ["-qq", "-n", archiveURL.path, "-d", destinationURL.path],
            context: "Failed to extract ZIP archive.",
            timeout: timeout
        )
    }

    static func listArchiveEntries(
        archiveURL: URL,
        unzipPath: String = "/usr/bin/unzip",
        timeout: TimeInterval = unzipTimeout
    ) throws -> [String] {
        let stdout = try runProcess(
            executablePath: unzipPath,
            arguments: ["-Z1", archiveURL.path],
            context: "Failed to inspect ZIP archive.",
            timeout: timeout
        )

        return stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Runs unzip and returns its stdout. Both pipes are drained WHILE unzip
    /// runs: reading them only after exit hung forever once the output passed
    /// one pipe buffer (~64 KB, e.g. `-Z1` on a zip of ~1,500+ entries).
    static func runProcess(
        executablePath: String,
        arguments: [String],
        context: String,
        timeout: TimeInterval = unzipTimeout
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let capture = ProcessOutputCapture(stdout: stdoutPipe, stderr: stderrPipe)
        capture.start()

        guard ProcessOutputCapture.waitForExit(process, until: Date().addingTimeInterval(timeout)) else {
            kill(process.processIdentifier, SIGKILL)
            _ = ProcessOutputCapture.waitForExit(process, until: Date().addingTimeInterval(2))
            _ = capture.finish(within: 2)
            let limit = timeout >= 60 ? "\(Int(timeout / 60)) minutes" : "\(timeout) seconds"
            throw NSError(
                domain: "ProjectsZipAutoExtractor",
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "\(context) unzip did not finish within \(limit) and was stopped."]
            )
        }

        let output = capture.finish(within: 2)
        let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
        let stderr = ProcessOutputCapture.text(output.stderr)

        guard process.terminationStatus == 0 else {
            let stderrMessage = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutMessage = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = !stderrMessage.isEmpty
                ? stderrMessage
                : (!stdoutMessage.isEmpty ? stdoutMessage : "Process exited with code \(process.terminationStatus)")

            throw NSError(
                domain: "ProjectsZipAutoExtractor",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(context) \(message)"]
            )
        }

        // Only a complete listing may be used: a cut or unfinished one could
        // hide an unsafe entry from the path check. A zero exit status does
        // not prove the output was read to its end.
        if let problem = output.stdoutProblem {
            throw NSError(
                domain: "ProjectsZipAutoExtractor",
                code: Int(output.stdoutTruncated ? EFBIG : EIO),
                userInfo: [NSLocalizedDescriptionKey: "\(context) unzip output \(problem)."]
            )
        }

        return stdout
    }

    static func isSafeArchiveEntryPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") || normalized.hasPrefix("~") { return false }

        let components = normalized.split(separator: "/")
        guard !components.isEmpty else { return false }

        for component in components {
            if component == "." || component == ".." || component.isEmpty {
                return false
            }
        }

        return true
    }
}
