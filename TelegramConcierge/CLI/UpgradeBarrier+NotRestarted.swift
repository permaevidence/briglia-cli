import Foundation

/// An assistant that did not come back after an update (2026-10-31): the
/// barrier closes once every participant acked `restarted` OR its process is
/// gone. The second case used to be silent. `closeAttempt` now records those
/// profiles in the closed barrier (`notRestarted`, `closedAt`); this file is
/// how they are surfaced:
/// - `/status` of every running assistant and `briglia doctor --read-only`
///   name a recorded profile that is still not running after a grace period;
/// - every other running assistant sends one Telegram notice per closed
///   barrier (upgrade monitor), with the same grace and liveness re-check;
/// - the assistant itself, on its next start, removes itself from the list
///   and, unless that start is the (slow) restart of the same update, tells
///   its user it had not restarted by itself.
/// Nothing waits or retries in a loop; the list is overwritten by the next
/// update's barrier.
extension UpgradeBarrier {
    /// A participant between `execv` and its new lease looks dead for a
    /// moment; only a profile still not running after this long counts.
    static var missedRestartGrace: TimeInterval {
        if adaCLIVersion.hasSuffix("-dev"), let v = Double(ProcessInfo.processInfo.environment["BRIGLIA_TEST_MISSED_RESTART_GRACE"] ?? ""), v >= 0 { return v }
        return 90
    }

    /// Pure: the recorded profiles still not running once the grace passed.
    static func stillNotRestarted(_ barrier: Record?, now: Date, grace: TimeInterval = missedRestartGrace,
                                  running: (String) -> Bool) -> [String] {
        guard let barrier, barrier.state == .closed, let list = barrier.notRestarted, !list.isEmpty,
              let closedAt = barrier.closedAt, now.timeIntervalSince(closedAt) >= grace else { return [] }
        return list.filter { !running($0) }
    }

    /// Pure: the user-facing text (EN/IT).
    static func notRestartedText(names: [String], version: String, includesDefault: Bool) -> String {
        let list = names.map { "‘\($0)’" }.joined(separator: ", ")
        let how: String
        #if os(macOS)
        how = includesDefault
            ? "type `briglia` in a Terminal window (an extra assistant: Start on the Assistants page of `briglia menu`)"
            : "press Start on the Assistants page of `briglia menu`"
        #else
        how = "open `briglia menu` and press Start"
        #endif
        return "⚠ After the update to \(version), \(list) did not restart by itself and is not running. To start it again, \(how). / "
            + "Dopo l'aggiornamento a \(version), \(list) non si è riavviato da solo e non è in esecuzione: avvialo di nuovo."
    }

    /// Any live (or unidentifiable) assistant lease of `profile`.
    static func profileRunning(_ profile: String, paths: Paths = .live, registryPaths: AssistantRegistry.Paths = .live) -> Bool {
        let dirs = UpgradeCoordinator.memberDirectories(registryPaths, defaultDirectory: paths.root.deletingLastPathComponent().appendingPathComponent("members", isDirectory: true))
        guard let dir = dirs.first(where: { $0.profile == profile })?.directory else { return false }
        return !MemberLeases.users(dir, assistantsOnly: true).isEmpty
    }

    /// Display names for the text (registry, else the profile name).
    static func displayNames(_ profiles: [String], registryPaths: AssistantRegistry.Paths = .live) -> [String] {
        profiles.map { UpgradeCoordinator.displayName($0, registryPaths) }
    }

    /// The `/status` / doctor line, or nil.
    static func notRestartedStatusLine(paths: Paths = .live, registryPaths: AssistantRegistry.Paths = .live, now: Date = Date()) -> String? {
        let barrier = current(paths)
        let missing = stillNotRestarted(barrier, now: now) { profileRunning($0, paths: paths, registryPaths: registryPaths) }
        guard let barrier, !missing.isEmpty else { return nil }
        return notRestartedText(names: displayNames(missing, registryPaths: registryPaths), version: barrier.targetVersion,
                                includesDefault: missing.contains(AssistantProfile.defaultName))
    }

    /// Startup of `profile` (after the restart marker was read). Removes the
    /// profile from the closed barrier's list under `upgrade.lock` (waiting
    /// at most 2 s; busy → left for the next start). Returns the barrier when
    /// this start must tell its user that it had not restarted by itself:
    /// never when `restartedFromBarrier` is that barrier (the restart only
    /// took a while), never when the removal could not be written (so a
    /// later start cannot repeat the notice).
    static func resolveOwnMissedRestart(profile: String, restartedFromBarrier: String?, paths: Paths = .live) -> Record? {
        guard let peek = current(paths), peek.state == .closed, peek.notRestarted?.contains(profile) == true else { return nil }
        guard case .acquired(let lock) = ProfileFileLock.take(paths.lock, waitSeconds: 2) else { return nil }
        defer { lock.release() }
        guard var barrier = current(paths), barrier.id == peek.id, barrier.state == .closed,
              var list = barrier.notRestarted, list.contains(profile) else { return nil }
        list.removeAll { $0 == profile }
        barrier.notRestarted = list.isEmpty ? nil : list
        if list.isEmpty { barrier.closedAt = nil }
        guard (try? writeBarrier(barrier, paths)) != nil else { return nil }
        return restartedFromBarrier == barrier.id ? nil : barrier
    }

    /// The notice the assistant itself sends on such a start.
    static func ownMissedRestartText(version: String) -> String {
        "⚠ After the update to \(version) this assistant did not restart by itself; it is running again now. / "
            + "Dopo l'aggiornamento a \(version) questo assistente non si era riavviato da solo; ora è di nuovo attivo."
    }
}

/// One Telegram notice per closed barrier per process (upgrade monitor).
@MainActor
enum MissedRestartNotices {
    static var handledBarrier: String?

    /// The notice to send now, or nil. Marks the barrier handled once the
    /// grace passed (whatever the outcome), so it is evaluated once.
    static func pending(me: String, paths: UpgradeBarrier.Paths = .live, registryPaths: AssistantRegistry.Paths = .live,
                        now: Date = Date()) -> String? {
        guard let barrier = UpgradeBarrier.current(paths), barrier.state == .closed, handledBarrier != barrier.id,
              barrier.notRestarted?.isEmpty == false, let closedAt = barrier.closedAt,
              now.timeIntervalSince(closedAt) >= UpgradeBarrier.missedRestartGrace else { return nil }
        handledBarrier = barrier.id
        let missing = UpgradeBarrier.stillNotRestarted(barrier, now: now) {
            $0 == me || UpgradeBarrier.profileRunning($0, paths: paths, registryPaths: registryPaths)
        }
        guard !missing.isEmpty else { return nil }
        return UpgradeBarrier.notRestartedText(names: UpgradeBarrier.displayNames(missing, registryPaths: registryPaths),
                                               version: barrier.targetVersion,
                                               includesDefault: missing.contains(AssistantProfile.defaultName))
    }
}
