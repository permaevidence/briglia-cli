import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hidden regression test: a Bot API transport failure must never expose the
/// bot token. Before this guard a DNS outage printed the full
/// `https://api.telegram.org/bot<token>/getUpdates?...` URL to the terminal
/// through NSURLError's userInfo (`[ConversationManager] Poll tick failed:`).
/// Runs against an unresolvable `.invalid` host (RFC 2606) with an isolated
/// XDG root — no real Briglia state, no real network endpoint.
struct TelegramTransportSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__telegram-transport-selftest",
        abstract: "Internal: verify Telegram transport errors never carry the bot token.",
        shouldDisplay: false
    )

    func run() async throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("briglia-tg-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        setenv("BRIGLIA_TELEGRAM_API_BASE", "https://telegram-transport-selftest.invalid/bot", 1)

        // Synthetic fixture: Bot API token SHAPE only (`<bot id>:<35-char
        // secret>`), never a real credential. The secret is a repeated
        // placeholder so it cannot be mistaken for one.
        let secret = String(repeating: "S", count: 35)
        let token = "1234567890:\(secret)"

        // 1. Static scrubber: the exact NSURLError userInfo shape seen in the field.
        let fieldLine = "Error Domain=NSURLErrorDomain Code=-1003 \"A server with the specified hostname could not be found.\" " +
            "NSErrorFailingURLStringKey=https://api.telegram.org/bot\(token)/getUpdates?offset=100&timeout=0, " +
            "NSErrorFailingURLKey=https://api.telegram.org/file/bot\(token)/photos/file_1.jpg"
        let scrubbed = TelegramBotService.redactBotTokens(in: fieldLine)
        check("scrubber removes every token occurrence", !scrubbed.contains(secret) && !scrubbed.contains(token))
        check("scrubber keeps the surrounding diagnostics",
              scrubbed.contains("Code=-1003") && scrubbed.contains("getUpdates?offset=100") && scrubbed.contains("bot[REDACTED]/getUpdates"))
        check("scrubber leaves a chat id alone", TelegramBotService.redactBotTokens(in: "chat 123456789 update 100") == "chat 123456789 update 100")
        check("scrubber leaves a timestamp alone", TelegramBotService.redactBotTokens(in: "2026-09-10T05:58:00 12:34:56") == "2026-09-10T05:58:00 12:34:56")

        // 2. Live transport path: every Bot API call funnels URLSession errors
        //    through the same helper; getUpdates and a file download are the
        //    two URL shapes that embed the token.
        let service = TelegramBotService()
        await service.configure(token: token)
        var pollError: Error?
        do { _ = try await service.getUpdates() } catch { pollError = error }
        check("getUpdates against an unresolvable host fails", pollError != nil)
        if let error = pollError {
            let rendered = "\(error)"
            check("getUpdates error is TelegramError.transport",
                  { if case .transport = error as? TelegramError { return true } else { return false } }(),
                  String(describing: type(of: error)))
            check("rendered getUpdates error carries no token", !rendered.contains(secret), rendered)
            // Linux's FoundationNetworking (curl) names the HOST in its
            // description ("Could not resolve host: …"); that is not a
            // secret. The invariant is the token-bearing PATH never appears.
            check("rendered getUpdates error carries no token path", !rendered.contains("/bot") && !rendered.contains("getUpdates"), rendered)
            check("localizedDescription carries no token", !error.localizedDescription.contains(secret), error.localizedDescription)
            check("rendered error is readable", rendered.hasPrefix("Telegram network error ("), rendered)
        }

        var sendError: Error?
        do { try await service.sendMessage(chatId: 1, text: "probe") } catch { sendError = error }
        check("sendMessage against an unresolvable host fails", sendError != nil)
        if let error = sendError {
            check("rendered sendMessage error carries no token", !"\(error)".contains(secret), "\(error)")
        }

        // 3. Cancellation survives as a bare URLError(.cancelled) — the turn's
        //    cancellation predicate depends on it.
        let cancelTask = Task { try await service.sendMessage(chatId: 1, text: "cancel-probe") }
        cancelTask.cancel()
        var cancelError: Error?
        do { try await cancelTask.value } catch { cancelError = error }
        if let error = cancelError {
            let isCancel = error is CancellationError || (error as? URLError)?.code == .cancelled
            let isTransport: Bool = { if case .transport = error as? TelegramError { return true } else { return false } }()
            check("cancelled send surfaces as cancellation or a token-free transport error",
                  (isCancel || isTransport) && !"\(error)".contains(secret), "\(error)")
        } else {
            check("cancelled send did not throw (accepted: request finished before cancellation)", true)
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        if failures > 0 { throw ExitCode.failure }
    }
}
