import Foundation

/// The per-run editing configuration (GPT_APPLY_PATCH_PLAN §3, amendment A1
/// of 2026-11-09). `.standard` is today's surface byte for byte; `.gpt`
/// swaps `edit_file`/`write_file` for the Codex-faithful `apply_patch`.
enum ToolProfile: String, Equatable, Sendable { case standard, gpt }

/// The wire form of the GPT `apply_patch` tool: Codex's freeform grammar
/// tool where a route is verified to accept it (§5.1), otherwise a JSON
/// function with one `input` string.
enum GPTPatchForm: String, Equatable, Sendable { case freeform, json }

struct EditingConfig: Equatable, Sendable, CustomStringConvertible {
    let profile: ToolProfile
    /// nil for `.standard`.
    let form: GPTPatchForm?

    static let standard = EditingConfig(profile: .standard, form: nil)
    static let gptJSON = EditingConfig(profile: .gpt, form: .json)
    static let gptFreeform = EditingConfig(profile: .gpt, form: .freeform)

    var isGPT: Bool { profile == .gpt }
    var description: String { isGPT ? "gpt/\(form?.rawValue ?? "json")" : "standard" }

    /// Resolution (§3.1 as amended by A1): kill switch → model matcher →
    /// route form → recorded rejection. `rejected` answers whether the
    /// freeform form of this route key is known to be refused; the run-start
    /// resolution passes the form store, the in-run compatibility check
    /// passes only the run's own transition (never pending store changes).
    static func resolve(model: String, route: GPTPatchRoute.Kind, routeKey: String, switchOn: Bool,
                        rejected: (String) -> Bool) -> EditingConfig {
        guard switchOn, GPTModelMatcher.isGPT(model) else { return .standard }
        if route == .freeformVerified && !rejected(routeKey) { return .gptFreeform }
        return .gptJSON
    }

    static func resolve(_ context: ProviderExecutionContext, switchOn: Bool, rejected: (String) -> Bool) -> EditingConfig {
        resolve(model: context.model, route: GPTPatchRoute.kind(context), routeKey: GPTPatchRoute.key(context),
                switchOn: switchOn, rejected: rejected)
    }

    /// Run-start resolution: live switch and the persisted form store.
    static func resolveAtRunStart(_ context: ProviderExecutionContext) -> EditingConfig {
        resolve(context, switchOn: GPTPatchSwitch.isOn, rejected: { GPTPatchFormStore.shared.hasRejection($0) })
    }
}

/// Owner amendment A1 (2026-11-09): any OpenAI GPT model of major version 5
/// or newer, on every provider, including future versions with no code
/// change. Matching is on the model-name part after any provider prefix
/// (`openai/gpt-5.6-luna` → `gpt-5.6-luna`): `gpt-` then a major version
/// number ≥ 5, then the end of the name or one of `.`, `-`, `:` (dated,
/// minor and suffixed variants such as `gpt-5-mini`, `gpt-5.1-codex`,
/// `gpt-6-luna-2026-10-01`, OpenRouter `:variant` tags). Never a loose
/// substring match: `gpt-4o`, `gpt-4.1`, `gpt-3.5-turbo`, `chatgpt-4o-latest`,
/// `gpt-oss-120b` (open question, excluded for now), `gpt-image-2` and
/// names that merely contain "gpt" are not GPT models here.
enum GPTModelMatcher {
    /// The model-name part: lowercased, trimmed, after the last `/`.
    static func modelName(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    static let minimumMajor = 5

    static func isGPT(_ id: String) -> Bool {
        let name = modelName(id)
        guard name.hasPrefix("gpt-") else { return false }
        let rest = name.dropFirst(4)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4, let major = Int(digits), major >= minimumMajor else { return false }
        let after = rest.dropFirst(digits.count)
        guard let next = after.first else { return true }
        return next == "." || next == "-" || next == ":"
    }
}

/// The kill switch (§3.5): `/gptpatch on|off`, stored like
/// `/prunebackground` (absent = on), and `BRIGLIA_GPT_PATCH=0` forcing off.
enum GPTPatchSwitch {
    static let defaultsKey = "briglia.gptPatchProfile"
    static let environmentKey = "BRIGLIA_GPT_PATCH"

    /// Test seam (same contract as the subagents flag): nil = absent.
    nonisolated(unsafe) static var storedOverrideForTesting: (() -> Bool?)?

    static var environmentForcesOff: Bool {
        ProcessInfo.processInfo.environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    static var storedValue: Bool? {
        if let override = storedOverrideForTesting { return override() }
        return Prefs.store.object(forKey: defaultsKey) as? Bool
    }

    static var storedOn: Bool { storedValue ?? true }
    static var isOn: Bool { storedOn && !environmentForcesOff }
}

/// Route classification for the patch form (§5.1 as amended by A1).
enum GPTPatchRoute {
    enum Kind: Equatable { case freeformVerified, jsonOnly }

    /// Freeform is verified (live probes, 2026-11-09, gpt-6-luna) on:
    /// - OpenRouter's Responses endpoint (phase 0: custom grammar tool
    ///   accepted, custom call and string output replayed). That route exists
    ///   in Briglia as a provider server (Responses protocol) whose base is
    ///   openrouter.ai;
    /// - the legacy ChatGPT subscription route (stage 3, probe P1: accepted,
    ///   custom call emitted, string output and native/semantic replay
    ///   accepted), only at its pinned endpoint;
    /// - Sign in with ChatGPT (stage 3, probe P2: the same, with the custom
    ///   tool inside the `briglia` namespace as Briglia sends every tool);
    /// - the OpenAI API with an API key (pre-release review L2): the same
    ///   host and endpoint P2 verified, and Codex 4e4767f sends the freeform
    ///   tool there whatever the auth mode (`create_apply_patch_freeform_tool`
    ///   for every model with `apply_patch_tool_type`; only its Vertex
    ///   provider drops it). A refusal still falls back to JSON (§5.6).
    /// Everything else — Chat Completions (including OpenRouter's main
    /// provider), OpenCode and any other custom endpoint — sends the JSON
    /// form until its own probe passes.
    static let freeformHosts: Set<String> = ["openrouter.ai", "api.openai.com"]
    /// Selftest seam: a loopback fixture server stands in for openrouter.ai.
    nonisolated(unsafe) static var freeformHostsOverrideForTesting: Set<String>?

    static func kind(_ context: ProviderExecutionContext) -> Kind {
        guard context.wireProtocol == .responses else { return .jsonOnly }
        // SIWC: every request goes to the one fixed SIWC URL (SIWCBody
        // checkDestination), whatever the context's endpoint string says.
        if context.siwc != nil || context.siwcFailure != nil { return .freeformVerified }
        if context.subscriptionGeneration != nil {
            // Legacy ChatGPT: only the pinned inference endpoint, compared as
            // the adapter does (any other endpoint is refused before sending).
            return context.endpoint == SubscriptionEndpoint.inference ? .freeformVerified : .jsonOnly
        }
        let normalized = (try? ResponsesAdapter.endpoint(context.endpoint)) ?? ""
        guard let host = URL(string: normalized)?.host?.lowercased(),
              (freeformHostsOverrideForTesting ?? freeformHosts).contains(host) else { return .jsonOnly }
        return .freeformVerified
    }

    /// §5.6 notices (route-neutral, I4).
    static let transitionNotice = "The model provider refused Briglia's patch-tool format; Briglia switched to the JSON form for this model. Nothing was lost."
    static let transitionFailedNotice = "The model provider refused Briglia's patch-tool format; Briglia tried the JSON form for this model, but that request failed too (the error follows). Nothing was changed by it."

    /// Route kind + normalized endpoint identity + model (§5.1).
    static func key(_ context: ProviderExecutionContext) -> String {
        let route: String
        if context.siwc != nil || context.siwcFailure != nil { route = "siwc" }
        else if context.subscriptionGeneration != nil { route = "chatgpt" }
        else { route = context.wireProtocol == .responses ? "responses" : "chat" }
        let endpoint = context.wireProtocol == .responses ? ((try? ResponsesAdapter.endpoint(context.endpoint)) ?? context.endpoint) : context.endpoint
        return route + "|" + endpoint + "|" + context.model
    }
}

/// Recorded freeform rejections (§5.6), per route key and Briglia version, in
/// `gpt-patch-form.json` under the data root (0600, atomic). An upgrade
/// retries freeform once. Deleted by `/deleteuserdata`; not in Mind export.
final class GPTPatchFormStore: @unchecked Sendable {
    static let shared = GPTPatchFormStore()
    static let fileName = "gpt-patch-form.json"

    private let lock = NSLock()
    private var cache: [String: String]?
    /// Test seam: a different file.
    nonisolated(unsafe) static var fileURLOverrideForTesting: URL?

    static var fileURL: URL { fileURLOverrideForTesting ?? StoragePaths.dataRoot.appendingPathComponent(fileName) }

    private func load() -> [String: String] {
        if let cache { return cache }
        var records: [String: String] = [:]
        if let data = try? Data(contentsOf: Self.fileURL),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let rejections = object["rejections"] as? [String: String] {
            records = rejections
        }
        cache = records
        return records
    }

    func hasRejection(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return load()[key] == adaCLIVersion
    }

    /// Records a rejection; true only for the first record of `key` in this
    /// version (single-flight: concurrent lanes produce one record).
    @discardableResult
    func recordRejection(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var records = load()
        guard records[key] != adaCLIVersion else { return false }
        records[key] = adaCLIVersion
        cache = records
        let object: [String: Any] = ["version": 1, "rejections": records]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            _ = try? PrivateStorage.writeAtomically(data, to: Self.fileURL, mode: 0o600)
        }
        return true
    }

    func records() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// `/deleteuserdata`, tests.
    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        if FileManager.default.fileExists(atPath: Self.fileURL.path) {
            try FileManager.default.removeItem(at: Self.fileURL)
        }
    }

    func resetCacheForTesting() {
        lock.lock(); cache = nil; lock.unlock()
    }
}

/// The run-owned editing lease (§3.2 F1). Created once per run (main turn,
/// subagent run) from the run-start context; every request of the run is
/// admitted through it, so the model, provider and protocol of each request
/// always match the inventory, prompt, stamp and engine.
final class EditingRun: @unchecked Sendable {
    private let lock = NSLock()
    private var current: EditingConfig
    private var runContext: ProviderExecutionContext
    private var transitioned = false
    /// The switch as captured at run start (compatibility checks never read
    /// a pending switch change).
    let switchOn: Bool
    private var currentRouteKey: String
    var routeKey: String { lock.lock(); defer { lock.unlock() }; return currentRouteKey }

    /// Where the §5.6 notice goes (the main turn's chat; nil = log only).
    private var notifier: (@Sendable (String) async -> Void)?
    func setNotifier(_ notifier: (@Sendable (String) async -> Void)?) { lock.lock(); self.notifier = notifier; lock.unlock() }
    func notify(_ text: String) async {
        lock.lock(); let n = notifier; lock.unlock()
        if let n { await n(text) } else { print("[GPTPatch] \(text)") }
    }

    init(context: ProviderExecutionContext, config: EditingConfig, switchOn: Bool) {
        var ctx = context
        ctx.editing = config
        self.runContext = ctx
        self.current = config
        self.switchOn = switchOn
        self.currentRouteKey = GPTPatchRoute.key(context)
    }

    /// Run-start resolution from the live switch and form store.
    static func start(_ context: ProviderExecutionContext) -> EditingRun {
        let on = GPTPatchSwitch.isOn
        let config = EditingConfig.resolve(context, switchOn: on, rejected: { GPTPatchFormStore.shared.hasRejection($0) })
        return EditingRun(context: context, config: config, switchOn: on)
    }

    var config: EditingConfig { lock.lock(); defer { lock.unlock() }; return current }
    var didTransition: Bool { lock.lock(); defer { lock.unlock() }; return transitioned }

    /// The context a request of this run uses. A fresh per-request context
    /// (Chat Completions resolves one per request) is used only when its
    /// editing configuration equals the run's; otherwise the run keeps its
    /// whole producing context and the new selection waits for the next run.
    func admit(fresh: ProviderExecutionContext) -> ProviderExecutionContext {
        lock.lock(); defer { lock.unlock() }
        let candidate = EditingConfig.resolve(fresh, switchOn: switchOn,
                                              rejected: { [transitioned, currentRouteKey] in transitioned && $0 == currentRouteKey })
        if candidate == current {
            var ctx = fresh
            ctx.editing = current
            runContext = ctx
            currentRouteKey = GPTPatchRoute.key(fresh)
            return ctx
        }
        return runContext
    }

    /// An explicit context for a request of this run (the run's Responses
    /// snapshot, an operation-scoped copy, a summary selection). Codex S2 R3:
    /// its presence never establishes ownership — the same compatibility
    /// check as `admit` applies; a cross-profile context is replaced by the
    /// run's own producing context. The run context is not updated.
    func admitExplicit(_ context: ProviderExecutionContext) -> ProviderExecutionContext {
        lock.lock(); defer { lock.unlock() }
        let candidate = EditingConfig.resolve(context, switchOn: switchOn,
                                              rejected: { [transitioned, currentRouteKey] in transitioned && $0 == currentRouteKey })
        guard candidate == current else { return runContext }
        var ctx = context
        ctx.editing = current
        return ctx
    }

    /// The run's configuration stamped on a context already admitted.
    func stamped(_ context: ProviderExecutionContext) -> ProviderExecutionContext {
        var ctx = context
        ctx.editing = config
        return ctx
    }

    /// §5.6: the one monotonic freeform → JSON transition. True when this
    /// call made it (the caller rebuilds and resends once).
    func transitionToJSON() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !transitioned, current.form == .freeform else { return false }
        transitioned = true
        current = .gptJSON
        runContext.editing = .gptJSON
        return true
    }

    /// Would a fresh selection change the editing configuration (for the
    /// `/model` reply, §3.2 F1 point 5)?
    func wouldDefer(_ fresh: ProviderExecutionContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let candidate = EditingConfig.resolve(fresh, switchOn: switchOn,
                                              rejected: { [transitioned, currentRouteKey] in transitioned && $0 == currentRouteKey })
        return candidate != current
    }
}

/// Foreign-profile edit calls (§10): a `.gpt` model calling `edit_file` or
/// `write_file`, or a standard model calling an unexposed `apply_patch`
/// (both learned from history). Only these names; every other blocked call
/// keeps today's text.
enum GPTForeignCall {
    static func message(name: String, editing: EditingConfig) -> String? {
        if editing.isGPT && (name == "edit_file" || name == "write_file") {
            return "\(name) is not available with this model; use apply_patch"
        }
        if !editing.isGPT && name == "apply_patch" {
            return "apply_patch is not available with this model; use edit_file"
        }
        return nil
    }

    /// JSON result text for a blocked call, or nil when `name` is exposed
    /// or not a foreign edit call.
    static func hint(name: String, editing: EditingConfig, exposed: Set<String>) -> String? {
        guard !exposed.contains(name), let text = message(name: name, editing: editing) else { return nil }
        let data = (try? JSONSerialization.data(withJSONObject: ["error": text], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
