import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension OpenRouterService {
    // Shared by main chat and existing auxiliary vision requests. The complete
    // URLRequest is reused for retries; no configuration is reread here.
    private static let chatRequestMaxAttempts = 4

    // MARK: - Oversized-body retry (OpenCode hosts only)
    //
    // OpenCode Go routes a share of requests to a fallback backend that
    // refuses bodies over 4.5 MiB with HTTP 413 ("Request body exceeds the
    // 4.5 MiB limit"), while the primary backend accepts far larger bodies
    // (z.ai took 12 MiB for glm-5.3-flash). The route is picked per request,
    // not per session, and its share spikes during upstream failover
    // (measured 4/61 on 2026-09-05, 7/140 on 2026-09-07, 2/2 at one peak).
    // A 413 is rejected before the model, so retrying costs no tokens. The
    // retry re-sends the identical prepared body: same bytes, same mid-turn
    // nonce, exactly like the generic retries. It gets its own longer
    // schedule (six attempts spread over roughly 45 s) so that a failover
    // spike lasting a few seconds does not consume every attempt. Every
    // other host keeps 413 fatal on the first hit: OpenRouter's payload
    // limit is deterministic and retrying it only wastes time.
    static let oversizedBodyMaxAttempts = 6
    static let oversizedBodyBaseDelays: [TimeInterval] = [2, 4, 8, 12, 16]
    static let oversizedBodyRetryJitter: TimeInterval = 0.5
    static let openCodeFallbackBodyLimitMiB = 4.5

    /// Development-build seams for the retry selftest. `sleepScale` shortens
    /// the real sleeps (ignored by release builds); `retrySink` observes each
    /// HTTP retry decision as (status, attempt, unscaled delay).
    struct ChatRetryTestHooks {
        var sleepScale: Double = 1
        var retrySink: ((Int, Int, TimeInterval) -> Void)?
    }
    nonisolated(unsafe) static var chatRetryTestHooks = ChatRetryTestHooks()

    private struct ChatHTTPFailure {
        let statusCode: Int
        let message: String
        let retryAfter: TimeInterval?
    }

    func sendChatRequestWithRetry(
        _ request: URLRequest,
        providerLabel: String,
        model: String
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        var lastError: Error?
        let bodyBytes = request.httpBody?.count ?? 0

        // The bound is the larger of the two schedules; each status class
        // enforces its own cap inside `retryDelayForHTTPFailure`.
        while attempt <= Self.oversizedBodyMaxAttempts {
            try Task.checkCancellation()

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenRouterError.invalidResponse
                }

                guard httpResponse.statusCode == 200 else {
                    let failure = chatHTTPFailure(from: data, response: httpResponse)
                    let oversizedOnOpenCode = failure.statusCode == 413 && Self.isOpenCodeRequest(request)
                    if let delay = retryDelayForHTTPFailure(failure, request: request, attempt: attempt) {
                        Self.chatRetryTestHooks.retrySink?(failure.statusCode, attempt, delay)
                        if oversizedOnOpenCode {
                            let line = "\(providerLabel) chat request refused with HTTP 413 for \(model) (attempt \(attempt)/\(Self.oversizedBodyMaxAttempts), body \(Self.formatBytes(bodyBytes)); OpenCode's fallback route caps bodies at \(Self.openCodeFallbackBodyLimitMiB) MiB); retrying in \(String(format: "%.2f", delay))s"
                            print("[OpenRouterService] \(line)")
                            DebugTelemetry.log(.info, summary: "OpenCode 413 retry", detail: line)
                        } else {
                            print("[OpenRouterService] \(providerLabel) chat request failed with HTTP \(failure.statusCode) for \(model) (attempt \(attempt)/\(Self.chatRequestMaxAttempts)); retrying in \(String(format: "%.2f", delay))s")
                        }
                        try await sleepForRetry(delay)
                        attempt += 1
                        continue
                    }
                    if oversizedOnOpenCode {
                        let line = "\(providerLabel) chat request refused with HTTP 413 for \(model) on every attempt (\(attempt)/\(Self.oversizedBodyMaxAttempts), body \(Self.formatBytes(bodyBytes)))"
                        print("[OpenRouterService] \(line). Raw response: \(failure.message)")
                        DebugTelemetry.log(.info, summary: "OpenCode 413 exhausted", detail: line, isError: true)
                        throw OpenRouterError.apiError(Self.oversizedBodyExhaustedMessage(
                            bodyBytes: bodyBytes, attempts: attempt, upstream: failure.message))
                    }
                    print("[OpenRouterService] HTTP \(failure.statusCode) error. Raw response: \(failure.message)")
                    throw OpenRouterError.apiError("HTTP \(failure.statusCode): \(failure.message)")
                }

                if attempt > 1 {
                    print("[OpenRouterService] \(providerLabel) chat request succeeded for \(model) on attempt \(attempt)")
                }
                return (data, httpResponse)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                // Task cancellation (/stop) interrupting an in-flight request
                // surfaces as URLError.cancelled, NOT CancellationError. Normalize
                // it so the caller's cancellation handling — which salvages the
                // partial tool interactions of the interrupted turn — triggers
                // instead of treating this as a generic turn failure that discards
                // them.
                throw CancellationError()
            } catch let error as OpenRouterError {
                throw error
            } catch {
                lastError = error
                if shouldRetryTransportError(error), attempt < Self.chatRequestMaxAttempts {
                    let delay = retryDelay(forAttempt: attempt, retryAfter: nil)
                    print("[OpenRouterService] \(providerLabel) chat transport error for \(model) (attempt \(attempt)/\(Self.chatRequestMaxAttempts)): \(error.localizedDescription). Retrying in \(String(format: "%.2f", delay))s")
                    try await sleepForRetry(delay)
                    attempt += 1
                    continue
                }
                throw error
            }
        }

        throw lastError ?? OpenRouterError.invalidResponse
    }

    private func chatHTTPFailure(from data: Data, response: HTTPURLResponse) -> ChatHTTPFailure {
        let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to decode error response"
        let message: String
        if let errorResponse = try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data) {
            message = errorResponse.error.composedMessage
        } else {
            let trimmed = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 600 ? String(trimmed.prefix(600)) + "..." : trimmed
            message = snippet.isEmpty ? "(empty body)" : snippet
        }

        return ChatHTTPFailure(
            statusCode: response.statusCode,
            message: message,
            retryAfter: retryAfterDelay(from: response)
        )
    }

    /// The delay before the next attempt, or nil when this failure is not
    /// retried (status not retryable, or the class's attempt cap reached).
    /// 413 is retried only for OpenCode hosts and only on its own schedule;
    /// a Retry-After header is not consulted for it because the fallback
    /// route's refusal is not a rate limit and the spread is the point.
    private func retryDelayForHTTPFailure(_ failure: ChatHTTPFailure, request: URLRequest, attempt: Int) -> TimeInterval? {
        if failure.statusCode == 413 {
            guard Self.isOpenCodeRequest(request), attempt < Self.oversizedBodyMaxAttempts else { return nil }
            return Self.oversizedBodyRetryDelay(forAttempt: attempt)
        }
        guard shouldRetryHTTPStatus(failure.statusCode), attempt < Self.chatRequestMaxAttempts else { return nil }
        return retryDelay(forAttempt: attempt, retryAfter: failure.retryAfter)
    }

    /// Parsed-host rule shared with session affinity: `https://opencode.ai`
    /// (or a label-suffix subdomain), or the development override. No
    /// substring matching on the URL string.
    static func isOpenCodeRequest(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return SessionAffinity.isOpenCodeURL(url)
    }

    /// Attempt 1 → 2 s, 2 → 4 s, 3 → 8 s, 4 → 12 s, 5 → 16 s (+ up to 0.5 s
    /// jitter): 42–44.5 s across the five waits of a six-attempt run.
    static func oversizedBodyRetryDelay(forAttempt attempt: Int) -> TimeInterval {
        let index = max(0, min(attempt - 1, oversizedBodyBaseDelays.count - 1))
        return oversizedBodyBaseDelays[index] + Double.random(in: 0...oversizedBodyRetryJitter)
    }

    static func oversizedBodyExhaustedMessage(bodyBytes: Int, attempts: Int, upstream: String) -> String {
        "HTTP 413: OpenCode's fallback route refuses requests over \(openCodeFallbackBodyLimitMiB) MiB and this conversation's request body is \(formatBytes(bodyBytes)); all \(attempts) attempts landed on it. Send the message again, or /prune to drop old tool images. Provider said: \(upstream)"
    }

    static func formatBytes(_ bytes: Int) -> String {
        let mib = Double(bytes) / 1_048_576
        return mib >= 0.1 ? String(format: "%.2f MiB", mib) : "\(bytes) bytes"
    }

    private func shouldRetryHTTPStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 409, 425, 429, 500, 502, 503, 504, 529:
            return true
        default:
            return false
        }
    }

    private func shouldRetryTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .requestBodyStreamExhausted:
            return true
        default:
            return false
        }
    }

    private func retryAfterDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(value), seconds.isFinite {
            return max(0, min(seconds, 30))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, min(date.timeIntervalSinceNow, 30))
    }

    private func retryDelay(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter {
            return retryAfter
        }
        let exponential = min(pow(2.0, Double(attempt - 1)), 4.0)
        let jitter = Double.random(in: 0...0.25)
        return exponential + jitter
    }

    private func sleepForRetry(_ delay: TimeInterval) async throws {
        var effective = delay
        if adaCLIVersion.hasSuffix("-dev") {
            effective *= Self.chatRetryTestHooks.sleepScale
        }
        guard effective > 0 else { return }
        let nanoseconds = UInt64(effective * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

}
