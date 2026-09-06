import ArgumentParser
import Foundation

struct CacheStatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cache-stats",
        abstract: "Read recent Responses token/cache statistics (not subscription credits).")
    @Flag(name: .long, help: "Print the bounded metadata ledger as JSON.") var json = false
    func run() throws {
        let store = ResponsesUsageStore()
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(store.read() ?? ResponsesUsageStore.State()), as: UTF8.self))
        } else { print(try store.summary()) }
    }
}
