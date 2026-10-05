import Foundation

/// Pure / near-pure rows: the two grace predicates (SV4c), the retry
/// schedule, stage refinement (SV14), archive phase markers (SV15b).
extension StopVisibilityHarness {

    func unitSection() async {
        await gracePredicateRows()
        retryScheduleRows()
        await archivePhaseMarkerRows()
    }

    /// SV4c: Bash confirmation keeps its own 3 s window; the turn
    /// observation has its own 2.5 s window; no captured turn → no wait.
    private func gracePredicateRows() async {
        final class FakeTime { var t: TimeInterval = 100; var pauses = 0 }
        let job = UUID()

        // Bash settling at 2.7 s is still confirmed (a single min(3, 2.5)
        // deadline would cut it at 2.5 s).
        do {
            let time = FakeTime()
            let left = await ConversationManager.observeStopGrace(
                bashJobs: [job],
                isSettled: { _ in time.t - 100 >= 2.7 },
                turnEnded: { true },
                now: { time.t },
                pause: { time.t += 0.05; time.pauses += 1 })
            check("SV4c Bash settling at 2.7 s is confirmed exactly as before (own 3 s window)", left.isEmpty,
                  "unconfirmed \(left.count), elapsed \(time.t - 100)")
        }
        // The turn observation stops at 2.5 s even though Bash is done.
        do {
            let time = FakeTime()
            _ = await ConversationManager.observeStopGrace(
                bashJobs: [], isSettled: { _ in true }, turnEnded: { false },
                now: { time.t }, pause: { time.t += 0.05; time.pauses += 1 })
            let waited = time.t - 100
            check("SV4c a turn that never ends adds at most 2.5 s of observation", waited >= 2.45 && waited <= 2.56,
                  "waited \(waited)")
        }
        // No captured task → no added wait at all.
        do {
            let time = FakeTime()
            _ = await ConversationManager.observeStopGrace(
                bashJobs: [], isSettled: { _ in true }, turnEnded: nil,
                now: { time.t }, pause: { time.t += 0.05; time.pauses += 1 })
            check("SV4c no captured turn and no Bash: no wait (0 pauses)", time.pauses == 0, "pauses \(time.pauses)")
        }
        // A turn that ends at 0.3 s ends the observation early.
        do {
            let time = FakeTime()
            _ = await ConversationManager.observeStopGrace(
                bashJobs: [], isSettled: { _ in true }, turnEnded: { time.t - 100 >= 0.3 },
                now: { time.t }, pause: { time.t += 0.05; time.pauses += 1 })
            let waited = time.t - 100
            check("SV4c the observation ends as soon as the turn ended", waited >= 0.3 && waited < 0.4, "waited \(waited)")
        }
        // Bash still unconfirmed at 3 s stays reported, turn already ended.
        do {
            let time = FakeTime()
            let left = await ConversationManager.observeStopGrace(
                bashJobs: [job], isSettled: { _ in false }, turnEnded: { true },
                now: { time.t }, pause: { time.t += 0.05; time.pauses += 1 })
            let waited = time.t - 100
            check("SV4c an unconfirmed Bash job is still waited for 3 s and reported", left == [job] && waited >= 2.95 && waited <= 3.06,
                  "left \(left.count), waited \(waited)")
        }
    }

    private func retryScheduleRows() {
        let pauses = (1...10).map { NoticeSeries.pauseSeconds(afterFailedAttempt: $0) }
        check("series retries: 2 s, 4 s (like sendText), then 30, 60, 120 … capped at 600 s",
              pauses == [2, 4, 30, 60, 120, 240, 480, 600, 600, 600], "\(pauses)")
    }

    /// SV15b: archive phase markers pair up on begin/end and on re-begin.
    private func archivePhaseMarkerRows() async {
        let manager = await freshManager()
        func open(_ name: String) -> Int { StageMarkers.openStages().filter { $0.stage == name }.count }
        manager._svArchivePhase(.consolidating, began: true)
        let afterBegin = open("archive.phase.consolidating")
        let noCall = StageMarkers.openStages().first { $0.stage == "archive.phase.consolidating" }.map { $0.callId == nil } ?? false
        manager._svArchivePhase(.consolidating, began: true)   // re-begin
        let afterRebegin = open("archive.phase.consolidating")
        manager._svArchivePhase(.consolidating, began: false)
        let afterEnd = open("archive.phase.consolidating")
        manager._svArchivePhase(.extractingUserContext, began: true)
        manager._svArchivePhase(.restructuringUserContext, began: true)
        let both = open("archive.phase.extract") + open("archive.phase.restructure")
        manager._svArchivePhase(.extractingUserContext, began: false)
        manager._svArchivePhase(.restructuringUserContext, began: false)
        let none = StageMarkers.openStages().filter { $0.stage.hasPrefix("archive.") }.count
        check("SV15b archive phase markers: begin opens one, re-begin closes the stale one, end closes it",
              afterBegin == 1 && afterRebegin == 1 && afterEnd == 0 && both == 2 && none == 0,
              "begin \(afterBegin), re-begin \(afterRebegin), end \(afterEnd), extract+restructure \(both), left \(none)")
        check("SV15b archive phase markers carry no call id (process-wide diagnostics)", noCall)
        check("SV15b the banner entries still pair as before",
              manager.maintenanceActivities.isEmpty, "\(manager.maintenanceActivities.count) left")
    }
}
