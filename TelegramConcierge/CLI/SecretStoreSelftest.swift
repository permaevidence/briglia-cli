import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Hidden deterministic test of the secret store's multi-writer contract
/// (field incident 2026-08-29: `secrets.json` has two writers — the daemon
/// and every short-lived `briglia setup-api` process — and the old per-process
/// forever-cache meant the daemon's next whole-file rewrite silently
/// reverted keys another process had saved, and the daemon couldn't see
/// externally saved keys until restart).
///
/// The store's per-process cache makes single-process assertions vacuous, so
/// the parent re-execs this same binary as `--worker` children whose
/// XDG_CONFIG_HOME/XDG_DATA_HOME point at an isolated temp root; the parent
/// inspects/edits that root's secrets.json directly (raw JSON, no
/// KeychainHelper) and never touches the real installation.
struct SecretStoreSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__secretstore-selftest",
        abstract: "Internal: verify secrets.json cross-process durability.",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Internal worker mode.")
    var worker: String?

    func run() throws {
        if let worker {
            try Worker.run(mode: worker)
            return
        }
        try Parent.run()
    }

    // ------------------------------------------------------------- worker
    // Runs with the isolated XDG roots already in its environment, so every
    // KeychainHelper touch lands in the parent's temp store.
    private enum Worker {
        static func run(mode: String) throws {
            switch mode {
            case "save-ab":
                try KeychainHelper.save(key: "alpha", value: "A1")
                try KeychainHelper.save(key: "beta", value: "B1")
                emit("DONE")
            case "load-alpha":
                emit(KeychainHelper.load(key: "alpha") ?? "MISSING")
            // The daemon-clobber reproduction: warm the cache, hold while the
            // parent writes the store from "another process", then save — the
            // parent's key must survive our whole-file rewrite.
            case "warm-then-save":
                _ = KeychainHelper.load(key: "alpha")
                emit("READY")
                _ = readLine()
                try KeychainHelper.save(key: "gamma", value: "G1")
                emit("DONE")
            // The restart-blindness reproduction: warm the cache, hold while
            // the parent injects a key externally, then report whether the
            // long-lived process can see it without restarting.
            case "warm-then-load":
                _ = KeychainHelper.load(key: "alpha")
                emit("READY")
                _ = readLine()
                emit(KeychainHelper.load(key: "injected") ?? "MISSING")
            // Batch semantics against a concurrently grown store.
            case "warm-then-batch":
                _ = KeychainHelper.load(key: "alpha")
                emit("READY")
                _ = readLine()
                try KeychainHelper.saveBatch(["alpha": "A2", "beta": nil])
                emit("DONE")
            case "save-slow-marker":
                // Used for the flock-contention check: the save itself is the
                // measured operation; DONE is only printed once the write
                // committed (i.e. after the parent released the lock).
                try KeychainHelper.save(key: "contended", value: "C1")
                emit("DONE")
            default:
                emit("UNKNOWN-MODE")
                throw ExitCode(2)
            }
        }

        private static func emit(_ line: String) {
            print(line)
            fflush(stdout)
        }
    }

    // ------------------------------------------------------------- parent
    private enum Parent {
        static func run() throws {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("ada-secretstore-selftest-\(UUID().uuidString)")
            let configRoot = temp.appendingPathComponent("config")
            let dataRoot = temp.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let storePath = configRoot.appendingPathComponent("briglia/secrets.json").path
            let lockPath = configRoot.appendingPathComponent("briglia/secrets.lock").path

            var failures = 0
            func check(_ label: String, _ ok: Bool, _ detail: String = "") {
                print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
                if !ok { failures += 1 }
            }

            func readStore() -> [String: String] {
                (try? Data(contentsOf: URL(fileURLWithPath: storePath)))
                    .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            }
            // "Another process wrote the file" — a plain non-atomic rewrite is
            // deliberate: same inode, so only mtime/size can betray the change.
            func writeStore(_ store: [String: String]) throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try (try encoder.encode(store))
                    .write(to: URL(fileURLWithPath: storePath))
            }

            // 1. Plain persistence across processes: one worker saves, a
            //    second (fresh) worker loads.
            var out = try runWorker("save-ab", configRoot: configRoot, dataRoot: dataRoot).output
            check("worker save commits", out.contains("DONE"), out)
            check("store file 0600", filePermissions(storePath) == 0o600,
                  String(format: "%o", filePermissions(storePath)))
            out = try runWorker("load-alpha", configRoot: configRoot, dataRoot: dataRoot).output
            check("fresh process reads saved key", out.contains("A1"), out)

            // 2. THE regression: a long-lived process with a warm cache must
            //    not revert another writer's key on its own next save.
            var proc = try startWorker("warm-then-save", configRoot: configRoot, dataRoot: dataRoot)
            try proc.expect("READY")
            var external = readStore()
            external["fromapp"] = "F1"
            try writeStore(external)
            proc.release()
            try proc.expect("DONE")
            proc.finish()
            var store = readStore()
            check("stale-cache save preserves the other writer's key",
                  store["fromapp"] == "F1", "\(store)")
            check("...while committing its own", store["gamma"] == "G1", "\(store)")
            check("...and keeping its warm-cache keys", store["alpha"] == "A1", "\(store)")

            // 3. Restart blindness: a long-lived process must SEE a key
            //    another process saved after its cache warmed.
            proc = try startWorker("warm-then-load", configRoot: configRoot, dataRoot: dataRoot)
            try proc.expect("READY")
            external = readStore()
            external["injected"] = "I1"
            try writeStore(external)
            proc.release()
            let seen = try proc.expectLine()
            proc.finish()
            check("warm process sees externally saved key without restart",
                  seen == "I1", seen)

            // 4. saveBatch (update + delete in one write) over a concurrently
            //    grown store: the external key survives, the batch applies.
            proc = try startWorker("warm-then-batch", configRoot: configRoot, dataRoot: dataRoot)
            try proc.expect("READY")
            external = readStore()
            external["grew"] = "W1"
            try writeStore(external)
            proc.release()
            try proc.expect("DONE")
            proc.finish()
            store = readStore()
            check("batch preserves concurrent external key", store["grew"] == "W1", "\(store)")
            check("batch update applied", store["alpha"] == "A2", "\(store)")
            check("batch delete applied", store["beta"] == nil, "\(store)")

            // 5. Real cross-process flock contention: parent holds LOCK_EX on
            //    the sidecar; a saving worker must block until release.
            let lockFD = open(lockPath, O_CREAT | O_WRONLY, 0o600)
            check("parent can open the sidecar lock", lockFD >= 0)
            if lockFD >= 0 {
                check("parent takes LOCK_EX", flock(lockFD, LOCK_EX) == 0)
                let contender = try startWorker("save-slow-marker",
                                                configRoot: configRoot, dataRoot: dataRoot)
                Thread.sleep(forTimeInterval: 0.4)
                check("writer blocks while another process holds the lock",
                      !contender.stdoutSoFar().contains("DONE"),
                      contender.stdoutSoFar())
                check("...and has not written yet", readStore()["contended"] == nil)
                _ = flock(lockFD, LOCK_UN)
                close(lockFD)
                try contender.expect("DONE", timeout: 10)
                contender.finish()
                check("writer completes after release", readStore()["contended"] == "C1")
            }

            // 6. Damaged-store protection (Codex, 2026-08-29): an EXISTING
            //    but corrupt or unreadable store must FAIL mutation with its
            //    bytes intact — treating it as empty rewrote the file as
            //    delta-only and reported ok, erasing every stored secret.
            let storeFile = URL(fileURLWithPath: storePath)
            let goodBytes = try Data(contentsOf: storeFile)
            let garbage = Data("not-json {{{".utf8)
            try garbage.write(to: storeFile)
            var res = try runWorker("save-slow-marker", configRoot: configRoot, dataRoot: dataRoot)
            check("save against corrupt store fails", res.status != 0, res.output)
            check("corrupt store bytes preserved",
                  (try? Data(contentsOf: storeFile)) == garbage)
            try goodBytes.write(to: storeFile)
            res = try runWorker("save-slow-marker", configRoot: configRoot, dataRoot: dataRoot)
            check("save works again once the store is repaired",
                  res.status == 0 && readStore()["contended"] == "C1", res.output)
            check("...and repaired-store save kept earlier keys",
                  readStore()["alpha"] == "A2", "\(readStore())")
            if geteuid() != 0 {
                _ = chmod(storePath, 0)
                res = try runWorker("save-slow-marker", configRoot: configRoot, dataRoot: dataRoot)
                _ = chmod(storePath, 0o600)
                check("save against unreadable store fails", res.status != 0, res.output)
                check("unreadable store bytes preserved", readStore()["alpha"] == "A2",
                      "\(readStore())")
            } else {
                print("skip unreadable-store checks (running as root — chmod is inert)")
            }

            // CredentialCatalog completeness: every `static let …Key = "…"`
            // constant in KeychainHelper.swift and ProviderProfiles.swift must
            // be classified, so a new key cannot be added without deciding
            // whether the redactor covers it.
            if let repoRoot = locateRepoRoot() {
                let sources = [
                    "TelegramConcierge/Utilities/KeychainHelper.swift",
                    "TelegramConcierge/Services/ProviderProfiles.swift",
                    "TelegramConcierge/Services/ProviderServers.swift",
                ]
                var scanned = 0
                var unclassified: [String] = []
                let pattern = try NSRegularExpression(pattern: #"static let (\w+Key)\s*=\s*"([^"]+)""#)
                for rel in sources {
                    let text = (try? String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
                    let ns = text as NSString
                    for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                        let name = ns.substring(with: m.range(at: 1))
                        let value = ns.substring(with: m.range(at: 2))
                        scanned += 1
                        if CredentialCatalog.treatment(forKey: value) == nil { unclassified.append("\(name)=\(value)") }
                    }
                }
                check("credential catalogue scan found the key constants (\(scanned))", scanned >= 60)
                check("every key constant is classified in CredentialCatalog", unclassified.isEmpty,
                      unclassified.joined(separator: ", "))
            } else {
                print("skip credential catalogue scan (source tree not found; set BRIGLIA_REPO_ROOT)")
            }
            check("redaction set is exactly the Telegram bot token (+ service-key family)",
                  CredentialCatalog.redactedKeys == [KeychainHelper.telegramBotTokenKey]
                  && CredentialCatalog.families.contains { $0.prefix == KeychainHelper.serviceKeyPrefix && $0.treatment == .redact },
                  "\(CredentialCatalog.redactedKeys)")
            check("provider and AgentMail keys are classified visible",
                  [KeychainHelper.openRouterApiKeyKey, ProviderProfiles.opencodeApiKeyKey,
                   KeychainHelper.serperApiKeyKey, KeychainHelper.agentMailApiKeyKey]
                    .allSatisfy { CredentialCatalog.treatment(forKey: $0) == .visible })

            print(failures == 0
                  ? "secret-store selftest: all checks passed"
                  : "secret-store selftest: \(failures) FAILURES")
            if failures != 0 { throw ExitCode(1) }
        }

        private static func locateRepoRoot() -> URL? {
            var candidates: [URL] = []
            if let env = ProcessInfo.processInfo.environment["BRIGLIA_REPO_ROOT"] {
                candidates.append(URL(fileURLWithPath: env))
            }
            candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            // The debug binary lives at <repo>/.build/<config>/briglia.
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            for candidate in candidates {
                let hasPackage = FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path)
                if hasPackage { return candidate }
            }
            return nil
        }

        private static func filePermissions(_ path: String) -> Int {
            var st = stat()
            guard stat(path, &st) == 0 else { return -1 }
            return Int(st.st_mode) & 0o777
        }

        private static func environment(configRoot: URL, dataRoot: URL) -> [String: String] {
            var env = ProcessInfo.processInfo.environment
            env["XDG_CONFIG_HOME"] = configRoot.path
            env["XDG_DATA_HOME"] = dataRoot.path
            return env
        }

        private static func selfExecutable() -> URL {
            (Bundle.main.executableURL
             ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        }

        /// One-shot worker: run to completion, return combined stdout.
        private static func runWorker(_ mode: String, configRoot: URL, dataRoot: URL)
            throws -> (output: String, status: Int32) {
            let child = try startWorker(mode, configRoot: configRoot, dataRoot: dataRoot)
            child.release()  // close stdin so any readLine() returns
            let status = child.finish()
            return (child.stdoutSoFar(), status)
        }

        /// Interactive worker with a stdin gate and polled stdout capture
        /// (poll-reader, not readabilityHandler — corelibs tail-loss lesson).
        final class WorkerHandle {
            let process: Process
            private let stdoutPipe: Pipe
            private let stdinPipe: Pipe
            private var captured = Data()
            private let captureLock = NSLock()
            private var consumedUpTo = 0

            init(process: Process, stdoutPipe: Pipe, stdinPipe: Pipe) {
                self.process = process
                self.stdoutPipe = stdoutPipe
                self.stdinPipe = stdinPipe
            }

            private func drain() {
                let data = stdoutPipe.fileHandleForReading.availableDataNonBlocking()
                if !data.isEmpty {
                    captureLock.lock()
                    captured.append(data)
                    captureLock.unlock()
                }
            }

            func stdoutSoFar() -> String {
                drain()
                captureLock.lock()
                defer { captureLock.unlock() }
                return String(data: captured, encoding: .utf8) ?? ""
            }

            /// Wait until `marker` appears in stdout AFTER the last expect.
            func expect(_ marker: String, timeout: TimeInterval = 5) throws {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    drain()
                    captureLock.lock()
                    let text = String(data: captured, encoding: .utf8) ?? ""
                    captureLock.unlock()
                    let fresh = String(text.dropFirst(consumedUpTo))
                    if let range = fresh.range(of: marker) {
                        consumedUpTo += fresh.distance(from: fresh.startIndex,
                                                       to: range.upperBound)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                throw ValidationError("timeout waiting for \(marker); got: \(stdoutSoFar())")
            }

            /// Wait for the next non-empty line after the last expect.
            func expectLine(timeout: TimeInterval = 5) throws -> String {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    drain()
                    captureLock.lock()
                    let text = String(data: captured, encoding: .utf8) ?? ""
                    captureLock.unlock()
                    let fresh = String(text.dropFirst(consumedUpTo))
                    if let nl = fresh.firstIndex(of: "\n") {
                        let line = String(fresh[..<nl]).trimmingCharacters(in: .whitespaces)
                        consumedUpTo += fresh.distance(from: fresh.startIndex, to: nl) + 1
                        if !line.isEmpty { return line }
                        continue
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                throw ValidationError("timeout waiting for a line; got: \(stdoutSoFar())")
            }

            /// Open the worker's stdin gate (its readLine() returns).
            func release() {
                stdinPipe.fileHandleForWriting.write(Data("go\n".utf8))
                try? stdinPipe.fileHandleForWriting.close()
            }

            @discardableResult
            func finish(timeout: TimeInterval = 10) -> Int32 {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    drain()
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                drain()
                return process.terminationStatus
            }
        }

        private static func startWorker(_ mode: String, configRoot: URL, dataRoot: URL)
            throws -> WorkerHandle {
            let process = Process()
            process.executableURL = selfExecutable()
            process.arguments = ["__secretstore-selftest", "--worker", mode]
            process.environment = environment(configRoot: configRoot, dataRoot: dataRoot)
            let stdoutPipe = Pipe()
            let stdinPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.standardError
            process.standardInput = stdinPipe
            try process.run()
            return WorkerHandle(process: process, stdoutPipe: stdoutPipe, stdinPipe: stdinPipe)
        }
    }
}

private extension FileHandle {
    /// Non-blocking best-effort read of whatever is buffered right now.
    func availableDataNonBlocking() -> Data {
        let fd = fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        var out = Data()
        while true {
            #if canImport(Darwin)
            let n = Darwin.read(fd, &buffer, buffer.count)
            #else
            let n = Glibc.read(fd, &buffer, buffer.count)
            #endif
            if n > 0 { out.append(contentsOf: buffer[0..<n]); continue }
            break
        }
        return out
    }
}
