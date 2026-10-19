import ArgumentParser
import Foundation

/// Hidden battery for opt-in background pruning.
struct BackgroundPruneSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__background-prune-selftest",
        abstract: "Internal: verify background pruning.",
        shouldDisplay: false
    )

    @MainActor func run() async throws {
        print("compile fixture")
    }
}
