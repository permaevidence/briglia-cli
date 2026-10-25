import Foundation

// MARK: - §8.2 AgentMail pinned release (static checks)
//
// The installer battery moved with the installer: Briglia's private AgentMail
// install (security plan v24 §7.8.1) is exercised by
// `briglia __private-runtime-selftest` (receipt, current link, journal, hold,
// repair transaction, crash recovery). Quick Setup keeps only the pin checks.

extension SelftestContext {
    /// Pinned upstream release (2026-09-04): the installer never asks GitHub
    /// for "latest"; the archive for this target is authenticated against
    /// the compiled-in SHA-256.
    func agentMailPinning() async throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        func isSHA(_ s: String) -> Bool { s.count == 64 && s.unicodeScalars.allSatisfy { hex.contains($0) } }
        check("pinned version is a plain semver", AgentMailService.pinnedVersion.split(separator: ".").count == 3 && !AgentMailService.pinnedVersion.hasPrefix("v"))
        check("every pinned entry is a lowercase 64-hex SHA-256", AgentMailService.pinnedArchiveSHA256.values.allSatisfy(isSHA) && AgentMailService.pinnedArchiveSHA256.count == 4)
        let pin = AgentMailService.pinnedAsset()
        check("this platform (\(AgentMailService.currentTargetTriple)) has a pinned build", pin != nil)
        if let pin {
            check("asset name follows the cargo-dist layout", pin.asset == "agentmail-cli-\(AgentMailService.currentTargetTriple).tar.gz")
            check("download URL is the immutable tag path on github.com",
                  pin.url.host == "github.com" && pin.url.path == "/agentmail-to/agentmail-cli/releases/download/v\(AgentMailService.pinnedVersion)/\(pin.asset)")
            check("Linux pins the static musl build (no libssl.so.3 dependency)",
                  !AgentMailService.currentTargetTriple.contains("linux") || AgentMailService.currentTargetTriple.hasSuffix("-musl"))
        }
        check("no pinned build for an unknown target", AgentMailService.pinnedAsset(triple: "sparc-unknown-plan9") == nil)
    }
}
