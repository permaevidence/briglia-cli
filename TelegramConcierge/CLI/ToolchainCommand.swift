import ArgumentParser
import Foundation

/// `briglia toolchain` — status / install / remove for the userdata media
/// toolchain (see UserdataToolchain.swift). Built for Ubuntu Touch, where
/// apt-to-rootfs is a trap (tiny, read-only, wiped by OTA); works on any
/// Debian-family system without root.
struct ToolchainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toolchain",
        abstract: "Media/document tools on the userdata partition (no root, OTA-safe).",
        subcommands: [Status.self, Install.self, Upgrade.self, Remove.self],
        defaultSubcommand: Status.self)

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "Show which tools are available and from where.")

        func run() throws {
            try AssistantProfile.requireDefault(AssistantProfile.toolchainMessage)
            let rows = UserdataToolchain.status()
            print("Media toolchain:")
            var lastPackage = ""
            for row in rows {
                if row.package != lastPackage {
                    print("  [\(row.package)\(row.optional ? " — optional" : "")]")
                    lastPackage = row.package
                }
                let mark = row.present ? "✔" : "✖"
                print("    \(mark) \(row.name)  (\(row.source))")
            }
            let missing = rows.filter { !$0.present && !$0.optional }
            let missingOptional = rows.filter { !$0.present && $0.optional }
            if missing.isEmpty {
                print("Everything present.")
            } else {
                print("Missing: \(missing.map { $0.name }.joined(separator: ", "))")
                print("Install without touching the rootfs:  briglia toolchain install")
            }
            if !missingOptional.isEmpty {
                print("Optional, not installed: "
                      + Set(missingOptional.map { $0.package }).sorted().joined(separator: ", ")
                      + "  (briglia toolchain install --pandoc / --libreoffice)")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install the missing tools into a userdata prefix (no sudo).")

        @Flag(name: .customLong("pandoc"),
              help: "Also install pandoc (document generation, ~150 MB).")
        var includePandoc = false

        @Flag(name: .customLong("libreoffice"),
              help: "Also install LibreOffice (headless DOCX/XLSX/PPTX→PDF conversions, ~350 MB on userdata).")
        var includeLibreOffice = false

        func run() async throws {
            try AssistantProfile.requireDefault(AssistantProfile.toolchainMessage)
            try IdentityMigration.gateMutatingEntry()
            let report = await Task.detached(priority: .userInitiated) {
                UserdataToolchain.installSync(includePandoc: includePandoc,
                                              includeLibreOffice: includeLibreOffice) {
                    print("  \($0)")
                }
            }.value
            if !report.alreadyPresent.isEmpty {
                print("Already available: \(report.alreadyPresent.joined(separator: ", "))")
            }
            if !report.wrappers.isEmpty {
                print("Installed to userdata: \(report.wrappers.joined(separator: ", "))")
            }
            for note in report.notes { print("Note: \(note)") }
            if report.ok {
                print("✔ Toolchain ready.")
            } else {
                for failure in report.failures { print("✖ \(failure)") }
                throw ExitCode(1)
            }
        }
    }

    struct Upgrade: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "upgrade",
            abstract: "Compare the prefix against the repo and rebuild it when security/bug fixes are available.")

        func run() async throws {
            try AssistantProfile.requireDefault(AssistantProfile.toolchainMessage)
            try IdentityMigration.gateMutatingEntry()
            let report = await Task.detached(priority: .userInitiated) {
                UserdataToolchain.upgradeSync {
                    print("  \($0)")
                }
            }.value
            if !report.wrappers.isEmpty {
                print("Rebuilt on userdata: \(report.wrappers.joined(separator: ", "))")
            }
            for note in report.notes { print("Note: \(note)") }
            if report.ok {
                print("✔ Toolchain current.")
            } else {
                for failure in report.failures { print("✖ \(failure)") }
                throw ExitCode(1)
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove the userdata prefix and every wrapper Briglia created.")

        func run() throws {
            try AssistantProfile.requireDefault(AssistantProfile.toolchainMessage)
            try IdentityMigration.gateMutatingEntry()
            let result = UserdataToolchain.removeAll()
            if !result.removed.isEmpty {
                print("Removed: \(result.removed.joined(separator: ", "))")
            }
            if let failure = result.failure {
                print("✖ \(failure)")
                throw ExitCode(1)
            }
            if result.removed.isEmpty {
                print("Nothing to remove — no Briglia-created wrappers or prefix found.")
            }
        }
    }
}
