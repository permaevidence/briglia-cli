import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// L7–L17: one write per checked save, resets, recovery names, file types,
/// legacy purge vs held indices, outside edits, wipe, notices, side readers.
extension RemLoadHarness {
    /// An import-quarantined scripted watcher whose script hash verifies.
    func quarantinedWatcherRow() -> (UUID, [String: Any]) {
        let id = UUID()
        let scripts = dataRoot.appendingPathComponent("reminder-scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("\(id.uuidString).sh")
        let source = "#!/bin/sh\nexit 0\n"
        try? source.write(to: script, atomically: true, encoding: .utf8)
        var reminder = Reminder(id: id, triggerDate: Date().addingTimeInterval(600), prompt: "W",
                                recurrence: .custom(minutes: 5), scriptPath: script.path,
                                scriptSHA256: Self.sha256Hex(Data(source.utf8)))
        reminder.paused = true
        reminder.importQuarantined = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try! JSONSerialization.jsonObject(with: try! encoder.encode(reminder)) as! [String: Any]
        return (id, object)
    }

    func quarantined(_ id: UUID) async -> Bool? {
        await svc._testAllReminders().first { $0.id == id }?.isImportQuarantined
    }

    /// Approval while the store is blocked: exactly one write; pre-rename
    /// failure keeps memory, disk and reply consistent (quarantined); a
    /// failure after the rename keeps the approval that reached disk.
    func rowL7() async {
        await reset()
        let (w, wRow) = quarantinedWatcherRow()
        put(json([wRow, "junk"]))
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        await svc._testInjectPreservationFailure(false)
        await svc._testInjectCheckedSaveFailure(true)
        let before = await svc._testReminderFileWrites()
        let failed = await svc.resumeImportedWatcher(id: w)
        await svc._testInjectCheckedSaveFailure(false)
        if case .success = failed { check("L7 pre-write failure reported", false) } else { check("L7 pre-write failure reported", true) }
        let writesAfter = await svc._testReminderFileWrites()
        check("L7 …memory still quarantined, no write", await quarantined(w) == true && writesAfter == before)
        let writes0 = await svc._testReminderFileWrites()
        let ok = await svc.resumeImportedWatcher(id: w)
        if case .success = ok { check("L7 approval succeeds after recovery", true) } else { check("L7 approval succeeds after recovery", false) }
        check("L7 exactly one reminders.json write for the approval", (await svc._testReminderFileWrites()) - writes0 == 1)
        check("L7 disk holds the approved watcher", diskRows()?.first { $0.id == w }?.isImportQuarantined == false)
        await rowL7PreRename()
        await rowL7PostRename()
    }

    /// Final-writer failure AFTER reconciliation (preservation done, rows
    /// adopted), before the rename: reply, memory and disk all say
    /// quarantined; an immediate reload agrees.
    func rowL7PreRename() async {
        await reset()
        let (w, wRow) = quarantinedWatcherRow()
        let original = json([wRow, "junk"])
        put(original)
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        await svc._testInjectPreservationFailure(false)
        await svc._testInjectPreRenameFailure(true)
        let result = await svc.resumeImportedWatcher(id: w)
        await svc._testInjectPreRenameFailure(false)
        var failed = false
        if case .failure = result { failed = true }
        check("L7 pre-rename (after reconcile): reply says still quarantined", failed)
        check("L7 …memory quarantined, disk untouched, original preserved", await quarantined(w) == true && diskBytes() == original && recovered().count == 1)
        await svc.reloadFromDisk()
        check("L7 …immediate reload agrees (quarantined)", await quarantined(w) == true)
    }

    func rowL7PostRename() async {
        await reset()
        let (w, wRow) = quarantinedWatcherRow()
        put(json([wRow]))
        await svc.reloadFromDisk()
        let writes0 = await svc._testReminderFileWrites()
        await svc._testInjectPostRenameFailure(true)
        let result = await svc.resumeImportedWatcher(id: w)
        await svc._testInjectPostRenameFailure(false)
        var succeeded = false
        if case .success = result { succeeded = true }
        check("L7 post-rename failure: reply says approved (it is on disk)", succeeded)
        let warned = await notices().contains { $0.contains("could not confirm") }
        let replacements = await svc._testReminderFileWrites() - writes0
        check("L7 …durability warning queued, exactly one replacement", warned && replacements == 1)
        check("L7 …memory approved, disk approved", await quarantined(w) == false && diskRows()?.first { $0.id == w }?.isImportQuarantined == false)
        await svc.reloadFromDisk()
        check("L7 …immediate reload agrees", await quarantined(w) == false)
    }

    /// Replace (Mind restore) from a blocked store with pending rows resets
    /// everything, for a valid, a missing and an unreadable file.
    func rowL8() async {
        for kind in ["valid", "missing", "unreadable"] {
            await reset()
            put(json([row("A"), 7]))
            await svc._testInjectPreservationFailure(true)
            await svc.reloadFromDisk()
            _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "pending")
            await svc._testInjectPreservationFailure(false)
            let fresh = UUID()
            try? FileManager.default.removeItem(at: file)
            switch kind {
            case "valid": put(json([row("F", id: fresh)]))
            case "unreadable": try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            default: break
            }
            await svc.reloadFromDisk()
            let ids = await memoryIds()
            let blocked = await svc._testStoreBlockReason() != nil
            switch kind {
            case "valid": check("L8 replace with a valid file: only its rows, unblocked", ids == [fresh] && !blocked)
            case "missing": check("L8 replace with no file: empty, unblocked", ids.isEmpty && !blocked)
            default: check("L8 replace with an unreadable file: empty, blocked", ids.isEmpty && blocked)
            }
        }
    }

    /// Recovery copies never overwrite each other (same second, pre-existing
    /// names); a failed rewrite after preservation + restart keeps them all.
    func rowL9() async {
        await reset()
        let first = json([row("A"), "x1"])
        put(first)
        await svc.reloadFromDisk()
        let second = json([row("B"), "x2"])
        put(second)
        await svc.reloadFromDisk()
        let copies = recovered().compactMap { try? Data(contentsOf: $0) }
        check("L9 two preservations (same second possible) → two distinct exact copies", copies.count == 2 && Set(copies) == [first, second])
        let third = json([row("C"), "x3"])
        put(third)
        chmod(dataRoot.path, 0o500)   // the rewrite after preservation cannot rename into place
        await svc.reloadFromDisk()
        chmod(dataRoot.path, 0o700)
        await svc.reloadFromDisk()      // "restart"
        let after = Set(recovered().compactMap { try? Data(contentsOf: $0) })
        check("L9 earlier copies intact after a failed rewrite + restart", after.isSuperset(of: [first, second]))
        check("L9 the third original survives (on disk or as a copy)", diskBytes() == third || after.contains(third))
    }

    /// File types: absent vs unreadable; FIFO/socket/dangling/cyclic links
    /// are refused without blocking the reader; a link to a regular file is read.
    func rowL10() async {
        let fm = FileManager.default
        await reset()
        check("L10 absent → absent", ReminderStoreFile.read(file) == .absent)
        mkfifo(file.path, 0o600)
        check("L10 FIFO refused without hanging", { if case .unreadable = ReminderStoreFile.read(file) { return true }; return false }())
        try? fm.removeItem(at: file)
        try? fm.createSymbolicLink(atPath: file.path, withDestinationPath: dataRoot.appendingPathComponent("nowhere").path)
        check("L10 dangling link is unreadable, not absent", { if case .unreadable = ReminderStoreFile.read(file) { return true }; return false }())
        try? fm.removeItem(at: file)
        try? fm.createSymbolicLink(atPath: file.path, withDestinationPath: file.path)
        check("L10 cyclic link is unreadable", { if case .unreadable = ReminderStoreFile.read(file) { return true }; return false }())
        try? fm.removeItem(at: file)
        let target = dataRoot.appendingPathComponent("target.json")
        try? json([row("T")]).write(to: target)
        try? fm.createSymbolicLink(atPath: file.path, withDestinationPath: target.path)
        check("L10 link to a regular file is read", { if case .data = ReminderStoreFile.read(file) { return true }; return false }())
        try? fm.removeItem(at: file); try? fm.removeItem(at: target)
        put(json([row("P")]))
        chmod(file.path, 0o000)
        let unreadable: Bool = { if case .unreadable = ReminderStoreFile.read(file) { return true }; return false }()
        chmod(file.path, 0o600)
        // root reads anything (Linux CI runs as root): only assert when the probe could fail.
        if getuid() != 0 {
            check("L10 permission error is unreadable, not absent", unreadable)
            chmod(dataRoot.path, 0o000)     // lstat itself fails (EACCES), not ENOENT
            let parentDenied: Bool = { if case .unreadable = ReminderStoreFile.read(file) { return true }; return false }()
            chmod(dataRoot.path, 0o700)
            check("L10 a failed lstat other than ENOENT is unreadable, not absent", parentDenied)
        }
    }

    /// A legacy triggered row BEFORE an imported watcher, partly damaged
    /// file, preservation failing first: the purge happens at load, so the
    /// approval's held index stays valid through a pre-rename failure.
    func rowL11() async {
        await reset()
        let (w, wRow) = quarantinedWatcherRow()
        let legacy = row("old", triggered: true)
        put(json([legacy, wRow, "junk"]))
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        check("L11 legacy row purged from memory even while blocked", await svc._testAllReminders().map { $0.id } == [w])
        await svc._testInjectPreservationFailure(false)
        // A never-loaded row appears on disk: the recovery merge appends it
        // AFTER W, then the final write fails before the rename.
        let n = UUID()
        put(json([legacy, wRow, "junk", row("N", id: n)]))
        await svc._testInjectPreRenameFailure(true)
        _ = await svc.resumeImportedWatcher(id: w)
        await svc._testInjectPreRenameFailure(false)
        let rows = await svc._testAllReminders()
        check("L11 no crash; W restored to quarantined at its index, neighbour N intact",
              rows.map { $0.id } == [w, n] && rows[0].isImportQuarantined && rows[1].prompt == "N")
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "next")
        let disk = diskRows() ?? []
        check("L11 legacy row not merged back after recovery", !disk.contains { $0.triggered } && disk.contains { $0.id == n })
    }

    /// Edits made outside Briglia are preserved before Briglia overwrites
    /// them; an unchanged file is not copied.
    func rowL12() async {
        await reset()
        put(json([row("A")]))
        await svc.reloadFromDisk()
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "B")
        check("L12 unchanged file → no copy", recovered().isEmpty)
        var edited = (try? JSONSerialization.jsonObject(with: diskBytes() ?? Data()) as? [Any]) ?? []
        let outside = UUID()
        edited.append(row("outside", id: outside))
        let editedBytes = json(edited)
        put(editedBytes)
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "C")
        check("L12 outside edit preserved byte-exact before the write", recovered().compactMap { try? Data(contentsOf: $0) } == [editedBytes])
        check("L12 the outside row joins the list", (diskRows() ?? []).contains { $0.id == outside })
        check("L12 notice says changed outside Briglia", (await notices()).contains { $0.contains("changed outside Briglia") })
    }
}
