import Foundation
#if canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Terminal input helpers for the wizard and doctor: plain prompts, yes/no,
/// and no-echo secret entry with a masked preview (`sk-…3k9f`) so the user
/// can verify what was pasted without it ever appearing on screen.
enum WizardIO {
    /// A closed stdin (EOF) means no answer can ever arrive — without this the
    /// re-ask loops (askNonEmpty, askSecretValidated) would spin forever on
    /// nil reads. Finished steps are already persisted, so stop cleanly.
    private static func readLineOrExit() -> String {
        guard let line = readLine(strippingNewline: true) else {
            print("\nInput closed — stopping here. Finished steps stay saved; run `briglia setup` to continue.")
            Foundation.exit(1)
        }
        return line
    }

    static func ask(_ prompt: String, default defaultValue: String? = nil) -> String {
        print("\(prompt): ", terminator: "")
        fflush(stdout)   // a piped stdout is fully buffered; the prompt must be visible before the read
        let line = readLineOrExit().trimmingCharacters(in: .whitespaces)
        if line.isEmpty, let defaultValue { return defaultValue }
        return line
    }

    static func askNonEmpty(_ prompt: String) -> String {
        while true {
            let value = ask(prompt)
            if !value.isEmpty { return value }
            print("  A value is required.")
        }
    }

    static func askYesNo(_ prompt: String, default defaultValue: Bool) -> Bool {
        let hint = defaultValue ? "[Y/n]" : "[y/N]"
        while true {
            let answer = ask("\(prompt) \(hint)").lowercased()
            if answer.isEmpty { return defaultValue }
            if ["y", "yes"].contains(answer) { return true }
            if ["n", "no"].contains(answer) { return false }
            print("  Please answer y or n.")
        }
    }

    /// Read a secret without echoing it, then show a masked preview.
    static func askSecret(_ prompt: String) -> String {
        print("\(prompt) (input hidden): ", terminator: "")
        let secret = readSecretLine()
        print(secret.isEmpty ? "(empty)" : masked(secret))
        return secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Secret entry + inline probe loop: re-asks until the probe passes or the
    /// user explicitly keeps a failing value. When a `current` value is
    /// already saved (wizard rerun or resumed setup), Enter keeps it without
    /// re-probing — it was validated when it was stored.
    static func askSecretValidated(
        _ prompt: String,
        current: String? = nil,
        probe: (String) async -> String?
    ) async -> String {
        let saved = current.flatMap { $0.isEmpty ? nil : $0 }
        if let saved {
            print("  Saved key \(masked(saved)) found — press Enter to keep it.")
        }
        while true {
            let secret = askSecret(prompt)
            if secret.isEmpty {
                if let saved {
                    print("  ✔ keeping the saved key")
                    return saved
                }
                print("  A key is required here.")
                continue
            }
            print("  validating…", terminator: " ")
            if let failure = await probe(secret) {
                print("✖ \(failure)")
                if askYesNo("Keep this key anyway?", default: false) { return secret }
                continue
            }
            print("✔")
            return secret
        }
    }

    static func masked(_ value: String) -> String {
        guard value.count > 10 else { return "•••" }
        return "\(value.prefix(5))…\(value.suffix(4))"
    }

    /// readLine with terminal echo disabled (falls back to plain readLine when
    /// stdin is not a TTY, e.g. scripted runs).
    private static func readSecretLine() -> String {
        guard isatty(fileno(stdin)) == 1 else { return readLineOrExit() }
        var original = termios()
        tcgetattr(fileno(stdin), &original)
        var noEcho = original
        noEcho.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(fileno(stdin), TCSAFLUSH, &noEcho)
        let line = readLine(strippingNewline: true)
        // Restore echo BEFORE any exit path — Foundation.exit skips defers,
        // and a terminal left with echo off outlives the process.
        tcsetattr(fileno(stdin), TCSAFLUSH, &original)
        print("")  // the suppressed newline
        guard let line else {
            print("\nInput closed — stopping here. Finished steps stay saved; run `briglia setup` to continue.")
            Foundation.exit(1)
        }
        return line
    }
}

/// Inline network validation probes. Each returns nil on success or a short
/// human-readable failure reason.
/// Dev-build-only redirection of every setup probe to a local mock server
/// (`BRIGLIA_DEV_PROBE_BASE=http://127.0.0.1:port`), for the quick-setup
/// headless smoke and browser tests. Release builds (no `-dev` suffix)
/// ignore the variable entirely.
enum DevProbeOverride {
    static let base: String? = {
        guard adaCLIVersion.hasSuffix("-dev"),
              let raw = ProcessInfo.processInfo.environment["BRIGLIA_DEV_PROBE_BASE"], !raw.isEmpty else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }()
    static func url(_ production: String, dev path: String) -> String {
        guard let base else { return production }
        return base + path
    }
    static func chatBase(_ production: String, service: String) -> String {
        guard let base else { return production }
        return "\(base)/\(service)/v1"
    }
}

enum Probes {
    /// How a failed probe should steer the retry loop: auth failures are
    /// terminal for the key, server-side failures say nothing about the key
    /// (the gateway authenticated it before routing), anything else is a
    /// plain refusal.
    enum FailureClass {
        case auth, serverSide, other
    }

    static func classifyFailure(_ failure: String) -> FailureClass {
        if failure.contains(" returned HTTP 401") || failure.contains(" returned HTTP 403") {
            return .auth
        }
        if failure.contains(" returned HTTP 5") { return .serverSide }
        return .other
    }

    /// Key probe with fallback models: a single model's upstream being down
    /// (503 from the gateway) must not brick setup, so on a server-side
    /// failure the next candidate is tried. Auth failures return immediately
    /// — no model choice can fix a bad key.
    static func chatCompletion(
        baseURL: String, apiKey: String?, model: String, fallbackModels: [String]
    ) async -> String? {
        var lastFailure: String?
        // One probe lane for the whole operation, shared by every fallback
        // candidate (plan §3.1).
        let lane = AffinityLane.probe(UUID())
        for candidate in [model] + fallbackModels {
            let failure = await chatCompletion(baseURL: baseURL, apiKey: apiKey, model: candidate, lane: lane)
            guard let failure else {
                if candidate != model {
                    print("(\(model) endpoint is down — validated with \(candidate) instead)",
                          terminator: " ")
                }
                return nil
            }
            lastFailure = failure
            switch classifyFailure(failure) {
            case .serverSide: continue
            case .auth, .other: return failure
            }
        }
        return (lastFailure ?? "server error")
            + " — the key itself authenticated; the model endpoints look temporarily down. Retry in a few minutes, or keep the key."
    }

    /// One tiny completion against any OpenAI-compatible /chat/completions.
    /// `lane` defaults to a fresh probe lane for single-shot callers.
    static func chatCompletion(baseURL rawBase: String, apiKey: String?, model: String,
                               lane: AffinityLane = .probe(UUID())) async -> String? {
        var baseURL = rawBase
        if DevProbeOverride.base != nil {
            if rawBase == OpenCodeGo.baseURL { baseURL = DevProbeOverride.chatBase(rawBase, service: "opencode") }
            else if rawBase == "https://openrouter.ai/api/v1" { baseURL = DevProbeOverride.chatBase(rawBase, service: "openrouter") }
        }
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmedBase)/chat/completions") else { return "invalid base URL" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            try SessionAffinity.decorate(&request, apiKey: apiKey ?? "", lane: lane)
        } catch {
            return "session affinity state unavailable: \(error)"
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "Reply with OK"]],
            // No output cap (owner rule 2026-09-29): a reasoning model can
            // spend a 10-token cap before answering and fail the probe.
        ])
        return await expectHTTP200(request, service: "endpoint")
    }

    static func openAI(apiKey: String) async -> String? {
        var request = URLRequest(url: URL(string: DevProbeOverride.url("https://api.openai.com/v1/models", dev: "/openai/v1/models"))!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return await expectHTTP200(request, service: "OpenAI")
    }

    static func serper(apiKey: String) async -> String? {
        var request = URLRequest(url: URL(string: DevProbeOverride.url("https://google.serper.dev/search", dev: "/serper/search"))!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["q": "ping", "num": 1])
        return await expectHTTP200(request, service: "Serper")
    }

    static func jina(apiKey: String) async -> String? {
        var request = URLRequest(url: URL(string: DevProbeOverride.url("https://r.jina.ai/https://example.com/", dev: "/jina/https://example.com/"))!)
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return await expectHTTP200(request, service: "Jina")
    }

    static func telegram(token: String) async -> String? {
        guard let url = URL(string: DevProbeOverride.url("https://api.telegram.org/bot\(token)/getMe", dev: "/telegram/bot\(token)/getMe")) else {
            return "invalid token format"
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        return await expectHTTP200(request, service: "Telegram")
    }

    private static func expectHTTP200(_ request: URLRequest, service: String) async -> String? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "no HTTP response" }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(140)
                let detail = (body?.isEmpty == false) ? " — \(body!)" : ""
                return "\(service) returned HTTP \(http.statusCode)\(detail)"
            }
            return nil
        } catch {
            return "\(service) unreachable: \(error.localizedDescription)"
        }
    }
}
