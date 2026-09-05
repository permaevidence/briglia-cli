import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Protocol is selected explicitly. Missing profile fields retain the legacy path.
enum ProviderWireProtocol: String, Codable { case chatCompletions, responses }

enum ResponsesFailure: Error, LocalizedError {
    case malformed(String), unsupported(String), incomplete(String), failed(String)
    case overflow, disconnected, http(Int, TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .malformed(let reason): return "Invalid Responses payload: \(reason)"
        case .unsupported(let type): return "Unsupported Responses output: \(type)"
        case .incomplete(let reason): return "Responses request incomplete: \(reason). No tool calls from this response were executed."
        case .failed(let reason): return "Responses request failed: \(reason). No tool calls from this response were executed."
        case .overflow: return "Responses payload exceeded the local size limit. Prune context or reduce the request."
        case .disconnected: return "Responses stream ended without a successful terminal response."
        case .http(let status, _): return "Responses HTTP \(status)"
        }
    }
}

/// These are transport/storage bounds, never an estimate of reasoning tokens.
enum ResponsesLimits {
    static let recordBytes = 8 * 1024 * 1024
    static let roundBytes = 64 * 1024 * 1024
    static let replayBytes = 64 * 1024 * 1024
    static let argumentBytes = 1024 * 1024
    static let items = 4096
}

struct ResponsesScope: Codable, Equatable {
    let endpoint: String
    let profile: String
    let model: String
    /// One-way fingerprint, never the credential itself. Key replacement invalidates replay.
    let credentialFingerprint: String
}

/// A receipt is transient and can only be produced from typed render bookkeeping.
struct PreparedRequestReceipt {
    let requestID: UUID
    let historyFingerprint: String
    let deliveryNonces: Set<String>
}

/// Only native IDs, ciphertext and canonical positions are persisted. Text,
/// arguments and tool results remain in their existing canonical structures.
struct ResponsesReplayEntry: Codable {
    let type: String
    let id: String?
    let callIndex: Int?
    let encryptedContent: String?
    let summary: [String]?
    let textParts: [Int]?
    let refusalParts: [Bool]?
}

struct ResponsesReplayEnvelope: Codable {
    let version: Int
    let responseID: String
    let scope: ResponsesScope
    let fingerprint: String
    let entries: [ResponsesReplayEntry]

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(text: String?, calls: [ToolCall]) -> String {
        struct Canonical: Encodable { let text: String?; let calls: [ToolCall] }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Both fields contain only strings/arrays; encoding cannot fail.
        return hash((try? encoder.encode(Canonical(text: text, calls: calls))) ?? Data())
    }

    var byteCount: Int { (try? JSONEncoder().encode(self).count) ?? ResponsesLimits.replayBytes + 1 }

    func matches(scope: ResponsesScope, text: String?, calls: [ToolCall]) -> Bool {
        version == 1 && self.scope == scope && byteCount <= ResponsesLimits.replayBytes
            && fingerprint == Self.fingerprint(text: text, calls: calls)
    }
}

struct ResponsesRoundMetadata {
    let envelope: ResponsesReplayEnvelope
    let receipt: PreparedRequestReceipt
    let cachedInputTokens: Int?
    let reasoningTokens: Int?
    let refused: Bool
}

struct ResponsesRound {
    let text: String?
    let calls: [ToolCall]
    let metadata: ResponsesRoundMetadata
    let inputTokens: Int?
    let outputTokens: Int?
}

extension JSONValue {
    var responsesString: String? { if case .string(let v) = self { return v }; return nil }
    var responsesObject: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var responsesArray: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var responsesInt: Int? { if case .int(let v) = self, v >= 0 { return v }; return nil }
}

/// Shared by JSON and SSE. Only a complete, validated terminal snapshot becomes
/// executable work; deltas and item-done events never escape as calls.
enum ResponsesRoundDecoder {
    static func decode(_ data: Data, scope: ResponsesScope, receipt: PreparedRequestReceipt,
                       allowedTools: Set<String>) throws -> ResponsesRound {
        guard data.count <= ResponsesLimits.roundBytes else { throw ResponsesFailure.overflow }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let object = root.responsesObject,
              let responseID = object["id"]?.responsesString, !responseID.isEmpty,
              let status = object["status"]?.responsesString else {
            throw ResponsesFailure.malformed("missing response identity/status")
        }
        if status == "incomplete" {
            let reason = object["incomplete_details"]?.responsesObject?["reason"]?.responsesString ?? "unknown reason"
            let partial = (object["output"]?.responsesArray ?? []).compactMap { $0.responsesObject }
                .filter { $0["type"]?.responsesString == "message" && $0["role"]?.responsesString == "assistant" }
                .flatMap { $0["content"]?.responsesArray ?? [] }
                .compactMap { $0.responsesObject }
                .filter { $0["type"]?.responsesString == "output_text" }
                .compactMap { $0["text"]?.responsesString }.joined()
            let suffix = partial.isEmpty ? "" : " — partial, uncompleted answer: " + MarkerNeutralizer.escape(String(partial.prefix(2000)))
            throw ResponsesFailure.incomplete(reason + suffix)
        }
        if status == "failed" {
            throw ResponsesFailure.failed(object["error"]?.responsesObject?["code"]?.responsesString ?? "provider failure")
        }
        guard status == "completed", object["error"] == nil || isNull(object["error"]),
              let output = object["output"]?.responsesArray else {
            throw ResponsesFailure.malformed("response is not a completed round")
        }
        guard output.count <= ResponsesLimits.items else { throw ResponsesFailure.overflow }
        var text = "", calls: [ToolCall] = [], entries: [ResponsesReplayEntry] = []
        var itemIDs = Set<String>(), callIDs = Set<String>(), refused = false
        for value in output {
            guard let item = value.responsesObject, let type = item["type"]?.responsesString else {
                throw ResponsesFailure.malformed("output item has no type")
            }
            let id = item["id"]?.responsesString
            if let id { guard !id.isEmpty, itemIDs.insert(id).inserted else { throw ResponsesFailure.malformed("duplicate item identity") } }
            let itemStatus = item["status"]?.responsesString
            guard itemStatus == nil || itemStatus == "completed" else { throw ResponsesFailure.malformed("unfinished output item") }
            switch type {
            case "reasoning":
                guard let id, let summary = item["summary"]?.responsesArray else { throw ResponsesFailure.malformed("reasoning metadata") }
                let summaries = try summary.map { value -> String in
                    guard let part = value.responsesObject, part["type"]?.responsesString == "summary_text",
                          let text = part["text"]?.responsesString else { throw ResponsesFailure.malformed("reasoning summary") }
                    return text
                }
                entries.append(.init(type: type, id: id, callIndex: nil,
                    encryptedContent: item["encrypted_content"]?.responsesString, summary: summaries,
                    textParts: nil, refusalParts: nil))
            case "message":
                guard item["role"]?.responsesString == "assistant", let parts = item["content"]?.responsesArray else {
                    throw ResponsesFailure.malformed("assistant message")
                }
                var lengths: [Int] = [], refusals: [Bool] = []
                for value in parts {
                    guard let part = value.responsesObject, let kind = part["type"]?.responsesString,
                          kind == "output_text" || kind == "refusal",
                          let content = part[kind == "refusal" ? "refusal" : "text"]?.responsesString else {
                        throw ResponsesFailure.unsupported("assistant content")
                    }
                    text += content; lengths.append(content.utf8.count); refusals.append(kind == "refusal")
                    refused = refused || kind == "refusal"
                }
                entries.append(.init(type: type, id: id, callIndex: nil, encryptedContent: nil,
                    summary: nil, textParts: lengths, refusalParts: refusals))
            case "function_call":
                guard let callID = item["call_id"]?.responsesString, !callID.isEmpty,
                      callIDs.insert(callID).inserted,
                      let name = item["name"]?.responsesString, allowedTools.contains(name),
                      let arguments = item["arguments"]?.responsesString else {
                    throw ResponsesFailure.malformed("duplicate/missing call identity or unexposed tool")
                }
                guard arguments.utf8.count <= ResponsesLimits.argumentBytes else { throw ResponsesFailure.overflow }
                guard (try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)))?.responsesObject != nil else {
                    throw ResponsesFailure.malformed("tool arguments must be a complete JSON object")
                }
                entries.append(.init(type: type, id: id, callIndex: calls.count, encryptedContent: nil,
                    summary: nil, textParts: nil, refusalParts: nil))
                calls.append(ToolCall(id: callID, type: "function", function: .init(name: name, arguments: arguments)))
            default: throw ResponsesFailure.unsupported(type)
            }
        }
        guard !text.isEmpty || !calls.isEmpty else { throw ResponsesFailure.malformed("no visible answer or calls") }
        guard !refused || calls.isEmpty else { throw ResponsesFailure.malformed("refusal mixed with executable calls") }
        let visible: String? = text.isEmpty ? nil : text
        let envelope = ResponsesReplayEnvelope(version: 1, responseID: responseID, scope: scope,
            fingerprint: ResponsesReplayEnvelope.fingerprint(text: visible, calls: calls), entries: entries)
        guard envelope.byteCount <= ResponsesLimits.replayBytes else { throw ResponsesFailure.overflow }
        let usage = object["usage"]?.responsesObject
        return ResponsesRound(text: visible, calls: calls,
            metadata: .init(envelope: envelope, receipt: receipt,
                cachedInputTokens: usage?["input_tokens_details"]?.responsesObject?["cached_tokens"]?.responsesInt,
                reasoningTokens: usage?["output_tokens_details"]?.responsesObject?["reasoning_tokens"]?.responsesInt,
                refused: refused),
            inputTokens: usage?["input_tokens"]?.responsesInt,
            outputTokens: usage?["output_tokens"]?.responsesInt)
    }

    private static func isNull(_ value: JSONValue?) -> Bool { if case .null? = value { return true }; return false }
}
