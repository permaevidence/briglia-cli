import Foundation

/// Run ownership (T7, Codex acceptance check 2): a /stop and a newer turn
/// interleaving AFTER an append — at the user-drain awaits of the old run —
/// never lets the old run overwrite the newer run's recovery file, drop or
/// acknowledge the newer run's items; the old run keeps its appended result
/// through its own interrupted-outcome path.
extension MidturnHarness {

    func roundRunOwnershipSection() async throws {
        let manager = await roundFresh()
        server.concurrent = true
        var oldRun: UUID?
        var appends = 0
        var newRunAppended = false
        var newItemKeptAtOldTeardown = false
        var newItem: UUID?
        // R1 appends job A; inside R1's drain: /stop + a newer turn R2. R2
        // appends job B and — still holding B only in its local round, not
        // yet stored — waits there until R1 has torn down.
        ConversationManager.roundDeliveryInterleaveForTesting = { stage in
            guard stage == "after-append" else { return }
            appends += 1
            if appends == 1 {
                oldRun = manager._testActiveRunId
                await manager._testStop()
                self.server.script([
                    Self.chatTools([Self.bgCall("t7-b", "sleep 0.1; echo T7_B"), Self.fgCall("t7-r2-fg", "sleep 1.2")]),
                    Self.chatText("t7 R2 final"),
                ])
                manager._testStartTurn(for: self.user("T7 newer turn"))
                _ = await self.waitUntil(timeout: 15) { newRunAppended }
            } else if appends == 2 {
                newRunAppended = true
                newItem = manager._testRoundReservations.values.first { $0.runId != oldRun }?.messageId
                // R1 has torn down once its interrupted outcome is saved and
                // its own reservations are resolved or released.
                _ = await self.waitUntil(timeout: 15) {
                    manager._testMessages.contains { $0.content.hasPrefix("⛔ Work interrupted") }
                        && !manager._testRoundReservations.values.contains { $0.runId == oldRun && $0.state == .reserved }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                newItemKeptAtOldTeardown = newItem.map { manager._testRoundReservations[$0] != nil } ?? false
            }
        }
        server.script([Self.chatTools([Self.bgCall("t7-a", "sleep 0.1; echo T7_A"), Self.fgCall("t7-r1-fg", "sleep 1.2")])])
        manager._testStartTurn(for: user("T7 old turn"))
        _ = await waitUntil(timeout: 30) { appends >= 2 && newItem != nil }
        _ = await manager._testAwaitIdle(timeout: 30)
        ConversationManager.roundDeliveryInterleaveForTesting = nil
        check("T7a the newer run appended its own item while the old run was unwinding", newRunAppended && newItem != nil)
        check("T7b the old run never overwrote the newer run's recovery file (write refused)", manager._testSalvageRefusals >= 1,
              "refusals \(manager._testSalvageRefusals)")
        check("T7c the old run's teardown left the newer run's reservation intact", newItemKeptAtOldTeardown)
        let bodies = carriers(manager).map(\.content)
        let a = bodies.filter { $0.contains("[BACKGROUND BASH COMPLETE]") && $0.contains("echo T7_A") }.count
        let b = bodies.filter { $0.contains("[BACKGROUND BASH COMPLETE]") && $0.contains("echo T7_B") }.count
        check("T7d the old run's result (A) kept in its interrupted outcome; the newer run's (B) in its round; each once",
              a == 1 && b == 1 && carriers(manager).count == 2, "A \(a) B \(b) carriers \(carriers(manager).count)")
        check("T7e both acknowledged", await roundSettled(manager))
        await manager._testIdleDrains()
        check("T7f no idle notice for A or B", !manager._testMessages.contains { $0.kind == .bashComplete })
        server.concurrent = false
    }
}
