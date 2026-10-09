import Foundation

/// Provider-boundary image handling shared by both wire protocols
/// (CACHE_KEY_AND_IMAGE_REJECTION_PLAN v2 §2.3 serialization guard and §2.4
/// "every live projection consults the set"):
///
/// - an attachment carrying a rejection mark (in memory OR in its persisted
///   reference) is never inlined: a note takes its place;
/// - every other image passes through `ModelImage` (memoized by content hash):
///   supported bytes are sent unchanged with their sniffed MIME, unsupported
///   formats are sent converted, anything not attachable becomes a note;
/// - each image part actually inlined is recorded in the request's
///   `TransmittedImageLog` under its stable slot.
///
/// A request with no marked, converted or refused image is byte-identical to
/// v0.2.51.
extension OpenRouterService {

    struct ToolMedia {
        var parts: [ContentPart] = []
        var visible: [String] = []
        var missing: [String] = []
        var nonInline: [String] = []
        var notes: [String] = []

        mutating func merge(_ other: ToolMedia) {
            parts += other.parts; visible += other.visible; missing += other.missing
            nonInline += other.nonInline; notes += other.notes
        }

        /// Notes carry file paths (untrusted-derived): neutralized.
        var notesPart: ContentPart? {
            notes.isEmpty ? nil : .text(MarkerNeutralizer.escape(notes.joined(separator: "\n")))
        }
    }

    /// The classifier gate in front of `appendInlineAttachment` (images only;
    /// PDFs and other types are unchanged). Returns whether parts were added.
    @discardableResult
    func appendGuardedInlineAttachment(filename: String, data: Data, mimeType: String, path: String,
                                       media: inout ToolMedia, renderPDFAsImages: Bool?) -> Bool {
        let before = media.parts.count
        if normalizeMimeType(mimeType).hasPrefix("image/") {
            let outcome = ModelImage.classifyCached(data: data, declaredMime: mimeType)
            guard let attachable = outcome.attachable else {
                media.notes.append(ModelImage.notSentNote(outcome, path: path))
                return false
            }
            appendInlineAttachment(filename: filename, data: attachable.data, mimeType: attachable.mime,
                                   contentParts: &media.parts, visibleFiles: &media.visible,
                                   nonInlineFiles: &media.nonInline, renderPDFAsImages: renderPDFAsImages)
        } else {
            appendInlineAttachment(filename: filename, data: data, mimeType: mimeType,
                                   contentParts: &media.parts, visibleFiles: &media.visible,
                                   nonInlineFiles: &media.nonInline, renderPDFAsImages: renderPDFAsImages)
        }
        return media.parts.count > before
    }

    /// The in-memory attachments of one tool result.
    func toolAttachmentMedia(_ result: ToolResultMessage, owner: UUID?, log: TransmittedImageLog?,
                             renderPDFAsImages: Bool?) -> ToolMedia {
        var media = ToolMedia()
        for (ordinal, attachment) in result.fileAttachments.enumerated() {
            let path = attachment.sourcePath ?? attachment.filename
            if ImageRejectionMarks.isRejected(result, ordinal: ordinal) {
                media.notes.append(ModelImage.rejectedNote(path: path)); continue
            }
            if appendGuardedInlineAttachment(filename: attachment.filename, data: attachment.data,
                                             mimeType: attachment.mimeType, path: path, media: &media,
                                             renderPDFAsImages: renderPDFAsImages) {
                log?.record(.tool(owner: owner, callId: result.toolCallId, ordinal: ordinal), label: path)
            }
        }
        return media
    }

    /// The persisted references of one tool result (same order and outcome
    /// lists as `rehydrateAttachmentReferences`, one reference at a time).
    func toolReferenceMedia(_ result: ToolResultMessage, owner: UUID?, log: TransmittedImageLog?,
                            imagesDirectory: URL, documentsDirectory: URL, renderPDFAsImages: Bool?) -> ToolMedia {
        var media = ToolMedia()
        for (ordinal, reference) in result.fileAttachmentReferences.enumerated() {
            let path = reference.sourcePath ?? reference.filename
            if ImageRejectionMarks.isRejected(result, ordinal: ordinal) {
                media.notes.append(ModelImage.rejectedNote(path: path)); continue
            }
            guard let url = reference.resolvedURL(imagesDirectory: imagesDirectory, documentsDirectory: documentsDirectory),
                  let data = dataForAttachmentReference(reference, url: url) else {
                media.missing.append(reference.filename); continue
            }
            if appendGuardedInlineAttachment(filename: reference.filename, data: data, mimeType: reference.mimeType,
                                             path: path, media: &media, renderPDFAsImages: renderPDFAsImages) {
                log?.record(.tool(owner: owner, callId: result.toolCallId, ordinal: ordinal), label: path)
            }
        }
        return media
    }

    /// One user image: nil part when it is marked or not attachable (the
    /// returned hint then explains why); otherwise the data URL part.
    func guardedUserImage(message: Message, name: String, data: Data?, path: String,
                          log: TransmittedImageLog?) -> (part: ContentPart?, refusal: String?) {
        if message.providerRejectedImageFileNames.contains(name) {
            return (nil, ModelImage.rejectedNote(path: path))
        }
        guard let data else { return (nil, nil) }
        let outcome = ModelImage.classifyCached(data: data)
        guard let attachable = outcome.attachable else { return (nil, ModelImage.notSentNote(outcome, path: path)) }
        log?.record(.user(message: message.id, file: name), label: path)
        return (.image(ImageURL(url: "data:\(attachable.mime);base64,\(attachable.data.base64EncodedString())")), nil)
    }
}
