import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Subagent compaction keeps the dialogue with the main agent and the newest
/// rounds under two budgets over one kept tail (SUBAGENT_DIALOGUE_PRESERVING_
/// COMPACTION_PLAN). §1–§7 drive the pure planner, transcript and estimator;
/// §8 runs the real SubagentRunner against a scripted local provider through
/// eager-at-resume and folded compactions. Self-isolates into temp XDG roots.
struct SubagentCompactionSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__subagent-compaction-selftest",
        abstract: "Internal: verify dialogue-preserving subagent compaction.",
        shouldDisplay: false
    )

    struct Failure: Error, CustomStringConvertible { let description: String }

    func run() async throws {
        guard adaCLIVersion.hasSuffix("-dev") else { throw ValidationError("Needs a development build") }
        var total = 0
        var failures = 0
        func check(_ name: String, _ value: Bool, _ detail: String = "") {
            total += 1
            if !value { failures += 1 }
            print("\(value ? "✔" : "✖") \(name)\(value || detail.isEmpty ? "" : " — \(detail)")")
        }

        // ---- Builders. Content sized so that ~4 chars/token estimates land
        // on round numbers; every item carries a tag for identity checks.
        func text(_ tag: String, tokens: Int) -> String {
            let body = String(repeating: "x", count: max(0, tokens * 4 - tag.count - 2))
            return "<\(tag)>" + body
        }
        func message(_ tag: String, _ role: Message.Role, tokens: Int, rounds: [ToolInteraction] = [], replay: Bool = false) -> Message {
            var m = Message(role: role, content: text(tag, tokens: tokens), timestamp: Date(timeIntervalSince1970: 1_700_000_000), toolInteractions: rounds)
            if replay {
                m.responsesReplay = ResponsesReplayEnvelope(version: 1, responseID: "resp-\(tag)",
                    scope: ResponsesScope(endpoint: "e", profile: "p", model: "m", credentialFingerprint: "f"),
                    fingerprint: "fp", entries: [])
            }
            return m
        }
        func round(_ tag: String, tokens: Int) -> ToolInteraction {
            // estimatedInteractionTokens: name/4 + 20 + args/4 + reasoning/4 + result/4 + 20 ≈ tokens
            let overhead = 40 + "read_file".count / 4 + "thinking \(tag)".count / 4
            let resultChars = max(0, (tokens - overhead) * 4 - 20)
            return ToolInteraction(
                assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: [
                    ToolCall(id: "call-\(tag)", type: "function", function: FunctionCall(name: "read_file", arguments: "{\"p\":\"\(tag)\"}"))
                ], reasoning: .string("thinking \(tag)")),
                results: [ToolResultMessage(toolCallId: "call-\(tag)", content: "<\(tag)>" + String(repeating: "r", count: resultChars))]
            )
        }
        func tag(_ m: Message) -> String { String(m.content.dropFirst().prefix { $0 != ">" }) }
        func tag(_ r: ToolInteraction) -> String { String(r.assistantMessage.toolCalls[0].id.dropFirst(5)) }
        func ordered(_ text: String, _ first: String, _ second: String) -> Bool {
            guard let a = text.range(of: first), let b = text.range(of: second) else { return false }
            return a.lowerBound < b.lowerBound
        }
        let total50 = 50_000
        let dialogue30 = SubagentRunner.dialogueKeepTokens(totalKeepTokens: total50)
        func plan(_ messages: [Message], _ rounds: [ToolInteraction], dialogue: Int? = nil, total: Int = 50_000) -> SubagentRunner.CompactionPlan {
            SubagentRunner.planCompaction(messages: messages, interactions: rounds,
                                          dialogueKeepTokens: dialogue ?? SubagentRunner.dialogueKeepTokens(totalKeepTokens: total),
                                          totalKeepTokens: total)
        }

        print("0. Budgets")
        check("0.1 dialogue cap is 30k at the default 50k tail", dialogue30 == 30_000)
        check("0.2 smaller tails split three fifths / two fifths", SubagentRunner.dialogueKeepTokens(totalKeepTokens: 250) == 150
              && SubagentRunner.dialogueKeepTokens(totalKeepTokens: 1) == 1)

        print("1. Single long run, tiny dialogue: the cap flows to the work tail")
        do {
            let prompt = message("task", .user, tokens: 1_000)
            let rounds = (0..<40).map { round("w\($0)", tokens: 2_000) }
            let p = plan([prompt], rounds)
            check("1.1 dialogue kept verbatim", p.keptMessages.count == 1 && tag(p.keptMessages[0]) == "task" && p.evictedDialogue.isEmpty)
            check("1.2 work budget is the whole tail minus the dialogue actually used", p.workKeepTokens == 49_000, "\(p.workKeepTokens)")
            check("1.3 newest 24 rounds kept (48k ≤ 49k), 16 oldest evicted", p.keptInteractions.count == 24 && p.evictedWork.count == 16,
                  "kept \(p.keptInteractions.count) evicted \(p.evictedWork.count)")
            check("1.4 kept rounds are the newest, evicted are the oldest in order",
                  p.keptInteractions.map(tag) == (16..<40).map { "w\($0)" } && p.evictedWork.map(tag) == (0..<16).map { "w\($0)" })
            check("1.5 more than a strict 20k reservation would keep (10 rounds)", p.keptInteractions.count > 10)
        }

        print("2. Twenty resumes: 40k dialogue, 100k work")
        do {
            var messages: [Message] = []
            for i in 0..<20 {
                messages.append(message("ask\(i)", .user, tokens: 1_000))
                messages.append(message("reply\(i)", .assistant, tokens: 1_000))
            }
            let rounds = (0..<50).map { round("w\($0)", tokens: 2_000) }
            let p = plan(messages, rounds)
            check("2.1 work budget is 20k once the dialogue took its 30k", p.workKeepTokens == 20_000, "\(p.workKeepTokens)")
            check("2.2 newest 10 rounds kept, 40 evicted", p.keptInteractions.count == 10 && p.evictedWork.count == 40)
            check("2.3 newest 30 dialogue messages kept (30k), 10 oldest evicted", p.keptMessages.count == 30 && p.evictedDialogue.count == 10,
                  "kept \(p.keptMessages.count) evicted \(p.evictedDialogue.count)")
            check("2.4 evicted dialogue is the oldest, in order", p.evictedDialogue.map(tag) == (0..<5).flatMap { ["ask\($0)", "reply\($0)"] })
            check("2.5 kept dialogue starts at ask5 and ends with reply19",
                  tag(p.keptMessages.first!) == "ask5" && tag(p.keptMessages.last!) == "reply19")
            let keptTokens = SubagentRunner.estimatedContextTokens(messages: p.keptMessages, interactions: p.keptInteractions)
            check("2.6 kept tail is about 50k", keptTokens >= 49_000 && keptTokens <= 51_000, "\(keptTokens)")
        }

        print("3. Floors: oversized items go over budget rather than orphaning")
        do {
            let two = plan([message("spec", .user, tokens: 40_000), message("reply", .assistant, tokens: 1_000)], [])
            check("3.1 the last two dialogue messages stay even at 41k", two.keptMessages.count == 2 && two.isEmpty)
            let three = plan([message("old", .user, tokens: 5_000), message("spec", .user, tokens: 40_000), message("reply", .assistant, tokens: 1_000)], [])
            check("3.2 with a third message only that one is evicted", three.keptMessages.map(tag) == ["spec", "reply"] && three.evictedDialogue.map(tag) == ["old"])
            let big3 = plan([message("task", .user, tokens: 100)], (0..<3).map { round("w\($0)", tokens: 15_000) }, total: 5_000)
            check("3.3 newest three rounds stay even at 45k over a 5k tail", big3.keptInteractions.count == 3 && big3.isEmpty)
            let big4 = plan([message("task", .user, tokens: 100)], (0..<4).map { round("w\($0)", tokens: 15_000) }, total: 5_000)
            check("3.4 a fourth round is evicted", big4.keptInteractions.count == 3 && big4.evictedWork.map(tag) == ["w0"])
            let tiny = plan([message("task", .user, tokens: 100)], [round("w0", tokens: 100)])
            check("3.5 nothing to evict → empty plan (caller falls back)", tiny.isEmpty && tiny.keptInteractions.count == 1)
        }

        print("4. Responses mode: completed replies keep their text, lose old embedded rounds")
        do {
            let r1 = (0..<10).map { round("m1r\($0)", tokens: 2_000) }
            let r3 = (0..<10).map { round("m3r\($0)", tokens: 2_000) }
            let messages = [
                message("ask0", .user, tokens: 1_000),
                message("reply0", .assistant, tokens: 1_000, rounds: r1, replay: true),
                message("ask1", .user, tokens: 1_000),
                message("reply1", .assistant, tokens: 1_000, rounds: r3, replay: true),
                message("ask2", .user, tokens: 1_000),
            ]
            let pending = (0..<8).map { round("p\($0)", tokens: 2_000) }
            let p = plan(messages, pending)  // work 56k > 45k → six oldest rounds of reply0 go → 44k
            check("4.1 no dialogue evicted (5k ≤ 30k)", p.evictedDialogue.isEmpty && p.keptMessages.count == 5)
            let reply0 = p.keptMessages[1], reply1 = p.keptMessages[3]
            check("4.2 oldest reply partly stripped: text kept, newest four rounds kept, final replay envelope retained, no log",
                  tag(reply0) == "reply0" && reply0.toolInteractions.map(tag) == (6..<10).map { "m1r\($0)" } && reply0.responsesReplay != nil && reply0.compactToolLog == nil)
            // A VALID final envelope (fingerprint over the reply text and zero
            // calls, one encrypted reasoning item) still renders natively after
            // the strip: the envelope never described round positions.
            let scope = ResponsesScope(endpoint: "e", profile: "p", model: "m", credentialFingerprint: "f")
            var valid = message("final", .assistant, tokens: 1_000, rounds: (0..<8).map { round("v\($0)", tokens: 2_000) })
            valid.responsesReplay = ResponsesReplayEnvelope(version: 1, responseID: "resp-final", scope: scope,
                fingerprint: ResponsesReplayEnvelope.fingerprint(text: valid.content, calls: []), entries: [
                    ResponsesReplayEntry(type: "reasoning", id: "rs-final", callIndex: nil, encryptedContent: "ENCRYPTED_FINAL", summary: [], textParts: nil, refusalParts: nil),
                    ResponsesReplayEntry(type: "message", id: "msg-final", callIndex: nil, encryptedContent: nil, summary: nil, textParts: [valid.content.utf8.count], refusalParts: [false])])
            let after = plan([message("task", .user, tokens: 10), valid], [], total: 5_000).keptMessages[1]
            let native = ResponsesAdapter.nativeItems(envelope: after.responsesReplay, scope: scope, text: after.content, calls: [])
            check("4.3 valid final envelope survives a partial strip and still renders its encrypted reasoning",
                  after.toolInteractions.count == 3 && native != nil && (native ?? []).contains { ($0.responsesObject?["encrypted_content"]?.responsesString) == "ENCRYPTED_FINAL" })
            check("4.4 newer reply untouched: rounds and replay intact", tag(reply1) == "reply1" && reply1.toolInteractions.count == 10 && reply1.responsesReplay != nil)
            check("4.5 pending rounds untouched", p.keptInteractions.count == 8)
            check("4.6 evicted work = the stripped rounds, oldest first", p.evictedWork.map(tag) == (0..<6).map { "m1r\($0)" })
            // 4b. A message evicted for dialogue reasons hands its rounds over in chronological position.
            let r = (0..<5).map { round("e\($0)", tokens: 1_000) }
            let long = [
                message("ask0", .user, tokens: 20_000),
                message("reply0", .assistant, tokens: 1_000, rounds: r, replay: true),
                message("ask1", .user, tokens: 15_000),
                message("reply1", .assistant, tokens: 1_000),
                message("ask2", .user, tokens: 15_000),
            ]
            let q = plan(long, (0..<3).map { round("p\($0)", tokens: 1_000) })
            check("4.7 dialogue evicted past the pinned reply: ask0 and ask1 out, reply0 stays in place with its rounds",
                  q.evictedDialogue.map(tag) == ["ask0", "ask1"] && q.keptMessages.map(tag) == ["reply0", "reply1", "ask2"]
                  && q.keptMessages[0].toolInteractions.count == 5)
            check("4.8 nothing evicted from the work side: kept rounds never move to the summarizer via dialogue eviction",
                  q.evictedWork.isEmpty && q.keptInteractions.count == 3)
            // 4c. The newest three rounds stay wherever they live: a reply's
            // embedded rounds are stripped round by round down to the floor.
            let last = [message("ask0", .user, tokens: 100), message("reply0", .assistant, tokens: 100, rounds: (0..<30).map { round("z\($0)", tokens: 2_000) }, replay: true)]
            let s = plan(last, [], total: 5_000)
            let reply = s.keptMessages[1]
            check("4.9 embedded rounds stripped down to the newest three, text kept, replay retained, no log",
                  reply.toolInteractions.map(tag) == ["z27", "z28", "z29"] && tag(reply) == "reply0" && reply.responsesReplay != nil
                  && reply.compactToolLog == nil && s.evictedWork.map(tag) == (0..<27).map { "z\($0)" })
            // 4d. One chronological work budget across both stores: embedded
            // rounds go first; when that is not enough the pending list is
            // evicted from the front; the kept work lands under the budget.
            let cross = [message("ask0", .user, tokens: 1_000), message("reply0", .assistant, tokens: 1_000, rounds: (0..<10).map { round("emb\($0)", tokens: 2_000) }, replay: true), message("ask1", .user, tokens: 1_000)]
            let c = plan(cross, (0..<30).map { round("p\($0)", tokens: 2_000) })  // work 80k, budget 47k
            var keptWork = c.keptInteractions.count * 2_000
            for m in c.keptMessages { keptWork += m.toolInteractions.count * 2_000 }
            let expectedEvicted: [String] = (0..<10).map { "emb\($0)" } + (0..<7).map { "p\($0)" }
            let expectedKept: [String] = (7..<30).map { "p\($0)" }
            check("4.10 embedded rounds evicted before any pending round, then the oldest pending rounds",
                  c.evictedWork.map(tag) == expectedEvicted && c.keptInteractions.map(tag) == expectedKept,
                  "evicted \(c.evictedWork.map(tag)) kept \(c.keptInteractions.map(tag)) budget \(c.workKeepTokens)")
            check("4.11 kept work lands under the shared budget (46k ≤ 47k) with nothing older than the newest kept", keptWork <= c.workKeepTokens && keptWork > c.workKeepTokens - 2_100, "\(keptWork) vs \(c.workKeepTokens)")
            check("4.12 the reply whose rounds all went keeps its text, no log, replay retained", tag(c.keptMessages[1]) == "reply0" && c.keptMessages[1].toolInteractions.isEmpty && c.keptMessages[1].compactToolLog == nil && c.keptMessages[1].responsesReplay != nil)
            // 4e. Floor across stores: embedded 10 + pending 2 over a tiny budget
            // keeps exactly the newest three: one embedded, two pending.
            let mixed = plan([message("ask0", .user, tokens: 100), message("reply0", .assistant, tokens: 100, rounds: (0..<10).map { round("e\($0)", tokens: 2_000) }, replay: true)],
                             (0..<2).map { round("p\($0)", tokens: 2_000) }, total: 5_000)
            check("4.13 floor counts rounds across stores: newest embedded round + both pending rounds stay",
                  mixed.keptMessages[1].toolInteractions.map(tag) == ["e9"] && mixed.keptInteractions.map(tag) == ["p0", "p1"] && mixed.evictedWork.map(tag) == (0..<9).map { "e\($0)" })
            // 4f. (Codex R1) The newest three rounds live in an OLD reply, followed
            // by a long text-only exchange: dialogue eviction skips the pinned
            // reply, evicts around it, and the rounds stay in place.
            let codexR1 = plan([message("oldtask", .user, tokens: 100), message("oldreply", .assistant, tokens: 100, rounds: (0..<3).map { round("newest\($0)", tokens: 100) }, replay: true),
                           message("longtask", .user, tokens: 31_000), message("textanswer", .assistant, tokens: 100), message("resume", .user, tokens: 100)], [])
            check("4.14 newest three rounds survive dialogue eviction inside their pinned reply, in chronological position",
                  codexR1.keptMessages.map(tag) == ["oldreply", "textanswer", "resume"] && codexR1.keptMessages[0].toolInteractions.map(tag) == ["newest0", "newest1", "newest2"]
                  && codexR1.evictedWork.isEmpty && codexR1.evictedDialogue.map(tag) == ["oldtask", "longtask"] && codexR1.keptMessages[0].responsesReplay != nil)
            // 4g. Mixed: two embedded + one pending round (floor not reached), dialogue over budget.
            let mixed2 = plan([message("ask0", .user, tokens: 1_000), message("reply0", .assistant, tokens: 1_000, rounds: (0..<2).map { round("e\($0)", tokens: 1_000) }, replay: true),
                               message("ask1", .user, tokens: 20_000), message("reply1", .assistant, tokens: 1_000), message("ask2", .user, tokens: 15_000)], [round("p0", tokens: 1_000)])
            check("4.15 fewer than three rounds overall: none evicted, embedded ones pinned, pending intact, dialogue evicted around them",
                  mixed2.evictedWork.isEmpty && mixed2.keptInteractions.count == 1 && mixed2.keptMessages.map(tag) == ["reply0", "reply1", "ask2"]
                  && mixed2.keptMessages[0].toolInteractions.count == 2 && mixed2.evictedDialogue.map(tag) == ["ask0", "ask1"])
            // 4h. (Codex R3) Earlier compact logs are budgeted work, evictable
            // without a floor, older than the message's own rounds.
            var logged: [Message] = []
            for i in 0..<25 {
                logged.append(message("task\(i)", .user, tokens: 10))
                var m = message("reply\(i)", .assistant, tokens: 10)
                m.compactToolLog = "LOG\(i) " + String(repeating: "read_file(x) → y\n", count: 500)   // ≈ 2k tokens each
                logged.append(m)
            }
            logged.append(message("resume", .user, tokens: 10))
            let codexR3 = plan(logged, [])
            let r3Estimate = SubagentRunner.estimatedContextTokens(messages: codexR3.keptMessages, interactions: codexR3.keptInteractions)
            check("4.16 a log-dominated session is compacted: oldest logs evicted, estimate lands near the tail, dialogue untouched",
                  !codexR3.isEmpty && codexR3.evictedLogs.count > 0 && codexR3.evictedLogs.first!.hasPrefix("LOG0") && r3Estimate <= 52_000 && codexR3.evictedDialogue.isEmpty
                  && codexR3.keptMessages.count == logged.count && codexR3.keptMessages.filter { $0.compactToolLog != nil }.count == 25 - codexR3.evictedLogs.count,
                  "evicted \(codexR3.evictedLogs.count) estimate \(r3Estimate)")
            var logAndRounds = message("reply", .assistant, tokens: 10, rounds: (0..<3).map { round("k\($0)", tokens: 1_000) })
            logAndRounds.compactToolLog = String(repeating: "old(x) → y\n", count: 2_000)   // ≈ 6k tokens
            let r3b = plan([message("task", .user, tokens: 10), logAndRounds, message("prompt", .user, tokens: 10)], [], total: 4_000)
            check("4.17 the log goes before the message's own rounds; the three rounds stay (floor), the log is gone",
                  r3b.evictedLogs.count == 1 && r3b.keptMessages[1].compactToolLog == nil && r3b.keptMessages[1].toolInteractions.count == 3 && r3b.evictedWork.isEmpty)
            var loggedOnly = message("oldreply", .assistant, tokens: 10)
            loggedOnly.compactToolLog = "ONLY_LOG"
            let r3c = plan([message("t0", .user, tokens: 5_000), loggedOnly, message("t1", .user, tokens: 30_100), message("a1", .assistant, tokens: 10), message("t2", .user, tokens: 10)], [])
            check("4.18 a dialogue-evicted message hands its earlier log to the summarizer", r3c.evictedDialogue.map(tag) == ["t0", "oldreply", "t1"] && r3c.evictedLogs == ["ONLY_LOG"])
        }

        print("5. Summary anchoring and transcript shape")
        do {
            let old = Message(role: .user, content: SubagentRunner.compactionSummaryHeader + "\n\n## Dialogue with the main agent\nOLD_DIALOGUE\n\nOLD_WORK", timestamp: Date(timeIntervalSince1970: 0))
            let older = Message(role: .user, content: SubagentRunner.compactionSummaryHeader + "\n\nOLDER", timestamp: Date(timeIntervalSince1970: 0))
            check("5.1 summary detection by header and role", SubagentRunner.isCompactionSummary(old)
                  && !SubagentRunner.isCompactionSummary(Message(role: .assistant, content: SubagentRunner.compactionSummaryHeader, timestamp: Date()))
                  && !SubagentRunner.isCompactionSummary(Message(role: .user, content: "plain", timestamp: Date())))
            let messages = [older, old, message("ask0", .user, tokens: 500), message("reply0", .assistant, tokens: 500), message("ask1", .user, tokens: 500)]
            let rounds = (0..<10).map { round("w\($0)", tokens: 6_000) }
            let p = plan(messages, rounds)
            check("5.2 both earlier summaries are folded, oldest first, none kept",
                  p.priorSummaries.map { $0.content } == [older.content, old.content] && !p.keptMessages.contains(where: SubagentRunner.isCompactionSummary))
            check("5.3 a plan with only summaries to fold is not empty", !plan([old, message("ask", .user, tokens: 10)], []).isEmpty)
            let transcript = SubagentRunner.compactionTranscript(priorSummaries: p.priorSummaries, dialogue: [message("ask", .user, tokens: 20), message("rep", .assistant, tokens: 20)], work: p.evictedWork)
            check("5.4 transcript blocks ordered prior → dialogue → work", ordered(transcript, "=== PRIOR SUMMARY", "=== DIALOGUE WITH THE MAIN AGENT") && ordered(transcript, "=== DIALOGUE WITH THE MAIN AGENT", "=== WORK"))
            check("5.5 dialogue roles labelled MAIN AGENT / SUBAGENT", transcript.contains("[MAIN AGENT] <ask>") && transcript.contains("[SUBAGENT] <rep>"))
            check("5.6 prior summary text carried into the transcript", transcript.contains("OLD_DIALOGUE") && transcript.contains("OLDER"))
            check("5.7 evicted work rendered with call and result", transcript.contains("[TOOL CALL] read_file") && transcript.contains("[TOOL RESULT] <w0>"))
            let none = SubagentRunner.compactionTranscript(priorSummaries: [], dialogue: [], work: [])
            check("5.8 empty transcript for an empty plan", none.isEmpty)
            let withLogs = SubagentRunner.compactionTranscript(priorSummaries: p.priorSummaries, dialogue: [message("ask", .user, tokens: 20)], work: [], logs: ["LOG_A", "LOG_B"])
            check("5.9 evicted logs rendered after the prior summary and before the dialogue, in order",
                  ordered(withLogs, "=== PRIOR SUMMARY", "=== EARLIER COMPACT TOOL LOGS") && ordered(withLogs, "LOG_A", "LOG_B") && ordered(withLogs, "LOG_B", "=== DIALOGUE WITH THE MAIN AGENT"))
        }

        print("6. Estimator counts embedded rounds and compact logs")
        do {
            let plain = message("a", .user, tokens: 1_000)
            let withRounds = message("b", .assistant, tokens: 1_000, rounds: (0..<2).map { round("q\($0)", tokens: 2_000) })
            var stripped = withRounds; stripped.toolInteractions = []; stripped.compactToolLog = String(repeating: "l", count: 4_000)
            let base = SubagentRunner.estimatedContextTokens(messages: [plain], interactions: [])
            let embedded = SubagentRunner.estimatedContextTokens(messages: [plain, withRounds], interactions: [])
            let logged = SubagentRunner.estimatedContextTokens(messages: [plain, stripped], interactions: [])
            check("6.1 plain message ≈ content/4", base == 1_000, "\(base)")
            check("6.2 embedded rounds counted (1k + 1k + 2×2k)", embedded >= 5_900 && embedded <= 6_100, "\(embedded)")
            check("6.3 a message without rounds counts its compact log (1k + 1k + 1k)", logged >= 2_900 && logged <= 3_100, "\(logged)")
            var measured = message("m", .assistant, tokens: 100, rounds: (0..<5).map { round("mr\($0)", tokens: 2_000) }); measured.measuredTokens = 99; measured.measuredToolTokens = 98
            let touched = plan([message("t", .user, tokens: 10), measured, message("p", .user, tokens: 10)], [], total: 3_000).keptMessages[1]
            check("6.4 a touched message loses its measured costs (estimates take over)", touched.toolInteractions.count == 3 && touched.measuredTokens == nil && touched.measuredToolTokens == nil)
            let untouched = plan([message("t", .user, tokens: 10), measured, message("p", .user, tokens: 10)], []).keptMessages[1]
            check("6.5 an untouched message keeps its measured costs", untouched.measuredTokens == 99 && untouched.measuredToolTokens == 98)
            let quiet = round("q", tokens: 1_000)
            let loud = ToolInteraction(assistantMessage: AssistantToolCallMessage(content: nil, toolCalls: quiet.assistantMessage.toolCalls,
                                                                                  reasoning: .string(String(repeating: "t", count: 1_600))), results: quiet.results)
            let delta = SubagentRunner.estimatedContextTokens(messages: [], interactions: [loud]) - SubagentRunner.estimatedContextTokens(messages: [], interactions: [quiet])
            check("6.6 replayed reasoning is part of a round's estimate (+400)", delta >= 390 && delta <= 410, "\(delta)")
        }

        print("7. Plan is deterministic and total-preserving")
        do {
            var messages: [Message] = []
            for i in 0..<6 { messages.append(message("ask\(i)", .user, tokens: 8_000)); messages.append(message("reply\(i)", .assistant, tokens: 8_000)) }
            let rounds = (0..<30).map { round("w\($0)", tokens: 3_000) }
            let a = plan(messages, rounds), b = plan(messages, rounds)
            check("7.1 same input, same plan", a.keptMessages.map(tag) == b.keptMessages.map(tag) && a.keptInteractions.map(tag) == b.keptInteractions.map(tag))
            let allMessages = (a.evictedDialogue + a.keptMessages).map(tag)
            check("7.2 every dialogue message is either kept or evicted, order preserved", allMessages == messages.map(tag))
            check("7.3 every round is either kept or evicted, order preserved", (a.evictedWork + a.keptInteractions).map(tag) == rounds.map(tag))
        }

        print("8. Real runner: eager compaction at resume, then a folded second compaction")
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-subagent-compaction-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            for (name, child) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
                setenv(name, root.appendingPathComponent(child).path, 1)
            }
            UserDefaults.standard.setVolatileDomain([
                "ada.applyPatchEnabled": false, "ada.shortcutsEnabled": false,
                KeychainHelper.serviceKeysMetadataDefaultsKey: Data("[]".utf8)
            ], forName: UserDefaults.argumentDomain)
            FileDescriptionsStore._testStoreURL = root.appendingPathComponent("descriptions.json")
            let server = try CaptureServer(); defer { server.stop() }
            let base = "http://127.0.0.1:\(server.port)"
            let settings = [
                KeychainHelper.llmProviderKey: LLMProvider.openAICompatible.rawValue,
                KeychainHelper.openAICompatibleBaseURLKey: base + "/v1",
                KeychainHelper.openAICompatibleApiKeyKey: "synthetic-selftest-key",
                KeychainHelper.openAICompatibleModelKey: "glm-5.3",
                KeychainHelper.textOnlyModelEnabledKey: "false",
                KeychainHelper.subagentTurnTokenBudgetKey: "1000",   // tail 250: dialogue 150, work 100
            ]
            for (key, value) in settings { try KeychainHelper.save(key: key, value: value) }
            func response(_ text: String, prompt: Int = 1) throws -> String {
                let body: [String: Any] = ["id": "s", "choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
                    "usage": ["prompt_tokens": prompt, "completion_tokens": 1, "total_tokens": prompt + 1]]
                return String(data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
            }
            func requestBodies() -> [String] { server.completeRequests.map { String(decoding: $0.body, as: UTF8.self) } }
            let runner = SubagentRunner()
            let service = OpenRouterService(); await service.configure(apiKey: "synthetic-selftest-key")
            let executor = ToolExecutor(outputMode: .subagent)
            let images = StoragePaths.dataRoot.appendingPathComponent("images")
            let documents = StoragePaths.dataRoot.appendingPathComponent("documents")
            let invocation = SubagentRunner.Invocation(subagentType: "general-purpose", description: "Selftest worker",
                taskPrompt: "First task for the selftest worker", modelOverride: nil, runInBackground: false)
            server.script([try response("first answer", prompt: 300)])
            let first = await runner.run(invocation: invocation, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                         imagesDirectory: images, documentsDirectory: documents, parentTools: [])
            check("8.1 fresh run persisted", first.error == nil && first.sessionPersisted, first.error ?? "")
            server.clear()
            // 8a. Oversized by WORK: six small exchanges (90 tokens) plus ten
            // 100-token rounds (1090 ≥ the 850 threshold). At resume the newest
            // two dialogue messages are the re-injected reply and the new
            // prompt; the planted exchanges fit the 150-token dialogue budget,
            // so only rounds are evicted (floor: newest three stay).
            let exchanges = (0..<6).map { message($0 % 2 == 0 ? "ask\($0)" : "reply\($0)", $0 % 2 == 0 ? .user : .assistant, tokens: 15) }
            let rounds = (0..<10).map { round("w\($0)", tokens: 100) }
            await SubagentSessionRegistry.shared.applyCompaction(sessionId: first.sessionId, messages: exchanges, toolInteractions: rounds)
            server.script([try response("EAGER_SUMMARY_TEXT"), try response("eager answer", prompt: 400)])
            let eager = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                         imagesDirectory: images, documentsDirectory: documents, parentTools: [])
            check("8.2 eager run persisted", eager.error == nil && eager.sessionPersisted && eager.finalMessage == "eager answer", eager.error ?? eager.finalMessage)
            var bodies = requestBodies()
            check("8.3 two requests: summarizer, then the continuation", bodies.count == 2, "\(bodies.count)")
            if bodies.count == 2 {
                check("8.4 summarizer sees the seven oldest rounds and no dialogue block",
                      bodies[0].contains("=== WORK") && bodies[0].contains("[TOOL RESULT] <w0>") && bodies[0].contains("<w6>")
                      && !bodies[0].contains("<w7>") && !bodies[0].contains("=== DIALOGUE WITH THE MAIN AGENT") && !bodies[0].contains("=== PRIOR SUMMARY"))
                check("8.5 summarizer prompt asks for the dialogue section first", bodies[0].contains("0. DIALOGUE WITH THE MAIN AGENT") && bodies[0].contains("## Dialogue with the main agent"))
                check("8.6 continuation replays the summary, every planted exchange, the newest three rounds and the prompt",
                      bodies[1].contains("EAGER_SUMMARY_TEXT") && bodies[1].contains("<ask0>") && bodies[1].contains("<reply5>")
                      && bodies[1].contains("<w7>") && bodies[1].contains("<w9>") && !bodies[1].contains("<w6>") && bodies[1].contains("First task for the selftest worker"))
            }
            let sessionFile = StoragePaths.dataRoot.appendingPathComponent("subagent_sessions/\(first.sessionId).json")
            let sessionDecoder = JSONDecoder(); sessionDecoder.dateDecodingStrategy = .iso8601
            let stored = try sessionDecoder.decode(SubagentSessionRegistry.Session.self, from: Data(contentsOf: sessionFile))
            check("8.7 persisted session: one summary first, dialogue intact after it, three rounds kept",
                  stored.messages.count >= 3 && SubagentRunner.isCompactionSummary(stored.messages[0]) && stored.messages[0].content.contains("EAGER_SUMMARY_TEXT")
                  && tag(stored.messages[1]) == "ask0" && stored.messages.filter(SubagentRunner.isCompactionSummary).count == 1
                  && stored.toolInteractions.count == 3 && stored.toolInteractions.map(tag) == ["w7", "w8", "w9"])
            server.clear()
            // 8b. Oversized by DIALOGUE: six 350-token exchanges appended. The
            // earlier summary is folded, the planted dialogue is evicted down
            // to the newest two messages, the three rounds stay (floor).
            var again = stored.messages
            again.append(contentsOf: (6..<12).map { message($0 % 2 == 0 ? "ask\($0)" : "reply\($0)", $0 % 2 == 0 ? .user : .assistant, tokens: 350) })
            await SubagentSessionRegistry.shared.applyCompaction(sessionId: first.sessionId, messages: again, toolInteractions: stored.toolInteractions)
            server.script([try response("FOLDED_SUMMARY_TEXT"), try response("folded answer", prompt: 400)])
            let folded = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                          imagesDirectory: images, documentsDirectory: documents, parentTools: [])
            check("8.8 folded run persisted", folded.error == nil && folded.sessionPersisted, folded.error ?? "")
            bodies = requestBodies()
            if bodies.count == 2 {
                check("8.9 summarizer: prior summary block, then the evicted dialogue oldest first, no work block",
                      bodies[0].contains("=== PRIOR SUMMARY") && bodies[0].contains("EAGER_SUMMARY_TEXT")
                      && ordered(bodies[0], "=== PRIOR SUMMARY", "=== DIALOGUE WITH THE MAIN AGENT")
                      && bodies[0].contains("[MAIN AGENT] <ask0>") && bodies[0].contains("[SUBAGENT] <reply11>") && bodies[0].contains("[SUBAGENT] first answer") && !bodies[0].contains("[SUBAGENT] eager answer")
                      && ordered(bodies[0], "<ask0>", "<reply11>") && !bodies[0].contains("=== WORK"))
                check("8.10 continuation carries exactly one summary (the new one), the newest two messages, the three rounds",
                      bodies[1].contains("FOLDED_SUMMARY_TEXT") && !bodies[1].contains("EAGER_SUMMARY_TEXT") && !bodies[1].contains("<ask0>")
                      && !bodies[1].contains("<reply11>") && bodies[1].contains("<w7>") && bodies[1].contains("First task for the selftest worker"))
            } else {
                check("8.9 two requests on the folded run", false, "\(bodies.count)")
            }
            let restored = try sessionDecoder.decode(SubagentSessionRegistry.Session.self, from: Data(contentsOf: sessionFile))
            check("8.11 persisted session carries one summary (folded), not a stack, and the three rounds",
                  restored.messages.filter(SubagentRunner.isCompactionSummary).count == 1 && restored.messages[0].content.contains("FOLDED_SUMMARY_TEXT")
                  && restored.toolInteractions.count == 3)
            server.clear()
            // 8c. Third compaction: the summarizer input must carry the previous
            // summary AND every newly evicted exchange verbatim, so nothing is
            // lost before the model sees it, however many times this repeats.
            var third = restored.messages
            third.append(contentsOf: [message("ask12", .user, tokens: 350), message("reply13", .assistant, tokens: 350)])
            await SubagentSessionRegistry.shared.applyCompaction(sessionId: first.sessionId, messages: third, toolInteractions: restored.toolInteractions)
            server.script([try response("THIRD_SUMMARY_TEXT"), try response("third answer", prompt: 400)])
            let last = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                        imagesDirectory: images, documentsDirectory: documents, parentTools: [])
            check("8.12 third run persisted", last.error == nil && last.sessionPersisted, last.error ?? "")
            bodies = requestBodies()
            if bodies.count == 2 {
                check("8.13 summarizer input: previous summary verbatim + the new exchanges + the re-injected reply, nothing older",
                      bodies[0].contains("FOLDED_SUMMARY_TEXT") && bodies[0].contains("[MAIN AGENT] <ask12>") && bodies[0].contains("[SUBAGENT] <reply13>")
                      && bodies[0].contains("[SUBAGENT] eager answer") && !bodies[0].contains("[SUBAGENT] folded answer") && !bodies[0].contains("EAGER_SUMMARY_TEXT") && !bodies[0].contains("<ask0>"))
                check("8.14 continuation carries only the third summary", bodies[1].contains("THIRD_SUMMARY_TEXT") && !bodies[1].contains("FOLDED_SUMMARY_TEXT") && !bodies[1].contains("<ask12>"))
            } else {
                check("8.13 two requests on the third run", false, "\(bodies.count)")
            }
            let final = try sessionDecoder.decode(SubagentSessionRegistry.Session.self, from: Data(contentsOf: sessionFile))
            check("8.15 still exactly one summary after three compactions", final.messages.filter(SubagentRunner.isCompactionSummary).count == 1 && final.messages[0].content.contains("THIRD_SUMMARY_TEXT"))
            check("8.16 no capture errors", server.errors.isEmpty, server.errors.joined(separator: "; "))
        }

        print("9. Responses mode: captured request after compaction, save/reload")
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("briglia-subagent-compaction-responses-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            for (name, child) in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache")] {
                setenv(name, root.appendingPathComponent(child).path, 1)
            }
            FileDescriptionsStore._testStoreURL = root.appendingPathComponent("descriptions.json")
            let server = try CaptureServer(); defer { server.stop() }
            try ProviderProfiles.saveProfile(.custom, apiKey: "synthetic-responses-key", baseURL: "http://127.0.0.1:\(server.port)/v1",
                                             model: "fixture-model", effort: nil, textOnly: false, wireProtocol: .responses)
            try ProviderProfiles.activate(.custom)
            try KeychainHelper.save(key: KeychainHelper.subagentTurnTokenBudgetKey, value: "1000")
            let file = root.appendingPathComponent("read.txt")
            try Data(("<FILE_BODY>" + String(repeating: "f", count: 1_600)).utf8).write(to: file)
            func body(_ text: String, id: String, tool: Bool = false) throws -> String {
                var output: [[String: Any]] = [
                    ["type": "reasoning", "id": "rs_" + id, "summary": [], "encrypted_content": "opaque_" + id],
                    ["type": "message", "role": "assistant", "status": "completed", "id": "msg_" + id,
                     "content": [["type": "output_text", "text": text, "annotations": []]]]]
                if tool {
                    let arguments = String(data: try JSONSerialization.data(withJSONObject: ["path": file.path]), encoding: .utf8)!
                    output.append(["type": "function_call", "id": "fc_" + id, "call_id": "call_" + id, "status": "completed", "name": "read_file", "arguments": arguments])
                }
                let snapshot: [String: Any] = ["id": "resp_" + id, "status": "completed", "output": output,
                    "usage": ["input_tokens": 100, "input_tokens_details": ["cached_tokens": 0], "output_tokens": 30, "output_tokens_details": ["reasoning_tokens": 20]]]
                return String(data: try JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys), encoding: .utf8)!
            }
            func input(_ request: CapturedHTTPRequest) throws -> [[String: Any]] {
                let object = try JSONSerialization.jsonObject(with: request.body) as! [String: Any]
                return object["input"] as! [[String: Any]]
            }
            let runner = SubagentRunner()
            let service = OpenRouterService(); await service.configure(apiKey: "synthetic-responses-key")
            let executor = ToolExecutor(outputMode: .subagent)
            let invocation = SubagentRunner.Invocation(subagentType: "general-purpose", description: "Responses worker",
                taskPrompt: "Read the fixture five times", modelOverride: nil, runInBackground: false)
            // Five tool rounds (each ≈450 tokens of result) then a final answer.
            server.script((0..<5).map { try! body("Reading \($0)", id: "r\($0)", tool: true) } + [try body("Worker completed", id: "final")])
            let first = await runner.run(invocation: invocation, sessionId: nil, openRouterService: service, toolExecutor: executor,
                                         imagesDirectory: root, documentsDirectory: root, parentTools: [AvailableTools.readFile])
            check("9.1 Responses-mode run with five rounds persisted", first.error == nil && first.sessionPersisted && first.turnsUsed == 6, first.error ?? "\(first.turnsUsed)")
            let sessionFile = StoragePaths.dataRoot.appendingPathComponent("subagent_sessions/\(first.sessionId).json")
            let sessionDecoder = JSONDecoder(); sessionDecoder.dateDecodingStrategy = .iso8601
            let stored = try sessionDecoder.decode(SubagentSessionRegistry.Session.self, from: Data(contentsOf: sessionFile))
            check("9.2 final reply owns the five rounds and a replay envelope", stored.messages.last?.toolInteractions.count == 5 && stored.messages.last?.responsesReplay != nil)
            server.clear()
            // Resume: the session (≈2.3k tokens) is over the 850 threshold → eager
            // compaction: the two oldest rounds go, the newest three stay
            // (floor), the final text and its envelope stay untouched.
            server.script([try body("RESPONSES_SUMMARY_TEXT", id: "sum"), try body("Resumed worker", id: "resumed")])
            let resumed = await runner.run(invocation: invocation, sessionId: first.sessionId, openRouterService: service, toolExecutor: executor,
                                           imagesDirectory: root, documentsDirectory: root, parentTools: [AvailableTools.readFile])
            check("9.3 resumed run persisted after compaction", resumed.error == nil && resumed.sessionPersisted && resumed.finalMessage == "Resumed worker", resumed.error ?? resumed.finalMessage)
            let requests = server.completeRequests
            check("9.4 two Responses requests: summarizer, then continuation", requests.count == 2, "\(requests.count)")
            if requests.count == 2 {
                let summarizer = String(decoding: requests[0].body, as: UTF8.self)
                check("9.5 summarizer input carries exactly the two evicted rounds (calls + results) and no dialogue",
                      summarizer.contains("=== WORK") && summarizer.components(separatedBy: "[TOOL CALL] read_file").count == 3
                      && summarizer.components(separatedBy: "[TOOL RESULT]").count == 3 && summarizer.contains("<FILE_BODY>")
                      && !summarizer.contains("=== DIALOGUE WITH THE MAIN AGENT") && !summarizer.contains("=== PRIOR SUMMARY"))
                let items = try input(requests[1])
                let encrypted = items.compactMap { $0["encrypted_content"] as? String }
                let callIDs = items.compactMap { $0["call_id"] as? String }
                let outputs = items.filter { ($0["type"] as? String) == "function_call_output" }.compactMap { $0["call_id"] as? String }
                let texts = items.compactMap { item -> String? in
                    guard let content = item["content"] as? [[String: Any]] else { return nil }
                    return content.compactMap { $0["text"] as? String }.joined()
                }
                check("9.6 retained rounds replay natively (their reasoning, calls and outputs), evicted rounds are absent",
                      Set(encrypted).isSuperset(of: ["opaque_r2", "opaque_r3", "opaque_r4"]) && !encrypted.contains("opaque_r0") && !encrypted.contains("opaque_r1")
                      && Set(callIDs).isSuperset(of: ["call_r2", "call_r3", "call_r4"]) && !callIDs.contains("call_r0") && !callIDs.contains("call_r1")
                      && Set(outputs) == ["call_r2", "call_r3", "call_r4"], "encrypted \(encrypted) calls \(callIDs) outputs \(outputs)")
                check("9.7 the final reply's encrypted reasoning replays natively after the partial strip", encrypted.contains("opaque_final"))
                check("9.8 the summary precedes the retained work and the reply text follows it verbatim",
                      texts.contains { $0.hasPrefix(SubagentRunner.compactionSummaryHeader) && $0.contains("RESPONSES_SUMMARY_TEXT") } && texts.contains("Worker completed")
                      && (items.firstIndex { (($0["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("RESPONSES_SUMMARY_TEXT") == true } ?? Int.max)
                         < (items.firstIndex { ($0["call_id"] as? String) == "call_r2" } ?? -1))
            }
            let reloaded = try sessionDecoder.decode(SubagentSessionRegistry.Session.self, from: Data(contentsOf: sessionFile))
            let finalReply = reloaded.messages.first { $0.role == .assistant && $0.content == "Worker completed" }
            check("9.9 save/reload: one summary first, the final reply keeps three rounds, its text and its envelope",
                  reloaded.messages.first.map(SubagentRunner.isCompactionSummary) == true && finalReply?.toolInteractions.count == 3
                  && finalReply?.responsesReplay != nil && finalReply?.compactToolLog == nil)
            check("9.10 no capture errors, script exhausted", server.errors.isEmpty && server.remainingResponses == 0, server.errors.joined(separator: "; "))
        }

        print("Subagent compaction selftest: \(total - failures)/\(total) passed")
        if failures > 0 { throw Failure(description: "\(failures) check(s) failed") }
    }
}
