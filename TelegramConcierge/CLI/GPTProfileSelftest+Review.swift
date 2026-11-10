import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Pre-release review fixes (2026-11-09) on the GPT side: one patch at a
/// time (B1), redaction placeholders (S1), names of tools GPT lacks (S2), the
/// relative-path hint (L1) and freeform on the OpenAI-key route (L2).
extension GPTProfileSelftest {

    /// Two-party rendezvous with a timeout (a synchronous transaction hook).
    final class Rendezvous: @unchecked Sendable {
        private let cond = NSCondition()
        private var arrived = 0
        private let timeout: TimeInterval
        init(timeout: TimeInterval) { self.timeout = timeout }
        /// true when the other party arrived as well.
        @discardableResult func arrive() -> Bool {
            cond.lock(); defer { cond.unlock() }
            arrived += 1
            if arrived >= 2 { cond.broadcast(); return true }
            let deadline = Date().addingTimeInterval(timeout)
            while arrived < 2 { if !cond.wait(until: deadline) { return false } }
            return true
        }
    }

    final class SetOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    static func lines400() -> String { (1...400).map { "line \($0)" }.joined(separator: "\n") + "\n" }

    /// Replaces "line n" with "LINE n" (three lines of context).
    static func upcase(_ path: String, _ n: Int) -> String {
        "*** Begin Patch\n*** Update File: \(path)\n@@\n line \(n - 1)\n-line \(n)\n+LINE \(n)\n line \(n + 1)\n*** End Patch"
    }

    static func patchCall(_ id: String, _ input: String) -> ToolCall { call("apply_patch", ["input": input], editing: .gptFreeform, id: id) }

    static func reviewTests(_ t: CPTest) async {
        await raceTests(t)
        await notStartedTests(t)
        await serializerUnitTests(t)
        await redactionTests(t)
        await staleNameTests(t)
        await hintTests(t)
    }

    // MARK: B1 — one GPT patch at a time

    static func raceTests(_ t: CPTest) async {
        await FileTimeTracker.shared.resetGPTForTesting()
        let executor = ToolExecutor()
        // Z.1 the review's reproduction, unchanged: two patches of one file
        // in one round (it lost an edit in 20 of 40 trials while both said
        // "Success").
        var both = 0, lost = 0, failed = 0
        for trial in 0..<20 {
            let d = t.dir("z1"); let f = d + "/f.txt"; t.write(f, lines400())
            let r = (try? await executor.executeParallel([patchCall("z1a\(trial)", upcase(f, 10)), patchCall("z1b\(trial)", upcase(f, 390))])) ?? []
            let text = t.read(f) ?? ""
            let ok = r.filter { $0.editOutcome?.status == .applied }.count
            if ok == 2 && text.contains("LINE 10\n") && text.contains("LINE 390\n") { both += 1 } else if ok == 2 { lost += 1 } else { failed += 1 }
        }
        t.check("Z.1 two patches of one file in one round both land in every trial (review B1 repro)", both == 20,
                "both \(both) lost \(lost) failed \(failed)")
        // Z.2 model order: the second patch is written against the first's
        // result; the first is held back before the lock.
        do {
            let d = t.dir("z2"); let f = d + "/f.txt"; t.write(f, lines400())
            ToolExecutor.gptPatchBeforeLockHookForTesting = { id in if id == "z2a" { try? await Task.sleep(nanoseconds: 200_000_000) } }
            let dependent = "*** Begin Patch\n*** Update File: \(f)\n@@\n LINE 10\n-line 11\n+LINE 11\n*** End Patch"
            let r = (try? await executor.executeParallel([patchCall("z2a", upcase(f, 10)), patchCall("z2b", dependent)])) ?? []
            ToolExecutor.gptPatchBeforeLockHookForTesting = nil
            t.check("Z.2 a round's patches run in the model's order: the second sees the first's change",
                    r.count == 2 && r.allSatisfy { $0.editOutcome?.status == .applied } && t.read(f)?.contains("LINE 10\nLINE 11\n") == true,
                    r.map { String($0.content.prefix(160)) }.joined(separator: " | "))
        }
        // Z.3 two executors (the main agent and a subagent) on one file: the
        // first transaction is held at its revalidation for the second; the
        // process-wide lock keeps the second out until the first committed.
        do {
            let d = t.dir("z3"); let f = d + "/f.txt"; t.write(f, lines400())
            let meet = Rendezvous(timeout: 0.4)
            CodexPatchTransaction.beforeRevalidateHook = { _ in meet.arrive() }
            let other = ToolExecutor()
            async let a = executor.executeParallel([patchCall("z3a", upcase(f, 10))])
            async let b = other.executeParallel([patchCall("z3b", upcase(f, 390))])
            let ra = (try? await a) ?? [], rb = (try? await b) ?? []
            CodexPatchTransaction.beforeRevalidateHook = nil
            let text = t.read(f) ?? ""
            t.check("Z.3 a main agent and a subagent patching one file never interleave: both land",
                    (ra + rb).filter { $0.editOutcome?.status == .applied }.count == 2 && text.contains("LINE 10\n") && text.contains("LINE 390\n"),
                    (ra + rb).map { String($0.content.prefix(160)) }.joined(separator: " | "))
        }
        // Z.4 negative control: with the round order and the lock switched
        // off, the same fixtures cannot both land — the tests above see B1.
        GPTPatchSerializer.bypassForTesting = true
        GPTPatchRoundOrder.bypassForTesting = true
        do {
            let d = t.dir("z4"); let f = d + "/f.txt"; t.write(f, lines400())
            let meet = Rendezvous(timeout: 5)
            CodexPatchTransaction.beforeRevalidateHook = { _ in meet.arrive() }
            let other = ToolExecutor()
            async let a = executor.executeParallel([patchCall("z4a", upcase(f, 10))])
            async let b = other.executeParallel([patchCall("z4b", upcase(f, 390))])
            _ = (try? await a, try? await b)
            let text = t.read(f) ?? ""
            let crossBoth = text.contains("LINE 10\n") && text.contains("LINE 390\n")
            let g = t.dir("z4r"); let gf = g + "/f.txt"; t.write(gf, lines400())
            let meet2 = Rendezvous(timeout: 5)
            CodexPatchTransaction.beforeRevalidateHook = { _ in meet2.arrive() }
            _ = try? await executor.executeParallel([patchCall("z4c", upcase(gf, 10)), patchCall("z4d", upcase(gf, 390))])
            let roundText = t.read(gf) ?? ""
            let roundBoth = roundText.contains("LINE 10\n") && roundText.contains("LINE 390\n")
            t.check("Z.4 negative control: unserialized, two executors cannot both land", !crossBoth)
            t.check("Z.4b negative control: unserialized, two patches of one round cannot both land", !roundBoth)
        }
        CodexPatchTransaction.beforeRevalidateHook = nil
        GPTPatchSerializer.bypassForTesting = false
        GPTPatchRoundOrder.bypassForTesting = false
        // Z.6 every other tool of the round stays parallel.
        do {
            let d = t.dir("z6"); t.write(d + "/a.txt", "old\n")
            let gate = GateBox()
            ToolExecutor.gptPatchWorkerHookForTesting = { await gate.wait() }
            let marker = d + "/marker"
            let patch = "*** Begin Patch\n*** Update File: \(d)/a.txt\n@@\n-old\n+new\n*** End Patch"
            let task = Task {
                try await executor.executeParallel([patchCall("z6a", patch),
                                                    call("bash", ["command": "touch \(marker)"], editing: .gptFreeform, id: "z6b")])
            }
            let appeared = await waitUntil(15) { t.exists(marker) }
            await gate.open()
            let r = (try? await task.value) ?? []
            ToolExecutor.gptPatchWorkerHookForTesting = nil
            t.check("Z.6 a bash call of the round finishes while its patch is still held (other tools stay parallel)",
                    appeared && r.count == 2 && t.read(d + "/a.txt") == "new\n")
        }
    }

    // MARK: B1 — a patch stopped while queued never starts

    static func notStartedTests(_ t: CPTest) async {
        await FileTimeTracker.shared.resetGPTForTesting()
        let executor = ToolExecutor()
        let scope = await executor.gptSettlementScope
        let d = t.dir("z5"); t.write(d + "/a.txt", "old\n"); t.write(d + "/b.txt", "old\n")
        let pa = "*** Begin Patch\n*** Update File: \(d)/a.txt\n@@\n-old\n+new\n*** End Patch"
        let pb = "*** Begin Patch\n*** Update File: \(d)/b.txt\n@@\n-old\n+new\n*** End Patch"
        let ida = "z5a-\(UUID().uuidString.prefix(6))", idb = "z5b-\(UUID().uuidString.prefix(6))"
        let calls = [patchCall(ida, pa), patchCall(idb, pb)]
        let gate = GateBox()
        ToolExecutor.gptPatchWorkerHookForTesting = { await gate.wait() }
        let task = Task { try await executor.executeParallel(calls) }
        let committing = await waitUntil(15) {
            GPTPatchSettlement.shared.isCommitting(scope: scope, callID: ida) && t.read(d + "/a.txt") == "new\n"
        }
        task.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.open()
        let threw = (try? await task.value) == nil
        ToolExecutor.gptPatchWorkerHookForTesting = nil
        let settled = await GPTPatchSettlement.shared.settle(scope: scope, callIDs: [ida, idb])
        let round = GPTPatchSettlement.interruptedRound(AssistantToolCallMessage(content: "", toolCalls: calls), settled: settled,
                                                        placeholder: "[outcome unknown]")
        let ra = round?.results.first { $0.toolCallId == ida }
        let rb = round?.results.first { $0.toolCallId == idb }
        t.check("Z.5 /stop while a patch waits for its turn: it never runs, the first keeps its real result",
                committing && threw && t.read(d + "/b.txt") == "old\n" && t.read(d + "/a.txt") == "new\n"
                && ra?.editOutcome?.status == .applied && ra?.content.hasPrefix("Success.") == true,
                "committing \(committing) threw \(threw) a \(ra?.content ?? "nil")")
        t.check("Z.5b …and the queued one is recorded as not started (typed not_executed, never 'outcome unknown')",
                settled[idb]?.notStarted == true && rb?.outcomeBinding?.kind == .notExecuted
                && rb?.content == GPTPatchSettlement.notStartedText && rb?.editOutcome == .refused(.cancelled),
                "\(rb?.content ?? "nil") \(String(describing: rb?.outcomeBinding?.kind))")
        t.check("Z.5c the stop reply describes it as stopped before any file changed",
                GPTPatchSettlement.describe(.refused(.cancelled)) == "the file edit was stopped before any file changed")
        // A real result is never overwritten by the not-started record.
        let reg = GPTPatchSettlement()
        reg.begin(scope: "s", callID: "c"); reg.finish(scope: "s", callID: "c", .init(text: "Success.", outcome: .init(status: .applied, changed: ["/x"])))
        reg.recordNotStartedIfAbsent(scope: "s", callID: "c")
        reg.begin(scope: "s", callID: "r")
        reg.recordNotStartedIfAbsent(scope: "s", callID: "r")
        t.check("Z.5d 'not started' never replaces a settled or running patch",
                reg.result(scope: "s", callID: "c")?.notStarted == false && reg.result(scope: "s", callID: "c")?.outcome.status == .applied
                && reg.isCommitting(scope: "s", callID: "r") && reg.result(scope: "s", callID: "r") == nil)
    }

    // MARK: B1 — the lock and the round order as units

    static func serializerUnitTests(_ t: CPTest) async {
        let s = GPTPatchSerializer()
        let a = GPTPatchSerializer.Ticket(), b = GPTPatchSerializer.Ticket(), c = GPTPatchSerializer.Ticket()
        let gotA = await s.acquire(a)
        let bDone = SetOnce()
        let waitB = Task { () -> Bool in let ok = await s.acquire(b); bDone.set(); return ok }
        _ = await waitUntil(5) { s.waitersForTesting == 1 }
        s.cancel(b)
        let leftAtOnce = await waitUntil(5) { bDone.isSet }
        s.release(a)          // bounded: a broken cancel would hand b the lock here
        let gotB = await waitB.value
        if gotB { s.release(b) }
        let gotC = await s.acquire(c)
        let heldWithC = s.isHeldForTesting
        s.release(c)
        t.check("Z.7 a waiter stopped in the queue leaves at once without running; the lock passes on",
                gotA && leftAtOnce && !gotB && gotC && heldWithC && !s.isHeldForTesting && s.waitersForTesting == 0)
        let early = GPTPatchSerializer.Ticket()
        s.cancel(early)
        let gotEarly = await s.acquire(early)
        t.check("Z.7b a ticket stopped before it asked is refused", !gotEarly && !s.isHeldForTesting)
        // Through the executor: a patch stopped while it waits behind another
        // run's patch (held inside its transaction) returns at once, unrun.
        do {
            let d = t.dir("z7d"); t.write(d + "/a.txt", "old\n"); t.write(d + "/b.txt", "old\n")
            let release = DispatchSemaphore(value: 0)
            let held = SetOnce(), bDone = SetOnce()
            CodexPatchTransaction.beforeRevalidateHook = { path in
                if path.hasSuffix("/a.txt") { held.set(); _ = release.wait(timeout: .now() + 15) }
            }
            let first = ToolExecutor(), second = ToolExecutor()
            let pa = "*** Begin Patch\n*** Update File: \(d)/a.txt\n@@\n-old\n+new\n*** End Patch"
            let pb = "*** Begin Patch\n*** Update File: \(d)/b.txt\n@@\n-old\n+new\n*** End Patch"
            let ta = Task { (try? await first.executeParallel([patchCall("z7da", pa)])) ?? [] }
            let isHeld = await waitUntil(10) { held.isSet }
            let tb = Task { () -> [ToolResultMessage] in
                let r = (try? await second.executeParallel([patchCall("z7db", pb)])) ?? []
                bDone.set()
                return r
            }
            let queued = await waitUntil(10) { GPTPatchSerializer.shared.waitersForTesting == 1 }
            tb.cancel()
            let returnedWhileHeld = await waitUntil(5) { bDone.isSet }
            release.signal()
            let rb = await tb.value
            let ra = await ta.value
            CodexPatchTransaction.beforeRevalidateHook = nil
            t.check("Z.7d a patch stopped while it waits for another run's patch returns at once and never runs",
                    isHeld && queued && returnedWhileHeld && rb.first?.editOutcome?.category == .cancelled && t.read(d + "/b.txt") == "old\n"
                    && ra.first?.editOutcome?.status == .applied && t.read(d + "/a.txt") == "new\n",
                    "held \(isHeld) queued \(queued) returned \(returnedWhileHeld) b \(rb.first?.content ?? "nil")")
        }
        // FIFO: the order of arrival is the order of the lock.
        let first = GPTPatchSerializer.Ticket()
        _ = await s.acquire(first)
        let order = OrderBox()
        var waiters: [Task<Void, Never>] = []
        for i in 0..<5 {
            let ticket = GPTPatchSerializer.Ticket()
            waiters.append(Task { if await s.acquire(ticket) { await order.add(i); s.release(ticket) } })
            _ = await waitUntil(5) { s.waitersForTesting == i + 1 }
        }
        s.release(first)
        for w in waiters { await w.value }
        let seen = await order.all
        t.check("Z.7c the lock is handed on in arrival order", seen == [0, 1, 2, 3, 4], "\(seen)")
        // Round order: turns finishing out of order never deadlock.
        let o = GPTPatchRoundOrder(count: 3)
        let turn0 = await o.waitForTurn(0)
        let granted = SetOnce()
        let third = Task { () -> Bool in let ok = await o.waitForTurn(2); if ok { granted.set() }; return ok }
        o.finish(1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let waitedForZero = !granted.isSet
        o.finish(0)
        let turn2 = await waitUntil(5) { granted.isSet }
        third.cancel()        // bounded: a broken order never leaves this test waiting
        _ = await third.value
        t.check("Z.8 turns: 0 runs, 1 leaves early, 2 starts only after 0 finished", turn0 && waitedForZero && turn2)
        let o2 = GPTPatchRoundOrder(count: 2)
        _ = await o2.waitForTurn(0)
        let wDone = SetOnce()
        let w = Task { () -> Bool in let ok = await o2.waitForTurn(1); wDone.set(); return ok }
        try? await Task.sleep(nanoseconds: 50_000_000)
        w.cancel()
        let turnLeftAtOnce = await waitUntil(5) { wDone.isSet }
        if !turnLeftAtOnce { o2.finish(0) }
        let cancelled = await w.value
        t.check("Z.8b a waiting turn whose task is stopped returns at once and does not start", turnLeftAtOnce && !cancelled)
    }

    actor OrderBox {
        private var values: [Int] = []
        func add(_ v: Int) { values.append(v) }
        var all: [Int] { values }
    }

    // MARK: S1 — redaction placeholders

    static func redactionTests(_ t: CPTest) async {
        let d = t.dir("z9"); let f = d + "/k.env"; t.write(f, "A=1\n")
        guard let id = (try? FileIdentity.lstatPath(f)) ?? nil else { t.check("Z.9 fixture", false); return }
        func result(_ stdout: String) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: ["exit_code": 0, "stdout": stdout, "stderr": "", "status": "exited"])) ?? Data(), as: UTF8.self)
        }
        let current = ["[REDACTED:BRIGLIA_KEY_DEMO]"]
        t.check("Z.9 a shell read showing a current placeholder earns no receipt (review S1)",
                GPTShellRead.receipt(path: f, before: id, command: "cat \(f)", resultContent: result("T=[REDACTED:BRIGLIA_KEY_DEMO]\n"), placeholders: current) == nil)
        t.check("Z.9b text that only looks like a placeholder still earns one",
                GPTShellRead.receipt(path: f, before: id, command: "cat \(f)", resultContent: result("T=[REDACTED:SOMETHING_ELSE]\n"), placeholders: current) != nil)
        // End to end with a registered service key (bash output is redacted).
        let base: [String: Any] = ["ada.applyPatchEnabled": false, "ada.shortcutsEnabled": false]
        var withKey = base
        withKey[KeychainHelper.serviceKeysMetadataDefaultsKey] = (try? JSONEncoder().encode([ServiceKey(name: "DEMO_TOKEN", label: "Demo Token", description: "")])) ?? Data()
        UserDefaults.standard.setVolatileDomain(withKey, forName: UserDefaults.argumentDomain)
        defer {
            var restore = base
            restore[KeychainHelper.serviceKeysMetadataDefaultsKey] = Data("[]".utf8)
            UserDefaults.standard.setVolatileDomain(restore, forName: UserDefaults.argumentDomain)
            KeychainHelper.deleteServiceKeyValue(name: "DEMO_TOKEN")
        }
        let secret = "sk-demo-1234567890abcdefXYZ"
        try? KeychainHelper.saveServiceKeyValue(name: "DEMO_TOKEN", value: secret)
        let placeholder = "[REDACTED:\(KeychainHelper.serviceKeyEnvironmentName(for: "DEMO_TOKEN"))]"
        t.check("Z.10 fixture: the service key is in the live redaction environment",
                EditProtections.currentRedactionPlaceholders().contains(placeholder), "\(EditProtections.currentRedactionPlaceholders())")
        await FileTimeTracker.shared.resetGPTForTesting()
        let executor = ToolExecutor()
        let proj = t.dir("z10"); let env = proj + "/.env"
        t.write(env, "API_URL=https://x.example\nDEMO_TOKEN=\(secret)\n")
        let cat = await exec(executor, call("bash", ["command": "cat \(env)"], editing: .gptJSON))
        t.check("Z.10a a redacted cat of the file earns no receipt", cat.content.contains(placeholder) && cat.gptEvidence == nil, cat.content)
        await GPTEvidenceSettlement.publish([cat])
        let rewrite = "*** Begin Patch\n*** Add File: \(env)\n+API_URL=https://y.example\n+DEMO_TOKEN=\(placeholder)\n*** End Patch"
        let rw = await exec(executor, call("apply_patch", ["input": rewrite], editing: .gptJSON))
        t.check("Z.10b a whole-file rewrite carrying the placeholder is refused; the real key stays (review S1)",
                rw.editOutcome?.category == .protected && rw.content.contains(placeholder) && t.read(env)?.contains("DEMO_TOKEN=\(secret)\n") == true, rw.content)
        let up = "*** Begin Patch\n*** Update File: \(env)\n@@\n API_URL=https://x.example\n+BACKUP_TOKEN=\(placeholder)\n*** End Patch"
        let upr = await exec(executor, call("apply_patch", ["input": up], editing: .gptJSON))
        t.check("Z.10c an Update adding a placeholder line is refused", upr.editOutcome?.category == .protected && t.read(env)?.contains("BACKUP_TOKEN") == false, upr.content)
        let lookalike = "*** Begin Patch\n*** Update File: \(env)\n@@\n API_URL=https://x.example\n+NOTE=[REDACTED:NOT_A_LABEL]\n*** End Patch"
        let lr = await exec(executor, call("apply_patch", ["input": lookalike], editing: .gptJSON))
        t.check("Z.10d a line that only looks like a placeholder is allowed", lr.editOutcome?.status == .applied && t.read(env)?.contains("NOTE=[REDACTED:NOT_A_LABEL]") == true, lr.content)
        let read = await exec(executor, call("read_file", ["path": env], editing: .gptJSON))
        await GPTEvidenceSettlement.publish([read])
        let real = "*** Begin Patch\n*** Add File: \(env)\n+API_URL=https://y.example\n+DEMO_TOKEN=\(secret)\n*** End Patch"
        let rr = await exec(executor, call("apply_patch", ["input": real], editing: .gptJSON))
        t.check("Z.10e after read_file (not redacted) the rewrite with the real text is allowed",
                rr.editOutcome?.status == .applied && t.read(env) == "API_URL=https://y.example\nDEMO_TOKEN=\(secret)\n", rr.content)
        t.check("Z.10f the GPT bash note warns about placeholders", AvailableTools.gptReadNote.contains("[REDACTED:…]") && AvailableTools.gptReadNote.contains("never copy one into a patch"))
    }
}
