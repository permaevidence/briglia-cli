import Foundation

enum ResponsesMindExport {
    /// Strip account-bound native metadata from copied harness history only.
    /// No-key files remain byte-identical, including legacy Mind exports.
    static func sanitize(_ root: URL) throws {
        let fm = FileManager.default
        var files = [root.appendingPathComponent("conversation.json")]
        for directory in ["archive", "subagent_sessions"] {
            let url = root.appendingPathComponent(directory)
            guard fm.fileExists(atPath: url.path) else { continue }
            var enumerationError: Error?
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw ResponsesFailure.failed("cannot inspect exported replay metadata")
            }
            for case let file as URL in enumerator where file.pathExtension == "json" {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw ResponsesFailure.failed("symlink in exported history") }
                if info.isRegularFile == true { files.append(file) }
            }
            if let enumerationError { throw enumerationError }
        }
        for file in files where fm.fileExists(atPath: file.path) {
            // Scan in bounded chunks: old archives can be very large and must
            // remain byte-identical without an eager whole-file allocation.
            guard try containsReplayKey(file) else { continue }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= ResponsesLimits.roundBytes * 2 else { throw ResponsesFailure.overflow }
            let data = try Data(contentsOf: file)
            let original = try JSONDecoder().decode(JSONValue.self, from: data)
            var changed = false
            let clean = strip(original, changed: &changed)
            guard changed else { continue }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try PrivateStorage.writeAtomically(try encoder.encode(clean), to: file)
        }
    }

    private static func containsReplayKey(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let keys = [Data("\"responsesReplay\"".utf8)]
        var tail = Data()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            tail.append(chunk)
            if keys.contains(where: { tail.range(of: $0) != nil }) { return true }
            tail = Data(tail.suffix(32))
        }
        return false
    }

    private static func strip(_ value: JSONValue, changed: inout Bool) -> JSONValue {
        switch value {
        case .object(var object):
            // Only canonical Message/AssistantToolCallMessage fields are ours.
            // Vendor reasoning JSON and ordinary document data stay opaque.
            if object["role"]?.responsesString == "assistant",
               object["id"] != nil || object["tool_calls"] != nil {
                if object.removeValue(forKey: "responsesReplay") != nil { changed = true }
            }
            for key in ["messages", "toolInteractions", "assistantMessage"] {
                if let child = object[key] { object[key] = strip(child, changed: &changed) }
            }
            return .object(object)
        case .array(let values): return .array(values.map { strip($0, changed: &changed) })
        default: return value
        }
    }
}
