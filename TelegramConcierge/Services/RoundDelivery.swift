import Foundation

// Mid-turn round delivery of background results (plan
// MIDTURN_ROUND_DELIVERY_PLAN.md v3, owner decisions 2026-09-28).
//
// While a turn runs, a finished background bash job or background/moved
// subagent IS tool output: at the next tool-round boundary its existing
// completion body is appended, framed, to the content of that round's last
// tool result. From then on it is saved, estimated, pruned, compacted,
// snapshotted and archived like any other tool output. No size limit, no
// excerpt, no report file, no size-based deferral. Idle delivery (a
// `.bashComplete` / `.subagentComplete` message that starts a turn) is
// unchanged and remains the only path while no turn is running.
//
// Durability: an item is acknowledged (registry withdrawal + crash record
// `.delivered`) only after a successful HISTORY save whose content carries
// it — inline in a result's typed `deliveredCompletions`, or in a snapshot
// reached from saved history whose sidecar lists it. Until then the item is
// reserved (the idle drains skip it). Recovery after a crash uses the typed
// field and sidecar, never the `completion_id:` prose.

enum RoundDelivery {
    /// First line of the appended section. Self-describing (the release adds
    /// no prompt or tool-description text).
    static let frameHeader = "[Background results — added by Briglia at this tool-round boundary. Not output of the tool above and not from the user: background work you started finished while you were working.]"
    static let frameFooter = "[End of background results]"

    /// Hidden kill switch: `BRIGLIA_MIDTURN_BACKGROUND_RESULTS=0` (or the
    /// defaults key set to false) restores idle-only delivery exactly.
    static let environmentKey = "BRIGLIA_MIDTURN_BACKGROUND_RESULTS"
    static let defaultsKey = "midturn_background_results"
    nonisolated(unsafe) static var overrideForTesting: Bool?

    static var isEnabled: Bool {
        if let overrideForTesting { return overrideForTesting }
        if let value = ProcessInfo.processInfo.environment[environmentKey] {
            let v = value.trimmingCharacters(in: .whitespaces).lowercased()
            if v == "0" || v == "false" || v == "off" || v == "no" { return false }
        }
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        return true
    }

    /// One item to append: its stable completion message id and the exact
    /// body idle delivery would have appended.
    struct Item {
        let messageId: UUID
        let body: String
    }

    /// The framed section (neutralized: bodies hold commands, stdout/stderr
    /// tails and subagent text). Appended after `"\n\n"`.
    static func section(for items: [Item]) -> String {
        var text = frameHeader
        for item in items {
            text += "\n" + item.body + "\ncompletion_id: " + item.messageId.uuidString
            if item.messageId != items.last?.messageId { text += "\n" }
        }
        text += "\n" + frameFooter
        return MarkerNeutralizer.escape(text)
    }

    /// Append a section to `content`.
    static func append(_ items: [Item], to content: String) -> String {
        content + "\n\n" + section(for: items)
    }

    /// The part of a result's content that the foreground tool produced.
    /// Consulted only for results that typed-carry delivered completions
    /// (every other result is returned unchanged, even if it contains a
    /// forged frame line); used by the compact tool log and the
    /// instruction/checkpoint marker scans, which must not read the
    /// appended background bodies. A forged frame inside a body only shifts
    /// this cosmetic split.
    static func foregroundContent(of result: ToolResultMessage) -> String {
        guard !result.deliveredCompletions.isEmpty,
              let range = result.content.range(of: "\n\n" + frameHeader, options: .backwards) else { return result.content }
        return String(result.content[..<range.lowerBound])
    }
}

/// An item appended at a round boundary and not yet acknowledged.
/// Keyed by completion message id; owned by the run that appended it.
struct RoundDeliveryReservation {
    enum Kind: Equatable {
        case bash(jobUUID: UUID)
        case subagent(jobId: UUID?, handleId: String)
    }
    enum State: Equatable {
        /// Appended to a round; no saved history carries it yet.
        case reserved
        /// A saved history carries it; the registry withdrawal is in
        /// flight. The idle drains keep skipping it until that completes.
        case acknowledging
    }
    let messageId: UUID
    let runId: UUID
    let kind: Kind
    /// Unrecorded subagent run (no crash record): charged once, at
    /// acknowledgement (owner decision D6: day/month, not the turn cap).
    let unrecordedSpendUSD: Double
    /// Last committed history message when appended: evidence can only live
    /// in messages after it.
    let anchor: UUID?
    var state: State = .reserved
    var charged = false
}
