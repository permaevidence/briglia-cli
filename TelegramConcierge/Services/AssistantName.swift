import Foundation

/// The assistant's own name (the persona name, `assistant_name`, default
/// "Bree"), shared by the menu and `/assistantname` (MULTI_ASSISTANT_PLAN
/// §24, §28.2, §28.6 S4-P6). With several assistants it is also the
/// registry's `displayName` and must be unique (case-insensitive). One write
/// path:
/// - default: `machine/identity-tx.lock` first, then the registry presence is
///   checked (so a first `profiles add` cannot seed a stale name);
/// - no registry: the secret only (today's storage);
/// - registry: under `registry.lock` (then `secrets.lock`, the §5.6 order)
///   refuse a name another record uses, write the record's `displayName`
///   (the reservation), then the secret, then an extra's `profile.json`. A
///   crash between them is healed by `reconcile()` at startup: the secret and
///   `profile.json` follow the registry.
/// - an offline setter (not the profile's running assistant) refuses while
///   the profile has a live or unidentifiable assistant lease, probed in the
///   same registry critical section (§5.6 "who may change").
enum AssistantName {
    static let maxLength = 40
    static let defaultName = "Bree"
    static let confirmToken = "confirm"

    enum Validation: Equatable {
        case valid(String)
        case empty, tooLong, control, reserved
    }

    static func validate(_ raw: String) -> Validation {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .empty }
        if name.count > maxLength { return .tooLong }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return .control }
        if name.lowercased() == confirmToken { return .reserved }
        return .valid(name)
    }

    struct Refusal: Error, CustomStringConvertible, LocalizedError {
        let description: String
        init(_ d: String) { description = d }
        var errorDescription: String? { description }
    }

    static let runningMessage = "This assistant is running; rename it from its own chat (/assistantname) or menu, or stop it first. / Questo assistente è in funzione; rinominalo dalla sua chat (/assistantname) o dal suo menu, oppure fermalo prima."

    static func takenMessage(_ name: String) -> String {
        "Another assistant is already called ‘\(name)’ — choose a different name. / Un altro assistente si chiama già ‘\(name)’: scegli un altro nome."
    }

    static func invalidMessage(_ v: Validation) -> String {
        switch v {
        case .empty: return "The name can't be empty. / Il nome non può essere vuoto."
        case .tooLong: return "The name is longer than \(maxLength) characters. / Il nome supera \(maxLength) caratteri."
        case .control: return "The name contains invisible control characters. / Il nome contiene caratteri di controllo."
        case .reserved: return "\"confirm\" is the command's confirmation word and can't be a name. / \"confirm\" è la parola di conferma del comando e non può essere un nome."
        case .valid: return ""
        }
    }

    /// The stored name, or "Bree".
    static func current(load: (String) -> String? = { KeychainHelper.load(key: $0) }) -> String {
        let v = (load(KeychainHelper.assistantNameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? defaultName : v
    }

    /// Set the selected profile's name. Returns the stored value.
    @discardableResult
    static func set(_ raw: String, mode: IdentityChange.Mode = IdentityChange.processMode,
                    profile: String = AssistantProfile.selectedName,
                    paths: AssistantRegistry.Paths = .live,
                    identityLockURL: URL? = nil,
                    ownLease: String? = MemberEntry.current?.uuid,
                    save: (String) throws -> Void = { try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: $0) },
                    leaseDirectory: ((AssistantRegistry.Record) -> URL?)? = nil) throws -> String {
        guard case .valid(let name) = validate(raw) else { throw Refusal(invalidMessage(validate(raw))) }
        var identity: ProfileFileLock?
        if profile == AssistantProfile.defaultName {
            if identityLockURL == nil { try MachinePaths.ensureMachineDir() }
            switch ProfileFileLock.take(identityLockURL ?? MachinePaths.identityTxLock, waitSeconds: 2) {
            case .acquired(let l): identity = l
            case .busy: throw Refusal(IdentityChange.identityBusyMessage)
            case .failed(let why): throw Refusal(why)
            }
        }
        defer { identity?.release() }
        guard AssistantRegistry.exists(paths) else {
            try save(name)
            return name
        }
        let leases: (AssistantRegistry.Record) -> URL? = leaseDirectory ?? { record in
            MemberLeases.directory(profile: record.name, generation: record.generation)
        }
        try AssistantRegistry.withLock(paths) { doc in
            guard var d = doc else {
                try save(name)       // registry vanished: today's storage
                return
            }
            guard let i = d.index(profile) else {
                guard profile == AssistantProfile.defaultName else {
                    throw Refusal("This assistant is not registered on this computer.")
                }
                try save(name)
                return
            }
            if mode == .offline, let dir = leases(d.records[i]),
               !MemberLeases.users(dir, assistantsOnly: true, except: ownLease).isEmpty {
                throw Refusal(runningMessage)
            }
            if AssistantRegistry.displayNameTaken(name, in: d, excluding: profile) {
                throw Refusal(takenMessage(name))
            }
            // The record first (it is the reservation): written by withLock
            // after this body returns — so the secret is saved by a second
            // critical section below; a crash in between leaves the registry
            // ahead, which reconcile() resolves in its favour.
            d.records[i].displayName = name
            doc = d
        }
        try AssistantRegistry.withLock(paths) { doc in
            // Still ours (not renamed by someone else meanwhile).
            guard let d = doc, let r = d.record(profile), r.displayName == name else {
                if doc == nil || doc?.record(profile) == nil { try save(name) }
                return
            }
            try save(name)
        }
        if profile != AssistantProfile.defaultName { updateMetadata(profile: profile, name: name) }
        return name
    }

    /// An extra's `profile.json` mirrors the name (best effort: the registry
    /// and the secret are authoritative).
    static func updateMetadata(profile: String, name: String) {
        guard var meta = AssistantProfile.readMetadata(profile), meta.displayName != name,
              let data = try? AssistantProfile.encodeMetadata({ meta.displayName = name; return meta }()) else { return }
        try? PrivateStorage.writeAtomically(data, to: AssistantProfile.metadataURL(profile), mode: 0o600)
    }

    enum ReconcileResult: Equatable { case unchanged, adopted(String), unavailable(String) }

    /// Startup (several assistants): the registry's `displayName` is the
    /// reservation, so the stored name and an extra's `profile.json` follow
    /// it (a crash between the record write and the secret write).
    @discardableResult
    static func reconcile(profile: String = AssistantProfile.selectedName, paths: AssistantRegistry.Paths = .live,
                          load: (String) -> String? = { KeychainHelper.load(key: $0) },
                          save: (String) throws -> Void = { try KeychainHelper.save(key: KeychainHelper.assistantNameKey, value: $0) }) -> ReconcileResult {
        guard AssistantRegistry.exists(paths) else { return .unchanged }
        var result = ReconcileResult.unchanged
        do {
            try AssistantRegistry.withLock(paths) { doc in
                guard let d = doc, let r = d.record(profile), case .valid(let name) = validate(r.displayName) else { return }
                let stored = (load(KeychainHelper.assistantNameKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if stored != name {
                    try save(name)
                    result = .adopted(name)
                }
            }
        } catch {
            return .unavailable("\(error)")
        }
        if profile != AssistantProfile.defaultName, let r = (try? AssistantRegistry.read(paths))??.record(profile) {
            updateMetadata(profile: profile, name: r.displayName)
        }
        return result
    }
}
