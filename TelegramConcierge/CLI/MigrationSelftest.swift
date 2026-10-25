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

/// Hidden deterministic test of the identity-migration engine
/// (MigrationEngine.swift) — the Stage 3 exit criteria of RENAME_PLAN.md
/// §4.3/§4.5: full fixture migration, the service-state matrix, refusals,
/// journal-corruption refusal, REAL crash injection (the engine runs in a
/// child process and _exit(137)s at the injected point) after every
/// destructive sub-step with state-appropriate recovery, byte-identical
/// typed-preimage rollback including metadata and absent-creation deletion,
/// park-restoring rollback with parked-asset hash verification,
/// verification-before-cleanup at committed/done, the preferences-domain
/// copy, and the diagnostics no-mutation battery. Everything runs against
/// fixtures in a temp root with a fake systemctl — no real service, any
/// platform.
struct MigrationSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__migration-selftest",
        abstract: "Internal: verify the identity-migration engine against fixtures.",
        shouldDisplay: false
    )

    func run() async throws {
        AdaCLI.prepareIO()
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("ada-migrate-selftest-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let adaBinary = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func note(_ text: String) { print("  · \(text)") }

        func writeScript(_ path: String, _ body: String) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        func writeFile(_ path: String, _ body: String, mode: Int = 0o644) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        func sha(_ path: String) -> String {
            guard let data = fm.contents(atPath: path) else { return "<unreadable>" }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func readText(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>"
        }

        /// Deterministic recursive snapshot: relative path → descriptor
        /// (type, mode, content hash / symlink target). Byte-identical
        /// restore is asserted by comparing snapshots.
        func snapshot(_ roots: [String]) -> [String: String] {
            var out: [String: String] = [:]
            for root in roots {
                var st = stat()
                guard lstat(root, &st) == 0 else { continue }
                let base = (root as NSString).lastPathComponent
                func record(_ path: String, rel: String) {
                    var st = stat()
                    guard lstat(path, &st) == 0 else { return }
                    let mode = String(st.st_mode & 0o7777, radix: 8)
                    switch st.st_mode & S_IFMT {
                    case S_IFLNK:
                        let target = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?"
                        out[rel] = "link|\(target)"
                    case S_IFDIR:
                        out[rel] = "dir|\(mode)"
                        for name in (try? fm.contentsOfDirectory(atPath: path))?.sorted() ?? [] {
                            record(path + "/" + name, rel: rel + "/" + name)
                        }
                    default:
                        out[rel] = "file|\(mode)|\(sha(path))"
                    }
                }
                record(root, rel: base)
            }
            return out
        }
        func snapshotDiff(_ a: [String: String], _ b: [String: String]) -> [String] {
            var diffs: [String] = []
            for key in Set(a.keys).union(b.keys).sorted() {
                if a[key] != b[key] {
                    diffs.append("\(key): \(a[key] ?? "absent") → \(b[key] ?? "absent")")
                }
            }
            return diffs
        }

        // -------------------------------------------------------- fixture

        struct Fixture {
            var root: String
            var oldConfig: String, newConfig: String
            var oldData: String, newData: String
            var oldLanding: String, newLanding: String
            var binDir: String, unitDir: String, sysd: String
            var oldBinary: String, newBinary: String
            var oldBundle: String, newBundle: String
            var systemUnits: String
            var stateDir: String, probeLog: String, specPath: String
            var spec: MigrationSpec
            var oldUnit: String { unitDir + "/ada-test.service" }
            var newUnit: String { unitDir + "/briglia-test.service" }
            var oldWakelockUnit: String { systemUnits + "/ada-keepawake-test.service" }
            var newWakelockUnit: String { systemUnits + "/briglia-keepawake-test.service" }
            /// Everything a rollback must restore byte-identically.
            var restoreRoots: [String] {
                [oldConfig, oldData, oldLanding, binDir, unitDir, oldBundle, systemUnits]
            }
        }

        func makeFixture(_ name: String,
                         units: Bool = true, unitEnabled: Bool = true,
                         unitActive: Bool = true,
                         wakelock: Bool = false, wakelockManaged: Bool = true,
                         prefs: Bool = false,
                         persona: String = "Ada",
                         binaryIsSymlink: Bool = false,
                         probeFails: Bool = false) throws -> Fixture {
            let root = tempRoot.appendingPathComponent(name).path
            let oldConfig = root + "/xdg-config/old-app"
            let newConfig = root + "/xdg-config/new-app"
            let oldData = root + "/xdg-data/old-app"
            let newData = root + "/xdg-data/new-app"
            let oldLanding = root + "/landing-old"
            let newLanding = root + "/landing-new"
            let binDir = root + "/bin"
            let unitDir = root + "/units"
            let sysd = root + "/sysd"
            let oldBundle = root + "/bundle-old"
            let newBundle = root + "/bundle-new"
            let systemUnits = root + "/system-units"
            let stateDir = root + "/state/migrate"
            let probeLog = root + "/probe.log"

            // Old config root.
            try writeFile(oldConfig + "/secrets.json",
                          "{\"assistant_name\": \"\(persona)\", \"other_key\": \"keep-me\"}",
                          mode: 0o600)
            try writeFile(oldConfig + "/mcp.json", "{}")

            // Old data root: reminders + scripted watcher, trust store,
            // toolchain prefix, conversation, instance lock.
            let script = oldData + "/reminder-scripts/hello.sh"
            try writeScript(script, "#!/bin/sh\necho hello-from-watcher\n")
            try writeFile(oldData + "/reminders.json", """
            [{"id": "morning", "prompt": "check", "script": "\(script)",
              "workdir": "\(oldData)/reminder-scripts"}]
            """)
            try writeFile(oldData + "/reminder-scripts/state/hello.json", """
            {"script": "\(script)", "sha256": "\(sha(script))", "runs": 3}
            """)
            try writeFile(oldData + "/release_trust.json",
                          "{\"schema\": 2, \"domains\": {\"ada-cli|https://x/\": 58}}")
            try writeFile(oldData + "/conversation.json", "{\"messages\": []}")
            try writeFile(oldData + "/instance.lock", "")
            let prefixTool = oldData + "/toolchain/prefix/usr/bin/faketool"
            try writeScript(prefixTool, "#!/bin/sh\necho faketool 1.0\n")
            // A setgid file the engine only ever MOVES (never rewrites): its
            // special bit must ride through migration and rollback exactly.
            try writeFile(oldData + "/toolchain/prefix/usr/bin/sgid-tool",
                          "#!/bin/sh\necho sgid\n", mode: 0o2755)
            try writeFile(oldData + "/toolchain/prefix/usr/lib/libreoffice/program/fundamentalrc",
                          "URE_BOOTSTRAP=\(oldData)/toolchain/prefix/usr/lib/libreoffice/program/fundamentalrc\n")

            // Landing zone.
            try writeFile(oldLanding + "/note.txt", "user document")

            // Binaries, bundles, wrappers.
            let oldBinary = binDir + "/ada-old"
            let newBinary = binDir + "/briglia-new"
            let realOld = binDir + "/real-ada"
            let oldBody = "#!/bin/sh\n[ -f \"\(oldData)/conversation.json\" ] || exit 3\necho old-ada\n"
            if binaryIsSymlink {
                try writeScript(realOld, oldBody)
                try fm.createSymbolicLink(atPath: oldBinary, withDestinationPath: realOld)
            } else {
                try writeScript(oldBinary, oldBody)
            }
            try writeScript(newBinary, "#!/bin/sh\necho new-briglia\n")
            try writeScript(binDir + "/agentmail",
                "#!/bin/sh\nKEY=$(\"\(oldBinary)\" __agentmail-key) || exit 1\nexec /usr/bin/true \"$KEY\" \"$@\"\n")
            try writeScript(binDir + "/faketool", """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            \(UserdataToolchain.closureMarker)
            export LD_LIBRARY_PATH="\(oldData)/toolchain/prefix/usr/lib"
            exec "\(prefixTool)" "$@"
            """)
            try writeFile(oldBundle + "/BundledSkills/pdf/SKILL.md", "old bundle content")
            try writeFile(newBundle + "/BundledSkills/pdf/SKILL.md", "new bundle content")

            // Fake systemd + lock holder + probe.
            try fm.createDirectory(atPath: sysd, withIntermediateDirectories: true)
            try writeFile(sysd + "/lockholder.py", """
            import fcntl, os, sys, time
            f = open(sys.argv[1], "a+")
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                sys.exit(1)
            with open(sys.argv[2], "w") as p:
                p.write(str(os.getpid()))
            time.sleep(600)
            """)
            let systemctl = root + "/systemctl"
            try writeScript(systemctl, """
            #!/bin/sh
            SD="\(sysd)"
            echo "$@" >> "$SD/log"
            if [ "${FAKE_SYSTEMCTL_LOG_OUTPATH:-0}" = "1" ]; then
                # Where does fd 1 point? (Linux: /proc; macOS: F_GETPATH.)
                exec 5>&1
                p=$(python3 -c 'import fcntl,os; p=os.path.exists("/proc/self/fd/5") and os.readlink("/proc/self/fd/5") or fcntl.fcntl(5, fcntl.F_GETPATH, b"\\0"*1024).split(b"\\0",1)[0].decode(); print(p)' 2>/dev/null)
                exec 5>&-
                echo "$p" >> "$SD/outpaths"
            fi
            if [ "$1" = "--user" ]; then shift; fi
            verb="$1"; unit="$2"
            # Broken-query seam: systemd/dbus itself failing must never read
            # as "inactive" (Codex round 2 #4).
            if [ "${FAKE_SYSTEMCTL_BREAK_QUERY:-0}" = "1" ]; then
                case "$verb" in is-enabled|is-active) echo "Failed to connect to bus: garbage"; exit 127;; esac
            fi
            # Real systemd rejects lifecycle operations on a unit with no
            # unit file ("not loaded", exit 5) and answers is-enabled with a
            # unit-file-state error — retried rollbacks must survive both.
            loaded=1
            if [ -n "$unit" ] && [ ! -f "\(unitDir)/$unit" ] && [ ! -f "\(systemUnits)/$unit" ]; then loaded=0; fi
            case "$verb" in
              daemon-reload) exit 0;;
              is-enabled) if [ "$loaded" = 0 ]; then echo "Failed to get unit file state for $unit: No such file or directory"; exit 1; fi
                          if [ -f "$SD/$unit.enabled" ]; then echo enabled; else echo disabled; fi; exit 0;;
              is-active)  # Transitional-state seam (Codex round 3 #3): a
                          # countdown file makes the unit answer "activating"
                          # that many times before settling.
                          if [ -f "$SD/$unit.transitional" ]; then
                              n=$(cat "$SD/$unit.transitional"); n=$((n-1))
                              if [ $n -le 0 ]; then rm -f "$SD/$unit.transitional"; else echo $n > "$SD/$unit.transitional"; fi
                              echo activating; exit 0
                          fi
                          if [ -f "$SD/$unit.active" ]; then echo active; else echo inactive; fi; exit 0;;
              enable|disable|start|stop)
                          if [ "$loaded" = 0 ]; then echo "Unit $unit not loaded."; exit 5; fi;;
            esac
            case "$verb" in
              enable) if [ "${FAKE_SYSTEMCTL_FAIL_ENABLE:-0}" = "1" ]; then echo "enable refused"; exit 1; fi
                      touch "$SD/$unit.enabled"; exit 0;;
              disable) rm -f "$SD/$unit.enabled"; exit 0;;
              stop) rm -f "$SD/$unit.active"
                    # The daemon fake writes its pidfile asynchronously after
                    # start returns — wait for it briefly, or a fast
                    # stop-after-start would leak a lock holder whose flock
                    # then travels back with the rolled-back data root.
                    i=0
                    while [ $i -lt 40 ]; do
                        if [ -f "$SD/$unit.pid" ]; then
                            echo "STOPKILL $unit pid=$(cat "$SD/$unit.pid")" >> "$SD/log"
                            kill "$(cat "$SD/$unit.pid")" 2>/dev/null
                            rm -f "$SD/$unit.pid"; break
                        fi
                        if [ "$unit" != "briglia-test.service" ]; then break; fi
                        sleep 0.05; i=$((i+1))
                    done
                    if [ "$unit" = "briglia-test.service" ] && [ $i -ge 40 ]; then echo "STOPKILL $unit TIMEOUT no pidfile" >> "$SD/log"; fi
                    exit 0;;
              start) if [ "${FAKE_SYSTEMCTL_FAIL_START:-0}" = "1" ]; then echo "start refused"; exit 1; fi
                     if [ -n "${FAKE_SYSTEMCTL_FAIL_START_UNIT:-}" ] && [ "$unit" = "$FAKE_SYSTEMCTL_FAIL_START_UNIT" ]; then echo "start refused for $unit"; exit 1; fi
                     touch "$SD/$unit.active"
                     if [ "$unit" = "briglia-test.service" ]; then
                       nohup python3 "$SD/lockholder.py" "\(newData)/instance.lock" "$SD/$unit.pid" >/dev/null 2>&1 &
                     fi
                     exit 0;;
            esac
            exit 0
            """)
            let probe = root + "/probe.sh"
            try writeScript(probe, probeFails
                ? "#!/bin/sh\necho probe-failing >> \"\(probeLog)\"\nexit 1\n"
                : "#!/bin/sh\n[ -d \"\(newData)\" ] || exit 4\necho probed >> \"\(probeLog)\"\nexit 0\n")

            if units {
                try writeFile(unitDir + "/ada-test.service",
                              "[Unit]\nDescription=old ada\n[Service]\nExecStart=\(oldBinary) daemon\n")
                if unitEnabled { try writeFile(sysd + "/ada-test.service.enabled", "") }
                if unitActive { try writeFile(sysd + "/ada-test.service.active", "") }
            } else {
                try fm.createDirectory(atPath: unitDir, withIntermediateDirectories: true)
            }
            try fm.createDirectory(atPath: systemUnits, withIntermediateDirectories: true)
            if wakelock {
                try writeFile(systemUnits + "/ada-keepawake-test.service",
                              "[Unit]\nDescription=old keepawake\n")
                try writeFile(sysd + "/ada-keepawake-test.service.enabled", "")
                try writeFile(sysd + "/ada-keepawake-test.service.active", "")
            }

            var spec = MigrationSpec(
                oldConfigRoot: oldConfig, newConfigRoot: newConfig,
                oldDataRoot: oldData, newDataRoot: newData,
                oldLandingZone: oldLanding, newLandingZone: newLanding,
                oldBinary: oldBinary, newBinary: newBinary,
                oldBundle: oldBundle, newBundle: newBundle,
                wrapperBinDir: binDir,
                unitDir: unitDir, oldUnitName: "ada-test.service",
                newUnitName: "briglia-test.service",
                newUnitText: "[Unit]\nDescription=new briglia\n[Service]\nExecStart=\(newBinary) daemon\n",
                systemctl: systemctl,
                oldWakelockUnitPath: wakelock ? systemUnits + "/ada-keepawake-test.service" : nil,
                newWakelockUnitPath: wakelock ? systemUnits + "/briglia-keepawake-test.service" : nil,
                oldWakelockUnitName: wakelock ? "ada-keepawake-test.service" : nil,
                newWakelockUnitName: wakelock ? "briglia-keepawake-test.service" : nil,
                newWakelockUnitText: wakelock ? "[Unit]\nDescription=new keepawake\n" : nil,
                wakelockSystemctl: wakelock ? systemctl : nil,
                wakelockManaged: wakelock ? wakelockManaged : nil,
                healthProbe: [probe], healthProbeTimeout: 15,
                stateDir: stateDir,
                personaOldName: "Ada", personaNewName: "Bree",
                personaMarkerName: nil,
                oldPrefsDomain: nil, newPrefsDomain: nil,
                toolchainWrapperMarker: nil, agentmailWrapperName: nil,
                upgradeMarkerNames: nil,
                recoveryCommand: "migrate-test")
            if prefs {
                let tag = UUID().uuidString.prefix(8)
                spec.oldPrefsDomain = "ada-mig-st-\(tag)-old"
                spec.newPrefsDomain = "ada-mig-st-\(tag)-new"
            }
            let specPath = root + "/spec.json"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(spec).write(to: URL(fileURLWithPath: specPath))

            return Fixture(root: root, oldConfig: oldConfig, newConfig: newConfig,
                           oldData: oldData, newData: newData,
                           oldLanding: oldLanding, newLanding: newLanding,
                           binDir: binDir, unitDir: unitDir, sysd: sysd,
                           oldBinary: oldBinary, newBinary: newBinary,
                           oldBundle: oldBundle, newBundle: newBundle,
                           systemUnits: systemUnits,
                           stateDir: stateDir, probeLog: probeLog,
                           specPath: specPath, spec: spec)
        }

        func killHolders(_ fixture: Fixture) {
            for name in (try? fm.contentsOfDirectory(atPath: fixture.sysd)) ?? []
                where name.hasSuffix(".pid") {
                if let pid = Int32(readText(fixture.sysd + "/" + name)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) {
                    kill(pid, SIGKILL)
                }
            }
        }

        /// Run the engine in a CHILD process (crash injection is a real
        /// process death). Goes through MigrationEngine.runBounded —
        /// posix_spawn + waitpid — because the fixture's fake `systemctl
        /// start` daemonizes a lock holder, and corelibs Process on Linux
        /// would wait on that grandchild's inherited socketpair instead of
        /// the runner's real exit (the orphan-hostage trap).
        @discardableResult
        func runEngine(_ fixture: Fixture, args: [String] = [],
                       env: [String: String] = [:]) -> (code: Int32, output: String) {
            let result = MigrationEngine.runBounded(
                [adaBinary, "__migrate-run", "--spec", fixture.specPath] + args,
                timeout: 120, extraEnv: env)
            return (result.exitCode, result.output)
        }

        func dumpPrefs(_ domain: String) -> String {
            let result = MigrationEngine.runBounded(
                [adaBinary, "__migrate-run", "--dump-prefs-domain", domain], timeout: 30)
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Post-success invariants shared by the clean run and every
        /// forward-recovery crash scenario.
        func assertMigratedState(_ fixture: Fixture, label: String,
                                 expectSymlink: Bool = true) {
            let f = fixture
            check("\(label): old roots gone, new roots present",
                  !fm.fileExists(atPath: f.oldConfig) && !fm.fileExists(atPath: f.oldData)
                  && !fm.fileExists(atPath: f.oldLanding)
                  && fm.fileExists(atPath: f.newConfig) && fm.fileExists(atPath: f.newData)
                  && fm.fileExists(atPath: f.newLanding))
            let secrets = readText(f.newConfig + "/secrets.json")
            check("\(label): persona rewritten Ada → Bree, other keys kept",
                  secrets.contains("\"assistant_name\" : \"Bree\"")
                  || secrets.contains("\"assistant_name\": \"Bree\""),
                  secrets)
            check("\(label): secrets.json keeps its 0600 mode",
                  MigrationEngine.fileMode(f.newConfig + "/secrets.json") == 0o600)
            check("\(label): persona marker written in the new data root",
                  readText(f.newData + "/migrated_from_ada.json").contains("\"priorName\""))
            let reminders = readText(f.newData + "/reminders.json")
            check("\(label): reminders rebased to the new data root",
                  reminders.contains(f.newData) && !reminders.contains(f.oldData))
            let state = readText(f.newData + "/reminder-scripts/state/hello.json")
            check("\(label): watcher state rebased", state.contains(f.newData))
            let script = f.newData + "/reminder-scripts/hello.sh"
            check("\(label): script content untouched, hash in state still valid",
                  state.contains(sha(script))
                  && readText(script) == "#!/bin/sh\necho hello-from-watcher\n")
            check("\(label): script keeps executable mode",
                  MigrationEngine.fileMode(script) == 0o755)
            let wrapper = readText(f.binDir + "/agentmail")
            check("\(label): agentmail wrapper re-pointed at the new binary",
                  wrapper.contains(f.newBinary) && !wrapper.contains(f.oldBinary)
                  && MigrationEngine.fileMode(f.binDir + "/agentmail") == 0o755)
            let toolWrapper = readText(f.binDir + "/faketool")
            check("\(label): toolchain wrapper rebased and executable",
                  toolWrapper.contains(f.newData) && !toolWrapper.contains(f.oldData)
                  && MigrationEngine.fileMode(f.binDir + "/faketool") == 0o755)
            check("\(label): setgid bit on a moved file survives bit-for-bit (0o2755)",
                  MigrationEngine.fileMode(f.newData + "/toolchain/prefix/usr/bin/sgid-tool") == 0o2755,
                  MigrationEngine.fileMode(f.newData + "/toolchain/prefix/usr/bin/sgid-tool")
                      .map { String($0, radix: 8) } ?? "missing")
            check("\(label): LibreOffice rc rebased",
                  readText(f.newData + "/toolchain/prefix/usr/lib/libreoffice/program/fundamentalrc")
                      .contains(f.newData))
            check("\(label): trust store moved unmodified",
                  readText(f.newData + "/release_trust.json").contains("ada-cli|https://x/"))
            if expectSymlink {
                let target = try? fm.destinationOfSymbolicLink(atPath: f.oldBinary)
                check("\(label): compat symlink old → new binary", target == f.newBinary)
            }
            check("\(label): old bundle retired", !fm.fileExists(atPath: f.oldBundle))
            if f.spec.oldWakelockUnitPath != nil, f.spec.wakelockManaged == true {
                check("\(label): keep-awake unit migrated (new enabled+active, old retired)",
                      fm.fileExists(atPath: f.newWakelockUnit)
                      && !fm.fileExists(atPath: f.oldWakelockUnit)
                      && fm.fileExists(atPath: f.sysd + "/briglia-keepawake-test.service.enabled")
                      && fm.fileExists(atPath: f.sysd + "/briglia-keepawake-test.service.active")
                      && !fm.fileExists(atPath: f.sysd + "/ada-keepawake-test.service.active"))
            }
            check("\(label): journal area fully cleaned up",
                  !fm.fileExists(atPath: f.stateDir))
            let probeRuns = readText(f.probeLog).split(separator: "\n").count
            check("\(label): health probe ran before AND after commit", probeRuns >= 2,
                  "probe runs: \(probeRuns)")
        }

        // ============================================================
        print("— spec validation and helpers —")

        do {
            var bad = try makeFixture("val").spec
            bad.stateDir = bad.oldDataRoot + "/state"
            check("spec validation: journal inside a root refused",
                  MigrationEngine.validateSpec(bad)?.contains("inside the root") == true)
            var rel = bad
            rel.stateDir = "relative/path"
            check("spec validation: relative path refused",
                  MigrationEngine.validateSpec(rel) != nil)
            var same = try makeFixture("val2").spec
            same.newDataRoot = same.oldDataRoot
            check("spec validation: identical old/new root refused",
                  MigrationEngine.validateSpec(same)?.contains("same path") == true)
        }

        do {
            let dir = MigrationEngine.defaultStateDir(
                name: "briglia-migrate", environment: ["XDG_STATE_HOME": "/tmp/xdgstate"])
            check("defaultStateDir honors XDG_STATE_HOME",
                  dir.path == "/tmp/xdgstate/briglia-migrate")
            let fallback = MigrationEngine.defaultStateDir(name: "briglia-migrate",
                                                           environment: [:])
            check("defaultStateDir falls back to ~/.local/state",
                  fallback.path.hasSuffix("/.local/state/briglia-migrate"))
        }

        // ============================================================
        print("\n— fresh-install no-op and read-only detection —")

        do {
            let fixture = try makeFixture("noop", units: false)
            // Remove the old roots entirely: fresh install.
            for path in [fixture.oldConfig, fixture.oldData, fixture.oldLanding] {
                try fm.removeItem(atPath: path)
            }
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture)
            check("fresh install: no-op success", result.code == 0
                  && result.output.contains("nothing to migrate"), result.output)
            // The cross-process lock sibling is the one documented artifact
            // of any engine invocation; the journal area must not appear.
            check("fresh install: zero writes (no journal area created)",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty
                  && !fm.fileExists(atPath: fixture.stateDir))
        }

        do {
            let fixture = try makeFixture("detect", units: false)
            let before = snapshot([fixture.root])
            let detect = runEngine(fixture, args: ["--detect"])
            check("detection: reports old roots, no journal",
                  detect.code == 0 && detect.output.contains("old=3")
                  && detect.output.contains("journal=none"), detect.output)
            let doctor = runEngine(fixture, args: ["--doctor"])
            check("doctor: no journal ⇒ no migration report",
                  doctor.code == 0 && doctor.output.contains("no migration journal"))
            check("detection and doctor are strictly read-only",
                  snapshotDiff(before, snapshot([fixture.root])).isEmpty)
        }

        // ============================================================
        print("\n— full fixture migration (units + prefs + symlink) —")

        let seededPrefs: [String: Any] = ["privacyMode": "strict", "spendCents": 4200]
        do {
            let fixture = try makeFixture("full", wakelock: true, prefs: true)
            defer { killHolders(fixture) }
            let oldDomain = fixture.spec.oldPrefsDomain!
            let newDomain = fixture.spec.newPrefsDomain!
            defer {
                TestPrefsDomains.purge(oldDomain)
                TestPrefsDomains.purge(newDomain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(seededPrefs, forName: oldDomain)
            UserDefaults.standard.synchronize()

            let result = runEngine(fixture)
            check("full migration succeeds", result.code == 0
                  && result.output.contains("MIGRATE-OUTCOME: ok"), result.output)
            assertMigratedState(fixture, label: "full")
            check("full: new unit installed, enabled, started",
                  fm.fileExists(atPath: fixture.newUnit)
                  && fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.enabled")
                  && fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.active"))
            check("full: old unit file retired",
                  !fm.fileExists(atPath: fixture.oldUnit))
            let log = readText(fixture.sysd + "/log")
            check("full: managed old service stopped before the move, disabled at retirement",
                  log.contains("stop ada-test.service") && log.contains("disable ada-test.service"))
            let newPrefs = dumpPrefs(newDomain)
            check("full: preferences domain copied",
                  newPrefs.contains("strict") && newPrefs.contains("4200"), newPrefs)
            check("full: old preferences domain removed at retirement",
                  dumpPrefs(oldDomain) == "{}", dumpPrefs(oldDomain))
            let leftovers = (fm.enumerator(atPath: fixture.root)?.allObjects as? [String] ?? [])
                .filter { $0.contains(".migrate-tmp-") || $0.contains(".durable-") }
            check("full: no leftover staging temp files", leftovers.isEmpty,
                  leftovers.joined(separator: ", "))
        }

        // ============================================================
        print("\n— persona exact-match rule —")

        // Fixture names must differ beyond letter case — macOS filesystems
        // are case-insensitive and "persona-ada"/"persona-Ada" would collide.
        for (slug, persona, expectKept) in [("custom", "Marvin", true),
                                            ("lowercase", "ada", true),
                                            ("exact", "Ada", false)] {
            let fixture = try makeFixture("persona-\(slug)", units: false, persona: persona)
            defer { killHolders(fixture) }
            let result = runEngine(fixture)
            check("persona \"\(persona)\": migration succeeds", result.code == 0, result.output)
            let secrets = readText(fixture.newConfig + "/secrets.json")
            if expectKept {
                check("persona \"\(persona)\": custom/variant name preserved verbatim",
                      secrets.contains("\"\(persona)\"") && !secrets.contains("\"Bree\""))
            } else {
                check("persona \"Ada\": rewritten to Bree", secrets.contains("\"Bree\""))
            }
        }

        // ============================================================
        print("\n— service-state matrix —")

        struct UnitCase {
            let name: String
            let enabled: Bool
            let active: Bool
        }
        for unitCase in [UnitCase(name: "installed-only", enabled: false, active: false),
                         UnitCase(name: "enabled-inactive", enabled: true, active: false),
                         UnitCase(name: "active-but-disabled", enabled: false, active: true)] {
            let fixture = try makeFixture("unit-\(unitCase.name)",
                                          unitEnabled: unitCase.enabled,
                                          unitActive: unitCase.active)
            defer { killHolders(fixture) }
            let result = runEngine(fixture)
            check("unit \(unitCase.name): migration succeeds", result.code == 0, result.output)
            let enabled = fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.enabled")
            let active = fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.active")
            check("unit \(unitCase.name): flags recreated independently (enabled=\(unitCase.enabled), active=\(unitCase.active))",
                  fm.fileExists(atPath: fixture.newUnit)
                  && enabled == unitCase.enabled && active == unitCase.active,
                  "got enabled=\(enabled) active=\(active)")
        }
        do {
            let fixture = try makeFixture("unit-none", units: false)
            defer { killHolders(fixture) }
            let result = runEngine(fixture)
            check("no unit installed: migration succeeds without creating one",
                  result.code == 0 && !fm.fileExists(atPath: fixture.newUnit))
        }

        do {
            // Optional roots may legitimately be absent (no landing zone yet).
            let fixture = try makeFixture("no-landing", units: false)
            try fm.removeItem(atPath: fixture.oldLanding)
            let result = runEngine(fixture)
            check("absent optional root: migration succeeds, nothing invented",
                  result.code == 0 && !fm.fileExists(atPath: fixture.newLanding)
                  && fm.fileExists(atPath: fixture.newData), result.output)
        }

        // ============================================================
        print("\n— refusals (nothing changed, service restored) —")

        do {
            let fixture = try makeFixture("refuse-lock")
            let before = snapshot(fixture.restoreRoots)
            // Hold the old instance lock ourselves: an "unmanaged" process.
            let fd = open(fixture.oldData + "/instance.lock", O_RDWR)
            check("refusal fixture: lock openable", fd >= 0)
            _ = flock(fd, LOCK_EX | LOCK_NB)
            let result = runEngine(fixture)
            flock(fd, LOCK_UN); close(fd)
            check("unmanaged lock holder: refused", result.code == 2
                  && result.output.contains("unmanaged"), result.output)
            check("unmanaged lock holder: fixture untouched",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
            let log = readText(fixture.sysd + "/log")
            check("unmanaged lock holder: managed service stopped, then restarted",
                  log.contains("stop ada-test.service") && log.contains("start ada-test.service"))
            check("unmanaged lock holder: no journal left behind",
                  !fm.fileExists(atPath: fixture.stateDir))
        }

        do {
            let fixture = try makeFixture("refuse-upgrade", units: false)
            try writeFile(fixture.binDir + "/.ada-upgrade-staged-bin", "staged")
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture)
            check("in-flight upgrade markers: refused", result.code == 2
                  && result.output.contains("upgrade"), result.output)
            check("in-flight upgrade markers: fixture untouched",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
        }

        do {
            let fixture = try makeFixture("refuse-newroot", units: false)
            try writeFile(fixture.newData + "/foreign.txt", "someone else's data")
            let before = snapshot(fixture.restoreRoots + [fixture.newData])
            let result = runEngine(fixture)
            check("new root already present without a journal: refused (never blind-overwrite)",
                  result.code == 2 && result.output.contains("already exists"), result.output)
            check("new root present: nothing touched",
                  snapshotDiff(before, snapshot(fixture.restoreRoots + [fixture.newData])).isEmpty)
        }

        do {
            let fixture = try makeFixture("refuse-nobinary", units: false)
            try fm.removeItem(atPath: fixture.newBinary)
            let result = runEngine(fixture)
            check("missing new binary: refused", result.code == 2
                  && result.output.contains("not installed"), result.output)
        }

        // ============================================================
        print("\n— journal corruption refusal —")

        do {
            // Produce a real mid-flight journal via an injected crash.
            let fixture = try makeFixture("corrupt", units: false)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "between-root-moves"])
            check("corruption fixture: crash injected", crashed.code == 137, crashed.output)
            let journalPath = fixture.stateDir + "/journal.json"
            let original = readText(journalPath)
            check("corruption fixture: journal exists", original.contains("\"state\""))

            // Tampering goes through parsed JSON, never text substitution —
            // pretty-print formatting differs between Darwin and corelibs.
            func expectCorrupt(_ label: String, needle: String,
                               _ tamper: (inout [String: Any]) -> Void) throws {
                if label == "garbage journal" {
                    try "this is not json{{{".write(toFile: journalPath, atomically: true,
                                                    encoding: .utf8)
                } else {
                    var object = try JSONSerialization.jsonObject(
                        with: Data(original.utf8)) as! [String: Any]
                    tamper(&object)
                    try JSONSerialization.data(withJSONObject: object)
                        .write(to: URL(fileURLWithPath: journalPath))
                }
                let before = snapshot(fixture.restoreRoots + [fixture.newConfig, fixture.newData])
                let result = runEngine(fixture)
                check("\(label): refused as corrupt", result.code == 3
                      && result.output.contains(needle), result.output)
                check("\(label): zero mutations",
                      snapshotDiff(before,
                                   snapshot(fixture.restoreRoots + [fixture.newConfig, fixture.newData])).isEmpty)
            }
            try expectCorrupt("garbage journal", needle: "not parseable") { _ in }
            try expectCorrupt("unknown schema", needle: "unknown schema") {
                $0["schema"] = 99
            }
            try expectCorrupt("foreign preimage path", needle: "outside the expected locations") {
                $0["preimages"] = [["id": "evil", "type": "file",
                                    "path": "/etc/passwd", "sha256": "00"]]
            }
            try expectCorrupt("absent entry naming a whole allowed directory",
                              needle: "outside the expected locations") {
                $0["preimages"] = [["id": "evil2", "type": "absent",
                                    "path": fixture.binDir]]
            }
            try expectCorrupt("parked asset with a substituted target",
                              needle: "unexpected parked asset") {
                $0["parked"] = [["id": "binary", "kind": "file",
                                 "originalPath": fixture.binDir + "/other-file",
                                 "sha256": "00"]]
            }
            try expectCorrupt("file preimage without a hash", needle: "without a hash") {
                $0["preimages"] = [["id": "pre-0000", "type": "file",
                                    "path": fixture.oldConfig + "/secrets.json"]]
            }
            try expectCorrupt("preimage id with path traversal", needle: "invalid preimage id") {
                $0["preimages"] = [["id": "../evil", "type": "file",
                                    "path": fixture.oldConfig + "/secrets.json",
                                    "sha256": "00"]]
            }
            try expectCorrupt("duplicate preimage ids", needle: "duplicate preimage id") {
                $0["preimages"] = [
                    ["id": "pre-0000", "type": "absent", "path": fixture.oldConfig + "/a"],
                    ["id": "pre-0000", "type": "absent", "path": fixture.oldConfig + "/b"]]
            }
            try expectCorrupt("truncated roots array", needle: "roots where the spec defines") {
                var roots = $0["roots"] as! [[String: Any]]
                roots.removeLast()
                $0["roots"] = roots
            }
            // Spec mismatch: same journal, different invoking spec.
            try original.write(toFile: journalPath, atomically: true, encoding: .utf8)
            var mismatched = fixture.spec
            mismatched.personaNewName = "Zed"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(mismatched).write(to: URL(fileURLWithPath: fixture.specPath))
            let result = runEngine(fixture)
            check("spec mismatch vs journal: refused as corrupt",
                  result.code == 3 && result.output.contains("different spec"), result.output)
            // Restore the real spec and finish this fixture forward so
            // nothing lingers half-moved.
            try encoder.encode(fixture.spec).write(to: URL(fileURLWithPath: fixture.specPath))
            _ = runEngine(fixture)
        }

        // ============================================================
        print("\n— doctor with a live journal (read-only) —")

        do {
            let fixture = try makeFixture("doctor", units: false)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-moved"])
            check("doctor fixture: crash injected", crashed.code == 137)
            let before = snapshot([fixture.root])
            let doctor = runEngine(fixture, args: ["--doctor"])
            check("doctor reports the journal state and the recovery command",
                  doctor.code == 0 && doctor.output.contains("moved")
                  && doctor.output.contains("migrate-test"), doctor.output)
            let detect = runEngine(fixture, args: ["--detect"])
            check("detection reports the in-flight journal",
                  detect.output.contains("journal=moved"), detect.output)
            check("doctor and detection made zero writes",
                  snapshotDiff(before, snapshot([fixture.root])).isEmpty)
            _ = runEngine(fixture)   // finish forward
            killHolders(fixture)
        }

        // ============================================================
        print("\n— crash matrix: forward recovery after every destructive sub-step —")

        let forwardPoints = ["after-prepared", "after-root-rename", "between-root-moves", "after-moved",
                             "mid-fixups", "after-fixups", "after-new-install-ready", "after-committing-marker",
                             "after-unit-retirement", "after-wakelock-retirement",
                             "after-binary-park", "after-bundle-park", "after-symlink",
                             "after-committed", "during-post-verify"]
        for point in forwardPoints {
            let fixture = try makeFixture("fwd-\(point)", wakelock: true)
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": point])
            check("crash@\(point): child died at the injected point",
                  crashed.code == 137, "exit \(crashed.code): \(crashed.output)")
            let recovered = runEngine(fixture)
            check("crash@\(point): forward recovery succeeds", recovered.code == 0,
                  recovered.output)
            assertMigratedState(fixture, label: "crash@\(point)")
        }

        // ============================================================
        print("\n— crash matrix: explicit rollback before the commit point —")

        for point in ["after-root-rename", "between-root-moves", "after-moved", "mid-fixups",
                      "after-fixups"] {
            let fixture = try makeFixture("rb-\(point)", wakelock: true,
                                          prefs: point == "after-fixups")
            defer { killHolders(fixture) }
            var oldDomain = "", newDomain = ""
            if let od = fixture.spec.oldPrefsDomain, let nd = fixture.spec.newPrefsDomain {
                oldDomain = od; newDomain = nd
                UserDefaults.standard.setPersistentDomain(seededPrefs, forName: od)
                UserDefaults.standard.synchronize()
            }
            defer {
                if !oldDomain.isEmpty {
                    TestPrefsDomains.purge(oldDomain)
                    TestPrefsDomains.purge(newDomain)
                    UserDefaults.standard.synchronize()
                }
            }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": point])
            check("rollback@\(point): child died at the injected point", crashed.code == 137)
            let rolled = runEngine(fixture, args: ["--rollback"])
            check("rollback@\(point): rollback recovery succeeds", rolled.code == 0,
                  rolled.output)
            let diffs = snapshotDiff(before, snapshot(fixture.restoreRoots))
            check("rollback@\(point): BYTE-IDENTICAL restore (content, modes, symlinks)",
                  diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
            check("rollback@\(point): new roots and journal fully removed",
                  !fm.fileExists(atPath: fixture.newConfig)
                  && !fm.fileExists(atPath: fixture.newData)
                  && !fm.fileExists(atPath: fixture.stateDir))
            let oldRun = MigrationEngine.runBounded([fixture.oldBinary], timeout: 15)
            check("rollback@\(point): the old binary runs against the restored roots",
                  oldRun.exitCode == 0 && oldRun.output.contains("old-ada"), oldRun.output)
            let toolRun = MigrationEngine.runBounded([fixture.binDir + "/faketool"], timeout: 15)
            check("rollback@\(point): restored toolchain wrapper probe passes",
                  toolRun.exitCode == 0 && toolRun.output.contains("faketool"), toolRun.output)
            if !oldDomain.isEmpty {
                check("rollback@\(point): old prefs domain intact, created new domain deleted",
                      dumpPrefs(oldDomain).contains("strict") && dumpPrefs(newDomain) == "{}",
                      "old=\(dumpPrefs(oldDomain)) new=\(dumpPrefs(newDomain))")
            }
            if fixture.spec.oldUnitName != nil {
                let log = readText(fixture.sysd + "/log")
                check("rollback@\(point): old service restarted per captured topology",
                      log.contains("start ada-test.service")
                      && fm.fileExists(atPath: fixture.sysd + "/ada-test.service.active"))
            }
        }

        // ============================================================
        print("\n— commit-phase failure ⇒ automatic rollback —")

        do {
            let fixture = try makeFixture("probe-fail", probeFails: true)
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture)
            check("health-probe failure: migration fails and rolls back",
                  result.code == 1 && result.output.contains("health probe"), result.output)
            check("health-probe failure: byte-identical restore",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
            check("health-probe failure: no new unit left, old service active again",
                  !fm.fileExists(atPath: fixture.newUnit)
                  && !fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.active")
                  && fm.fileExists(atPath: fixture.sysd + "/ada-test.service.active"))
        }

        do {
            let fixture = try makeFixture("enable-fail")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture, env: ["FAKE_SYSTEMCTL_FAIL_ENABLE": "1"])
            check("unit-enable failure (privileges analog): fails and rolls back",
                  result.code == 1 && result.output.contains("enable"), result.output)
            check("unit-enable failure: byte-identical restore",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
        }

        // ============================================================
        print("\n— park-restoring rollback (forward impossible, parked verify) —")

        do {
            let fixture = try makeFixture("park-restore", wakelock: true, prefs: true)
            defer { killHolders(fixture) }
            let oldDomain = fixture.spec.oldPrefsDomain!
            let newDomain = fixture.spec.newPrefsDomain!
            defer {
                TestPrefsDomains.purge(oldDomain)
                TestPrefsDomains.purge(newDomain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(seededPrefs, forName: oldDomain)
            UserDefaults.standard.synchronize()
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-binary-park"])
            check("park-restore: crash injected after binary parking", crashed.code == 137)
            // Make forward completion impossible: destroy the new binary.
            try fm.removeItem(atPath: fixture.newBinary)
            let result = runEngine(fixture)
            check("park-restore: recovery reports the defined park-restoring rollback",
                  result.code == 1 && result.output.contains("restored byte-identically"),
                  result.output)
            // The new binary was destroyed by the test itself; restore it for
            // the snapshot comparison (it lives in binDir).
            try writeScript(fixture.newBinary, "#!/bin/sh\necho new-briglia\n")
            let diffs = snapshotDiff(before, snapshot(fixture.restoreRoots))
            check("park-restore: BYTE-IDENTICAL restore incl. parked binary/unit/bundle",
                  diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
            check("park-restore: old prefs domain re-imported, new domain deleted",
                  dumpPrefs(oldDomain).contains("strict") && dumpPrefs(newDomain) == "{}",
                  "old=\(dumpPrefs(oldDomain)) new=\(dumpPrefs(newDomain))")
            let oldRun = MigrationEngine.runBounded([fixture.oldBinary], timeout: 15)
            check("park-restore: the restored old binary runs", oldRun.exitCode == 0)
            check("park-restore: old unit re-enabled per captured flags",
                  fm.fileExists(atPath: fixture.sysd + "/ada-test.service.enabled"))
            check("park-restore: old keep-awake unit re-armed (enabled + active)",
                  fm.fileExists(atPath: fixture.sysd + "/ada-keepawake-test.service.enabled")
                  && fm.fileExists(atPath: fixture.sysd + "/ada-keepawake-test.service.active")
                  && fm.fileExists(atPath: fixture.oldWakelockUnit))
        }

        do {
            let fixture = try makeFixture("park-corrupt")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-binary-park"])
            check("park-corrupt: crash injected", crashed.code == 137)
            try fm.removeItem(atPath: fixture.newBinary)
            // Corrupt the parked binary: rollback must be refused, everything held.
            let parkedBinary = fixture.stateDir + "/parked/binary"
            check("park-corrupt: parked binary exists", fm.fileExists(atPath: parkedBinary))
            try "tampered".write(toFile: parkedBinary, atomically: true, encoding: .utf8)
            let result = runEngine(fixture)
            check("park-corrupt: recovery refuses (no restore from unverified assets), holds all",
                  result.code == 1 && result.output.contains("do not verify"), result.output)
            check("park-corrupt: journal and parked assets left in place",
                  fm.fileExists(atPath: fixture.stateDir + "/journal.json")
                  && fm.fileExists(atPath: parkedBinary))
        }

        // ============================================================
        print("\n— verification-before-cleanup at committed/done —")

        do {
            let fixture = try makeFixture("verify-hold")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-committed"])
            check("verify-hold: crash injected after the committed marker", crashed.code == 137)
            // Break verification: the moved data root disappears.
            try fm.moveItem(atPath: fixture.newData, toPath: fixture.root + "/hidden-data")
            let held = runEngine(fixture)
            check("verify-hold: committed journal reruns verification, FAILS, cleans nothing",
                  held.code == 1 && held.output.contains("post-commit verification failed")
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json")
                  && fm.fileExists(atPath: fixture.stateDir + "/parked"), held.output)
            // Repair and re-run: verification passes, cleanup completes.
            try fm.moveItem(atPath: fixture.root + "/hidden-data", toPath: fixture.newData)
            let done = runEngine(fixture)
            check("verify-hold: after repair, re-verification passes and cleanup finishes",
                  done.code == 0 && !fm.fileExists(atPath: fixture.stateDir), done.output)
        }

        do {
            let fixture = try makeFixture("rollback-past-commit")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture,
                                    env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-committing-marker"])
            check("past-commit: crash injected at the committing marker", crashed.code == 137)
            let refused = runEngine(fixture, args: ["--rollback"])
            check("past-commit: explicit rollback is refused at ≥ committing",
                  refused.code == 2 && refused.output.contains("commit point"), refused.output)
            let forward = runEngine(fixture)
            check("past-commit: forward recovery then completes", forward.code == 0,
                  forward.output)
            assertMigratedState(fixture, label: "past-commit")
        }

        // ============================================================
        print("\n— §4.6 identity verification: symlink binary + foreign binary —")

        do {
            let fixture = try makeFixture("symlink-binary", binaryIsSymlink: true)
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-binary-park"])
            check("symlink binary: crash injected after parking", crashed.code == 137)
            try fm.removeItem(atPath: fixture.newBinary)
            let result = runEngine(fixture)
            check("symlink binary: park-restoring rollback runs", result.code == 1,
                  result.output)
            var st = stat()
            let isLink = lstat(fixture.oldBinary, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
            let target = try? fm.destinationOfSymbolicLink(atPath: fixture.oldBinary)
            check("symlink binary: restored AS A SYMLINK with its original target",
                  isLink && target == fixture.binDir + "/real-ada", target ?? "nil")
        }

        do {
            let fixture = try makeFixture("foreign-binary")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture,
                                    env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-committing-marker"])
            check("foreign binary: crash injected before binary parking", crashed.code == 137)
            // Someone replaces the binary between the crash and recovery.
            try writeScript(fixture.oldBinary, "#!/bin/sh\necho impostor\n")
            let result = runEngine(fixture)
            check("foreign binary: forward recovery still succeeds", result.code == 0,
                  result.output)
            check("foreign binary: warned, left untouched, NO symlink created",
                  result.output.contains("does not match")
                  && readText(fixture.oldBinary).contains("impostor")
                  && (try? fm.destinationOfSymbolicLink(atPath: fixture.oldBinary)) == nil)
            assertMigratedState(fixture, label: "foreign-binary", expectSymlink: false)
        }

        // ============================================================
        print("\n— hardening round: lock, honest rollback, destination state, wakelock privileges —")

        do {
            // Concurrent migrate/recovery refused by the sibling flock.
            let fixture = try makeFixture("lock-conflict", units: false)
            try fm.createDirectory(atPath: (fixture.stateDir as NSString)
                .deletingLastPathComponent, withIntermediateDirectories: true)
            let lockPath = fixture.stateDir + ".lock"
            let fd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
            check("lock fixture: sibling lock openable", fd >= 0)
            _ = flock(fd, LOCK_EX | LOCK_NB)
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture)
            flock(fd, LOCK_UN); close(fd)
            check("concurrent migration: refused while the lock is held",
                  result.code == 2 && result.output.contains("already running"), result.output)
            check("concurrent migration: nothing touched",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
            let retry = runEngine(fixture)
            check("after the lock is released, migration proceeds", retry.code == 0, retry.output)
        }

        do {
            // Rollback must not report success when the old service cannot
            // be restarted: journal preserved, retry completes honestly.
            let fixture = try makeFixture("rollback-honesty")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-fixups"])
            check("rollback-honesty: crash injected", crashed.code == 137)
            let failed = runEngine(fixture, args: ["--rollback"],
                                   env: ["FAKE_SYSTEMCTL_FAIL_START": "1"])
            check("rollback-honesty: failed service restart surfaces as FAILURE, journal kept",
                  failed.code == 1 && failed.output.contains("journal")
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json"), failed.output)
            let retried = runEngine(fixture, args: ["--rollback"])
            check("rollback-honesty: retry completes the rollback", retried.code == 0,
                  retried.output)
            check("rollback-honesty: byte-identical restore after the retry",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
            check("rollback-honesty: old service active again",
                  fm.fileExists(atPath: fixture.sysd + "/ada-test.service.active"))
        }

        do {
            // A new root existing WITHOUT its old counterpart must refuse
            // (unrelated destination data must never be mixed in).
            let fixture = try makeFixture("refuse-orphan-newroot", units: false)
            try fm.removeItem(atPath: fixture.oldData)
            try writeFile(fixture.newData + "/foreign.txt", "not ours")
            let result = runEngine(fixture)
            check("orphan new root (old side missing): refused",
                  result.code == 2 && result.output.contains("already exists"), result.output)
            check("orphan new root: foreign data untouched",
                  readText(fixture.newData + "/foreign.txt") == "not ours")
        }

        do {
            // A pre-existing NEW preferences domain refuses — it was not
            // created by a migration and rollback bookkeeping would
            // otherwise delete it.
            let fixture = try makeFixture("refuse-prefs", units: false, prefs: true)
            let newDomain = fixture.spec.newPrefsDomain!
            defer {
                TestPrefsDomains.purge(newDomain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(["pre": "existing"], forName: newDomain)
            UserDefaults.standard.synchronize()
            let result = runEngine(fixture)
            check("pre-existing new prefs domain: refused",
                  result.code == 2 && result.output.contains("preferences domain"), result.output)
            check("pre-existing new prefs domain: its data survives",
                  dumpPrefs(newDomain).contains("existing"))
        }

        do {
            // Unprivileged wakelock: captured and warned about, never touched.
            let fixture = try makeFixture("wakelock-unmanaged", wakelock: true,
                                          wakelockManaged: false)
            defer { killHolders(fixture) }
            let wakelockBytes = sha(fixture.oldWakelockUnit)
            let result = runEngine(fixture)
            check("unprivileged wakelock: migration succeeds with a warning",
                  result.code == 0 && result.output.contains("no privileges"), result.output)
            check("unprivileged wakelock: old unit file untouched, no new unit created",
                  sha(fixture.oldWakelockUnit) == wakelockBytes
                  && !fm.fileExists(atPath: fixture.newWakelockUnit)
                  && fm.fileExists(atPath: fixture.sysd + "/ada-keepawake-test.service.active"))
        }

        // ============================================================
        print("\n— round 2: honest refusals, broken systemctl, retry idempotency, durability faults —")

        do {
            // Pre-move restart failure must be REPORTED, not hidden behind
            // "the installation is untouched".
            let fixture = try makeFixture("restart-honesty")
            let fd = open(fixture.oldData + "/instance.lock", O_RDWR)
            _ = flock(fd, LOCK_EX | LOCK_NB)
            let result = runEngine(fixture, env: ["FAKE_SYSTEMCTL_FAIL_START": "1"])
            flock(fd, LOCK_UN); close(fd)
            check("pre-move restart failure: refusal names the failed restart",
                  result.code == 2 && result.output.contains("could NOT be restarted"),
                  result.output)
        }

        do {
            // Broken systemctl queries refuse at capture — never recorded
            // as "inactive/disabled".
            let fixture = try makeFixture("broken-query")
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture, env: ["FAKE_SYSTEMCTL_BREAK_QUERY": "1"])
            check("broken is-active/is-enabled: refused at capture",
                  result.code == 2 && result.output.contains("cannot capture the service state"),
                  result.output)
            check("broken query: nothing changed, no journal left",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty
                  && !fm.fileExists(atPath: fixture.stateDir))
        }

        do {
            // Retry idempotency against real systemd semantics: the first
            // rollback (triggered by a failed probe) deletes the new unit
            // file, then fails restarting the old service; the retry must
            // NOT trip over stop/disable of the now-unloaded new unit
            // (which the fake, like real systemctl, rejects with exit 5).
            let fixture = try makeFixture("retry-unloaded-unit", probeFails: true)
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let failed = runEngine(fixture,
                                   env: ["FAKE_SYSTEMCTL_FAIL_START_UNIT": "ada-test.service"])
            check("retry-unloaded: first rollback fails at the old-service restart, journal kept",
                  failed.code == 1
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json"), failed.output)
            let retried = runEngine(fixture, args: ["--rollback"])
            if retried.code != 0 {
                note("sysd log: " + readText(fixture.sysd + "/log")
                    .replacingOccurrences(of: "\n", with: " | "))
                let lsof = MigrationEngine.runBounded(
                    ["/usr/sbin/lsof", fixture.oldData + "/instance.lock"], timeout: 20)
                note("lsof: " + lsof.output.replacingOccurrences(of: "\n", with: " | "))
                let ps = MigrationEngine.runBounded(["/bin/ps", "ax"], timeout: 20)
                for line in ps.output.split(separator: "\n")
                    where line.contains("lockholder") && line.contains("retry-unloaded") {
                    note("ps: \(line)")
                }
            }
            check("retry-unloaded: retry skips the unloaded new unit and completes",
                  retried.code == 0, retried.output)
            check("retry-unloaded: byte-identical restore, old service active",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty
                  && fm.fileExists(atPath: fixture.sysd + "/ada-test.service.active"))
        }

        do {
            // A rollback whose root move-back cannot be made durable fails
            // honestly and keeps the journal; the retry completes.
            let fixture = try makeFixture("rollback-fsync-fault")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-moved"])
            check("rollback-fsync-fault: crash injected", crashed.code == 137)
            // The fault fires INSIDE fsyncPath for the roots' parent
            // directory — before any real barrier is issued (round 3 #2).
            let faulted = runEngine(fixture, args: ["--rollback"],
                                    env: ["BRIGLIA_MIGRATE_FAULT": "fsync=" + fixture.root + "/xdg-config"])
            check("rollback-fsync-fault: real fsync failure surfaces, journal kept",
                  faulted.code == 1 && faulted.output.contains("not durable")
                  && faulted.output.contains("injected fault")
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json"), faulted.output)
            let retried = runEngine(fixture, args: ["--rollback"])
            check("rollback-fsync-fault: clean retry restores byte-identically",
                  retried.code == 0
                  && snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty,
                  retried.output)
        }

        do {
            // A preferences write that cannot be persisted fails the fixup
            // and the automatic rollback restores everything.
            let fixture = try makeFixture("prefs-sync-fault", units: false, prefs: true)
            let oldDomain = fixture.spec.oldPrefsDomain!
            let newDomain = fixture.spec.newPrefsDomain!
            defer {
                TestPrefsDomains.purge(oldDomain)
                TestPrefsDomains.purge(newDomain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(seededPrefs, forName: oldDomain)
            UserDefaults.standard.synchronize()
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture, env: ["BRIGLIA_MIGRATE_FAULT": "prefs-sync"])
            check("prefs-sync fault: fixup failure rolls back automatically",
                  result.code == 1 && result.output.contains("persisted"), result.output)
            check("prefs-sync fault: byte-identical restore, old domain intact, new domain gone",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty
                  && dumpPrefs(oldDomain).contains("strict")
                  && dumpPrefs(newDomain) == "{}")
        }

        do {
            // Cleanup deletion failures are reported and retried — never
            // silently suppressed.
            let fixture = try makeFixture("cleanup-retry")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-committed"])
            check("cleanup-retry: crash injected after committed", crashed.code == 137,
                  crashed.output)
            let parkedPath = fixture.stateDir + "/parked"
            if getuid() == 0 {
                // Root ignores directory permissions, so the undeletable-dir
                // simulation is impossible here (Linux CI containers run as
                // root); the failure branch is covered by non-root runs.
                note("running as root — skipping the undeletable-parked-dir simulation")
                let finished = runEngine(fixture)
                check("cleanup-retry (root): committed journal re-verifies and cleans up",
                      finished.code == 0 && !fm.fileExists(atPath: fixture.stateDir),
                      finished.output)
            } else {
                // Recovery re-tightens parked/ itself to 0700 (H7.4b), so the
                // undeletable simulation lives one level down: a 0500 child
                // directory with a file inside makes removeItem(parked) fail.
                let stuck = parkedPath + "/stuck"
                try fm.createDirectory(atPath: stuck, withIntermediateDirectories: true)
                fm.createFile(atPath: stuck + "/keep", contents: Data("x".utf8))
                try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuck)
                let held = runEngine(fixture)
                check("cleanup-retry: undeletable parked dir reported, journal retained",
                      held.code == 0 && held.output.contains("could not remove")
                      && fm.fileExists(atPath: fixture.stateDir + "/journal.json"), held.output)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuck)
                let finished = runEngine(fixture)
                check("cleanup-retry: after repair, cleanup completes and the journal is gone",
                      finished.code == 0 && !fm.fileExists(atPath: fixture.stateDir),
                      finished.output)
            }
        }

        // ============================================================
        print("\n— round 3: pre-verified rollback assets, repeated barriers, transitional units —")

        /// First "file"-type preimage recorded in a live journal.
        func firstFilePreimage(_ fixture: Fixture) -> (id: String, path: String)? {
            guard let data = fm.contents(atPath: fixture.stateDir + "/journal.json"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let preimages = object["preimages"] as? [[String: Any]] else { return nil }
            for pre in preimages where pre["type"] as? String == "file" {
                if let id = pre["id"] as? String, let path = pre["path"] as? String {
                    return (id, path)
                }
            }
            return nil
        }
        let rootPairs: (Fixture) -> [(old: String, new: String)] = { f in
            [(f.oldConfig, f.newConfig), (f.oldData, f.newData), (f.oldLanding, f.newLanding)]
        }
        /// Parent directory of the first root currently sitting at its NEW path.
        func firstMovedParent(_ fixture: Fixture) -> String? {
            for pair in rootPairs(fixture)
                where !fm.fileExists(atPath: pair.old) && fm.fileExists(atPath: pair.new) {
                return (pair.old as NSString).deletingLastPathComponent
            }
            return nil
        }
        /// Parent directory of the first root currently back at its OLD path.
        func firstBackParent(_ fixture: Fixture) -> String? {
            for pair in rootPairs(fixture)
                where fm.fileExists(atPath: pair.old) && !fm.fileExists(atPath: pair.new) {
                return (pair.old as NSString).deletingLastPathComponent
            }
            return nil
        }

        preimageCorrupt: do {
            // #1 — a damaged stored preimage is rejected BEFORE rollback
            // modifies anything; the healthy live file is never overwritten.
            let fixture = try makeFixture("preimage-corrupt")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-fixups"])
            check("preimage-corrupt: crash injected after fixups", crashed.code == 137,
                  crashed.output)
            guard let pre = firstFilePreimage(fixture) else {
                check("preimage-corrupt: the journal records a file preimage", false)
                break preimageCorrupt
            }
            let storedPath = fixture.stateDir + "/preimages/" + pre.id
            let journalPath = fixture.stateDir + "/journal.json"
            let originalBytes = fm.contents(atPath: storedPath) ?? Data()
            try Data("tampered preimage".utf8).write(to: URL(fileURLWithPath: storedPath))
            let liveRoots = fixture.restoreRoots + [fixture.newConfig, fixture.newData,
                                                   fixture.newLanding]
            let held = snapshot(liveRoots)
            let journalBefore = sha(journalPath)
            let corrupted = runEngine(fixture, args: ["--rollback"])
            check("preimage-corrupt: rollback refused BEFORE any modification",
                  corrupted.code == 1 && corrupted.output.contains("BEFORE modifying anything")
                  && corrupted.output.contains("does not match its recorded hash"),
                  corrupted.output)
            let diffs = snapshotDiff(held, snapshot(liveRoots))
            check("preimage-corrupt: zero mutations — live file, roots, units untouched",
                  diffs.isEmpty && sha(journalPath) == journalBefore
                  && fm.fileExists(atPath: fixture.newData),
                  diffs.prefix(5).joined(separator: "; "))
            try fm.removeItem(atPath: storedPath)
            let missing = runEngine(fixture, args: ["--rollback"])
            check("preimage-corrupt: a MISSING stored preimage is refused the same way",
                  missing.code == 1 && missing.output.contains("BEFORE modifying anything")
                  && missing.output.contains("missing"), missing.output)
            check("preimage-corrupt: still zero mutations after the second refusal",
                  snapshotDiff(held, snapshot(liveRoots)).isEmpty)
            try originalBytes.write(to: URL(fileURLWithPath: storedPath))
            let restored = runEngine(fixture, args: ["--rollback"])
            check("preimage-corrupt: with the preimage intact again, rollback restores byte-identically",
                  restored.code == 0
                  && snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty,
                  restored.output)
        }

        parkPreimageCorrupt: do {
            // #1 on the park-restoring path: preimages are verified there too,
            // before the parked assets move or any unit is touched.
            let fixture = try makeFixture("park-preimage-corrupt")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-binary-park"])
            check("park-preimage-corrupt: crash injected after binary parking",
                  crashed.code == 137, crashed.output)
            try fm.removeItem(atPath: fixture.newBinary)
            guard let pre = firstFilePreimage(fixture) else {
                check("park-preimage-corrupt: the journal records a file preimage", false)
                break parkPreimageCorrupt
            }
            let storedPath = fixture.stateDir + "/preimages/" + pre.id
            let originalBytes = fm.contents(atPath: storedPath) ?? Data()
            try Data("tampered preimage".utf8).write(to: URL(fileURLWithPath: storedPath))
            let parkedBinary = fixture.stateDir + "/parked/binary"
            let result = runEngine(fixture)
            check("park-preimage-corrupt: park-restoring rollback refused BEFORE any modification",
                  result.code == 1 && result.output.contains("BEFORE modifying anything"),
                  result.output)
            check("park-preimage-corrupt: parked binary still parked, nothing restored",
                  fm.fileExists(atPath: parkedBinary) && !fm.fileExists(atPath: fixture.oldBinary))
            try originalBytes.write(to: URL(fileURLWithPath: storedPath))
            let restored = runEngine(fixture)
            check("park-preimage-corrupt: intact again ⇒ park-restoring rollback completes",
                  restored.code == 1 && restored.output.contains("restored byte-identically")
                  && fm.fileExists(atPath: fixture.oldBinary), restored.output)
        }

        do {
            // #2a — forward reconciliation: a crash between a root's rename
            // and its barriers; recovery must repeat the barriers, and an
            // fsync failure there must surface (with the journal kept).
            let fixture = try makeFixture("reconcile-move-fsync")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-root-rename"])
            check("reconcile-move-fsync: crash injected between rename and barrier",
                  crashed.code == 137, crashed.output)
            let parent = firstMovedParent(fixture) ?? "?"
            let faulted = runEngine(fixture, env: ["BRIGLIA_MIGRATE_FAULT": "fsync=" + parent])
            check("reconcile-move-fsync: the repeated barrier's failure surfaces honestly",
                  faulted.code == 1 && faulted.output.contains("found already done")
                  && faulted.output.contains("not durable"), faulted.output)
            check("reconcile-move-fsync: journal kept (the moved root is NOT stranded)",
                  fm.fileExists(atPath: fixture.stateDir + "/journal.json"))
            let recovered = runEngine(fixture)
            check("reconcile-move-fsync: clean recovery completes forward", recovered.code == 0,
                  recovered.output)
            assertMigratedState(fixture, label: "reconcile-move-fsync")
        }

        do {
            // #2b — rollback reconciliation: a crash between a root's rename
            // BACK and its barriers; the retried rollback finds the root
            // already back and must repeat the barriers.
            let fixture = try makeFixture("reconcile-rollback-fsync")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-moved"])
            check("reconcile-rollback-fsync: crash injected after moved", crashed.code == 137)
            let crashedBack = runEngine(fixture, args: ["--rollback"],
                                        env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-rollback-rename"])
            check("reconcile-rollback-fsync: rollback crashed between rename-back and barrier",
                  crashedBack.code == 137, crashedBack.output)
            let parent = firstBackParent(fixture) ?? "?"
            let faulted = runEngine(fixture, args: ["--rollback"],
                                    env: ["BRIGLIA_MIGRATE_FAULT": "fsync=" + parent])
            check("reconcile-rollback-fsync: repeated barrier failure surfaces, journal kept",
                  faulted.code == 1 && faulted.output.contains("already back")
                  && faulted.output.contains("not durable")
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json"), faulted.output)
            let retried = runEngine(fixture, args: ["--rollback"])
            check("reconcile-rollback-fsync: clean retry restores byte-identically",
                  retried.code == 0
                  && snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty,
                  retried.output)
        }

        do {
            // #2c — parked-asset restore syncs the SOURCE parked/ directory;
            // a failure there surfaces, and the retry (after one asset was
            // already put back) still ends byte-identical — including the
            // binary that had an `absent` compat-symlink record at its path.
            let fixture = try makeFixture("park-restore-fsync")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-symlink"])
            check("park-restore-fsync: crash injected after the compat symlink",
                  crashed.code == 137, crashed.output)
            try fm.removeItem(atPath: fixture.newBinary)
            let faulted = runEngine(fixture,
                                    env: ["BRIGLIA_MIGRATE_FAULT": "fsync=" + fixture.stateDir + "/parked"])
            check("park-restore-fsync: parked/ barrier failure surfaces, journal kept",
                  faulted.code == 1 && faulted.output.contains("not durable")
                  && faulted.output.contains("/parked")
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json"), faulted.output)
            let retried = runEngine(fixture)
            check("park-restore-fsync: retry completes the park-restoring rollback",
                  retried.code == 1 && retried.output.contains("restored byte-identically"),
                  retried.output)
            try writeScript(fixture.newBinary, "#!/bin/sh\necho new-briglia\n")
            let diffs = snapshotDiff(before, snapshot(fixture.restoreRoots))
            check("park-restore-fsync: byte-identical after the retry (restored binary kept)",
                  diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
        }

        do {
            // #3 — a unit in a transitional state is neither running nor
            // stopped: capture waits a bounded time, then REFUSES.
            let fixture = try makeFixture("transitional-stuck")
            let before = snapshot(fixture.restoreRoots)
            try writeFile(fixture.sysd + "/ada-test.service.transitional", "999")
            let result = runEngine(fixture)
            check("transitional-stuck: capture refuses a unit stuck in `activating`",
                  result.code == 2 && result.output.contains("transitional state")
                  && result.output.contains("activating"), result.output)
            check("transitional-stuck: nothing changed, no journal left",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty
                  && !fm.fileExists(atPath: fixture.stateDir))
        }

        do {
            // #3 — a unit that settles within the wait proceeds normally.
            let fixture = try makeFixture("transitional-settles")
            defer { killHolders(fixture) }
            try writeFile(fixture.sysd + "/ada-test.service.transitional", "3")
            let result = runEngine(fixture)
            check("transitional-settles: an `activating` unit that settles is captured as active and migrated",
                  result.code == 0, result.output)
            assertMigratedState(fixture, label: "transitional-settles")
        }

        // ============================================================
        print("\n— round 4: parked assets verified at whichever location holds them —")

        /// Parked entries (id, originalPath, kind) recorded in a live journal.
        func parkedEntries(_ fixture: Fixture) -> [(id: String, path: String, kind: String)] {
            guard let data = fm.contents(atPath: fixture.stateDir + "/journal.json"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parked = object["parked"] as? [[String: Any]] else { return [] }
            return parked.compactMap { entry in
                guard let id = entry["id"] as? String, let path = entry["originalPath"] as? String,
                      let kind = entry["kind"] as? String else { return nil }
                return (id, path, kind)
            }
        }
        func entryExists(_ path: String) -> Bool {
            var st = stat(); return lstat(path, &st) == 0
        }

        restoredCorrupt: do {
            // An asset already put back by an interrupted park-restoring
            // rollback (parked/ copy gone) must be verified AT ITS ORIGINAL
            // PATH; a damaged object there is refused with zero mutations —
            // never accepted as "restored byte-identically".
            let fixture = try makeFixture("restored-corrupt")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-symlink"])
            check("restored-corrupt: crash injected after the compat symlink",
                  crashed.code == 137, crashed.output)
            try fm.removeItem(atPath: fixture.newBinary)
            // Interrupt the park-restoring rollback after its FIRST asset is
            // back at its original path (the parked/ barrier fault).
            let interrupted = runEngine(fixture,
                                        env: ["BRIGLIA_MIGRATE_FAULT": "fsync=" + fixture.stateDir + "/parked"])
            check("restored-corrupt: first restore attempt interrupted after one asset",
                  interrupted.code == 1 && interrupted.output.contains("not durable"),
                  interrupted.output)
            guard let restored = parkedEntries(fixture).first(where: {
                !entryExists(fixture.stateDir + "/parked/" + $0.id) && entryExists($0.path)
            }) else {
                check("restored-corrupt: exactly one asset sits at its original path", false)
                break restoredCorrupt
            }
            note("already-restored asset: \(restored.id) (\(restored.kind))")
            // Damage the already-restored object in a way that changes its
            // recorded hash, remembering how to undo it exactly.
            var undo: () throws -> Void
            if restored.kind == "directory" {
                let extra = restored.path + "/planted.txt"
                try writeFile(extra, "planted")
                undo = { try fm.removeItem(atPath: extra) }
            } else {
                let original = fm.contents(atPath: restored.path) ?? Data()
                let mode = MigrationEngine.fileMode(restored.path) ?? 0o644
                try (original + Data("tampered".utf8)).write(to: URL(fileURLWithPath: restored.path))
                undo = {
                    try original.write(to: URL(fileURLWithPath: restored.path))
                    _ = chmod(restored.path, mode_t(mode))
                }
            }
            let liveRoots = fixture.restoreRoots + [fixture.newConfig, fixture.newData,
                                                   fixture.newLanding, fixture.stateDir + "/parked"]
            let held = snapshot(liveRoots)
            let refused = runEngine(fixture)
            check("restored-corrupt: recovery refuses — damaged already-restored asset named",
                  refused.code == 1 && refused.output.contains("already-restored \(restored.id)")
                  && !refused.output.contains("byte-identically"), refused.output)
            let diffs = snapshotDiff(held, snapshot(liveRoots))
            check("restored-corrupt: zero mutations (roots, parked/, new roots)",
                  diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
            try undo()
            let retried = runEngine(fixture)
            check("restored-corrupt: undamaged again ⇒ park-restoring rollback completes",
                  retried.code == 1 && retried.output.contains("restored byte-identically"),
                  retried.output)
            try writeScript(fixture.newBinary, "#!/bin/sh\necho new-briglia\n")
            let finalDiffs = snapshotDiff(before, snapshot(fixture.restoreRoots))
            check("restored-corrupt: byte-identical in the end", finalDiffs.isEmpty,
                  finalDiffs.prefix(5).joined(separator: "; "))
        }

        do {
            // Both copies present without the expected compat-symlink state:
            // an unrelated object at the original path while the parked copy
            // exists is refused — never overwritten, never accepted.
            let fixture = try makeFixture("dual-copies")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-binary-park"])
            check("dual-copies: crash injected after binary parking", crashed.code == 137,
                  crashed.output)
            try fm.removeItem(atPath: fixture.newBinary)
            try writeScript(fixture.oldBinary, "#!/bin/sh\necho impostor\n")
            let liveRoots = fixture.restoreRoots + [fixture.newConfig, fixture.newData,
                                                   fixture.newLanding, fixture.stateDir + "/parked"]
            let held = snapshot(liveRoots)
            let refused = runEngine(fixture)
            check("dual-copies: recovery refuses an unrelated file beside the parked binary",
                  refused.code == 1 && refused.output.contains("exists BOTH"), refused.output)
            check("dual-copies: zero mutations",
                  snapshotDiff(held, snapshot(liveRoots)).isEmpty
                  && fm.fileExists(atPath: fixture.stateDir + "/parked/binary"))
            try fm.removeItem(atPath: fixture.oldBinary)
            let restored = runEngine(fixture)
            check("dual-copies: impostor removed ⇒ park-restoring rollback completes",
                  restored.code == 1 && restored.output.contains("restored byte-identically"),
                  restored.output)
            try writeScript(fixture.newBinary, "#!/bin/sh\necho new-briglia\n")
            check("dual-copies: byte-identical in the end",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
        }

        do {
            // The compat symlink is the ONE accepted dual state — but only
            // when it points at the new binary. A symlink elsewhere at the
            // binary path is refused like any other foreign object.
            let fixture = try makeFixture("dual-foreign-symlink")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-symlink"])
            check("dual-foreign-symlink: crash injected after the compat symlink",
                  crashed.code == 137, crashed.output)
            try fm.removeItem(atPath: fixture.newBinary)
            try fm.removeItem(atPath: fixture.oldBinary)
            try fm.createSymbolicLink(atPath: fixture.oldBinary, withDestinationPath: "/usr/bin/true")
            let liveRoots = fixture.restoreRoots + [fixture.stateDir + "/parked"]
            let held = snapshot(liveRoots)
            let refused = runEngine(fixture)
            check("dual-foreign-symlink: refused, zero mutations",
                  refused.code == 1 && refused.output.contains("exists BOTH")
                  && snapshotDiff(held, snapshot(liveRoots)).isEmpty, refused.output)
        }

        // ============================================================
        print("\n— preferences persistence path (resolved concretely, both platforms) —")

        do {
            let domain = "ada-mig-probe-\(UUID().uuidString.prefix(8))"
            defer {
                TestPrefsDomains.purge(domain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(["probe": "sentinel"], forName: domain)
            UserDefaults.standard.synchronize()
            let home = fm.homeDirectoryForCurrentUser.path
            let env = ProcessInfo.processInfo.environment
            var candidates = [
                home + "/Library/Preferences/\(domain).plist",
                (env["XDG_CONFIG_HOME"] ?? home + "/.config") + "/\(domain).plist",
                (env["XDG_DATA_HOME"] ?? home + "/.local/share") + "/\(domain).plist",
            ]
            #if os(Linux)
            candidates.append(home + "/.config/\(domain).plist")
            // corelibs resolves `homeDirectoryForCurrentUser` through the
            // passwd entry but persists UserDefaults under $HOME; the two
            // differ on hosted CI containers (HOME=/github/home, passwd
            // /root). Every real install has them equal — the probe must
            // still find the file wherever corelibs actually put it.
            if let envHome = env["HOME"], !envHome.isEmpty, envHome != home {
                candidates += [envHome + "/.config/\(domain).plist",
                               envHome + "/.local/share/\(domain).plist",
                               envHome + "/Library/Preferences/\(domain).plist"]
            }
            #endif
            let found = candidates.first { fm.fileExists(atPath: $0) }
            check("preferences persist to a discoverable per-user plist", found != nil,
                  "checked: \(candidates.joined(separator: ", "))")
            if let found {
                note("preferences path on this platform: \(found)")
                // The plist is a SIBLING file named <domain>.plist — never
                // inside a directory named after the domain — so a root move
                // can never carry it: the mandatory domain copy (§4.5.8) is
                // the correct treatment on this platform.
                check("preferences file lies OUTSIDE any movable root directory",
                      !found.contains("/\(domain)/"))
            }
        }

        // ============================================================
        print("\n— diagnostics no-mutation battery (§4.2, current identity) —")

        do {
            let bat = tempRoot.appendingPathComponent("battery").path
            try writeFile(bat + "/config/ada/secrets.json",
                          "{\"assistant_name\": \"Ada\"}", mode: 0o600)
            try writeFile(bat + "/share/ada/conversation.json", "{\"messages\": []}")
            try fm.createDirectory(atPath: bat + "/home", withIntermediateDirectories: true)
            let env = ["HOME": bat + "/home",
                       "XDG_CONFIG_HOME": bat + "/config",
                       "XDG_DATA_HOME": bat + "/share"]
            for args in [["--version"], ["bundle-check"], ["setup-api", "status"]] {
                let before = snapshot([bat])
                _ = MigrationEngine.runBounded([adaBinary] + args, timeout: 60,
                                               extraEnv: env)
                let after = snapshot([bat])
                let diffs = snapshotDiff(before, after).filter { diff in
                    // Lazily-created EMPTY directories are the one documented
                    // side effect; file creation/modification/deletion is not.
                    !(diff.contains("absent → dir|") )
                }
                check("diagnostic `\(args.joined(separator: " "))`: no file writes, no deletions",
                      diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
            }
        }

        // ============================================================
        // Stage 4 (RENAME_PLAN §4.1/§4.2/§4.4/§4.5/§4.6): the PRODUCTION
        // wiring — this very binary, its real StoragePaths/IdentityMigration
        // spec, the user-facing `migrate` command and the setup-api verb —
        // against a redirected fixture home. Everything above exercised the
        // engine through a synthetic spec; this proves the spec the shipped
        // command actually builds.
        print("\n— Stage 4: production identity wiring (§4.1/§4.2/§4.4/§4.5/§4.6) —")
        do {
            let s4 = tempRoot.appendingPathComponent("stage4").path
            let home = s4 + "/home"
            let cfg = s4 + "/cfg", data = s4 + "/data", state = s4 + "/state"
            let bin = home + "/.local/bin"
            let unitDir = home + "/.config/systemd/user"
            let sysd = s4 + "/sysd"
            for dir in [bin, unitDir, sysd, home + "/Documents/AdaCLI/telegram"] {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            // This build as both the retired `ada` and the new `briglia`,
            // with the resource bundle beside them (bundle-check needs it).
            let newBinary = bin + "/briglia", oldBinary = bin + "/ada"
            try fm.copyItem(atPath: adaBinary, toPath: newBinary)
            try fm.copyItem(atPath: adaBinary, toPath: oldBinary)
            let bundleSrc = (adaBinary as NSString).deletingLastPathComponent + "/" + BundleCheck.bundleName
            if fm.fileExists(atPath: bundleSrc) {
                try fm.copyItem(atPath: bundleSrc, toPath: bin + "/" + BundleCheck.bundleName)
            }
            // The old install: secrets (default persona + a stored token),
            // a watcher whose row embeds an absolute old-root path, the
            // agentmail broker wrapper pinned to the old binary, a userdata
            // toolchain wrapper with the LEGACY marker and old prefix path,
            // an enabled+active old user unit.
            try writeFile(cfg + "/ada/secrets.json",
                          "{\"assistant_name\": \"Ada\", \"telegram_bot_token\": \"tok-keep\"}", mode: 0o600)
            let watcherId = UUID().uuidString
            try writeFile(data + "/ada/reminders.json",
                          "[{\"id\": \"\(watcherId)\", \"scriptPath\": \"\(data)/ada/reminder-scripts/\(watcherId).sh\"}]")
            try writeScript(data + "/ada/reminder-scripts/\(watcherId).sh", "#!/bin/sh\necho hi\n")
            try writeFile(data + "/ada/conversation.json", "{\"messages\": []}")
            try writeScript(bin + "/agentmail-bin", "#!/bin/sh\necho agentmail-bin\n")
            try writeScript(bin + "/agentmail",
                            AgentMailService.legacyWrapperScript(adaPath: oldBinary, realBinaryPath: bin + "/agentmail-bin"))
            try writeScript(bin + "/pdftotext",
                            "#!/bin/sh\n\(UserdataToolchain.legacyWrapperMarker)\nexec \"\(data)/ada/toolchain/prefix/usr/bin/pdftotext\" \"$@\"\n")
            try writeFile(unitDir + "/ada.service",
                          AgentServiceSupport.userUnitText(adaPath: oldBinary, home: home))
            try writeFile(sysd + "/ada.service.enabled", "")
            try writeFile(sysd + "/ada.service.active", "")
            try writeFile(sysd + "/lockholder.py", """
            import fcntl, os, sys, time
            f = open(sys.argv[1], "a+")
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                sys.exit(1)
            with open(sys.argv[2], "w") as p:
                p.write(str(os.getpid()))
            time.sleep(600)
            """)
            // Fake systemctl (state = marker files in sysd; `start` of the
            // new unit holds the NEW instance.lock like a real daemon so the
            // engine's post-start lock check is exercised for real).
            let systemctl = sysd + "/systemctl"
            try writeScript(systemctl, """
            #!/bin/sh
            SD="\(sysd)"
            echo "$@" >> "$SD/log"
            if [ "$1" = "--user" ]; then shift; fi
            verb="$1"; unit="$2"
            loaded=1
            if [ -n "$unit" ] && [ ! -f "\(unitDir)/$unit" ]; then loaded=0; fi
            case "$verb" in
              daemon-reload) exit 0;;
              is-enabled) if [ "$loaded" = 0 ]; then echo "Failed to get unit file state for $unit: No such file or directory"; exit 1; fi
                          if [ -f "$SD/$unit.enabled" ]; then echo enabled; else echo disabled; fi; exit 0;;
              is-active)  if [ -f "$SD/$unit.active" ]; then echo active; else echo inactive; fi; exit 0;;
              enable)  if [ "$loaded" = 0 ]; then echo "Unit $unit not loaded."; exit 5; fi; touch "$SD/$unit.enabled"; exit 0;;
              disable) rm -f "$SD/$unit.enabled"; exit 0;;
              stop)    rm -f "$SD/$unit.active"
                       if [ -f "$SD/$unit.pid" ]; then kill "$(cat "$SD/$unit.pid")" 2>/dev/null; rm -f "$SD/$unit.pid"; fi
                       exit 0;;
              start)   if [ "$loaded" = 0 ]; then echo "Unit $unit not loaded."; exit 5; fi
                       touch "$SD/$unit.active"
                       if [ "$unit" = "briglia.service" ]; then
                         # Like systemd: `start` succeeds even if the service then
                         # exits at once. The daemon it launches runs the startup
                         # gate first — so run exactly that gate (the real binary,
                         # this environment) and hold the instance lock ONLY when
                         # it admits. A lock-holder that cannot refuse is how the
                         # 0.2.0 systemd rollback shipped blind.
                         if "\(newBinary)" __migrate-gate >> "$SD/gate.log" 2>&1; then
                           nohup python3 "$SD/lockholder.py" "\(data)/briglia/instance.lock" "$SD/$unit.pid" >/dev/null 2>&1 &
                         else
                           echo "gate refused (exit $?)" >> "$SD/gate.log"
                         fi
                       fi
                       exit 0;;
            esac
            exit 0
            """)
            // Throwaway preferences domains (never the machine's real ones).
            let tag = UUID().uuidString.prefix(8)
            let oldDomain = "briglia-s4-\(tag)-old", newDomain = "briglia-s4-\(tag)-new"
            #if os(Linux)
            // corelibs persists domains under the PROCESS's home
            // ($HOME/.config/<domain>.plist — resolved concretely above), so
            // the child running under the fixture home sees a different
            // store than this process: seed the fixture's store as files,
            // and read it back through a child (below) — never in-process.
            let seedPlist = try PropertyListSerialization.data(
                fromPropertyList: ["s4": "seeded"], format: .xml, options: 0)
            for dir in [cfg, home + "/.config"] {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try seedPlist.write(to: URL(fileURLWithPath: dir + "/\(oldDomain).plist"))
            }
            #else
            UserDefaults.standard.setPersistentDomain(["s4": "seeded"], forName: oldDomain)
            UserDefaults.standard.synchronize()
            #endif
            defer {
                TestPrefsDomains.purge(oldDomain)
                TestPrefsDomains.purge(newDomain)
                UserDefaults.standard.synchronize()
                if let pid = Int32((try? String(contentsOfFile: sysd + "/briglia.service.pid", encoding: .utf8)) ?? "") {
                    kill(pid, SIGTERM)
                }
            }
            let env: [String: String] = [
                "HOME": home, "XDG_CONFIG_HOME": cfg, "XDG_DATA_HOME": data, "XDG_STATE_HOME": state,
                "BRIGLIA_TOOLCHAIN_BIN": bin,
                "BRIGLIA_MIGRATE_SYSTEMCTL": systemctl,
                "BRIGLIA_MIGRATE_PREFS_DOMAINS": "\(oldDomain):\(newDomain)",
                "PATH": bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
            ]
            func runNew(_ args: [String], extra: [String: String] = [:]) -> MigrationEngine.RunResult {
                MigrationEngine.runBounded([newBinary] + args, timeout: 180,
                                           extraEnv: env.merging(extra) { $1 })
            }
            let watched = [cfg, data, state, unitDir, sysd, home + "/Documents"]
            let binHashBefore = sha(oldBinary) + sha(newBinary)

            // §4.2: diagnostics never migrate, never create the new roots.
            for args in [["--version"], ["bundle-check"], ["doctor"], ["setup-api", "status"],
                         ["migrate", "--status"], ["service", "status"], ["toolchain", "status"]] {
                let before = snapshot(watched)
                let r = runNew(args)
                let diffs = snapshotDiff(before, snapshot(watched))
                check("real identity: diagnostic `\(args.joined(separator: " "))` writes nothing with an old install present",
                      diffs.isEmpty, diffs.prefix(4).joined(separator: "; ") + " | rc=\(r.exitCode) " + r.tail)
            }
            check("real identity: diagnostics materialized no new roots",
                  !fm.fileExists(atPath: cfg + "/briglia") && !fm.fileExists(atPath: data + "/briglia"))
            do {
                let r = runNew(["migrate", "--status"])
                check("real identity: `migrate --status` reports PENDING (exit 3 for the installers)",
                      r.exitCode == 3 && r.output.contains("PENDING") && r.output.contains("briglia migrate"), r.tail)
                let st = runNew(["setup-api", "status"])
                if let obj = try? JSONSerialization.jsonObject(with: Data(st.output.utf8)) as? [String: Any],
                   let migration = obj["migration"] as? [String: Any] {
                    check("real identity: setup-api status schema 2 + migration.needed",
                          obj["schema"] as? Int == 2 && migration["needed"] as? Bool == true
                          && (migration["old_roots_present"] as? [String])?.count == 2
                          && migration["recovery_command"] as? String == "briglia migrate")
                } else {
                    check("real identity: setup-api status is JSON with a migration block", false, st.tail)
                }
            }

            // §4.2: every entry point that would write the new roots refuses
            // with the exact instruction and touches nothing.
            for args in [["chat"], ["daemon"], ["setup"], ["trigger", UUID().uuidString],
                         ["upgrade"], ["toolchain", "install"], ["service", "install"]] {
                let before = snapshot(watched)
                let r = runNew(args)
                let diffs = snapshotDiff(before, snapshot(watched))
                check("real identity: `\(args.joined(separator: " "))` refuses (exit 2) with the migrate instruction, zero writes",
                      r.exitCode == 2 && r.output.contains("Run `briglia migrate`") && diffs.isEmpty,
                      "rc=\(r.exitCode) " + r.tail + (diffs.isEmpty ? "" : " diffs: " + diffs.prefix(3).joined(separator: "; ")))
            }
            do {
                let r = MigrationEngine.runBounded(
                    ["/bin/sh", "-c", "printf '{\"identity\":{\"user_name\":\"x\"}}' | '\(newBinary)' setup-api apply"],
                    timeout: 60, extraEnv: env)
                check("real identity: setup-api apply refuses with code migration_needed",
                      r.output.contains("\"migration_needed\"") && r.output.contains("\"ok\":false"), r.tail)
                let r2 = MigrationEngine.runBounded(
                    ["/bin/sh", "-c", "printf '{\"action\":\"status\"}' | '\(newBinary)' setup-api service"],
                    timeout: 60, extraEnv: env)
                check("real identity: setup-api service refuses with code migration_needed",
                      r2.output.contains("\"migration_needed\""), r2.tail)
                check("real identity: refused API verbs created no new roots",
                      !fm.fileExists(atPath: cfg + "/briglia") && !fm.fileExists(atPath: data + "/briglia"))
            }

            // §4.5.4: legacy variables are named, their values never echoed.
            do {
                let r = runNew(["doctor"], extra: ["ADA_RELEASE_BASE": "hunter2-never-printed"])
                check("legacy env var: doctor names ADA_RELEASE_BASE and its replacement, value withheld",
                      r.output.contains("ADA_RELEASE_BASE is set but no longer read; use BRIGLIA_RELEASE_BASE")
                      && !r.output.contains("hunter2"), r.tail)
            }

            // `--rollback` without an in-flight journal is a refusal, not a
            // forward migration in disguise.
            do {
                let before = snapshot(watched)
                let r = runNew(["migrate", "--rollback"])
                check("real identity: `migrate --rollback` with no journal refuses and writes nothing",
                      r.exitCode == 2 && r.output.contains("nothing to roll back")
                      && snapshotDiff(before, snapshot(watched)).isEmpty, r.tail)
            }

            // Every partial / coexisting root combination (Codex Stage 4
            // round 1): ANY old root closes the gate; old+new together is a
            // CONFLICT — `migrate --status` exits 4, every mutating entry
            // refuses without creating a root, setup-api reports conflict,
            // and `briglia migrate` reaches the engine's pre-existing-
            // destination refusal with zero writes. Old-only combos are a
            // clean pending migration (exit 3) that completes.
            do {
                struct Combo { let oc: Bool, od: Bool, nc: Bool, nd: Bool }
                let combos: [Combo] = [
                    Combo(oc: true,  od: true,  nc: true,  nd: false),
                    Combo(oc: true,  od: true,  nc: false, nd: true),
                    Combo(oc: true,  od: true,  nc: true,  nd: true),
                    Combo(oc: true,  od: false, nc: true,  nd: false),
                    Combo(oc: false, od: true,  nc: false, nd: true),
                    Combo(oc: true,  od: false, nc: false, nd: true),
                    Combo(oc: false, od: true,  nc: true,  nd: false),
                    Combo(oc: true,  od: false, nc: false, nd: false),
                    Combo(oc: false, od: true,  nc: false, nd: false),
                    Combo(oc: false, od: false, nc: true,  nd: true),
                    Combo(oc: false, od: false, nc: false, nd: false),
                ]
                for (index, combo) in combos.enumerated() {
                    let label = "old(cfg:\(combo.oc ? 1 : 0) data:\(combo.od ? 1 : 0)) new(cfg:\(combo.nc ? 1 : 0) data:\(combo.nd ? 1 : 0))"
                    let root = tempRoot.appendingPathComponent("stage4-combo-\(index)").path
                    let cHome = root + "/home", cCfg = root + "/cfg", cData = root + "/data", cState = root + "/state"
                    try fm.createDirectory(atPath: cHome, withIntermediateDirectories: true)
                    if combo.oc { try writeFile(cCfg + "/ada/secrets.json", "{\"assistant_name\": \"Ada\"}", mode: 0o600) }
                    if combo.od { try writeFile(cData + "/ada/conversation.json", "{\"messages\": []}") }
                    if combo.nc { try writeFile(cCfg + "/briglia/foreign.txt", "stray") }
                    if combo.nd { try writeFile(cData + "/briglia/foreign.txt", "stray") }
                    let cEnv: [String: String] = [
                        "HOME": cHome, "XDG_CONFIG_HOME": cCfg, "XDG_DATA_HOME": cData, "XDG_STATE_HOME": cState,
                        "BRIGLIA_TOOLCHAIN_BIN": bin, "BRIGLIA_MIGRATE_PREFS_DOMAINS": "none",
                        "PATH": bin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
                    ]
                    func runC(_ args: [String]) -> MigrationEngine.RunResult {
                        MigrationEngine.runBounded([newBinary] + args, timeout: 180, extraEnv: cEnv)
                    }
                    let oldAny = combo.oc || combo.od, newAny = combo.nc || combo.nd
                    let expectedCode: Int32 = oldAny ? (newAny ? 4 : 3) : 0
                    let st = runC(["migrate", "--status"])
                    check("\(label): `migrate --status` exits \(expectedCode)"
                          + (expectedCode == 4 ? " and says CONFLICT" : expectedCode == 3 ? " and says PENDING" : ""),
                          st.exitCode == expectedCode
                          && (expectedCode != 4 || st.output.contains("CONFLICT"))
                          && (expectedCode != 3 || st.output.contains("PENDING")), "rc=\(st.exitCode) " + st.tail)
                    let api = runC(["setup-api", "status"])
                    if let obj = try? JSONSerialization.jsonObject(with: Data(api.output.utf8)) as? [String: Any],
                       let migration = obj["migration"] as? [String: Any] {
                        check("\(label): setup-api reports needed=\(oldAny) conflict=\(oldAny && newAny)",
                              migration["needed"] as? Bool == oldAny
                              && migration["conflict"] as? Bool == (oldAny && newAny)
                              && (migration["old_roots_present"] as? [String])?.count == (combo.oc ? 1 : 0) + (combo.od ? 1 : 0)
                              && (migration["new_roots_present"] as? [String])?.count == (combo.nc ? 1 : 0) + (combo.nd ? 1 : 0))
                    } else {
                        check("\(label): setup-api status parses", false, api.tail)
                    }
                    let watchedC = [cCfg, cData, cState, cHome]
                    // The health probe must fail on ANY remaining old root —
                    // with or without a new root beside it (Codex round 2) —
                    // and pass only when the new identity serves something.
                    do {
                        let pr = runC([MigrateProbe.configuration.commandName ?? "__migrate-probe"])
                        let expectOK = !oldAny && newAny
                        // The probe reports the FIRST old root it finds (config
                        // before data): the mixed-roots wording is expected only
                        // when that pair has a new root beside it.
                        let samePairMixed = combo.oc ? combo.nc : (combo.od && combo.nd)
                        check("\(label): __migrate-probe \(expectOK ? "passes" : "fails")",
                              (pr.exitCode == 0) == expectOK
                              && (expectOK || pr.output.contains("PROBE-FAIL"))
                              && (!samePairMixed || pr.output.contains("mixed roots")), "rc=\(pr.exitCode) " + pr.tail)
                    }
                    if oldAny {
                        for args in [["trigger", UUID().uuidString], ["chat"], ["setup"]] {
                            let before = snapshot(watchedC)
                            let r = runC(args)
                            let diffs = snapshotDiff(before, snapshot(watchedC))
                            check("\(label): `\(args[0])` refuses (exit 2), creates no root, writes nothing",
                                  r.exitCode == 2 && r.output.contains("briglia migrate") && diffs.isEmpty
                                  && (combo.nc || !fm.fileExists(atPath: cCfg + "/briglia"))
                                  && (combo.nd || !fm.fileExists(atPath: cData + "/briglia")),
                                  "rc=\(r.exitCode) " + r.tail + (diffs.isEmpty ? "" : " diffs: " + diffs.prefix(3).joined(separator: "; ")))
                        }
                    }
                    if oldAny && newAny {
                        let before = snapshot(watchedC)
                        let r = runC(["migrate"])
                        // The engine's cross-process lock is a zero-byte
                        // SIBLING of the (never created) journal dir — the
                        // one documented side effect of asking it.
                        let diffs = snapshotDiff(before, snapshot(watchedC))
                            .filter { !$0.hasPrefix("state/briglia-migrate.lock:") && !$0.hasPrefix("state:") }
                        check("\(label): `briglia migrate` reaches the engine's fail-closed refusal, zero writes, no journal",
                              r.exitCode == 2 && r.output.contains("already exists") && r.output.contains("refused")
                              && diffs.isEmpty && !fm.fileExists(atPath: cState + "/briglia-migrate/journal.json"),
                              "rc=\(r.exitCode) " + r.tail)
                        let d = runC(["doctor"])
                        check("\(label): doctor flags the conflict as a problem with the resolution hint",
                              d.output.contains("CONFLICT") && d.output.contains("move the Briglia directories aside"), d.tail)
                    } else if oldAny {
                        let r = runC(["migrate"])
                        check("\(label): clean pending migration completes",
                              r.exitCode == 0 && r.output.contains("migration committed and verified")
                              && (!combo.oc || (fm.fileExists(atPath: cCfg + "/briglia/secrets.json") && !fm.fileExists(atPath: cCfg + "/ada")))
                              && (!combo.od || (fm.fileExists(atPath: cData + "/briglia/conversation.json") && !fm.fileExists(atPath: cData + "/ada"))),
                              "rc=\(r.exitCode) " + r.tail)
                        let after = runC(["migrate", "--status"])
                        check("\(label): after migrating, `migrate --status` exits 0", after.exitCode == 0, after.tail)
                    } else {
                        let r = runC(["migrate"])
                        check("\(label): nothing to migrate, exit 0", r.exitCode == 0 && r.output.contains("Nothing to migrate"), r.tail)
                    }
                }
            }

            // End-to-end (Codex round 2): if an old root is (re)present when
            // the health probe runs — mixed roots at the worst moment — the
            // probe fails and the engine rolls back: roots restored, Ada's
            // binary/unit untouched (never parked, no compat symlink), no
            // Briglia unit left, no journal. The production spec is taken
            // verbatim from `migrate --dump-spec`; only its probe is wrapped
            // by a script that recreates the old config root first.
            do {
                let e2e = tempRoot.appendingPathComponent("stage4-probe-mixed").path
                let eHome = e2e + "/home", eCfg = e2e + "/cfg", eData = e2e + "/data", eState = e2e + "/state"
                let eBin = eHome + "/.local/bin", eUnitDir = eHome + "/.config/systemd/user", eSysd = e2e + "/sysd"
                for dir in [eBin, eUnitDir, eSysd] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
                let eNew = eBin + "/briglia", eOld = eBin + "/ada"
                try fm.copyItem(atPath: adaBinary, toPath: eNew)
                try fm.copyItem(atPath: adaBinary, toPath: eOld)
                if fm.fileExists(atPath: bundleSrc) {
                    try fm.copyItem(atPath: bundleSrc, toPath: eBin + "/" + BundleCheck.bundleName)
                }
                try writeFile(eCfg + "/ada/secrets.json", "{\"assistant_name\": \"Ada\"}", mode: 0o600)
                try writeFile(eData + "/ada/conversation.json", "{\"messages\": []}")
                try writeFile(eUnitDir + "/ada.service", AgentServiceSupport.userUnitText(adaPath: eOld, home: eHome))
                try writeFile(eSysd + "/ada.service.enabled", "")
                // Reuse the Stage-4 fake systemctl shape, bound to this fixture.
                let eSystemctl = eSysd + "/systemctl"
                try writeScript(eSystemctl, """
                #!/bin/sh
                SD="\(eSysd)"
                echo "$@" >> "$SD/log"
                if [ "$1" = "--user" ]; then shift; fi
                verb="$1"; unit="$2"
                loaded=1
                if [ -n "$unit" ] && [ ! -f "\(eUnitDir)/$unit" ]; then loaded=0; fi
                case "$verb" in
                  daemon-reload) exit 0;;
                  is-enabled) if [ "$loaded" = 0 ]; then echo "Failed to get unit file state for $unit: No such file or directory"; exit 1; fi
                              if [ -f "$SD/$unit.enabled" ]; then echo enabled; else echo disabled; fi; exit 0;;
                  is-active)  if [ -f "$SD/$unit.active" ]; then echo active; else echo inactive; fi; exit 0;;
                  enable)  if [ "$loaded" = 0 ]; then echo "Unit $unit not loaded."; exit 5; fi; touch "$SD/$unit.enabled"; exit 0;;
                  disable) rm -f "$SD/$unit.enabled"; exit 0;;
                  stop)    rm -f "$SD/$unit.active"; exit 0;;
                  start)   if [ "$loaded" = 0 ]; then echo "Unit $unit not loaded."; exit 5; fi; touch "$SD/$unit.active"; exit 0;;
                esac
                exit 0
                """)
                let eEnv: [String: String] = [
                    "HOME": eHome, "XDG_CONFIG_HOME": eCfg, "XDG_DATA_HOME": eData, "XDG_STATE_HOME": eState,
                    "BRIGLIA_TOOLCHAIN_BIN": eBin, "BRIGLIA_MIGRATE_SYSTEMCTL": eSystemctl,
                    "BRIGLIA_MIGRATE_PREFS_DOMAINS": "none",
                    "PATH": eBin + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
                ]
                let dump = MigrationEngine.runBounded([eNew, "migrate", "--dump-spec"], timeout: 60, extraEnv: eEnv)
                var spec = try JSONDecoder().decode(MigrationSpec.self, from: Data(dump.output.utf8))
                check("probe-mixed e2e: `migrate --dump-spec` yields the production spec (probe = __migrate-probe, roots = fixture)",
                      spec.healthProbe == [eNew, "__migrate-probe"] && spec.oldConfigRoot == eCfg + "/ada"
                      && spec.newDataRoot == eData + "/briglia" && spec.oldBinary == eOld, dump.tail)
                let specPath = eSysd + "/spec.json"
                let oldBinHash = sha(eOld)
                var st = stat()
                func adaNotRetired() -> Bool {
                    lstat(eOld, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && sha(eOld) == oldBinHash
                        && fm.fileExists(atPath: eUnitDir + "/ada.service")
                        && !fm.fileExists(atPath: eUnitDir + "/briglia.service")
                        && ((try? fm.contentsOfDirectory(atPath: eState + "/briglia-migrate/parked")) ?? []).isEmpty
                }

                // Variant B first: the foreign old root STAYS after the probe.
                // The probe fails; the engine cannot put the old roots back
                // over a path something else now occupies, so it HOLDS with
                // the journal (never guesses) — Ada is not retired either way.
                let stayer = eSysd + "/probe-old-root-stays.sh"
                try writeScript(stayer, "#!/bin/sh\nmkdir -p '\(eCfg)/ada'\nexec '\(eNew)' __migrate-probe\n")
                spec.healthProbe = [stayer]
                try JSONEncoder().encode(spec).write(to: URL(fileURLWithPath: specPath))
                let held = MigrationEngine.runBounded([eNew, "__migrate-run", "--spec", specPath], timeout: 180, extraEnv: eEnv)
                check("probe-mixed e2e (foreign root stays): the migration FAILS at the health probe with the mixed-roots reason",
                      held.exitCode == 1 && held.output.contains("health probe") && held.output.contains("mixed roots"), "rc=\(held.exitCode) " + held.tail)
                check("probe-mixed e2e (foreign root stays): Ada NOT retired — binary regular + original hash, old unit intact, no Briglia unit, nothing parked",
                      adaNotRetired(), held.tail)
                check("probe-mixed e2e (foreign root stays): engine holds with its journal for recovery rather than guessing",
                      fm.fileExists(atPath: eState + "/briglia-migrate/journal.json"), held.tail)
                let stHeld = MigrationEngine.runBounded([eNew, "migrate", "--status"], timeout: 60, extraEnv: eEnv)
                check("probe-mixed e2e (foreign root stays): `migrate --status` reports the interrupted journal (exit 3)",
                      stHeld.exitCode == 3 && stHeld.output.contains("journal:") && !stHeld.output.contains("journal:    none"), stHeld.tail)
                let gate = MigrationEngine.runBounded([eNew, "chat"], timeout: 60, extraEnv: eEnv)
                check("probe-mixed e2e (foreign root stays): chat refuses until recovered",
                      gate.exitCode == 2 && gate.output.contains("interrupted"), gate.tail)
                // The user removes the foreign directory; explicit rollback
                // restores Ada. (Through the harness with the SAME spec the
                // journal was written under — the engine refuses a journal
                // written for a different spec, and this test's spec differs
                // from production only by the wrapped probe.)
                try fm.removeItem(atPath: eCfg + "/ada")
                let rb = MigrationEngine.runBounded([eNew, "__migrate-run", "--spec", specPath, "--rollback"], timeout: 180, extraEnv: eEnv)
                check("probe-mixed e2e (foreign root stays): after removing it, `migrate --rollback` restores the Ada install",
                      rb.exitCode == 0 && fm.fileExists(atPath: eCfg + "/ada/secrets.json") && fm.fileExists(atPath: eData + "/ada/conversation.json")
                      && !fm.fileExists(atPath: eCfg + "/briglia") && !fm.fileExists(atPath: eData + "/briglia")
                      && !fm.fileExists(atPath: eState + "/briglia-migrate/journal.json") && adaNotRetired(), "rc=\(rb.exitCode) " + rb.tail)

                // Variant A: the old root is present exactly while the probe
                // runs and gone right after — the engine rolls back on the
                // spot, byte-identically.
                let flasher = eSysd + "/probe-old-root-flashes.sh"
                try writeScript(flasher, "#!/bin/sh\nmkdir -p '\(eCfg)/ada'\n'\(eNew)' __migrate-probe\nrc=$?\nrmdir '\(eCfg)/ada'\nexit $rc\n")
                spec.healthProbe = [flasher]
                try JSONEncoder().encode(spec).write(to: URL(fileURLWithPath: specPath))
                let before = snapshot([eCfg, eData, eUnitDir])
                let run = MigrationEngine.runBounded([eNew, "__migrate-run", "--spec", specPath], timeout: 180, extraEnv: eEnv)
                check("probe-mixed e2e (transient): the migration FAILS at the health probe with the mixed-roots reason",
                      run.exitCode == 1 && run.output.contains("health probe") && run.output.contains("mixed roots"), "rc=\(run.exitCode) " + run.tail)
                let diffs = snapshotDiff(before, snapshot([eCfg, eData, eUnitDir]))
                check("probe-mixed e2e (transient): rolled back byte-identically — old roots back, no new roots, old unit intact, no Briglia unit",
                      diffs.isEmpty && fm.fileExists(atPath: eCfg + "/ada/secrets.json") && !fm.fileExists(atPath: eData + "/briglia"),
                      diffs.prefix(6).joined(separator: "; ") + " | " + run.tail)
                check("probe-mixed e2e (transient): Ada NOT retired, no journal left",
                      adaNotRetired() && !fm.fileExists(atPath: eState + "/briglia-migrate/journal.json"), run.tail)
                let stAfter = MigrationEngine.runBounded([eNew, "migrate", "--status"], timeout: 60, extraEnv: eEnv)
                check("probe-mixed e2e (transient): afterwards the install is a clean PENDING migration again (exit 3)",
                      stAfter.exitCode == 3 && stAfter.output.contains("PENDING"), stAfter.tail)
            }

            // The migration itself.
            let mig = runNew(["migrate"])
            check("real identity: `briglia migrate` completes",
                  mig.exitCode == 0 && mig.output.contains("migration committed and verified"), mig.tail)
            let rootsDetail = [
                "cfg/briglia/secrets.json=\(fm.fileExists(atPath: cfg + "/briglia/secrets.json"))",
                "data/briglia/conversation.json=\(fm.fileExists(atPath: data + "/briglia/conversation.json"))",
                "cfg/ada=\(fm.fileExists(atPath: cfg + "/ada"))",
                "data/ada=\(fm.fileExists(atPath: data + "/ada"))",
                "ls cfg: " + ((try? fm.contentsOfDirectory(atPath: cfg)) ?? []).joined(separator: ","),
                "ls data: " + ((try? fm.contentsOfDirectory(atPath: data)) ?? []).joined(separator: ","),
                "ls data/ada: " + ((try? fm.contentsOfDirectory(atPath: data + "/ada")) ?? []).joined(separator: ","),
                "ls cfg/ada: " + ((try? fm.contentsOfDirectory(atPath: cfg + "/ada")) ?? []).joined(separator: ","),
            ].joined(separator: " | ")
            check("real identity: roots moved (new present, old absent)",
                  fm.fileExists(atPath: cfg + "/briglia/secrets.json")
                  && fm.fileExists(atPath: data + "/briglia/conversation.json")
                  && !fm.fileExists(atPath: cfg + "/ada") && !fm.fileExists(atPath: data + "/ada"),
                  rootsDetail + " | " + mig.tail)
            check("real identity: landing zone moved",
                  fm.fileExists(atPath: home + "/Documents/Briglia/telegram")
                  && !fm.fileExists(atPath: home + "/Documents/AdaCLI"))
            let secrets = readText(cfg + "/briglia/secrets.json")
            check("§4.5.1: persona Ada → Bree, other secrets preserved verbatim",
                  secrets.contains("\"assistant_name\" : \"Bree\"") && secrets.contains("tok-keep"), secrets)
            check("§4.5.1: secrets.json keeps mode 0600 across the staged rewrite",
                  MigrationEngine.fileMode(cfg + "/briglia/secrets.json") == 0o600)
            let marker = readText(data + "/briglia/" + IdentityMigration.markerFileName)
            check("§4.5.6: durable persona marker records the prior name",
                  marker.contains("\"priorName\" : \"Ada\""), marker)
            check("§4.4: the persona bridge reads the marker from the migrated data root",
                  IdentityMigration.priorPersonaName(dataRoot: URL(fileURLWithPath: data + "/briglia")) == "Ada")
            let reminders = readText(data + "/briglia/reminders.json")
            check("§4.5.7: watcher path rebased onto the new data root, script untouched",
                  reminders.contains("\(data)/briglia/reminder-scripts/\(watcherId).sh")
                  && !reminders.contains("/ada/")
                  && readText(data + "/briglia/reminder-scripts/\(watcherId).sh") == "#!/bin/sh\necho hi\n", reminders)
            let wrapper = readText(bin + "/agentmail")
            check("§4.5.2: agentmail broker wrapper re-pinned to the new binary",
                  wrapper.contains("'\(newBinary)' __agentmail-key") && !wrapper.contains("'\(oldBinary)'"), wrapper)
            let tool = readText(bin + "/pdftotext")
            check("§4.5.9: toolchain wrapper rebased, legacy marker kept, still recognized as ours",
                  tool.contains("\(data)/briglia/toolchain/prefix") && !tool.contains("/ada/")
                  && tool.contains(UserdataToolchain.legacyWrapperMarker)
                  && UserdataToolchain.isOurWrapper(bin + "/pdftotext"), tool)
            check("§4.6: compatibility symlink ada → briglia over the verified old binary",
                  (try? fm.destinationOfSymbolicLink(atPath: oldBinary)) == newBinary
                  && sha(newBinary) == String(binHashBefore.suffix(64)))
            let newUnit = readText(unitDir + "/briglia.service")
            check("§4.3.5a: briglia.service installed from captured state (enabled + active), old unit retired",
                  newUnit.contains("ExecStart=\"\(newBinary)\" daemon")
                  && !fm.fileExists(atPath: unitDir + "/ada.service")
                  && fm.fileExists(atPath: sysd + "/briglia.service.enabled")
                  && fm.fileExists(atPath: sysd + "/briglia.service.active")
                  && !fm.fileExists(atPath: sysd + "/ada.service.active"), newUnit)
            let log = readText(sysd + "/log")
            check("§4.3.5b: the new daemon was started and held the new instance lock before retirement",
                  log.contains("start briglia.service") && fm.fileExists(atPath: sysd + "/briglia.service.pid")
                  && MigrationEngine.lockHeld(data + "/briglia/instance.lock"), log)
            let gateLog = readText(sysd + "/gate.log")
            check("§4.3.5a/5b: the systemd-started daemon passed the REAL startup gate on the live journal (0.2.0 regression)",
                  gateLog.contains("GATE-OK") && !gateLog.contains("refused") && !gateLog.contains("✖"), gateLog)
            // Read the domains the way the migrated binary does — in a
            // child under the fixture environment (the only correct view
            // on Linux; identical through cfprefsd on macOS).
            func dumpDomain(_ domain: String) -> [String: String] {
                let r = runNew(["__migrate-run", "--dump-prefs-domain", domain])
                let line = r.output.split(separator: "\n").last.map(String.init) ?? ""
                return ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]) ?? [:]
            }
            check("§4.5.8: preferences domain copied to the new domain, old domain retired",
                  // (the dump prints String(describing:) — corelibs yields
                  // Optional("seeded") where Darwin yields "seeded")
                  dumpDomain(newDomain)["s4"]?.contains("seeded") == true && dumpDomain(oldDomain).isEmpty,
                  "new=\(dumpDomain(newDomain)) old=\(dumpDomain(oldDomain))")
            check("§4.3: journal, preimages and parked assets cleaned after verification",
                  !fm.fileExists(atPath: state + "/briglia-migrate"))

            // After: the shipped surfaces agree the install is Briglia's.
            do {
                let st = runNew(["setup-api", "status"])
                if let obj = try? JSONSerialization.jsonObject(with: Data(st.output.utf8)) as? [String: Any],
                   let migration = obj["migration"] as? [String: Any],
                   let identity = obj["identity"] as? [String: Any] {
                    check("after: setup-api status — migration not needed, assistant Bree, schema 2",
                          migration["needed"] as? Bool == false && identity["assistant_name"] as? String == "Bree"
                          && obj["schema"] as? Int == 2)
                } else {
                    check("after: setup-api status parses", false, st.tail)
                }
                let again = runNew(["migrate"])
                check("after: `briglia migrate` again is a no-op",
                      again.exitCode == 0 && again.output.contains("already on Briglia"), again.tail)
                let doc = runNew(["doctor"])
                check("after: doctor reports the compatibility symlink and the migration marker",
                      doc.output.contains("compatibility symlink") && doc.output.contains("migrated from Ada-era"), doc.tail)
                let probe = runNew([MigrateProbe.configuration.commandName ?? "__migrate-probe"])
                check("after: the health probe passes against the migrated roots",
                      probe.exitCode == 0 && probe.output.contains("PROBE-OK schema=2"), probe.tail)
            }

            // setup-api `migrate` verb (the companion app's path) on a second
            // fixture with a CUSTOM persona and no service: the name is
            // preserved verbatim; the verb reports the outcome; rerun is a
            // documented no-op.
            do {
                let s4b = tempRoot.appendingPathComponent("stage4b").path
                let homeB = s4b + "/home", cfgB = s4b + "/cfg", dataB = s4b + "/data", stateB = s4b + "/state"
                let binB = homeB + "/.local/bin"
                try fm.createDirectory(atPath: binB, withIntermediateDirectories: true)
                let newB = binB + "/briglia"
                try fm.copyItem(atPath: adaBinary, toPath: newB)
                if fm.fileExists(atPath: bundleSrc) {
                    try fm.copyItem(atPath: bundleSrc, toPath: binB + "/" + BundleCheck.bundleName)
                }
                try writeFile(cfgB + "/ada/secrets.json", "{\"assistant_name\": \"Nina\"}", mode: 0o600)
                try writeFile(dataB + "/ada/conversation.json", "{\"messages\": []}")
                let envB: [String: String] = [
                    "HOME": homeB, "XDG_CONFIG_HOME": cfgB, "XDG_DATA_HOME": dataB, "XDG_STATE_HOME": stateB,
                    "BRIGLIA_TOOLCHAIN_BIN": binB, "BRIGLIA_MIGRATE_PREFS_DOMAINS": "none",
                ]
                let r = MigrationEngine.runBounded(["/bin/sh", "-c", "'\(newB)' setup-api migrate </dev/null"],
                                                   timeout: 180, extraEnv: envB)
                let obj = (try? JSONSerialization.jsonObject(with: Data(r.output.utf8))) as? [String: Any]
                check("setup-api migrate: ok, outcome migrated, migration block now not needed",
                      obj?["ok"] as? Bool == true && obj?["outcome"] as? String == "migrated"
                      && (obj?["migration"] as? [String: Any])?["needed"] as? Bool == false, r.tail)
                // The persona fixup must not even rewrite the file when the
                // stored name is not exactly the old default: the bytes are
                // the fixture's own (compact JSON, no pretty-print).
                let secretsB = readText(cfgB + "/briglia/secrets.json")
                check("§4.5.1: a custom persona (Nina) is preserved verbatim (file untouched), marker still written",
                      secretsB == "{\"assistant_name\": \"Nina\"}"
                      && readText(dataB + "/briglia/" + IdentityMigration.markerFileName).contains("\"storedNameAtMigration\" : \"Nina\""),
                      secretsB)
                check("no old binary present: no compat symlink, migration still completes",
                      !fm.fileExists(atPath: binB + "/ada"))
                let r2 = MigrationEngine.runBounded(["/bin/sh", "-c", "'\(newB)' setup-api migrate </dev/null"],
                                                    timeout: 60, extraEnv: envB)
                let obj2 = (try? JSONSerialization.jsonObject(with: Data(r2.output.utf8))) as? [String: Any]
                check("setup-api migrate: rerun reports nothing_to_do",
                      obj2?["ok"] as? Bool == true && obj2?["outcome"] as? String == "nothing_to_do", r2.tail)
            }
        }

        // ============================================================
        print("\n— hardening bundle (H7): rollback preflight, exclusive temps, capture-kind checks, special modes, lock probe —")

        // H7.1 — a directory planted at a recorded preimage path holds the
        // WHOLE rollback before its first mutation.
        do {
            let fixture = try makeFixture("h7-planted-dir", wakelock: true)
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-fixups"])
            check("H7.1: crash injected after fixups", crashed.code == 137, crashed.output)
            let journalData = fm.contents(atPath: fixture.stateDir + "/journal.json") ?? Data()
            let journal = try? JSONDecoder().decode(MigrationJournal.self, from: journalData)
            // Rollback walks preimages in REVERSE: the FIRST-recorded entry
            // is restored LAST, so a per-entry check would only trip after
            // every later entry had already been restored or deleted.
            let firstFile = journal?.preimages.first { $0.type == "file" }
            check("H7.1: journal records a file preimage", firstFile != nil)
            if let firstFile {
                let victim = firstFile.path   // roots are moved at this point: the new-root location
                let originalBytes = fm.contents(atPath: victim)
                try fm.removeItem(atPath: victim)
                try fm.createDirectory(atPath: victim, withIntermediateDirectories: false)
                try writeFile(victim + "/inner.txt", "planted")
                let watched = fixture.restoreRoots + [fixture.newConfig, fixture.newData, fixture.stateDir]
                let held = snapshot(watched)
                let refused = runEngine(fixture, args: ["--rollback"])
                check("H7.1: rollback refuses BEFORE modifying anything, naming the planted directory",
                      refused.code == 1 && refused.output.contains("refused BEFORE modifying anything")
                      && refused.output.contains("DIRECTORY") && refused.output.contains(victim), refused.output)
                let diffs = snapshotDiff(held, snapshot(watched))
                check("H7.1: zero mutations — every other entry untouched, journal kept (tree hash before == after)",
                      diffs.isEmpty && fm.fileExists(atPath: fixture.stateDir + "/journal.json"),
                      diffs.prefix(5).joined(separator: "; "))
                try fm.removeItem(atPath: victim)
                if let originalBytes { _ = fm.createFile(atPath: victim, contents: originalBytes) }
                let rolled = runEngine(fixture, args: ["--rollback"])
                check("H7.1: with the planted directory gone the rollback completes", rolled.code == 0, rolled.output)
                let finalDiffs = snapshotDiff(before, snapshot(fixture.restoreRoots))
                check("H7.1: byte-identical restore", finalDiffs.isEmpty, finalDiffs.prefix(5).joined(separator: "; "))
            }
        }

        // H7.2 — exclusive staging temps; orphans swept at engine start.
        do {
            let fixture = try makeFixture("h7-orphans", units: false)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-moved"])
            check("H7.2: crash injected after the root moves", crashed.code == 137, crashed.output)
            let orphan1 = fixture.stateDir + "/" + MigrationEngine.stagingTempPrefix + "orphan-1"
            let orphan2 = fixture.stateDir + "/preimages/" + MigrationEngine.stagingTempPrefix + "orphan-2"
            let keep = fixture.stateDir + "/preimages/keep-me"
            try writeFile(orphan1, "half-written")
            try writeFile(orphan2, "half-written")
            try writeFile(keep, "not a staging temp")
            let reentered = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "mid-fixups"])
            check("H7.2: recovery re-entered (and crashed at the next seam, keeping the journal area)",
                  reentered.code == 137, reentered.output)
            check("H7.2: orphan staging temps swept at engine start, other files untouched",
                  !fm.fileExists(atPath: orphan1) && !fm.fileExists(atPath: orphan2)
                  && fm.fileExists(atPath: keep))
            let done = runEngine(fixture)
            check("H7.2: migration then completes forward", done.code == 0, done.output)

            let wdDir = tempRoot.appendingPathComponent("h7-writedurable").path
            try fm.createDirectory(atPath: wdDir, withIntermediateDirectories: true)
            let target = wdDir + "/out.txt"
            let why = MigrationEngine.writeDurable(Data("x".utf8), to: URL(fileURLWithPath: target))
            let prior = umask(0o022); umask(prior)
            let expectedDefault = Int(0o666 & ~prior)
            check("H7.2: writeDurable without a mode yields the plain-create (umask) mode",
                  why == nil && MigrationEngine.fileMode(target) == expectedDefault,
                  "\(why ?? "") mode=\(MigrationEngine.fileMode(target).map { String($0, radix: 8) } ?? "?") expected=\(String(expectedDefault, radix: 8))")
            let why2 = MigrationEngine.writeDurable(Data("y".utf8), to: URL(fileURLWithPath: target), mode: 0o600)
            check("H7.2: writeDurable applies the requested mode", why2 == nil
                  && MigrationEngine.fileMode(target) == 0o600 && readText(target) == "y", why2 ?? "")
            let empty = MigrationEngine.writeDurable(Data(), to: URL(fileURLWithPath: wdDir + "/empty"), mode: 0o600)
            check("H7.2: writeDurable handles empty content", empty == nil
                  && fm.contents(atPath: wdDir + "/empty")?.isEmpty == true, empty ?? "")
            let dirTarget = wdDir + "/adir"
            try fm.createDirectory(atPath: dirTarget, withIntermediateDirectories: true)
            let why3 = MigrationEngine.writeDurable(Data("z".utf8), to: URL(fileURLWithPath: dirTarget))
            let leftovers = ((try? fm.contentsOfDirectory(atPath: wdDir)) ?? [])
                .filter { $0.hasPrefix(MigrationEngine.stagingTempPrefix) }
            check("H7.2: writeDurable over a directory fails cleanly and leaves no staging temp",
                  why3 != nil && leftovers.isEmpty && fm.fileExists(atPath: dirTarget), why3 ?? "nil")
        }

        // H7.3 — check-then-act on recorded paths: a staged write refuses a
        // target whose kind changed since capture; a park refuses an asset
        // whose kind changed since it was recorded.
        do {
            let fixture = try makeFixture("h7-kind-fixup", wakelock: true)
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-preimage-record"])
            check("H7.3: crash injected right after the first preimage record", crashed.code == 137, crashed.output)
            let secrets = fixture.newConfig + "/secrets.json"
            let copy = fixture.root + "/secrets-copy.json"
            check("H7.3: the recorded file is still a regular file at the crash", MigrationEngine.entryKind(secrets) == "file")
            try fm.copyItem(atPath: secrets, toPath: copy)
            try fm.removeItem(atPath: secrets)
            try fm.createSymbolicLink(atPath: secrets, withDestinationPath: copy)
            let result = runEngine(fixture)
            check("H7.3: staged write refuses a target whose kind changed since capture (file → symlink) and rolls back",
                  result.code == 1 && result.output.contains("changed kind since it was captured")
                  && result.output.contains("rolled back"), result.output)
            let diffs = snapshotDiff(before, snapshot(fixture.restoreRoots))
            check("H7.3: byte-identical restore after the refusal (symlink replaced by the recorded file)",
                  diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
        }
        do {
            let fixture = try makeFixture("h7-kind-park", wakelock: true)
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-park-record-bundle"])
            check("H7.3: crash injected right after the bundle's park record", crashed.code == 137, crashed.output)
            let skill = fixture.oldBundle + "/BundledSkills/pdf/SKILL.md"
            let skillText = readText(skill)
            check("H7.3: the recorded asset (old bundle directory) is still at its original path, not yet parked",
                  MigrationEngine.entryKind(fixture.oldBundle) == "directory"
                  && !fm.fileExists(atPath: fixture.stateDir + "/parked/bundle"))
            try fm.removeItem(atPath: fixture.oldBundle)
            try writeFile(fixture.oldBundle, "now a regular file")
            let held = runEngine(fixture)
            check("H7.3: park refuses an asset whose kind changed since it was recorded (directory → file), journal kept",
                  held.code == 1 && held.output.contains("changed kind since it was recorded for parking")
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json"), held.output)
            check("H7.3: the planted file was neither parked nor removed",
                  !fm.fileExists(atPath: fixture.stateDir + "/parked/bundle")
                  && MigrationEngine.entryKind(fixture.oldBundle) == "file")
            try fm.removeItem(atPath: fixture.oldBundle)
            try writeFile(skill, skillText)
            let done = runEngine(fixture)
            check("H7.3: with the original file back, recovery completes forward", done.code == 0, done.output)
            assertMigratedState(fixture, label: "H7.3-park")
        }

        // H7.4 — journal-area subdirectories are owner-only.
        do {
            let fixture = try makeFixture("h7-modes", units: false)
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-prepared"])
            check("H7.4: crash injected after prepare", crashed.code == 137, crashed.output)
            let modes = [fixture.stateDir, fixture.stateDir + "/preimages", fixture.stateDir + "/parked"]
                .map { MigrationEngine.fileMode($0) }
            check("H7.4: state dir, preimages/ and parked/ are 0700", modes.allSatisfy { $0 == 0o700 },
                  modes.map { $0.map { String($0, radix: 8) } ?? "missing" }.joined(separator: ","))
            _ = runEngine(fixture)
        }

        // H7.4b — recovery re-tightens a journal area an older build created
        //         at 0755, and refuses an entry that is no longer a directory.
        do {
            let fixture = try makeFixture("h7-modes-recover", units: false)
            let fm = FileManager.default
            let preimages = fixture.stateDir + "/preimages"
            let parked = fixture.stateDir + "/parked"
            let journalPath = fixture.stateDir + "/journal.json"
            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-prepared"])
            check("H7.4b: crash injected after prepare", crashed.code == 137, crashed.output)
            _ = chmod(preimages, 0o755)
            _ = chmod(parked, 0o755)
            let tightened = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "after-recovery-tighten"])
            check("H7.4b: crash injected right after recovery tightened the journal area", tightened.code == 137, tightened.output)
            let modes = [fixture.stateDir, preimages, parked].map { MigrationEngine.fileMode($0) }
            check("H7.4b: recovery re-applies 0700 to pre-existing preimages/ and parked/", modes.allSatisfy { $0 == 0o700 },
                  modes.map { $0.map { String($0, radix: 8) } ?? "missing" }.joined(separator: ","))
            // parked/ replaced by a symlink to a decoy directory: refused, nothing touched.
            let decoy = fixture.stateDir + "-decoy"
            try fm.createDirectory(atPath: decoy, withIntermediateDirectories: true)
            try fm.removeItem(atPath: parked)
            try fm.createSymbolicLink(atPath: parked, withDestinationPath: decoy)
            let refused = runEngine(fixture)
            let parkedIsLink = (try? fm.destinationOfSymbolicLink(atPath: parked)) != nil
            check("H7.4b: recovery refuses a journal-area entry that is not a directory (parked/ → symlink), journal preserved",
                  refused.code != 0 && refused.output.contains("not a directory") && fm.fileExists(atPath: journalPath),
                  refused.output)
            check("H7.4b: the planted symlink and its target were not touched",
                  parkedIsLink && fm.fileExists(atPath: decoy))
            try fm.removeItem(atPath: parked)
            try fm.createDirectory(atPath: parked, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            let done = runEngine(fixture)
            check("H7.4b: with the directory restored, recovery completes forward", done.code == 0, done.output)
        }

        // H7.5 — subprocess output files live under the journal area.
        do {
            let fixture = try makeFixture("h7-outpaths")
            defer { killHolders(fixture) }
            let result = runEngine(fixture, env: ["FAKE_SYSTEMCTL_LOG_OUTPATH": "1"])
            check("H7.5: migration succeeds while systemctl records where its output goes", result.code == 0, result.output)
            let lines = readText(fixture.sysd + "/outpaths").split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty }
            let stateReal = MigrationEngine.canonicalize(fixture.stateDir, dereferenceLeaf: true) ?? fixture.stateDir
            let bad = lines.filter {
                !($0.hasPrefix(fixture.stateDir + "/migrate-out-") || $0.hasPrefix(stateReal + "/migrate-out-"))
            }
            check("H7.5: every subprocess output file was created under the 0700 journal area (\(lines.count) calls)",
                  !lines.isEmpty && bad.isEmpty, bad.prefix(3).joined(separator: ", "))
        }

        // H7.6 — systemctl by absolute path only; journal unit captures must
        // be the spec's.
        do {
            let fixture = try makeFixture("h7-units")
            defer { killHolders(fixture) }
            var relative = fixture.spec
            relative.systemctl = "systemctl"
            check("H7.6: a spec naming systemctl by a relative name is refused",
                  MigrationEngine.validateSpec(relative)?.contains("absolute path") == true,
                  MigrationEngine.validateSpec(relative) ?? "accepted")
            var badUnit = fixture.spec
            badUnit.oldUnitName = "../evil.service"
            check("H7.6: a spec naming a unit with a path separator is refused",
                  MigrationEngine.validateSpec(badUnit)?.contains("invalid systemd unit") == true,
                  MigrationEngine.validateSpec(badUnit) ?? "accepted")
            let fixed = IdentityMigration.systemctlFixedPath()
            check("H7.6: production systemctl resolves only to a fixed location (or none)",
                  fixed == nil || IdentityMigration.systemctlCandidates.contains(fixed!), fixed ?? "nil")

            let crashed = runEngine(fixture, env: ["BRIGLIA_MIGRATE_CRASH_POINT": "between-root-moves"])
            check("H7.6: crash injected with a unit capture in the journal", crashed.code == 137, crashed.output)
            let journalPath = fixture.stateDir + "/journal.json"
            let original = readText(journalPath)
            var object = try JSONSerialization.jsonObject(with: Data(original.utf8)) as! [String: Any]
            var service = object["oldService"] as! [String: Any]
            service["name"] = "evil.service"
            object["oldService"] = service
            try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: journalPath))
            let watched = fixture.restoreRoots + [fixture.newConfig, fixture.newData]
            let held = snapshot(watched)
            let refused = runEngine(fixture)
            check("H7.6: a journal whose unit capture is not the spec's unit is refused as corrupt, zero mutations",
                  refused.code == 3 && refused.output.contains("not the spec's old unit")
                  && snapshotDiff(held, snapshot(watched)).isEmpty, refused.output)
            try original.write(toFile: journalPath, atomically: true, encoding: .utf8)
            _ = runEngine(fixture)
        }

        // H7.7 — lock probe distinguishes free / held / unknown.
        do {
            let lockDir = tempRoot.appendingPathComponent("h7-lock").path
            try fm.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
            check("H7.7: a missing lock file probes as free",
                  MigrationEngine.lockProbe(lockDir + "/none.lock") == .free)
            let probe = MigrationEngine.lockProbe(lockDir)   // a directory: open(O_RDWR) fails, not ENOENT
            var unknown = false
            if case .unknown = probe { unknown = true }
            check("H7.7: an unprobeable lock path is unknown with its errno — never free, never held",
                  unknown && probe.problem != nil && !MigrationEngine.lockHeld(lockDir), "\(probe)")
            let path = lockDir + "/held.lock"
            let fd = open(path, O_WRONLY | O_CREAT, 0o600)
            check("H7.7: a held lock probes as held",
                  fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0 && MigrationEngine.lockProbe(path) == .held)
            flock(fd, LOCK_UN); close(fd)
            check("H7.7: a released lock probes as free", MigrationEngine.lockProbe(path) == .free)

            let fixture = try makeFixture("h7-lock-unknown", units: false)
            try fm.removeItem(atPath: fixture.oldData + "/instance.lock")
            try fm.createDirectory(atPath: fixture.oldData + "/instance.lock", withIntermediateDirectories: false)
            let before = snapshot(fixture.restoreRoots)
            let refused = runEngine(fixture)
            check("H7.7: an unprobeable instance lock refuses the migration instead of guessing",
                  refused.code == 2 && refused.output.contains("refusing to proceed on a guess"), refused.output)
            check("H7.7: refusal left the fixture untouched, no journal",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty
                  && !fm.fileExists(atPath: fixture.stateDir))
        }

        // H7.8 — special permission bits: preserved exactly on moved files
        // (asserted in every migrated-state check), refused by name on an
        // asset the engine would have to rewrite.
        do {
            let fixture = try makeFixture("h7-special-rewrite", units: false)
            let wrapper = fixture.binDir + "/agentmail"
            try fm.setAttributes([.posixPermissions: 0o2755], ofItemAtPath: wrapper)
            check("H7.8: fixture wrapper carries setgid", MigrationEngine.fileMode(wrapper) == 0o2755)
            let before = snapshot(fixture.restoreRoots)
            let refused = runEngine(fixture)
            check("H7.8: an engine-rewritten asset carrying setgid is refused BEFORE anything moves, by name",
                  refused.code == 2 && refused.output.contains("setgid") && refused.output.contains(wrapper)
                  && refused.output.contains("nothing was changed"), refused.output)
            check("H7.8: refusal left everything untouched, no journal",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty
                  && !fm.fileExists(atPath: fixture.stateDir))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
            let ok = runEngine(fixture)
            check("H7.8: with the bit cleared the migration proceeds", ok.code == 0, ok.output)
            assertMigratedState(fixture, label: "H7.8")
        }

        // H3 — the raw engine runner is a development-build command.
        do {
            check("H3: bare release versions are not development builds",
                  !MigrationRunCommand.isDevelopmentBuild(version: "0.2.4")
                  && !MigrationRunCommand.isDevelopmentBuild(version: "0.2.4-rc1")
                  && !MigrationRunCommand.isDevelopmentBuild(version: "1.0.0"))
            check("H3: -dev versions are development builds",
                  MigrationRunCommand.isDevelopmentBuild(version: "0.1.0-dev")
                  && MigrationRunCommand.isDevelopmentBuild(version: "0.2.4-dev"))
            check("H3: this test binary is a development build (the battery drives __migrate-run through it)",
                  MigrationRunCommand.isDevelopmentBuild())
        }

        // ============================================================
        print("\n— startup gate vs a LIVE migration journal (the 0.2.0 systemd rollback) —")
        do {
            let g = tempRoot.appendingPathComponent("gate").path
            let gHome = g + "/home", gCfg = g + "/cfg", gData = g + "/data", gState = g + "/state"
            for d in [gHome, gCfg, gData, gState] {
                try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            }
            let gEnv: [String: String] = [
                "HOME": gHome, "XDG_CONFIG_HOME": gCfg, "XDG_DATA_HOME": gData, "XDG_STATE_HOME": gState,
                "BRIGLIA_TOOLCHAIN_BIN": g + "/bin", "BRIGLIA_MIGRATE_SYSTEMCTL": "/usr/bin/false",
                "BRIGLIA_MIGRATE_PREFS_DOMAINS": "none",
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ]
            let spec = IdentityMigration.productionSpec(environment: gEnv)
            let stateDir = IdentityMigration.stateDir(environment: gEnv)
            let lockPath = IdentityMigration.migrationLockPath(environment: gEnv)
            let engineLock = (spec.stateDir.hasSuffix("/") ? String(spec.stateDir.dropLast()) : spec.stateDir) + ".lock"
            check("gate: IdentityMigration.migrationLockPath equals the engine's lock derived from the production spec",
                  engineLock == lockPath && lockPath == gState + "/briglia-migrate.lock", lockPath)
            let journalPath = stateDir + "/journal.json"
            func writeJournal(state: String, ready: Bool?, dropKey: Bool = false,
                              tamper: ((inout [String: Any]) -> Void)? = nil) throws {
                var j = MigrationEngine.freshJournal(spec: spec)
                j.state = state
                j.newInstallReady = ready
                // The gate validates the journal with the engine's own loader
                // (H7.9): a real in-flight journal records every root pair.
                j.roots = spec.rootPairs.map {
                    MigrationJournal.RootMove(old: $0.old, new: $0.new, existed: true, moved: true)
                }
                try fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
                var data = try JSONEncoder().encode(j)
                if dropKey || tamper != nil {
                    var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    if dropKey {   // a journal written by 0.2.0 — no such key at all
                        obj.removeValue(forKey: "newInstallReady")
                    }
                    tamper?(&obj)
                    data = try JSONSerialization.data(withJSONObject: obj)
                }
                try data.write(to: URL(fileURLWithPath: journalPath))
            }
            func status() -> IdentityMigration.Status { IdentityMigration.status(environment: gEnv) }
            func runGate(_ args: [String]) -> MigrationEngine.RunResult {
                MigrationEngine.runBounded([adaBinary] + args, timeout: 60, extraEnv: gEnv)
            }
            // Hold the engine's lock from here: flock is per open file
            // description, so a probe on another fd sees it as held.
            let lockFD = open(lockPath, O_WRONLY | O_CREAT, 0o600)
            check("gate: fixture can create the migration lock", lockFD >= 0)
            var held = false
            func hold() { if !held { held = flock(lockFD, LOCK_EX | LOCK_NB) == 0 } }
            func release() { if held { flock(lockFD, LOCK_UN); held = false } }
            defer { release(); close(lockFD) }
            let newCfg = gCfg + "/briglia", newData = gData + "/briglia"
            let oldCfg = gCfg + "/ada"

            var s0 = status()
            check("gate: no journal, no roots → nothing pending, no lock seen",
                  !s0.pending && !s0.migrationRunning && !s0.migrationLockHeld)

            // A live migrator BEFORE the ready flag (roots already moved so
            // the gate — not a missing root — is what the probe reports).
            try fm.createDirectory(atPath: newCfg, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: newData, withIntermediateDirectories: true)
            try writeJournal(state: "fixups", ready: false); hold()
            s0 = status()
            check("gate: live journal (lock held) but new install not ready → REFUSED as running",
                  s0.pending && s0.migrationRunning && !s0.servedByLiveMigration
                  && IdentityMigration.pendingMessage(s0).contains("running right now"),
                  IdentityMigration.pendingMessage(s0))
            var r = runGate(["__migrate-gate"])
            check("gate: real binary `__migrate-gate` refuses (exit 2, 'running right now') before ready",
                  r.exitCode == 2 && r.output.contains("running right now"), r.tail)
            r = runGate(["__migrate-probe"])
            check("gate: `__migrate-probe` fails on the not-ready live journal naming the startup gate",
                  r.exitCode != 0 && r.output.contains("PROBE-FAIL") && r.output.contains("startup gate"), r.tail)

            // The migrator set the flag and is now probing/starting: ADMIT.
            try writeJournal(state: "fixups", ready: true)
            s0 = status()
            check("gate: live journal + new install ready + no old root → admitted (served by the live migration)",
                  !s0.pending && s0.servedByLiveMigration && s0.newInstallReady)
            r = runGate(["__migrate-gate"])
            check("gate: real binary `__migrate-gate` admits (GATE-OK) exactly as the daemon would",
                  r.exitCode == 0 && r.output.contains("GATE-OK"), r.tail)
            r = runGate(["__migrate-probe"])
            check("gate: `__migrate-probe` passes on the ready live journal", r.exitCode == 0 && r.output.contains("PROBE-OK"), r.tail)
            for st in ["committing", "committed", "done"] {
                try writeJournal(state: st, ready: true)
                check("gate: live journal in state \(st) + ready → admitted (roll-forward recovery restarts the daemon)",
                      !status().pending)
            }
            try writeJournal(state: "fixups", ready: true)

            // Same flag, but an old root is back: the invariant wins.
            try fm.createDirectory(atPath: oldCfg, withIntermediateDirectories: true)
            s0 = status()
            check("gate: ready live journal but an old root present → refused (ANY old root closes the gate)",
                  s0.pending && !s0.servedByLiveMigration)
            r = runGate(["__migrate-gate"])
            check("gate: real binary refuses with an old root present even mid-live-migration", r.exitCode == 2, r.tail)
            try fm.removeItem(atPath: oldCfg)

            // The migrator died: same journal, nobody holds the lock.
            release()
            s0 = status()
            check("gate: same ready journal with NO live holder → interrupted, refused ('was interrupted')",
                  s0.pending && !s0.migrationLockHeld && !s0.migrationRunning
                  && IdentityMigration.pendingMessage(s0).contains("was interrupted"),
                  IdentityMigration.pendingMessage(s0))
            r = runGate(["__migrate-gate"])
            check("gate: real binary refuses the orphaned journal (exit 2)", r.exitCode == 2 && r.output.contains("interrupted"), r.tail)

            // A 0.2.0-era journal (no flag key) under a live holder: never admitted by guesswork.
            try writeJournal(state: "fixups", ready: nil, dropKey: true); hold()
            s0 = status()
            check("gate: pre-flag (0.2.0) journal decodes and is refused even under a live lock",
                  s0.journalState == "fixups" && s0.migrationRunning && !s0.newInstallReady && s0.pending)
            release()

            // H7.9: a journal that DECODES but fails the engine's validation
            // is unreadable to the gate — never admitted, even ready and
            // under a live lock. Three shapes: an out-of-bounds preimage, a
            // truncated roots array, a unit capture that is not the spec's.
            let tampers: [(String, (inout [String: Any]) -> Void)] = [
                ("out-of-bounds preimage", { $0["preimages"] = [["id": "evil", "type": "file",
                                                                  "path": "/etc/passwd", "sha256": "00"]] }),
                ("truncated roots", { var roots = $0["roots"] as! [[String: Any]]; roots.removeLast(); $0["roots"] = roots }),
                ("foreign unit capture", { $0["oldService"] = ["name": "evil.service", "unitPath": "/tmp/evil.service",
                                                                "installed": true, "enabled": true, "active": true] }),
            ]
            for (label, tamper) in tampers {
                try writeJournal(state: "fixups", ready: true, tamper: tamper); hold()
                s0 = status()
                check("H7.9 gate: invalid journal (\(label)) reads as unreadable and keeps the gate closed even when ready + live",
                      s0.journalState == "unreadable" && s0.pending && !s0.servedByLiveMigration,
                      "state=\(s0.journalState ?? "nil") pending=\(s0.pending)")
                r = runGate(["__migrate-gate"])
                check("H7.9 gate: real binary refuses the invalid journal (\(label), exit 2)", r.exitCode == 2, r.tail)
                release()
            }
            try writeJournal(state: "fixups", ready: true); hold()
            check("H7.9 gate: the untampered ready journal is admitted again (validation is not over-broad)",
                  !status().pending && status().servedByLiveMigration)
            release()
            try? fm.removeItem(atPath: journalPath)
        }

        // ============================================================
        // H8.4: every throwaway preferences domain this run created is gone
        // — including the empty shell cfprefsd writes a few seconds after a
        // removal (see TestPrefsDomains).
        let leftoverDomains = TestPrefsDomains.finalSweep()
        check("hygiene: no throwaway preferences domain survives the run",
              leftoverDomains.isEmpty, leftoverDomains.joined(separator: ", "))

        print(failures == 0 ? "\nmigration selftest: all checks passed"
                            : "\nmigration selftest: \(failures) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
