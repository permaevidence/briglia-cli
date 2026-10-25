import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Reading and per-entry decoding of `reminders.json` (0.2.63,
/// REMINDERS_LOAD_AND_ARG_HINT_PLAN §2.1).
///
/// Before 0.2.63 every reader decoded the whole array in one go: one malformed
/// entry (e.g. a hand edit) made the daemon load ZERO reminders and its next
/// save overwrote the file, destroying every reminder. Here each element is
/// decoded on its own: valid rows load, invalid ones are reported so the
/// caller can set the original aside before anything is rewritten.
enum ReminderStoreFile {
    enum Read: Equatable {
        case absent
        case unreadable(String)
        case data(Data)
    }

    enum Decoded {
        /// The file is a JSON array. `rejected` holds each element that does
        /// not decode as a `Reminder` (non-objects included), RE-SERIALISED
        /// from the parsed element — same content, not the file's exact bytes.
        case entries(valid: [Reminder], rejected: [Data])
        /// Not JSON, truncated, or JSON whose top level is not an array.
        case notAnArray
    }

    /// `lstat` decides absence (only ENOENT counts as absent); the file is then
    /// opened non-blocking and `fstat`ed through the descriptor, so a FIFO,
    /// socket, directory or dangling/cyclic link is refused without blocking.
    /// A link to a regular file is read.
    static func read(_ url: URL) -> Read {
        let path = url.path
        var lst = stat()
        if lstat(path, &lst) != 0 {
            let code = errno
            return code == ENOENT ? .absent : .unreadable("it could not be inspected (\(String(cString: strerror(code))))")
        }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            return .unreadable("it could not be opened (\(String(cString: strerror(errno))))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return .unreadable("it could not be inspected (\(String(cString: strerror(errno))))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .unreadable("it is not a regular file")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { posixRead(fd, $0.baseAddress, $0.count) }
            if n > 0 { data.append(buffer, count: n); continue }
            if n == 0 { break }
            if errno == EINTR { continue }
            return .unreadable("it could not be read (\(String(cString: strerror(errno))))")
        }
        return .data(data)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func decode(_ data: Data) -> Decoded {
        guard let top = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let array = top as? [Any] else {
            return .notAnArray
        }
        let decoder = makeDecoder()
        var valid: [Reminder] = []
        var rejected: [Data] = []
        for element in array {
            // Every element of a parsed array re-serialises (fragmentsAllowed
            // covers bare strings/numbers/null). If one ever did not, treat
            // the file as unparseable so the caller preserves it whole —
            // never drop an element silently.
            guard let raw = try? JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
                return .notAnArray
            }
            if element is [String: Any], let reminder = try? decoder.decode(Reminder.self, from: raw) {
                valid.append(reminder)
            } else {
                rejected.append(raw)
            }
        }
        return .entries(valid: valid, rejected: rejected)
    }

    /// Read-only lenient read for side readers (`briglia trigger`, the session
    /// registry's pinned-set hydration): the valid rows, or nil when the file
    /// is absent/unreadable/not an array. Never writes.
    static func readValidEntries(at url: URL) -> [Reminder]? {
        guard case .data(let data) = read(url) else { return nil }
        if case .entries(let valid, _) = decode(data) { return valid }
        return nil
    }
}

@inline(__always)
private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.read(fd, buf, count)
    #else
    return Darwin.read(fd, buf, count)
    #endif
}
