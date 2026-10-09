import Foundation

/// Race and scope rows (plan v2 §2.5 R6, R7, R9) and the subagent (R8).
extension MidturnHarness {

    func irRaceSection() async throws {
        try await irMidTurnArrival()
        try await irMidTurnDrainedArrival()
        try await irStopRace()
        try await irPDFPages()
    }

    /// R6: a user message with an image that arrives while the rejected
    /// request is in flight is not part of that request and is never marked.
    private func irMidTurnArrival() async throws {
        let (manager, _) = await irFresh()
        let path = irFile("R6.png", IRFixtures.png)
        let lateName = irUserImage("R6-late.jpg", IRFixtures.jpeg)
        let late = Message(role: .user, content: "R6 also look at this", imageFileNames: [lateName])
        server.script([
            tools([(id: "R6-read", name: "read_file", args: ["path": path])], responses: false),
            Self.irRejection(responses: false), text("R6 done", responses: false), text("R6 follow-up", responses: false),
        ], statuses: [200, 400, 200, 200])
        let png = irBase64(IRFixtures.png)
        var dispatched = false
        server.requestObserver = { request in
            guard !dispatched, String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/").contains(png) else { return }
            dispatched = true
            Task { @MainActor in await manager._testDispatchUser(late) }
            Thread.sleep(forTimeInterval: 0.6)
        }
        manager._testSetPolling(true)   // the follow-up turn for queued messages
        manager._testStartTurn(for: user("R6 read"))
        _ = await manager._testAwaitIdle(timeout: 30)
        _ = await waitUntil(timeout: 10) { !manager._testIsActive && manager._testQueue.isEmpty }
        _ = await manager._testAwaitIdle(timeout: 30)
        server.requestObserver = nil
        let lateMessage = manager._testMessages.first { $0.id == late.id }
        let bodies = irRequestBodies()
        check("R6 the mid-turn image was not marked; it still reaches a later request",
              dispatched && lateMessage != nil && lateMessage?.providerRejectedImageFileNames.isEmpty == true
                && bodies.dropFirst(2).contains { $0.contains(irBase64(IRFixtures.jpeg)) },
              "dispatched \(dispatched) found \(lateMessage != nil) requests \(bodies.count)")
    }

    /// R6b: a user message with an image that arrived while the round's
    /// tools ran is drained into that round (its history copy is canonical
    /// and the rejected request carries it as a typed delivery, not as an
    /// image part): recovery never marks it.
    private func irMidTurnDrainedArrival() async throws {
        let (manager, _) = await irFresh()
        let path = irFile("R6b.png", IRFixtures.png)
        let lateName = irUserImage("R6b-late.jpg", IRFixtures.jpeg)
        let late = Message(role: .user, content: "R6b also this one", imageFileNames: [lateName])
        server.script([
            tools([(id: "R6b-read", name: "read_file", args: ["path": path]),
                   (id: "R6b-wait", name: "bash", args: ["command": "sleep 1.5"])], responses: false),
            Self.irRejection(responses: false), text("R6b done", responses: false), text("R6b follow-up", responses: false),
        ], statuses: [200, 400, 200, 200])
        var first = true
        server.requestObserver = { _ in
            guard first else { return }
            first = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                await manager._testDispatchUser(late)
            }
        }
        manager._testSetPolling(true)
        manager._testStartTurn(for: user("R6b read and wait"))
        _ = await manager._testAwaitIdle(timeout: 30)
        _ = await waitUntil(timeout: 10) { !manager._testIsActive && manager._testQueue.isEmpty }
        _ = await manager._testAwaitIdle(timeout: 30)
        server.requestObserver = nil
        let lateMessage = manager._testMessages.first { $0.id == late.id }
        let bodies = irRequestBodies()
        let delivered = bodies.count >= 2 && bodies[1].contains("R6b also this one")
        check("R6b a message drained into the rejected round keeps its image unmarked",
              lateMessage != nil && lateMessage?.providerRejectedImageFileNames.isEmpty == true
                && manager._testMessages.contains { $0.providerRejectedImageFileNames.isEmpty == false } == false,
              "drained into the rejected request \(delivered) found \(lateMessage != nil) requests \(bodies.count)")
    }

    /// R7: /stop landing between the rejection and the commit → nothing
    /// written, no resend, no notice.
    private func irStopRace() async throws {
        for responses in [false, true] {
            let restore: (() -> Void)? = responses ? try useResponses() : nil
            let tag = responses ? "R7r" : "R7"
            let (manager, channel) = await irFresh()
            let path = irFile("\(tag).png", IRFixtures.png)
            server.script([
                tools([(id: "\(tag)-read", name: "read_file", args: ["path": path])], responses: responses),
                Self.irRejection(responses: responses), text("never", responses: responses),
            ], statuses: [200, 400, 200])
            ImageRejectionRecovery.beforeCommitForTesting = { await manager._testStop() }
            manager._testStartTurn(for: user("\(tag) read"))
            _ = await manager._testAwaitIdle(timeout: 30)
            ImageRejectionRecovery.beforeCommitForTesting = nil
            check("\(tag) /stop before the commit: no mark written, no resend, no notice",
                  irRequestBodies().count == 2 && !irSavedConversation().contains("providerRejected") && irNotices(channel).isEmpty,
                  "requests \(irRequestBodies().count)")
            restore?()
        }
    }

    /// R9: a PDF rendered to page images inside the rejected request is
    /// excluded as a whole attachment (all pages), and noted.
    private func irPDFPages() async throws {
        for responses in [false, true] {
            let restore: (() -> Void)? = responses ? try useResponses() : nil
            let tag = responses ? "R9r" : "R9"
            let (manager, _) = await irFresh()
            let path = irFile("\(tag).pdf", IRFixtures.pdf())
            server.script([
                tools([(id: "\(tag)-read", name: "read_file", args: ["path": path])], responses: responses),
                Self.irRejection(responses: responses), text("\(tag) done", responses: responses),
            ], statuses: [200, 400, 200])
            manager._testStartTurn(for: user("\(tag) read the pdf"))
            _ = await manager._testAwaitIdle(timeout: 60)
            let bodies = irRequestBodies()
            let refs = manager._testMessages.flatMap { $0.toolInteractions.flatMap(\.results) }.flatMap(\.fileAttachmentReferences)
            check("\(tag) rendered PDF pages in the rejected request → the whole PDF excluded and noted in the retry",
                  bodies.count == 3 && bodies[1].contains("data:image/") && !bodies[2].contains("data:image/")
                    && !bodies[2].contains("application/pdf;base64") && bodies[2].contains(ModelImage.rejectedNote(path: path))
                    && refs.contains { $0.mimeType == "application/pdf" && $0.providerRejected == true },
                  "requests \(bodies.count)")
            restore?()
        }
    }

    /// R8: subagent recovery persists through its session before the
    /// resend; a session write failure fails the subagent run as today.
    func irSubagentSection() async throws {
        for failing in [false, true] {
            let tag = failing ? "R8f" : "R8"
            let (manager, _) = await irFresh()
            ToolExecutor.detachEligibilityOverrideForTesting = { _ in false }
            if failing { SubagentSessionRegistry.imageRejectionPersistFaultForTesting = { throw IRInjected() } }
            let path = irFile("\(tag).png", IRFixtures.png)
            var script = [
                Self.chatTools([(id: "\(tag)-agent", name: "Agent", args: Self.agentArgs(description: "look", prompt: "\(tag) read the image"))]),
                Self.chatTools([(id: "\(tag)-sub-read", name: "read_file", args: ["path": path])]),
                IRFixtures.openAIChatBMP,
            ]
            var statuses = [200, 200, 400]
            if !failing { script.append(Self.chatText("\(tag) sub done")); statuses.append(200) }
            script.append(Self.chatText("\(tag) main done")); statuses.append(200)
            server.script(script, statuses: statuses)
            manager._testStartTurn(for: user("\(tag) delegate"))
            _ = await manager._testAwaitIdle(timeout: 60)
            SubagentSessionRegistry.imageRejectionPersistFaultForTesting = nil
            ToolExecutor.detachEligibilityOverrideForTesting = nil
            let bodies = irRequestBodies()
            let image = irBase64(IRFixtures.png)
            let sessions = (try? FileManager.default.contentsOfDirectory(at: StoragePaths.dataRoot.appendingPathComponent("subagent_sessions"),
                                                                         includingPropertiesForKeys: nil)) ?? []
            let sessionText = sessions.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
            if failing {
                let agentResult = manager._testMessages.flatMap { $0.toolInteractions.flatMap(\.results) }.first { $0.toolCallId == "\(tag)-agent" }
                check("R8 session write failed: no subagent resend; the run fails as today; the main turn continues",
                      bodies.count == 4 && agentResult != nil && manager._testMessages.last?.content == "\(tag) main done"
                        && !sessionText.contains("providerRejected"), "requests \(bodies.count)")
            } else {
                check("R8 subagent: marked and saved in its session before the resend; retry without the image; no tool re-run",
                      bodies.count == 5 && bodies[2].contains(image) && !bodies[3].contains(image)
                        && sessionText.contains("providerRejected") && manager._testMessages.last?.content == "\(tag) main done",
                      "requests \(bodies.count)")
            }
        }
    }
}
