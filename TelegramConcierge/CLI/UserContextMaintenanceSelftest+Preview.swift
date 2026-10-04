import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The developer preview (plan §11) and its harness rows V1–V4.
///
/// `__user-context-maintenance-selftest --live-preview --profile <file>
/// --out <dir> --credentials <file>` runs, in a development build only, the
/// REAL maintenance path once on a COPY of a profile in scratch roots and
/// writes `user-context-preview.md` (every drop/edit/add, sizes, the
/// resulting profile) and `user-context-preview.log` (timing, sends, finish
/// reasons; no profile text, no credentials), both 0600.
///
/// The credentials file is a small JSON object the developer prepares; only
/// API-key provider settings on the allowlist below are accepted. A ChatGPT
/// subscription login is never accepted or copied: a copy refreshing its
/// token could invalidate the real login.
extension UserContextMaintenanceSelftest {

    static let previewAllowedKeys: Set<String> = [
        KeychainHelper.llmProviderKey, KeychainHelper.openRouterModelKey, KeychainHelper.openRouterReasoningEffortKey,
        KeychainHelper.openAICompatibleBaseURLKey, KeychainHelper.openAICompatibleModelKey,
        KeychainHelper.openAICompatibleReasoningEffortKey, KeychainHelper.openAICompatibleApiKeyKey,
        KeychainHelper.assistantNameKey, KeychainHelper.userNameKey, "openrouter_api_key",
    ]

    struct PreviewRefusal: Error, CustomStringConvertible { let description: String }

    /// V3: refuse anything outside the allowlist (in particular a subscription login).
    static func previewCredentials(_ data: Data) throws -> [String: String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw PreviewRefusal(description: "credentials file must be a flat JSON object of strings")
        }
        let refused = object.keys.filter { !previewAllowedKeys.contains($0) }.sorted()
        guard refused.isEmpty else { throw PreviewRefusal(description: "refusing non-allowlisted keys: \(refused.joined(separator: ", "))") }
        if (object[KeychainHelper.openAICompatibleBaseURLKey] ?? "").lowercased().contains("chatgpt.com") {
            throw PreviewRefusal(description: "refusing the ChatGPT subscription endpoint")
        }
        return object
    }

    /// V2: every root must resolve (after symlinks) outside every real root.
    static func rootsOutside(_ roots: [URL], real: [URL]) -> Bool {
        let resolvedReal = real.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        return roots.allSatisfy { root in
            let path = root.resolvingSymlinksInPath().standardizedFileURL.path
            return resolvedReal.allSatisfy { realPath in path != realPath && !path.hasPrefix(realPath + "/") && !realPath.hasPrefix(path + "/") }
        }
    }

    static func runPreviewChild(profile: String?, out: String?, credentials: String?, realRoots: [String]) async throws {
        guard StoragePaths.dataRoot.path.contains(rootPrefix), ProcessInfo.processInfo.processName == linkName else {
            print("✖ refusing: the preview runs only in its isolated scratch home"); throw PreviewRefusal(description: "not isolated")
        }
        guard let profile, let out, let credentials else { throw PreviewRefusal(description: "--profile, --out and --credentials are required") }
        // The account's passwd home (HOME and CFFIXED_USER_HOME point at
        // scratch here) plus the roots the parent process resolved.
        guard realRoots.count >= 2, let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            throw PreviewRefusal(description: "cannot determine the real roots to protect")
        }
        let realHome = URL(fileURLWithPath: String(cString: dir))
        let real = [realHome.appendingPathComponent(".config/briglia"), realHome.appendingPathComponent(".local/share/briglia"),
                    realHome.appendingPathComponent(".config/ada"), realHome.appendingPathComponent(".local/share/ada")]
            + realRoots.map { URL(fileURLWithPath: $0) }
        let outURL = URL(fileURLWithPath: out)
        guard rootsOutside([StoragePaths.configRoot, StoragePaths.dataRoot, outURL], real: real) else {
            let shown = [StoragePaths.configRoot, StoragePaths.dataRoot, outURL].map { $0.resolvingSymlinksInPath().path }
            throw PreviewRefusal(description: "a scratch or output root resolves into a real Briglia root: \(shown) vs \(real.map(\.path))")
        }
        let settings = try previewCredentials(try Data(contentsOf: URL(fileURLWithPath: credentials)))
        let text = try String(contentsOf: URL(fileURLWithPath: profile), encoding: .utf8)
        for (key, value) in settings where key != "openrouter_api_key" { try KeychainHelper.save(key: key, value: value) }
        try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: text)
        let archive = ConversationArchiveService()
        if let key = settings["openrouter_api_key"] { await archive.configure(apiKey: key) }
        var captured: UserContextMaintenanceReport?
        UserContextMaintenance.testHooks = UserContextMaintenanceHooks(onReport: { captured = $0 })
        UserContextMaintenance.testPolicy = nil
        await archive.maintainUserContextIfNeeded(event: .archive)
        guard let report = captured else { throw PreviewRefusal(description: "no maintenance run happened (profile \(text.count) chars)") }
        let result = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        try PrivateStorage.ensureDirectory(outURL)
        try PrivateStorage.writeAtomically(Data(previewMarkdown(report, before: text, after: result).utf8),
                                           to: outURL.appendingPathComponent("user-context-preview.md"), mode: 0o600)
        try PrivateStorage.writeAtomically(Data(previewLog(report, settings: settings).utf8),
                                           to: outURL.appendingPathComponent("user-context-preview.log"), mode: 0o600)
        print("Preview written to \(outURL.path) (\(report.sizeBefore) → \(report.sizeAfter) characters, outcome \(report.outcome))")
    }

    static func previewMarkdown(_ r: UserContextMaintenanceReport, before: String, after: String) -> String {
        var md = "# User-profile maintenance preview\n\n"
        md += "Size: **\(UserContextMaintenance.grouped(r.sizeBefore)) → \(UserContextMaintenance.grouped(r.sizeAfter)) characters** (target 30,000, threshold 40,000). Passes: \(r.passes). Model requests: \(r.sends). Outcome: \(r.outcome).\n\n"
        md += "Dropped \(r.drops.count) facts (\(UserContextMaintenance.grouped(r.charsDropped)) chars), shortened \(r.edits.count) (saved \(UserContextMaintenance.grouped(r.charsEditedDelta)) chars), added \(r.adds.count) (\(UserContextMaintenance.grouped(r.charsAdded)) chars). Ignored operations: \(r.opsIgnored.count).\n\n"
        md += "## Dropped\n\n"
        var lastSection: String? = nil
        for drop in r.drops {
            if drop.section != lastSection { md += "\n**\(drop.section.isEmpty ? "(no section)" : drop.section)**\n\n"; lastSection = drop.section }
            md += "- (pass \(drop.pass)) \(drop.content)\n"
        }
        md += "\n## Shortened / edited\n\n"
        for edit in r.edits {
            md += "- (pass \(edit.pass), \(edit.section.isEmpty ? "no section" : edit.section))\n  - before: \(edit.old)\n  - after: \(edit.new)\n"
        }
        md += "\n## Added\n\n"
        for add in r.adds { md += "- (pass \(add.pass)) \(add.line.trimmingCharacters(in: .whitespaces))\n" }
        md += "\n## Ignored operations\n\n"
        for reason in r.opsIgnored { md += "- \(reason)\n" }
        md += "\n## Resulting profile\n\n```\n\(after)\n```\n"
        return md
    }

    static func previewLog(_ r: UserContextMaintenanceReport, settings: [String: String]) -> String {
        let model = settings[KeychainHelper.openRouterModelKey] ?? settings[KeychainHelper.openAICompatibleModelKey] ?? "?"
        return """
        provider=\(settings[KeychainHelper.llmProviderKey] ?? "?") model=\(model)
        reason=\(r.reason.rawValue) outcome=\(r.outcome) passes=\(r.passes) sends=\(r.sends) auth_requests=\(r.authRequests)
        seconds=\(String(format: "%.1f", r.seconds)) pass_seconds=\(r.passSeconds.map { String(format: "%.1f", $0) }.joined(separator: "/"))
        tokens_in=\(r.promptTokens) tokens_out=\(r.completionTokens) finish_reasons=\(r.finishReasons.joined(separator: ","))
        size=\(r.sizeBefore)->\(r.sizeAfter) dropped_chars=\(r.charsDropped) edit_saved_chars=\(r.charsEditedDelta) added_chars=\(r.charsAdded)
        ops_applied=\(r.opsApplied) ops_ignored=\(r.opsIgnored.count)

        """
    }

    static func previewHarnessRows(_ h: UCMHarness) async throws {
        // V1: release builds refuse (same predicate as __migrate-run, checked before any work).
        h.check("V1 the preview gate refuses release versions and admits only development builds",
                !previewAdmitted(version: "0.2.49") && !previewAdmitted(version: "0.2.49-rc1") && previewAdmitted(version: "0.1.0-dev"))
        // V2: roots inside or symlinked into a real root are refused.
        let fakeReal = h.archiveDir.deletingLastPathComponent().appendingPathComponent("fake-real/.config/briglia")
        try FileManager.default.createDirectory(at: fakeReal, withIntermediateDirectories: true)
        let link = h.archiveDir.deletingLastPathComponent().appendingPathComponent("link-into-real")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fakeReal)
        h.check("V2 a root inside a real root is refused", !rootsOutside([fakeReal.appendingPathComponent("x")], real: [fakeReal]))
        h.check("V2 a root symlinked into a real root is refused", !rootsOutside([link], real: [fakeReal]))
        h.check("V2 a separate scratch root is accepted", rootsOutside([h.archiveDir], real: [fakeReal]))
        // V3: the subscription login and non-allowlisted keys are refused.
        var refused = 0
        for bad in ["{\"subscription_generation\":\"g\"}", "{\"openai_platform_api_key\":\"k\"}",
                    "{\"llm_provider\":\"openAICompatible\",\"openai_compatible_base_url\":\"https://chatgpt.com/backend-api\"}"] {
            do { _ = try previewCredentials(Data(bad.utf8)) } catch { refused += 1 }
        }
        h.check("V3 subscription settings and non-allowlisted keys are refused", refused == 3)
        // V4: against a fake provider — only the two 0600 files appear; the real-root stand-in is untouched.
        let p45 = UCMHarness.profile(size: 45_000)
        _ = try h.fresh(profile: p45)
        let outDir = h.archiveDir.deletingLastPathComponent().appendingPathComponent("preview-out-\(UUID().uuidString)")
        let profileFile = outDir.deletingLastPathComponent().appendingPathComponent("profile-copy.txt")
        try PrivateStorage.writeAtomically(Data(p45.utf8), to: profileFile)
        var captured: UserContextMaintenanceReport?
        UserContextMaintenance.testHooks?.onReport = { captured = $0 }
        h.script([UCMHarness.dropOps(for: p45, toBelow: 29_000)])
        await ConversationArchiveService().maintainUserContextIfNeeded(event: .archive)
        if let report = captured {
            try PrivateStorage.ensureDirectory(outDir)
            try PrivateStorage.writeAtomically(Data(previewMarkdown(report, before: p45, after: h.profile).utf8), to: outDir.appendingPathComponent("user-context-preview.md"), mode: 0o600)
            try PrivateStorage.writeAtomically(Data(previewLog(report, settings: [:]).utf8), to: outDir.appendingPathComponent("user-context-preview.log"), mode: 0o600)
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).sorted()
        let modes = files.map { name -> mode_t in var st = stat(); _ = stat(outDir.appendingPathComponent(name).path, &st); return st.st_mode & 0o777 }
        let log = (try? String(contentsOf: outDir.appendingPathComponent("user-context-preview.log"), encoding: .utf8)) ?? ""
        h.check("V4 exactly the two report files, both 0600; the log carries no profile text",
                files == ["user-context-preview.log", "user-context-preview.md"] && modes.allSatisfy { $0 == 0o600 } && !log.contains("Fact f1:"),
                "\(files)")
        h.check("V4 the report lists drops and the resulting profile",
                ((try? String(contentsOf: outDir.appendingPathComponent("user-context-preview.md"), encoding: .utf8)) ?? "").contains("## Dropped"))
    }
}
