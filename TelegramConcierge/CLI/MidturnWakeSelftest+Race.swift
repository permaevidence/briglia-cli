import Foundation

/// R1 race rows (§6 R1): finish vs wake vs timeout vs cancellation on the
/// registry actor, 2,400 waiter resolutions with jitter. A double
/// resumption would trap (CheckedContinuation); every waiter must resolve
/// exactly once and every job must end with at most one queued notice.
extension MidturnHarness {

    func raceSection() async {
        await resetState()
        let registry = BackgroundProcessRegistry.shared
        let savedGrace = TurnWakeCenter.graceSecondsForTesting
        TurnWakeCenter.graceSecondsForTesting = 0.08
        defer { TurnWakeCenter.graceSecondsForTesting = savedGrace }
        var resolved = 0
        var outcomes: [String: Int] = [:]
        var duplicateNotices = 0
        var lostJobs = 0
        let rounds = 24, perRound = 100
        for round in 0..<rounds {
            let run = UUID()
            await TurnWakeCenter.shared.arm(runId: run)
            var handles: [String] = []
            for _ in 0..<perRound {
                let delay = Double.random(in: 0...0.2)
                if let h = try? await registry.start(command: "sleep \(String(format: "%.3f", delay))", workdir: nil, description: nil) {
                    handles.append(h.id)
                }
            }
            let fireAt = Double.random(in: 0...0.1)
            let fire = Task {
                try? await Task.sleep(nanoseconds: UInt64(fireAt * 1e9))
                await TurnWakeCenter.shared.fire(runId: run, generation: UInt64(round + 1))
            }
            let results: [String] = await withTaskGroup(of: String.self) { group in
                for (i, handle) in handles.enumerated() {
                    let cancelAfter: Double? = i % 4 == 3 ? Double.random(in: 0...0.2) : nil
                    let timeout = UInt64(Double.random(in: 0.05...0.35) * 1e9)
                    group.addTask {
                        let context = WakeContext(turnRunId: run, callId: "race-\(i)", toolName: "bash", fingerprint: "",
                                                  callStartedAt: .now, historyAnchorMessageId: nil)
                        let waiter = Task { await registry.awaitSettlement(handleId: handle, timeoutNanos: timeout, wake: context) }
                        if let cancelAfter {
                            try? await Task.sleep(nanoseconds: UInt64(cancelAfter * 1e9))
                            waiter.cancel()
                        }
                        switch await waiter.value {
                        case .settled: return "settled"
                        case .waitTimedOut: return "timeout"
                        case .cancelled: return "cancelled"
                        case .woken: return "woken"
                        case .refusedDuplicate: return "duplicate"
                        case .unknownHandle: return "unknown"
                        }
                    }
                }
                var all: [String] = []
                for await r in group { all.append(r) }
                return all
            }
            _ = await fire.value
            resolved += results.count
            for r in results { outcomes[r, default: 0] += 1 }
            // Every job settles; at most one notice each.
            _ = await waitUntil(timeout: 10) { await registry.runningMainOwnedJobs().isEmpty }
            let pending = await registry.pendingCompletionsForDelivery()
            let perJob = Dictionary(grouping: pending, by: \.jobUUID)
            duplicateNotices += perJob.values.filter { $0.count > 1 }.count
            lostJobs += max(0, handles.count - perJob.count)
            _ = await registry.purgeAllForWipe()
        }
        await TurnWakeCenter.shared.disarm()
        check("RACE1 \(resolved) waiter resolutions (finish/timeout/wake/cancel with jitter), each exactly once",
              resolved == rounds * perRound && outcomes["duplicate", default: 0] == 0 && outcomes["unknown", default: 0] == 0,
              "\(outcomes)")
        check("RACE2 every raced job ends with exactly one queued notice (none lost, none doubled)",
              duplicateNotices == 0 && lostJobs == 0, "dup \(duplicateNotices), lost \(lostJobs)")
        check("RACE3 all four outcomes occurred (the race was real)",
              ["settled", "woken", "cancelled"].allSatisfy { outcomes[$0, default: 0] > 0 }, "\(outcomes)")
    }
}
