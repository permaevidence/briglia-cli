import Foundation

/// Recovery rows on the real manager and the scripted loopback provider
/// (plan v2 §2.5 R1, R2, R10, R11), both protocols. Every row checks the
/// immediate retry AND a later request (in memory and after a restart).
extension MidturnHarness {

    func irRecoverySection() async throws {
        try await irActiveToolImage(responses: false)
        let restore = try useResponses()
        do { try await irActiveToolImage(responses: true) }
        restore()
        try await irOldUserImage(responses: false)
        let restore2 = try useResponses()
        do { try await irOldUserImage(responses: true) }
        restore2()
    }

    /// R1 + R11: an active-turn tool image (both in-memory bytes and the
    /// persisted reference populated) is rejected; the newest round's image
    /// is marked and saved, the request is rebuilt without re-running the
    /// tool, the notice follows the successful retry; the next turn in
    /// memory and after a restart send the note, never the image.
    private func irActiveToolImage(responses: Bool) async throws {
        let tag = responses ? "R1r" : "R1"
        let (manager, channel) = await irFresh()
        let path = irFile("\(tag)-frame.png", IRFixtures.png)
        let count = irFile("\(tag)-count.txt", Data())
        server.script([
            tools([(id: "\(tag)-read", name: "read_file", args: ["path": path]),
                   (id: "\(tag)-bash", name: "bash", args: ["command": "echo run >> \(count)"])], responses: responses),
            Self.irRejection(responses: responses),
            text("\(tag) done", responses: responses),
        ], statuses: [200, 400, 200])
        manager._testStartTurn(for: user("\(tag) read the frame"))
        _ = await manager._testAwaitIdle(timeout: 30)
        let bodies = irRequestBodies()
        let image = irBase64(IRFixtures.png)
        let note = ModelImage.rejectedNote(path: path)
        check("\(tag)a three requests: tool round, rejected request with the image, retry without it",
              bodies.count == 3 && bodies[1].contains(image) && !bodies[2].contains(image), "requests \(bodies.count)")
        check("\(tag)b the retry carries the note in the image's place", bodies.count == 3 && bodies[2].contains(note))
        let runs = (try? String(contentsOfFile: count, encoding: .utf8))?.components(separatedBy: "run").count ?? 0
        check("\(tag)c no tool re-executed (bash ran once)", runs - 1 == 1, "runs \(runs - 1)")
        let saved = irSavedConversation()
        check("\(tag)d the turn finished and the mark reached conversation.json",
              manager._testMessages.last?.content == "\(tag) done" && saved.contains("\"providerRejected\":true"))
        check("\(tag)e one notice, sent after the successful retry", irNotices(channel).count == 1
              && channel.delivered.firstIndex { $0.hasPrefix("⚠️ The provider rejected") }.map { $0 < (channel.delivered.firstIndex { $0 == "\(tag) done" } ?? 0) } == true,
              "\(channel.delivered)")
        // Next turn, same process (Responses prefers the in-memory bytes).
        server.clear()
        server.script([text("\(tag) next", responses: responses)])
        manager._testStartTurn(for: user("\(tag) anything else?"))
        _ = await manager._testAwaitIdle(timeout: 30)
        let next = irRequestBodies().first ?? ""
        check("\(tag)f next turn in memory: note, no image", next.contains(note) && !next.contains(image))
        // After a restart (only the persisted reference exists).
        let restarted = await restart()
        restarted._svRegisterChannel(channel)
        server.clear()
        server.script([text("\(tag) after restart", responses: responses)])
        restarted._testStartTurn(for: user("\(tag) after restart"))
        _ = await restarted._testAwaitIdle(timeout: 30)
        let after = irRequestBodies().first ?? ""
        check("\(tag)g after a restart: note, no image", after.contains(note) && !after.contains(image))
    }

    /// R2: an old poisoned user image after a text-only turn. The newest
    /// unit (the new text message) carried no image, so recovery goes
    /// straight to the wider scope — never an identical resend.
    private func irOldUserImage(responses: Bool) async throws {
        let tag = responses ? "R2r" : "R2"
        let name = irUserImage("\(tag)-old.png", IRFixtures.png)
        let old = Message(role: .user, content: "\(tag) look at this", imageFileNames: [name])
        let (manager, channel) = await irFresh(history: [old, Message(role: .assistant, content: "seen")])
        server.script([Self.irRejection(responses: responses), text("\(tag) done", responses: responses)], statuses: [400, 200])
        manager._testStartTurn(for: user("\(tag) and now?"))
        _ = await manager._testAwaitIdle(timeout: 30)
        let bodies = irRequestBodies()
        let image = irBase64(IRFixtures.png)
        check("\(tag)a two requests only (no identical resend): rejected one with the old image, retry without",
              bodies.count == 2 && bodies[0].contains(image) && !bodies[1].contains(image), "requests \(bodies.count)")
        let marked = manager._testMessages.first { $0.id == old.id }?.providerRejectedImageFileNames ?? []
        check("\(tag)b the old canonical message carries the mark, persisted", marked == [name]
              && irSavedConversation().contains("\"providerRejectedImageFileNames\":[\"\(name)\"]"))
        check("\(tag)c the retry says why the image is missing", bodies.count == 2 && bodies[1].contains(ModelImage.rejectedNote(path: StoragePaths.dataRoot.appendingPathComponent("images").appendingPathComponent(name).path)))
        check("\(tag)d one notice", irNotices(channel).count == 1)
        let restarted = await restart()
        server.clear()
        server.script([text("\(tag) later", responses: responses)])
        restarted._testStartTurn(for: user("\(tag) later"))
        _ = await restarted._testAwaitIdle(timeout: 30)
        check("\(tag)e after a restart the old image stays excluded", !(irRequestBodies().first ?? image).contains(image))
    }

    /// R10 + R11: the second rejection widens once; a third fails exactly as
    /// today; at most two extra sends; no tool re-run; no notice on failure.
    func irWidenSection() async throws {
        // The driver's own bound, independent of what the serializers drop:
        // a provider that keeps rejecting a request that keeps carrying an
        // image gets three sends in total, then the original error.
        var sends = 0, commits = 0
        let slot = ImageSlot.tool(owner: nil, callId: "u", ordinal: 0)
        do {
            _ = try await ImageRejectionRecovery.run(
                send: { log in
                    sends += 1; log.record(slot, label: "/tmp/u.png")
                    throw ProviderImageRejection.Rejected(status: 400, underlying: ResponsesFailure.http(400, nil))
                },
                newestUnit: { Set($0) }, commit: { _ in commits += 1; return true })
            check("R10u the driver gives up", false)
        } catch {
            check("R10u at most two extra sends even if every request still carries an image; the original error is rethrown",
                  sends == 3 && commits == 2 && { if case ResponsesFailure.http(400, nil) = error { return true }; return false }(),
                  "sends \(sends) commits \(commits) \(error)")
        }
        // A commit that refuses (a failed write) ends the recovery at once.
        sends = 0
        do {
            _ = try await ImageRejectionRecovery.run(
                send: { log in sends += 1; log.record(slot, label: "x"); throw ProviderImageRejection.Rejected(status: 400, underlying: IRInjected()) },
                newestUnit: { Set($0) }, commit: { _ in false })
        } catch { check("R10v a refused commit: one send, original error", sends == 1 && error is IRInjected) }

        for responses in [false, true] {
            let restore: (() -> Void)? = responses ? try useResponses() : nil
            let tag = responses ? "R10r" : "R10"
            let oldName = irUserImage("\(tag)-old.png", IRFixtures.png)
            let old = Message(role: .user, content: "\(tag) earlier", imageFileNames: [oldName])
            let (manager, channel) = await irFresh(history: [old, Message(role: .assistant, content: "ok")])
            let path = irFile("\(tag)-new.jpg", IRFixtures.jpeg)
            let count = irFile("\(tag)-count.txt", Data())
            let rejection = Self.irRejection(responses: responses)
            server.script([
                tools([(id: "\(tag)-read", name: "read_file", args: ["path": path]),
                       (id: "\(tag)-bash", name: "bash", args: ["command": "echo run >> \(count)"])], responses: responses),
                rejection, rejection, rejection, text("never", responses: responses),
            ], statuses: [200, 400, 400, 400, 200])
            manager._testStartTurn(for: user("\(tag) read it"))
            _ = await manager._testAwaitIdle(timeout: 30)
            let bodies = irRequestBodies()
            let newImage = irBase64(IRFixtures.jpeg), oldImage = irBase64(IRFixtures.png)
            check("\(tag)a exactly two extra sends (4 requests), then the turn fails",
                  bodies.count == 4 && server.remainingResponses == 1, "requests \(bodies.count)")
            check("\(tag)b first retry drops only the newest round's image; the second drops every image",
                  bodies.count == 4 && bodies[1].contains(newImage) && bodies[1].contains(oldImage)
                    && !bodies[2].contains(newImage) && bodies[2].contains(oldImage)
                    && !bodies[3].contains(newImage) && !bodies[3].contains(oldImage))
            let runs = ((try? String(contentsOfFile: count, encoding: .utf8)) ?? "").components(separatedBy: "run").count - 1
            check("\(tag)c the tool ran once", runs == 1, "runs \(runs)")
            let error = channel.delivered.first { $0.hasPrefix("❌ Something went wrong") } ?? ""
            let expected = responses ? "Responses HTTP 400" : "API error: HTTP 400"
            check("\(tag)d the turn fails with today's error text and no notice",
                  error.contains(expected) && irNotices(channel).isEmpty, error)
            restore?()
        }
    }
}
