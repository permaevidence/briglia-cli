import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The AgentMail repair transaction (security plan v14 §7.8.1 "Explicit
/// repair", v23 §7.9.2 probe mode). Owner rule: a failed or interrupted
/// repair leaves AgentMail OFF until a repair succeeds; Briglia never falls
/// back to an older copy. The hold is written at R1 before anything changes
/// and removed only by a successful repair (e3).
enum AgentMailRepair {
    enum Result: Equatable, CustomStringConvertible {
        case nothingToRepair
        case repaired(String)
        case failed(String)
        case busy(String)
        case throttled(String)
        var description: String {
            switch self {
            case .nothingToRepair: return "nothing to repair"
            case .repaired(let v): return "repaired (AgentMail CLI \(v))"
            case .failed(let w): return "failed: \(w)"
            case .busy(let w): return "busy: \(w)"
            case .throttled(let w): return "not attempted: \(w)"
            }
        }
    }

    static func run(spec: RuntimeSpec, automatic: Bool, idle: RuntimeIdleGate?,
                    progress: (@Sendable (String) -> Void)? = nil) async -> Result {
        let c = RuntimeComponent.agentmail
        // R0 + R1 under both locks.
        let attempt: RuntimeAttempt
        let priorCurrent: String?
        let snapshotVerified: String?
        let journalBytes: Data?
        let generation: Int
        do {
            let locks = try RuntimeLocks.take(c)
            defer { locks.release() }
            let (loaded, corrupted) = try RuntimeSelectionStore.load()
            var sel = loaded
            let health = await PrivateRuntimeEngine.recoverLocked(spec, &sel, selectionCorrupted: corrupted)
            try PrivateRuntimeEngine.commitRecovered(spec, &sel)
            if case .ready(let r) = health, r.pin == spec.pin, sel[c].hold == nil {
                return .nothingToRepair
            }
            var st = sel[c]
            if let live = PrivateRuntimeEngine.liveForeignAttempt(st) {
                return .busy("another Briglia process is installing or repairing AgentMail (attempt \(live.attemptId.prefix(8)))")
            }
            if automatic, let last = st.latestAutoAttempt, last.result != "converged",
               Date().timeIntervalSince(last.startedAt) < PrivateRuntimeEngine.throttle {
                return .throttled("last automatic attempt under an hour ago")
            }
            // v14: the automatic repair is only for a NEW pin (held pin ≠ compiled pin).
            if automatic, let hold = st.hold, hold.pin == spec.pin {
                return .throttled("the hold is for this pin: only an explicit repair acts")
            }
            priorCurrent = PrivateRuntimeEngine.rawCurrent(c)
            snapshotVerified = ((try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c))) ?? nil)?.verified
            journalBytes = RuntimeFS.kind(RuntimePaths.journal(c).path) == .regular ? try? Data(contentsOf: RuntimePaths.journal(c)) : nil
            generation = sel.generation
            attempt = PrivateRuntimeEngine.newAttempt(spec, kind: automatic ? "repair-auto" : "repair", generation: generation)
            st.attempts.append(attempt)
            st.hold = RuntimeHold(pin: spec.pin, reason: "repair-in-progress", since: Date(), attemptId: attempt.attemptId)
            st.mirror = nil
            sel[c] = st
            try PrivateRuntimeEngine.commitRecovered(spec, &sel)   // one atomic write: attempt + hold
            RuntimeSeams.crash(c, "repair-after-hold")
        } catch {
            return .failed("repair could not start: \(error)")
        }

        func setHold(_ reason: String, result: String) {
            _ = try? RuntimeSelectionStore.update { sel in
                var st = sel[c]
                PrivateRuntimeEngine.finishAttempt(&st, attempt.attemptId, result: result, onlyIfUnset: false)
                if var h = st.hold, h.attemptId == attempt.attemptId { h.reason = reason; st.hold = h }
                sel[c] = st
            }
        }

        // R2 stage (same as an ordinary update; placeholder-only staged probe).
        let staging = RuntimePaths.staging(c, attempt: attempt.attemptId)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        let identity: String
        do {
            try PrivateStorage.ensureDirectory(staging)
            _ = try await spec.stage(payload, progress)
            try RuntimeFS.restrictTree(payload)
            guard let h = RuntimeFS.sha256(file: payload.appendingPathComponent(spec.binaryRelPath)) else {
                throw RuntimeError("the staged copy lacks \(spec.binaryRelPath)")
            }
            identity = h
        } catch {
            try? RuntimeFS.removeTree(staging)
            setHold("repair-failed", result: "failed: \((error as? RuntimeError)?.description ?? error.localizedDescription)")
            return .failed("\(error)")
        }
        RuntimeSeams.crash(c, "repair-after-stage")

        // R3 commit, under both locks, while idle.
        if let idle, !(await idle.acquire()) {
            try? RuntimeFS.removeTree(staging)
            setHold("repair-interrupted", result: "abandoned")
            return .failed("Briglia did not become idle; AgentMail stays off until a repair succeeds")
        }
        let result = await commit(spec, attempt, priorCurrent, snapshotVerified, journalBytes, generation, staging, payload, identity, idle)
        if let idle { await idle.release() }
        return result
    }

    private static func commit(_ spec: RuntimeSpec, _ attempt: RuntimeAttempt, _ priorCurrent: String?,
                               _ snapshotVerified: String?, _ journalBytes: Data?, _ generation: Int,
                               _ staging: URL, _ payload: URL, _ identity: String, _ idle: RuntimeIdleGate?) async -> Result {
        let c = RuntimeComponent.agentmail
        do {
            let locks = try RuntimeLocks.take(c)
            defer { locks.release() }
            var (sel, _) = try RuntimeSelectionStore.load()
            var receipt = try RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(c)) ?? RuntimeReceipt()
            let nowJournal: Data? = RuntimeFS.kind(RuntimePaths.journal(c).path) == .regular ? try? Data(contentsOf: RuntimePaths.journal(c)) : nil
            let stillWanted = await (idle?.stillWanted() ?? true)
            guard stillWanted, sel.generation == generation, PrivateRuntimeEngine.rawCurrent(c) == priorCurrent,
                  receipt.verified == snapshotVerified, nowJournal == journalBytes,
                  sel[c].hold?.attemptId == attempt.attemptId else {
                try? RuntimeFS.removeTree(staging)
                var st = sel[c]
                PrivateRuntimeEngine.finishAttempt(&st, attempt.attemptId, result: "abandoned", onlyIfUnset: false)
                if var h = st.hold, h.attemptId == attempt.attemptId { h.reason = "repair-interrupted"; st.hold = h }
                sel[c] = st
                try RuntimeSelectionStore.save(sel)
                return .failed("the installation changed during the repair; AgentMail stays off — run the repair again")
            }
            // (p1a) the new destination (never an existing path).
            guard let dest = PrivateRuntimeEngine.freshDirectoryName(spec) else { throw RuntimeError("no free version directory name") }
            try PrivateStorage.ensureDirectory(RuntimePaths.versions(c))
            guard rename(payload.path, RuntimePaths.dir(c).appendingPathComponent(dest).path) == 0 else {
                throw RuntimeError("could not publish \(dest): \(String(cString: strerror(errno)))")
            }
            try PrivateStorage.fsyncDirectory(RuntimePaths.versions(c).path)
            try? RuntimeFS.removeTree(staging)
            RuntimeSeams.crash(c, "repair-after-p1a")
            // (p1b) its record (not verified).
            let record = RuntimeRecord(triple: spec.pin.triple, version: spec.pin.version, archiveSHA256: spec.pin.archiveSHA256,
                                       binarySHA256: identity, directory: dest, installedAt: Date())
            receipt.records.append(record)
            try RuntimeFS.writeJSON(receipt, RuntimePaths.receipt(c))
            RuntimeSeams.crash(c, "repair-after-p1b")
            // (p2) retire an existing journal by copy.
            var retired: String?
            if let jb = journalBytes {
                try PrivateStorage.ensureDirectory(RuntimePaths.retired(c))
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                let name = "tx-\(stamp)-\(attempt.attemptId.prefix(12)).json"
                try PrivateStorage.writeAtomically(jb, to: RuntimePaths.retired(c).appendingPathComponent(name), mode: 0o600)
                retired = "retired/\(name)"
                pruneRetired()
            }
            RuntimeSeams.crash(c, "repair-after-p2")
            // (p3) the repair journal replaces tx.json in one rename.
            var j = RuntimeJournal(attemptId: attempt.attemptId, oldTarget: nil, newTarget: dest, newRecord: record,
                                   state: "committing", mode: "repair", priorCurrent: priorCurrent, retired: retired)
            try RuntimeFS.writeJSON(j, RuntimePaths.journal(c))
            RuntimeSeams.crash(c, "repair-after-p3")
            // (p4) the switch.
            try RuntimeFS.switchLink(RuntimePaths.current(c), to: dest)
            RuntimeSeams.crash(c, "repair-after-p4")
            // (p5) probe through the wrapper (journal-bound probe mode; the matching hold is permitted).
            if let why = await spec.postProbe(j) {
                // (r1) no link; (r2) result + hold reason; (r3) journal gone.
                try RuntimeFS.remove(RuntimePaths.current(c))
                var st = sel[c]
                PrivateRuntimeEngine.finishAttempt(&st, attempt.attemptId, result: "failed: probe (\(why))", onlyIfUnset: false)
                if var h = st.hold, h.attemptId == attempt.attemptId { h.reason = "repair-failed"; st.hold = h }
                sel[c] = st
                try RuntimeSelectionStore.save(sel)
                try RuntimeFS.remove(RuntimePaths.journal(c))
                return .failed("the repaired copy failed its check (\(why)); AgentMail stays off")
            }
            // (p5') probed.
            j.state = "probed"
            try RuntimeFS.writeJSON(j, RuntimePaths.journal(c))
            RuntimeSeams.crash(c, "repair-after-probed")
            // (e1) verified.
            receipt.verified = dest
            try RuntimeFS.writeJSON(receipt, RuntimePaths.receipt(c))
            RuntimeSeams.crash(c, "repair-after-e1")
            // (e2) mirror, (e3) result + hold removed (one write).
            var st = sel[c]
            st.mirror = record
            PrivateRuntimeEngine.finishAttempt(&st, attempt.attemptId, result: "converged", onlyIfUnset: false)
            st.hold = nil
            sel[c] = st
            try RuntimeSelectionStore.save(sel)
            RuntimeSeams.crash(c, "repair-after-e3")
            // (f)
            try RuntimeFS.remove(RuntimePaths.journal(c))
            try? AgentMailService.ensureWrapper()
            return .repaired(spec.pin.version)
        } catch {
            _ = try? RuntimeSelectionStore.update { sel in
                var st = sel[c]
                PrivateRuntimeEngine.finishAttempt(&st, attempt.attemptId, result: "failed: \(error)", onlyIfUnset: true)
                if var h = st.hold, h.attemptId == attempt.attemptId, h.reason == "repair-in-progress" { h.reason = "repair-interrupted"; st.hold = h }
                sel[c] = st
            }
            return .failed("\(error); AgentMail stays off until a repair succeeds")
        }
    }

    static func pruneRetired() {
        let dir = RuntimePaths.retired(.agentmail)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("tx-") }.sorted()
        for name in names.dropLast(PrivateRuntimeEngine.retiredKept) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
