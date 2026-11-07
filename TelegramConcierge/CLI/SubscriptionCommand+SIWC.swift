import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// `briglia subscription … --official` (SIWC plan §3.10): Sign in with
// ChatGPT from a terminal. While a daemon runs it owns the attempt and its
// listener (every action is forwarded); otherwise this process owns it and
// publishes through a short offline commit. A pasted address is read from
// standard input, handed to the one paste parser and never printed.

enum SIWCTerminal {
    /// One owner, whichever it is.
    struct Owner {
        var start: (SIWCFlow.Mode) async -> [String: Any]
        var paste: (String) async -> [String: Any]
        var status: () async -> [String: Any]
        var cancel: (_ failed: Bool) async -> [String: Any]
    }

    @MainActor
    static var local: Owner {
        Owner(start: { await SIWCFlow.shared.start(mode: $0).json },
              paste: { text in
                  var r = SIWCFlow.shared.status.json
                  r["reply"] = await SIWCFlow.shared.paste(text)
                  r.merge(SIWCFlow.shared.status.json) { $1 }
                  return r
              },
              status: { SIWCFlow.shared.status.json },
              cancel: { await SIWCFlow.shared.cancel(browserFailed: $0).json })
    }

    static var remote: Owner {
        func send(_ o: [String: Any]) async -> [String: Any] {
            switch await SIWCRemote.forward(o) {
            case .reply(let r): return r
            case .noOwner: return ["state": "failed", "message": "Briglia stopped while you were signing in; nothing was saved."]
            case .unsupported: return ["state": "failed", "message": SettingsClient.unsupportedMessage]
            case .lost: return ["state": "failed", "message": "The connection to Briglia was lost; check ChatGPT in briglia menu."]
            }
        }
        return Owner(start: { await send(["action": "start", "mode": $0.rawValue]) },
                     paste: { await send(["action": "paste", "text": $0]) },
                     status: { await send(["action": "status"]) },
                     cancel: { await send(["action": $0 ? "failed" : "cancel"]) })
    }

    /// Whether a daemon owns sign-ins right now.
    static func daemonOwner() async -> SIWCRemote.ClientResult {
        await SIWCRemote.forward(["action": "status"], timeout: 5)
    }

    /// Read lines from stdin off the main actor (a blocked read never holds
    /// the actor); each line is handed over once, never printed.
    final class LineReader: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func start() {
            let thread = Thread { [weak self] in
                while let line = readLine(strippingNewline: true) { self?.push(line) }
            }
            thread.start()
        }
        private func push(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        func take() -> String? { lock.lock(); defer { lock.unlock() }; return lines.isEmpty ? nil : lines.removeFirst() }
    }

    /// `subscription login --official`. Returns the process exit code.
    @MainActor
    static func login() async -> Int32 {
        let owner: Owner
        switch await daemonOwner() {
        case .reply: owner = remote
        case .unsupported: print("✖ " + SettingsClient.unsupportedMessage); return 1
        case .noOwner, .lost: owner = local
        }
        let ssh = ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil || ProcessInfo.processInfo.environment["SSH_TTY"] != nil
        let started = await owner.start(ssh ? .paste : .browser)
        guard started["state"] as? String == "waiting", let url = started["url"] as? String else {
            print("✖ " + (started["message"] as? String ?? "ChatGPT sign-in could not start.")); return 1
        }
        print("Sign in to ChatGPT (\(SIWCSurface.label)). Open this link in a browser:\n\n  \(url)\n")
        print("If the browser is on this computer, Briglia finishes on its own. If it is on another device, after you approve copy the address the browser ends on (a page that can't load) and paste it here. \(SIWCFlow.pasteHint)")
        print("Type `failed` if ChatGPT shows an error, `cancel` to stop. The link expires in 10 minutes.")
        // Ctrl-C cancels the attempt (its pending marker and reservation).
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        var interrupted = false
        interrupt.setEventHandler { interrupted = true }
        interrupt.resume()
        defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }
        let reader = LineReader()
        reader.start()
        while true {
            if interrupted { let r = await owner.cancel(false); print(r["message"] as? String ?? "Cancelled."); return 1 }
            if let line = reader.take() {
                let word = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if word == "cancel" || word == "failed" {
                    let r = await owner.cancel(word == "failed"); print(r["message"] as? String ?? "Cancelled."); return 1
                }
                if !word.isEmpty {
                    let r = await owner.paste(line)
                    if r["state"] as? String == "waiting" { print(r["reply"] as? String ?? CallbackPaste.Rejection.notSignInAddress.rawValue); continue }
                    return report(r)
                }
            }
            let s = await owner.status()
            let state = s["state"] as? String ?? "failed"
            if state != "waiting" && state != "finishing" { return report(s) }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    static func report(_ r: [String: Any]) -> Int32 {
        let ok = r["state"] as? String == "done" && r["outcome"] as? String != "plan_usage_off"
        print((ok ? "" : "✖ ") + (r["message"] as? String ?? "ChatGPT sign-in finished."))
        if r["first_use"] as? Bool == true, ok { print(SIWCFlow.firstUseNotice) }
        if r["legacy_login_kept"] as? Bool == true, ok {
            print("Your legacy ChatGPT login is still saved on this computer. To remove it: briglia subscription logout --legacy.")
        }
        if r["outcome"] as? String == "plan_usage_off" { print("Run `briglia subscription login --official` again and allow plan usage.") }
        return ok ? 0 : 1
    }

    /// logout / cancel / use / status on the SIWC route.
    @MainActor
    static func simple(_ action: String) async -> Int32 {
        switch await daemonOwner() {
        case .reply:
            if action == "status" { printStatus(); return 0 }
            switch await SIWCRemote.forward(["action": action], timeout: 60) {
            case .reply(let r):
                print((r["state"] as? String == "failed" ? "✖ " : "") + (r["message"] as? String ?? "Done."))
                return r["state"] as? String == "failed" ? 1 : 0
            default: print("✖ The connection to Briglia was lost; check ChatGPT in briglia menu."); return 1
            }
        case .unsupported: print("✖ " + SettingsClient.unsupportedMessage); return 1
        case .noOwner, .lost: break
        }
        switch action {
        case "status": printStatus(); return 0
        case "logout":
            let r = await SIWCSurface.logout()
            print((r.ok ? "" : "✖ ") + r.message); return r.ok ? 0 : 1
        case "use":
            switch await SIWCFlow.shared.activate(origin: "subscription") {
            case .success: print("Briglia now uses \(SIWCSurface.label)."); return 0
            case .failure(let why): print("✖ Not switched: " + why); return 1
            }
        default:
            print("No ChatGPT sign-in is waiting in this terminal."); return 0
        }
    }

    static func printStatus() {
        let lines = SIWCSurface.statusLines()
        print(lines.isEmpty ? "\(SIWCSurface.label): not signed in." : lines.joined(separator: "\n"))
    }
}
