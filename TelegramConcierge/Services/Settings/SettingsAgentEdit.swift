import Foundation

/// The agent's own field edits of `secrets.json` (KEYLESS_WEB_AND_LIVE_MENU
/// plan B.5, round-3 finding 2; owner decision D21). The feature and its
/// Telegram-token invariant stay; the edit is turned into a CONDITIONAL
/// DELTA: the keys it added, changed or removed, committed through the one
/// settings writer only if those keys still hold the values the edit was
/// made from. A concurrent unrelated change survives; an overlapping one
/// makes the tool fail with nothing written. Applied immediately during the
/// agent's own turn even when it changes a route (D21) — a policy derived
/// from this internal caller only, never from a forwarded request.
/// The file is re-serialized by the store (formatting is not preserved).
enum SettingsAgentEdit {
    enum Outcome: Equatable {
        case applied(changed: [String])
        case unchanged
        case refused(String)
    }

    static let formattingNote = "secrets.json was saved through Briglia's settings writer: only the keys you changed were written, and the file was re-serialized (its formatting and key order are Briglia's own)."

    static func parse(_ text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in object {
            guard let s = v as? String else { return nil }
            out[k] = s
        }
        return out
    }

    struct Delta: Equatable {
        var writes: [String: String] = [:]
        var deletes: [String] = []
        /// key → the value it must still hold (nil = must be absent).
        var expected: [String: String?] = [:]
        var keys: [String] { (Array(writes.keys) + deletes).sorted() }
        var isEmpty: Bool { writes.isEmpty && deletes.isEmpty }
    }

    static func delta(from original: [String: String], to updated: [String: String]) -> Delta {
        var d = Delta()
        for (k, v) in updated where original[k] != v { d.writes[k] = v; d.expected[k] = original[k] }
        for k in original.keys where updated[k] == nil { d.deletes.append(k); d.expected[k] = original[k] }
        d.deletes.sort()
        return d
    }

    /// The prepared change of a delta (no preparation run: the delta IS the
    /// description). Preconditions are the edit's own original values.
    static func change(_ delta: Delta, label: String) throws -> PreparedChange {
        var change = PreparedChange(origin: "agent-edit", label: label, epoch: try ReplacementEpoch.read())
        change.writes = delta.writes
        change.deletes = delta.deletes
        for (k, v) in delta.expected { change.expected[k] = SettingsDigest.of(v) }
        change.category = SettingsKeyRoles.category(of: change)
        change.reply = PreparedChange.jsonText(["ok": true])
        return change
    }

    /// The in-process owner's immediate path (set by the daemon).
    nonisolated(unsafe) static var immediateOwner: (@MainActor (PreparedChange) async -> SettingsCommitResult)?

    @MainActor
    static func commit(originalText: String, updatedText: String, label: String = "secrets.json edit") async -> Outcome {
        guard let original = parse(originalText), let updated = parse(updatedText) else {
            return .refused("edit refused: secrets.json must stay a JSON object of string values")
        }
        let d = delta(from: original, to: updated)
        guard !d.isEmpty else { return .unchanged }
        guard !d.keys.contains(KeychainHelper.telegramBotTokenKey) else {
            return .refused("edit refused: the Telegram bot token is managed by /switchbot")
        }
        let prepared: PreparedChange
        do { prepared = try change(d, label: label) } catch { return .refused("\(error)") }
        let result: SettingsCommitResult
        if let owner = immediateOwner {
            result = await owner(prepared)
        } else {
            let host = OfflineAgentEditHost()
            let writer = SettingsWriter(host: host)
            result = await writer.commit(prepared, policy: .immediate)
            withExtendedLifetime(host) {}
        }
        switch result.state {
        case .applied: return .applied(changed: d.keys)
        default:
            if let message = result.message, message.hasPrefix("Your settings changed elsewhere") {
                return .refused("secrets.json changed since you read it (keys: \(d.keys.joined(separator: ", "))); read it again and redo the edit. Nothing was written.")
            }
            return .refused("secrets.json was not changed: \(result.message ?? result.state.rawValue)")
        }
    }
}

/// A writer host for the rare process that runs file tools without a
/// settings owner (selftests): no barrier, no reconciliation.
@MainActor
final class OfflineAgentEditHost: SettingsOwnerHost {
    var isDaemon: Bool { false }
    func beginRouteBarrier() async -> Bool { true }
    func endRouteBarrier() {}
    func admissionRefusal() -> String? { nil }
    func reconcile(after change: PreparedChange, routeChanged: Bool) async {}
    var toolSwitches: SettingsToolSwitches { SettingsToolSwitches.current() }
}
