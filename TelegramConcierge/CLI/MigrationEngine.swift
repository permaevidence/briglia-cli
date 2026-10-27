import ArgumentParser
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Rename-migration engine (RENAME_PLAN.md §4.3, Stage 3)
//
// Moves an existing installation's persisted state from one product identity
// to another (config root, data root, landing zone, binary, resource bundle,
// systemd unit, preferences domain, persona default) as a crash-safe
// transaction with a byte-identical restore guarantee: after ANY failed or
// rolled-back migration the old installation is functional and every touched
// file matches its recorded preimage.
//
// The engine is deliberately identity-neutral: every path, unit name, domain
// and persona string arrives through MigrationSpec, so the same code runs the
// real rename later and runs hermetically against fixtures today (Stage 3 is
// built and tested under the current identity per the plan).
//
// Transaction shape (journal states):
//   prepared → moved → fixups → committing → committed → done
//
//   • prepared:  pre-state captured (service flags, binary hash); nothing on
//                disk has changed yet apart from the journal itself.
//   • moved:     the roots were rename(2)d old → new.
//   • fixups:    path-embedding files inside and outside the moved roots are
//                being rewritten; every modified file has a hash-recorded
//                preimage FIRST, every created artifact an `absent` record.
//   • committing: written durably BEFORE the first retirement sub-step. From
//                here recovery completes forward; old assets are PARKED into
//                the journal area (content, type, mode preserved), never
//                deleted.
//   • committed: retirement finished; post-commit verification pending.
//   • done:      verification passed; cleanup (parked/preimages/journal
//                deletion) is the only remaining work and costs nothing but
//                disk if interrupted.
//
// Recovery semantics by state (plan §4.3.6): before `committing` recovery may
// roll back (or complete forward when intact); at or after `committing` it
// deterministically completes forward — unless forward completion is
// impossible AND the parked assets verify intact, in which case a defined
// park-restoring rollback runs. A `committed`/`done` journal always reruns
// post-commit verification before any cleanup.

struct MigrationSpec: Codable, Equatable {
    // Roots moved by rename(2). Old and new must live on one filesystem.
    var oldConfigRoot: String
    var newConfigRoot: String
    var oldDataRoot: String
    var newDataRoot: String
    var oldLandingZone: String?
    var newLandingZone: String?

    // The installed product binary and its SwiftPM resource bundle.
    var oldBinary: String
    var newBinary: String
    var oldBundle: String?
    var newBundle: String?

    // Where the agentmail broker wrapper and toolchain wrappers live.
    var wrapperBinDir: String

    // systemd user unit management. `systemctl` nil ⇒ no unit management on
    // this host (macOS): capture records not-installed and unit steps no-op.
    var unitDir: String?
    var oldUnitName: String?
    var newUnitName: String?
    var newUnitText: String?
    var systemctl: String?

    // Ubuntu Touch keep-awake unit (plan §4.3 step 1: BOTH units captured
    // with three independent flags; recreated/retired transactionally
    // "where privileges allow"). It is a SYSTEM unit — a separate systemctl
    // seam without --user, and `wakelockManaged` says whether this process
    // may modify system units (phones route that through the UT app's sudo
    // dialog; an unmanaged run captures state and warns instead).
    var oldWakelockUnitPath: String?
    var newWakelockUnitPath: String?
    var oldWakelockUnitName: String?
    var newWakelockUnitName: String?
    var newWakelockUnitText: String?
    var wakelockSystemctl: String?
    var wakelockManaged: Bool?

    // Bounded health probe (plan §4.3.5b): argv that must exit 0 against the
    // NEW identity before anything old is retired.
    var healthProbe: [String]
    var healthProbeTimeout: Double?

    // Journal home — must sit OUTSIDE every old and every moved root.
    var stateDir: String

    // Persona rewrite: applied only when the stored assistant name is
    // EXACTLY personaOldName (plan §4.5.1).
    var personaOldName: String
    var personaNewName: String
    var personaMarkerName: String?

    // UserDefaults domain copy (plan §4.5.8). Domain names, not paths — the
    // copy goes through the persistent-domain API on both platforms.
    var oldPrefsDomain: String?
    var newPrefsDomain: String?

    // Detection markers for wrapper ownership and in-flight upgrades.
    var toolchainWrapperMarker: String?
    var agentmailWrapperName: String?
    var upgradeMarkerNames: [String]?

    // The command doctor tells the user to run for recovery.
    var recoveryCommand: String?

    var probeTimeout: Double { healthProbeTimeout ?? 60 }
    var markerName: String { personaMarkerName ?? "migrated_from_ada.json" }
    var toolchainMarker: String { toolchainWrapperMarker ?? UserdataToolchain.wrapperMarker }
    var agentmailName: String { agentmailWrapperName ?? "agentmail" }
    var upgradeMarkers: [String] {
        upgradeMarkerNames ?? [".ada-upgrade-staged-bin", ".ada-upgrade-staged-bundle"]
    }
    var recoveryHint: String { recoveryCommand ?? "migrate" }
    var wakelockPrivileged: Bool { wakelockManaged ?? false }

    /// Root pairs in move order. Only pairs whose old side exists at run
    /// time are moved; the journal records what was found.
    var rootPairs: [(old: String, new: String)] {
        var pairs = [(oldConfigRoot, newConfigRoot), (oldDataRoot, newDataRoot)]
        if let ol = oldLandingZone, let nl = newLandingZone { pairs.append((ol, nl)) }
        return pairs
    }
}

struct MigrationJournal: Codable {
    var schema: Int
    var state: String
    var createdAt: String
    var spec: MigrationSpec

    struct UnitCapture: Codable {
        var name: String
        var unitPath: String
        var installed: Bool
        var enabled: Bool
        var active: Bool
    }
    var oldService: UnitCapture?
    var wakelockService: UnitCapture?
    var stoppedOldService: Bool

    var oldBinaryExists: Bool
    var oldBinaryIsSymlink: Bool
    var oldBinarySymlinkTarget: String?
    var oldBinarySHA256: String?

    struct RootMove: Codable {
        var old: String
        var new: String
        var existed: Bool
        var moved: Bool
    }
    var roots: [RootMove]

    /// Typed preimage manifest (plan v6 correction 4). `file` carries bytes
    /// under preimages/<id> plus metadata; `symlink` records the target and
    /// is restored as a symlink, never dereferenced; `absent` marks a path
    /// the migration CREATED — rollback must delete it. The two prefs types
    /// cover the UserDefaults domain copy: `prefs-old-domain` stores the
    /// exported old domain (re-imported by a park-restoring rollback after
    /// retirement removed it), `prefs-new-domain` marks the created domain
    /// for deletion on rollback.
    struct Preimage: Codable {
        var id: String
        var type: String   // "file" | "symlink" | "absent" | "prefs-old-domain" | "prefs-new-domain"
        var path: String   // filesystem path, or the domain name for prefs types
        var sha256: String?
        var mode: Int?
        var uid: Int?
        var gid: Int?
        var target: String?
    }
    var preimages: [Preimage]

    /// Retired assets moved (never deleted) into parked/ at ≥ committing.
    struct Parked: Codable {
        var id: String
        var originalPath: String
        var kind: String   // "file" | "directory" | "symlink"
        var sha256: String?
        var mode: Int?
        var uid: Int?
        var gid: Int?
        var target: String?
    }
    var parked: [Parked]

    var fixupsDone: [String]
    var newUnitInstalled: Bool
    var newUnitEnabled: Bool
    var startedNewUnit: Bool
    var newWakelockInstalled: Bool
    var newWakelockEnabled: Bool
    var startedNewWakelock: Bool
    var symlinkCreated: Bool
    /// §4.6: the file at oldBinary did not hash-match the capture — it was
    /// left untouched and no compat symlink was created.
    var binaryParkSkipped: Bool
    var warnings: [String]
    /// Set durably at the top of commit(): roots moved and every fixup
    /// applied, so the NEW identity may serve — the startup gate admits a
    /// daemon started by the live (lock-holding) migrator only on this
    /// flag. Optional for journals written before it existed (read as
    /// false: such a daemon is refused, never admitted by guesswork).
    var newInstallReady: Bool?
}

enum MigrationOutcome {
    case ok(notes: [String])
    /// Pre-conditions not met; nothing was changed (or everything was
    /// restored). Safe to retry after addressing the reason.
    case refused(String)
    /// The journal (or its recorded paths) failed validation. Nothing was
    /// touched; the message says exactly what was found.
    case corrupt(String)
    /// The migration failed. The message states whether the old install was
    /// restored (rollback) or everything was held in place for recovery.
    case failed(String)
}

enum MigrationMode: String {
    case auto      // forward by default; rollback only when forward fails
    case rollback  // explicit rollback request (honored only before committing)
}

final class MigrationEngine {
    let spec: MigrationSpec
    let mode: MigrationMode
    let log: (String) -> Void
    let fm = FileManager.default
    var journal: MigrationJournal
    var notes: [String] = []

    var stateDirURL: URL { URL(fileURLWithPath: spec.stateDir) }
    var journalURL: URL { stateDirURL.appendingPathComponent("journal.json") }
    var preimagesDir: URL { stateDirURL.appendingPathComponent("preimages") }
    var parkedDir: URL { stateDirURL.appendingPathComponent("parked") }

    struct EngineError: Error { let outcome: MigrationOutcome }

    // ------------------------------------------------------------ entry

    static func run(spec: MigrationSpec, mode: MigrationMode,
                    log: @escaping (String) -> Void) -> MigrationOutcome {
        if let why = validateSpec(spec) { return .refused(why) }
        // Exclusive cross-process lock (Codex Stage 3 round 1 #1): two
        // concurrent migrate/recovery processes would load the same journal
        // and race the same root renames. The lock is a SIBLING of the state
        // dir — cleanup deletes the state dir wholesale, and unlinking a
        // held lock would let a rival acquire a fresh inode at the same path
        // (the toolchain-lock lesson). Held for the whole transaction;
        // flock dies with the process, so a crash never wedges it.
        let lockPath = spec.stateDir.hasSuffix("/")
            ? String(spec.stateDir.dropLast()) + ".lock" : spec.stateDir + ".lock"
        try? FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let lockFD = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        guard lockFD >= 0 else {
            return .refused("cannot open the migration lock at \(lockPath): "
                + String(cString: strerror(errno)))
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            return .refused("another migration or recovery process is already running "
                + "(lock \(lockPath) is held) — wait for it to finish and retry")
        }
        // Close-on-exec, or the daemon this migration STARTS inherits the fd
        // and keeps the flock alive after we exit — every later recovery
        // would then refuse against a phantom holder (the InstanceLock
        // lesson).
        _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        sweepOrphanTemps(stateDir: spec.stateDir)
        let journalPath = URL(fileURLWithPath: spec.stateDir)
            .appendingPathComponent("journal.json")
        if FileManager.default.fileExists(atPath: journalPath.path) {
            switch loadJournal(spec: spec) {
            case .failure(let why): return .corrupt(why.message)
            case .success(let journal):
                let engine = MigrationEngine(spec: spec, mode: mode, journal: journal, log: log)
                return engine.recover()
            }
        }
        let engine = MigrationEngine(spec: spec, mode: mode,
                                     journal: freshJournal(spec: spec), log: log)
        return engine.fresh()
    }

    /// Staging temps of a `writeDurable` interrupted before its rename are
    /// swept from the journal area (state dir and its immediate
    /// subdirectories) under the transaction lock, at every engine start.
    /// Only our own `.migrate-tmp-*` names are touched, and only regular
    /// files — never a directory, never a symlink's target.
    static let stagingTempPrefix = ".migrate-tmp-"

    static func sweepOrphanTemps(stateDir: String) {
        let fm = FileManager.default
        var dirs = [stateDir]
        if let children = try? fm.contentsOfDirectory(atPath: stateDir) {
            for child in children {
                let path = stateDir + "/" + child
                var st = stat()
                if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    dirs.append(path)
                }
            }
        }
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries where name.hasPrefix(stagingTempPrefix) {
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFREG || kind == S_IFLNK { unlink(path) }
            }
        }
    }

    private init(spec: MigrationSpec, mode: MigrationMode,
                 journal: MigrationJournal, log: @escaping (String) -> Void) {
        self.spec = spec
        self.mode = mode
        self.journal = journal
        self.log = log
    }

    // ---------------------------------------------------- read-only APIs

    struct DetectionStatus {
        var oldRootsPresent: [String]
        var newRootsPresent: [String]
        var journalState: String?
        var migrationNeeded: Bool {
            !oldRootsPresent.isEmpty || journalState != nil
        }
    }

    /// Strictly read-only (plan §4.2): consulted by diagnostic commands,
    /// performs zero filesystem writes.
    static func detect(spec: MigrationSpec) -> DetectionStatus {
        let fm = FileManager.default
        var old: [String] = []
        var new: [String] = []
        for pair in spec.rootPairs {
            if fm.fileExists(atPath: pair.old) { old.append(pair.old) }
            if fm.fileExists(atPath: pair.new) { new.append(pair.new) }
        }
        let journalPath = URL(fileURLWithPath: spec.stateDir)
            .appendingPathComponent("journal.json")
        var state: String? = nil
        if let data = try? Data(contentsOf: journalPath),
           let parsed = try? JSONDecoder().decode(MigrationJournal.self, from: data) {
            state = parsed.state
        } else if fm.fileExists(atPath: journalPath.path) {
            state = "unreadable"
        }
        return DetectionStatus(oldRootsPresent: old, newRootsPresent: new,
                               journalState: state)
    }

    /// doctor's view (plan §4.3): reports the journal state and prints the
    /// recovery command. Never mutates, never prompts.
    static func doctorReport(spec: MigrationSpec) -> String? {
        let status = detect(spec: spec)
        guard let state = status.journalState else { return nil }
        return "an interrupted identity migration was found (journal state: \(state)) — "
            + "run `\(spec.recoveryHint)` to recover; nothing is changed until you do"
    }

    // ------------------------------------------------------- validation

    static func validateSpec(_ spec: MigrationSpec) -> String? {
        var all: [String] = [spec.oldConfigRoot, spec.newConfigRoot,
                             spec.oldDataRoot, spec.newDataRoot,
                             spec.oldBinary, spec.newBinary,
                             spec.wrapperBinDir, spec.stateDir]
        all += [spec.oldLandingZone, spec.newLandingZone, spec.oldBundle,
                spec.newBundle, spec.unitDir].compactMap { $0 }
        for path in all {
            guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                return "spec path is not an absolute, traversal-free path: \(path)"
            }
        }
        for pair in spec.rootPairs where pair.old == pair.new {
            return "old and new root are the same path: \(pair.old)"
        }
        // The journal must survive every root move and every rollback — it
        // cannot live inside anything it protects (plan §4.3 journal
        // protocol).
        let state = spec.stateDir.hasSuffix("/") ? spec.stateDir : spec.stateDir + "/"
        for root in spec.rootPairs.flatMap({ [$0.old, $0.new] }) {
            let prefixed = root.hasSuffix("/") ? root : root + "/"
            if state.hasPrefix(prefixed) {
                return "the journal directory \(spec.stateDir) lies inside the root \(root) — it must be outside every moved root"
            }
        }
        if spec.healthProbe.isEmpty {
            return "spec has no health probe command"
        }
        // systemctl is executed by absolute path only — never resolved
        // through PATH at run time (the production spec pins the standard
        // locations; the -dev seam supplies an explicit path).
        for tool in [spec.systemctl, spec.wakelockSystemctl].compactMap({ $0 }) {
            guard tool.hasPrefix("/"), !tool.split(separator: "/").contains("..") else {
                return "spec names a systemctl that is not an absolute path: \(tool)"
            }
        }
        for name in [spec.oldUnitName, spec.newUnitName,
                     spec.oldWakelockUnitName, spec.newWakelockUnitName].compactMap({ $0 }) {
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                return "spec names an invalid systemd unit: \"\(name)\""
            }
        }
        return nil
    }

    /// Journal load with corruption refusal (plan §4.3): unknown schema,
    /// parse failure, spec mismatch with the invoking spec, or any recorded
    /// path outside the expected per-user locations refuses — nothing is
    /// guessed or repaired.
    struct LoadFailure: Error { let message: String }

    static func loadJournal(spec: MigrationSpec) -> Result<MigrationJournal, LoadFailure> {
        let url = URL(fileURLWithPath: spec.stateDir).appendingPathComponent("journal.json")
        guard let data = try? Data(contentsOf: url) else {
            return .failure(LoadFailure(message: "the migration journal at \(url.path) exists but cannot be read"))
        }
        guard let journal = try? JSONDecoder().decode(MigrationJournal.self, from: data) else {
            return .failure(LoadFailure(message: "the migration journal at \(url.path) is not parseable — refusing to act on it. "
                + "Inspect it manually; if it is damaged beyond repair and you are certain no migration "
                + "is in flight, delete the directory \(spec.stateDir) to start over"))
        }
        guard journal.schema == 1 else {
            return .failure(LoadFailure(message: "the migration journal has unknown schema \(journal.schema) — refusing to act on it"))
        }
        guard journal.spec == spec else {
            return .failure(LoadFailure(message: "the migration journal was written for a different spec (paths differ) — refusing to act on it"))
        }
        let states = ["prepared", "moved", "fixups", "committing", "committed", "done"]
        guard states.contains(journal.state) else {
            return .failure(LoadFailure(message: "the migration journal has unknown state \"\(journal.state)\" — refusing to act on it"))
        }
        // Recorded unit captures name exactly the spec's units — the
        // journal never gets to pick which unit rollback restarts or
        // recovery retires.
        if let service = journal.oldService {
            guard let dir = spec.unitDir, let name = spec.oldUnitName,
                  service.name == name, service.unitPath == dir + "/" + name else {
                return .failure(LoadFailure(message: "the migration journal records a service (\(service.name) at \(service.unitPath)) that is not the spec's old unit — refusing to act on it"))
            }
        }
        if let wakelock = journal.wakelockService {
            guard let name = spec.oldWakelockUnitName, let path = spec.oldWakelockUnitPath,
                  wakelock.name == name, wakelock.unitPath == path else {
                return .failure(LoadFailure(message: "the migration journal records a keep-awake unit (\(wakelock.name) at \(wakelock.unitPath)) that is not the spec's — refusing to act on it"))
            }
        }
        // Every recorded path must resolve — symlinks canonicalized through
        // the deepest existing ancestor — to a location STRICTLY INSIDE one
        // the spec names, never a whole directory itself: rollback DELETES
        // `absent` paths, so a corrupted entry naming e.g. the wrapper bin
        // dir must not validate (Codex Stage 3 round 1 #4).
        var allowed = spec.rootPairs.flatMap { [$0.old, $0.new] }
        allowed += [spec.wrapperBinDir,
                    (spec.oldBinary as NSString).deletingLastPathComponent,
                    (spec.newBinary as NSString).deletingLastPathComponent]
        allowed += [spec.unitDir, spec.oldBundle, spec.newBundle].compactMap { $0 }
        if let path = spec.oldWakelockUnitPath {
            allowed.append((path as NSString).deletingLastPathComponent)
        }
        if let path = spec.newWakelockUnitPath {
            allowed.append((path as NSString).deletingLastPathComponent)
        }
        let canonicalAllowed = allowed.compactMap { canonicalize($0, dereferenceLeaf: true) }
        func strictlyInside(_ path: String) -> Bool {
            guard let canonical = canonicalize(path) else { return false }
            return canonicalAllowed.contains { root in
                canonical.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }
        // Preimage ids become filesystem paths under preimages/ — constrain
        // the alphabet (no separators, no traversal) and require uniqueness
        // so a corrupted journal cannot alias two records onto one stored
        // preimage (Codex Stage 3 round 2 #2).
        var seenPreimageIDs = Set<String>()
        for pre in journal.preimages {
            guard !pre.id.isEmpty,
                  pre.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                return .failure(LoadFailure(message: "the migration journal has an invalid preimage id \"\(pre.id)\" — refusing to act on it"))
            }
            guard seenPreimageIDs.insert(pre.id).inserted else {
                return .failure(LoadFailure(message: "the migration journal has a duplicate preimage id \"\(pre.id)\" — refusing to act on it"))
            }
            switch pre.type {
            case "file":
                guard pre.sha256 != nil, !pre.id.isEmpty else {
                    return .failure(LoadFailure(message: "the migration journal has a file preimage without a hash (\(pre.path)) — refusing to act on it"))
                }
                guard strictlyInside(pre.path) else {
                    return .failure(LoadFailure(message: "the migration journal records a path outside the expected locations (\(pre.path)) — refusing to act on it"))
                }
            case "symlink":
                guard pre.target != nil else {
                    return .failure(LoadFailure(message: "the migration journal has a symlink preimage without a target (\(pre.path)) — refusing to act on it"))
                }
                guard strictlyInside(pre.path) else {
                    return .failure(LoadFailure(message: "the migration journal records a path outside the expected locations (\(pre.path)) — refusing to act on it"))
                }
            case "absent":
                guard strictlyInside(pre.path) else {
                    return .failure(LoadFailure(message: "the migration journal records a path outside the expected locations (\(pre.path)) — refusing to act on it"))
                }
            case "prefs-old-domain", "prefs-new-domain":
                guard pre.path == spec.oldPrefsDomain || pre.path == spec.newPrefsDomain else {
                    return .failure(LoadFailure(message: "the migration journal records an unexpected preferences domain (\(pre.path)) — refusing to act on it"))
                }
            default:
                return .failure(LoadFailure(message: "the migration journal has a preimage of unknown type \"\(pre.type)\" — refusing to act on it"))
            }
        }
        // Parked assets restore to EXACT spec-named targets — validate the
        // id → path binding precisely, not just containment.
        let parkedTargets: [String: String?] = [
            "unit": spec.unitDir.flatMap { dir in spec.oldUnitName.map { dir + "/" + $0 } },
            "wakelock-unit": spec.oldWakelockUnitPath,
            "binary": spec.oldBinary,
            "bundle": spec.oldBundle,
        ]
        var seenParkedIDs = Set<String>()
        for parked in journal.parked {
            guard seenParkedIDs.insert(parked.id).inserted else {
                return .failure(LoadFailure(message: "the migration journal has a duplicate parked id \"\(parked.id)\" — refusing to act on it"))
            }
            guard let expected = parkedTargets[parked.id] ?? nil,
                  parked.originalPath == expected else {
                return .failure(LoadFailure(message: "the migration journal records an unexpected parked asset (\(parked.id) → \(parked.originalPath)) — refusing to act on it"))
            }
            switch parked.kind {
            case "file", "directory":
                guard parked.sha256 != nil else {
                    return .failure(LoadFailure(message: "the migration journal has a parked \(parked.id) without a hash — refusing to act on it"))
                }
            case "symlink":
                guard parked.target != nil else {
                    return .failure(LoadFailure(message: "the migration journal has a parked symlink without a target — refusing to act on it"))
                }
            default:
                return .failure(LoadFailure(message: "the migration journal has a parked asset of unknown kind \"\(parked.kind)\" — refusing to act on it"))
            }
        }
        // Roots must be exactly the spec's pairs, in order and in FULL — a
        // truncated array would silently skip a root during recovery.
        let specPairs = spec.rootPairs
        guard journal.roots.count == specPairs.count else {
            return .failure(LoadFailure(message: "the migration journal records \(journal.roots.count) roots where the spec defines \(specPairs.count) — refusing to act on it"))
        }
        for (index, root) in journal.roots.enumerated() {
            guard root.old == specPairs[index].old, root.new == specPairs[index].new else {
                return .failure(LoadFailure(message: "the migration journal's root #\(index) does not match the spec — refusing to act on it"))
            }
        }
        return .success(journal)
    }

    /// Canonical form for containment checks: realpath(3) of the deepest
    /// EXISTING ancestor of the PARENT (defeating symlinked parents), with
    /// the leaf and any not-yet-existing remainder re-appended (already
    /// traversal-checked). The leaf itself is never dereferenced: recorded
    /// paths are directory ENTRIES the engine manipulates with lstat
    /// semantics — a recorded `absent` path that currently holds the compat
    /// symlink (dangling once the new binary is gone) must still validate
    /// as the entry it names, not as wherever the link points.
    static func canonicalize(_ path: String, dereferenceLeaf: Bool = false) -> String? {
        guard path.hasPrefix("/"), path != "/",
              !path.split(separator: "/").contains("..") else {
            return nil
        }
        var existing = path
        var remainder: [String] = []
        if !dereferenceLeaf {
            // Recorded entry: canonicalize the parent chain only.
            existing = (path as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
            remainder = [(path as NSString).lastPathComponent]
        }
        while existing != "/" {
            var st = stat()
            if lstat(existing, &st) == 0 { break }
            remainder.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard realpath(existing, &buffer) != nil else { return nil }
        var canonical = String(cString: buffer)
        for component in remainder.reversed() {
            canonical += (canonical.hasSuffix("/") ? "" : "/") + component
        }
        return canonical
    }

    static func freshJournal(spec: MigrationSpec) -> MigrationJournal {
        MigrationJournal(
            schema: 1, state: "prepared",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            spec: spec, oldService: nil, wakelockService: nil,
            stoppedOldService: false,
            oldBinaryExists: false, oldBinaryIsSymlink: false,
            oldBinarySymlinkTarget: nil, oldBinarySHA256: nil,
            roots: [], preimages: [], parked: [], fixupsDone: [],
            newUnitInstalled: false, newUnitEnabled: false,
            startedNewUnit: false,
            newWakelockInstalled: false, newWakelockEnabled: false,
            startedNewWakelock: false, symlinkCreated: false,
            binaryParkSkipped: false, warnings: [], newInstallReady: false)
    }

    /// Resolve the default journal home from the environment:
    /// `$XDG_STATE_HOME/<name>`, default `~/.local/state/<name>`.
    static func defaultStateDir(name: String,
                                environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL {
        let base: URL
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state", isDirectory: true)
        }
        return base.appendingPathComponent(name, isDirectory: true)
    }

    // ----------------------------------------------------- crash seams

    /// Fault-injection seam for durability tests (same pattern as
    /// BRIGLIA_TOOLCHAIN_FAULT): "prefs-sync" | "fsync=<exact path>". The fsync
    /// fault fires INSIDE `fsyncPath`, before the real fsync(2) is issued —
    /// a fault injected after a real barrier already succeeded would prove
    /// nothing about the failure path (Codex Stage 3 round 3 #2).
    static var faultPoint: String? {
        ProcessInfo.processInfo.environment["BRIGLIA_MIGRATE_FAULT"]
    }

    static var fsyncFaultPath: String? {
        guard let fault = faultPoint, fault.hasPrefix("fsync=") else { return nil }
        return String(fault.dropFirst("fsync=".count))
    }

    /// Test-only crash injection: a REAL process death (no defers, no
    /// cleanup) at named points after every destructive sub-step, driven by
    /// the selftest through subprocess runs.
    static func crashPoint(_ name: String) {
        if ProcessInfo.processInfo.environment["BRIGLIA_MIGRATE_CRASH_POINT"] == name {
            FileHandle.standardError.write(Data("injected crash at \(name)\n".utf8))
            _exit(137)
        }
    }

    // --------------------------------------------------- durable writes

    static func fsyncPath(_ url: URL) -> String? {
        if let faultPath = fsyncFaultPath, faultPath == url.path {
            return "fsync failed for \(url.path): injected fault (no barrier was issued)"
        }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            return "could not open \(url.path) for fsync: \(String(cString: strerror(errno)))"
        }
        let rc = fsync(fd)
        close(fd)
        guard rc == 0 else {
            return "fsync failed for \(url.path): \(String(cString: strerror(errno)))"
        }
        return nil
    }

    /// temp file → checked chmod → fsync(file) → rename(2) →
    /// fsync(directory). The journal and every fixup modification ride on
    /// this. The mode is applied to the TEMP file, before the rename and the
    /// barriers — a crash can therefore never leave the final path with
    /// content but wrong permissions (Codex Stage 3 round 1 #3: secrets.json
    /// must never exist with loosened permissions, even transiently across
    /// power loss).
    @discardableResult
    static func writeDurable(_ data: Data, to url: URL, mode: Int? = nil) -> String? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return "could not create \(dir.path): \(error.localizedDescription)"
        }
        // The temp is created EXCLUSIVELY (O_EXCL, 0600) and written through
        // its own descriptor: a name planted at the temp path beforehand —
        // a symlink pointing anywhere — makes the create fail instead of
        // being followed.
        let tmp = dir.appendingPathComponent(stagingTempPrefix + UUID().uuidString)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return "could not create \(tmp.path) exclusively: \(String(cString: strerror(errno)))"
        }
        var writeError: String? = nil
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count, raw.baseAddress != nil {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    writeError = String(cString: strerror(errno))
                    return
                }
                offset += n
            }
        }
        if let writeError {
            close(fd)
            unlink(tmp.path)
            return "could not write \(tmp.path): \(writeError)"
        }
        // Mode: the requested one, else what a plain create would have
        // produced under the process umask (the temp starts at 0600 so the
        // final file is never wider than the caller asked for, even
        // transiently).
        let finalMode: mode_t
        if let mode {
            finalMode = mode_t(mode)
        } else {
            let current = umask(0o022)
            umask(current)
            finalMode = 0o666 & ~current
        }
        guard fchmod(fd, finalMode) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            unlink(tmp.path)
            return "could not set mode \(String(finalMode, radix: 8)) on \(url.path): \(why)"
        }
        if let faultPath = fsyncFaultPath, faultPath == tmp.path {
            close(fd)
            unlink(tmp.path)
            return "fsync failed for \(tmp.path): injected fault (no barrier was issued)"
        }
        guard fsync(fd) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            unlink(tmp.path)
            return "fsync failed for \(tmp.path): \(why)"
        }
        close(fd)
        guard rename(tmp.path, url.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            return "could not move \(tmp.lastPathComponent) into place at \(url.path): \(why)"
        }
        return fsyncPath(dir)
    }

    func persistJournal() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        if let why = Self.writeDurable(data, to: journalURL, mode: 0o600) {
            throw EngineError(outcome: .failed("could not persist the migration journal: \(why)"))
        }
    }

    func setState(_ state: String) throws {
        journal.state = state
        try persistJournal()
    }

    // ---------------------------------------------------------- hashing

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(ofFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256(of: data)
    }

    /// Deterministic recursive hash of a directory tree: sorted relative
    /// paths with per-entry type, mode and content hash. Used to verify
    /// parked bundles byte-for-byte before a park-restoring rollback.
    /// Content+metadata hash of a tree, keyed by paths RELATIVE to `root`.
    /// Uses the path-based enumerator, which yields relative subpaths
    /// directly: the URL-based one can hand back paths with a different
    /// prefix than `root.path` (e.g. /var → /private/var on macOS), and a
    /// prefix-length `dropFirst` then produces garbage that depends on the
    /// root's path length — the same tree hashed at its original location
    /// and inside parked/ would not match.
    static func treeHash(of root: URL) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root.path) else { return nil }
        var entries: [String] = []
        for case let rel as String in enumerator {
            let url = root.appendingPathComponent(rel)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            let mode = st.st_mode & 0o7777
            if (st.st_mode & S_IFMT) == S_IFLNK {
                guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else {
                    return nil
                }
                entries.append("\(rel)|link|\(target)")
            } else if (st.st_mode & S_IFMT) == S_IFDIR {
                entries.append("\(rel)|dir|\(String(mode, radix: 8))")
            } else {
                guard let hash = sha256(ofFile: url) else { return nil }
                entries.append("\(rel)|file|\(String(mode, radix: 8))|\(hash)")
            }
        }
        return sha256(of: Data(entries.sorted().joined(separator: "\n").utf8))
    }

    static func fileMode(_ path: String) -> Int? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Int(st.st_mode & 0o7777)
    }

    // ------------------------------------------------------ subprocesses

    struct RunResult {
        let exitCode: Int32
        let output: String
        var tail: String {
            output.count <= 400 ? output : "…" + output.suffix(400)
        }
    }

    /// Bounded, non-interactive subprocess: stdin from /dev/null, output to
    /// a temp FILE, SIGKILL past the deadline. Deliberately posix_spawn +
    /// waitpid(WNOHANG), not Foundation Process: on Linux, corelibs detects
    /// child exit through an inherited socketpair, and a daemonized
    /// grandchild (exactly what `systemctl start` leaves behind) keeps that
    /// socketpair open past the child's exit — the parent then never sees
    /// the exit (the orphan-hostage trap from the Bash-streaming arc,
    /// reference_corelibs_process_pipes_linux). waitpid reports the direct
    /// child's real exit immediately, grandchildren notwithstanding; the
    /// file-backed output likewise cannot be held hostage the way pipe EOF
    /// can.
    static func runBounded(_ argv: [String], timeout: Double,
                           extraEnv: [String: String] = [:],
                           outputDir: URL? = nil) -> RunResult {
        guard let exe = argv.first, exe.hasPrefix("/") else {
            return RunResult(exitCode: 127, output: "argv[0] must be an absolute path")
        }
        let fm = FileManager.default
        // The output file is created EXCLUSIVELY (O_EXCL, 0600) by this
        // process and handed to the child as fds 1/2. The engine passes
        // its 0700 state dir; callers without one fall back to the
        // process temp dir (still exclusive).
        let outDir = outputDir ?? fm.temporaryDirectory
        if let outputDir {
            try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        let outURL = outDir.appendingPathComponent("migrate-out-\(UUID().uuidString)")
        let outFD = open(outURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard outFD >= 0 else {
            return RunResult(exitCode: 127, output: "could not create the output file "
                + "\(outURL.path) exclusively: \(String(cString: strerror(errno)))")
        }
        defer { close(outFD); unlink(outURL.path) }

        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        defer { for arg in cargs { free(arg) } }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnv { environment[key] = value }
        var cenv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)
        defer { for entry in cenv { free(entry) } }

        #if os(Linux)
        var fileActions = posix_spawn_file_actions_t()
        #else
        var fileActions: posix_spawn_file_actions_t? = nil
        #endif
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, outFD, 2)

        // SETSIGDEF + empty SETSIGMASK: give the child clean signal state,
        // exactly as Foundation Process does when it spawns. Raw posix_spawn
        // otherwise propagates inherited ignored dispositions AND the signal
        // mask — observed live in the selftest, where a daemon started
        // through this path (fake systemctl → lock holder) inherited an
        // unkillable SIGTERM from the harness ancestry and outlived every
        // stop (the SetsidExec lesson, second sighting).
        #if os(Linux)
        var attr = posix_spawnattr_t()
        #else
        var attr: posix_spawnattr_t? = nil
        #endif
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaultSigs = sigset_t()
        sigfillset(&defaultSigs)
        posix_spawnattr_setsigdefault(&attr, &defaultSigs)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF) | Int16(POSIX_SPAWN_SETSIGMASK))

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &fileActions, &attr, cargs, cenv)
        guard rc == 0 else {
            return RunResult(exitCode: 127, output: "\(exe): \(String(cString: strerror(rc)))")
        }
        var status: Int32 = 0
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited == -1 && errno != EINTR { break }
            if Date() >= deadline {
                timedOut = true
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        var text = ""
        if let data = fm.contents(atPath: outURL.path) {
            text = String(decoding: data, as: UTF8.self)
        }
        if timedOut {
            return RunResult(exitCode: 124, output: text + "\n(timed out after \(Int(timeout))s)")
        }
        let signum = status & 0x7f
        let code: Int32 = signum != 0 ? 128 + signum : (status >> 8) & 0xff
        return RunResult(exitCode: code, output: text)
    }

    func systemctl(_ args: [String]) -> RunResult {
        guard let path = spec.systemctl else {
            return RunResult(exitCode: 0, output: "")
        }
        return Self.runBounded([path, "--user"] + args, timeout: 60, outputDir: stateDirURL)
    }

    /// System-bus systemctl for the wakelock unit (no --user).
    func systemctlSystem(_ args: [String]) -> RunResult {
        guard let path = spec.wakelockSystemctl ?? spec.systemctl else {
            return RunResult(exitCode: 0, output: "")
        }
        return Self.runBounded([path] + args, timeout: 60, outputDir: stateDirURL)
    }

    /// A service operation whose failure must surface, never be shrugged
    /// off (Codex Stage 3 round 1 #2): rollback deleting the journal after
    /// an ignored failed restart would falsely report a restored system.
    func systemctlChecked(_ args: [String], system: Bool = false,
                          context: String) throws {
        let result = system ? systemctlSystem(args) : systemctl(args)
        guard result.exitCode == 0 else {
            throw EngineError(outcome: .failed(
                "\(context): systemctl \(args.joined(separator: " ")) failed "
                + "(exit \(result.exitCode)): \(result.tail) — the journal at "
                + "\(journalURL.path) is preserved; re-run `\(spec.recoveryHint)` after fixing this"))
        }
    }

    /// Unit-state probes that DISTINGUISH "definitely not active/enabled"
    /// from "the query itself failed" (command missing, timeout, permission
    /// error, garbage output). Interpreting a broken systemctl as "inactive"
    /// would let capture record — and rollback verify — fiction (Codex
    /// Stage 3 round 2 #4).
    struct UnitQueryFailure: Error { let message: String }

    /// Transitional unit states (systemd's `activating`, `deactivating`,
    /// `reloading`, `refreshing`, `maintenance`) are NEITHER running nor
    /// stopped: reading `activating` as inactive would let the migration
    /// skip stopping an old daemon that is still starting (Codex Stage 3
    /// round 3 #3). The probe waits a bounded time for the unit to settle,
    /// then refuses — capture/rollback/recovery must retry, never guess.
    static let transitionalStates: Set<String> =
        ["activating", "deactivating", "reloading", "refreshing", "maintenance"]
    static let transitionalWaitSeconds: TimeInterval = 5
    static let transitionalPollInterval: UInt32 = 250_000   // µs

    func queryActive(_ name: String, system: Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(Self.transitionalWaitSeconds)
        var lastTransitional: String? = nil
        while true {
            let result = system ? systemctlSystem(["is-active", name])
                                : systemctl(["is-active", name])
            let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if out == "active" { return true }
            let negative = ["inactive", "failed", "unknown", "not-found"]
            if negative.contains(out) { return false }
            if Self.transitionalStates.contains(out) {
                lastTransitional = out
                if Date() < deadline {
                    usleep(Self.transitionalPollInterval)
                    continue
                }
                throw UnitQueryFailure(message: "\(name) is still in the transitional state "
                    + "\"\(out)\" after \(Int(Self.transitionalWaitSeconds))s — refusing to treat "
                    + "a unit that is starting or stopping as settled; retry once it has settled")
            }
            throw UnitQueryFailure(message: "could not determine whether \(name) is active "
                + "(systemctl is-active exit \(result.exitCode): "
                + "\(out.isEmpty ? "no output" : out)"
                + (lastTransitional.map { "; last transitional state seen: \($0)" } ?? "") + ")")
        }
    }

    func queryEnabled(_ name: String, system: Bool) throws -> Bool {
        let result = system ? systemctlSystem(["is-enabled", name])
                            : systemctl(["is-enabled", name])
        let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "enabled" { return true }
        let negative = ["disabled", "static", "masked", "indirect", "not-found",
                        "linked", "alias"]
        if negative.contains(out) { return false }
        // systemd's answer for a unit with no unit file:
        if out.hasPrefix("Failed to get unit file state") { return false }
        throw UnitQueryFailure(message: "could not determine whether \(name) is enabled "
            + "(systemctl is-enabled exit \(result.exitCode): "
            + "\(out.isEmpty ? "no output" : out))")
    }

    var wakelockConfigured: Bool {
        spec.oldWakelockUnitPath != nil && spec.oldWakelockUnitName != nil
    }

    var unitManaged: Bool { spec.systemctl != nil && spec.unitDir != nil
        && spec.oldUnitName != nil && spec.newUnitName != nil }
    var oldUnitPath: String? {
        guard let dir = spec.unitDir, let name = spec.oldUnitName else { return nil }
        return dir + "/" + name
    }
    var newUnitPath: String? {
        guard let dir = spec.unitDir, let name = spec.newUnitName else { return nil }
        return dir + "/" + name
    }

    // ---------------------------------------------------------- locking

    /// Result of probing a flock: definitely free, definitely held, or
    /// the probe itself failed (anything but "no such file") — callers
    /// must treat `unknown` as a refusal, never as free.
    enum LockProbe: Equatable {
        case free
        case held
        case unknown(errno: Int32)

        var isHeld: Bool { self == .held }
        var problem: String? {
            if case let .unknown(code) = self {
                return "cannot probe the lock: \(String(cString: strerror(code))) (errno \(code))"
            }
            return nil
        }
    }

    /// Probe the flock at `path` with LOCK_NB and release immediately when
    /// it succeeds — never keeps the lock. ENOENT is the one open failure
    /// that means "not held"; every other failure is reported as unknown
    /// with its errno.
    static func lockProbe(_ path: String) -> LockProbe {
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            return errno == ENOENT ? .free : .unknown(errno: errno)
        }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return .free
        }
        return errno == EWOULDBLOCK || errno == EAGAIN ? .held : .unknown(errno: errno)
    }

    /// Strictly "definitely held". Unknown probes are NOT held here —
    /// call sites that must fail closed on an unknown probe use
    /// `lockProbe` directly.
    static func lockHeld(_ path: String) -> Bool {
        lockProbe(path).isHeld
    }

    // ============================================================ fresh

    func fresh() -> MigrationOutcome {
        do {
            // Detection: nothing to do is a clean no-op, with zero writes.
            let existing = spec.rootPairs.filter { fm.fileExists(atPath: $0.old) }
            if existing.isEmpty {
                return .ok(notes: ["nothing to migrate — no old roots present"])
            }
            // Refusals that must not leave a journal behind. ANY existing
            // new root refuses — even one whose old counterpart is absent:
            // proceeding would mix unrelated pre-existing destination data
            // into the migration (Codex Stage 3 round 1 #5).
            for pair in spec.rootPairs where fm.fileExists(atPath: pair.new) {
                return .refused("the new root \(pair.new) already exists. A previous partial "
                    + "attempt would have left a journal (none was found), so this directory was "
                    + "not created by a migration — move it aside, then retry")
            }
            if let newDomain = spec.newPrefsDomain,
               let existingPrefs = Prefs.domains.persistentDomain(forName: newDomain),
               !existingPrefs.isEmpty {
                return .refused("the new preferences domain \(newDomain) already contains data — "
                    + "it was not created by a migration; export/remove it first, then retry")
            }
            let binDir = (spec.oldBinary as NSString).deletingLastPathComponent
            for marker in spec.upgradeMarkers {
                if fm.fileExists(atPath: binDir + "/" + marker) {
                    return .refused("an in-flight upgrade left staged files (\(marker) in \(binDir)) — "
                        + "finish or clean up that upgrade first, then retry")
                }
            }
            guard fm.fileExists(atPath: spec.newBinary) else {
                return .refused("the new binary \(spec.newBinary) is not installed — install it first")
            }
            if let refusal = rewriteTargetSpecialModeProblem() {
                return .refused(refusal)
            }

            // 1. Capture (plan §4.3 step 1).
            try fm.createDirectory(at: stateDirURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: preimagesDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: parkedDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try capture(existingRoots: existing)
            Self.crashPoint("after-prepared")

            // 2. Stop what we manage; refuse an unmanaged holder.
            if let refusal = try stopManagedAndCheckLock() {
                let restartProblem = restoreServiceAfterRefusal()
                cleanupJournalArea()
                if let restartProblem {
                    return .refused(refusal + ". ALSO: " + restartProblem)
                }
                return .refused(refusal)
            }

            // 3–5. Move, fix up, commit.
            try moveRoots()
            try runFixups()
            Self.crashPoint("after-fixups")
            try commit()
            return .ok(notes: notes + journal.warnings.map { "⚠ " + $0 })
        } catch let error as EngineError {
            return error.outcome
        } catch {
            // Unexpected failure mid-transaction: state decides what recovery
            // can do; roll back now when we are still before committing.
            return handleMidTransactionFailure("unexpected error: \(error.localizedDescription)")
        }
    }

    /// Assets the fixups REWRITE through a staged replacement (persona
    /// secrets, the agentmail wrapper, reminder/watcher records, toolchain
    /// wrappers and LibreOffice rc files) cannot carry setuid, setgid or
    /// sticky bits into the replacement meaningfully — the kernel may clear
    /// them on the staged file and rollback would then not be exact. Such
    /// an asset is refused BEFORE anything moves, by name; everything the
    /// engine merely renames keeps every bit untouched and is not checked.
    /// Evaluated against the OLD roots (pre-move), with the same predicates
    /// the fixups apply, so an asset the fixups would leave alone does not
    /// block the migration.
    func rewriteTargetSpecialModeProblem() -> String? {
        var candidates: [String] = []
        let secrets = spec.oldConfigRoot + "/secrets.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: secrets)),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           object["assistant_name"] as? String == spec.personaOldName {
            candidates.append(secrets)
        }
        let agentmail = spec.wrapperBinDir + "/" + spec.agentmailName
        if let text = try? String(contentsOfFile: agentmail, encoding: .utf8),
           text.contains("__agentmail-key"), text.contains(spec.oldBinary) {
            candidates.append(agentmail)
        }
        var records = [spec.oldDataRoot + "/reminders.json"]
        let stateDir = spec.oldDataRoot + "/reminder-scripts/state"
        if let entries = try? fm.contentsOfDirectory(atPath: stateDir) {
            records += entries.sorted().filter { $0.hasSuffix(".json") }.map { stateDir + "/" + $0 }
        }
        var prefixes = [spec.oldDataRoot, spec.oldConfigRoot]
        if let landing = spec.oldLandingZone { prefixes.append(landing) }
        for path in records {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if prefixes.contains(where: { text.contains($0) }) { candidates.append(path) }
        }
        if let entries = try? fm.contentsOfDirectory(atPath: spec.wrapperBinDir) {
            for name in entries.sorted() {
                let path = spec.wrapperBinDir + "/" + name
                guard path != agentmail,
                      let text = try? String(contentsOfFile: path, encoding: .utf8),
                      text.contains(spec.toolchainMarker), text.contains(spec.oldDataRoot) else { continue }
                candidates.append(path)
            }
        }
        let loProgram = spec.oldDataRoot + "/toolchain/prefix/usr/lib/libreoffice/program"
        if let entries = try? fm.contentsOfDirectory(atPath: loProgram) {
            for name in entries.sorted() where name.hasSuffix("rc") {
                let path = loProgram + "/" + name
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      text.contains(spec.oldDataRoot) else { continue }
                candidates.append(path)
            }
        }
        for path in candidates {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let special = Int(st.st_mode) & 0o7000
            if special != 0 {
                let bits = [(0o4000, "setuid"), (0o2000, "setgid"), (0o1000, "sticky")]
                    .filter { special & $0.0 != 0 }.map { $0.1 }.joined(separator: "+")
                return "\(path) carries the \(bits) permission bit(s) and the migration would have to "
                    + "rewrite it (mode \(String(st.st_mode & 0o7777, radix: 8))) — a staged rewrite "
                    + "cannot preserve those bits exactly. Clear them (chmod \(bits.contains("setuid") ? "u-s" : bits.contains("setgid") ? "g-s" : "-t") "
                    + "\(path)) or move the file aside, then retry; nothing was changed"
            }
        }
        return nil
    }

    func capture(existingRoots: [(old: String, new: String)]) throws {
        // Capture flags come from throwing queries: if systemctl itself is
        // broken, the migration must refuse now — not record fiction that
        // commit and rollback would later "restore".
        do {
            if unitManaged, let unitPath = oldUnitPath, let unitName = spec.oldUnitName {
                let installed = fm.fileExists(atPath: unitPath)
                journal.oldService = MigrationJournal.UnitCapture(
                    name: unitName, unitPath: unitPath,
                    installed: installed,
                    enabled: installed ? try queryEnabled(unitName, system: false) : false,
                    active: installed ? try queryActive(unitName, system: false) : false)
            }
            if wakelockConfigured, let unitPath = spec.oldWakelockUnitPath,
               let unitName = spec.oldWakelockUnitName {
                let installed = fm.fileExists(atPath: unitPath)
                journal.wakelockService = MigrationJournal.UnitCapture(
                    name: unitName, unitPath: unitPath,
                    installed: installed,
                    enabled: installed ? try queryEnabled(unitName, system: true) : false,
                    active: installed ? try queryActive(unitName, system: true) : false)
            }
        } catch let failure as UnitQueryFailure {
            cleanupJournalArea()
            throw EngineError(outcome: .refused(
                "cannot capture the service state: \(failure.message) — fix systemctl "
                + "access first; nothing was changed"))
        }
        if let wakelock = journal.wakelockService,
           wakelock.installed, !spec.wakelockPrivileged {
            journal.warnings.append(
                "the keep-awake unit \(wakelock.name) is installed but this process has no "
                + "privileges to migrate system units — its captured state is recorded; "
                + "swap it via the companion app (or manually) after migration")
        }
        var st = stat()
        if lstat(spec.oldBinary, &st) == 0 {
            journal.oldBinaryExists = true
            if (st.st_mode & S_IFMT) == S_IFLNK {
                journal.oldBinaryIsSymlink = true
                journal.oldBinarySymlinkTarget =
                    try? fm.destinationOfSymbolicLink(atPath: spec.oldBinary)
            }
            journal.oldBinarySHA256 = Self.sha256(ofFile: URL(fileURLWithPath: spec.oldBinary))
        }
        journal.roots = spec.rootPairs.map { pair in
            MigrationJournal.RootMove(old: pair.old, new: pair.new,
                                      existed: fm.fileExists(atPath: pair.old),
                                      moved: false)
        }
        try persistJournal()
        log("captured pre-state (journal at \(journalURL.path))")
    }

    /// Returns a refusal reason, or nil to proceed. Only the MANAGED unit is
    /// ever stopped; an unmanaged process holding the instance lock is the
    /// user's to stop (plan §4.3 step 2).
    func stopManagedAndCheckLock() throws -> String? {
        if let service = journal.oldService, service.installed, service.active {
            let stop = systemctl(["stop", service.name])
            guard stop.exitCode == 0 else {
                return "could not stop the managed service \(service.name): \(stop.tail)"
            }
            journal.stoppedOldService = true
            try persistJournal()
            log("stopped \(service.name)")
        }
        let lockPath = spec.oldDataRoot + "/instance.lock"
        switch Self.lockProbe(lockPath) {
        case .held:
            return "an unmanaged process is still running against \(spec.oldDataRoot) "
                + "(instance.lock is held). Quit it (a terminal chat session, or a manually "
                + "started daemon), then retry"
        case .unknown:
            return "cannot tell whether a process is running against \(spec.oldDataRoot): "
                + "\(Self.lockProbe(lockPath).problem ?? "lock probe failed") at \(lockPath) — "
                + "refusing to proceed on a guess"
        case .free:
            return nil
        }
    }

    /// Restart the managed service we stopped, VERIFIED. Returns nil on
    /// success (or nothing to do); otherwise a one-line detail the caller
    /// must surface — a refusal that silently leaves the daemon down would
    /// be a lie (Codex Stage 3 round 2 #1).
    func restoreServiceAfterRefusal() -> String? {
        guard journal.stoppedOldService, let service = journal.oldService,
              service.active else { return nil }
        let start = systemctl(["start", service.name])
        let activeNow = (try? queryActive(service.name, system: false)) ?? false
        guard start.exitCode == 0, activeNow else {
            return "the managed service \(service.name) was stopped for the migration and "
                + "could NOT be restarted (exit \(start.exitCode): \(start.tail)) — start it "
                + "manually: systemctl --user start \(service.name)"
        }
        log("restarted \(service.name) after refusal")
        return nil
    }

    /// Refusal before anything moved: the journal area must not linger — a
    /// leftover journal would make the next run enter recovery for a
    /// migration that never started.
    func cleanupJournalArea() {
        try? fm.removeItem(at: stateDirURL)
    }

    func moveRoots() throws {
        var firstMoveDone = false
        for index in journal.roots.indices where journal.roots[index].existed {
            let root = journal.roots[index]
            guard !root.moved else { continue }
            let parent = (root.new as NSString).deletingLastPathComponent
            let oldParent = (root.old as NSString).deletingLastPathComponent
            // Disk reconciliation for recovery re-entry: a crash between the
            // rename and the journal write leaves moved=false with the move
            // already done on disk. The rename may have happened but its
            // barriers may NOT have (the crash could sit between the two) —
            // the barriers are repeated before the journal records
            // completion, never skipped (Codex Stage 3 round 3 #2).
            if !fm.fileExists(atPath: root.old), fm.fileExists(atPath: root.new) {
                for dir in [parent, oldParent] {
                    if let why = Self.fsyncPath(URL(fileURLWithPath: dir)) {
                        throw EngineError(outcome: handleMidTransactionFailure(
                            "root move of \(root.old) (found already done) is not durable: \(why)"))
                    }
                }
                journal.roots[index].moved = true
                try persistJournal()
                log("reconciled \(root.old) → \(root.new) (already moved on disk)")
                continue
            }
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            guard rename(root.old, root.new) == 0 else {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "could not move \(root.old) → \(root.new): \(String(cString: strerror(errno)))"))
            }
            Self.crashPoint("after-root-rename")
            for dir in [parent, oldParent] {
                if let why = Self.fsyncPath(URL(fileURLWithPath: dir)) {
                    throw EngineError(outcome: handleMidTransactionFailure(
                        "root move of \(root.old) is not durable: \(why)"))
                }
            }
            journal.roots[index].moved = true
            try persistJournal()
            log("moved \(root.old) → \(root.new)")
            if firstMoveDone == false {
                firstMoveDone = true
                Self.crashPoint("between-root-moves")
            }
        }
        try setState("moved")
        Self.crashPoint("after-moved")
    }

    // =========================================================== fixups

    func newPreimageID() -> String {
        String(format: "pre-%04d", journal.preimages.count)
    }

    /// Record a file's typed preimage BEFORE modifying it: bytes copied into
    /// preimages/ and fsynced, then the manifest entry persisted. Idempotent
    /// per path — the first recorded preimage (the true original) wins.
    func recordFilePreimage(_ path: String) throws {
        if journal.preimages.contains(where: { $0.path == path && $0.type != "absent" }) {
            return
        }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw EngineError(outcome: handleMidTransactionFailure(
                "cannot stat \(path) for its preimage"))
        }
        let id = newPreimageID()
        if (st.st_mode & S_IFMT) == S_IFLNK {
            let target = try fm.destinationOfSymbolicLink(atPath: path)
            journal.preimages.append(MigrationJournal.Preimage(
                id: id, type: "symlink", path: path, sha256: nil,
                mode: nil, uid: Int(st.st_uid), gid: Int(st.st_gid), target: target))
        } else {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "cannot read \(path) for its preimage"))
            }
            let copy = preimagesDir.appendingPathComponent(id)
            if let why = Self.writeDurable(data, to: copy, mode: 0o600) {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "cannot store the preimage of \(path): \(why)"))
            }
            journal.preimages.append(MigrationJournal.Preimage(
                id: id, type: "file", path: path, sha256: Self.sha256(of: data),
                mode: Int(st.st_mode & 0o7777), uid: Int(st.st_uid),
                gid: Int(st.st_gid), target: nil))
        }
        try persistJournal()
        Self.crashPoint("after-preimage-record")
    }

    /// Record a path the migration is ABOUT to create: rollback deletes it.
    func recordAbsent(_ path: String) throws {
        if journal.preimages.contains(where: { $0.path == path }) { return }
        journal.preimages.append(MigrationJournal.Preimage(
            id: newPreimageID(), type: "absent", path: path, sha256: nil,
            mode: nil, uid: nil, gid: nil, target: nil))
        try persistJournal()
    }

    /// Fixup modification: staged copy with the target mode applied to the
    /// temp file BEFORE the atomic rename — content and permissions become
    /// visible together, durably. The target is re-`lstat`ed immediately
    /// before the staged rename and compared with what the journal
    /// recorded for it at capture: a recorded file must still be a regular
    /// file, a recorded symlink a symlink (or the regular file a previous
    /// attempt of this same write left), a recorded `absent` path absent
    /// (or that regular file). Anything else — a directory, a device, a
    /// planted symlink at a path we are about to create — refuses. Same-uid
    /// check-then-act only; the window between this lstat and rename(2)
    /// is not closed (no O_NOFOLLOW rework), and rename over a directory
    /// fails on its own.
    func stagedWrite(_ data: Data, to path: String, mode: Int?) throws {
        let recorded = journal.preimages.first { $0.path == path && $0.type != "absent" }
            ?? journal.preimages.first { $0.path == path }
        guard let recorded else {
            throw EngineError(outcome: handleMidTransactionFailure(
                "internal: staged write to \(path) without a recorded preimage"))
        }
        let now = Self.entryKind(path)
        let allowed: Set<String?>
        switch recorded.type {
        case "file": allowed = ["file"]
        case "symlink": allowed = ["symlink", "file"]
        default: allowed = [nil, "file"]
        }
        guard allowed.contains(now) else {
            throw EngineError(outcome: handleMidTransactionFailure(
                "\(path) changed kind since it was captured (recorded \(recorded.type), "
                + "now \(now ?? "absent")) — refusing to write over it"))
        }
        if let why = Self.writeDurable(data, to: URL(fileURLWithPath: path), mode: mode) {
            throw EngineError(outcome: handleMidTransactionFailure(
                "could not write \(path): \(why)"))
        }
    }

    func runFixups() throws {
        try setState("fixups")
        try fixup("persona") { try self.fixupPersona() }
        Self.crashPoint("mid-fixups")
        try fixup("persona-marker") { try self.fixupPersonaMarker() }
        try fixup("agentmail-wrapper") { try self.fixupAgentmailWrapper() }
        try fixup("reminders-rebase") { try self.fixupRemindersRebase() }
        try fixup("toolchain-rebase") { try self.fixupToolchainRebase() }
        try fixup("preferences") { try self.fixupPreferences() }
    }

    func fixup(_ name: String, _ body: () throws -> Void) throws {
        guard !journal.fixupsDone.contains(name) else { return }
        try body()
        journal.fixupsDone.append(name)
        try persistJournal()
    }

    /// Plan §4.5.1: rewrite the stored assistant name ONLY when it is
    /// exactly personaOldName; any other value — custom names, deliberate
    /// case variants — is preserved verbatim.
    func fixupPersona() throws {
        let path = spec.newConfigRoot + "/secrets.json"
        guard fm.fileExists(atPath: path) else {
            notes.append("no secrets.json — persona fixup skipped")
            return
        }
        let mode = Self.fileMode(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EngineError(outcome: handleMidTransactionFailure(
                "secrets.json is not readable JSON — refusing to modify it"))
        }
        guard let stored = object["assistant_name"] as? String,
              stored == spec.personaOldName else { return }
        try recordFilePreimage(path)
        object["assistant_name"] = spec.personaNewName
        let out = try JSONSerialization.data(withJSONObject: object,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try stagedWrite(out, to: path, mode: mode)
        notes.append("assistant name \(spec.personaOldName) → \(spec.personaNewName)")
    }

    /// Plan §4.5.6: the durable persona-migration marker lives in the new
    /// data root, OUTSIDE the journal, and survives journal deletion.
    func fixupPersonaMarker() throws {
        let path = spec.newDataRoot + "/" + spec.markerName
        guard !fm.fileExists(atPath: path) else { return }
        var prior: String? = nil
        if let data = try? Data(contentsOf: URL(fileURLWithPath: spec.newConfigRoot + "/secrets.json")),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            prior = object["assistant_name"] as? String
        }
        try recordAbsent(path)
        let marker: [String: Any] = [
            "migratedAt": ISO8601DateFormatter().string(from: Date()),
            "priorName": spec.personaOldName,
            "storedNameAtMigration": prior ?? spec.personaOldName,
        ]
        let data = try JSONSerialization.data(withJSONObject: marker,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try stagedWrite(data, to: path, mode: 0o600)
    }

    /// Plan §4.5.2: the broker wrapper embeds the absolute old binary path.
    /// Regenerated (path-rebased) only when it is OURS — identified by the
    /// hidden broker subcommand it calls.
    func fixupAgentmailWrapper() throws {
        let path = spec.wrapperBinDir + "/" + spec.agentmailName
        guard fm.fileExists(atPath: path),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              text.contains("__agentmail-key"),
              text.contains(spec.oldBinary) else { return }
        let mode = Self.fileMode(path)
        try recordFilePreimage(path)
        let rebased = text.replacingOccurrences(of: spec.oldBinary, with: spec.newBinary)
        try stagedWrite(Data(rebased.utf8), to: path, mode: mode)
        notes.append("agentmail wrapper re-pointed at \(spec.newBinary)")
    }

    /// Plan §4.5.7: reminder rows and scripted-watcher STATE records embed
    /// absolute old-root paths — rebased as JSON string values. Script FILE
    /// CONTENTS are user-owned, hash-tracked material and are never edited.
    func fixupRemindersRebase() throws {
        var targets = [spec.newDataRoot + "/reminders.json"]
        let stateDir = spec.newDataRoot + "/reminder-scripts/state"
        if let entries = try? fm.contentsOfDirectory(atPath: stateDir) {
            targets += entries.sorted().filter { $0.hasSuffix(".json") }
                .map { stateDir + "/" + $0 }
        }
        for path in targets where fm.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                journal.warnings.append("\(path) is not parseable JSON — left unchanged")
                try persistJournal()
                continue
            }
            let rebased = rebaseJSONValue(object)
            let out = try JSONSerialization.data(withJSONObject: rebased.value,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            guard rebased.changed else { continue }
            let mode = Self.fileMode(path)
            try recordFilePreimage(path)
            try stagedWrite(out, to: path, mode: mode)
        }
    }

    /// Recursively rebase absolute old-root prefixes inside JSON string
    /// values (metadata only — never file contents).
    func rebaseJSONValue(_ value: Any) -> (value: Any, changed: Bool) {
        var pairs = [(spec.oldDataRoot, spec.newDataRoot),
                     (spec.oldConfigRoot, spec.newConfigRoot)]
        if let ol = spec.oldLandingZone, let nl = spec.newLandingZone {
            pairs.append((ol, nl))
        }
        if let text = value as? String {
            var out = text
            for (old, new) in pairs {
                if out == old || out.hasPrefix(old + "/") || out.contains(old + "/") {
                    out = out.replacingOccurrences(of: old + "/", with: new + "/")
                    if out == old { out = new }
                }
                if out == old { out = new }
            }
            return (out, out != text)
        }
        if let array = value as? [Any] {
            var changed = false
            let mapped = array.map { element -> Any in
                let r = rebaseJSONValue(element)
                if r.changed { changed = true }
                return r.value
            }
            return (mapped, changed)
        }
        if let dict = value as? [String: Any] {
            var changed = false
            var mapped: [String: Any] = [:]
            for (key, element) in dict {
                let r = rebaseJSONValue(element)
                if r.changed { changed = true }
                mapped[key] = r.value
            }
            return (mapped, changed)
        }
        return (value, false)
    }

    /// Plan §4.5.9: toolchain wrappers on PATH and LibreOffice's rc files
    /// inside the moved prefix embed the absolute old data root. Both are
    /// path-rebased with preimages (the plan's "toolchain configuration
    /// files"); wrapper MARKER migration stays with the toolchain code.
    func fixupToolchainRebase() throws {
        let marker = spec.toolchainMarker
        if let entries = try? fm.contentsOfDirectory(atPath: spec.wrapperBinDir) {
            for name in entries.sorted() {
                let path = spec.wrapperBinDir + "/" + name
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      text.contains(marker), text.contains(spec.oldDataRoot) else { continue }
                let mode = Self.fileMode(path)
                try recordFilePreimage(path)
                let rebased = text.replacingOccurrences(
                    of: spec.oldDataRoot, with: spec.newDataRoot)
                try stagedWrite(Data(rebased.utf8), to: path, mode: mode)
            }
        }
        let loProgram = spec.newDataRoot + "/toolchain/prefix/usr/lib/libreoffice/program"
        if let entries = try? fm.contentsOfDirectory(atPath: loProgram) {
            for name in entries.sorted() where name.hasSuffix("rc") {
                let path = loProgram + "/" + name
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      text.contains(spec.oldDataRoot) else { continue }
                let mode = Self.fileMode(path)
                try recordFilePreimage(path)
                let rebased = text.replacingOccurrences(
                    of: spec.oldDataRoot, with: spec.newDataRoot)
                try stagedWrite(Data(rebased.utf8), to: path, mode: mode)
            }
        }
    }

    /// Plan §4.5.8: copy the complete old UserDefaults domain to the new
    /// domain through the persistent-domain API (works identically through
    /// cfprefsd on macOS and corelibs-foundation's file store on Linux —
    /// deliberately no direct plist-file paths, so cache coherence is the
    /// framework's problem, not ours). The exported old domain is the
    /// preimage; the created new domain is rollback-deleted. The OLD domain
    /// stays until retirement (§4.3.5c).
    func fixupPreferences() throws {
        guard let oldDomain = spec.oldPrefsDomain,
              let newDomain = spec.newPrefsDomain else { return }
        let defaults = Prefs.domains
        guard let contents = defaults.persistentDomain(forName: oldDomain),
              !contents.isEmpty else {
            notes.append("no \(oldDomain) preferences domain — nothing to copy")
            return
        }
        // Export = preimage (plan: "the exported original plist stored as
        // the preimage") — consumed by the park-restoring rollback after
        // retirement removes the old domain.
        let export = try PropertyListSerialization.data(
            fromPropertyList: contents, format: .xml, options: 0)
        let id = newPreimageID()
        if let why = Self.writeDurable(export, to: preimagesDir.appendingPathComponent(id),
                                       mode: 0o600) {
            throw EngineError(outcome: handleMidTransactionFailure(
                "cannot export the \(oldDomain) preferences domain: \(why)"))
        }
        journal.preimages.append(MigrationJournal.Preimage(
            id: id, type: "prefs-old-domain", path: oldDomain,
            sha256: Self.sha256(of: export), mode: nil, uid: nil, gid: nil, target: nil))
        journal.preimages.append(MigrationJournal.Preimage(
            id: newPreimageID(), type: "prefs-new-domain", path: newDomain,
            sha256: nil, mode: nil, uid: nil, gid: nil, target: nil))
        try persistJournal()
        defaults.setPersistentDomain(contents, forName: newDomain)
        guard defaults.synchronize(), Self.faultPoint != "prefs-sync" else {
            throw EngineError(outcome: handleMidTransactionFailure(
                "the copied \(newDomain) preferences domain could not be persisted "
                + "(synchronize failed)"))
        }
        notes.append("preferences domain \(oldDomain) copied to \(newDomain)")
    }

    // =========================================================== commit

    func commit() throws {
        // 5·0. Durable "the new install may serve" marker BEFORE anything
        // starts or probes it: the daemon systemd launches in 5a and the
        // `__migrate-probe` in 5b both run the startup gate, which admits a
        // live journal only on this flag (+ our held lock, + no old root).
        // Without it the daemon exits 2 on its own journal, systemd loops
        // it, and 5b waits for an instance lock nobody takes → rollback —
        // exactly what 0.2.0 did on every systemd-managed install.
        if journal.newInstallReady != true {
            journal.newInstallReady = true
            try persistJournal()
        }
        Self.crashPoint("after-new-install-ready")

        // 5a. Recreate the captured service topology on the new identity —
        // installed/enabled/active as three independent flags.
        if let service = journal.oldService, service.installed, unitManaged,
           let newUnitPath, let newUnitName = spec.newUnitName {
            guard let unitText = spec.newUnitText else {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "the old service is installed but the spec provides no new unit text"))
            }
            try recordAbsent(newUnitPath)
            try stagedWrite(Data(unitText.utf8), to: newUnitPath, mode: 0o644)
            journal.newUnitInstalled = true
            try persistJournal()
            let reload = systemctl(["daemon-reload"])
            guard reload.exitCode == 0 else {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "daemon-reload failed after installing \(newUnitName): \(reload.tail)"))
            }
            if service.enabled {
                let enable = systemctl(["enable", newUnitName])
                guard enable.exitCode == 0 else {
                    throw EngineError(outcome: handleMidTransactionFailure(
                        "could not enable \(newUnitName): \(enable.tail)"))
                }
                journal.newUnitEnabled = true
                try persistJournal()
            }
            if service.active {
                let start = systemctl(["start", newUnitName])
                guard start.exitCode == 0 else {
                    throw EngineError(outcome: handleMidTransactionFailure(
                        "could not start \(newUnitName): \(start.tail)"))
                }
                journal.startedNewUnit = true
                try persistJournal()
                log("started \(newUnitName)")
            }
        }

        // 5a (continued): the keep-awake unit, transactionally, where
        // privileges allow (plan §4.3.5a). Both old wakelock and new run
        // side by side until retirement — two holders of one kernel
        // wakelock are harmless, and the phone must never sleep mid-window.
        if let wakelock = journal.wakelockService, wakelock.installed,
           spec.wakelockPrivileged,
           let newPath = spec.newWakelockUnitPath,
           let newName = spec.newWakelockUnitName {
            guard let unitText = spec.newWakelockUnitText else {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "the old keep-awake unit is installed but the spec provides no new unit text"))
            }
            try recordAbsent(newPath)
            try stagedWrite(Data(unitText.utf8), to: newPath, mode: 0o644)
            journal.newWakelockInstalled = true
            try persistJournal()
            let reload = systemctlSystem(["daemon-reload"])
            guard reload.exitCode == 0 else {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "system daemon-reload failed after installing \(newName): \(reload.tail)"))
            }
            if wakelock.enabled {
                let enable = systemctlSystem(["enable", newName])
                guard enable.exitCode == 0 else {
                    throw EngineError(outcome: handleMidTransactionFailure(
                        "could not enable \(newName): \(enable.tail)"))
                }
                journal.newWakelockEnabled = true
                try persistJournal()
            }
            if wakelock.active {
                let start = systemctlSystem(["start", newName])
                guard start.exitCode == 0 else {
                    throw EngineError(outcome: handleMidTransactionFailure(
                        "could not start \(newName): \(start.tail)"))
                }
                journal.startedNewWakelock = true
                try persistJournal()
            }
        }

        // 5b. Verify the new install actually works BEFORE retiring
        // anything: bounded health probe, plus the new instance lock when a
        // daemon was started.
        let probe = Self.runBounded(spec.healthProbe, timeout: spec.probeTimeout,
                                    outputDir: stateDirURL)
        guard probe.exitCode == 0 else {
            throw EngineError(outcome: handleMidTransactionFailure(
                "the new install failed its health probe (exit \(probe.exitCode)): \(probe.tail)"))
        }
        if journal.startedNewUnit {
            let lockPath = spec.newDataRoot + "/instance.lock"
            let deadline = Date().addingTimeInterval(spec.probeTimeout)
            var probe = Self.lockProbe(lockPath)
            while probe == .free && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
                probe = Self.lockProbe(lockPath)
            }
            if let problem = probe.problem {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "cannot verify that the started daemon holds \(lockPath): \(problem)"))
            }
            guard probe.isHeld else {
                throw EngineError(outcome: handleMidTransactionFailure(
                    "the started daemon never acquired \(lockPath) — it is not actually running"))
            }
        }
        log("new install verified healthy")

        // 5c. The durable committing marker, then retirement by PARKING —
        // nothing old is deleted until post-`done` cleanup (plan v6).
        try setState("committing")
        Self.crashPoint("after-committing-marker")
        try retire()

        // 5d/5e. Committed, verified, cleaned.
        try setState("committed")
        Self.crashPoint("after-committed")
        try verifyAndCleanup()
    }

    /// Move one filesystem object into parked/ with its identity recorded.
    /// Resumable: the record is persisted BEFORE the move, so recovery can
    /// tell "recorded + parked present" (done) from "recorded + original
    /// still present" (redo the move).
    func park(_ originalPath: String, id: String) throws {
        if let existing = journal.parked.first(where: { $0.id == id }) {
            if fm.fileExists(atPath: parkedDir.appendingPathComponent(id).path)
                || !fm.fileExists(atPath: existing.originalPath) {
                return  // already parked (or original legitimately gone)
            }
        } else {
            var st = stat()
            guard lstat(originalPath, &st) == 0 else { return }
            let kind: String
            var hash: String? = nil
            var target: String? = nil
            if (st.st_mode & S_IFMT) == S_IFLNK {
                kind = "symlink"
                target = try? fm.destinationOfSymbolicLink(atPath: originalPath)
            } else if (st.st_mode & S_IFMT) == S_IFDIR {
                kind = "directory"
                hash = Self.treeHash(of: URL(fileURLWithPath: originalPath))
            } else {
                kind = "file"
                hash = Self.sha256(ofFile: URL(fileURLWithPath: originalPath))
            }
            journal.parked.append(MigrationJournal.Parked(
                id: id, originalPath: originalPath, kind: kind, sha256: hash,
                mode: Int(st.st_mode & 0o7777), uid: Int(st.st_uid),
                gid: Int(st.st_gid), target: target))
            try persistJournal()
            Self.crashPoint("after-park-record")
            Self.crashPoint("after-park-record-\(id)")
        }
        // Immediately before the move: the object at the original path must
        // still be the kind the record describes (a retried park after a
        // crash sees the record first, then the disk).
        if let record = journal.parked.first(where: { $0.id == id }),
           let now = Self.entryKind(originalPath), now != record.kind {
            throw EngineError(outcome: .failed(
                "\(originalPath) changed kind since it was recorded for parking (recorded "
                + "\(record.kind), now \(now)) — refusing to park it; the journal at "
                + "\(journalURL.path) is preserved for inspection"))
        }
        let dest = parkedDir.appendingPathComponent(id)
        try? fm.removeItem(at: dest)
        guard rename(originalPath, dest.path) == 0 else {
            throw EngineError(outcome: .failed(
                "could not park \(originalPath): \(String(cString: strerror(errno))) — "
                + "the journal is at \(journalURL.path); re-run `\(spec.recoveryHint)` to resume"))
        }
        for dir in [parkedDir,
                    URL(fileURLWithPath: (originalPath as NSString).deletingLastPathComponent)] {
            if let why = Self.fsyncPath(dir) {
                throw EngineError(outcome: .failed(
                    "parking of \(originalPath) is not durable: \(why) — the journal is "
                    + "preserved; re-run `\(spec.recoveryHint)` to resume"))
            }
        }
    }

    /// Retirement sub-steps, each idempotent for forward recovery.
    func retire() throws {
        // Old unit: disable (reversible from captured flags), park the unit
        // file, reload — each checked; a silently failed retirement would
        // leave two services owning one bot/conversation.
        if let service = journal.oldService, service.installed, unitManaged {
            if service.enabled, fm.fileExists(atPath: service.unitPath) {
                try systemctlChecked(["disable", service.name], context: "retirement")
            }
            if fm.fileExists(atPath: service.unitPath) {
                try park(service.unitPath, id: "unit")
                try systemctlChecked(["daemon-reload"], context: "retirement")
            }
        }
        Self.crashPoint("after-unit-retirement")

        // Old keep-awake unit (privileged only): stop, disable, park, reload.
        if let wakelock = journal.wakelockService, wakelock.installed,
           spec.wakelockPrivileged {
            if fm.fileExists(atPath: wakelock.unitPath) {
                if wakelock.active {
                    try systemctlChecked(["stop", wakelock.name], system: true,
                                         context: "retirement")
                }
                if wakelock.enabled {
                    try systemctlChecked(["disable", wakelock.name], system: true,
                                         context: "retirement")
                }
                try park(wakelock.unitPath, id: "wakelock-unit")
                try systemctlChecked(["daemon-reload"], system: true,
                                     context: "retirement")
            }
        }
        Self.crashPoint("after-wakelock-retirement")

        // Old binary: park ONLY a verified installation (plan §4.6) — the
        // content hash must match the capture. Anything else stays untouched
        // and the migration warns instead of replacing it.
        var binaryParked = journal.parked.contains { $0.id == "binary" }
        if !binaryParked, journal.oldBinaryExists, !journal.binaryParkSkipped {
            var st = stat()
            if lstat(spec.oldBinary, &st) == 0 {
                let isLink = (st.st_mode & S_IFMT) == S_IFLNK
                let linkTarget = isLink
                    ? (try? fm.destinationOfSymbolicLink(atPath: spec.oldBinary)) : nil
                if isLink && linkTarget == spec.newBinary {
                    // Already this migration's own compat symlink (a prior
                    // completed attempt) — nothing to park.
                    journal.symlinkCreated = true
                    try persistJournal()
                } else if Self.sha256(ofFile: URL(fileURLWithPath: spec.oldBinary))
                            == journal.oldBinarySHA256 {
                    try park(spec.oldBinary, id: "binary")
                    binaryParked = true
                } else {
                    journal.binaryParkSkipped = true
                    journal.warnings.append(
                        "\(spec.oldBinary) does not match the binary captured at the start of the "
                        + "migration — it was left untouched and NO compatibility symlink was "
                        + "created. Remove or rename it manually if it should not be there")
                    try persistJournal()
                }
            }
        }
        Self.crashPoint("after-binary-park")

        // Old resource bundle.
        if let bundle = spec.oldBundle, fm.fileExists(atPath: bundle) {
            try park(bundle, id: "bundle")
        }
        Self.crashPoint("after-bundle-park")

        // Old preferences domain — removed here (retirement), NOT during
        // fixups; the exported preimage is kept until cleanup so a
        // park-restoring rollback can re-import it (plan §4.5.8).
        if let oldDomain = spec.oldPrefsDomain,
           journal.preimages.contains(where: { $0.type == "prefs-old-domain" }) {
            let defaults = Prefs.domains
            defaults.removePersistentDomain(forName: oldDomain)
            guard defaults.synchronize() else {
                throw EngineError(outcome: .failed(
                    "removal of the old \(oldDomain) preferences domain could not be "
                    + "persisted (synchronize failed) — the journal is preserved; re-run "
                    + "`\(spec.recoveryHint)` to resume"))
            }
        }

        // Compat symlink (plan §4.6): only over the just-parked verified
        // binary, never over a foreign file.
        if binaryParked, !journal.binaryParkSkipped, !journal.symlinkCreated {
            try recordAbsent(spec.oldBinary)
            try? fm.removeItem(atPath: spec.oldBinary)
            try fm.createSymbolicLink(atPath: spec.oldBinary,
                                      withDestinationPath: spec.newBinary)
            if let why = Self.fsyncPath(URL(fileURLWithPath:
                (spec.oldBinary as NSString).deletingLastPathComponent)) {
                throw EngineError(outcome: .failed(
                    "the compatibility symlink is not durable: \(why) — the journal is "
                    + "preserved; re-run `\(spec.recoveryHint)` to resume"))
            }
            journal.symlinkCreated = true
            try persistJournal()
            log("compatibility symlink \(spec.oldBinary) → \(spec.newBinary)")
        }
        Self.crashPoint("after-symlink")
    }

    /// 5e + recovery at committed/done: verification ALWAYS reruns before
    /// any cleanup; a failure reports and holds everything in place.
    func verifyAndCleanup() throws {
        Self.crashPoint("during-post-verify")
        var problems: [String] = []
        for root in journal.roots where root.moved {
            if !fm.fileExists(atPath: root.new) {
                problems.append("moved root missing: \(root.new)")
            }
        }
        let probe = Self.runBounded(spec.healthProbe, timeout: spec.probeTimeout,
                                    outputDir: stateDirURL)
        if probe.exitCode != 0 {
            problems.append("health probe failed (exit \(probe.exitCode)): \(probe.tail)")
        }
        if journal.startedNewUnit {
            let probe = Self.lockProbe(spec.newDataRoot + "/instance.lock")
            if let problem = probe.problem {
                problems.append("the new daemon's instance lock could not be probed: \(problem)")
            } else if !probe.isHeld {
                problems.append("the new daemon no longer holds the instance lock")
            }
        }
        if journal.symlinkCreated {
            let target = try? fm.destinationOfSymbolicLink(atPath: spec.oldBinary)
            if target != spec.newBinary {
                problems.append("compat symlink does not resolve to \(spec.newBinary)")
            }
        }
        func probedActive(_ name: String, system: Bool) -> Bool? {
            do { return try queryActive(name, system: system) } catch {
                problems.append((error as? UnitQueryFailure)?.message
                    ?? "unit query failed for \(name)")
                return nil
            }
        }
        if let service = journal.oldService, service.installed {
            if fm.fileExists(atPath: service.unitPath) {
                problems.append("old unit file still present: \(service.unitPath)")
            }
            if unitManaged, probedActive(service.name, system: false) == true {
                problems.append("the old unit \(service.name) is still active")
            }
        }
        if journal.startedNewWakelock, let name = spec.newWakelockUnitName,
           probedActive(name, system: true) == false {
            problems.append("the new keep-awake unit \(name) is not active")
        }
        if let wakelock = journal.wakelockService, wakelock.installed,
           spec.wakelockPrivileged {
            if fm.fileExists(atPath: wakelock.unitPath) {
                problems.append("old keep-awake unit file still present: \(wakelock.unitPath)")
            }
            if probedActive(wakelock.name, system: true) == true {
                problems.append("the old keep-awake unit \(wakelock.name) is still active")
            }
        }
        guard problems.isEmpty else {
            throw EngineError(outcome: .failed(
                "post-commit verification failed: " + problems.joined(separator: "; ")
                + " — NOTHING was cleaned up; parked assets, preimages and the journal are intact "
                + "at \(spec.stateDir). Re-run `\(spec.recoveryHint)` after addressing this"))
        }
        try setState("done")
        // Cleanup: parked assets and preimages first, the journal last —
        // its deletion is what marks the migration finished. A failed
        // deletion is REPORTED and leaves the journal so the next run
        // re-verifies and retries; suppressing it would strand parked
        // assets invisibly (Codex Stage 3 round 2 #4).
        for dir in [parkedDir, preimagesDir] where fm.fileExists(atPath: dir.path) {
            do { try fm.removeItem(at: dir) } catch {
                notes.append("migration committed and verified, but cleanup could not remove "
                    + "\(dir.lastPathComponent) (\(error.localizedDescription)) — the journal "
                    + "stays; the next run re-verifies and retries the cleanup")
                return
            }
        }
        if fm.fileExists(atPath: journalURL.path) {
            guard unlink(journalURL.path) == 0 else {
                notes.append("migration committed and verified, but the journal could not be "
                    + "deleted (\(String(cString: strerror(errno)))) — the next run re-verifies and retries")
                return
            }
            if let why = Self.fsyncPath(stateDirURL) {
                notes.append("migration committed and verified, but the journal deletion may "
                    + "not be durable yet: \(why)")
                return
            }
        }
        try? fm.removeItem(at: stateDirURL)
        notes.append("migration committed and verified")
    }

    // ========================================================= recovery

    func recover() -> MigrationOutcome {
        log("recovering from journal state \"\(journal.state)\"")
        do {
            // The journal area may predate this build's owner-only creation
            // (an interrupted run of an older binary): validate that each
            // entry is a real directory and re-apply 0700 before anything is
            // read from or written to it (Codex, Release A review).
            try tightenJournalArea()
            Self.crashPoint("after-recovery-tighten")
            // A crash — or a reboot, which restarts an enabled unit — can
            // leave the managed OLD service running again. Stop it before
            // touching anything, whatever direction recovery takes; the
            // captured flags still decide what gets restored or recreated.
            if let service = journal.oldService, service.installed {
                let active: Bool
                do { active = try queryActive(service.name, system: false) } catch {
                    return .failed("cannot determine the old service's state during recovery: "
                        + "\((error as? UnitQueryFailure)?.message ?? "\(error)") — the journal "
                        + "at \(journalURL.path) is preserved; fix systemctl access and re-run "
                        + "`\(spec.recoveryHint)`")
                }
                if active {
                    try systemctlChecked(["stop", service.name], context: "recovery")
                    journal.stoppedOldService = true
                    try persistJournal()
                }
            }
            // Before the commit point, an unmanaged process may have been
            // started against the old roots since the crash — same refusal
            // as a fresh run, but the journal stays (the transaction is
            // real and still needs recovering).
            if ["prepared", "moved", "fixups"].contains(journal.state),
               fm.fileExists(atPath: spec.oldDataRoot) {
                let probe = Self.lockProbe(spec.oldDataRoot + "/instance.lock")
                if probe.isHeld {
                    return .refused("an unmanaged process is running against \(spec.oldDataRoot) "
                        + "(instance.lock is held) — quit it, then re-run `\(spec.recoveryHint)`. "
                        + "The migration journal is preserved")
                }
                if let problem = probe.problem {
                    return .refused("cannot tell whether a process is running against "
                        + "\(spec.oldDataRoot): \(problem) — refusing to recover on a guess. "
                        + "The migration journal is preserved")
                }
            }
            switch journal.state {
            case "prepared", "moved", "fixups":
                if mode == .rollback {
                    try rollback(reason: nil)
                    return .ok(notes: notes + ["rolled back — the previous installation was restored"])
                }
                // Forward by default when possible; otherwise roll back.
                if let why = forwardPossible() {
                    try rollback(reason: why)
                    return .failed("forward recovery impossible (\(why)) — rolled back; "
                        + "the previous installation was restored")
                }
                try moveRoots()
                try runFixups()
                try commit()
                return .ok(notes: notes + ["recovered forward and completed the migration"]
                    + journal.warnings.map { "⚠ " + $0 })
            case "committing":
                if mode == .rollback {
                    return .refused("the migration already passed its commit point (state: committing) — "
                        + "recovery completes forward; rollback is no longer offered")
                }
                if let why = forwardPossible() {
                    // Forward impossible: park-restoring rollback, but ONLY
                    // when every parked asset verifies intact.
                    if let parkedProblem = parkedAssetsProblem() {
                        return .failed("forward recovery impossible (\(why)) AND the parked assets "
                            + "do not verify (\(parkedProblem)) — everything was left in place at "
                            + "\(spec.stateDir) for manual inspection")
                    }
                    try parkRestoringRollback()
                    return .failed("forward recovery impossible (\(why)) — the parked assets verified "
                        + "intact and the previous installation was restored byte-identically")
                }
                try retire()
                try setState("committed")
                try verifyAndCleanup()
                return .ok(notes: notes + ["recovered forward from the commit phase"]
                    + journal.warnings.map { "⚠ " + $0 })
            case "committed", "done":
                if mode == .rollback {
                    return .refused("the migration is already committed — recovery only reruns "
                        + "verification and cleanup; rollback is no longer offered")
                }
                try verifyAndCleanup()
                return .ok(notes: notes + ["re-verified a committed migration and finished cleanup"])
            default:
                return .corrupt("unknown journal state \(journal.state)")
            }
        } catch let error as EngineError {
            return error.outcome
        } catch {
            return .failed("recovery failed: \(error.localizedDescription) — the journal at "
                + "\(journalURL.path) is preserved; re-run `\(spec.recoveryHint)` to retry")
        }
    }

    /// nil ⇒ forward completion is possible; otherwise the reason it isn't.
    func forwardPossible() -> String? {
        guard fm.fileExists(atPath: spec.newBinary) else {
            return "the new binary \(spec.newBinary) is missing"
        }
        for root in journal.roots where root.existed {
            let oldThere = fm.fileExists(atPath: root.old)
            let newThere = fm.fileExists(atPath: root.new)
            if oldThere && newThere {
                return "both \(root.old) and \(root.new) exist — inconsistent state"
            }
            if !oldThere && !newThere {
                return "neither \(root.old) nor \(root.new) exists — the root is lost"
            }
        }
        if let service = journal.oldService, service.installed, unitManaged,
           spec.newUnitText == nil {
            return "no new unit text in the spec"
        }
        return nil
    }

    /// lstat-based presence and kind — `fileExists` follows symlinks and
    /// would report a dangling compat symlink as "nothing there".
    static func entryKind(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return "symlink"
        case S_IFDIR: return "directory"
        default: return "file"
        }
    }

    /// Verify a parked asset's recorded kind + hash/target against the
    /// object at `path` (its parked copy or its original location).
    func parkedContentProblem(_ parked: MigrationJournal.Parked, at path: String,
                              label: String) -> String? {
        guard let kind = Self.entryKind(path) else {
            return "\(label) \(parked.id) at \(path) is unreadable"
        }
        guard kind == parked.kind else {
            return "\(label) \(parked.id) at \(path) is a \(kind), recorded as \(parked.kind)"
        }
        switch parked.kind {
        case "file":
            if Self.sha256(ofFile: URL(fileURLWithPath: path)) != parked.sha256 {
                return "\(label) \(parked.id) at \(path) does not match its recorded hash"
            }
        case "directory":
            if Self.treeHash(of: URL(fileURLWithPath: path)) != parked.sha256 {
                return "\(label) \(parked.id) tree at \(path) does not match its recorded hash"
            }
        case "symlink":
            if (try? fm.destinationOfSymbolicLink(atPath: path)) != parked.target {
                return "\(label) \(parked.id) symlink target at \(path) changed"
            }
        default:
            return "parked \(parked.id) has unknown kind \(parked.kind)"
        }
        return nil
    }

    /// Verify one parked asset at WHICHEVER location currently holds it:
    /// its parked copy, or its original path when an interrupted rollback
    /// already put it back (Codex Stage 3 round 4). Both present is refused
    /// — the engine never guesses which copy is genuine — except for the
    /// one expected state: the parked binary while its original path holds
    /// the compat symlink to the new binary (an `absent` record that the
    /// restore removes first). Nowhere present is refused as missing.
    func parkedAssetProblem(_ parked: MigrationJournal.Parked) -> String? {
        let stored = parkedDir.appendingPathComponent(parked.id).path
        let parkedThere = Self.entryKind(stored) != nil
        let originalThere = Self.entryKind(parked.originalPath) != nil
        if parkedThere && originalThere {
            let compatSymlink = parked.id == "binary" && journal.symlinkCreated
                && Self.entryKind(parked.originalPath) == "symlink"
                && (try? fm.destinationOfSymbolicLink(atPath: parked.originalPath)) == spec.newBinary
            guard compatSymlink else {
                return "parked \(parked.id) exists BOTH in parked/ and at \(parked.originalPath) "
                    + "— refusing to guess which copy is genuine"
            }
            return parkedContentProblem(parked, at: stored, label: "parked")
        }
        if parkedThere {
            return parkedContentProblem(parked, at: stored, label: "parked")
        }
        if originalThere {
            return parkedContentProblem(parked, at: parked.originalPath, label: "already-restored")
        }
        return "parked asset \(parked.id) is missing entirely"
    }

    func parkedAssetsProblem() -> String? {
        for parked in journal.parked {
            if let problem = parkedAssetProblem(parked) { return problem }
        }
        return nil
    }

    /// Stop and disable the new-identity units this migration started or
    /// enabled, exactly as far as they still exist: query current state
    /// first (throwing on broken queries), operate checked only on what is
    /// actually active/enabled.
    func stopNewIdentityUnits(context: String) throws {
        do {
            if journal.startedNewUnit, let name = spec.newUnitName,
               try queryActive(name, system: false) {
                try systemctlChecked(["stop", name], context: context)
            }
            if journal.newUnitEnabled, let name = spec.newUnitName,
               try queryEnabled(name, system: false) {
                try systemctlChecked(["disable", name], context: context)
            }
            if journal.startedNewWakelock, let name = spec.newWakelockUnitName,
               try queryActive(name, system: true) {
                try systemctlChecked(["stop", name], system: true, context: context)
            }
            if journal.newWakelockEnabled, let name = spec.newWakelockUnitName,
               try queryEnabled(name, system: true) {
                try systemctlChecked(["disable", name], system: true, context: context)
            }
        } catch let failure as UnitQueryFailure {
            throw EngineError(outcome: .failed(
                "\(context): \(failure.message) — the journal at \(journalURL.path) is "
                + "preserved; fix systemctl access and re-run `\(spec.recoveryHint)`"))
        }
    }

    /// Where a recorded path lives RIGHT NOW: a retried rollback runs after
    /// a partial one already moved some roots back, and restoring to the
    /// recorded new-root path would then recreate the new root from
    /// scratch. Translates new-root paths onto the old root when the move
    /// back has already happened; nil means the containing root is in an
    /// inconsistent state (both or neither side present) and the caller
    /// must hold.
    func currentLocation(of path: String) -> String? {
        for pair in spec.rootPairs {
            let newPrefix = pair.new.hasSuffix("/") ? pair.new : pair.new + "/"
            guard path == pair.new || path.hasPrefix(newPrefix) else { continue }
            let newThere = fm.fileExists(atPath: pair.new)
            let oldThere = fm.fileExists(atPath: pair.old)
            if newThere && !oldThere { return path }
            if oldThere && !newThere {
                return pair.old + String(path.dropFirst(pair.new.count))
            }
            return nil
        }
        return path   // outside every moved root (bin dir, unit dir, …)
    }

    /// Verify EVERY stored rollback asset against the journal BEFORE the
    /// rollback modifies anything: a damaged preimage must be rejected
    /// while the healthy file it would overwrite is still untouched (Codex
    /// Stage 3 round 3 #1). Returns the first problem, or nil when the whole
    /// set verifies. Reads only.
    func rollbackAssetsProblem() -> String? {
        for pre in journal.preimages {
            switch pre.type {
            case "file", "prefs-old-domain":
                let stored = preimagesDir.appendingPathComponent(pre.id)
                guard let expected = pre.sha256 else {
                    return "preimage \(pre.id) of \(pre.path) has no recorded hash"
                }
                var st = stat()
                guard lstat(stored.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                    return "stored preimage \(pre.id) of \(pre.path) is missing or not a regular file"
                }
                guard Self.sha256(ofFile: stored) == expected else {
                    return "stored preimage \(pre.id) of \(pre.path) does not match its recorded hash"
                }
                if pre.type == "prefs-old-domain" {
                    guard let data = try? Data(contentsOf: stored),
                          (try? PropertyListSerialization.propertyList(
                              from: data, format: nil)) as? [String: Any] != nil else {
                        return "stored preferences export \(pre.id) of \(pre.path) is not a plist dictionary"
                    }
                }
            case "symlink":
                guard let target = pre.target, !target.isEmpty else {
                    return "symlink preimage \(pre.id) of \(pre.path) has no recorded target"
                }
            case "absent", "prefs-new-domain":
                continue
            default:
                return "preimage \(pre.id) has unknown type \(pre.type)"
            }
        }
        return nil
    }

    /// Kind preflight over EVERY path a rollback will delete, overwrite or
    /// re-link — all recorded preimage paths at their current locations
    /// and every parked asset's original path — before the first mutation.
    /// The engine only ever creates or rewrites regular files and
    /// symlinks, so each target must be absent, a symlink or a regular
    /// file; a directory (or a device, FIFO, socket) at any of them means
    /// the record or the world is wrong, and the whole rollback holds with
    /// zero mutations rather than restoring the entries before it and
    /// stopping mid-way. Reads only.
    func rollbackTargetKindProblem() -> String? {
        func acceptable(_ path: String, label: String) -> String? {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }   // absent is fine
            switch st.st_mode & S_IFMT {
            case S_IFREG, S_IFLNK: return nil
            case S_IFDIR:
                return "\(label) \(path) is a DIRECTORY where a file, a symlink or nothing was recorded"
            default:
                return "\(label) \(path) is neither a regular file nor a symlink"
            }
        }
        for pre in journal.preimages where ["absent", "file", "symlink"].contains(pre.type) {
            // An inconsistent root (both or neither side present) is not a
            // kind problem: the restore loop holds on it exactly as before,
            // after the new-identity units are stopped. Only resolvable
            // entries are kind-checked here.
            guard let location = currentLocation(of: pre.path) else { continue }
            if let problem = acceptable(location, label: "recorded \(pre.type) path") {
                return problem
            }
        }
        for parked in journal.parked {
            // A restored parked asset may legitimately be back at its
            // original path (verified by parkedAssetProblem); anything else
            // there must be removable: absent or a symlink (the compat
            // link), never a directory that is not the verified asset.
            let stored = parkedDir.appendingPathComponent(parked.id).path
            guard Self.entryKind(stored) != nil else { continue }
            if let now = Self.entryKind(parked.originalPath), now != "symlink" {
                return "parked \(parked.id)'s original path \(parked.originalPath) holds a \(now) "
                    + "while the parked copy exists"
            }
        }
        return nil
    }

    /// Refuse-and-hold when the rollback assets do not verify: nothing has
    /// been modified yet, and nothing will be.
    func requireVerifiedRollbackAssets(context: String) throws {
        if let problem = rollbackAssetsProblem() {
            throw EngineError(outcome: .failed(
                "\(context) refused BEFORE modifying anything: \(problem) — a rollback from "
                + "unverified assets could overwrite healthy files; everything was held for "
                + "inspection at \(spec.stateDir)"))
        }
        if let problem = parkedAssetsProblem() {
            throw EngineError(outcome: .failed(
                "\(context) refused BEFORE modifying anything: \(problem) — everything was held "
                + "for inspection at \(spec.stateDir)"))
        }
        if let problem = rollbackTargetKindProblem() {
            throw EngineError(outcome: .failed(
                "\(context) refused BEFORE modifying anything: \(problem) — refusing to delete or "
                + "overwrite it; every entry was left as it is and the journal at "
                + "\(journalURL.path) is preserved for inspection"))
        }
    }

    /// Ordinary rollback — valid strictly BEFORE `committing` (nothing has
    /// been parked or retired yet). Restores roots, preimages (verified by
    /// hash), service topology; deletes everything the migration created.
    /// Recovery preflight over the journal area: `stateDir`, `preimages/`
    /// and `parked/` must each be absent or a real directory (never a
    /// symlink or a file — a planted link would redirect restores), and
    /// every present one is set to 0700 whatever an older build created.
    func tightenJournalArea() throws {
        for dir in [stateDirURL, preimagesDir, parkedDir] {
            var st = stat()
            guard lstat(dir.path, &st) == 0 else {
                if errno == ENOENT { continue }
                throw EngineError(outcome: .failed(
                    "cannot inspect \(dir.path) (errno \(errno)) — refusing to recover on a guess; "
                    + "the journal is preserved"))
            }
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                throw EngineError(outcome: .failed(
                    "\(dir.path) is not a directory (mode \(String(st.st_mode & S_IFMT, radix: 8))) — a migration "
                    + "journal area entry was replaced; refusing to recover, the journal is preserved. "
                    + "Restore it as a plain directory and re-run `\(spec.recoveryHint)`"))
            }
            if (st.st_mode & 0o777) != 0o700, chmod(dir.path, 0o700) != 0 {
                throw EngineError(outcome: .failed(
                    "cannot set owner-only permissions on \(dir.path) (errno \(errno)) — the journal is preserved"))
            }
        }
    }

    func rollback(reason: String?) throws {
        if let reason { log("rolling back: \(reason)") }
        // Every stored preimage is verified against the journal BEFORE the
        // first modification — including the service stops below.
        try requireVerifiedRollbackAssets(context: "rollback")
        // Stop/disable anything we started on the new identity — CHECKED (a
        // rollback that leaves the new service running while reporting
        // success would be a lie), but guarded by CURRENT state, not the
        // historical flags: a retried rollback runs after the unit file is
        // already gone, and real systemctl rejects operations on an
        // unloaded unit — the retry must still reach the old-service
        // restore (Codex Stage 3 round 2 #3).
        try stopNewIdentityUnits(context: "rollback")

        // Preimages in reverse order, each at its CURRENT location.
        for pre in journal.preimages.reversed() {
            let location: String
            switch pre.type {
            case "absent", "file", "symlink":
                guard let resolved = currentLocation(of: pre.path) else {
                    throw EngineError(outcome: .failed(
                        "rollback found the root containing \(pre.path) in an inconsistent "
                        + "state — everything was held for inspection; the journal is at \(journalURL.path)"))
                }
                location = resolved
            default:
                location = pre.path
            }
            // Re-lstat immediately before each destructive step: the
            // preflight above ran over the whole set, this catches a kind
            // change since then (same-uid check-then-act; narrow by design).
            func requireRemovableKind(_ step: String) throws {
                var st = stat()
                guard lstat(location, &st) == 0 else { return }
                let kind = st.st_mode & S_IFMT
                guard kind == S_IFREG || kind == S_IFLNK else {
                    throw EngineError(outcome: .failed(
                        "rollback found \(kind == S_IFDIR ? "a DIRECTORY" : "an unexpected object") at "
                        + "\(location) while \(step) — refusing to touch it; the journal is preserved "
                        + "for inspection"))
                }
            }
            switch pre.type {
            case "absent":
                var st = stat()
                if lstat(location, &st) == 0 {
                    // We only ever CREATE files and symlinks. A directory
                    // here means the record (or the world) is wrong — and
                    // deleting a directory recursively on a corrupted
                    // record is exactly the disaster validation exists to
                    // prevent. Refuse and hold.
                    try requireRemovableKind("removing a path the migration created")
                    do { try fm.removeItem(atPath: location) } catch {
                        throw EngineError(outcome: .failed(
                            "rollback could not remove the created path \(location): "
                            + "\(error.localizedDescription) — the journal is preserved"))
                    }
                }
            case "file":
                let stored = preimagesDir.appendingPathComponent(pre.id)
                guard let data = try? Data(contentsOf: stored) else {
                    throw EngineError(outcome: .failed(
                        "rollback could not read the preimage of \(pre.path) — everything was "
                        + "left in place at \(spec.stateDir); nothing more was restored"))
                }
                try requireRemovableKind("restoring a file preimage")
                if let why = Self.writeDurable(data, to: URL(fileURLWithPath: location),
                                               mode: pre.mode) {
                    throw EngineError(outcome: .failed(
                        "rollback could not restore \(location): \(why) — the journal and "
                        + "preimages are preserved; re-run `\(spec.recoveryHint)` to retry"))
                }
                if let uid = pre.uid, let gid = pre.gid {
                    guard chown(location, uid_t(uid), gid_t(gid)) == 0 else {
                        throw EngineError(outcome: .failed(
                            "rollback could not restore the ownership of \(location): "
                            + "\(String(cString: strerror(errno))) — the journal is preserved"))
                    }
                    if let why = Self.fsyncPath(URL(fileURLWithPath: location)) {
                        throw EngineError(outcome: .failed(
                            "restored ownership of \(location) is not durable: \(why) — the journal is preserved"))
                    }
                }
            case "symlink":
                try requireRemovableKind("restoring a symlink preimage")
                try? fm.removeItem(atPath: location)
                if let target = pre.target {
                    try fm.createSymbolicLink(atPath: location, withDestinationPath: target)
                    if let why = Self.fsyncPath(URL(fileURLWithPath:
                        (location as NSString).deletingLastPathComponent)) {
                        throw EngineError(outcome: .failed(
                            "restored symlink \(location) is not durable: \(why) — the journal is preserved"))
                    }
                }
            case "prefs-new-domain":
                let defaults = Prefs.domains
                defaults.removePersistentDomain(forName: pre.path)
                guard defaults.synchronize() else {
                    throw EngineError(outcome: .failed(
                        "rollback could not persist the removal of the \(pre.path) "
                        + "preferences domain (synchronize failed) — the journal is preserved"))
                }
            case "prefs-old-domain":
                // Before committing the old domain was never removed;
                // re-import only if it is somehow missing.
                let defaults = Prefs.domains
                if defaults.persistentDomain(forName: pre.path)?.isEmpty ?? true {
                    try reimportOldPrefsDomain(pre)
                }
            default:
                throw EngineError(outcome: .corrupt(
                    "unknown preimage type \(pre.type) in the journal"))
            }
        }

        // Verify restored files against their recorded hashes NOW, at their
        // current locations, BEFORE the roots move back — the move only
        // happens after every restore has been proven.
        for pre in journal.preimages where pre.type == "file" {
            guard let location = currentLocation(of: pre.path),
                  Self.sha256(ofFile: URL(fileURLWithPath: location)) == pre.sha256 else {
                throw EngineError(outcome: .failed(
                    "rollback restored \(pre.path) but its hash does not match the preimage — "
                    + "the journal and preimages are preserved for inspection"))
            }
        }

        // Roots back, disk-reconciled.
        for index in journal.roots.indices.reversed() {
            let root = journal.roots[index]
            guard root.existed else { continue }
            let oldThere = fm.fileExists(atPath: root.old)
            let newThere = fm.fileExists(atPath: root.new)
            let parents = [(root.old as NSString).deletingLastPathComponent,
                           (root.new as NSString).deletingLastPathComponent]
            if oldThere && !newThere {
                // Never moved — or already back. If the journal still says
                // moved, a previous rollback attempt renamed it back and
                // died before its barriers: repeat them before recording
                // (Codex Stage 3 round 3 #2).
                if root.moved {
                    for dir in parents {
                        if let why = Self.fsyncPath(URL(fileURLWithPath: dir)) {
                            throw EngineError(outcome: .failed(
                                "rollback found \(root.old) already back but the move is not durable: "
                                + "\(why) — the journal is preserved; re-run `\(spec.recoveryHint)` to retry"))
                        }
                    }
                    journal.roots[index].moved = false
                    try persistJournal()
                }
                continue
            }
            if !oldThere && newThere {
                guard rename(root.new, root.old) == 0 else {
                    throw EngineError(outcome: .failed(
                        "rollback could not move \(root.new) back to \(root.old): "
                        + "\(String(cString: strerror(errno))) — the journal is preserved; "
                        + "re-run `\(spec.recoveryHint)` to retry"))
                }
                Self.crashPoint("after-rollback-rename")
                for dir in parents {
                    if let why = Self.fsyncPath(URL(fileURLWithPath: dir)) {
                        throw EngineError(outcome: .failed(
                            "rollback moved \(root.new) back but the move is not durable: \(why) "
                            + "— the journal is preserved; re-run `\(spec.recoveryHint)` to retry"))
                    }
                }
                journal.roots[index].moved = false
                try persistJournal()
                continue
            }
            throw EngineError(outcome: .failed(
                "rollback found \(root.old) and \(root.new) in an inconsistent state "
                + "(\(oldThere ? "both present" : "both missing")) — everything was held for "
                + "manual inspection; the journal is at \(journalURL.path)"))
        }

        // Unit files created on the new identity are gone now (absent
        // restores) — reload before restoring the old topology.
        if unitManaged, journal.newUnitInstalled {
            try systemctlChecked(["daemon-reload"], context: "rollback")
        }
        if journal.newWakelockInstalled {
            try systemctlChecked(["daemon-reload"], system: true, context: "rollback")
        }

        // Service topology as captured: the old unit was never uninstalled
        // before committing, only stopped — restart it if it was active.
        if journal.stoppedOldService, let service = journal.oldService, service.active {
            try systemctlChecked(["start", service.name],
                                 context: "rollback (restarting the old service)")
            log("restarted \(service.name)")
        }

        // VERIFY the restored topology before declaring success — the
        // journal is deleted below, so this is the last honest moment
        // (Codex Stage 3 round 1 #2).
        do {
            if unitManaged {
                if let service = journal.oldService, service.installed,
                   try queryActive(service.name, system: false) != service.active {
                    throw EngineError(outcome: .failed(
                        "rollback finished but \(service.name) is \(service.active ? "not active" : "still active") "
                        + "— captured topology not restored; the journal is preserved"))
                }
                if let newUnitName = spec.newUnitName, journal.startedNewUnit,
                   try queryActive(newUnitName, system: false) {
                    throw EngineError(outcome: .failed(
                        "rollback finished but \(newUnitName) is still active — the journal is preserved"))
                }
            }
            if spec.wakelockPrivileged {
                if let wakelock = journal.wakelockService, wakelock.installed,
                   try queryActive(wakelock.name, system: true) != wakelock.active {
                    throw EngineError(outcome: .failed(
                        "rollback finished but the keep-awake unit \(wakelock.name) does not match "
                        + "its captured state — the journal is preserved"))
                }
                if let name = spec.newWakelockUnitName, journal.startedNewWakelock,
                   try queryActive(name, system: true) {
                    throw EngineError(outcome: .failed(
                        "rollback finished but \(name) is still active — the journal is preserved"))
                }
            }
        } catch let failure as UnitQueryFailure {
            throw EngineError(outcome: .failed(
                "rollback finished but its verification could not query systemctl: "
                + "\(failure.message) — the journal is preserved"))
        }

        // Rollback complete — clear the journal area, CHECKED: an orphaned
        // journal on a rolled-back tree would send the next run into
        // forward recovery the user never asked for.
        for dir in [preimagesDir, parkedDir] where fm.fileExists(atPath: dir.path) {
            do { try fm.removeItem(at: dir) } catch {
                throw EngineError(outcome: .failed(
                    "the rollback itself SUCCEEDED — every file was restored and verified — "
                    + "but the journal area could not be cleared (\(error.localizedDescription)); "
                    + "delete \(spec.stateDir) manually before the next migration attempt"))
            }
        }
        if fm.fileExists(atPath: journalURL.path) {
            guard unlink(journalURL.path) == 0 else {
                throw EngineError(outcome: .failed(
                    "the rollback itself SUCCEEDED, but the journal could not be deleted "
                    + "(\(String(cString: strerror(errno)))); delete \(spec.stateDir) manually "
                    + "before the next migration attempt"))
            }
            if let why = Self.fsyncPath(stateDirURL) {
                throw EngineError(outcome: .failed(
                    "the rollback itself SUCCEEDED, but the journal deletion is not durable: "
                    + "\(why); ensure \(spec.stateDir) is gone before the next attempt"))
            }
        }
        try? fm.removeItem(at: stateDirURL)
        notes.append("every touched file was restored and verified against its preimage")
    }

    /// Park-restoring rollback (plan v6): from ≥ committing, when forward is
    /// impossible and the parked assets verify. Puts unit/binary/bundle back
    /// from parked/, re-enables the old unit, re-imports the old prefs
    /// domain, then runs the ordinary rollback.
    func parkRestoringRollback() throws {
        log("park-restoring rollback")
        // Parked assets AND preimages verified before the first modification.
        try requireVerifiedRollbackAssets(context: "park-restoring rollback")
        // Anything started on the new identity goes down first, so old and
        // new never run side by side during the restore.
        try stopNewIdentityUnits(context: "park-restoring rollback")
        // The compat symlink occupies the binary's path — remove it first
        // (it is also an `absent` record, so this is just ordering).
        if journal.symlinkCreated,
           (try? fm.destinationOfSymbolicLink(atPath: spec.oldBinary)) == spec.newBinary {
            try? fm.removeItem(atPath: spec.oldBinary)
        }
        var restoredPaths: Set<String> = []
        for parked in journal.parked.reversed() {
            let stored = parkedDir.appendingPathComponent(parked.id)
            guard Self.entryKind(stored.path) != nil else {
                // Already restored by an earlier, interrupted attempt (or
                // never parked): it counts as restored ONLY if the object
                // at the original path verifies against the record — then
                // its `absent` record is dropped below, otherwise a RETRIED
                // park-restoring rollback would delete the binary its first
                // attempt had just put back. (Pre-verified above; re-checked
                // here so this branch can never accept an unverified object.)
                if Self.entryKind(parked.originalPath) != nil {
                    if let problem = parkedContentProblem(parked, at: parked.originalPath,
                                                          label: "already-restored") {
                        throw EngineError(outcome: .failed(
                            "park-restoring rollback held: \(problem) — the journal is preserved"))
                    }
                    restoredPaths.insert(parked.originalPath)
                }
                continue
            }
            if let now = Self.entryKind(parked.originalPath), now != "symlink" {
                throw EngineError(outcome: .failed(
                    "park-restoring rollback found a \(now) at \(parked.originalPath) while "
                    + "restoring parked \(parked.id) — refusing to remove it; the journal is preserved"))
            }
            try? fm.removeItem(atPath: parked.originalPath)
            guard rename(stored.path, parked.originalPath) == 0 else {
                throw EngineError(outcome: .failed(
                    "could not restore parked \(parked.id) to \(parked.originalPath): "
                    + "\(String(cString: strerror(errno))) — the journal is preserved"))
            }
            if parked.kind != "symlink" {
                if let mode = parked.mode {
                    guard chmod(parked.originalPath, mode_t(mode)) == 0 else {
                        throw EngineError(outcome: .failed(
                            "could not restore the mode of \(parked.originalPath): "
                            + "\(String(cString: strerror(errno))) — the journal is preserved"))
                    }
                }
                if let uid = parked.uid, let gid = parked.gid {
                    guard chown(parked.originalPath, uid_t(uid), gid_t(gid)) == 0 else {
                        throw EngineError(outcome: .failed(
                            "could not restore the ownership of \(parked.originalPath): "
                            + "\(String(cString: strerror(errno))) — the journal is preserved"))
                    }
                }
            }
            // Barriers on the file itself (mode/ownership), the destination
            // parent (the rename's new entry) AND the source parked/
            // directory (the rename's removed entry) — a crash after an
            // un-synced source would let the asset reappear in parked/ and
            // be "restored" again over the live file (Codex round 3 #2).
            for target in [parked.originalPath,
                           (parked.originalPath as NSString).deletingLastPathComponent,
                           parkedDir.path]
                where parked.kind != "symlink" || target != parked.originalPath {
                if let why = Self.fsyncPath(URL(fileURLWithPath: target)) {
                    throw EngineError(outcome: .failed(
                        "restore of \(parked.originalPath) is not durable: \(why) — the journal is preserved"))
                }
            }
            restoredPaths.insert(parked.originalPath)
        }
        // A restored parked asset supersedes any `absent` record at the same
        // path (the compat symlink over the binary): rollback must not
        // delete what was just put back.
        if !restoredPaths.isEmpty {
            journal.preimages.removeAll {
                $0.type == "absent" && restoredPaths.contains($0.path)
            }
            try persistJournal()
        }
        if let service = journal.oldService, service.installed, unitManaged {
            try systemctlChecked(["daemon-reload"], context: "park-restoring rollback")
            if service.enabled {
                try systemctlChecked(["enable", service.name],
                                     context: "park-restoring rollback")
            }
        }
        // The old keep-awake unit was stopped and disabled at retirement —
        // re-arm it exactly per its captured flags.
        if let wakelock = journal.wakelockService, wakelock.installed,
           spec.wakelockPrivileged {
            try systemctlChecked(["daemon-reload"], system: true,
                                 context: "park-restoring rollback")
            if wakelock.enabled {
                try systemctlChecked(["enable", wakelock.name], system: true,
                                     context: "park-restoring rollback")
            }
            if wakelock.active {
                try systemctlChecked(["start", wakelock.name], system: true,
                                     context: "park-restoring rollback")
            }
        }
        if let pre = journal.preimages.first(where: { $0.type == "prefs-old-domain" }) {
            try reimportOldPrefsDomain(pre)
        }
        try rollback(reason: nil)
    }

    func reimportOldPrefsDomain(_ pre: MigrationJournal.Preimage) throws {
        let stored = preimagesDir.appendingPathComponent(pre.id)
        guard let data = try? Data(contentsOf: stored),
              Self.sha256(of: data) == pre.sha256,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any] else {
            throw EngineError(outcome: .failed(
                "could not re-import the exported \(pre.path) preferences domain — "
                + "the export at \(stored.path) is missing or does not match its hash"))
        }
        let defaults = Prefs.domains
        defaults.setPersistentDomain(plist, forName: pre.path)
        guard defaults.synchronize() else {
            throw EngineError(outcome: .failed(
                "re-import of the \(pre.path) preferences domain could not be persisted "
                + "(synchronize failed) — the journal is preserved"))
        }
    }

    /// True when every root that existed is still at its OLD path and its
    /// new path is absent — the only situation in which a journal may be
    /// dropped without a rollback.
    func rootsUntouchedOnDisk() -> Bool {
        for root in journal.roots where root.existed {
            guard fm.fileExists(atPath: root.old), !fm.fileExists(atPath: root.new) else {
                return false
            }
        }
        return true
    }

    /// A failure while the transaction is still before `committing`: roll
    /// back now and report honestly whether the restore succeeded.
    func handleMidTransactionFailure(_ why: String) -> MigrationOutcome {
        // Past the commit point, rollback is NOT the answer — recovery
        // completes forward (or runs the defined park-restoring rollback,
        // decided by the next run's state machine, never by an ad-hoc
        // failure path).
        if ["committing", "committed", "done"].contains(journal.state) {
            return .failed(why + " — the migration is past its commit point; nothing was rolled "
                + "back. The journal at \(journalURL.path) is preserved; re-run "
                + "`\(spec.recoveryHint)` to complete the migration")
        }
        // Pre-move failures (state prepared, nothing moved): restore the
        // service, drop the journal, report honestly — including a restart
        // that did not work. "Nothing moved" is decided by the DISK, not by
        // the journal flags alone: a root whose rename succeeded but whose
        // barrier failed (or a crash between the two, reconciled on
        // recovery) is moved with moved=false in the journal — dropping the
        // journal there would strand the root at its new path with no
        // record of the move.
        if journal.state == "prepared", !journal.roots.contains(where: { $0.moved }),
           rootsUntouchedOnDisk() {
            let restartProblem = restoreServiceAfterRefusal()
            cleanupJournalArea()
            if let restartProblem {
                return .failed(why + " — nothing had been moved, but " + restartProblem)
            }
            return .failed(why + " — nothing had been moved; the installation is untouched")
        }
        do {
            try rollback(reason: why)
            return .failed(why + " — the migration was rolled back; the previous installation "
                + "was restored and verified")
        } catch let rollbackError as EngineError {
            if case let .failed(inner) = rollbackError.outcome {
                return .failed(why + "; ROLLBACK ALSO INCOMPLETE: " + inner)
            }
            return rollbackError.outcome
        } catch {
            return .failed(why + "; rollback also failed: \(error.localizedDescription) — "
                + "the journal at \(journalURL.path) is preserved; re-run `\(spec.recoveryHint)`")
        }
    }
}

// MARK: - Hidden runner (Stage 3 test harness)
//
// Runs the engine against a spec FILE in a separate process, which is what
// makes the selftest's crash injection real: BRIGLIA_MIGRATE_CRASH_POINT kills
// this process with _exit — no defers, no cleanup — and recovery then runs
// as a genuinely fresh process against whatever the journal says. Stage 4
// wires the real user-facing `migrate` command; nothing user-facing changes
// in Stage 3.
struct MigrationRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__migrate-run",
        abstract: "Internal: run the identity-migration engine against a spec file.",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Path to a MigrationSpec JSON file.")
    var spec: String?

    @Flag(name: .long, help: "Explicit rollback instead of forward recovery.")
    var rollback = false

    @Flag(name: .long, help: "Print read-only detection status and exit.")
    var detect = false

    @Flag(name: .long, help: "Print doctor's read-only migration report and exit.")
    var doctor = false

    @Option(name: .long, help: "Print a UserDefaults persistent domain as JSON and exit.")
    var dumpPrefsDomain: String?

    /// The raw engine runner exists for the selftest battery only. It is
    /// admitted solely in development builds — the same version predicate
    /// the dev seams and release-policy overrides use — and refused before
    /// ANY branch (forward, --rollback, --detect, --doctor,
    /// --dump-prefs-domain) in a release build. No environment override.
    static let refusalText = "__migrate-run is a development-build command"

    static func isDevelopmentBuild(version: String = adaCLIVersion) -> Bool {
        version.hasSuffix("-dev")
    }

    func run() throws {
        try AssistantProfile.requireDefault(AssistantProfile.migrateMessage)
        AdaCLI.prepareIO()
        guard Self.isDevelopmentBuild() else {
            print(Self.refusalText)
            throw ExitCode(2)
        }
        if let domain = dumpPrefsDomain {
            // Read in a FRESH process so the caller never sees its own
            // process-local UserDefaults cache.
            let contents = Prefs.domains.persistentDomain(forName: domain) ?? [:]
            var out: [String: String] = [:]
            for (key, value) in contents { out[key] = String(describing: value) }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        guard let specPath = spec else {
            throw ValidationError("--spec is required (or --dump-prefs-domain)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: specPath))
        let decoded = try JSONDecoder().decode(MigrationSpec.self, from: data)
        if detect {
            let status = MigrationEngine.detect(spec: decoded)
            print("DETECT old=\(status.oldRootsPresent.count) new=\(status.newRootsPresent.count) "
                + "journal=\(status.journalState ?? "none")")
            return
        }
        if doctor {
            print(MigrationEngine.doctorReport(spec: decoded) ?? "no migration journal")
            return
        }
        let outcome = MigrationEngine.run(spec: decoded,
                                          mode: rollback ? .rollback : .auto) { print("· \($0)") }
        switch outcome {
        case .ok(let notes):
            for note in notes { print("✔ \(note)") }
            print("MIGRATE-OUTCOME: ok")
        case .refused(let why):
            print("MIGRATE-OUTCOME: refused: \(why)")
            throw ExitCode(2)
        case .corrupt(let why):
            print("MIGRATE-OUTCOME: corrupt: \(why)")
            throw ExitCode(3)
        case .failed(let why):
            print("MIGRATE-OUTCOME: failed: \(why)")
            throw ExitCode(1)
        }
    }
}
