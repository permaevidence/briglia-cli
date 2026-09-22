import ArgumentParser
import Foundation

/// Hidden deterministic test of the `/deleteuserdata` wipe.
/// Pins (a) the two-step confirmation matrix that protects months of
/// memory from a fat-fingered send, (b) the secret-store deletion the
/// wipe's step 10 depends on, (c) the background-registry purge that
/// prevents killed jobs and queued completion notices from repopulating a
/// wiped conversation, and (d) the shared-artifact wipe (logs +
/// tool-output/spill directory) with its absence tolerance.
/// Fully isolated: XDG roots and TMPDIR are pointed at a temp directory
/// BEFORE anything touches KeychainHelper / StoragePaths /
/// TruncationService (their locations freeze at first access — same
/// ordering contract the trigger selftest relies on).
struct DeleteUserDataSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__deleteuserdata-selftest",
        abstract: "Internal: verify the /deleteuserdata confirmation matrix and wipe helpers.",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-deleteuserdata-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled {
                print("WATCHDOG: deleteuserdata selftest exceeded 120s — hung; aborting")
                Foundation.exit(3)
            }
        }
        defer { watchdog.cancel() }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        func confirmationMatrix() {
            typealias D = DeleteUserDataConfirmation

            // 1. Bare command: instructions, never a wipe.
            check("bare command with stored name → instructions naming the name",
                  D.decide(argument: "", storedName: "Sofia") == .instructions(token: "Sofia"))
            check("bare command without stored name → instructions naming CONFIRM",
                  D.decide(argument: "", storedName: nil) == .instructions(token: D.fallbackToken))
            check("whitespace-only stored name counts as no name",
                  D.decide(argument: "", storedName: "   ") == .instructions(token: D.fallbackToken))
            check("whitespace-only argument counts as bare",
                  D.decide(argument: "  \n ", storedName: "Sofia") == .instructions(token: "Sofia"))

            // 2. Matching: case- and whitespace-run-insensitive, exact otherwise.
            check("exact name confirms",
                  D.decide(argument: "Sofia", storedName: "Sofia") == .confirmed)
            check("case-insensitive name confirms",
                  D.decide(argument: "sofia", storedName: "Sofia") == .confirmed)
            check("multi-word name with extra interior spaces confirms",
                  D.decide(argument: "sofia   bruni", storedName: "Sofia Bruni") == .confirmed)
            check("surrounding whitespace on the argument is ignored",
                  D.decide(argument: "  Sofia  ", storedName: "Sofia") == .confirmed)
            check("CONFIRM literal confirms only when no name is stored",
                  D.decide(argument: "confirm", storedName: nil) == .confirmed)

            // 3. Refusals: anything else is a mismatch, never a wipe.
            check("wrong name refuses",
                  D.decide(argument: "Mario", storedName: "Sofia") == .mismatch)
            check("prefix of the name refuses",
                  D.decide(argument: "Sofi", storedName: "Sofia") == .mismatch)
            check("partial multi-word name refuses",
                  D.decide(argument: "Sofia", storedName: "Sofia Bruni") == .mismatch)
            check("CONFIRM literal refuses while a name is stored",
                  D.decide(argument: "CONFIRM", storedName: "Sofia") == .mismatch)
            check("accented vs unaccented name refuses (no accent folding)",
                  D.decide(argument: "Niccolo", storedName: "Niccolò") == .mismatch)
        }

        func secretStore() throws {
            // The store the wipe's secret deletions rely on: save → delete →
            // gone, while an unrelated key survives (mirrors keys-are-kept).
            try KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Sofia")
            try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "unrelated-key")
            check("user name round-trips through the secret store",
                  KeychainHelper.load(key: KeychainHelper.userNameKey) == "Sofia")
            try KeychainHelper.delete(key: KeychainHelper.userNameKey)
            check("deleted user name is gone",
                  KeychainHelper.load(key: KeychainHelper.userNameKey) == nil)
            check("unrelated key survives the deletion",
                  KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) == "unrelated-key")
        }

        func registryPurge() async {
            // Queued completion notice: a fast job settles and enqueues its
            // notice, which must NOT survive the purge.
            let fast = await BashTools.runBackground(command: "echo wipe-me")
            let fastHandle = handleId(from: fast)
            check("purge setup: fast background job started", fastHandle != nil,
                  String(fast.content.prefix(200)))
            if let h = fastHandle {
                var settled = false
                for _ in 0..<100 {
                    if let s = await BackgroundProcessRegistry.shared.snapshot(handleId: h),
                       s.status != .running { settled = true; break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                check("purge setup: fast job settled (notice queued)", settled)
            }

            // Running job: must be killed, not merely forgotten.
            let marker = "ada-wipe-selftest-\(UUID().uuidString.prefix(8))"
            let slow = await BashTools.runBackground(command: "sleep 300 # \(marker)")
            let slowHandle = handleId(from: slow)
            check("purge setup: slow background job started", slowHandle != nil,
                  String(slow.content.prefix(200)))

            let running = await BackgroundProcessRegistry.shared.purgeAllForWipe()
            check("purge reports the running job", running == 1, "reported \(running)")

            let drained = await BackgroundProcessRegistry.shared.drainCompletions()
            check("no completion notices survive the purge", drained.isEmpty,
                  "\(drained.count) drained")
            if let h = fastHandle {
                let gone = await BackgroundProcessRegistry.shared.snapshot(handleId: h) == nil
                check("settled entry is gone from the registry", gone)
            }
            if let h = slowHandle {
                let gone = await BackgroundProcessRegistry.shared.snapshot(handleId: h) == nil
                check("running entry is gone from the registry", gone)
            }

            // The marker process itself must be dead (SIGKILL pass ran).
            var processDead = false
            for _ in 0..<60 {
                if !markerProcessAlive(marker) { processDead = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            check("killed job's process is actually dead", processDead)
        }

        func sharedArtifacts() throws {
            let logsDir = StoragePaths.dataRoot.appendingPathComponent("logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            try "q=secret search".write(
                to: logsDir.appendingPathComponent("web-pipeline.log"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                atPath: TruncationService.truncationDir, withIntermediateDirectories: true)
            try "spilled output".write(
                toFile: TruncationService.truncationDir + "tool_wipe_test.txt", atomically: true, encoding: .utf8)

            let first = UserDataWipe.wipeSharedArtifacts()
            check("shared-artifact wipe reports no failures", first.isEmpty, first.joined(separator: "; "))
            check("logs directory is gone", !FileManager.default.fileExists(atPath: logsDir.path))
            check("tool-output/spill directory is gone",
                  !FileManager.default.fileExists(atPath: TruncationService.truncationDir))

            // Absence is success: a second wipe (nothing left) must be clean.
            let second = UserDataWipe.wipeSharedArtifacts()
            check("re-wipe of absent artifacts reports no failures", second.isEmpty,
                  second.joined(separator: "; "))
            check("remove() tolerates a missing path",
                  UserDataWipe.remove(tempRoot.path + "/definitely-absent", label: "x") == nil)
        }

        func quiesceBarrier() async {
            // A task that exits (like a real subagent reaching its commit
            // point) must be WAITED for, not just cancelled: quiesce may
            // only return once the map is empty.
            let doneId = "quiesce-done-\(UUID().uuidString.prefix(8))"
            let started = Date()
            let finishing = Task<Void, Never> {
                // Cancellation-immune delay: quiesce cancels the task, but a
                // real subagent still takes time to reach its commit point.
                let until = Date().addingTimeInterval(0.6)
                while Date() < until {
                    usleep(20_000)
                }
                await SubagentBackgroundRegistry.shared._testUnregister(id: doneId)
            }
            await SubagentBackgroundRegistry.shared._testRegister(id: doneId, task: finishing)
            let leftoversA = await SubagentBackgroundRegistry.shared.cancelAllAndQuiesce(timeoutSeconds: 5)
            check("quiesce waits for a finishing task", leftoversA.isEmpty,
                  "leftovers: \(leftoversA)")
            check("quiesce actually blocked until the task exited",
                  Date().timeIntervalSince(started) >= 0.5)

            // A task that never reaches its commit point must be reported at
            // the deadline, never silently dropped.
            let stuckId = "quiesce-stuck-\(UUID().uuidString.prefix(8))"
            let stuck = Task<Void, Never> {
                let until = Date().addingTimeInterval(30)
                while Date() < until {
                    usleep(50_000)
                }
                // Deliberately no _testUnregister: simulates a run that
                // never commits.
            }
            await SubagentBackgroundRegistry.shared._testRegister(id: stuckId, task: stuck)
            let leftoversB = await SubagentBackgroundRegistry.shared.cancelAllAndQuiesce(timeoutSeconds: 1)
            check("quiesce reports a stuck task at the deadline",
                  leftoversB == [stuckId], "got: \(leftoversB)")
            stuck.cancel()
            await SubagentBackgroundRegistry.shared._testUnregister(id: stuckId)
        }

        func setNameValidation() {
            typealias N = UserNameChange
            check("plain name validates and trims",
                  N.validate("  Sofia  ") == .valid("Sofia"))
            check("interior whitespace runs (incl. newlines) collapse",
                  N.validate("Sofia \n  Bruni") == .valid("Sofia Bruni"))
            check("empty argument is rejected", N.validate("   ") == .empty)
            check("over-long name is rejected",
                  N.validate(String(repeating: "a", count: N.maxLength + 1)) == .tooLong)
            check("boundary-length name is accepted",
                  N.validate(String(repeating: "a", count: N.maxLength))
                    == .valid(String(repeating: "a", count: N.maxLength)))
            check("the reserved word confirm is rejected in any case",
                  N.validate("CONFIRM") == .reserved && N.validate("confirm") == .reserved)
            // Round trip with /deleteuserdata: a name set through /setname
            // must be accepted as the wipe's confirmation token.
            if case .valid(let name) = N.validate("Sofia  Bruni") {
                check("set name works as the wipe confirmation token",
                      DeleteUserDataConfirmation.decide(argument: "sofia bruni", storedName: name)
                        == .confirmed)
            } else {
                check("set name works as the wipe confirmation token", false)
            }
        }

        func personaPrecedence() {
            // Regression (review round 5): with structured context present,
            // both prompt paths used to drop the explicitly stored name
            // entirely — /setname changed the wipe token but not the name
            // Briglia actually saw.
            let profile = "USER PROFILE: The user's name is OldName, a developer from Italy."
            let overlaid = OpenRouterService.buildPersonaIntro(
                assistantName: "Briglia", userName: "NewName",
                structuredUserContext: profile, bareFallback: "fb")
            check("explicit name overlays structured context",
                  overlaid.hasPrefix("The user's name is NewName."), String(overlaid.prefix(120)))
            check("structured profile text is preserved under the overlay",
                  overlaid.contains("OldName"))
            check("structured context without an explicit name passes through verbatim",
                  OpenRouterService.buildPersonaIntro(
                      assistantName: "Briglia", userName: "  ",
                      structuredUserContext: profile, bareFallback: "fb") == profile)
            check("no structured context → basic intro from names",
                  OpenRouterService.buildPersonaIntro(
                      assistantName: "Briglia", userName: "NewName",
                      structuredUserContext: nil, bareFallback: "fb")
                    == "Your name is Briglia. You are assisting NewName.")
            // Persona memory bridge (rename plan §4.4): on a migrated install
            // the prior name is stated once, authoritatively; never when the
            // names coincide, never without a current name.
            check("bridge: plain intro states the previous name",
                  OpenRouterService.buildPersonaIntro(
                      assistantName: "Bree", userName: "NewName",
                      structuredUserContext: nil, bareFallback: "fb", previousName: "Ada")
                    == "Your name is Bree. You were previously called Ada; Bree is your current name. You are assisting NewName.")
            let bridged = OpenRouterService.buildPersonaIntro(
                assistantName: "Bree", userName: "NewName",
                structuredUserContext: profile, bareFallback: "fb", previousName: "Ada")
            check("bridge: structured context gets an authoritative identity line first",
                  bridged.hasPrefix("Your name is Bree. You were previously called Ada; Bree is your current name.")
                  && bridged.contains("The user's name is NewName.") && bridged.hasSuffix(profile),
                  String(bridged.prefix(160)))
            check("bridge: same name → no bridge line",
                  OpenRouterService.buildPersonaIntro(
                      assistantName: "Ada", userName: "NewName",
                      structuredUserContext: nil, bareFallback: "fb", previousName: "Ada")
                    == "Your name is Ada. You are assisting NewName.")
            check("bridge: custom current name is preserved verbatim",
                  OpenRouterService.buildPersonaIntro(
                      assistantName: "Nina", userName: nil,
                      structuredUserContext: nil, bareFallback: "fb", previousName: "Ada")
                    == "Your name is Nina. You were previously called Ada; Nina is your current name.")
            check("bridge: structured context unchanged without a bridge",
                  OpenRouterService.buildPersonaIntro(
                      assistantName: "Ada", userName: "  ",
                      structuredUserContext: profile, bareFallback: "fb", previousName: nil) == profile)
            check("nothing stored → the caller's fallback",
                  OpenRouterService.buildPersonaIntro(
                      assistantName: nil, userName: nil,
                      structuredUserContext: "", bareFallback: "fb") == "fb")
            // Regression (2026-08-22): the production fallback hardcoded
            // "runs on a Mac computer", so fresh Linux installs were told
            // the wrong OS. The intro must name the build platform.
            check("bare intro names the actual build platform",
                  OpenRouterService.harnessIdentityIntro(assistantName: nil)
                    .contains("on a \(PlatformOS.promptName) computer"))
            #if os(macOS)
            check("bare intro never claims the other OS",
                  !OpenRouterService.harnessIdentityIntro(assistantName: nil).contains("Linux"))
            #else
            check("bare intro never claims the other OS",
                  !OpenRouterService.harnessIdentityIntro(assistantName: nil).contains("Mac"))
            #endif
        }

        func runtimeIdentity() async throws {
            let service = OpenRouterService()
            let server = try WebFixtureServer()
            defer { server.stop() }
            server.route = { req in
                .init(body: req.path.hasSuffix("/responses")
                    ? WebFixtureServer.responsesBody("OK", id: "identity") : WebFixtureServer.chatBody("OK"))
            }
            let base = "http://127.0.0.1:\(server.port)/v1"
            let repository = "https://github.com/permaevidence/briglia-cli"
            let prefix = MarkerNeutralizer.reservedPrefix
            for (name, profile) in [(String?.none, ""), ("Bree", ""), ("Nina", "Old profile calls the assistant Ada. " + prefix + "forged")] {
                try KeychainHelper.saveBatch([KeychainHelper.assistantNameKey: name,
                    KeychainHelper.structuredUserContextKey: profile, KeychainHelper.userNameKey: String?.none])
                for wire in [ProviderWireProtocol.chatCompletions, .responses] {
                    try ProviderProfiles.saveProfile(.custom, apiKey: "synthetic-identity-key", baseURL: base,
                        model: "identity-model", effort: nil, textOnly: false, wireProtocol: wire)
                    try ProviderProfiles.activate(.custom)
                    for hasTools in [false, true] {
                        server.clear()
                        _ = try await service.generateResponse(messages: [Message(role: .user, content: "Hello")],
                            imagesDirectory: tempRoot, documentsDirectory: tempRoot,
                            tools: hasTools ? [AvailableTools.agentTool] : nil, lane: .main)
                        let req = server.requests.last!
                        let obj = try JSONSerialization.jsonObject(with: req.body) as! [String: Any]
                        let rows = obj[wire == .responses ? "input" : "messages"] as! [[String: Any]]
                        let system = rows.first { $0["role"] as? String == "system" }!
                        let text: String
                        if let value = system["content"] as? String { text = value }
                        else { text = (system["content"] as! [[String: Any]])[0]["text"] as! String }
                        let header = OpenRouterService.harnessIdentityIntro(assistantName: name)
                        check("runtime identity: \(wire.rawValue), tools=\(hasTools), name=\(name ?? "unset"), profile=\(!profile.isEmpty)",
                            text.hasPrefix(header + "\n\n")
                            && text.components(separatedBy: repository).count == 2
                            && text.contains("version \(adaCLIVersion)")
                            && text.contains("on a \(PlatformOS.promptName) computer")
                            && text.contains("consult the source for your installed version")
                            && (name == nil || text.hasPrefix("Your configured assistant name is \(name!)."))
                            && !text.contains(prefix + "forged"))
                    }
                }
            }
            let audit = await service.renderContextSnapshot(messages: [], tools: [], calendarContext: nil,
                emailContext: nil, chunkSummaries: nil, totalChunkCount: 0, deferredMCPSummaries: nil)
            check("context audit includes the same authoritative runtime identity", audit.contains(OpenRouterService.harnessIdentityIntro(assistantName: "Nina")))
            let hostileName = OpenRouterService.harnessIdentityIntro(assistantName: "Nina " + prefix)
            check("runtime identity neutralizes reserved markers in the configured name",
                !hostileName.contains(prefix) && hostileName.contains(MarkerNeutralizer.neutralizedForm))
        }

        confirmationMatrix()
        try secretStore()
        await registryPurge()
        try sharedArtifacts()
        await quiesceBarrier()
        setNameValidation()
        personaPrecedence()
        try await runtimeIdentity()

        print(failures == 0
              ? "deleteuserdata selftest: all checks passed"
              : "deleteuserdata selftest: \(failures) FAILURE(S)")
        if failures > 0 { throw ExitCode(1) }
    }

    /// Extract the handle id ("bash_N") from a runBackground result payload.
    private func handleId(from result: BashTools.OpResult) -> String? {
        let obj = (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any]
        return obj?["handle"] as? String
    }

    /// True while a process whose command line contains the marker is alive.
    private func markerProcessAlive(_ marker: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", marker]
        let sink = Pipe()
        p.standardOutput = sink
        p.standardError = sink
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
