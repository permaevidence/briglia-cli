import Foundation

// Sign in with ChatGPT requests between processes (SIWC plan §3.10): while a
// daemon runs, it owns the attempt, its verifier and its 127.0.0.1 listener;
// the terminal command and setup-api forward every action to it over the
// owner socket (peer-UID verified). A pasted address travels only inside
// that request and is never echoed, logged or stored on either side.

enum SIWCRemote {
    /// The owner side: one request, answered with a status object.
    @MainActor
    static func handle(_ object: [String: Any], flow: SIWCFlow = .shared) async -> [String: Any] {
        let action = object["action"] as? String ?? ""
        var reply: [String: Any] = [:]
        switch action {
        case "start":
            let mode = SIWCFlow.Mode(rawValue: object["mode"] as? String ?? "browser") ?? .browser
            let status = await flow.start(mode: mode, consent: object["consent"] as? Bool ?? false,
                                          newRegistration: object["new"] as? Bool ?? false)
            if status.state == "waiting" { _ = await SIWCSurface.setOptIn(true, origin: "siwc") }
            reply = status.json
        case "paste":
            let text = object["text"] as? String ?? ""
            reply = flow.status.json
            reply["reply"] = await flow.paste(text)
            reply.merge(flow.status.json) { $1 }
        case "status": reply = flow.status.json
        case "cancel": reply = await flow.cancel().json
        case "failed": reply = await flow.cancel(browserFailed: true).json
        case "logout":
            let r = await SIWCSurface.logout()
            reply = ["state": r.ok ? "done" : "failed", "message": r.message]
        case "use":
            switch await flow.activate(origin: "siwc") {
            case .success(let applied): reply = ["state": "done", "outcome": applied ? "signed_in" : "pending",
                "message": applied ? "Briglia now uses ChatGPT (Sign in with ChatGPT)." : "Saved; Briglia switches when its current task finishes."]
            case .failure(let why): reply = ["state": "failed", "message": why]
            }
        default:
            reply = ["state": "failed", "message": "unknown Sign in with ChatGPT action"]
        }
        reply["owner"] = "daemon"
        return reply
    }

    /// The client side: forward to the running owner, nil when none runs
    /// (the caller then owns the attempt itself). `unsupported` = an older
    /// daemon without this request type.
    enum ClientResult { case reply([String: Any]), noOwner, unsupported, lost }

    static func forward(_ object: [String: Any], timeout: Double = 30) async -> ClientResult {
        var body = object
        body["type"] = "siwc"
        let request = body
        do {
            let reply = try await Task.detached { try OwnerSocket.request(request, timeout: timeout) }.value
            return .reply(reply)
        } catch OwnerSocket.Failure.unavailable {
            return .noOwner
        } catch OwnerSocket.Failure.nack(let why) {
            return why.contains("unknown request type") ? .unsupported : .reply(["state": "failed", "message": why])
        } catch {
            return .lost
        }
    }
}
