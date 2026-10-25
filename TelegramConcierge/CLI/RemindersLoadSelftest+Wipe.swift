import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// L13–L17: wipe, notices, side readers, strict Mind import, duplicate ids.
extension RemLoadHarness {
    /// Wipe while blocked writes [] (no merge, no copy); a failed [] write
    /// followed by a save never brings the old rows back.
    func rowL13() async {
        await reset()
        put(json([row("A"), "junk"]))
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        await svc._testInjectPreservationFailure(false)
        await svc.clearAllReminders()
        check("L13 wipe while blocked → [] and no recovery copy", diskRows()?.isEmpty == true && recovered().isEmpty)

        await reset()
        let old = json([row("A"), row("B")])
        put(old)
        await svc.reloadFromDisk()
        chmod(dataRoot.path, 0o500)        // the [] write cannot rename into place
        await svc.clearAllReminders()
        chmod(dataRoot.path, 0o700)
        let failedWrite = diskBytes() == old
        // The file then changes outside Briglia (hash differs): the wiped rows
        // must still be neither merged back nor copied aside.
        var edited = (try? JSONSerialization.jsonObject(with: old) as? [Any]) ?? []
        edited.append(row("outside-after-wipe"))
        if failedWrite { put(json(edited)) }
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "after")
        let rows = diskRows() ?? []
        if getuid() != 0 || !failedWrite {
            check("L13 failed [] write then a save: old rows do not return", rows.count == 1 && rows[0].prompt == "after")
            check("L13 …and the wiped rows are not copied aside", recovered().isEmpty)
        }
        await rowL13Recovery()
    }

    /// /deleteuserdata step 12 helper: removes every recovery copy, reports
    /// listing and per-file failures.
    func rowL13Recovery() async {
        await reset()
        put(json([row("A"), "junk"]))
        await svc.reloadFromDisk()
        check("L13 recovery copies exist before the wipe", recovery().count == 2)
        if getuid() != 0 {
            chmod(dataRoot.path, 0o500)
            let failures = ReminderService.removeRecoveryFilesForWipe(in: dataRoot)
            chmod(dataRoot.path, 0o700)
            check("L13 per-file removal failures are reported", failures.count == 2)
        }
        check("L13 wipe helper removes them", ReminderService.removeRecoveryFilesForWipe(in: dataRoot).isEmpty && recovery().isEmpty)
        check("L13 unlistable folder is reported", ReminderService.removeRecoveryFilesForWipe(in: file).count == 1)
        let absent = dataRoot.appendingPathComponent("no-such-folder")
        check("L13 absent folder: nothing to report", ReminderService.removeRecoveryFilesForWipe(in: absent).isEmpty)
        if getuid() != 0 {
            // Unsearchable ancestor: fileExists is false, but this is not absence.
            let parent = dataRoot.appendingPathComponent("l13-parent", isDirectory: true)
            let inner = parent.appendingPathComponent("data", isDirectory: true)
            try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: inner.appendingPathComponent("reminders.recovered-probe.json"))
            chmod(parent.path, 0o000)
            let reported = ReminderService.removeRecoveryFilesForWipe(in: inner)
            chmod(parent.path, 0o700)
            try? FileManager.default.removeItem(at: parent)
            check("L13 unsearchable ancestor is reported, not treated as absent", reported.count == 1)
        }
    }

    /// Notices are loaded before reminders; a load notice is persisted (the
    /// bytes a restart would read — no real process restart here).
    func rowL14() async {
        await reset()
        put(json([row("A"), "junk"]))
        await svc.reloadFromDisk()
        let notices = dataRoot.appendingPathComponent("reminder-notices.json")
        let saved = (try? Data(contentsOf: notices)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        check("L14 load notice persisted to reminder-notices.json", saved.contains { $0.contains("could not be read") })
    }

    /// One blocked notice per blocked episode, however many saves fail.
    func rowL14b() async {
        await reset()
        put(json([row("A"), "junk"]))
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        for i in 0..<3 { _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "p\(i)") }
        let blockedNotices = await notices().filter { $0.contains("kept in memory only") }
        await svc._testInjectPreservationFailure(false)
        check("L14 blocked episode → exactly one notice", blockedNotices.count == 1, "\(blockedNotices.count)")
    }

    /// Side readers (`briglia trigger`, registry hydration) see valid rows
    /// beside a bad one; never write.
    func rowL15() async {
        await reset()
        let a = UUID()
        let bytes = json([row("A", id: a), "junk"])
        put(bytes)
        let rows = ReminderStoreFile.readValidEntries(at: file)
        check("L15 side reader sees the valid row", rows?.map { $0.id } == [a])
        check("L15 side reader wrote nothing", diskBytes() == bytes && recovered().isEmpty)
    }

    /// Mind import stays strict: a staged reminders.json that does not decode
    /// as a whole is refused before anything changes.
    func rowL16() async {
        await reset()
        put(json([row("live")]))
        await svc.reloadFromDisk()
        let staged = dataRoot.deletingLastPathComponent().appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try? json([row("S"), "junk"]).write(to: staged.appendingPathComponent("reminders.json"))
        var refused = false
        do { _ = try ReminderService.prepareStagedReminders(stagedRoot: staged) } catch { refused = true }
        try? FileManager.default.removeItem(at: staged)
        let live = await svc._testAllReminders().map { $0.prompt }
        check("L16 damaged staged archive refused; live store untouched", refused && live == ["live"])
    }

    func rowL17() async {
        await reset()
        let id = UUID()
        put(json([row("one", id: id), row("two", id: id)]))
        await svc.reloadFromDisk()
        check("L17 duplicate ids load without trapping (as before)", await svc._testAllReminders().count == 2)
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "x")
        check("L17 …and save", diskRows()?.count == 3)
    }
}
