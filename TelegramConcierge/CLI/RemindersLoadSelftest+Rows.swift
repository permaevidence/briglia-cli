import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// L1–L6: per-entry load, whole-file preservation, the blocked store.
extension RemLoadHarness {
    /// The v0.2.62 loader, verbatim: one `decode([Reminder].self)`.
    func legacyLoadCount(_ data: Data) -> Int {
        (try? ReminderStoreFile.makeDecoder().decode([Reminder].self, from: data))?.count ?? 0
    }

    func rowL1() async {
        await reset()
        let a = UUID(), b = UUID()
        let original = json([row("A", id: a), ["id": "not-a-uuid", "prompt": 3], row("B", id: b)])
        put(original)
        await svc.reloadFromDisk()
        check("L1 v0.2.62 loader on this file loads 0 (characterisation)", legacyLoadCount(original) == 0)
        check("L1 the two valid reminders load", await memoryIds() == [a, b])
        let copies = recovered()
        check("L1 exact original copy, one file", copies.count == 1 && (try? Data(contentsOf: copies[0])) == original)
        check("L1 copy is 0600", copies.first.map { mode($0) == 0o600 } ?? false)
        let lists = rejectedLists()
        let listText = lists.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check("L1 rejected list holds the bad entry", lists.count == 1 && listText.contains("not-a-uuid"))
        check("L1 reminders.json rewritten without it", Set(diskRows()?.map { $0.id } ?? []) == [a, b])
        let n = await notices()
        check("L1 one notice naming the copy", n.count == 1 && n[0].contains(copies.first?.path ?? "?") && n[0].contains("other 2 loaded"))
    }

    func rowL2to4() async {
        let cases: [(String, Data)] = [
            ("L2 non-array {}", Data("{}".utf8)),
            ("L3 truncated", Data(json([row("A"), row("B")]).prefix(40))),
            ("L4 not JSON", Data("reminders: oops".utf8)),
        ]
        for (label, original) in cases {
            await reset()
            put(original)
            await svc.reloadFromDisk()
            let copies = recovered()
            check("\(label): nothing loads", await memoryIds().isEmpty)
            check("\(label): original preserved byte-exact", copies.count == 1 && (try? Data(contentsOf: copies[0])) == original)
            check("\(label): reminders.json is now []", diskRows()?.isEmpty == true)
            let blocked = await svc._testStoreBlockReason()
            let first = await notices().first
            check("\(label): not blocked, notice queued", blocked == nil && first?.contains("not a valid reminder list") == true)
        }
    }

    func rowL5() async {
        await reset()
        let a = UUID()
        put(json([NSNull(), "s", 3, true, [1, 2], ["id": "bad"], row("A", id: a)]))
        await svc.reloadFromDisk()
        check("L5 the one valid row loads beside scalars/null/arrays/bad objects", await memoryIds() == [a])
        let list = rejectedLists().first.flatMap { try? Data(contentsOf: $0) }
        let parsed = list.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
        check("L5 rejected list has all six", parsed?.count == 6)
    }

    /// Preservation fails: blocked, file untouched; delete a loaded row while
    /// blocked; recover — the deleted row never comes back.
    func rowL6a() async {
        await reset()
        let a = UUID(), b = UUID()
        let original = json([row("A", id: a), row("B", id: b), ["id": 1]])
        put(original)
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        let blockedNow = await svc._testStoreBlockReason()
        check("L6a preservation failed → valid rows active, store blocked", await memoryIds() == [a, b] && blockedNow != nil)
        check("L6a no copy, file untouched", recovered().isEmpty && diskBytes() == original)
        _ = await svc.deleteReminder(id: a)
        check("L6a delete while blocked: file still untouched", diskBytes() == original)
        await svc._testInjectPreservationFailure(false)
        let c = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "C").id
        let disk = Set(diskRows()?.map { $0.id } ?? [])
        let mem = await memoryIds()
        check("L6a recovery: deleted A not resurrected, B and C saved", disk == [b, c] && mem == [b, c])
        check("L6a recovery copy is the exact original", recovered().count == 1 && (try? Data(contentsOf: recovered()[0])) == original)
        await svc.reloadFromDisk()
        check("L6a after reload: still B and C", await memoryIds() == [b, c])
    }

    /// Unreadable at start (a directory): blocked; rows created meanwhile
    /// survive; a genuinely never-loaded disk row merges; same id → memory wins.
    func rowL6b() async {
        await reset()
        try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await svc.reloadFromDisk()
        check("L6b directory at the path → blocked", await svc._testStoreBlockReason() != nil)
        let c = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "C-memory").id
        var isDir: ObjCBool = false
        check("L6b save while blocked leaves the directory", FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) && isDir.boolValue)
        try? FileManager.default.removeItem(at: file)
        let d = UUID()
        put(json([row("D", id: d), row("C-disk", id: c)]))
        let e = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "E").id
        let rows = diskRows() ?? []
        check("L6b merge: C, E from memory + never-loaded D", Set(rows.map { $0.id }) == [c, d, e])
        check("L6b same id: memory's C wins", rows.first { $0.id == c }?.prompt == "C-memory")
        check("L6b block cleared", await svc._testStoreBlockReason() == nil)
    }

    /// Repeated failures keep memory-only rows and removals.
    func rowL6c() async {
        await reset()
        let a = UUID()
        let original = json([row("A", id: a), "junk"])
        put(original)
        await svc._testInjectPreservationFailure(true)
        await svc.reloadFromDisk()
        let x = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "X").id
        let y = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "Y").id
        _ = await svc.deleteReminder(id: x)
        check("L6c three failed saves left the file untouched", diskBytes() == original)
        await svc._testInjectPreservationFailure(false)
        let z = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "Z").id
        check("L6c recovery keeps A, Y, Z; X stays deleted", Set(diskRows()?.map { $0.id } ?? []) == [a, y, z])
    }

    /// Ordinary save whose write lands then throws (Codex R2-1/R2-2): the
    /// write counts as committed; a later delete is not undone by a merge.
    func rowL6d() async {
        await reset()
        put(json([] as [Any]))
        await svc.reloadFromDisk()
        await svc._testInjectPostRenameFailure(true)
        let c = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "C").id
        await svc._testInjectPostRenameFailure(false)
        check("L6d write landed despite the error", Set(diskRows()?.map { $0.id } ?? []) == [c])
        check("L6d durability notice queued", (await notices()).contains { $0.contains("could not confirm") })
        _ = await svc.deleteReminder(id: c)
        await svc.reloadFromDisk()
        check("L6d deleted row not resurrected after reload", await memoryIds().isEmpty && diskRows()?.isEmpty == true)
        check("L6d no recovery copy needed (bytes were ours)", recovered().isEmpty)
        // One-shot completion path.
        let d = await svc.addReminder(triggerDate: Date().addingTimeInterval(-5), prompt: "D").id
        await svc._testInjectPostRenameFailure(true)
        _ = await svc.completePlainOccurrence(id: d)
        await svc._testInjectPostRenameFailure(false)
        _ = await svc.addReminder(triggerDate: Date().addingTimeInterval(7_200), prompt: "E")
        await svc.reloadFromDisk()
        check("L6d completed one-shot not resurrected", !(await memoryIds()).contains(d))
    }
}
