import Foundation

/// A provider error body, read up to a fixed bound BEFORE any display
/// truncation. A body longer than the bound is flagged and never recognised:
/// a complete small JSON object followed by enough padding could otherwise
/// still parse after the cut (Codex round 2, answer 2).
struct ProviderErrorBody {
    static let limit = 64 * 1024
    let data: Data
    let truncated: Bool

    init(raw: Data) {
        truncated = raw.count > Self.limit
        data = truncated ? raw.prefix(Self.limit) : raw
    }
}

/// Recogniser for the provider's "this image is not valid" answer
/// (CACHE_KEY_AND_IMAGE_REJECTION_PLAN v2 §2.4). Deliberately narrow:
///
/// - HTTP 400 only, body within the bound, parsed as JSON;
/// - the code and the message must come from the SAME error object: the
///   top-level `error`, or the OpenAI error nested (as JSON text) in
///   OpenRouter's `error.metadata.raw`. Wrapper fields are never mixed with
///   nested ones;
/// - code ∈ {invalid_image_format, image_parse_error, invalid_image,
///   invalid_image_url}, or code `invalid_value` together with image wording
///   in that same object's message;
/// - the failed request actually carried an image part.
///
/// Anything else keeps today's behaviour exactly. SSE/200 error events are
/// out of scope.
enum ProviderImageRejection {
    static let imageCodes: Set<String> = ["invalid_image_format", "image_parse_error", "invalid_image", "invalid_image_url"]
    static let invalidValueWording = ["does not represent a valid image", "unsupported image", "image format"]

    /// The original transport error, re-thrown under this type only when the
    /// status, body and request all match. Its description is the original
    /// one, so a turn that still fails shows exactly today's text.
    struct Rejected: Error, LocalizedError {
        let status: Int
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    static func matches(status: Int, body: ProviderErrorBody) -> Bool {
        guard status == 400, !body.truncated,
              let root = try? JSONSerialization.jsonObject(with: body.data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return false }
        if objectMatches(error) { return true }
        // OpenRouter: the upstream body travels as JSON text in metadata.raw.
        guard let metadata = error["metadata"] as? [String: Any],
              let raw = metadata["raw"] as? String,
              raw.utf8.count <= ProviderErrorBody.limit,
              let nestedRoot = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let nested = nestedRoot["error"] as? [String: Any] else { return false }
        return objectMatches(nested)
    }

    private static func objectMatches(_ object: [String: Any]) -> Bool {
        guard let code = object["code"] as? String else { return false }
        if imageCodes.contains(code) { return true }
        guard code == "invalid_value", let message = (object["message"] as? String)?.lowercased() else { return false }
        return invalidValueWording.contains { message.contains($0) }
    }

    /// Whether a serialized request body carried at least one image part
    /// (Chat Completions `image_url`, Responses `input_image`).
    static func requestCarriesImage(_ body: Data?) -> Bool {
        guard let body else { return false }
        return body.range(of: Data("\"input_image\"".utf8)) != nil
            || body.range(of: Data("\"image_url\"".utf8)) != nil
    }

    /// The transport-level decision: wrap `underlying` when everything matches.
    static func classify(status: Int, rawBody: Data, requestBody: Data?, underlying: Error) -> Error {
        guard status == 400, requestCarriesImage(requestBody),
              matches(status: status, body: ProviderErrorBody(raw: rawBody)) else { return underlying }
        return Rejected(status: status, underlying: underlying)
    }

    /// The original error for callers that classify by transport type.
    static func unwrap(_ error: Error) -> Error {
        (error as? Rejected)?.underlying ?? error
    }
}
