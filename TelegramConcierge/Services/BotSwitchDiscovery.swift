import Foundation

/// `/switchbot` discovery under several assistants (MULTI_ASSISTANT_PLAN
/// §5.6, Codex stage-1 round 2 R2).
///
/// Discovery polls the NEW bot's `getUpdates`, which competes with any other
/// poller of that bot, and its acknowledgment request consumes the batch
/// server-side. Two rules keep it from touching a bot another assistant owns:
///
/// 1. Admission. In default, `machine/identity-tx.lock` is taken BEFORE the
///    registry check and held for the whole discovery→cutover lifetime, so
///    `briglia profiles add` (which needs that lock to create the registry
///    and reserve a bot) is refused until the switch finishes or is
///    cancelled. A never-multi install therefore cannot become multi while
///    a discovery is outstanding. Extras need no lock: they always have a
///    registry, and with a registry only the bot the profile already holds
///    may be scanned.
/// 2. Every request is gated, the acknowledgment included.
enum BotSwitchDiscovery {
    enum Admission {
        /// Discovery may run; keep the lock (nil for extras) alive until it ends.
        case admitted(ProfileFileLock?)
        case refused(String)
    }

    static let lockBusyMessage =
        "An assistant is being added, or a Telegram bot is being changed, on this computer right now — try again in a moment."

    /// `existing`: the lock an earlier, still pending switch of this process
    /// already holds (a replacement `/switchbot <token>` reuses it — a second
    /// `flock` from the same process would be refused).
    static func admit(token: String, profile: String = AssistantProfile.selectedName,
                      existing: ProfileFileLock? = nil,
                      lockURL: @autoclosure () -> URL = MachinePaths.identityTxLock,
                      ensureLockDir: () throws -> Void = { try MachinePaths.ensureMachineDir() },
                      paths: AssistantRegistry.Paths = .live) -> Admission {
        var lock: ProfileFileLock?
        if profile == AssistantProfile.defaultName {
            if let existing, existing.fd >= 0 {
                lock = existing
            } else {
                do { try ensureLockDir() } catch { return .refused("cannot prepare the assistants lock (\(error))") }
                switch ProfileFileLock.take(lockURL()) {
                case .acquired(let l): lock = l
                case .busy: return .refused(lockBusyMessage)
                case .failed(let why): return .refused(why)
                }
            }
        }
        if let refusal = AssistantRegistry.telegramDiscoveryRefusal(profile: profile, token: token, paths: paths) {
            return .refused(refusal)   // a lock taken here is released when `lock` goes out of scope
        }
        return .admitted(lock)
    }

    typealias GetUpdates = (_ token: String, _ offset: Int, _ timeoutSeconds: Int) async throws -> (status: Int, data: Data)

    /// The discovery loop: long-poll until the code appears in a private
    /// chat, then acknowledge its batch. `refusal` runs before EVERY request
    /// (the acknowledgment included); a refusal ends discovery as a
    /// permanent failure without sending anything further.
    static func run(token: String, code: String, deadline: Date,
                    refusal: () -> String?,
                    getUpdates: GetUpdates,
                    backoffNanoseconds: UInt64 = 3_000_000_000) async
        -> (discovered: BotSwitchFlow.DiscoveredChat?, permanentFailure: String?) {
        var offset = 0
        var discovered: BotSwitchFlow.DiscoveredChat?
        var permanentFailure: String?
        while !Task.isCancelled && Date() < deadline {
            if let refused = refusal() { permanentFailure = refused; break }
            do {
                let (status, data) = try await getUpdates(token, offset, 20)
                switch BotSwitchFlow.classifyGetUpdates(httpStatus: status, data: data) {
                case .updates(let parsed):
                    if let maxId = parsed.maxUpdateId { offset = maxId + 1 }
                    if let found = BotSwitchFlow.findCode(code, in: parsed.messages) {
                        // The request carrying offset = maxId+1 IS the
                        // acknowledgment: it consumes the batch, so it is
                        // gated like every other request.
                        if let refused = refusal() { permanentFailure = refused; break }
                        discovered = found
                        _ = try? await getUpdates(token, offset, 0)
                    }
                case .permanentError(let description):
                    permanentFailure = description
                case .transientError:
                    // Errored requests return instantly (no long poll to pace
                    // the loop) — back off before retrying.
                    try? await Task.sleep(nanoseconds: backoffNanoseconds)
                }
                if discovered != nil || permanentFailure != nil { break }
            } catch {
                try? await Task.sleep(nanoseconds: backoffNanoseconds)
            }
        }
        return (discovered, permanentFailure)
    }
}
