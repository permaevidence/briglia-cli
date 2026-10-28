import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden selftest of multi-assistant stage 2 (MULTI_ASSISTANT_PLAN §4.3,
/// §4.4, §5.6, §5.7, §6, §25): member leases and the entry protocol,
/// identity transactions, profile removal and stop, the upgrade barrier and
/// its recovery, the supervisor, the shared ChatGPT login. Same isolation as
/// `__profile-isolation-selftest` (ProfileHarness): scratch XDG roots, a
/// hard link named `briglia-mw-profiles`, throwaway preference domains.
struct MultiAssistantSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__multi-assistant-selftest",
        abstract: "Internal: multi-assistant stage-2 selftest.",
        shouldDisplay: false
    )

    @Option(name: .customLong("only")) var only: String?

    func run() throws {
        let h = try ProfileHarness(only: only)
        defer { h.cleanup() }
        if h.section("leases") { h.leasesSection() }
        if h.section("identity") { h.identitySection() }
        if h.section("remove") { h.removeSection() }
        if h.section("upgrade") { h.upgradeSection() }
        if h.section("supervisor") { h.supervisorSection() }
        if h.section("chatgpt") { h.sharedLoginSection() }
        if h.section("round2") { h.stage2Round2Section() }
        print("\n\(h.total - h.failures)/\(h.total) multi-assistant checks passed")
        if h.failures > 0 { throw ExitCode(1) }
    }
}

/// Hidden test probe: reports this process's member lease and can hold it,
/// or hold an offline identity transaction, for the race tests.
struct MemberProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__member-probe",
        abstract: "Internal: member-lease probe for selftests.",
        shouldDisplay: false
    )

    @Flag(name: .customLong("assistant")) var assistant = false
    @Option(name: .customLong("hold")) var hold: Double = 0
    @Option(name: .customLong("hold-tx")) var holdTx: String?
    @Flag(name: .customLong("long-lived")) var longLived = false
    @Flag(name: .customLong("promote")) var promote = false
    @Option(name: .customLong("reexec-after")) var reexecAfter: Double?

    func run() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        if longLived { MemberEntry.startSessionBarrierWatch(poll: 0.5) }
        var info: [String: Any] = ["profile": AssistantProfile.selectedName, "pid": Int(getpid())]
        if let lease = MemberEntry.current {
            info["uuid"] = lease.uuid
            info["role"] = lease.sidecar.role
            info["directory"] = lease.directory.path
        }
        if let g = MemberEntry.generation { info["generation"] = g }
        let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if promote, let lease = MemberEntry.current {
            let refusal = MemberEntry.promoteToAssistant(kind: "chat")
            let onDisk = MemberLeases.readSidecar(lease.sidecarURL)
            print("PROMOTED:\(refusal ?? "ok"):\(onDisk?.role ?? "?"):\(onDisk?.sessionKind ?? "?"):\(lease.uuid)")
        }
        var ticket: IdentityChange.Ticket?
        if let holdTx {
            let parts = holdTx.split(separator: ":", maxSplits: 1).map(String.init)
            let kind: AssistantRegistry.Kind = parts.first == "inbox" ? .inbox : .bot
            do {
                ticket = try IdentityChange.begin(kind: kind, rawValue: parts.count > 1 ? parts[1] : "", mode: .offline)
                print("TX_HELD")
            } catch {
                print("TX_REFUSED:\(error)")
            }
        }
        if let reexecAfter {
            // R3: the running image's sequence is compared with a validated
            // installed release that appeared after this process started.
            Thread.sleep(forTimeInterval: reexecAfter)
            UpgradeBarrier.reexecIfOlder()
            print("CONTINUED-ON-OLD-IMAGE")
        }
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        ticket?.finish()
        print("PROBE_DONE")
    }
}
