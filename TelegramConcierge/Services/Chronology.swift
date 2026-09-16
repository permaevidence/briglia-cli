import Foundation

/// Clock for every harness-recorded chronology timestamp (tool-result
/// delivery, subagent reply completion, compaction-summary creation). One seam
/// so selftests and the instrumented lifecycle builds pin the input without
/// touching an encoder, a decision or a persistence writer. Progress and
/// staleness clocks are deliberately NOT routed here: they must stay real.
enum HarnessClock {
    nonisolated(unsafe) static var overrideForTesting: (() -> Date)?

    static func now() -> Date {
        overrideForTesting?() ?? Date()
    }
}

/// Conversation chronology shared by the Chat Completions and Responses
/// serializers, for the main agent and every subagent type alike
/// (WEB_SUBAGENT_PLAN §12, R0).
///
/// Formats are the ones the main agent has always used: a day header
/// `--- EEEE, d MMMM yyyy ---` at the start of history and on a change of day,
/// `[HH:mm]` on user-role messages, `[System Note: Current time is now
/// HH:mm:ss]` on tool results. Everything is local time (`TimeZone.current`,
/// `Calendar.current`), matching the timezone stated in the system prompt.
/// Values come only from harness-owned metadata (`Message.timestamp`,
/// `ToolResultMessage.completedAt`); nothing here parses date-looking text
/// out of tool output or model text.
enum Chronology {
    static let dayHeaderFormat = "EEEE, d MMMM yyyy"
    static let timeFormat = "HH:mm"
    static let clockFormat = "HH:mm:ss"
    /// Compact, locale-independent stamp for internal transcripts handed to
    /// summarizers (never user-facing).
    static let transcriptStampFormat = "yyyy-MM-dd HH:mm"
    static let transcriptClockFormat = "yyyy-MM-dd HH:mm:ss"

    /// Header of the summary message a subagent compaction leaves at the
    /// front of the session. Byte-stable: the next compaction recognizes it
    /// by this prefix and folds it into the new summary, so a session carries
    /// ONE anchored summary instead of a stack. A summary is not an event: the
    /// serializers give it neither a day header nor a time prefix and it does
    /// not move the chronology cursor; its own creation time and the period it
    /// covers are stated inside it (`compactionSummaryChronologyLine`).
    static let compactionSummaryHeader = "[SESSION HISTORY SUMMARY — Earlier work in this session was summarized to free context space. Details below are from the evicted portion.]"

    static func isCompactionSummary(_ message: Message) -> Bool {
        message.role == .user && message.content.hasPrefix(compactionSummaryHeader)
    }

    /// Same formatter configuration the legacy serializer used (default
    /// locale, current timezone), so existing wire bytes are unchanged.
    static func makeFormatter(_ format: String, posix: Bool = false) -> DateFormatter {
        let formatter = DateFormatter()
        if posix { formatter.locale = Locale(identifier: "en_US_POSIX") }
        formatter.dateFormat = format
        return formatter
    }

    /// `UTC+02:00` / `UTC-05:00` for the offset in force at `date`. Rendered on
    /// a change of offset so a repeated local hour at a daylight-saving
    /// transition is distinguishable without reordering anything.
    static func offsetLabel(_ date: Date, timeZone: TimeZone = .current) -> String {
        offsetLabel(seconds: timeZone.secondsFromGMT(for: date))
    }

    static func offsetLabel(seconds: Int) -> String {
        let magnitude = abs(seconds)
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", magnitude / 3600, (magnitude % 3600) / 60)
    }

    /// `[HH:mm]` for the reply-time metadata line and transcript stamps.
    static func time(_ date: Date) -> String { makeFormatter(timeFormat).string(from: date) }
    /// Transcript stamps carry the UTC offset, so a lone event that survived
    /// compaction is unambiguous even on a daylight-saving repeated hour.
    static func transcriptStamp(_ date: Date) -> String { makeFormatter(transcriptStampFormat, posix: true).string(from: date) + " " + offsetLabel(date) }
    static func transcriptClock(_ date: Date) -> String { makeFormatter(transcriptClockFormat, posix: true).string(from: date) + " " + offsetLabel(date) }

    /// The run/resume clock note appended (outside the stable prefix, as the
    /// tail) to every model request of one subagent run: recorded once at the
    /// run's start, never regenerated. It is what separates the current run's
    /// clock from replayed historical tool notes — in the Chat Completions
    /// resume layout an earlier run's rounds follow the new continuation
    /// prompt, so the last "Current time is now" note in the request can be
    /// yesterday's.
    static func runClockNote(startedAt: Date) -> String {
        "[Run clock: this run started at \(makeFormatter(clockFormat).string(from: startedAt)) on \(makeFormatter(dayHeaderFormat).string(from: startedAt)) (\(offsetLabel(startedAt))). Tool notes and reply times earlier than that are historical, from previous runs of this session.]"
    }

    /// The metadata line that exposes an assistant reply's original time.
    /// Rendered inside the `[Turn metadata]` system note, never as a prefix
    /// on the assistant text, so the model is not taught to imitate a
    /// timestamp prefix in its own replies.
    static func assistantReplyTimeLine(_ date: Date) -> String {
        "Assistant reply time: \(time(date))"
    }

    /// Second line of a compaction summary: when it was written and which
    /// period of evicted history it covers, each endpoint with its own UTC
    /// offset. `coverage` is nil when none of the evicted events recorded a
    /// time (legacy rounds); the line then says so instead of inventing a
    /// period.
    static func compactionSummaryChronologyLine(writtenAt: Date, coverage: ClosedRange<Date>?, foldsEarlierSummaries: Bool) -> String {
        let day = makeFormatter(dayHeaderFormat)
        let clock = makeFormatter(timeFormat)
        var line = "[Summary written \(clock.string(from: writtenAt)), \(day.string(from: writtenAt)) (\(offsetLabel(writtenAt)))."
        if let coverage {
            // Each endpoint carries its own offset: a range across a
            // daylight-saving repeated hour would otherwise read
            // "from 02:30 … to 02:30 …" with nothing to tell the two apart
            // (Codex round 2).
            line += " Covers evicted session history from \(clock.string(from: coverage.lowerBound)), \(day.string(from: coverage.lowerBound)) (\(offsetLabel(coverage.lowerBound)))"
            line += " to \(clock.string(from: coverage.upperBound)), \(day.string(from: coverage.upperBound)) (\(offsetLabel(coverage.upperBound)))."
        } else {
            line += " The evicted history recorded no event times."
        }
        if foldsEarlierSummaries { line += " Earlier summaries are folded in." }
        return line + "]"
    }
}

/// Walks one serialized request in emission order and decides where a day
/// header, an offset-change line or a dated tool note is due. One cursor per
/// request; canonical messages and tool results advance it, compaction
/// summaries do not.
struct ChronologyCursor {
    struct Transition {
        /// True on the first event and whenever the local day differs from
        /// the previous event's.
        let dayChanged: Bool
        /// The previous event's UTC offset when it differs from this one.
        let previousOffset: Int?
        let offset: Int
    }

    private let calendar = Calendar.current
    private let timeZone = TimeZone.current
    private let dayFormatter = Chronology.makeFormatter(Chronology.dayHeaderFormat)
    private let timeFormatter = Chronology.makeFormatter(Chronology.timeFormat)
    private let clockFormatter = Chronology.makeFormatter(Chronology.clockFormat)
    private(set) var lastDate: Date?
    private(set) var lastOffset: Int?

    init() {}

    mutating func advance(to date: Date) -> Transition {
        let offset = timeZone.secondsFromGMT(for: date)
        let transition = Transition(
            dayChanged: lastDate.map { !calendar.isDate($0, inSameDayAs: date) } ?? true,
            previousOffset: (lastOffset != nil && lastOffset != offset) ? lastOffset : nil,
            offset: offset
        )
        lastDate = date
        lastOffset = offset
        return transition
    }

    /// Lines placed before a canonical message (each ending in "\n"): the day
    /// header on the first message and on a change of day; the offset line on
    /// a change of UTC offset. Empty when neither applies.
    mutating func messageLead(for date: Date) -> String {
        let transition = advance(to: date)
        var lead = ""
        if transition.dayChanged {
            lead += "--- \(dayFormatter.string(from: date)) ---\n"
        }
        if let previous = transition.previousOffset {
            lead += "--- clock offset now \(Chronology.offsetLabel(seconds: transition.offset)) (was \(Chronology.offsetLabel(seconds: previous))) ---\n"
        }
        return lead
    }

    /// `[HH:mm] ` — user-role messages only (see the serializers).
    func timePrefix(for date: Date) -> String {
        "[\(timeFormatter.string(from: date))] "
    }

    /// The harness time note for a tool result delivered at `date`. The bare
    /// note is byte-identical to the legacy main-agent note; the day is added
    /// only when the day changed since the previous event of the request, and
    /// the offset only when it changed, so a midnight crossing or a
    /// daylight-saving switch inside a run is never an unexplained jump.
    mutating func resultNote(at date: Date) -> String {
        let transition = advance(to: date)
        var note = Self.bareResultNote(at: date, clock: clockFormatter)
        note.removeLast()   // reopen the bracket
        if transition.dayChanged {
            note += " on \(dayFormatter.string(from: date))"
        }
        if let previous = transition.previousOffset {
            note += " (clock offset now \(Chronology.offsetLabel(seconds: transition.offset)), was \(Chronology.offsetLabel(seconds: previous)))"
        }
        return note + "]"
    }

    /// The note without day/offset context, for renderers that do not walk a
    /// whole request (nothing to compare the day against).
    static func bareResultNote(at date: Date, clock: DateFormatter = Chronology.makeFormatter(Chronology.clockFormat)) -> String {
        "[System Note: Current time is now \(clock.string(from: date))]"
    }

    /// The harness note placed before an assistant tool-call round that
    /// recorded its receipt time (`AssistantToolCallMessage.issuedAt`): a
    /// system message of its own, so the round's native call/result adjacency
    /// is untouched. Day and offset context as for `resultNote`.
    mutating func issuedNote(at date: Date) -> String {
        let transition = advance(to: date)
        var note = "[System Note: The following tool calls were issued at \(clockFormatter.string(from: date))"
        if transition.dayChanged {
            note += " on \(dayFormatter.string(from: date))"
        }
        if let previous = transition.previousOffset {
            note += " (clock offset now \(Chronology.offsetLabel(seconds: transition.offset)), was \(Chronology.offsetLabel(seconds: previous)))"
        }
        return note + "]"
    }
}
