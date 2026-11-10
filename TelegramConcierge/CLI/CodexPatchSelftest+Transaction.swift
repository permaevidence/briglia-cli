import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// §14.3 transaction tests, §14.10b F2 and R3-2, §21 note 2.
extension CodexPatchSelftest {

    /// A directory tree as comparable values: kind, mode, bytes/link target.
    struct TreeEntry: Equatable { let kind: String; let mode: mode_t; let payload: Data }

    static func snapshot(_ root: String) -> [String: TreeEntry] {
        var out: [String: TreeEntry] = [:]
        func walk(_ dir: String, _ rel: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() {
                let path = dir + "/" + name, r = rel.isEmpty ? name : rel + "/" + name
                guard let id = try? FileIdentity.lstatPath(path) else { continue }
                switch id.kind {
                case .regular: out[r] = TreeEntry(kind: "f", mode: id.mode, payload: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
                case .symlink: out[r] = TreeEntry(kind: "l", mode: 0, payload: Data((id.linkTarget ?? "").utf8))
                case .directory: out[r] = TreeEntry(kind: "d", mode: id.mode, payload: Data()); walk(path, r)
                case .other: out[r] = TreeEntry(kind: "o", mode: id.mode, payload: Data())
                }
            }
        }
        walk(root, "")
        return out
    }

    static func diffTrees(_ a: [String: TreeEntry], _ b: [String: TreeEntry]) -> String {
        let keys = Set(a.keys).union(b.keys).sorted()
        return keys.filter { a[$0] != b[$0] }.map { k in
            "\(k): \(a[k].map { "\($0.kind) \(String($0.mode, radix: 8)) \($0.payload.count)B" } ?? "absent") → \(b[k].map { "\($0.kind) \(String($0.mode, radix: 8)) \($0.payload.count)B" } ?? "absent")"
        }.joined(separator: "; ")
    }

    /// The four-operation patch every injection point is driven through.
    static func fourOpFixture(_ t: CPTest, _ name: String) async -> (dir: String, patch: String) {
        let d = t.dir(name)
        t.write(d + "/upd.txt", "u1\nu2\n")
        t.write(d + "/mv.txt", "m1\n")
        t.write(d + "/del.txt", "d1\n")
        chmod(d + "/upd.txt", 0o640)
        await t.seed(d + "/del.txt")
        let patch = t.wrap("""
        *** Add File: \(d)/newdir/a/add.txt
        +added
        *** Update File: \(d)/upd.txt
        @@
         u1
        -u2
        +U2
        *** Update File: \(d)/mv.txt
        *** Move to: \(d)/moved/dir/mv.txt
        @@
        -m1
        +M1
        *** Delete File: \(d)/del.txt
        """)
        return (d, patch)
    }

    static func transactionTests(_ t: CPTest) async {
        // T.1: every fault point on every target — nothing left behind.
        var cases = 0, clean = 0, details: [String] = []
        for point in CodexPatchTransaction.FaultPoint.allCases {
            for suffix in ["/add.txt", "/upd.txt", "/moved/dir/mv.txt", "/mv.txt", "/del.txt", "/newdir", "/newdir/a", "/moved", "/moved/dir"] {
                let (d, patch) = await fourOpFixture(t, "t1")
                let before = snapshot(d)
                let fired = HitFlag()
                CodexPatchTransaction.faultInjector = { p, path in
                    // One-shot (a transient failure): the rollback runs without it.
                    if !fired.value && p == point && path.hasSuffix(suffix) && !CodexPatchTransaction.isTempName((path as NSString).lastPathComponent) { fired.hit(); return true }
                    return false
                }
                let r = await t.apply(patch)
                CodexPatchTransaction.faultInjector = nil
                guard fired.value else { continue }
                cases += 1
                let after = snapshot(d)
                let ok = r.outcome.status == .rolledBack && after == before
                if ok { clean += 1 } else { details.append("\(point.rawValue)@\(suffix): \(r.outcome.status) \(diffTrees(before, after)) \(r.text.prefix(200))") }
            }
        }
        t.check("T.1 a failure at every journaled step of every target rolls back to the exact pre-state (\(clean)/\(cases) injections)",
                cases >= 20 && clean == cases, details.prefix(6).joined(separator: " || "))

        do {
            // T.2 change between two target writes: the second target's change is preserved, the first is rolled back.
            let (d, patch) = await fourOpFixture(t, "t2")
            CodexPatchTransaction.beforeRevalidateHook = { path in
                if path.hasSuffix("/upd.txt") { try? Data("external\n".utf8).write(to: URL(fileURLWithPath: path)) }
            }
            let r = await t.apply(patch)
            CodexPatchTransaction.beforeRevalidateHook = nil
            t.check("T.2 a target changed between two writes: conflict, the external content is kept, earlier writes rolled back",
                    r.outcome.status == .rolledBack && r.outcome.category == .conflict && t.read(d + "/upd.txt") == "external\n"
                    && !t.exists(d + "/newdir") && r.text.contains("\(d)/upd.txt changed during the patch"), r.text)
        }
        do {
            // T.3 a destination appearing after preflight is never overwritten.
            let d = t.dir("t3")
            t.write(d + "/s.txt", "s\n")
            CodexPatchTransaction.beforeRevalidateHook = { path in
                if path.hasSuffix("/dest.txt") { try? Data("someone else\n".utf8).write(to: URL(fileURLWithPath: path)) }
            }
            let r = await t.apply(t.wrap("*** Update File: \(d)/s.txt\n*** Move to: \(d)/dest.txt\n@@\n-s\n+t"))
            CodexPatchTransaction.beforeRevalidateHook = nil
            t.check("T.3 a move destination that appears after preflight is kept and reported",
                    r.outcome.status == .rolledBack && t.read(d + "/dest.txt") == "someone else\n" && t.read(d + "/s.txt") == "s\n", r.text)
        }
        do {
            // T.4 link retargeting between preflight and commit.
            let d = t.dir("t4")
            t.write(d + "/one.txt", "x\n"); t.write(d + "/two.txt", "x\n")
            symlink(d + "/one.txt", d + "/link.txt")
            CodexPatchTransaction.beforeRevalidateHook = { _ in
                unlink(d + "/link.txt"); symlink(d + "/two.txt", d + "/link.txt")
            }
            let r = await t.apply(t.wrap("*** Update File: \(d)/link.txt\n@@\n-x\n+y"))
            CodexPatchTransaction.beforeRevalidateHook = nil
            t.check("T.4 a link retargeted during the patch is a conflict; neither file is written",
                    r.outcome.category == .conflict && t.read(d + "/one.txt") == "x\n" && t.read(d + "/two.txt") == "x\n", r.text)
        }
        do {
            // T.5 metadata-only change before the replace.
            let d = t.dir("t5")
            t.write(d + "/m.txt", "a\n"); chmod(d + "/m.txt", 0o644)
            CodexPatchTransaction.beforeRevalidateHook = { path in chmod(path, 0o600) }
            let r = await t.apply(t.wrap("*** Update File: \(d)/m.txt\n@@\n-a\n+b"))
            CodexPatchTransaction.beforeRevalidateHook = nil
            t.check("T.5 a metadata-only change (chmod) before the replace is a conflict", r.outcome.category == .conflict && t.read(d + "/m.txt") == "a\n", r.text)
        }
        do {
            // T.6 staged metadata before exposure: the temp already has the final mode.
            let d = t.dir("t6")
            t.write(d + "/k.sh", "#!/bin/sh\n"); chmod(d + "/k.sh", 0o751)
            let seen = ModeBox()
            CodexPatchTransaction.beforeRevalidateHook = { path in
                let dir = (path as NSString).deletingLastPathComponent
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where CodexPatchTransaction.isTempName(name) {
                    seen.mode = (try? FileIdentity.lstatPath(dir + "/" + name))??.mode
                }
            }
            let r = await t.apply(t.wrap("*** Update File: \(d)/k.sh\n@@\n+echo hi"))
            CodexPatchTransaction.beforeRevalidateHook = nil
            t.check("T.6 the staged file carries its final mode before it is exposed; outside the roots the exact mode is kept",
                    r.outcome.status == .applied && seen.mode == 0o751 && t.mode(d + "/k.sh") == 0o751, "temp \(String(seen.mode ?? 0, radix: 8)) final \(String(t.mode(d + "/k.sh") ?? 0, radix: 8))")
        }
        do {
            // T.7 PrivateStorage policy inside Briglia's roots (P39).
            let dataRoot = StoragePaths.dataRoot.appendingPathComponent("documents/cp-\(UUID().uuidString.prefix(6))").path
            let r = await t.apply(t.wrap("*** Add File: \(dataRoot)/sub/new.md\n+x"))
            t.check("T.7a inside the roots a new file is 0600 and new directories 0700",
                    r.outcome.status == .applied && t.mode(dataRoot + "/sub/new.md") == 0o600 && t.mode(dataRoot + "/sub") == 0o700 && t.mode(dataRoot) == 0o700, r.text)
            t.write(dataRoot + "/wide.md", "w\n"); chmod(dataRoot + "/wide.md", 0o644)
            let r2 = await t.apply(t.wrap("*** Update File: \(dataRoot)/wide.md\n@@\n-w\n+v"))
            t.check("T.7b inside the roots an update strips group/other bits (0644 → 0600)", r2.outcome.status == .applied && t.mode(dataRoot + "/wide.md") == 0o600, r2.text)
            let outside = t.dir("t7")
            let r3 = await t.apply(t.wrap("*** Add File: \(outside)/plain.txt\n+p"))
            let expected: mode_t = 0o666 & ~CodexPatchFS.currentUmask()
            t.check("T.7c outside the roots a new file gets the umask mode", r3.outcome.status == .applied && t.mode(outside + "/plain.txt") == expected,
                    "mode \(String(t.mode(outside + "/plain.txt") ?? 0, radix: 8)) expected \(String(expected, radix: 8))")
            let harness = StoragePaths.dataRoot.appendingPathComponent("archive/cp-\(UUID().uuidString.prefix(6)).txt").path
            t.write(outside + "/hl-target.txt", "h\n")
            try? FileManager.default.createDirectory(atPath: (harness as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            symlink(outside + "/hl-target.txt", harness)
            let r4 = await t.apply(t.wrap("*** Update File: \(harness)\n@@\n-h\n+g"))
            t.check("T.7d a symlink at a harness-owned state path is refused (writeAtomically's rule)", r4.outcome.status == .refused && t.read(outside + "/hl-target.txt") == "h\n", r4.text)
            unlink(harness)
        }
        do {
            // The MCP config file is written under its sidecar lock (forward path).
            let mcp = MCPRegistry.configFileURL.path
            t.write(mcp, "{\n  \"mcpServers\": {}\n}\n")
            let r = await t.apply(t.wrap("*** Update File: \(mcp)\n@@\n-  \"mcpServers\": {}\n+  \"mcpServers\": { }"))
            t.check("T.7e an Update of mcp.json goes through (sidecar lock taken) with the policy mode",
                    r.outcome.status == .applied && t.read(mcp)?.contains("{ }") == true && t.mode(mcp) == 0o600, r.text)
            unlink(mcp)
        }
        do {
            // F2: failure after a private-root rename, before the directory fsync.
            let dataDir = StoragePaths.dataRoot.appendingPathComponent("documents/f2-\(UUID().uuidString.prefix(6))").path
            t.write(dataDir + "/p.md", "p\n"); chmod(dataDir + "/p.md", 0o600)
            let before = snapshot(dataDir)
            let once = HitFlag()
            CodexPatchTransaction.faultInjector = { p, path in
                if !once.value && p == .directoryFsync && path.hasSuffix("/p.md") { once.hit(); return true }
                return false
            }
            let r = await t.apply(t.wrap("*** Update File: \(dataDir)/p.md\n@@\n-p\n+q"))
            CodexPatchTransaction.faultInjector = nil
            t.check("T.8 F2: a failed directory fsync after the rename is rolled back from the receipt",
                    r.outcome.status == .rolledBack && snapshot(dataDir) == before && r.outcome.restored == ["\(dataDir)/p.md"], r.text)
        }
        do {
            // F2: directory-mode tightening is journaled and undone.
            let dataDir = StoragePaths.dataRoot.appendingPathComponent("documents/f2t-\(UUID().uuidString.prefix(6))").path
            t.write(dataDir + "/w.md", "w\n")
            chmod(dataDir, 0o755)
            let once9 = HitFlag()
            CodexPatchTransaction.faultInjector = { p, path in
                if !once9.value && p == .stageWrite && path.hasSuffix("/w.md") { once9.hit(); return true }
                return false
            }
            let r = await t.apply(t.wrap("*** Update File: \(dataDir)/w.md\n@@\n-w\n+x"))
            CodexPatchTransaction.faultInjector = nil
            t.check("T.9 F2: a tightened parent directory gets its old mode back on rollback", r.outcome.status == .rolledBack && t.mode(dataDir) == 0o755, "mode \(String(t.mode(dataDir) ?? 0, radix: 8)) \(r.text)")
        }
    }

    static func transactionRollbackTests(_ t: CPTest) async {
        // Each case: commit the four-op fixture's first steps, then force a
        // rollback at the final Delete, with interference before rollback.
        func forced(_ name: String, interfere: @escaping (String) -> Void) async -> (dir: String, result: CodexPatch.Result) {
            let (d, patch) = await fourOpFixture(t, name)
            CodexPatchTransaction.faultInjector = { p, path in p == .remove && path.hasSuffix("/del.txt") }
            CodexPatchTransaction.beforeRollbackHook = { interfere(d) }
            let r = await t.apply(patch)
            CodexPatchTransaction.faultInjector = nil
            CodexPatchTransaction.beforeRollbackHook = nil
            return (d, r)
        }
        do {
            let (d, r) = await forced("r1") { _ in }
            t.check("T.10 without interference every step is undone (Move source restored, Delete untouched)",
                    r.outcome.status == .rolledBack && t.read(d + "/mv.txt") == "m1\n" && t.read(d + "/upd.txt") == "u1\nu2\n" && t.mode(d + "/upd.txt") == 0o640
                    && !t.exists(d + "/moved") && !t.exists(d + "/newdir") && t.read(d + "/del.txt") == "d1\n", r.text)
        }
        do {
            let (d, r) = await forced("r2") { d in try? Data("concurrent\n".utf8).write(to: URL(fileURLWithPath: d + "/upd.txt")) }
            t.check("T.11 a concurrent edit before rollback is preserved and reported as a conflict (P38)",
                    r.outcome.status == .partial && t.read(d + "/upd.txt") == "concurrent\n" && r.outcome.conflicts.contains("\(d)/upd.txt")
                    && r.text.contains("NOT restored") && r.text.contains("\(d)/upd.txt"), r.text)
        }
        do {
            let (d, r) = await forced("r3") { d in chmod(d + "/upd.txt", 0o600) }
            t.check("T.12 a chmod of a committed file before rollback is a conflict, not undone (R3-2, P53)",
                    r.outcome.conflicts.contains("\(d)/upd.txt") && t.read(d + "/upd.txt") == "u1\nU2\n" && t.mode(d + "/upd.txt") == 0o600, r.text)
        }
        do {
            let (d, r) = await forced("r4") { d in
                rmdir(d + "/newdir/a") // only works if empty — it holds add.txt, so remove that first
                unlink(d + "/newdir/a/add.txt"); rmdir(d + "/newdir/a"); mkdir(d + "/newdir/a", 0o700)
            }
            t.check("T.13 a created directory replaced by another empty directory is a conflict, not removed (P54)",
                    r.outcome.conflicts.contains("\(d)/newdir/a") && t.exists(d + "/newdir/a"), r.text)
        }
        do {
            let (d, r) = await forced("r5") { d in try? Data("recreated\n".utf8).write(to: URL(fileURLWithPath: d + "/mv.txt")) }
            t.check("T.14 a removed source recreated before rollback is a conflict; the new file is kept (P55)",
                    r.outcome.conflicts.contains("\(d)/mv.txt") && t.read(d + "/mv.txt") == "recreated\n", r.text)
        }
        do {
            let (d, r) = await forced("r6") { d in chmod(d + "/moved/dir", 0o700) }
            t.check("T.15 chmod of a created directory before rollback is a conflict (§21 note 2)",
                    r.outcome.conflicts.contains("\(d)/moved/dir") && t.exists(d + "/moved/dir"), r.text)
        }
        do {
            // A tightened directory whose mode changed again: conflict, left as found.
            let dataDir = StoragePaths.dataRoot.appendingPathComponent("documents/r7-\(UUID().uuidString.prefix(6))").path
            t.write(dataDir + "/a.md", "a\n"); t.write(dataDir + "/z.md", "z\n")
            await t.seed(dataDir + "/z.md")
            chmod(dataDir, 0o755)
            CodexPatchTransaction.faultInjector = { p, path in p == .remove && path.hasSuffix("/z.md") }
            CodexPatchTransaction.beforeRollbackHook = { chmod(dataDir, 0o750) }
            let r = await t.apply(t.wrap("*** Update File: \(dataDir)/a.md\n@@\n-a\n+b\n*** Delete File: \(dataDir)/z.md"))
            CodexPatchTransaction.faultInjector = nil
            CodexPatchTransaction.beforeRollbackHook = nil
            let canon = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
            t.check("T.16 a tightened directory whose mode changed again is a conflict (R3-2)",
                    r.outcome.conflicts.contains { canon($0) == canon(dataDir) } && t.mode(dataDir) == 0o750, r.text)
        }
        do {
            // Temps registered before a failing write are cleaned.
            let d = t.dir("r8")
            t.write(d + "/a.txt", "a\n")
            for point in [CodexPatchTransaction.FaultPoint.stageWrite, .stageChmod, .stageFsync] {
                CodexPatchTransaction.faultInjector = { p, _ in p == point }
                _ = await t.apply(t.wrap("*** Update File: \(d)/a.txt\n@@\n-a\n+b"))
                CodexPatchTransaction.faultInjector = nil
            }
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter(CodexPatchTransaction.isTempName)
            t.check("T.17 temp files registered before a failing write/chmod/fsync are removed", leftovers.isEmpty && t.read(d + "/a.txt") == "a\n", "\(leftovers)")
        }
        do {
            // §6.5 order and the rollback report wording (I5).
            let (d, r) = await forced("r9") { d in try? Data("x\n".utf8).write(to: URL(fileURLWithPath: d + "/newdir/a/add.txt")) }
            t.check("T.18 the report names restored and conflicting paths exactly (I5)",
                    r.outcome.restored.contains("\(d)/upd.txt") && r.outcome.restored.contains("\(d)/mv.txt")
                    && r.outcome.conflicts.contains("\(d)/newdir/a/add.txt") && r.text.contains("Rolled back:") && r.text.contains("\(d)/newdir/a/add.txt"), r.text)
        }
    }

    /// Codex S1 R1: a failure while staging a RESTORATION (rollback of a
    /// replaced file or of a removed Move source) must still clean its temp.
    static func rollbackStageFailureTests(_ t: CPTest) async {
        var details: [String] = []
        var ok = 0, total = 0
        for (kind, suffix) in [("replaced", "/upd.txt"), ("removed", "/mv.txt")] {
            for point in [CodexPatchTransaction.FaultPoint.stageWrite, .stageChmod, .stageFsync] {
                total += 1
                let (d, patch) = await fourOpFixture(t, "rs")
                CodexPatchTransaction.faultInjector = { p, path in p == .remove && path.hasSuffix("/del.txt") }
                CodexPatchTransaction.beforeRollbackHook = {
                    CodexPatchTransaction.faultInjector = { p, path in p == point && path.hasSuffix(suffix) }
                }
                let r = await t.apply(patch)
                CodexPatchTransaction.faultInjector = nil
                CodexPatchTransaction.beforeRollbackHook = nil
                var leftovers: [String] = []
                if let e = FileManager.default.enumerator(atPath: d) {
                    for case let rel as String in e where CodexPatchTransaction.isTempName((rel as NSString).lastPathComponent) { leftovers.append(rel) }
                }
                let target = d + suffix
                let reported = r.outcome.changed.contains(target)
                if leftovers.isEmpty && reported && r.outcome.status == .partial { ok += 1 }
                else { details.append("\(kind)/\(point.rawValue): leftovers \(leftovers) status \(r.outcome.status) changed \(r.outcome.changed)") }
            }
        }
        t.check("T.19 a failed restoration stage (replaced and removed, write/chmod/fsync) leaves no temp and is reported (Codex S1 R1) (\(ok)/\(total))",
                ok == total, details.joined(separator: " || "))
        do {
            // Codex's engine-level reproduction.
            let d = t.dir("rs2")
            t.write(d + "/a.txt", "old\n"); t.write(d + "/b.txt", "old\n")
            CodexPatchTransaction.faultInjector = { p, path in p == .stageWrite && path.hasSuffix("/b.txt") }
            CodexPatchTransaction.beforeRollbackHook = { CodexPatchTransaction.faultInjector = { p, _ in p == .stageFsync } }
            let r = await t.apply(t.wrap("*** Update File: \(d)/a.txt\n@@\n-old\n+new\n*** Update File: \(d)/b.txt\n@@\n-old\n+new"))
            CodexPatchTransaction.faultInjector = nil
            CodexPatchTransaction.beforeRollbackHook = nil
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter(CodexPatchTransaction.isTempName)
            t.check("T.20 Codex's reproduction: partial outcome, a.txt reported still changed, no temp left",
                    leftovers.isEmpty && r.outcome.status == .partial && r.outcome.changed == ["\(d)/a.txt"] && t.read(d + "/b.txt") == "old\n", "\(leftovers) \(r.text)")
        }
    }

    /// Codex S1 round 2: the restoration's rename AND the temp's unlink fail
    /// under real permissions (parent made read-only after staging); the temp
    /// must stay accounted for and be named.
    static func discardFailureTests(_ t: CPTest) async {
        let d = t.dir("rs3")
        t.write(d + "/a.txt", "old\n"); t.write(d + "/b.txt", "old\n")
        CodexPatchTransaction.faultInjector = { p, path in p == .stageWrite && path.hasSuffix("/b.txt") }
        CodexPatchTransaction.beforeRollbackHook = {
            CodexPatchTransaction.faultInjector = nil
            CodexPatchTransaction.beforeRevalidateHook = { _ in chmod(d, 0o500) }
        }
        let r = await t.apply(t.wrap("*** Update File: \(d)/a.txt\n@@\n-old\n+new\n*** Update File: \(d)/b.txt\n@@\n-old\n+new"))
        chmod(d, 0o700)
        CodexPatchTransaction.faultInjector = nil
        CodexPatchTransaction.beforeRollbackHook = nil
        CodexPatchTransaction.beforeRevalidateHook = nil
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter(CodexPatchTransaction.isTempName)
        let accounted = leftovers.allSatisfy { r.text.contains($0) }
        t.check("T.21 a temp whose unlink fails during rollback stays accounted for and is named (Codex S1 round 2)",
                getuid() == 0 || (accounted && r.outcome.status == .partial && r.text.contains("Temporary files that could not be removed or checked") == !leftovers.isEmpty
                                  && !leftovers.isEmpty), "\(leftovers) \(r.text)")
        for name in leftovers { unlink(d + "/" + name) }
    }

    /// Codex S1 round 3: the parent becomes unsearchable (0400), so even
    /// inspecting the temp fails — it must be named, never forgotten.
    static func unsearchableParentTests(_ t: CPTest) async {
        for (label, rollbackFault) in [("revalidation", false), ("stageFsync", true)] {
            let d = t.dir("rs4")
            t.write(d + "/a.txt", "old\n"); t.write(d + "/b.txt", "old\n")
            CodexPatchTransaction.faultInjector = { p, path in p == .stageWrite && path.hasSuffix("/b.txt") }
            CodexPatchTransaction.beforeRollbackHook = {
                if rollbackFault {
                    CodexPatchTransaction.faultInjector = { p, path in
                        guard p == .stageFsync, path.hasSuffix("/a.txt") else { return false }
                        chmod(d, 0o400); return true
                    }
                } else {
                    CodexPatchTransaction.faultInjector = nil
                    CodexPatchTransaction.beforeRevalidateHook = { _ in chmod(d, 0o400) }
                }
            }
            let r = await t.apply(t.wrap("*** Update File: \(d)/a.txt\n@@\n-old\n+new\n*** Update File: \(d)/b.txt\n@@\n-old\n+new"))
            chmod(d, 0o700)
            CodexPatchTransaction.faultInjector = nil
            CodexPatchTransaction.beforeRollbackHook = nil
            CodexPatchTransaction.beforeRevalidateHook = nil
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter(CodexPatchTransaction.isTempName)
            t.check("T.22 \(label): with an unsearchable parent the surviving temp is named, not forgotten (Codex S1 round 3)",
                    getuid() == 0 || (!leftovers.isEmpty && leftovers.allSatisfy { r.text.contains($0) }
                                      && r.text.contains("Temporary files that could not be removed or checked") && r.outcome.status == .partial),
                    "\(leftovers) \(r.text)")
            for name in leftovers { unlink(d + "/" + name) }
        }
        do {
            // Direct helper check: an inspection error keeps the receipt.
            let d = t.dir("rs5")
            let journal = CodexPatchTransaction.Journal()
            if let staged = try? CodexPatchTransaction.stage(Data("x".utf8), forTarget: d + "/f.txt", finalMode: 0o600, journal: journal) {
                chmod(d, 0o400)
                CodexPatchTransaction.discard(staged, journal: journal)
                var report = CodexPatchTransaction.RollbackReport()
                CodexPatchTransaction.cleanTemps(journal, &report)
                chmod(d, 0o700)
                let kept = journal.receipts.contains { if case .temp = $0 { return true }; return false }
                t.check("T.23 discard/cleanTemps keep and report a temp they cannot inspect",
                        getuid() == 0 || (kept && report.leftoverTemps == [staged.tempPath]), "kept \(kept) report \(report.leftoverTemps)")
                unlink(staged.tempPath)
            } else { t.check("T.23 fixture", false) }
        }
        // Codex S1 round 4 (non-blocking test note): rollback's direct
        // `.temp` branch and the created-directory branch, inspection failure
        // versus verified absence.
        do {
            let d = t.dir("rs6")
            let journal = CodexPatchTransaction.Journal()
            if let staged = try? CodexPatchTransaction.stage(Data("x".utf8), forTarget: d + "/g.txt", finalMode: 0o600, journal: journal) {
                chmod(d, 0o400)
                let report = await CodexPatchTransaction.rollback(journal)
                chmod(d, 0o700)
                t.check("T.24 rollback's .temp branch names a temp it cannot inspect (never unlinks it)",
                        getuid() == 0 || (report.leftoverTemps == [staged.tempPath] && t.exists(staged.tempPath)),
                        "report \(report.leftoverTemps) exists \(t.exists(staged.tempPath))")
                unlink(staged.tempPath)
            } else { t.check("T.24 fixture", false) }
        }
        do {
            let d = t.dir("rs7")
            let child = d + "/made/deeper"
            let journal = CodexPatchTransaction.Journal()
            if (try? CodexPatchTransaction.ensureParent(of: child + "/f.txt", inScope: false, journal: journal)) != nil {
                let created = journal.receipts.compactMap { r -> String? in if case .createdDirectory(let p, _, _, _) = r { return p }; return nil }
                // Inspection failure: the parent of the created directories
                // becomes unsearchable — reported as a conflict, kept.
                chmod(d, 0o400)
                let blocked = await CodexPatchTransaction.rollback(journal)
                chmod(d, 0o700)
                t.check("T.25 created directory that cannot be inspected is a conflict and is kept",
                        getuid() == 0 || (!created.isEmpty && created.allSatisfy { blocked.conflicts.contains($0) }
                                          && FileManager.default.fileExists(atPath: child)),
                        "created \(created) conflicts \(blocked.conflicts)")
                // Verified absence: someone removed them; nothing to undo.
                try? FileManager.default.removeItem(atPath: d + "/made")
                let absent = await CodexPatchTransaction.rollback(journal)
                t.check("T.25 verified absence of a created directory is no conflict",
                        absent.conflicts.isEmpty, "conflicts \(absent.conflicts)")
            } else { t.check("T.25 fixture", false) }
        }
    }

    final class HitFlag: @unchecked Sendable {
        private(set) var value = false
        func hit() { value = true }
    }

    final class ModeBox: @unchecked Sendable { var mode: mode_t? }
}
