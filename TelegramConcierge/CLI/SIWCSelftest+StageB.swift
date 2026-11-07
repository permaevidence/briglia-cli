import Foundation

extension SIWCSelftest {
    static func bodyTests(_ root: URL, _ c: Checks) async throws {}
    static func routeTests(_ root: URL, _ c: Checks) async throws {}
    static func adapterTests(_ root: URL, _ c: Checks) async throws {}
    static func adapterSignOutTests(_ root: URL, _ c: Checks) async throws {}
    static func webTests(_ root: URL, _ c: Checks) async throws {}
    static func modelsTests(_ root: URL, _ c: Checks) async throws {}
    static func errorTests(_ root: URL, _ c: Checks) async throws {}
    static func legacyUnchangedTests(_ root: URL, _ c: Checks) async throws {}
}
