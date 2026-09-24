import ArgumentParser
import Foundation

/// Hidden deterministic test of the email/calendar provider system.
/// Pins (a) provider resolution — explicit choice wins, unset falls back to
/// the legacy "gws if installed" inference so pre-provider installs keep
/// working, (b) the manage_calendar tool gate — present ONLY for the
/// agentmail provider, (c) the provider-aware prompt strings (guidance
/// bullet, new-mail envelope hint) so the model is never told to use a CLI
/// it doesn't have, (d) AgentMail wire-format parsing and formatting, and
/// (e) the local calendar store roundtrip including short-id resolution.
/// XDG roots are pointed at a temp directory so the calendar checks never
/// touch real data; provider reads go through the test seams, never the
/// machine's real secrets.json.
struct EmailCalendarSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__emailcal-selftest",
        abstract: "Internal: verify email/calendar provider gating, prompt strings, AgentMail parsing, and the calendar store.",
        shouldDisplay: false
    )

    func run() async throws {
        // Isolate ALL storage before anything touches StoragePaths.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("emailcal-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        defer {
            EmailCalendarProvider.storedOverrideForTesting = nil
            EmailCalendarProvider.gwsInstalledOverrideForTesting = nil
        }

        // 1. Provider resolution.
        EmailCalendarProvider.storedOverrideForTesting = { "agentmail" }
        check("stored 'agentmail' wins", EmailCalendarProvider.current == .agentmail)
        EmailCalendarProvider.storedOverrideForTesting = { "gws" }
        check("stored 'gws' wins", EmailCalendarProvider.current == .gws)
        EmailCalendarProvider.storedOverrideForTesting = { "none" }
        EmailCalendarProvider.gwsInstalledOverrideForTesting = { true }
        check("stored 'none' wins even with gws installed", EmailCalendarProvider.current == .none)
        EmailCalendarProvider.storedOverrideForTesting = { nil }
        EmailCalendarProvider.gwsInstalledOverrideForTesting = { true }
        check("unset + gws installed → legacy gws inference", EmailCalendarProvider.current == .gws)
        EmailCalendarProvider.gwsInstalledOverrideForTesting = { false }
        check("unset + no gws → none (fresh-install default)", EmailCalendarProvider.current == .none)
        EmailCalendarProvider.storedOverrideForTesting = { "imap" }
        check("unknown stored value falls back to inference", EmailCalendarProvider.current == .none)

        // 2. manage_calendar tool gate — present only for agentmail.
        func toolNames() -> [String] {
            AvailableTools.all(includeWebSearch: true).map { $0.function.name }
        }
        EmailCalendarProvider.storedOverrideForTesting = { "agentmail" }
        check("agentmail → manage_calendar in the tool array", toolNames().contains("manage_calendar"))
        EmailCalendarProvider.storedOverrideForTesting = { "gws" }
        check("gws → no manage_calendar tool", !toolNames().contains("manage_calendar"))
        EmailCalendarProvider.storedOverrideForTesting = { "none" }
        EmailCalendarProvider.gwsInstalledOverrideForTesting = { false }
        check("none → no manage_calendar tool", !toolNames().contains("manage_calendar"))

        // With provider none, no serialized schema may reference the email
        // CLIs or the calendar tool (same sweep philosophy as /subagents).
        let encoder = JSONEncoder()
        let noneSchemas = (try? encoder.encode(AvailableTools.all(includeWebSearch: true))).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("none → no schema mentions manage_calendar", !noneSchemas.contains("manage_calendar"))

        // 3. Guidance bullet.
        EmailCalendarProvider.storedOverrideForTesting = { "gws" }
        check("gws bullet names gws",
              EmailCalendarProvider.current.toolGuidanceBullet == "- Use `gws` for Google Workspace actions.")
        EmailCalendarProvider.storedOverrideForTesting = { "agentmail" }
        let amBullet = EmailCalendarProvider.current.toolGuidanceBullet ?? ""
        check("agentmail bullet names the agentmail CLI", amBullet.contains("`agentmail`"))
        check("agentmail bullet names manage_calendar", amBullet.contains("manage_calendar"))
        check("agentmail bullet says the CLI self-authenticates", amBullet.contains("authenticates itself"))
        check("agentmail bullet points at the key broker for raw calls", amBullet.contains("__agentmail-key"))
        EmailCalendarProvider.storedOverrideForTesting = { "none" }
        EmailCalendarProvider.gwsInstalledOverrideForTesting = { false }
        check("none → no guidance bullet at all", EmailCalendarProvider.current.toolGuidanceBullet == nil)

        // 4. New-mail envelope hint.
        EmailCalendarProvider.storedOverrideForTesting = { "gws" }
        check("gws envelope hint teaches gws gmail",
              EmailCalendarProvider.current.emailFollowUpHint.contains("gws gmail +read"))
        EmailCalendarProvider.storedOverrideForTesting = { "agentmail" }
        // Prompt syntax follows the INSTALLED CLI: the pinned 1.x Rust CLI
        // nests resources (`inboxes messages`); a device still on the 0.7.x
        // Go CLI keeps the colon form (`inboxes:messages`). Teaching the
        // wrong one makes every first email action fail (2026-09-04).
        AgentMailService.cliSyntaxOverrideForTesting = .v0Colon
        let legacyHint = EmailCalendarProvider.current.emailFollowUpHint
        check("0.x CLI installed → colon syntax in the envelope hint", legacyHint.contains("agentmail inboxes:messages get"))
        check("0.x CLI installed → colon syntax in the guidance bullet",
              (EmailCalendarProvider.current.toolGuidanceBullet ?? "").contains("agentmail inboxes:messages list"))
        check("syntax map: nil (not installed) → nested (what a fresh install gets)", AgentMailService.cliSyntax(forInstalledVersion: nil) == .v1Nested)
        check("syntax map: legacy unversioned → colon", AgentMailService.cliSyntax(forInstalledVersion: "legacy") == .v0Colon)
        check("syntax map: 0.7.14 → colon", AgentMailService.cliSyntax(forInstalledVersion: "0.7.14") == .v0Colon)
        check("syntax map: 1.3.0 → nested", AgentMailService.cliSyntax(forInstalledVersion: "1.3.0") == .v1Nested)
        check("syntax map: 2.0.0 → nested", AgentMailService.cliSyntax(forInstalledVersion: "2.0.0") == .v1Nested)
        check("version parse: versioned name", AgentMailService.cliVersion(fromTargetBasename: "agentmail-bin-1.3.0-0123456789ab") == "1.3.0")
        check("version parse: legacy name", AgentMailService.cliVersion(fromTargetBasename: "agentmail-bin") == "legacy")
        check("version parse: foreign name → nil", AgentMailService.cliVersion(fromTargetBasename: "agentmail") == nil)
        AgentMailService.cliSyntaxOverrideForTesting = .v1Nested
        let amHint = EmailCalendarProvider.current.emailFollowUpHint
        check("agentmail envelope hint teaches the agentmail CLI (nested 1.x syntax)", amHint.contains("agentmail inboxes messages"))
        check("1.x syntax never emits the colon form", !amHint.contains("inboxes:messages"))
        check("agentmail envelope hint never mentions gws", !amHint.contains("gws"))
        // The installed CLI (v0.7.14+) says `get`, not `retrieve` — teaching a
        // dead subcommand makes the first read of an arrived email fail
        // (Codex, 2026-08-22; verified against the live binary).
        check("envelope hint uses the real `get` subcommand", amHint.contains("inboxes messages get"))
        check("no prompt string teaches the removed `retrieve`",
              !amHint.contains("retrieve") && !(EmailCalendarProvider.current.toolGuidanceBullet ?? "").contains("retrieve"))
        check("guidance bullet uses `get` too",
              (EmailCalendarProvider.current.toolGuidanceBullet ?? "").contains("… get"))

        // 4b. Credential broker: the key never rides in bash environments at
        // all — the installed `agentmail` command is a wrapper that fetches
        // the key itself (via `briglia __agentmail-key`) and execs the real
        // binary, so only the actual AgentMail process sees it (Codex,
        // 2026-08-22: substring matching is not a credential boundary).
        let wrapper = AgentMailService.wrapperScript(
            adaPath: "/home/u/.local/bin/ada",
            realBinaryPath: "/home/u/.local/bin/agentmail-bin")
        check("wrapper is a plain sh script", wrapper.hasPrefix("#!/bin/sh"))
        check("wrapper brokers the key through briglia __agentmail-key",
              wrapper.contains("'/home/u/.local/bin/ada' __agentmail-key"))
        check("wrapper execs the real binary with all arguments",
              wrapper.contains("exec '/home/u/.local/bin/agentmail-bin' \"$@\""))
        check("wrapper respects a caller-provided key",
              wrapper.contains("if [ -z \"${AGENTMAIL_API_KEY:-}\" ]"))
        check("wrapper never embeds the key itself", !wrapper.contains("am_"))

        // 4c. Capped backlogs drain via PERSISTED page cursors — timestamp
        // rewinds cannot step past >cap messages sharing one second (the
        // livelock Codex found). Simulate 120 messages ALL sharing one
        // timestamp, page size 50, one page per tick: three ticks must
        // deliver every message exactly once, carrying the cursor between
        // ticks and completing on the third.
        let sharedTs = "2026-08-22T10:00:00.000Z"
        let backlog = (1...120).map { i in
            AgentMailService.MessageRow(
                messageId: "<b\(i)@x>", threadId: nil, from: "s@x",
                subject: "B\(i)", preview: nil, timestamp: sharedTs, labels: ["unread"])
        }
        // Fake pager: token = start index; afterISO is irrelevant to paging
        // but must be preserved across ticks (cursors continue one query).
        func fakePage(_ afterISO: String, _ token: String?) -> (rows: [AgentMailService.MessageRow], nextPageToken: String?) {
            let start = token.flatMap { Int($0) } ?? 0
            let end = min(start + 50, backlog.count)
            return (Array(backlog[start..<end]), end < backlog.count ? "\(end)" : nil)
        }
        let tick1At = Date(timeIntervalSince1970: 2_000_000)
        var delivered: [String] = []
        var drain: AgentMailService.DrainState?
        var ticks = 0
        var lastCompletedWatermark: Date?
        repeat {
            ticks += 1
            // Each simulated tick happens 300s after the previous one.
            let tickAt = tick1At.addingTimeInterval(Double(ticks - 1) * 300)
            let outcome = await AgentMailService.drainInbox(
                existingDrain: drain, sinceISO: "SINCE-0", pollStartedAt: tickAt, maxPages: 1,
                fetchPage: { a, t in fakePage(a, t) })
            guard let outcome else { break }
            delivered.append(contentsOf: outcome.rows.map { $0.messageId })
            drain = outcome.drain
            lastCompletedWatermark = outcome.completedWatermark
        } while drain != nil && ticks < 10
        check("backlog fully drained in 3 ticks (no livelock)", ticks == 3 && drain == nil)
        check("every message delivered exactly once (incl. the 120th)",
              delivered.count == 120 && Set(delivered).count == 120 && delivered.contains("<b120@x>"))
        // A completing multi-tick drain advances only to the tick that
        // STARTED it — mail arriving during the drain gets re-queried by
        // the next window, regardless of the API's cursor semantics.
        check("multi-tick drain completes to its STARTING tick's watermark",
              lastCompletedWatermark == tick1At)
        // A drain that starts and completes within one tick advances to
        // that tick normally.
        let sameTick = await AgentMailService.drainInbox(
            existingDrain: nil, sinceISO: "S", pollStartedAt: tick1At, maxPages: 5,
            fetchPage: { a, t in fakePage(a, t) })
        check("same-tick drain completes to the current tick",
              sameTick?.drain == nil && sameTick?.completedWatermark == tick1At)
        // Mid-drain the cursor preserves its ORIGINAL query bound.
        let firstTick = await AgentMailService.drainInbox(
            existingDrain: nil, sinceISO: "SINCE-A", pollStartedAt: tick1At, maxPages: 1,
            fetchPage: { a, t in fakePage(a, t) })
        check("cursor records the originating window", firstTick?.drain?.afterISO == "SINCE-A")
        check("cursor records the completion watermark at creation",
              firstTick?.drain?.completionWatermark == tick1At)
        let failed = await AgentMailService.drainInbox(
            existingDrain: nil, sinceISO: "SINCE-A", pollStartedAt: tick1At, maxPages: 1,
            fetchPage: { _, _ in nil })
        check("page failure fails the tick (nil, no bogus progress)", failed == nil)

        // 4g. Poll-state restore gate: fresh state restores (a restart must
        // not abandon a backlog tail or downtime arrivals); stale or
        // future-dated state keeps the anti-flood seed.
        let now = Date(timeIntervalSince1970: 3_000_000)
        check("state from 5 minutes ago restores",
              AgentMailService.shouldRestorePollState(savedAt: now.addingTimeInterval(-300), now: now))
        check("state from 47h ago restores",
              AgentMailService.shouldRestorePollState(savedAt: now.addingTimeInterval(-47 * 3600), now: now))
        check("state from 49h ago is stale (anti-flood seed wins)",
              !AgentMailService.shouldRestorePollState(savedAt: now.addingTimeInterval(-49 * 3600), now: now))
        check("future-dated state refused (clock rollback)",
              !AgentMailService.shouldRestorePollState(savedAt: now.addingTimeInterval(7200), now: now))
        let stateFixture = AgentMailService.PollState(
            watermark: now, drains: ["i@x": .init(afterISO: "A", token: "T", completionWatermark: now)], savedAt: now)
        let stateEncoder = JSONEncoder(); stateEncoder.dateEncodingStrategy = .iso8601
        let stateDecoder = JSONDecoder(); stateDecoder.dateDecodingStrategy = .iso8601
        let roundtripped = (try? stateEncoder.encode(stateFixture)).flatMap { try? stateDecoder.decode(AgentMailService.PollState.self, from: $0) }
        check("poll state roundtrips through JSON", roundtripped == stateFixture)

        // 4h. ~/.local/bin leads the agent-shell PATH even when the
        // inherited PATH already lists it after Homebrew — otherwise a
        // foreign agentmail shadows Briglia's key-broker wrapper.
        let home = NSHomeDirectory()
        check("~/.local/bin moved to the front of an inherited PATH (rest preserved)",
              BashTools.augmentedPath("/opt/homebrew/bin:\(home)/.local/bin:/usr/bin")
              == "\(home)/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin")
        check("missing dirs prepended with ~/.local/bin first",
              BashTools.augmentedPath("/usr/bin:/bin")
              == "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")

        // 4f. Broker detection is content-based: a bare binary named
        // `agentmail` (pre-broker Briglia, npm, brew) must NOT count as
        // installed — it cannot authenticate.
        let binDir = tempRoot.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let realWrapper = binDir.appendingPathComponent("agentmail")
        try AgentMailService.wrapperScript(adaPath: "/x/ada", realBinaryPath: "/x/agentmail-bin")
            .data(using: .utf8)!.write(to: realWrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realWrapper.path)
        check("our wrapper is recognized", AgentMailService.isBrokerWrapper(at: realWrapper))
        let bareBinary = binDir.appendingPathComponent("agentmail-bare")
        try "#!/bin/sh\necho fake agentmail\n".data(using: .utf8)!.write(to: bareBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bareBinary.path)
        check("a bare binary is NOT mistaken for the broker", !AgentMailService.isBrokerWrapper(at: bareBinary))
        let nonExec = binDir.appendingPathComponent("agentmail-noexec")
        try AgentMailService.wrapperScript(adaPath: "/x/ada", realBinaryPath: "/x/agentmail-bin")
            .data(using: .utf8)!.write(to: nonExec)
        check("a non-executable wrapper does not count", !AgentMailService.isBrokerWrapper(at: nonExec))

        // 4e. Arrival envelope is bounded: a paginated burst details at most
        // 20 emails and summarizes the rest, so one poll can never explode a
        // single model turn.
        let burst = (1...30).map { i in
            GoogleWorkspaceService.UnreadEmail(
                id: "<m\(i)@x>", threadId: nil, from: "s\(i)@x", subject: "Subject \(i)",
                date: "2026-08-22 10:0\(i % 10)", snippet: "")
        }
        let envelope = ConversationManager.newEmailsEnvelope(emails: burst, followUpHint: "HINT")
        check("envelope details the first 20", envelope.contains("Subject 20"))
        check("envelope omits the 21st detail", !envelope.contains("Subject 21"))
        check("envelope summarizes the overflow count", envelope.contains("and 10 more new email(s)"))
        let small = ConversationManager.newEmailsEnvelope(emails: Array(burst.prefix(3)), followUpHint: "HINT")
        check("no overflow line when under the cap", !small.contains("more new email(s)"))
        check("envelope carries the provider hint", small.contains("HINT"))

        // 4d. Pagination continuation field decodes (a silent field-name
        // mismatch would disable pagination without any error).
        let pageFixture = #"{"count":1,"limit":1,"messages":[],"next_page_token":"tok-1"}"#
        let pageDecoder = JSONDecoder()
        pageDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = pageFixture.data(using: .utf8).flatMap { try? pageDecoder.decode(AgentMailService.MessagesResponse.self, from: $0) }
        check("next_page_token decodes", page?.nextPageToken == "tok-1")
        let lastPageFixture = #"{"count":1,"limit":1,"messages":[]}"#
        let lastPage = lastPageFixture.data(using: .utf8).flatMap { try? pageDecoder.decode(AgentMailService.MessagesResponse.self, from: $0) }
        check("absent next_page_token decodes as nil (final page)", lastPage != nil && lastPage?.nextPageToken == nil)

        // 5. AgentMail wire-format parsing (fixture mirrors the real
        //    /v0/inboxes/…/messages response, verified live 2026-08-22).
        let fixture = """
        {"message_id":"<abc-123@mail.example>","thread_id":"t-1","from":"Alice <alice@example.com>",
         "subject":"Ciao","preview":"Hello there\\nsecond line","timestamp":"2026-08-22T13:41:07.000Z",
         "labels":["received","unread"]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let data = fixture.data(using: .utf8),
           let row = try? decoder.decode(AgentMailService.MessageRow.self, from: data) {
            let email = AgentMailService.toUnreadEmail(row)
            check("message_id → id", email.id == "<abc-123@mail.example>")
            check("thread_id → threadId", email.threadId == "t-1")
            check("from preserved", email.from == "Alice <alice@example.com>")
            check("subject preserved", email.subject == "Ciao")
            check("preview → snippet (trimmed)", email.snippet == "Hello there\nsecond line")
            check("timestamp parsed to a display date", email.date.hasPrefix("2026-08-22"))
        } else {
            check("AgentMail message fixture decodes", false)
        }
        // Missing optionals degrade gracefully (a bare row must not crash the poll).
        let bareFixture = #"{"message_id":"<x@y>","timestamp":"2026-08-22T13:41:07Z"}"#
        if let data = bareFixture.data(using: .utf8),
           let row = try? decoder.decode(AgentMailService.MessageRow.self, from: data) {
            let email = AgentMailService.toUnreadEmail(row)
            check("bare row → placeholder sender/subject",
                  email.from == "(unknown sender)" && email.subject == "(no subject)")
            check("non-fractional timestamp parses", AgentMailService.parseTimestamp("2026-08-22T13:41:07Z") != nil)
        } else {
            check("bare AgentMail fixture decodes", false)
        }

        // 6. Unread formatting.
        let sample = GoogleWorkspaceService.UnreadEmail(
            id: "<abc-123@mail.example>", threadId: "t-1",
            from: "Alice <alice@example.com>", subject: "Ciao",
            date: "2026-08-22 15:41", snippet: "Hello there")
        let formatted = AgentMailService.formatUnreadEmails([sample])
        check("format contains inbox header", formatted.contains("📧 **Your Inbox**"))
        check("format contains subject + sender", formatted.contains("**Ciao** from Alice <alice@example.com>"))
        check("format teaches agentmail follow-ups", formatted.contains("agentmail inboxes messages"))
        AgentMailService.cliSyntaxOverrideForTesting = nil
        check("no emails → empty context (block omitted)", AgentMailService.formatUnreadEmails([]) == "")

        // 7. Local calendar store roundtrip (isolated XDG root).
        let added = try await CalendarService.shared.addEvent(
            title: "Dentista", datetime: Date().addingTimeInterval(86_400), notes: "portare referto")
        let events = await CalendarService.shared.getEvents(includePast: false)
        check("added event is listed", events.contains { $0.id == added.id })

        let prefix = String(added.id.uuidString.prefix(8))
        let resolved = await CalendarService.shared.resolveEventId(prefix)
        check("8-char prefix resolves to the event", resolved == .success(added.id))
        let resolvedLower = await CalendarService.shared.resolveEventId(prefix.lowercased())
        check("prefix resolution is case-insensitive", resolvedLower == .success(added.id))
        let tooShort = await CalendarService.shared.resolveEventId("abc")
        if case .failure(let message) = tooShort {
            check("short prefix refused with teaching error", message.contains("at least 8"))
        } else {
            check("short prefix refused with teaching error", false)
        }
        let noMatch = await CalendarService.shared.resolveEventId("00000000-dead")
        if case .failure(let message) = noMatch {
            check("unknown prefix → actionable error", message.contains("no event found"))
        } else {
            check("unknown prefix → actionable error", false)
        }

        let updated = try await CalendarService.shared.updateEvent(
            id: added.id, title: "Dentista (spostato)", datetime: nil, notes: nil)
        check("update succeeds", updated)
        let context = await CalendarService.shared.getCalendarContextForSystemPrompt()
        check("context reflects the update (mutation invalidates the day cache)", context.contains("Dentista (spostato)"))

        // Persistence honesty: a failed save must throw AND roll back the
        // in-memory state — a "saved" event that vanishes on restart is worse
        // than an error (Codex, 2026-08-22).
        await CalendarService.shared.setSaveFailureForTesting(true)
        var addThrew = false
        do {
            _ = try await CalendarService.shared.addEvent(title: "Ghost", datetime: Date(), notes: nil)
        } catch {
            addThrew = true
        }
        check("failed save → addEvent throws", addThrew)
        var updateThrew = false
        do {
            _ = try await CalendarService.shared.updateEvent(id: added.id, title: "Ghost2", datetime: nil, notes: nil)
        } catch {
            updateThrew = true
        }
        check("failed save → updateEvent throws", updateThrew)
        await CalendarService.shared.setSaveFailureForTesting(false)
        let afterFailure = await CalendarService.shared.getEvents(includePast: true)
        check("failed add rolled back (no Ghost event)", !afterFailure.contains { $0.title == "Ghost" })
        check("failed update rolled back (title unchanged)",
              afterFailure.first { $0.id == added.id }?.title == "Dentista (spostato)")

        let deleted = try await CalendarService.shared.deleteEvent(id: added.id)
        check("delete succeeds", deleted)
        let afterDelete = await CalendarService.shared.getEvents(includePast: true)
        check("store empty after delete", !afterDelete.contains { $0.id == added.id })

        // 9. Wipe/poll concurrency (Codex round 7): the actor is reentrant,
        // so a poll tick suspended at an await can resume AFTER resetForWipe()
        // cleared state. The generation token must make such a tick discard
        // everything — no delivery, no watermark, no recreated checkpoint
        // file. Gates park the tick at a chosen suspension point while the
        // wipe runs, then release it.
        let raceEmail = GoogleWorkspaceService.UnreadEmail(
            id: "race-msg-1", threadId: nil, from: "codex@example.com",
            subject: "race probe", date: "2026-08-22 13:00", snippet: "boo")
        let stateURL = AgentMailService.pollStateURLForTesting
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        func awaitParked(_ gate: RaceGate) async -> Bool {
            for _ in 0..<400 {  // ≤2s — deterministic, just yields to the tick
                if await gate.hasWaiter() { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }

        // 9a. Tick suspended IN THE FETCH when the wipe lands.
        do {
            let svc = AgentMailService()
            await svc.seedWatermarkForTesting(Date(timeIntervalSinceNow: -3600))
            let gen = await svc.currentGenerationForTesting()
            let gate = RaceGate()
            let delivered = RaceCounter()
            let tick = Task {
                await svc.pollTick(
                    generation: gen,
                    fetch: { _, _ in
                        await gate.wait()
                        return AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: Date())
                    },
                    handler: { _ in await delivered.increment(); return true })
            }
            check("race(fetch): tick reached its suspension point", await awaitParked(gate))
            await svc.resetForWipe()
            await gate.open()
            await tick.value
            check("race(fetch): pre-wipe mail never delivered", await delivered.value() == 0)
            check("race(fetch): watermark stays cleared", await svc.watermarkForTesting() == nil)
            check("race(fetch): checkpoint file not recreated",
                  !FileManager.default.fileExists(atPath: stateURL.path))
        }

        // 9b. Tick suspended IN THE HANDLER when the wipe lands. The wipe
        // call site quiesces the poller BEFORE clearing the ambient buffers
        // (and processNewUnreadEmails refuses outright during the restore
        // gate — pinned in section 10), so a handler suspended here cannot
        // leave side effects behind; this check pins the poller half: the
        // tick's checkpoint must not advance post-wipe state.
        do {
            let svc = AgentMailService()
            await svc.seedWatermarkForTesting(Date(timeIntervalSinceNow: -3600))
            let gen = await svc.currentGenerationForTesting()
            let gate = RaceGate()
            let tick = Task {
                await svc.pollTick(
                    generation: gen,
                    fetch: { _, _ in
                        AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: Date())
                    },
                    handler: { _ in
                        await gate.wait()
                        return true
                    })
            }
            check("race(handler): tick reached its suspension point", await awaitParked(gate))
            await svc.resetForWipe()
            await gate.open()
            await tick.value
            check("race(handler): watermark stays cleared", await svc.watermarkForTesting() == nil)
            check("race(handler): checkpoint file not recreated",
                  !FileManager.default.fileExists(atPath: stateURL.path))
        }

        // 9c. Stale generation at tick ENTRY (a lingering loop after
        // stopBackgroundPoll) is a complete no-op.
        do {
            let svc = AgentMailService()
            await svc.seedWatermarkForTesting(nil)
            let gen = await svc.currentGenerationForTesting()
            await svc.stopBackgroundPoll()  // bumps the generation
            let delivered = RaceCounter()
            await svc.pollTick(
                generation: gen,
                fetch: { _, _ in
                    AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: Date())
                },
                handler: { _ in await delivered.increment(); return true })
            check("stale generation at entry: nothing fetched or delivered", await delivered.value() == 0)
            check("stale generation at entry: no checkpoint", await svc.watermarkForTesting() == nil)
        }

        // 9d. Non-durable delivery holds the checkpoint (round 6's contract,
        // previously untested): handler=false → watermark and file untouched.
        do {
            let svc = AgentMailService()
            let seeded = Date(timeIntervalSinceNow: -3600)
            await svc.seedWatermarkForTesting(seeded)
            let gen = await svc.currentGenerationForTesting()
            await svc.pollTick(
                generation: gen,
                fetch: { _, _ in
                    AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: Date())
                },
                handler: { _ in false })
            check("non-durable delivery: watermark held", await svc.watermarkForTesting() == seeded)
            check("non-durable delivery: no checkpoint file",
                  !FileManager.default.fileExists(atPath: stateURL.path))
        }

        // 9e. Sanity: an un-raced durable tick still advances and persists —
        // the guards must not have broken the normal commit path.
        do {
            let svc = AgentMailService()
            await svc.seedWatermarkForTesting(Date(timeIntervalSinceNow: -3600))
            let gen = await svc.currentGenerationForTesting()
            let advance = Date()
            await svc.pollTick(
                generation: gen,
                fetch: { _, _ in
                    AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: advance)
                },
                handler: { _ in true })
            check("un-raced tick: watermark advances", await svc.watermarkForTesting() == advance)
            check("un-raced tick: checkpoint persisted",
                  FileManager.default.fileExists(atPath: stateURL.path))
            try? FileManager.default.removeItem(at: stateURL)
        }

        // 9f. resetForWipe's timeout is a REAL bound (Codex round 8: the
        // previous task-group race waited for the poller anyway, because
        // leaving a task group awaits all children). A tick parked
        // indefinitely must make resetForWipe return false near its
        // deadline, not hang until the tick finishes.
        do {
            let svc = AgentMailService()
            await svc.seedWatermarkForTesting(Date(timeIntervalSinceNow: -3600))
            let gen = await svc.currentGenerationForTesting()
            let gate = RaceGate()
            let tick = Task {
                await svc.pollTick(
                    generation: gen,
                    fetch: { _, _ in
                        await gate.wait()  // parked until AFTER the reset returns
                        return AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: Date())
                    },
                    handler: { _ in true })
            }
            check("timeout: tick reached its suspension point", await awaitParked(gate))
            check("timeout: tick counted in flight", await svc.ticksInFlightForTesting() == 1)
            let began = Date()
            let quiesced = await svc.resetForWipe(timeoutSeconds: 0.3)
            let elapsed = Date().timeIntervalSince(began)
            check("timeout: reports NOT quiesced", quiesced == false)
            check("timeout: returned near the deadline, not when the tick ended",
                  elapsed < 5, "elapsed \(elapsed)s")
            await gate.open()
            await tick.value
            check("timeout: released tick discards (watermark stays cleared)",
                  await svc.watermarkForTesting() == nil)
            check("timeout: counter returns to zero", await svc.ticksInFlightForTesting() == 0)
            check("timeout: a later reset with no tick reports quiesced",
                  await svc.resetForWipe(timeoutSeconds: 0.3))
        }

        // 9g. A tick that finishes during the quiescence wait → true.
        do {
            let svc = AgentMailService()
            await svc.seedWatermarkForTesting(Date(timeIntervalSinceNow: -3600))
            let gen = await svc.currentGenerationForTesting()
            let gate = RaceGate()
            let tick = Task {
                await svc.pollTick(
                    generation: gen,
                    fetch: { _, _ in
                        await gate.wait()
                        return AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: Date())
                    },
                    handler: { _ in true })
            }
            check("quiesce: tick reached its suspension point", await awaitParked(gate))
            let reset = Task { await svc.resetForWipe(timeoutSeconds: 5) }
            await gate.open()
            await tick.value
            check("quiesce: reset reports genuine quiescence", await reset.value)
            check("quiesce: counter is zero", await svc.ticksInFlightForTesting() == 0)
        }

        // 9h. Recovery after a timed-out reset (Codex round 9): an aborted
        // wipe restarts the poller, so the service must remain fully
        // operational for a FRESH generation even while the stuck tick is
        // still in flight — only stale generations are refused. The abort
        // path in deleteAllMemory calls startBackgroundPoll, which mints a
        // fresh generation exactly like the one simulated here.
        do {
            let svc = AgentMailService()
            await svc.seedWatermarkForTesting(Date(timeIntervalSinceNow: -3600))
            let stuckGen = await svc.currentGenerationForTesting()
            let gate = RaceGate()
            let stuck = Task {
                await svc.pollTick(
                    generation: stuckGen,
                    fetch: { _, _ in
                        await gate.wait()
                        return AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: Date())
                    },
                    handler: { _ in true })
            }
            check("recovery: stuck tick parked", await awaitParked(gate))
            check("recovery: reset times out (not quiesced)",
                  await svc.resetForWipe(timeoutSeconds: 0.3) == false)
            // The restarted loop's tick, under the CURRENT (post-reset)
            // generation, with the stuck tick still parked in flight:
            let newGen = await svc.currentGenerationForTesting()
            await svc.seedWatermarkForTesting(Date(timeIntervalSinceNow: -1800))
            let delivered = RaceCounter()
            let advance = Date()
            await svc.pollTick(
                generation: newGen,
                fetch: { _, _ in
                    AgentMailService.ArrivalFetchResult(emails: [raceEmail], advanceTo: advance)
                },
                handler: { _ in await delivered.increment(); return true })
            check("recovery: fresh-generation tick delivers", await delivered.value() == 1)
            check("recovery: fresh-generation tick commits its watermark",
                  await svc.watermarkForTesting() == advance)
            check("recovery: checkpoint persists again",
                  FileManager.default.fileExists(atPath: stateURL.path))
            try? FileManager.default.removeItem(at: stateURL)
            // The stuck tick finally resumes — and still discards everything.
            await gate.open()
            await stuck.value
            check("recovery: late stuck tick still discarded (watermark intact)",
                  await svc.watermarkForTesting() == advance)
            check("recovery: no stray checkpoint from the stuck tick",
                  !FileManager.default.fileExists(atPath: stateURL.path))
        }

        // 9i. Durable baseline (Codex round 10), via the REAL lifecycle
        // methods: with no pre-existing checkpoint, startBackgroundPoll must
        // persist its anti-flood seed immediately — otherwise a reset +
        // restart before the first successful poll (the wipe's timeout-abort
        // recovery) re-seeds to a later "now" and mail arriving in between
        // silently loses its notification. Uses a dummy key in the
        // XDG-isolated secret store; the poller's first network attempt is
        // 300s away, so nothing leaves the process in test time.
        do {
            try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "am_selftest_dummy")
            let svc = AgentMailService()
            check("baseline: no pre-existing checkpoint",
                  !FileManager.default.fileExists(atPath: stateURL.path))
            await svc.startBackgroundPoll()
            check("baseline: anti-flood seed persisted at start",
                  FileManager.default.fileExists(atPath: stateURL.path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = (try? Data(contentsOf: stateURL))
                .flatMap { try? decoder.decode(AgentMailService.PollState.self, from: $0) }
            check("baseline: persisted watermark is the seed (≈now)",
                  persisted.map { abs($0.watermark.timeIntervalSinceNow) < 10 } ?? false)
            check("baseline: reset with no tick in flight quiesces",
                  await svc.resetForWipe(timeoutSeconds: 0.3))
            // Distinguishable restore proof: overwrite the checkpoint with a
            // 30-min-old watermark. If the restart RESTORED, the watermark is
            // 30 min old; if it re-seeded, it would be ≈now.
            let crafted = AgentMailService.PollState(
                watermark: Date(timeIntervalSinceNow: -1800),
                drains: [:],
                savedAt: Date(timeIntervalSinceNow: -600),
                account: AgentMailService.currentAccountFingerprint())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try (try encoder.encode(crafted)).write(to: stateURL, options: [.atomic])
            await svc.startBackgroundPoll()  // the abort path's restart
            let restored = await svc.watermarkForTesting()
            check("baseline: restart restores the durable baseline, not a later now",
                  restored.map { abs($0.timeIntervalSince(crafted.watermark)) < 2 } ?? false)
            // Round 11: a restore must NOT rewrite the checkpoint — refreshing
            // savedAt on every restart would keep a never-advancing watermark
            // restore-eligible forever, defeating the 48h anti-flood gate.
            let afterRestore = (try? Data(contentsOf: stateURL))
                .flatMap { try? decoder.decode(AgentMailService.PollState.self, from: $0) }
            check("baseline: restore leaves the checkpoint's savedAt untouched",
                  afterRestore.map { abs($0.savedAt.timeIntervalSince(crafted.savedAt)) < 2 } ?? false)
            await svc.stopBackgroundPoll()

            // …while a STALE checkpoint (>48h) is refused and REPLACED by a
            // freshly persisted anti-flood seed.
            let stale = AgentMailService.PollState(
                watermark: Date(timeIntervalSinceNow: -60 * 3600),
                drains: [:],
                savedAt: Date(timeIntervalSinceNow: -49 * 3600))
            try (try encoder.encode(stale)).write(to: stateURL, options: [.atomic])
            await svc.startBackgroundPoll()
            let reseeded = await svc.watermarkForTesting()
            check("baseline: stale checkpoint refused (watermark re-seeds to ≈now)",
                  reseeded.map { abs($0.timeIntervalSinceNow) < 10 } ?? false)
            let afterStale = (try? Data(contentsOf: stateURL))
                .flatMap { try? decoder.decode(AgentMailService.PollState.self, from: $0) }
            check("baseline: stale checkpoint replaced by a fresh durable seed",
                  afterStale.map { abs($0.savedAt.timeIntervalSinceNow) < 10 && abs($0.watermark.timeIntervalSinceNow) < 10 } ?? false)
            await svc.stopBackgroundPoll()
            try? FileManager.default.removeItem(at: stateURL)
            try? KeychainHelper.delete(key: KeychainHelper.agentMailApiKeyKey)
        }

        // 10. Email delivery routing (Codex round 8): a handler suspended
        // across the wipe's buffer clears re-enters the main actor mid-wipe;
        // the route matrix must refuse — NOT durable, no history append, no
        // turn — whenever the Mind restore gate is up, regardless of every
        // other flag.
        typealias Route = ConversationManager.EmailDeliveryRoute
        for providerActive in [true, false] {
            for hasChannel in [true, false] {
                for count in [0, 3] {
                    for turnActive in [true, false] {
                        let route = ConversationManager.emailDeliveryRoute(
                            isRestoringMind: true, providerActive: providerActive,
                            hasReplyChannel: hasChannel,
                            emailCount: count, turnActive: turnActive)
                        if route != .refuseNotDurable {
                            check("restore gate refuses (provider=\(providerActive) channel=\(hasChannel) count=\(count) active=\(turnActive))", false)
                        }
                    }
                }
            }
        }
        check("restore gate refuses in every configuration", true)
        // Provider none (e.g. a tick suspended across a wipe that reset the
        // provider): never surfaces, regardless of channel/turn state.
        for hasChannel in [true, false] {
            for turnActive in [true, false] {
                let route = ConversationManager.emailDeliveryRoute(
                    isRestoringMind: false, providerActive: false,
                    hasReplyChannel: hasChannel, emailCount: 3, turnActive: turnActive)
                if route != .nothingToDeliver {
                    check("provider none never delivers (channel=\(hasChannel) active=\(turnActive))", false)
                }
            }
        }
        check("provider none never delivers", true)
        check("no channel → checkpoint may advance (nothing to deliver)",
              ConversationManager.emailDeliveryRoute(
                isRestoringMind: false, providerActive: true, hasReplyChannel: false, emailCount: 3, turnActive: false) == Route.nothingToDeliver)
        check("empty batch → nothing to deliver",
              ConversationManager.emailDeliveryRoute(
                isRestoringMind: false, providerActive: true, hasReplyChannel: true, emailCount: 0, turnActive: false) == Route.nothingToDeliver)
        check("active turn → ambient queue",
              ConversationManager.emailDeliveryRoute(
                isRestoringMind: false, providerActive: true, hasReplyChannel: true, emailCount: 3, turnActive: true) == Route.deferToAmbientQueue)
        check("idle → start turn",
              ConversationManager.emailDeliveryRoute(
                isRestoringMind: false, providerActive: true, hasReplyChannel: true, emailCount: 3, turnActive: false) == Route.startTurn)

        // 11. Email-credential wipe (/deleteuserdata must sever email access,
        // not just local memory — user decision 2026-08-22). Isolated secret
        // store + a temp stand-in for ~/.config/gws.
        do {
            try KeychainHelper.save(key: KeychainHelper.agentMailApiKeyKey, value: "am_wipe_dummy")
            try KeychainHelper.save(key: KeychainHelper.agentMailInboxAddressKey, value: "x@agentmail.to")
            try KeychainHelper.save(key: KeychainHelper.gwsOAuthClientIDKey, value: "cid.apps.googleusercontent.com")
            try KeychainHelper.save(key: KeychainHelper.gwsOAuthClientSecretKey, value: "GOCSPX-dummy")
            try KeychainHelper.save(key: KeychainHelper.emailCalendarProviderKey, value: "agentmail")
            try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "unrelated-survives")
            let fakeGws = tempRoot.appendingPathComponent("fake-gws-config", isDirectory: true)
            try FileManager.default.createDirectory(at: fakeGws, withIntermediateDirectories: true)
            try "tokens".write(to: fakeGws.appendingPathComponent("credentials.json"), atomically: true, encoding: .utf8)

            let wipeFailures = EmailCredentialWipe.execute(gwsConfigDir: fakeGws)
            check("credential wipe reports no failures", wipeFailures.isEmpty,
                  wipeFailures.joined(separator: "; "))
            check("AgentMail key deleted", KeychainHelper.load(key: KeychainHelper.agentMailApiKeyKey) == nil)
            check("AgentMail inbox address deleted", KeychainHelper.load(key: KeychainHelper.agentMailInboxAddressKey) == nil)
            check("gws OAuth client id deleted", KeychainHelper.load(key: KeychainHelper.gwsOAuthClientIDKey) == nil)
            check("gws OAuth client secret deleted", KeychainHelper.load(key: KeychainHelper.gwsOAuthClientSecretKey) == nil)
            check("provider reset to explicit none (inference can't resurrect gws)",
                  KeychainHelper.load(key: KeychainHelper.emailCalendarProviderKey) == "none")
            check("gws config/token directory removed",
                  !FileManager.default.fileExists(atPath: fakeGws.path))
            check("unrelated key survives the credential wipe",
                  KeychainHelper.load(key: KeychainHelper.serperApiKeyKey) == "unrelated-survives")
            // Idempotent: a second wipe on the already-clean state is silent.
            check("credential wipe is idempotent",
                  EmailCredentialWipe.execute(gwsConfigDir: fakeGws).isEmpty)
            try? KeychainHelper.delete(key: KeychainHelper.serperApiKeyKey)
            try? KeychainHelper.delete(key: KeychainHelper.emailCalendarProviderKey)
        }

        // 12. Pre-wipe warning honesty (Codex, 2026-08-22): the confirmation
        // text must disclose the irreversible email-credential removals
        // BEFORE showing the token — it previously still promised "Kept:
        // API keys" while the confirmed wipe deleted them.
        do {
            let warning = ConversationManager.deleteUserDataWarningText(token: "Sofia")
            check("warning names the AgentMail API key", warning.contains("AgentMail API key"))
            check("warning names the gws OAuth client + token store",
                  warning.contains("gws OAuth client + token store"))
            check("warning discloses the gws logout", warning.contains("logged out of Google"))
            check("warning no longer promises bare 'API keys' kept",
                  !warning.contains("Kept: API keys"))
            check("warning says OTHER API keys are kept", warning.contains("Kept: other API keys"))
            check("warning notes server-side mailboxes are untouched",
                  warning.contains("server-side mailboxes are untouched"))
            check("warning ends with the confirmation token", warning.contains("/deleteuserdata Sofia"))
            check("warning says it cannot be undone", warning.contains("cannot be undone"))
        }

        // 13. gws wipe quiescence (Codex, 2026-08-22): gws subprocesses
        // ignore Swift task cancellation, so resetForWipe must wait for the
        // whole in-flight OPERATION (retry ladders included) — counter-based,
        // deadline-bounded, reporting false when quiescence wasn't reached
        // so the wipe aborts before deleting ~/.config/gws.
        do {
            let svc = GoogleWorkspaceService()
            let gate = RaceGate()
            let op = Task { await svc.performTrackedOpForTesting { await gate.wait() } }
            check("gws quiesce: op reached its suspension point", await awaitParked(gate))
            check("gws quiesce: op counted in flight", await svc.opsInFlightForTesting() == 1)
            let began = Date()
            let quiesced = await svc.resetForWipe(timeoutSeconds: 0.3)
            check("gws quiesce: stuck op → NOT quiesced", quiesced == false)
            check("gws quiesce: returned near the deadline",
                  Date().timeIntervalSince(began) < 5)
            await gate.open()
            await op.value
            check("gws quiesce: counter returns to zero", await svc.opsInFlightForTesting() == 0)
            check("gws quiesce: reset with no op in flight quiesces",
                  await svc.resetForWipe(timeoutSeconds: 0.3))
        }

        print(failures == 0 ? "\nAll email/calendar checks passed." : "\n\(failures) email/calendar check(s) FAILED.")
        if failures > 0 { throw ExitCode(1) }
    }
}

/// Async gate for the wipe/poll race checks: parks a poll tick at a chosen
/// suspension point until the test releases it.
private actor RaceGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func hasWaiter() -> Bool { !waiters.isEmpty }
}

private actor RaceCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}
