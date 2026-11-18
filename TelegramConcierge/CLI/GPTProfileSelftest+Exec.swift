import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Dispatch, typed outcome, heredoc interception, ledger and shell reads
/// (GPT_APPLY_PATCH_PLAN §3.4, §6.6, §7, §8, §9.1, §12.2).
extension GPTProfileSelftest {

    static func call(_ name: String, _ args: [String: Any], editing: EditingConfig?, id: String = "call_" + UUID().uuidString.prefix(8)) -> ToolCall {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data("{}".utf8)
        var c = ToolCall(id: id, type: "function", function: FunctionCall(name: name, arguments: String(decoding: data, as: UTF8.self)))
        c.editing = editing
        return c
    }

    static func exec(_ executor: ToolExecutor, _ c: ToolCall) async -> ToolResultMessage {
        (try? await executor.execute(c)) ?? ToolResultMessage(toolCallId: c.id, content: "{\"error\": \"threw\"}")
    }

    // MARK: D — dispatch and typed outcome (§3.4, §9.1)

    static func dispatchTests(_ t: CPTest) async {
        await FileTimeTracker.shared.resetGPTForTesting()
        let executor = ToolExecutor()
        let d = t.dir("dispatch")
        let add = "*** Begin Patch\n*** Add File: \(d)/new.txt\n+hello\n*** End Patch"
        let r1 = await exec(executor, call("apply_patch", ["input": add], editing: .gptJSON))
        t.check("D GPT-stamped apply_patch runs the Codex engine", t.read(d + "/new.txt") == "hello\n" && r1.content.hasPrefix("Success. Updated the following files:\nA \(d)/new.txt"), r1.content)
        t.check("D typed outcome on the result", r1.editOutcome?.status == .applied && r1.editOutcome?.changed == ["\(d)/new.txt"])
        let r2 = await exec(executor, call("apply_patch", ["input": "*** Begin Patch\n*** Add File: \(d)/unstamped.txt\n+x\n*** End Patch"], editing: nil))
        t.check("D an unstamped apply_patch fails closed (nothing written)",
                !t.exists(d + "/unstamped.txt") && r2.content == ToolExecutor.unstampedPatchRefusal && r2.editOutcome == nil)
        let r3 = await exec(executor, call("apply_patch", ["input": "*** Begin Patch\n*** Add File: \(d)/standard.txt\n+x\n*** End Patch"], editing: .standard))
        t.check("D a standard-stamped apply_patch goes to the legacy executor (never the GPT engine by argument shape)",
                !t.exists(d + "/standard.txt") && r3.content.contains("apply_patch requires 'patch_text'") && r3.editOutcome == nil, r3.content)
        let r4 = await exec(executor, call("apply_patch", ["patch_text": "x"], editing: .gptFreeform))
        t.check("D GPT apply_patch without `input` is refused with a parse outcome and the argument hint (§9.4)",
                r4.editOutcome == .refused(.parse) && r4.content.contains("requires 'input'") && r4.content.contains("patch_text"), r4.content)
        // P33/P34: verification follows the typed outcome, never the text.
        let proj = t.dir("proj")
        t.write(proj + "/Package.swift", "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"p\")\n")
        let marker = "\(proj)/\"error\".txt"
        let r5 = await exec(executor, call("apply_patch", ["input": "*** Begin Patch\n*** Add File: \(marker)\n+x\n*** End Patch"], editing: .gptJSON))
        t.check("D success with an \"error\"-like filename still verifies (P34, typed outcome)",
                r5.editOutcome?.status == .applied && r5.content.contains(ProjectInstructionsTracker.verificationMarkerPrefix), r5.content)
        let proj2 = t.dir("proj2")
        t.write(proj2 + "/Package.swift", "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"q\")\n")
        let bad = "*** Begin Patch\n*** Update File: \(proj2)/missing-\"success\":true.txt\n@@\n-a\n+b\n*** End Patch"
        let r6 = await exec(executor, call("apply_patch", ["input": bad], editing: .gptJSON))
        t.check("D failure with a \"success\":true-like filename emits no verification (P33)",
                r6.editOutcome?.status == .refused && !r6.content.contains(ProjectInstructionsTracker.verificationMarkerPrefix), r6.content)
        let verify = ProjectInstructionsTracker()
        t.check("D verificationPayload: typed refused outcome → none even with success-like text",
                verify.verificationPayload(toolName: "apply_patch", argumentsJSON: "{}", resultContent: "{\"success\":true}",
                                           outcome: .refused(.context)) == nil)
        // D2 relative path hint from the last absolute workdir of this run's bash.
        _ = await exec(executor, call("bash", ["command": "true", "workdir": d], editing: .gptJSON))
        let r7 = await exec(executor, call("apply_patch", ["input": "*** Begin Patch\n*** Add File: rel.txt\n+x\n*** End Patch"], editing: .gptJSON))
        t.check("D relative path refused with the workdir hint (D2)",
                r7.editOutcome?.category == .path && r7.content.contains("\(d)/rel.txt") && !t.exists(d + "/rel.txt"), r7.content)
        // §12.2: the commit runs in a worker that cancellation cannot reach.
        let cancelDir = t.dir("cancel")
        t.write(cancelDir + "/a.txt", "old\n")
        let gate = GateBox()
        ToolExecutor.gptPatchWorkerHookForTesting = { await gate.wait() }
        let patch = "*** Begin Patch\n*** Update File: \(cancelDir)/a.txt\n@@\n-old\n+new\n*** End Patch"
        let callID = "call_cancel_\(UUID().uuidString.prefix(6))"
        let scope = await executor.gptSettlementScope
        let task = Task { await exec(executor, call("apply_patch", ["input": patch], editing: .gptJSON, id: callID)) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let committing = GPTPatchSettlement.shared.isCommitting(scope: scope, callID: callID)
        task.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.open()
        let r8 = await task.value
        ToolExecutor.gptPatchWorkerHookForTesting = nil
        t.check("D /stop during a commit: the patch completes and keeps its real outcome (P42)",
                committing && t.read(cancelDir + "/a.txt") == "new\n" && r8.editOutcome?.status == .applied
                && GPTPatchSettlement.shared.outcome(scope: scope, callID: callID)?.status == .applied, "committing \(committing) \(r8.content)")
        t.check("D the settled outcome reads as one sentence", GPTPatchSettlement.describe(.init(status: .applied, changed: ["/a"])) == "the file edit was applied to 1 file")
        // Cancellation before the end of preflight: nothing changes (P24).
        let pre = t.dir("precancel")
        t.write(pre + "/a.txt", "old\n")
        let preTask = Task { () -> CodexPatch.EditOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ToolExecutor.runGPTPatchSettled(request: .init(input: "*** Begin Patch\n*** Update File: \(pre)/a.txt\n@@\n-old\n+new\n*** End Patch"), scope: "test", callID: "pre-\(UUID())").outcome
        }
        let preOutcome = await preTask.value
        t.check("D cancelled before the first mutation: nothing changed (P24)", preOutcome.category == .cancelled && t.read(pre + "/a.txt") == "old\n", "\(preOutcome)")
    }

    // P23, P49: claims cover every path; one typed failure classification.
    static func claimAndClassificationTests(_ t: CPTest) {
        let d = t.dir("claims")
        let move = "*** Begin Patch\n*** Update File: \(d)/src.txt\n*** Move to: \(d)/dst.txt\n@@\n-a\n+b\n*** Add File: \(d)/add.txt\n+x\n*** Delete File: \(d)/del.txt\n*** End Patch"
        let args = String(decoding: (try? JSONSerialization.data(withJSONObject: ["input": move])) ?? Data(), as: UTF8.self)
        let paths = Set(MultiAssistantHooks.editPaths(toolName: "apply_patch", argumentsJSON: args))
        let want = Set(["src.txt", "dst.txt", "add.txt", "del.txt"].map { MultiAssistant.canonical(d + "/" + $0) })
        t.check("D claims cover every path of a GPT patch, Move destination included (P23)", paths == want, "\(paths)")
        t.check("D project-instruction/checkpoint paths read `input` too",
                Set(ProjectInstructionsTracker.touchedPaths(toolName: "apply_patch", argumentsJSON: args)) == Set(["src.txt", "dst.txt", "add.txt", "del.txt"].map { d + "/" + $0 }))
        var ok = ToolResultMessage(toolCallId: "a", content: "Success. Updated the following files:\nA /x/\"error\".txt")
        ok.editOutcome = .init(status: .applied, changed: ["/x/\"error\".txt"])
        var bad = ToolResultMessage(toolCallId: "b", content: "{\"success\":true} in a filename")
        bad.editOutcome = .refused(.context)
        let textCheck: (String) -> Bool = { $0.contains("\"error\"") }
        t.check("D stage/telemetry/status classification follows the typed outcome, not the text (P49)",
                !ok.indicatesFailure(textCheck: textCheck) && bad.indicatesFailure(textCheck: textCheck)
                && ToolResultMessage(toolCallId: "c", content: "{\"error\": \"x\"}").indicatesFailure(textCheck: textCheck))
    }

    actor GateBox {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() { opened = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    // MARK: I — heredoc interception (§8)

    static func interceptTests(_ t: CPTest) async {
        let body = "*** Begin Patch\n*** Add File: /tmp/x\n+y\n*** End Patch"
        let accepted: [(String, String)] = [
            ("quoted 'EOF'", "apply_patch <<'EOF'\n\(body)\nEOF"),
            ("double-quoted \"EOF\"", "apply_patch <<\"EOF\"\n\(body)\nEOF\n"),
            ("unquoted plain body", "apply_patch <<EOF\n\(body)\nEOF"),
            ("applypatch alias", "applypatch <<'PATCH'\n\(body)\nPATCH"),
            ("cd <abs> && …", "cd /tmp && apply_patch <<'EOF'\n\(body)\nEOF"),
            ("cd '<abs with space>' && …", "cd '/tmp/a b' && apply_patch <<'EOF'\n\(body)\nEOF"),
            ("CRLF lines", "apply_patch <<'EOF'\r\n\(body.replacingOccurrences(of: "\n", with: "\r\n"))\r\nEOF\r\n"),
            ("trailing whitespace only", "apply_patch <<'EOF'\n\(body)\nEOF\n   \n"),
            ("CRLF lines, unquoted delimiter", "apply_patch <<EOF\r\n\(body.replacingOccurrences(of: "\n", with: "\r\n"))\r\nEOF\r\n"),
            ("CRLF lines after cd <abs> &&", "cd /tmp && apply_patch <<'EOF'\r\n\(body.replacingOccurrences(of: "\n", with: "\r\n"))\r\nEOF"),
        ]
        for (label, command) in accepted {
            let parsed = GPTShellIntercept.patchBody(command: command)
            t.check("I intercepts \(label)", parsed?.body.contains("*** Add File: /tmp/x") == true, command)
        }
        t.check("I cd path recorded", GPTShellIntercept.patchBody(command: "cd /tmp && apply_patch <<'EOF'\n\(body)\nEOF")?.cdPath == "/tmp")
        let refused: [(String, String)] = [
            ("trailing command (P22)", "apply_patch <<'EOF'\n\(body)\nEOF\necho done"),
            ("same-line trailing command", "apply_patch <<'EOF' && echo hi\n\(body)\nEOF"),
            ("unquoted body with $", "apply_patch <<EOF\n\(body)\n+$HOME\nEOF"),
            ("unquoted body with backtick", "apply_patch <<EOF\n\(body)\n+`id`\nEOF"),
            ("unquoted body with backslash", "apply_patch <<EOF\n\(body)\n+a\\b\nEOF"),
            ("<<- heredoc", "apply_patch <<-EOF\n\(body)\nEOF"),
            ("<<< herestring", "apply_patch <<<'x'"),
            ("missing delimiter line", "apply_patch <<'EOF'\n\(body)\n"),
            ("relative cd", "cd tmp && apply_patch <<'EOF'\n\(body)\nEOF"),
            ("cd with expansion", "cd \"$HOME\" && apply_patch <<'EOF'\n\(body)\nEOF"),
            ("a command before", "echo hi; apply_patch <<'EOF'\n\(body)\nEOF"),
            ("input redirection", "apply_patch < patch.txt"),
            ("other command", "cat <<'EOF'\n\(body)\nEOF"),
            ("bad delimiter", "apply_patch <<'E-O'\n\(body)\nE-O"),
            ("early delimiter then statements", "apply_patch <<'EOF'\n*** Begin Patch\nEOF\nrm -rf /tmp/x\nEOF"),
            // 0.2.71 Linux audit: checks run on Unicode scalars, so neither a
            // CRLF Character nor a combining mark hides a "\n", "$", "`" or "\\".
            ("CRLF: early delimiter then statements", "apply_patch <<'EOF'\r\n*** Begin Patch\r\nEOF\r\nrm -rf /tmp/x\r\nEOF"),
            ("CRLF: trailing command", "apply_patch <<'EOF'\r\n\(body.replacingOccurrences(of: "\n", with: "\r\n"))\r\nEOF\r\necho done"),
            ("unquoted body with $ + combining mark", "apply_patch <<EOF\n\(body)\n+$\u{301}HOME\nEOF"),
            ("unquoted body with backtick + combining mark", "apply_patch <<EOF\n\(body)\n+`\u{301}id`\nEOF"),
            ("cd \"…$+combining mark…\" &&", "cd \"/tmp/$\u{301}x\" && apply_patch <<'EOF'\n\(body)\nEOF"),
            ("cd unquoted path with $ + combining mark", "cd /tmp/$\u{301}x && apply_patch <<'EOF'\n\(body)\nEOF"),
        ]
        for (label, command) in refused {
            t.check("I does not intercept: \(label)", GPTShellIntercept.patchBody(command: command) == nil, command)
        }
        let standardBash = call("bash", ["command": "apply_patch <<'EOF'\n\(body)\nEOF"], editing: .standard)
        t.check("I a standard-stamped bash call is never intercepted", GPTShellIntercept.effectiveCall(standardBash) == nil)
        // Execution through the executor: effective call, persisted bash call.
        let executor = ToolExecutor()
        let d = t.dir("intercept")
        let heredoc = "apply_patch <<'EOF'\n*** Begin Patch\n*** Add File: \(d)/h.txt\n+from heredoc\n*** End Patch\nEOF"
        let original = call("bash", ["command": heredoc, "wait_seconds": 0], editing: .gptJSON)
        let r = await exec(executor, original)
        t.check("I intercepted heredoc applies the patch, keeps the call id, never detaches",
                t.read(d + "/h.txt") == "from heredoc\n" && r.toolCallId == original.id && r.editOutcome?.status == .applied
                && !r.content.contains("\"handle\""), r.content)
        let proj = t.dir("iproj")
        t.write(proj + "/Package.swift", "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"r\")\n")
        let rv = await exec(executor, call("bash", ["command": "apply_patch <<'EOF'\n*** Begin Patch\n*** Add File: \(proj)/v.txt\n+x\n*** End Patch\nEOF"], editing: .gptJSON))
        t.check("I verification is injected once for an intercepted success",
                rv.content.components(separatedBy: ProjectInstructionsTracker.verificationMarkerPrefix).count == 2, rv.content)
        let notIntercepted = call("bash", ["command": "PATH=/usr/bin:/bin apply_patch --version"], editing: .gptJSON)
        let r127 = await exec(executor, notIntercepted)
        t.check("I a non-matching apply_patch command runs normally and gets the 127 note",
                r127.content.contains(GPTShellIntercept.notAShellCommandNote) && r127.editOutcome == nil, r127.content)
        let standardRun = await exec(executor, call("bash", ["command": "PATH=/usr/bin:/bin apply_patch --version"], editing: .standard))
        t.check("I a standard bash call gets no GPT note", !standardRun.content.contains(GPTShellIntercept.notAShellCommandNote))
    }

    // MARK: K — read-before-write ledger (§7, R3-1, F3, §21)

    static func ledgerTests(_ t: CPTest) async {
        await FileTimeTracker.shared.resetGPTForTesting()
        let executor = ToolExecutor()
        let d = t.dir("ledger")
        t.write(d + "/f.txt", "one\ntwo\n")
        let key = CodexPatch.evidenceKey(d + "/f.txt")
        let read = await exec(executor, call("read_file", ["path": d + "/f.txt"], editing: .gptJSON))
        t.check("K GPT read_file earns a receipt but publishes nothing before delivery",
                read.gptEvidence?.receipts.count == 1, String(describing: read.gptEvidence))
        let before = await FileTimeTracker.shared.gptRecord(forKey: key)
        t.check("K no GPT record until the result is committed", before == nil)
        t.check("K the standard record is written exactly as today", await FileTimeTracker.shared.standardSnapshotForTesting(path: d + "/f.txt") != nil)
        await GPTEvidenceSettlement.publish([read])
        t.check("K published after delivery", await FileTimeTracker.shared.gptRecord(forKey: key) != nil)
        let del = await exec(executor, call("apply_patch", ["input": "*** Begin Patch\n*** Delete File: \(d)/f.txt\n*** End Patch"], editing: .gptJSON))
        t.check("K Delete allowed with a fresh GPT record", del.editOutcome?.status == .applied && !t.exists(d + "/f.txt"), del.content)
        // P50: a zero-line read of a non-empty file earns nothing.
        t.write(d + "/g.txt", "only\n")
        let far = await exec(executor, call("read_file", ["path": d + "/g.txt", "offset": 50], editing: .gptJSON))
        t.check("K zero-line read earns no receipt (P50)", far.gptEvidence == nil)
        // A standard-stamped read never earns GPT evidence (F3, P46).
        let std = await exec(executor, call("read_file", ["path": d + "/g.txt"], editing: .standard))
        t.check("K standard read earns no GPT receipt", std.gptEvidence == nil)
        await GPTEvidenceSettlement.publish([std])
        let delStd = await exec(executor, call("apply_patch", ["input": "*** Begin Patch\n*** Delete File: \(d)/g.txt\n*** End Patch"], editing: .gptJSON))
        t.check("K a standard record never unlocks a GPT Delete (P46)", delStd.editOutcome?.category == .knowledge && t.exists(d + "/g.txt"), delStd.content)
        // Empty file read whole earns an empty-file record.
        t.write(d + "/empty.txt", "")
        let emptyRead = await exec(executor, call("read_file", ["path": d + "/empty.txt"], editing: .gptJSON))
        t.check("K empty file read whole earns a record", emptyRead.gptEvidence?.receipts.count == 1)
        // R3-1 / §21 note 1 / Codex S2 R1: the bytes and their identity come
        // from one descriptor; in-place change, replacement and an alias
        // retargeted away and back all earn nothing (P51).
        t.write(d + "/h.txt", "a\n")
        let ok = "{\"success\":true,\"returned_lines\":1}"
        GPTReadObservation.afterOpenHookForTesting = { path in
            if let fh = FileHandle(forWritingAtPath: path) { usleep(20_000); fh.seekToEndOfFile(); fh.write(Data("b\n".utf8)); fh.closeFile() }
        }
        let inPlace = await exec(executor, call("read_file", ["path": d + "/h.txt"], editing: .gptJSON))
        GPTReadObservation.afterOpenHookForTesting = nil
        t.check("K an in-place write between open and read earns nothing (P51)", inPlace.gptEvidence == nil, inPlace.content)
        do {
            let o = GPTReadObservation(path: d + "/h.txt")
            _ = try? o.readAll(d + "/h.txt")
            t.write(d + "/h.new", "c\n"); rename(d + "/h.new", d + "/h.txt")
            t.check("K replacement after the read earns nothing", ToolExecutor.gptReadReceipt(o, path: d + "/h.txt", resultContent: ok) == nil)
        }
        t.write(d + "/A.txt", "UNSEEN A\n"); t.write(d + "/B.txt", "OBSERVED B\n")
        symlink(d + "/A.txt", d + "/alias.txt")
        do {
            let o = GPTReadObservation(path: d + "/alias.txt")
            unlink(d + "/alias.txt"); symlink(d + "/B.txt", d + "/alias.txt")
            let bytes = (try? o.readAll(d + "/alias.txt")).map { String(decoding: $0, as: UTF8.self) }
            unlink(d + "/alias.txt"); symlink(d + "/A.txt", d + "/alias.txt")
            let receipt = ToolExecutor.gptReadReceipt(o, path: d + "/alias.txt", resultContent: ok)
            t.check("K alias retargeted away and back: B's bytes never credit unread A (Codex S2 R1)",
                    bytes == "OBSERVED B\n" && receipt == nil, "\(String(describing: bytes)) \(String(describing: receipt))")
            if let receipt { await GPTEvidenceSettlement(receipts: [receipt]).publish() }
            let delA = await exec(executor, call("apply_patch", ["input": "*** Begin Patch\n*** Delete File: \(d)/A.txt\n*** End Patch"], editing: .gptJSON))
            t.check("K …and unread A cannot be deleted", delA.editOutcome?.category == .knowledge && t.exists(d + "/A.txt"), delA.content)
        }
        do {
            t.write(d + "/t1.txt", "1\n")
            let o = GPTReadObservation(path: d + "/t1.txt")
            _ = try? o.readAll(d + "/t1.txt")
            t.check("K an unchanged read earns a receipt", ToolExecutor.gptReadReceipt(o, path: d + "/t1.txt", resultContent: ok) != nil)
            let unread = GPTReadObservation(path: d + "/t1.txt")
            t.check("K an observation that never read earns nothing", ToolExecutor.gptReadReceipt(unread, path: d + "/t1.txt", resultContent: ok) == nil)
        }
        // A published receipt whose path changed since is not published (§21 note 3).
        t.write(d + "/p.txt", "p\n")
        let pr = await exec(executor, call("read_file", ["path": d + "/p.txt"], editing: .gptJSON))
        usleep(20_000)
        t.write(d + "/p.txt", "changed later\n")
        await GPTEvidenceSettlement.publish([pr])
        t.check("K a receipt for a version that changed before delivery is not published",
                await FileTimeTracker.shared.gptRecord(forKey: CodexPatch.evidenceKey(d + "/p.txt")) == nil)
        // Codex S2 round 2: cancellation while publication waits for the
        // tracker earns nothing; an older record stays (single receipt queued
        // behind tracker work, and a result with forget + receipt).
        do {
            t.write(d + "/m1.txt", "m1\n"); t.write(d + "/m2.txt", "m2\n")
            let k1 = CodexPatch.evidenceKey(d + "/m1.txt"), k2 = CodexPatch.evidenceKey(d + "/m2.txt")
            guard let id1 = (try? FileIdentity.lstatPath(k1)) ?? nil, let id2 = (try? FileIdentity.lstatPath(k2)) ?? nil else {
                t.check("K publication fixture", false); return
            }
            await FileTimeTracker.shared.publishGPT(GPTEvidence.Receipt(key: k2, identity: id2, source: .shellRead))
            usleep(20_000); t.write(d + "/m1.txt", "m1 replaced\n")
            let newID1 = ((try? FileIdentity.lstatPath(k1)) ?? nil) ?? id1
            for (label, settlement) in [("single receipt", GPTEvidenceSettlement(receipts: [GPTEvidence.Receipt(key: k1, identity: newID1, source: .gptPatch)])),
                                        ("forget + receipt", GPTEvidenceSettlement(receipts: [GPTEvidence.Receipt(key: k1, identity: newID1, source: .gptPatch)], forget: [k2]))] {
                let gate = GateBox()
                FileTimeTracker.beforeGPTMutationHookForTesting = { await gate.wait() }
                var r = ToolResultMessage(toolCallId: "pub", content: "x"); r.gptEvidence = settlement
                let task = Task { await GPTEvidenceSettlement.publish([r]) }
                try? await Task.sleep(nanoseconds: 100_000_000)
                task.cancel()
                await gate.open()
                await task.value
                FileTimeTracker.beforeGPTMutationHookForTesting = nil
                let rec1 = await FileTimeTracker.shared.gptRecord(forKey: k1)
                let rec2 = await FileTimeTracker.shared.gptRecord(forKey: k2)
                t.check("K cancelled during publication (\(label)): nothing published, older record kept (Codex S2 round 2)",
                        rec1 == nil && rec2?.identity == id2 && rec2?.source == .shellRead,
                        "rec1 \(String(describing: rec1?.source)) rec2 \(String(describing: rec2?.source))")
            }
        }
        // P20: a GPT write never unlocks the standard edit_file.
        let addQ = await exec(executor, call("apply_patch", ["input": "*** Begin Patch\n*** Add File: \(d)/q.txt\n+q\n*** End Patch"], editing: .gptJSON))
        await GPTEvidenceSettlement.publish([addQ])
        let edit = await exec(executor, call("edit_file", ["path": d + "/q.txt", "old_string": "q", "new_string": "r"], editing: .standard))
        t.check("K a GPT patch record never unlocks edit_file (P20)", edit.content.contains("read_file") && t.read(d + "/q.txt") == "q\n", edit.content)
        t.check("K the GPT write left the standard store untouched (P35)", await FileTimeTracker.shared.standardSnapshotForTesting(path: d + "/q.txt") == nil)
        // Shell read crediting through the executor (exit 0, foreground, output).
        t.write(d + "/s.txt", "line\n")
        let sh = await exec(executor, call("bash", ["command": "cat \(d)/s.txt"], editing: .gptJSON))
        t.check("K a recognised single-file shell read earns a receipt", sh.gptEvidence?.receipts.first?.source == .shellRead, sh.content)
        let shStd = await exec(executor, call("bash", ["command": "cat \(d)/s.txt"], editing: .standard))
        t.check("K a standard bash read earns none", shStd.gptEvidence == nil)
        let shFail = await exec(executor, call("bash", ["command": "cat -- \(d)/missing.txt"], editing: .gptJSON))
        t.check("K a failed read earns none (P21)", shFail.gptEvidence == nil)
    }

    // MARK: H — shell-read recognizer table (§7, P47/P48)

    static func shellReadTests(_ t: CPTest) {
        let d = t.dir("shell")
        t.write(d + "/a.txt", "a\nb\n"); t.write(d + "/b.txt", "b\n"); t.write(d + "/sp ace.txt", "s\n"); t.write(d + "/e.txt", "")
        t.write(d + "/cr\r\nlf.txt", "x\n")
        try? FileManager.default.createDirectory(atPath: d + "/dir", withIntermediateDirectories: true)
        symlink(d + "/a.txt", d + "/ln.txt")
        let a = d + "/a.txt"
        let yes: [(String, String?)] = [
            ("cat \(a)", nil), ("cat -n \(a)", nil), ("cat -- \(a)", nil), ("cat -n -- \(a)", nil),
            ("nl -ba \(a)", nil), ("nl \(a)", nil), ("head \(a)", nil), ("head -n 20 \(a)", nil), ("head -5 \(a)", nil),
            ("tail -n 3 \(a)", nil), ("tail -3 \(a)", nil), ("sed -n '1,5p' \(a)", nil), ("sed -n 1,5p \(a)", nil), ("sed -n '3p' \(a)", nil),
            ("cat \(a) | head -n 5", nil), ("cat \(a) | nl -ba", nil), ("nl -ba \(a) | sed -n '1,9p'", nil),
            ("cat a.txt", d), ("head -n 2 a.txt", d), ("cat '\(d)/sp ace.txt'", nil), ("cat \"\(d)/sp ace.txt\"", nil),
            ("  cat \(a)  ", nil),
        ]
        for (command, workdir) in yes {
            t.check("H recognised: \(command.replacingOccurrences(of: d, with: "D"))\(workdir == nil ? "" : " (workdir)")",
                    GPTShellRead.target(command: command, workdir: workdir) != nil)
        }
        let no: [(String, String?)] = [
            ("cat \(a) \(d)/b.txt", nil), ("cat --help", nil), ("cat -A \(a)", nil), ("head -n 0 \(a)", nil), ("head -0 \(a)", nil),
            ("head -n x \(a)", nil), ("tail -f \(a)", nil), ("sed -i 's/a/b/' \(a)", nil), ("sed -n 's/a/b/p' \(a)", nil),
            ("sed -n '1,5p;6q' \(a)", nil), ("sed -n '0,5p' \(a)", nil), ("rg --files \(d)", nil), ("grep -q a \(a)", nil),
            ("grep a \(a)", nil), ("cat \(a) > /tmp/out", nil), ("cat \(a); rm \(a)", nil), ("cat \(a) && echo hi", nil),
            ("cat \(a) || true", nil), ("cat $(echo \(a))", nil), ("cat `echo \(a)`", nil), ("cat \(d)/*.txt", nil),
            ("cat \(a) | wc -l", nil), ("cat \(a) | head -n 2 | sort", nil), ("cat \(a) | head", nil), ("cat a.txt", nil),
            ("cat a.txt", "relative/dir"), ("cat \(d)/dir", nil), ("cat \(d)/ln.txt", nil), ("cat \(d)/missing.txt", nil),
            ("cat \"$HOME/x\"", nil), ("cat \(a)\ncat \(a)", nil), ("(cat \(a))", nil), ("cat ~/x", nil), ("less \(a)", nil),
            ("cat", nil), ("", nil), ("head -n", nil), ("nl -b a \(a)", nil),
            // 0.2.71 Linux audit: a CRLF Character still makes the command multi-line.
            ("cat \(a)\r\ncat \(a)", nil), ("cat \(d)/cr\r\nlf.txt", nil), ("cat \(a)\rcat \(a)", nil),
        ]
        for (command, workdir) in no {
            let shown = command.replacingOccurrences(of: d, with: "D").unicodeScalars
                .map { $0 == "\n" ? "⏎" : $0 == "\r" ? "␍" : String($0) }.joined()
            t.check("H not recognised: \(shown)",
                    GPTShellRead.target(command: command, workdir: workdir) == nil)
        }
        t.check("H table size ≥ 40", yes.count + no.count >= 40)
        // Crediting conditions.
        guard let before = (try? FileIdentity.lstatPath(a)) ?? nil, let emptyID = (try? FileIdentity.lstatPath(d + "/e.txt")) ?? nil else {
            t.check("H fixture identities", false); return
        }
        func result(_ exit: Int, _ stdout: String, handle: Bool = false) -> String {
            var o: [String: Any] = ["exit_code": exit, "stdout": stdout, "stderr": "", "status": "exited", "handle": "bash_1"]
            if handle { o = ["status": "running", "handle": "bash_1", "stdout": stdout] }
            return String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self)
        }
        t.check("H credited: exit 0 with output", GPTShellRead.receipt(path: a, before: before, command: "cat \(a)", resultContent: result(0, "a\n"), placeholders: []) != nil)
        t.check("H not credited: exit ≠ 0 (P21)", GPTShellRead.receipt(path: a, before: before, command: "cat \(a)", resultContent: result(1, "a\n"), placeholders: []) == nil)
        t.check("H not credited: empty output from a non-empty file (P48)",
                GPTShellRead.receipt(path: a, before: before, command: "sed -n '9,10p' \(a)", resultContent: result(0, ""), placeholders: []) == nil)
        t.check("H not credited: moved to the background (handle)", GPTShellRead.receipt(path: a, before: before, command: "cat \(a)", resultContent: result(0, "a\n", handle: true), placeholders: []) == nil)
        t.check("H credited: empty file read whole with plain cat", GPTShellRead.receipt(path: d + "/e.txt", before: emptyID, command: "cat \(d)/e.txt", resultContent: result(0, ""), placeholders: []) != nil)
        t.check("H not credited: empty file through head", GPTShellRead.receipt(path: d + "/e.txt", before: emptyID, command: "head -n 1 \(d)/e.txt", resultContent: result(0, ""), placeholders: []) == nil)
        usleep(20_000)
        t.write(a, "changed\n")
        t.check("H not credited: the file changed during the command", GPTShellRead.receipt(path: a, before: before, command: "cat \(a)", resultContent: result(0, "a\n"), placeholders: []) == nil)
    }
}
