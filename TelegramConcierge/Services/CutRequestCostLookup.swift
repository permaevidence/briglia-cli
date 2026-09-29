import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Later cost lookup for OpenRouter extraction requests Briglia stopped
/// waiting for at their total deadline (ToolChargeLedger's cut-request
/// incidents). OpenRouter keeps generating and billing a non-streaming
/// request after the client leaves; its generation record
/// (GET /api/v1/generation?id=…) reports `total_cost` once it exists.
/// Until a lookup finds a cost the amount stays UNKNOWN (an open or
/// accepted incident) — never an estimate, never zero.
///
/// Driven by the daemon's idle poll, at most once per `minInterval`, one
/// run at a time; looks only at incidents younger than seven days.
enum CutRequestCostLookup {
    static let minInterval: TimeInterval = 300
    /// Selftest seam: replaces the HTTP lookup.
    nonisolated(unsafe) static var lookupOverride: ((String) async -> Double?)?

    private actor Gate {
        var running = false
        var lastStart: TimeInterval = -.infinity
        func runIfDue() async {
            let now = ProcessInfo.processInfo.systemUptime
            guard !running, now - lastStart >= CutRequestCostLookup.minInterval,
                  !ToolChargeLedger.pendingCutRequests().isEmpty else { return }
            running = true; lastStart = now
            await ToolChargeLedger.reconcileCutRequests(lookup: CutRequestCostLookup.lookup)
            running = false
        }
    }
    private static let gate = Gate()

    /// Idle hook (non-blocking).
    static func kickIfDue() {
        Task.detached { await gate.runIfDue() }
    }

    /// The generation's reported cost, or nil when unavailable (no key,
    /// not found yet, error, no cost field).
    static func lookup(_ generationId: String) async -> Double? {
        if let lookupOverride { return await lookupOverride(generationId) }
        guard let key = KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, var components = URLComponents(string: "https://openrouter.ai/api/v1/generation") else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: generationId)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseTotalCost(data)
    }

    /// `data.total_cost` of a generation record.
    static func parseTotalCost(_ data: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = object["data"] as? [String: Any], let raw = record["total_cost"] else { return nil }
        // Darwin bridges numbers as NSNumber; corelibs may hand back Double/Int.
        guard let value = (raw as? Double) ?? (raw as? Int).map(Double.init) ?? (raw as? NSNumber)?.doubleValue else { return nil }
        return value.isFinite && value >= 0 ? value : nil
    }
}
