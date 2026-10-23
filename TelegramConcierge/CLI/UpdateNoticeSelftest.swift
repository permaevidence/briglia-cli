import ArgumentParser
import Foundation

/// The update-available notice (security plan v8 §5, §15 items 1–6):
/// metadata parsing and classification, the observed-release record and
/// replay, the rate/reminder state machine with identity across releases,
/// bounded history, critical-floor escalation, one-attempt delivery and
/// retries, the store (lock, cap, quarantine, deletion) and the Telegram
/// outcome classifier. Hermetic: fake clock, temp directories, fake
/// transports. Groups live in `UpdateNoticeSelftest+*.swift` (small
/// functions: large single functions overwhelm the Linux CI frontend).
struct UpdateNoticeSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__update-notice-selftest",
        abstract: "Internal: verify the update-available notice.",
        shouldDisplay: false
    )

    @Option(help: "Run only groups whose name contains this.")
    var only: String?

    final class Tally {
        var total = 0, failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            let d = ok ? "" : detail()
            print("\(ok ? "✔" : "✖") \(label)\(d.isEmpty ? "" : " — \(d)")")
            if !ok { failures += 1 }
        }
    }

    @MainActor
    func run() async throws {
        let t = Tally()
        let groups: [(String, (Tally) -> Void)] = [
            ("metadata", Self.metadataGroup),
            ("classification", Self.classificationGroup),
            ("observation", Self.observationGroup),
            ("basics", Self.basicsGroup),
            ("rate", Self.rateGroup),
            ("identity", Self.identityGroup),
            ("bounded", Self.boundedGroup),
            ("reintroduction-client", Self.reintroductionClientGroup),
            ("writer", Self.writerGroup),
            ("floor", Self.floorGroup),
            ("delivery", Self.deliveryGroup),
            ("retry", Self.retryGroup),
            ("store", Self.storeGroup),
            ("wording", Self.wordingGroup),
        ]
        for (name, run) in groups where only.map({ name.contains($0) }) ?? true {
            print("— \(name) —")
            run(t)
        }
        if only.map({ "service".contains($0) }) ?? true {
            print("— service —")
            await Self.serviceGroup(t)
        }
        if only.map({ "telegram".contains($0) }) ?? true {
            print("— telegram —")
            await Self.telegramGroup(t)
        }
        print(t.failures == 0 ? "\nALL \(t.total) UPDATE NOTICE CHECKS PASSED" : "\n\(t.failures) of \(t.total) FAILED")
        if t.failures > 0 { throw ExitCode(1) }
    }
}
