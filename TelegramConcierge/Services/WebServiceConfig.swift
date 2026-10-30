import Foundation

// MARK: - Search service resolution (KEYLESS_WEB_AND_LIVE_MENU_PLAN A.3, A.7)

/// Which service answers a web search. Distinct from `WebSearchBackend`,
/// which is the MODEL backend of extraction and research (setup-api's
/// `web_search_backend` keeps that meaning).
enum SearchService: String, Sendable {
    /// A Serper.dev key is configured: today's path, unchanged.
    case serper
    /// No Serper key and free search on: Parallel's keyless Search MCP.
    case parallelKeyless = "parallel"
    /// No Serper key and free search off (or withdrawn): no search at all.
    case none
}

/// The free-search switch. On disk it is the string "true"/"false" under
/// `KeychainHelper.keylessSearchKey` in secrets.json; absent = the build
/// default. Precedence (A.7): Serper key → Serper; hard-disable constant →
/// off; `BRIGLIA_KEYLESS_SEARCH=0` → off; stored "false" → off; stored
/// "true" → on; otherwise the default constant.
enum KeylessSearchSwitch {
    /// The build's DEFAULT: what an install without an explicit choice gets.
    /// Owner decision D3 (2026-10-30): on.
    static let defaultOn = true
    /// Vendor withdrawal: forces free search off regardless of the stored
    /// choice (a release flips it; the stored value is kept for later).
    static let hardDisabled = false
    static let environmentKey = "BRIGLIA_KEYLESS_SEARCH"

    /// Selftest seams (never set in production).
    nonisolated(unsafe) static var defaultOnOverrideForTesting: Bool?
    nonisolated(unsafe) static var hardDisabledOverrideForTesting: Bool?
    nonisolated(unsafe) static var environmentOverrideForTesting: [String: String]?

    static var effectiveDefaultOn: Bool { defaultOnOverrideForTesting ?? defaultOn }
    static var effectiveHardDisabled: Bool { hardDisabledOverrideForTesting ?? hardDisabled }

    /// The environment forces free search off (only "0" is recognized, so a
    /// stray value can never turn it ON against a stored "false").
    static var environmentForcesOff: Bool {
        let env = environmentOverrideForTesting ?? ProcessInfo.processInfo.environment
        return env[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    enum Stored: String { case on = "true", off = "false", unset = "default" }

    static func stored(_ snapshot: [String: String]) -> Stored {
        switch snapshot[KeychainHelper.keylessSearchKey] {
        case "true": return .on
        case "false": return .off
        default: return .unset
        }
    }

    /// Whether free search is on, ignoring Serper (what the toggle shows).
    static func keylessEnabled(_ snapshot: [String: String]) -> Bool {
        if effectiveHardDisabled { return false }
        if environmentForcesOff { return false }
        switch stored(snapshot) {
        case .off: return false
        case .on: return true
        case .unset: return effectiveDefaultOn
        }
    }

    /// The one resolver (A.3). `serperKey` is the raw stored string: a
    /// non-empty value means Serper, exactly today's `!serperKey.isEmpty`.
    static func resolve(serperKey: String, snapshot: [String: String]) -> SearchService {
        if !serperKey.isEmpty { return .serper }
        return keylessEnabled(snapshot) ? .parallelKeyless : .none
    }

    /// From ONE coherent snapshot (never separate key loads).
    static func resolve(snapshot: [String: String]) -> SearchService {
        resolve(serperKey: snapshot[KeychainHelper.serperApiKeyKey] ?? "", snapshot: snapshot)
    }

    static func current() -> SearchService { resolve(snapshot: KeychainHelper.loadSnapshot()) }

    /// Human line for /status, /websubagent and doctor (never model-visible).
    static func summary(_ snapshot: [String: String]) -> String {
        let search: String
        switch resolve(snapshot: snapshot) {
        case .serper: search = "Serper.dev (your key)"
        case .parallelKeyless: search = "free (Parallel, no key)"
        case .none:
            search = effectiveHardDisabled ? "off (free search is withdrawn in this version; add a Serper.dev key)"
                : "off (free search switched off; add a Serper.dev key or /freesearch on)"
        }
        let jina = (snapshot[KeychainHelper.jinaApiKeyKey] ?? "").isEmpty ? "Jina without a key" : "Jina (your key)"
        return "search: \(search); page reading: \(jina)"
    }
}

// MARK: - Executor web configuration (A.9)

/// One immutable snapshot of the credentials the web pipeline uses. With
/// keys present the strings are exactly the ones passed today, so requests
/// are identical. `version` is allocated when the values are READ (not when
/// installed), so a slow stale read can never replace a newer one.
struct WebServiceConfig: Sendable, Equatable {
    let version: UInt64
    let openRouterKey: String
    let serperKey: String
    let jinaKey: String

    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    static func nextVersion() -> UInt64 {
        counterLock.lock(); defer { counterLock.unlock() }
        counter += 1
        return counter
    }

    /// Values as read now, with a version from this moment.
    static func make(openRouterKey: String, serperKey: String, jinaKey: String) -> WebServiceConfig {
        WebServiceConfig(version: nextVersion(), openRouterKey: openRouterKey, serperKey: serperKey, jinaKey: jinaKey)
    }

    static let unconfigured = WebServiceConfig(version: 0, openRouterKey: "", serperKey: "", jinaKey: "")
}

/// The shared reference root and child executors (and their orchestrators)
/// hold. Every service call takes `current` once at its start and uses only
/// that value. Installs never go backwards in version; deletion installs
/// empty strings like any other value.
final class WebServiceConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WebServiceConfig

    init(_ initial: WebServiceConfig = .unconfigured) { value = initial }

    var current: WebServiceConfig {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// True when installed; false when a newer value was already in place.
    @discardableResult
    func install(_ new: WebServiceConfig) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard new.version > value.version else { return false }
        value = new
        return true
    }
}

// MARK: - Keyless `web_query` (D14)

extension AvailableTools {
    /// The Web researcher's `web_query` when searches go to Parallel: the
    /// same schema; the description drops Serper's answer boxes and
    /// knowledge panels, which Parallel never returns. The keyed variant is
    /// `webQuery`, byte for byte unchanged.
    static let webQueryKeyless = ToolDefinition(
        function: FunctionDefinition(
            name: "web_query",
            description: "Run web searches. Provide up to \(webQueryMaxQueries) distinct queries per call; they run concurrently and return results (title, excerpt, link, publication date when known). Vary phrasing and angle rather than repeating one query. A result already retrieved in this session is listed again with the time it was retrieved and whether its extract is still in your context — nothing is hidden. Extra queries beyond the cap are dropped and reported.",
            parameters: FunctionParameters(
                properties: [
                    "queries": ParameterProperty(
                        type: "array",
                        description: "Search query strings, at most \(webQueryMaxQueries).",
                        items: ArrayItemsSchema(type: "string")
                    )
                ],
                required: ["queries"]
            )
        )
    )

    /// The `web_query` the Web researcher receives for a search service.
    static func webQuery(for service: SearchService) -> ToolDefinition {
        service == .parallelKeyless ? webQueryKeyless : webQuery
    }
}
