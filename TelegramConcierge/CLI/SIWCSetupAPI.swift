import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// setup-api Sign in with ChatGPT actions (SIWC plan §3.10): `siwc_start`,
// `siwc_paste`, `siwc_status`, `siwc_cancel` on the `subscription` verb,
// beside the legacy device-code actions (unchanged).
//
// - A daemon runs: every action is forwarded to it (it owns the attempt,
//   its verifier and its listener).
// - No daemon: `siwc_start` with `"wait": true` makes THIS process the
//   owner. Nothing is held while the human waits (no transaction, share,
//   auth or replacement lock, no instance lease); one flushed progress event
//   goes to stderr first, the usual single JSON object to stdout at the end.
//   SIGTERM/SIGINT cancel. Other actions answer `no_owner`.
// - A pasted address never reaches stdout, stderr or a log: only the fixed
//   reply does.

enum SIWCSetupAPI {
    static let actions: Set<String> = ["siwc_start", "siwc_paste", "siwc_status", "siwc_cancel", "siwc_failed"]

    /// Selftest seam: the stderr progress line.
    nonisolated(unsafe) static var progressForTesting: ((String) -> Void)?

    static func noOwner() -> [String: Any] {
        SetupAPICore.errorResponse(code: "no_owner", message: "No Briglia owns a ChatGPT sign-in right now. Start one with siwc_start and \"wait\": true, or paste in the terminal or Telegram.")
    }

    @MainActor
    static func perform(_ request: [String: Any], forward: ([String: Any]) async -> SIWCRemote.ClientResult = { await SIWCRemote.forward($0) },
                        flow: SIWCFlow = .shared) async -> [String: Any] {
        let action = request["action"] as? String ?? ""
        let remoteAction: [String: String] = ["siwc_start": "start", "siwc_paste": "paste", "siwc_status": "status",
                                              "siwc_cancel": "cancel", "siwc_failed": "failed"]
        var body: [String: Any] = ["action": remoteAction[action] ?? "status"]
        if action == "siwc_start" { body["mode"] = request["mode"] as? String ?? "browser" }
        if action == "siwc_paste" {
            guard let text = request["text"] as? String else { return SetupAPICore.errorResponse(code: "invalid_request", message: "siwc_paste needs \"text\".") }
            body["text"] = text
        }
        switch await forward(body) {
        case .reply(let reply):
            var out = reply
            out["ok"] = (reply["state"] as? String) != "failed"
            out["schema"] = SetupAPICore.schemaVersion
            out["owner"] = "daemon"
            return out
        case .unsupported:
            return SetupAPICore.errorResponse(code: "owner_protocol_unsupported", message: SettingsClient.unsupportedMessage)
        case .lost:
            return SetupAPICore.errorResponse(code: "uncertain", message: "The connection to Briglia was lost; check siwc_status.")
        case .noOwner: break
        }
        guard action == "siwc_start", request["wait"] as? Bool == true else { return noOwner() }
        return await waitMode(request, flow: flow)
    }

    /// Offline wait mode: this process owns the attempt until callback,
    /// cancel (signal) or the 10-minute expiry.
    @MainActor
    static func waitMode(_ request: [String: Any], flow: SIWCFlow) async -> [String: Any] {
        let mode = SIWCFlow.Mode(rawValue: request["mode"] as? String ?? "browser") ?? .browser
        let started = await flow.start(mode: mode)
        guard started.state == "waiting", let url = started.url else {
            return SetupAPICore.errorResponse(code: "refused", message: started.message ?? "ChatGPT sign-in could not start.")
        }
        var event: [String: Any] = ["event": "siwc_authorize", "url": url, "expires_at": started.expiresAt ?? 0]
        if let pending = started.pending { event["pending"] = pending }
        if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            if let progressForTesting { progressForTesting(line) }
            else { FileHandle.standardError.write(Data((line + "\n").utf8)); fflush(stderr) }
        }
        // SIGTERM / SIGINT: the attempt, its pending marker and its host
        // reservation are cleared; the answer is {"state":"cancelled"}.
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { Task { @MainActor in _ = await flow.cancel() } }
            source.resume()
            sources.append(source)
        }
        defer { for s in sources { s.cancel() } }
        let final = await flow.waitForEnd()
        var out = final.json
        out["ok"] = final.state == "done" && final.outcome != "plan_usage_off"
        out["schema"] = SetupAPICore.schemaVersion
        out["owner"] = "this_process"
        if final.state == "cancelled" { out["state"] = "cancelled" }
        return out
    }

    /// The `status` verb's Sign in with ChatGPT fields.
    static func statusFields(stored: [String: String] = KeychainHelper.loadSnapshot()) -> [String: Any] {
        var out: [String: Any] = [:]
        out["chatgpt_route"] = SIWCSurface.route(stored) ?? NSNull()
        let info = SIWCSurface.info(stored: stored)
        out["chatgpt_plan_state"] = info.selected ? (info.login == "signed_in" ? (info.planState?.rawValue ?? "ok") : info.login) : NSNull()
        out["siwc_opt_in"] = SIWCSurface.optedIn(stored)
        return out
    }
}
