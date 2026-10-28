import ArgumentParser
import Foundation

/// Hidden selftest child (development builds: an `assistant` member): runs
/// REAL tool calls through `ToolExecutor` under the selected profile, one
/// JSON command per stdin line, so the stage-3 selftest can drive two
/// assistants against each other (claims, tripwire, heads-ups, ambient).
///
/// Commands: {"op":"turn-start"} {"op":"turn-end"} {"op":"ambient"}
/// {"op":"tool","name":"write_file","args":{…}} {"op":"quit"}.
/// Every answer is one line: `R <json>`.
struct BoardProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__board-probe",
        abstract: "Internal: multi-assistant stage-3 probe.",
        shouldDisplay: false
    )

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard adaCLIVersion.hasSuffix("-dev"), MemberEntry.current != nil else {
            print("R {\"error\":\"needs a development build and an assistant lease\"}"); return
        }
        BoardWriter.throttleSeconds = 0
        ClaimScopes.tickSeconds = 0.2
        let executor = ToolExecutor()
        var turn: UUID?
        func answer(_ object: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            print("R " + String(decoding: data, as: UTF8.self))
        }
        print("PROBE_READY \(AssistantProfile.selectedName) context=\(MultiAssistant.context() != nil)")
        while let line = readLine() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let op = obj["op"] as? String else { answer(["error": "bad command"]); continue }
            switch op {
            case "turn-start":
                let id = UUID(); turn = id
                ClaimScopes.shared.turnStarted(id)
                answer(["ok": true])
            case "turn-end":
                if let id = turn { ClaimScopes.shared.turnEnded(id) }
                turn = nil
                // The release runs on a detached task: wait until the
                // scope bookkeeping is done (bounded).
                for _ in 0..<50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if ClaimScopes.shared.pendingScopesForTesting.isEmpty { break }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                answer(["ok": true])
            case "ambient":
                answer(["text": await AmbientStatus.currentText(omit: false) ?? ""])
            case "tool":
                let name = obj["name"] as? String ?? ""
                let args = obj["args"] ?? [:]
                let argData = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
                let call = ToolCall(id: "probe_\(UUID().uuidString.prefix(6))", type: "function",
                                    function: FunctionCall(name: name, arguments: String(decoding: argData, as: UTF8.self)))
                do {
                    let result = try await executor.execute(call)
                    answer(["content": result.content])
                } catch {
                    answer(["error": "\(error)"])
                }
            case "tools":
                answer(["names": AvailableTools.coreTools(webSearchAvailable: false).map(\.function.name)])
            case "quit":
                answer(["ok": true])
                return
            default:
                answer(["error": "unknown op"])
            }
        }
    }
}
