import ArgumentParser
import Foundation

/// Hidden, resource-free and exempt from every gate (MULTI_ASSISTANT_PLAN
/// §5.1, §6.1): prints this binary's version and compiled-in release
/// sequence as JSON, so another process can learn what is on disk without
/// trusting a record that may be stale.
struct ReleaseIdentityCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__release-identity",
        abstract: "Internal: print this binary's release identity.",
        shouldDisplay: false
    )

    func run() throws {
        let identity = UpgradeBarrier.ReleaseIdentity(version: adaCLIVersion, sequence: ReleaseSequence.compiled)
        let data = try JSONEncoder().encode(identity)
        print(String(decoding: data, as: UTF8.self))
    }
}
