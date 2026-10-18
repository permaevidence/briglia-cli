import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Web researcher silence-timeout retry limit (WEB_OFFLINE_HANG, owner
/// decision 2026-10-18, replacing the earlier 180 s wall-clock round deadline).
///
/// The hang: in the Thread v5 timing trials a researcher round-2 request was
/// accepted by the provider and never answered. Each researcher model request
/// used the main-agent transport unchanged: its silence clock and up to three
/// adapter retries after a timeout, so one dead provider response held the
/// run for four silence windows. The 0.2.55 clocks (unchanged here), per
/// main profile / protocol:
///   - native OpenRouter, chat completions: 360 s request (inactivity) clock;
///   - OpenAI API or ChatGPT, Responses: 360 s connect/idle, 1200 s overall;
///   - OpenCode (an OpenAI-compatible profile, so "custom"), either protocol,
///     and every other custom/local endpoint: 1200 s, idle = overall.
///
/// The fix changes nothing but the retry COUNT for silence timeouts on the
/// researcher's model rounds: the transport's clocks (connect, idle, overall,
/// URLSession request/resource), its attempt caps, its HTTP/transport retry
/// schedule and every other caller are exactly as in 0.2.55. A request whose
/// attempt ends on a silence timeout is retried once; a second silence
/// timeout in the same request throws `WebModelSilenceTimeoutError`, which the
/// runner reports as `web_model_timeout`. A call that keeps producing bytes is
/// never cut by anything new.
///
/// Silence is never inferred from a missing label (Codex round 3, R1): the
/// Responses transport labels EVERY timeout it completes with, including
/// URLSession's own completion errors, from that attempt's connect/idle
/// state read under the transport lock at the completion decision; the chat
/// path classifies its URLSession timeout at its own boundary
/// (`isChatSilence`).
enum ModelSilenceTimeout {
    /// Silence-timeout retries per researcher request: one retry, then stop.
    static let researcherRetryLimit = 1

    /// userInfo flag (Bool) the Responses transport puts on every timeout it
    /// completes with: true when the attempt's connect/idle clock had expired
    /// (no byte for the whole silence window), false otherwise, e.g. an
    /// overall or URLSession resource expiry during an active stream.
    static let silenceKey = "BrigliaSilence"

    /// Development-build seam (selftests only): replaces the 360 s (native
    /// OpenRouter / OpenAI-API base) / 1200 s (custom profiles, incl. OpenCode)
    /// `URLRequest.timeoutInterval` the chat and Responses adapters set, so a
    /// silence timeout can be reproduced in seconds. Ignored in release
    /// builds; never part of the request body.
    nonisolated(unsafe) static var requestTimeoutOverrideForTesting: TimeInterval?

    /// The adapters' per-request timeout: 0.2.55's value unless the dev seam
    /// is set.
    static func requestTimeout(customEndpoint: Bool) -> TimeInterval {
        if adaCLIVersion.hasSuffix("-dev"), let override = requestTimeoutOverrideForTesting { return override }
        return customEndpoint ? 1200 : 360
    }

    /// Responses: true only for a timeout the transport labelled silent
    /// (`silenceKey == true`). Anything unlabelled is not silence; the
    /// transport labels all of its own timeouts, so an unlabelled one would be
    /// a source this classifier knows nothing about and keeps the standard
    /// retries.
    static func isSilence(_ error: Error) -> Bool {
        guard let urlError = error as? URLError, urlError.code == .timedOut else { return false }
        return (urlError as NSError).userInfo[silenceKey] as? Bool == true
    }

    /// Chat completions (`URLSession.shared.data(for:)`, Darwin and
    /// FoundationNetworking alike): the only clocks are the request's
    /// `timeoutInterval` and the session's resource clock (URLSession.shared:
    /// seven days). The request clock is an inactivity clock on both
    /// platforms (Apple's timeoutIntervalForRequest documentation;
    /// corelibs' _EasyHandle resets it on every header/body callback), so a
    /// timeout before the resource clock could have fired means no byte for
    /// the whole silence window. A timeout at or after the resource clock is
    /// an overall expiry and is NOT silence. `elapsed`: that attempt's time
    /// from send to failure.
    static func isChatSilence(_ error: Error, elapsed: TimeInterval,
                              resourceTimeout: TimeInterval = URLSession.shared.configuration.timeoutIntervalForResource) -> Bool {
        guard let urlError = error as? URLError, urlError.code == .timedOut else { return false }
        if let labelled = (urlError as NSError).userInfo[silenceKey] as? Bool { return labelled }
        return elapsed < resourceTimeout - 1
    }

    /// The error a researcher request throws once its silence retries are
    /// spent (also when the attempt cap ends it on a silence timeout).
    static func exhausted(_ error: Error, attempts: Int, timeout: TimeInterval) -> WebModelSilenceTimeoutError {
        WebModelSilenceTimeoutError(silenceTimeouts: attempts, timeout: timeout, underlying: error.localizedDescription)
    }
}

/// Thrown by the transports for the Web researcher's rounds only.
struct WebModelSilenceTimeoutError: Error, LocalizedError {
    let silenceTimeouts: Int
    let timeout: TimeInterval
    let underlying: String
    var errorDescription: String? {
        "the research model sent nothing for \(Int(timeout)) s on \(silenceTimeouts) attempt\(silenceTimeouts == 1 ? "" : "s") (\(underlying)); research stopped"
    }
}
