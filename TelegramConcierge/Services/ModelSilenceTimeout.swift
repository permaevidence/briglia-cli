import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Web researcher silence-timeout retry limit (WEB_OFFLINE_HANG, owner
/// decision 2026-10-18, replacing the earlier 180 s wall-clock round deadline).
///
/// The hang: in the Thread v5 timing trials a researcher round-2 request was
/// accepted by the provider and never answered. Each researcher model request
/// used the main-agent transport unchanged: the silence clock (360 s hosted,
/// 1200 s custom endpoints) and up to three adapter retries after a timeout,
/// so one dead provider response held the run for ~4 × 360 s.
///
/// The fix changes nothing but the retry COUNT for silence timeouts on the
/// researcher's model rounds: the transport's clocks (connect, idle, overall),
/// its attempt caps, its HTTP/transport retry schedule and every other caller
/// are exactly as in 0.2.55. A request whose attempt ends on a silence
/// timeout is retried once; a second silence timeout in the same request
/// throws `WebModelSilenceTimeoutError`, which the runner reports as
/// `web_model_timeout`. A call that keeps producing bytes is never cut by
/// anything new.
enum ModelSilenceTimeout {
    /// Silence-timeout retries per researcher request: one retry, then stop.
    static let researcherRetryLimit = 1

    /// userInfo flag set by the Responses transport on a timeout that ended
    /// an attempt with no byte for the whole silence window.
    static let silenceKey = "BrigliaSilence"

    /// Development-build seam (selftests only): replaces the 360 s / 1200 s
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

    /// True when `error` is a timeout that ended an attempt on silence:
    /// - a URLSession timeout (chat completions on URLSession.shared, or the
    ///   URLSession clock behind the Responses transport): URLSession's
    ///   request timeout is an inactivity clock, so it only fires on silence;
    /// - a Responses transport timeout carrying `silenceKey` (its connect or
    ///   idle clock, or its overall clock firing with no byte inside the idle
    ///   window, e.g. OpenRouter/OpenCode where the two are both 360 s).
    /// A Responses OVERALL expiry during an active stream is not silence and
    /// keeps the standard retries.
    static func isSilence(_ error: Error) -> Bool {
        guard let urlError = error as? URLError, urlError.code == .timedOut else { return false }
        let info = (urlError as NSError).userInfo
        guard info["BrigliaResponsesDeadline"] != nil else { return true }
        return info[silenceKey] as? Bool == true
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
