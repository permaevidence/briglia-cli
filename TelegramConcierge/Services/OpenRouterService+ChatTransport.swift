import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension OpenRouterService {
    // Shared by main chat and existing auxiliary vision requests. The complete
    // URLRequest is reused for retries; no configuration is reread here.
    private static let chatRequestMaxAttempts = 4

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

        while attempt <= Self.chatRequestMaxAttempts {
            try Task.checkCancellation()

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenRouterError.invalidResponse
                }

                guard httpResponse.statusCode == 200 else {
                    let failure = chatHTTPFailure(from: data, response: httpResponse)
                    if shouldRetryHTTPStatus(failure.statusCode), attempt < Self.chatRequestMaxAttempts {
                        let delay = retryDelay(forAttempt: attempt, retryAfter: failure.retryAfter)
                        print("[OpenRouterService] \(providerLabel) chat request failed with HTTP \(failure.statusCode) for \(model) (attempt \(attempt)/\(Self.chatRequestMaxAttempts)); retrying in \(String(format: "%.2f", delay))s")
                        try await sleepForRetry(delay)
                        attempt += 1
                        continue
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
        guard delay > 0 else { return }
        let nanoseconds = UInt64(delay * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

}
