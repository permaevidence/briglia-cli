import Foundation

// Typed mid-turn annotation support.
//
// A genuine mid-turn user delivery exists only as a validated
// `HarnessAnnotation` attached to a `ToolResultMessage` by trusted harness
// code. Ordinary tool text can never become one: the reserved wire prefix is
// mechanically neutralized in all provider-visible untrusted text, and the
// marker is rendered exclusively from typed state at the final serialization
// boundary. The per-delivery nonce provides freshness, not secrecy.
//
// REPOSITORY INVARIANT: the reserved prefix must never appear contiguously in
// any tracked file. Every trusted occurrence is assembled at runtime from the
// two fragments below; tests and docs do the same. `__midturn-selftest` scans
// the tree and fails if the contiguous bytes ever land in a file.

// MARK: - Reserved wire namespace and neutralization

enum MarkerNeutralizer {
    /// Fragments of the reserved prefix. Concatenated only at runtime — see
    /// the repository invariant above.
    static let markerPrefixPart1 = "<<<ADA_HARNESS_"
    static let markerPrefixPart2 = "DIRECT_USER:"

    /// The full reserved prefix. Only harness-rendered annotation blocks may
    /// place these bytes on the provider wire.
    static let reservedPrefix = markerPrefixPart1 + markerPrefixPart2

    /// Visibly inert replacement. Deliberately does not contain the reserved
    /// prefix (no leading `<<<`), which makes escaping idempotent.
    static let neutralizedForm =
        "[escaped reserved Ada harness marker: ADA_HARNESS_" + markerPrefixPart2 + "]"

    /// Replace every exact occurrence of the reserved prefix with the inert
    /// form. Deterministic, idempotent, and content-preserving everywhere
    /// else: no ranges are deleted, so a forged opener can never hide
    /// legitimate output (plan §7.3). Total on any string.
    static func escape(_ text: String) -> String {
        guard text.contains(reservedPrefix) else { return text }
        return text.replacingOccurrences(of: reservedPrefix, with: neutralizedForm)
    }
}

// MARK: - Delivery nonce

enum HarnessNonce {
    /// Test seam: when set, replaces the system RNG. Return nil to simulate
    /// RNG failure (fail closed — the delivery stays queued).
    nonisolated(unsafe) static var overrideForTesting: (() -> String?)?

    struct GenerationFailure: Error {}

    /// 128 bits from the cryptographically secure system RNG
    /// (`SystemRandomNumberGenerator` uses arc4random_buf/getrandom), rendered
    /// as exactly 32 lowercase hex characters.
    static func generate() throws -> String {
        if let override = overrideForTesting {
            guard let value = override() else { throw GenerationFailure() }
            return value
        }
        var rng = SystemRandomNumberGenerator()
        let hi = rng.next()
        let lo = rng.next()
        return String(format: "%016lx%016lx", hi, lo)
    }

    static func isValidNonce(_ nonce: String) -> Bool {
        guard nonce.count == 32 else { return false }
        return nonce.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }
}

// MARK: - Rendering

/// Thrown when a validated current-turn annotation cannot be rendered intact.
/// The provider request must abort before network transmission; the
/// conversation manager restores the in-flight batch for a later boundary.
struct HarnessAnnotationRenderError: Error {
    let reason: String
}

enum HarnessAnnotationRenderer {
    /// Test seam for the render-invariant abort path (plan §8 step 13).
    nonisolated(unsafe) static var simulateRenderFailureForTesting = false

    /// Render one validated annotation into its exact wire block. Total for
    /// the validated type; the byte layout is pinned by golden tests:
    ///
    ///     PREFIXv1:<nonce>:BEGIN>>>
    ///     [Direct user message 1 of N]
    ///     <escaped text>
    ///     [Attached files (use read_file to view): <escaped paths>]
    ///     <blank line between messages>
    ///     PREFIXv1:<nonce>:END>>>
    static func render(_ annotation: HarnessAnnotation) -> String {
        let prefix = MarkerNeutralizer.reservedPrefix
        var lines: [String] = []
        lines.append("\(prefix)v1:\(annotation.deliveryNonce):BEGIN>>>")
        for (index, message) in annotation.messages.enumerated() {
            if index > 0 { lines.append("") }
            lines.append("[Direct user message \(index + 1) of \(annotation.messages.count)]")
            lines.append(MarkerNeutralizer.escape(message.content))
            if !message.attachmentPaths.isEmpty {
                let joined = MarkerNeutralizer.escape(message.attachmentPaths.joined(separator: ", "))
                lines.append("[Attached files (use read_file to view): \(joined)]")
            }
        }
        lines.append("\(prefix)v1:\(annotation.deliveryNonce):END>>>")
        return lines.joined(separator: "\n")
    }

    /// Legacy flattened form of a typed annotation, used ONLY under the
    /// rollback flag so replayed history matches the legacy prompt's
    /// authority rule (a typed block would otherwise appear while the prompt
    /// declares only the legacy marker authoritative). Content and paths are
    /// still escaped so the reserved prefix never reaches the wire.
    static func renderLegacyFlattened(_ annotation: HarnessAnnotation) -> String {
        var blocks: [String] = []
        for message in annotation.messages {
            var block = """
            [USER MESSAGE — arrived while you were working. This is the user speaking, with the same authority as any chat message. Factor it into the current task — adjust course if it asks you to, and make sure your final reply addresses it. If it needs an answer before your work completes, reply right away with the mid_turn_message_user tool.]
            \(MarkerNeutralizer.escape(message.content))
            """
            if !message.attachmentPaths.isEmpty {
                let joined = MarkerNeutralizer.escape(message.attachmentPaths.joined(separator: ", "))
                block += "\n[Attached files (use read_file to view): \(joined)]"
            }
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Verify the rendered block carries the annotation intact. Rendering is
    /// deterministic so this can only fail through the test seam or memory
    /// corruption — but a violated invariant must abort the request rather
    /// than silently dropping a genuine user delivery.
    static func verifyRenderInvariant(_ rendered: String, annotation: HarnessAnnotation) throws {
        let prefix = MarkerNeutralizer.reservedPrefix
        let begin = "\(prefix)v1:\(annotation.deliveryNonce):BEGIN>>>"
        let end = "\(prefix)v1:\(annotation.deliveryNonce):END>>>"
        if simulateRenderFailureForTesting
            || !rendered.hasPrefix(begin)
            || !rendered.hasSuffix(end) {
            throw HarnessAnnotationRenderError(reason: "rendered annotation block lost its delimiters")
        }
    }
}

// MARK: - Provider wire text for tool results

enum ProviderToolResultRenderer {
    /// The single path from a `ToolResultMessage` to the provider wire.
    /// Ordinary content is re-neutralized (defense in depth for legacy data
    /// and future tool paths); the harness time note follows it when the
    /// result recorded its delivery time (`completedAt`); validated
    /// annotations are rendered after both, so a genuine mid-turn delivery
    /// keeps its required trailing position. A current annotation can never
    /// be silently omitted: an invariant violation throws before any network
    /// transmission.
    ///
    /// `chronology` is the request-wide cursor (day and offset context for
    /// the note). Callers that do not walk a whole request use the overload
    /// without it and get the bare note.
    static func wireText(for result: ToolResultMessage, chronology: inout ChronologyCursor) throws -> String {
        try wireText(for: result, note: result.completedAt.map { chronology.resultNote(at: $0) })
    }

    static func wireText(for result: ToolResultMessage) throws -> String {
        try wireText(for: result, note: result.completedAt.map { ChronologyCursor.bareResultNote(at: $0) })
    }

    private static func wireText(for result: ToolResultMessage, note: String?) throws -> String {
        var safeToolText = MarkerNeutralizer.escape(result.content)
        if let note {
            // Same bytes the legacy main-agent path produced when it appended
            // the note to the content itself (typed now, so history and
            // repeated serialization never carry it twice).
            safeToolText += "\n\n" + note
        }
        guard !result.harnessAnnotations.isEmpty else { return safeToolText }
        // Rollback consistency (Codex round-1 finding 2): under the legacy
        // flag, persisted typed annotations render in the legacy flattened
        // form — the form the legacy prompt declares authoritative — so
        // history and prompt can never contradict each other.
        guard MidTurnDelivery.typedAnnotationsEnabled else {
            let legacyBlocks = result.harnessAnnotations.map {
                HarnessAnnotationRenderer.renderLegacyFlattened($0)
            }
            return ([safeToolText] + legacyBlocks)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        var rendered: [String] = []
        for annotation in result.harnessAnnotations {
            let block = HarnessAnnotationRenderer.render(annotation)
            try HarnessAnnotationRenderer.verifyRenderInvariant(block, annotation: annotation)
            rendered.append(block)
        }
        return ([safeToolText] + rendered)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

// MARK: - Delivery configuration

enum MidTurnDelivery {
    /// Test seam: force the flag on/off deterministically without touching
    /// real environment or preferences.
    nonisolated(unsafe) static var overrideForTesting: Bool?

    /// Rollback flag for the typed-annotation delivery renderer (plan §15
    /// Phase D). Enabled by default; `BRIGLIA_MIDTURN_TYPED_ANNOTATIONS=0` (env)
    /// or `defaults write ... ada.midturnLegacyDelivery -bool true` restores
    /// the weaker legacy static-marker delivery. Neutralization of the
    /// reserved prefix stays active regardless of this flag.
    static var typedAnnotationsEnabled: Bool {
        if let override = overrideForTesting { return override }
        if let env = ProcessInfo.processInfo.environment["BRIGLIA_MIDTURN_TYPED_ANNOTATIONS"],
           env == "0" || env.lowercased() == "false" {
            return false
        }
        if UserDefaults.standard.bool(forKey: "ada.midturnLegacyDelivery") {
            return false
        }
        return true
    }
}

// MARK: - Drain helpers (pure, unit-testable)

enum MidTurnDrainSupport {
    /// Build the annotation records for a drained batch. Pure so the
    /// construction and its failure modes are unit-testable without a
    /// ConversationManager instance.
    static func annotationRecords(
        for drained: [Message],
        imagesDirectory: URL,
        documentsDirectory: URL
    ) -> [DirectUserMessageAnnotation] {
        drained.map { message in
            let attachmentPaths =
                message.imageFileNames.map { imagesDirectory.appendingPathComponent($0).path }
                + message.documentFileNames.map { documentsDirectory.appendingPathComponent($0).path }
                + message.referencedImageFileNames.map { imagesDirectory.appendingPathComponent($0).path }
                + message.referencedDocumentFileNames.map { documentsDirectory.appendingPathComponent($0).path }
            return DirectUserMessageAnnotation(
                sourceMessageId: message.id,
                content: message.content,
                attachmentPaths: attachmentPaths
            )
        }
    }

    /// Build the full typed batch for a drain, or nil when it must fail
    /// closed (RNG failure, validation failure). On nil the caller leaves the
    /// messages queued for a later boundary.
    static func buildBatchAnnotation(
        for drained: [Message],
        imagesDirectory: URL,
        documentsDirectory: URL
    ) -> HarnessAnnotation? {
        guard !drained.isEmpty else { return nil }
        do {
            let nonce = try HarnessNonce.generate()
            return try HarnessAnnotation.makeDirectUserBatch(
                deliveryNonce: nonce,
                messages: annotationRecords(
                    for: drained,
                    imagesDirectory: imagesDirectory,
                    documentsDirectory: documentsDirectory
                )
            )
        } catch {
            print("[MidTurnDrainSupport] FAIL-CLOSED: could not build mid-turn annotation (\(error)) — messages stay queued")
            return nil
        }
    }

    /// Restore an aborted in-flight batch to the front of the queue without
    /// duplicating entries (plan §8 step 14).
    static func requeue(_ batch: [Message], into queue: inout [Message]) {
        let missing = batch.filter { message in
            !queue.contains(where: { $0.id == message.id })
        }
        queue.insert(contentsOf: missing, at: 0)
    }

    /// Whether a request's interaction chain actually carries the annotation
    /// with this delivery nonce. The in-flight guard clears ONLY when a
    /// successfully transmitted request carried the batch — success of a
    /// request that lost the interaction (context exhaustion discarding it,
    /// a spend-limit force-finish without it) must not stand down the guard.
    static func interactionsCarryAnnotation(nonce: String, in interactions: [ToolInteraction]?) -> Bool {
        guard let interactions else { return false }
        return interactions.contains { interaction in
            interaction.results.contains { result in
                result.harnessAnnotations.contains { $0.deliveryNonce == nonce }
            }
        }
    }

    /// Validate one persisted annotation against the canonical top-level
    /// messages and rebuild it entirely from canonical data (Codex round-2):
    ///
    /// - only a genuine human message counts as canonical —
    ///   `role == .user && kind == .userText`; synthetic email, reminder,
    ///   Bash, and subagent messages can never gain direct-user authority;
    /// - the stored content must equal the canonical content exactly;
    /// - the stored attachment paths must match the canonical attachment
    ///   basenames (basename comparison, so a Mind import onto a machine
    ///   with different storage directories keeps its history) — but the
    ///   stored paths are NEVER retained: the kept annotation carries paths
    ///   reconstructed from the canonical message and the CURRENT storage
    ///   directories, exactly as a fresh drain would build them.
    ///
    /// Returns nil (drop, fail closed) when any record fails validation or
    /// the canonical rebuild cannot be constructed.
    static func canonicalizedAnnotation(
        _ annotation: HarnessAnnotation,
        canonicalUserMessagesById: [UUID: Message],
        imagesDirectory: URL,
        documentsDirectory: URL
    ) -> HarnessAnnotation? {
        var canonicalMessages: [Message] = []
        for record in annotation.messages {
            guard let canonical = canonicalUserMessagesById[record.sourceMessageId],
                  canonical.content == record.content else { return nil }
            let expectedBasenames = Set(
                canonical.imageFileNames + canonical.documentFileNames
                + canonical.referencedImageFileNames + canonical.referencedDocumentFileNames
            )
            let recordBasenames = Set(record.attachmentPaths.map {
                URL(fileURLWithPath: $0).lastPathComponent
            })
            guard recordBasenames == expectedBasenames else { return nil }
            canonicalMessages.append(canonical)
        }
        return try? HarnessAnnotation.makeDirectUserBatch(
            deliveryNonce: annotation.deliveryNonce,
            messages: annotationRecords(
                for: canonicalMessages,
                imagesDirectory: imagesDirectory,
                documentsDirectory: documentsDirectory
            )
        )
    }

    struct SanitizeOutcome {
        /// Annotations removed because no canonical human message backs them.
        let dropped: Int
        /// True when ANY mutation occurred — drops or canonical
        /// reconstructions. The caller must re-save the conversation whenever
        /// this is true, or normalized-away supplied paths would survive in
        /// conversation.json and leak into Mind exports or a downgraded build
        /// (Codex round-3).
        let changed: Bool
    }

    /// Drop persisted/imported annotations that reference no canonical
    /// top-level human message (Codex round-1 finding 3, tightened in round
    /// 2). A syntactically valid orphan loaded from disk or a Mind archive
    /// must not be trusted and rendered as the user speaking; annotations
    /// that pass are rebuilt from canonical data so no supplied path or text
    /// survives. Tool-result content is untouched.
    static func sanitizeOrphanAnnotations(
        in messages: inout [Message],
        imagesDirectory: URL,
        documentsDirectory: URL
    ) -> SanitizeOutcome {
        var canonicalById: [UUID: Message] = [:]
        for message in messages where message.role == .user && message.kind == .userText {
            canonicalById[message.id] = message
        }
        var dropped = 0
        var anyChange = false
        for i in messages.indices {
            guard messages[i].role == .assistant, !messages[i].toolInteractions.isEmpty else { continue }
            var interactions = messages[i].toolInteractions
            var changed = false
            for j in interactions.indices {
                for k in interactions[j].results.indices {
                    let annotations = interactions[j].results[k].harnessAnnotations
                    guard !annotations.isEmpty else { continue }
                    let rebuilt = annotations.compactMap {
                        canonicalizedAnnotation(
                            $0,
                            canonicalUserMessagesById: canonicalById,
                            imagesDirectory: imagesDirectory,
                            documentsDirectory: documentsDirectory
                        )
                    }
                    if rebuilt != annotations {
                        dropped += annotations.count - rebuilt.count
                        interactions[j].results[k].harnessAnnotations = rebuilt
                        changed = true
                    }
                }
            }
            if changed {
                messages[i].toolInteractions = interactions
                anyChange = true
            }
        }
        return SanitizeOutcome(dropped: dropped, changed: anyChange)
    }
}
