import Foundation

// The admitted commit transaction (plan B.4a), staging and the superseding
// observer (B.5), the idle apply.
extension LiveMenuHarness {
    func commitSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        // S while busy → applied now, no barrier.
        reset(Self.routeBase)
        owner.busy = true
        guard let s = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-new") }) else { check("commit: prepared", false); return }
        let rs = await writer.commit(s)
        check("commit: a key replacement applies even while Briglia is busy", rs.state == .applied && store()[KeychainHelper.serperApiKeyKey] == "serper-new", "\(rs.state)")
        check("commit: a key replacement takes no barrier", owner.barriersTaken == 0)
        check("commit: a key replacement is reconciled without a route change", owner.reconciles.last?.routeChanged == false)
        // D while busy, pending accepted → staged, nothing written.
        guard let d = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "openai/gpt-6-luna") }) else { return }
        let before = store()
        let rd = await writer.commit(d)
        check("commit: a route change while busy is staged (pending)", rd.state == .pending && rd.ticket != nil, "\(rd.state) \(rd.message ?? "")")
        check("commit: a staged change writes nothing", store() == before)
        check("commit: the staged change is in its slot", pendingDoc().slots["ai"]?.staged?.ticket == rd.ticket)
        // D while busy without accepting pending → busy.
        var noAccept = d; noAccept.acceptPending = false
        let rb = await writer.commit(noAccept)
        check("commit: a route change while busy without accept_pending answers busy", rb.state == .busy)
        // D when idle → applied under the barrier, released after.
        owner.busy = false
        reset(Self.routeBase)
        guard let d2 = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "openai/gpt-6-luna") }) else { return }
        let ra = await writer.commit(d2)
        check("commit: a route change while idle applies", ra.state == .applied && store()[KeychainHelper.openRouterModelKey] == "openai/gpt-6-luna")
        check("commit: the barrier was taken once and released", owner.barriersTaken == 1 && !owner.barrierHeld)
        check("commit: the route change is reconciled as one", owner.reconciles.last?.routeChanged == true)
        // Admission closed → refused at once, nothing written.
        reset(Self.routeBase)
        guard let s2 = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-x") }) else { return }
        writer.gate.closeAdmission(reason: "memory operation")
        let rr = await writer.commit(s2)
        check("commit: closed admission refuses at once", rr.state == .refused && rr.message == "memory operation" && store()[KeychainHelper.serperApiKeyKey] == "serper-synthetic-old-0001")
        writer.gate.reopenAdmission()
        // The host's admission flags at the decision point.
        owner.admission = "Briglia is updating"
        let rf = await writer.commit(s2)
        check("commit: the decision point checks the owner's admission flags", rf.state == .refused && rf.message == "Briglia is updating")
        owner.admission = nil
        // An empty change is applied without a write.
        let count = KeychainHelper._testWriteCount
        if let empty = await prepare(label: "nothing", { }) {
            let re = await writer.commit(empty)
            check("commit: an empty change writes nothing", re.state == .applied && KeychainHelper._testWriteCount == count)
        } else { check("commit: empty prepared", false) }
        // Immediate policy: a route change applies at once (the agent's own edit).
        owner.busy = true
        if let im = await prepare(label: "edit", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "x/y") }) {
            let ri = await writer.commit(im, policy: .immediate)
            check("commit: the immediate policy applies a route change mid-task (D21)", ri.state == .applied && store()[KeychainHelper.openRouterModelKey] == "x/y")
            check("commit: the immediate policy takes no barrier and reconciles lightly", owner.barriersTaken == 1 && owner.reconciles.last?.routeChanged == false)
        }
        owner.busy = false
    }

    func commitRaceSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        // Stale S: prepared as a key replacement; another change removes the
        // key; a turn starts; the resume never applies it mid-turn.
        reset(Self.routeBase.merging([KeychainHelper.geminiApiKeyKey: "gemini-synthetic-1"]) { $1 })
        guard let s = await prepare(label: "Gemini key", { try KeychainHelper.save(key: KeychainHelper.geminiApiKeyKey, value: "gemini-synthetic-2") }) else { return }
        try? KeychainHelper.delete(key: KeychainHelper.geminiApiKeyKey)
        owner.busy = true
        let r = await writer.commit(s)
        check("stale S: refused by its preconditions, never applied mid-turn", r.state == .refused && store()[KeychainHelper.geminiApiKeyKey] == nil, "\(r.state) \(r.message ?? "")")
        owner.busy = false
        // Revision race: a write between the token and the decision point.
        reset(Self.routeBase)
        guard let s2 = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-raced") }) else { return }
        writer.beforeDecisionPointForTesting = { try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-external") }
        let r2 = await writer.commit(s2)
        writer.beforeDecisionPointForTesting = nil
        check("race: a write before the decision point aborts the commit", r2.state == .refused && store()[KeychainHelper.serperApiKeyKey] == "serper-external")
        // Whole-store read: a concurrent route change refuses it.
        reset(Self.routeBase)
        guard let whole = await prepare(label: "name", {
            _ = KeychainHelper.loadSnapshot(); try KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Seen")
        }) else { return }
        try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "changed/elsewhere")
        let r3 = await writer.commit(whole)
        check("race: a change prepared from the whole store refuses after a route change", r3.state == .refused)
        // Epoch: a wipe or import between preparation and commit.
        reset(Self.routeBase)
        guard let s3 = await prepare(label: "Serper key", { try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-old-epoch") }) else { return }
        _ = try? ReplacementEpoch.advance()
        let r4 = await writer.commit(s3)
        check("epoch: a change prepared before a wipe is refused after it", r4.state == .refused && r4.message == SettingsWriter.epochMessage)
        check("epoch: nothing was written", store()[KeychainHelper.serperApiKeyKey] == "serper-synthetic-old-0001")
        // A bot change is refused in a running daemon (use /switchbot).
        ProcessKind.isDaemon = true
        reset(Self.routeBase)
        if let bot = await prepare(label: "Telegram", { try KeychainHelper.saveBatch([KeychainHelper.telegramBotTokenKey: "1:synthetic", KeychainHelper.telegramChatIdKey: "42"]) }) {
            let r5 = await writer.commit(bot)
            check("bot: a running daemon refuses a Telegram bot change", r5.state == .refused && store()[KeychainHelper.telegramBotTokenKey] == nil)
        }
        ProcessKind.isDaemon = false
    }

    // MARK: Pending (B.5)

    func pendingSection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        owner.busy = true
        func stageModel(_ model: String) async -> String? {
            guard let d = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: model) }) else { return nil }
            return await writer.commit(d).ticket
        }
        // Superseded by a later write of one of its keys.
        reset(Self.routeBase)
        SettingsSupersede.install()
        let t1 = await stageModel("a/one")
        try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "telegram/choice")
        let dropped = pendingDoc().lastResults.last
        check("supersede: a later write of its key drops the staged change", pendingDoc().slots["ai"] == nil && dropped?.ticket == t1 && dropped?.state == "dropped", "\(pendingDoc().slots)")
        check("supersede: the result says why", dropped?.message == SettingsWriter.supersededMessage)
        // An unrelated write keeps it.
        let t2 = await stageModel("a/two")
        try? KeychainHelper.save(key: KeychainHelper.userContextKey, value: "unrelated")
        check("supersede: an unrelated write keeps the staged change", pendingDoc().slots["ai"]?.staged?.ticket == t2)
        // A→B→A: the event supersedes even though the value came back.
        try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "b/b")
        try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "deepseek/deepseek-v4.1-flash-1017")
        check("supersede: A→B→A drops the staged change (the event, not the value)", pendingDoc().slots["ai"] == nil)
        // Maintenance writes never supersede.
        let t3 = await stageModel("a/three")
        SettingsSupersede.$maintenanceWrite.withValue(true) {
            try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "rebind/same")
        }
        check("supersede: a maintenance (rebind) write does not supersede", pendingDoc().slots["ai"]?.staged?.ticket == t3)
        // Newest wins.
        let t4 = await stageModel("a/four")
        check("staging: the newest change replaces the staged one", pendingDoc().slots["ai"]?.staged?.ticket == t4
              && pendingDoc().lastResults.contains { $0.ticket == t3 && $0.message == "replaced by a newer change" })
        // Cancel by ticket.
        check("cancel: a staged change is cancelled by its ticket", (try? SettingsWriter.cancelStaged(ticket: t4 ?? "")) == "cancelled" && pendingDoc().slots["ai"] == nil)
        check("cancel: an unknown ticket is not found", (try? SettingsWriter.cancelStaged(ticket: "nope")) == "not found")
        // A change prepared from the whole store: a key replacement keeps
        // it; a route change drops it.
        reset(Self.routeBase)
        SettingsSupersede.install()
        if let whole = await prepare(label: "AI model", {
            _ = KeychainHelper.loadSnapshot(); try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "whole/model")
        }) {
            let t = await writer.commit(whole).ticket
            try? KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: "serper-replaced-meanwhile")
            check("supersede: a key replaced meanwhile keeps a staged whole-store change", pendingDoc().slots["ai"]?.staged?.ticket == t)
            try? KeychainHelper.save(key: KeychainHelper.voiceTranscriptionProviderKey, value: "local")
            check("supersede: a route change elsewhere drops a staged whole-store change", pendingDoc().slots["ai"] == nil)
        }
        // A subscription login supersedes a change prepared against it.
        reset(Self.routeBase)
        SettingsSupersede.install()
        var signedIn = SubscriptionAuthState(generation: UUID().uuidString)
        signedIn.credential = credential()
        writeAuth(signedIn)
        var withExpectation = await prepare(label: "ChatGPT model", { try KeychainHelper.save(key: ProviderProfiles.subscriptionModelKey, value: "gpt-6-sol") })
        withExpectation?.subscriptionExpectations = [SettingsSubscriptionExpectation(store: StoragePaths.configRoot.path, generation: signedIn.generation, requireUsable: true, requireNoPending: true)]
        withExpectation?.writes[ProviderProfiles.activeProfileKey] = "chatgpt"
        if let w = withExpectation { _ = await writer.commit(w) }
        check("supersede: the change is staged", pendingDoc().slots["ai"]?.staged != nil)
        SettingsSupersede.subscriptionChanged(store: StoragePaths.configRoot.path)
        check("supersede: a user login/logout of its store drops it", pendingDoc().slots["ai"] == nil)
        SettingsSupersede.uninstall()
        owner.busy = false
    }

    func pendingApplySection() async {
        let owner = FakeSettingsOwner()
        let writer = SettingsWriter(host: owner)
        reset(Self.routeBase)
        owner.busy = true
        guard let d = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "staged/model") }) else { return }
        let ticket = await writer.commit(d).ticket
        // Busy: the apply leaves it staged.
        let none = await writer.applyStaged(category: "ai")
        check("apply: a refused barrier leaves the change staged", none == nil && pendingDoc().slots["ai"]?.staged?.ticket == ticket)
        // Idle: applied, marker, result, slot empty.
        owner.busy = false
        let applied = await writer.applyStaged(category: "ai")
        let doc = pendingDoc()
        check("apply: at an idle point the staged change is applied", applied?.state == .applied && store()[KeychainHelper.openRouterModelKey] == "staged/model", "\(applied?.state.rawValue ?? "nil") \(applied?.message ?? "")")
        check("apply: the secrets attempt marker is written with the change", (store()[SettingsWriter.attemptMarkerKey("ai")].map { UUID(uuidString: $0) != nil }) ?? false)
        check("apply: the slot is empty and the attempt journal cleaned", doc.slots["ai"] == nil && doc.attempts.isEmpty)
        check("apply: the result is recorded as applied", doc.lastResults.last?.ticket == ticket && doc.lastResults.last?.state == "applied")
        check("apply: the barrier was released", !owner.barrierHeld)
        // External edit (no observer: a shell, an old binary) → caught at apply.
        reset(Self.routeBase)
        owner.busy = true
        guard let d2 = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "staged/two") }) else { return }
        _ = await writer.commit(d2)
        try? KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "external/edit")   // no observer installed
        owner.busy = false
        let r = await writer.applyStaged(category: "ai")
        check("apply: an external edit is caught by the preconditions at apply", r?.state == .refused && store()[KeychainHelper.openRouterModelKey] == "external/edit")
        check("apply: the refused change is dropped with its reason and the slot emptied", pendingDoc().slots["ai"] == nil && pendingDoc().lastResults.last?.state == "dropped")
        // Cancel during apply → "already applying".
        reset(Self.routeBase)
        owner.busy = true
        guard let d3 = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "staged/three") }) else { return }
        let t3 = await writer.commit(d3).ticket ?? ""
        owner.busy = false
        var answer = ""
        writer.beforeDecisionPointForTesting = { answer = (try? SettingsWriter.cancelStaged(ticket: t3)) ?? "" }
        _ = await writer.applyStaged(category: "ai")
        writer.beforeDecisionPointForTesting = nil
        check("apply: cancel while applying answers \"already applying\"", answer == "already applying")
        // Closed admission during the claim → back to staged.
        reset(Self.routeBase)
        owner.busy = true
        guard let d4 = await prepare(label: "AI model", { try KeychainHelper.save(key: KeychainHelper.openRouterModelKey, value: "staged/four") }) else { return }
        let t4 = await writer.commit(d4).ticket
        owner.busy = false
        owner.admission = "memory operation"
        _ = await writer.applyStaged(category: "ai")
        owner.admission = nil
        check("apply: a refusal after the claim and before intent returns the change to staged", pendingDoc().slots["ai"]?.staged?.ticket == t4 && pendingDoc().slots["ai"]?.active == nil)
    }
}
