import Foundation

/// Read-only status of Briglia's private runtimes for doctor, `/status`, the
/// menu and `briglia agentmail status` (security plan v24 §7.8.1 step 8,
/// §7.9.6). Lock-free reads; never "up to date" unless the validated
/// `verified` copy equals this build's pin.
enum RuntimeStatus {
    static func agentMail() -> SecurityStatus.Component? {
        let name = "AgentMail CLI"
        guard let pin = AgentMailService.runtimePin else { return nil }
        let st = RuntimeSelectionStore.peek()?[.agentmail]
        if let hold = st?.hold {
            return .init(name: name, state: .off, detail: AgentMailService.offMessage(AgentMailService.holdText(hold)))
        }
        let receipt = (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.agentmail))) ?? nil
        if let v = receipt?.verifiedRecord {
            guard AgentMailService.agentMailBrokerInstalled() else {
                return .init(name: name, state: .unknownState, detail: "the install does not match its receipt; run `briglia agentmail repair`")
            }
            if v.pin == pin { return .init(name: name, state: .pinned, detail: "\(v.version), Briglia's private copy (archive SHA-256 compiled in)") }
            let last = st?.attempts.last
            let tail = last?.result.flatMap { $0.hasPrefix("failed") ? "update failed: \($0.dropFirst("failed: ".count)); retried at the next start, or run `briglia agentmail upgrade`" : nil }
                ?? "updating when idle"
            return .init(name: name, state: .differs, detail: "AgentMail CLI \(v.version) still in use; this Briglia expects \(pin.version) (\(tail))")
        }
        if AgentMailService.legacyInstalledVersion() != nil {
            return .init(name: name, state: .differs, detail: "an older Briglia copy in ~/.local/bin is not used any more; Briglia installs its own \(pin.version) at the next start")
        }
        guard EmailCalendarProvider.current == .agentmail else { return nil }
        return .init(name: name, state: .notInstalled, detail: "not installed for Briglia (`briglia agentmail upgrade` or the email step of `briglia menu`)")
    }

    static func node() -> SecurityStatus.Component? {
        let name = "Node.js"
        guard let sel = RuntimeSelectionStore.peek()?[.node].selection else { return nil }
        if NodeRuntime.restartPending() {
            return .init(name: name, state: .restartPending, detail: "Briglia still runs the previous Node.js for the browser; send /restart to switch")
        }
        switch sel.providerClass {
        case "private-exact":
            // Validate the copy itself, not the cached version string (review follow-up).
            let rcpt = (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.node))) ?? nil
            guard let pin = NodeRuntime.runtimePin, let vr = rcpt?.verifiedRecord,
                  PrivateRuntimeEngine.currentState(.node) == .ref(vr.directory),
                  PrivateRuntimeEngine.validate(NodeRuntime.spec(pin: pin), vr) == nil else {
                return .init(name: name, state: .unknownState, detail: "Briglia's private Node.js copy does not match its receipt; it is reinstalled at the next start")
            }
            if vr.pin != pin {
                return .init(name: name, state: .differs, detail: "\(vr.version) in use; this Briglia expects \(NodeRuntime.pinnedVersion) (updated at the next start)")
            }
            if let v = sel.version, v == pin.version {
                return .init(name: name, state: .pinned, detail: "\(v), Briglia's private copy (used only by Briglia's browser tools)")
            }
            return .init(name: name, state: .differs, detail: "\(sel.version ?? "?") in use; this Briglia expects \(NodeRuntime.pinnedVersion)\(sel.reason.map { " (\($0))" } ?? "")")
        case "shared-accepted":
            return .init(name: name, state: .userOwned, detail: "your \(sel.path ?? "Node") (\(sel.version ?? "?")); at least Briglia's \(NodeRuntime.pinnedVersion), never changed by Briglia")
        default:
            return .init(name: name, state: .notInstalled, detail: "unavailable: \(sel.reason ?? "unknown")")
        }
    }

    static func python() -> SecurityStatus.Component? {
        let name = "Python environment"
        let st = RuntimeSelectionStore.peek()?[.python]
        let receipt = (try? RuntimeFS.readJSON(RuntimeReceipt.self, RuntimePaths.receipt(.python))) ?? nil
        guard receipt?.verifiedRecord != nil || st?.attempts.isEmpty == false else { return nil }
        switch PythonRuntime.execDecision() {
        case .run:
            let v = receipt?.verifiedRecord
            let current = PythonRuntime.lockSHA256.map { String($0.prefix(12)) }
            if let v, v.version == current {
                return .init(name: name, state: .pinned, detail: "Briglia's private venv (lock \(v.version), Python \(v.extra?["baseVersion"] ?? "?"))")
            }
            return .init(name: name, state: .differs, detail: "built from an older lock (\(v?.version ?? "?")); rebuilt at the next start")
        case .refuse(let why):
            return .init(name: name, state: .unknownState, detail: why)
        }
    }

    static func all() -> [SecurityStatus.Component] { [agentMail(), node(), python()].compactMap { $0 } }
}

extension AgentMailService {
    /// `briglia agentmail status` and doctor.
    static func statusLines() -> [String] {
        var out: [String] = []
        if let c = RuntimeStatus.agentMail() { out.append("\(c.name): \(c.state.label) — \(c.detail)") }
        else { out.append("AgentMail CLI: not used (email provider is not AgentMail)") }
        if let last = RuntimeSelectionStore.peek()?[.agentmail].attempts.last {
            out.append("last attempt: \(last.kind) \(last.pin.version) at \(ISO8601DateFormatter().string(from: last.startedAt)): \(last.result ?? "in progress")")
        }
        out += legacyFindings().map { "note: \($0)" }
        return out
    }
}
