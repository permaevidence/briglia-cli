import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Local-transcription shim (CLI)
//
// Briglia CLI is cloud-only for voice transcription (OpenAI gpt-transcribe).
// This shim preserves the WhisperKitService API surface that the core
// services reference, but never reports a local model as ready, so every
// caller falls through to its OpenAITranscriptionService branch.

@MainActor
final class WhisperKitService {
    static let shared = WhisperKitService()

    var isDownloading = false
    var isLoading = false
    var isCompiling = false
    var downloadProgress: Float = 0
    var statusMessage = "Local transcription is not available in Briglia CLI; cloud transcription (OpenAI) is used instead"
    var isModelReady = false

    var hasModelOnDisk: Bool { false }
    var isCompiled: Bool { false }

    private init() {}

    func checkModelStatus() async {}
    func loadModel() async {}
    func startDownload() async {}
    func deleteModelFromDisk() throws {}

    func transcribeAudioFile(url: URL) async -> String? { nil }

    /// A speech segment with absolute timestamps, for SRT generation.
    struct TimedSegment {
        let start: Double
        let end: Double
        let text: String
    }

    func transcribeAudioFileSegments(url: URL, language: String? = nil) async -> [TimedSegment]? { nil }
}

// MARK: - Cloud transcription (OpenAI) — identical to the Ada.app implementation

actor OpenAITranscriptionService {
    private static let defaultInstance = OpenAITranscriptionService()
    /// Selftest seam: a fake-transport service (never a live key or API).
    nonisolated(unsafe) static var overrideForTesting: OpenAITranscriptionService?
    static var shared: OpenAITranscriptionService { overrideForTesting ?? defaultInstance }

    /// Where a transcription goes. `.openAI` is the historical path
    /// (api.openai.com, byte-identical). `.openRouter` serves the OpenRouter
    /// lane when no OpenAI key is configured (`MediaRouting.transcription`):
    /// the same multipart shape on openrouter.ai, verified live 2026-09-25
    /// with `openai/gpt-transcribe` and the `prompt` vocabulary hint.
    enum Endpoint: Equatable, Sendable {
        case openAI
        case openRouter

        init(_ route: MediaRouting.TranscriptionRoute) {
            self = route.viaOpenRouter ? .openRouter : .openAI
        }

        var url: String {
            switch self {
            case .openAI: return "https://api.openai.com/v1/audio/transcriptions"
            case .openRouter: return "https://openrouter.ai/api/v1/audio/transcriptions"
            }
        }
        var textModel: String { self == .openAI ? "gpt-transcribe" : "openai/gpt-transcribe" }
        var label: String { self == .openAI ? "OpenAI" : "OpenRouter" }
        /// What tools report as the provider/model that transcribed.
        var textProviderLabel: String { self == .openAI ? "openai/gpt-transcribe" : "openrouter/openai/gpt-transcribe" }
        var srtProviderLabel: String { self == .openAI ? "openai/whisper-1" : "openrouter/openai/whisper-1" }
    }

    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    /// OpenRouter's verbose_json (whisper-1): segments with start/end
    /// seconds. OpenRouter serves no "srt" format ("Only json and
    /// verbose_json are supported", verified 2026-09-25), so SRT is built
    /// locally from these.
    struct VerboseTranscription: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
        let text: String?
        let segments: [Segment]?
    }

    private struct APIErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String
        }
        let error: APIError
    }

    /// Transcription failure carrying the real cause (HTTP status + provider
    /// message) so callers can show the user something actionable instead of
    /// a generic "check the API key".
    struct TranscriptionServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `prompt` is OpenAI's transcription hint: a short list of proper nouns
    /// the recognizer would otherwise misspell (see
    /// `TranscriptionVocabulary.chatHint`). Chat voice notes pass it;
    /// `transcribe_media` on arbitrary files does not.
    func transcribeAudioFile(url: URL, apiKey: String, language: String? = nil, prompt: String? = nil,
                             endpoint: Endpoint = .openAI) async throws -> String {
        let data = try await performRequest(
            url: url,
            apiKey: apiKey,
            model: endpoint.textModel,
            responseFormat: nil,
            language: language,
            prompt: prompt,
            endpoint: endpoint
        )

        guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            print("[OpenAITranscriptionService] Failed to decode transcription response")
            throw TranscriptionServiceError(message: "\(endpoint.label) returned an unreadable transcription response")
        }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionServiceError(message: "the audio contained no recognizable speech")
        }
        return text
    }

    /// Transcribe to SRT subtitles. Uses whisper-1 because gpt-transcribe
    /// does not support timestamped response formats.
    func transcribeAudioFileSRT(url: URL, apiKey: String, language: String? = nil, prompt: String? = nil,
                                endpoint: Endpoint = .openAI) async throws -> String {
        if endpoint == .openRouter {
            let data = try await performRequest(
                url: url,
                apiKey: apiKey,
                model: "openai/whisper-1",
                responseFormat: "verbose_json",
                language: language,
                prompt: prompt,
                endpoint: endpoint
            )
            guard let decoded = try? JSONDecoder().decode(VerboseTranscription.self, from: data) else {
                throw TranscriptionServiceError(message: "OpenRouter returned an unreadable timestamped transcription")
            }
            let srt = Self.srt(from: decoded.segments ?? [])
            guard !srt.isEmpty else {
                throw TranscriptionServiceError(message: "the audio contained no recognizable speech (no timed segments)")
            }
            return srt
        }
        let data = try await performRequest(
            url: url,
            apiKey: apiKey,
            model: "whisper-1",
            responseFormat: "srt",
            language: language,
            prompt: prompt,
            endpoint: endpoint
        )

        let srt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let srt, !srt.isEmpty else {
            print("[OpenAITranscriptionService] Empty SRT response")
            throw TranscriptionServiceError(message: "the audio contained no recognizable speech (empty SRT)")
        }
        return srt
    }

    /// Shared multipart upload to the OpenAI transcriptions endpoint.
    /// Returns the raw response body on HTTP 200; throws with the real HTTP
    /// status + provider error message otherwise, and feeds ToolServiceHealth
    /// so repeated/deterministic failures raise a user alert.
    private func performRequest(
        url: URL,
        apiKey: String,
        model: String,
        responseFormat: String?,
        language: String?,
        prompt: String?,
        endpoint route: Endpoint
    ) async throws -> Data {
        let trimmedApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedApiKey.isEmpty else {
            throw TranscriptionServiceError(message: "no \(route.label) API key is configured")
        }

        guard let endpoint = URL(string: route.url) else {
            throw TranscriptionServiceError(message: "invalid endpoint URL")
        }

        do {
            let fileData = try Data(contentsOf: url)
            let boundary = "Boundary-\(UUID().uuidString)"

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("Bearer \(trimmedApiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let filename = url.lastPathComponent.isEmpty ? "voice.ogg" : url.lastPathComponent
            request.httpBody = Self.multipartBody(
                boundary: boundary,
                model: model,
                responseFormat: responseFormat,
                language: language,
                prompt: prompt,
                filename: filename,
                mimeType: mimeType(for: url),
                fileData: fileData
            )

            let (data, response) = try await transport(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptionServiceError(message: "invalid HTTP response from \(route.label)")
            }

            guard httpResponse.statusCode == 200 else {
                let detail: String
                if let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
                    detail = apiError.error.message
                } else if let bodyText = String(data: data, encoding: .utf8), !bodyText.isEmpty {
                    detail = String(bodyText.prefix(200))
                } else {
                    detail = "no error body"
                }
                let message = "HTTP \(httpResponse.statusCode): \(detail)"
                print("[OpenAITranscriptionService] API error \(message)")
                await ToolServiceHealth.shared.recordFailure(.transcription, error: message)
                throw TranscriptionServiceError(message: message)
            }

            await ToolServiceHealth.shared.recordSuccess(.transcription)
            return data
        } catch let error as TranscriptionServiceError {
            throw error
        } catch {
            print("[OpenAITranscriptionService] Transcription error: \(error.localizedDescription)")
            await ToolServiceHealth.shared.recordFailure(.transcription, error: error.localizedDescription)
            throw TranscriptionServiceError(message: error.localizedDescription)
        }
    }

    /// SubRip text from timed segments (1-based cues, HH:MM:SS,mmm).
    nonisolated static func srt(from segments: [VerboseTranscription.Segment]) -> String {
        func stamp(_ seconds: Double) -> String {
            let totalMs = max(0, Int((seconds * 1000).rounded()))
            let h = totalMs / 3_600_000, m = (totalMs / 60_000) % 60, s = (totalMs / 1000) % 60, ms = totalMs % 1000
            return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
        }
        var cues: [String] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append("\(cues.count + 1)\n\(stamp(segment.start)) --> \(stamp(max(segment.end, segment.start)))\n\(text)")
        }
        return cues.joined(separator: "\n\n")
    }

    /// The multipart form the transcriptions endpoint expects. Pure and
    /// static so the selftest can assert the exact fields sent (the `prompt`
    /// vocabulary hint in particular) without a network.
    nonisolated static func multipartBody(
        boundary: String,
        model: String,
        responseFormat: String?,
        language: String?,
        prompt: String?,
        filename: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)
        if let responseFormat {
            appendField(name: "response_format", value: responseFormat)
        }
        if let language, !language.isEmpty {
            appendField(name: "language", value: language)
        }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            appendField(name: "prompt", value: prompt)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "ogg", "oga":
            return "audio/ogg"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        default:
            return "application/octet-stream"
        }
    }
}

// MARK: - Vocabulary hint for chat voice notes

/// Builds the `prompt` sent with chat voice notes. OpenAI's transcription
/// models treat it as a spelling/vocabulary hint, which is exactly what the
/// product and persona names need: "Briglia" is opaque to an English
/// recognizer and "Bree" to an Italian one, and a custom /setname persona
/// or an unusual user name has the same problem.
///
/// Shape matters: measured 2026-09-01 on gpt-transcribe with Italian audio,
/// a bare list ("Briglia, Bree.") still produced "Bre"/"Bray", while a
/// glossary sentence that says what each name IS ("Bree (the assistant),
/// Briglia (the software)") produced "Bree" — the model uses the role
/// context, not just the spelling. whisper-1 is fine with either.
enum TranscriptionVocabulary {
    static let productName = "Briglia"
    static let defaultPersonaName = "Bree"

    /// Hint for the configured persona and user (reads the secret store).
    static func chatHint() -> String {
        chatHint(
            assistantName: KeychainHelper.load(key: KeychainHelper.assistantNameKey),
            userName: KeychainHelper.load(key: KeychainHelper.userNameKey)
        )
    }

    /// Pure variant. The persona entry is the configured name (default
    /// "Bree"); "Bree" is still listed as a plain term when the persona was
    /// renamed, and the user's name gets its own entry. Each name is
    /// collapsed to one line, capped, and deduplicated case-insensitively.
    /// Always non-empty, always one line.
    static func chatHint(assistantName: String?, userName: String?) -> String {
        func clean(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let collapsed = raw
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !collapsed.isEmpty else { return nil }
            return String(collapsed.prefix(60))
        }
        var entries: [String] = []
        var seen = Set<String>()
        func add(_ name: String?, role: String?) {
            guard let name, seen.insert(name.lowercased()).inserted else { return }
            entries.append(role.map { "\(name) (\($0))" } ?? name)
        }
        let persona = clean(assistantName) ?? defaultPersonaName
        add(persona, role: "the assistant")
        add(defaultPersonaName, role: nil)
        add(productName, role: "the software")
        add(clean(userName), role: "the user")
        return "Names: " + entries.joined(separator: ", ") + "."
    }
}
