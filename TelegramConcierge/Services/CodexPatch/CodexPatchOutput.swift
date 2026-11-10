import Foundation

extension CodexPatch {

    /// Failure categories (plan §6.5 step 6).
    enum Category: String, Equatable {
        case parse, path, knowledge, protected, claim, context, conflict, io, cancelled
    }

    /// The typed outcome every integration reads instead of the result text
    /// (plan §6.6, §9.1). In memory only; never encoded.
    struct EditOutcome: Equatable {
        enum Status: String, Equatable { case applied, refused, rolledBack, partial }
        var status: Status
        /// Paths this call left changed (for a success: every target,
        /// including both ends of a move).
        var changed: [String] = []
        /// Paths restored to their pre-image by the rollback.
        var restored: [String] = []
        /// Paths left untouched by the rollback because something else changed
        /// them (or they could not be restored) — they may differ.
        var conflicts: [String] = []
        var category: Category?

        static func refused(_ category: Category) -> EditOutcome { EditOutcome(status: .refused, category: category) }
    }

    /// What the engine returns. `evidence` and `forget` are published by the
    /// caller only after the result is delivered to the model (§7).
    struct Result {
        var text: String
        var outcome: EditOutcome
        /// Files written (for LSP diagnostics): path and new text.
        var writtenFiles: [(path: String, text: String)] = []
        var evidence: [GPTEvidence.Receipt] = []
        var forget: [String] = []
        /// Committed operations by kind (FilesLedger, S2): created files,
        /// files removed (Delete targets and Move sources).
        var addedPaths: [String] = []
        var removedPaths: [String] = []
    }

    // MARK: - Model-facing text

    static func successText(added: [String], modified: [String], deleted: [String], notes: [String]) -> String {
        var lines = ["Success. Updated the following files:"]
        lines += added.map { "A \($0)" }
        lines += modified.map { "M \($0)" }
        lines += deleted.map { "D \($0)" }
        lines += notes
        return lines.joined(separator: "\n")
    }

    static func fuzzNote(_ level: FuzzLevel, path: String) -> String? {
        switch level {
        case .exact: return nil
        case .trimEnd, .trim: return "note: matched ignoring whitespace in \(path)"
        case .punctuation: return "note: matched ignoring typographic punctuation in \(path)"
        }
    }

    static func verificationFailure(_ message: String) -> String { "apply_patch verification failed: \(message)" }

    /// Transaction failure + rollback report (I5: exactly which targets
    /// changed, were restored, or could not be restored).
    static func transactionFailureText(reason: String, outcome: EditOutcome) -> String {
        var lines = ["apply_patch failed: \(reason)"]
        if outcome.restored.isEmpty && outcome.conflicts.isEmpty && outcome.changed.isEmpty {
            lines.append("No file was changed.")
        } else {
            if !outcome.restored.isEmpty { lines.append("Rolled back: \(outcome.restored.joined(separator: ", ")) restored to the state before the patch.") }
            if !outcome.conflicts.isEmpty {
                lines.append("NOT restored (changed by something else during the patch, left as found — check them): \(outcome.conflicts.joined(separator: ", "))")
            }
            if !outcome.changed.isEmpty {
                lines.append("Still changed by this patch (could not be undone): \(outcome.changed.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Context-miss hints

    /// Up to 6 file lines most similar to the first line that could not be
    /// located, with 1-based line numbers (plan §6.6).
    static func nearestLinesHint(fileLines: [String], missed: [String]) -> String? {
        guard let probe = missed.map(RustStr.trim).first(where: { $0.count >= 3 }) else { return nil }
        let probeGrams = bigrams(probe)
        guard !probeGrams.isEmpty else { return nil }
        // Pre-release review L3: a stopped caller gets no hint (the engine
        // reports the cancellation).
        let cancelled = SeekCancellation.isCancelled
        var scored: [(index: Int, score: Double)] = []
        for (i, line) in fileLines.enumerated() {
            if i & 1023 == 0, cancelled?() == true { return nil }
            let t = RustStr.trim(line)
            guard !t.isEmpty else { continue }
            let grams = bigrams(t)
            guard !grams.isEmpty else { continue }
            let common = probeGrams.intersection(grams).count
            let score = 2.0 * Double(common) / Double(probeGrams.count + grams.count)
            if score >= 0.5 { scored.append((i, score)) }
        }
        guard !scored.isEmpty else { return nil }
        let top = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(6).sorted { $0.index < $1.index }
        return "Nearest lines in the file:\n" + top.map { "\($0.index + 1): \(fileLines[$0.index])" }.joined(separator: "\n")
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count >= 2 else { return [] }
        var out = Set<String>()
        for i in 0..<(scalars.count - 1) {
            var v = String.UnicodeScalarView()
            v.append(scalars[i]); v.append(scalars[i + 1])
            out.insert(String(v))
        }
        return out
    }
}
