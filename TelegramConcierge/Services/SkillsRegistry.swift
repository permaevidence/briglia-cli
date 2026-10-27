import Foundation

/// Skills registry — discovers and loads curated procedural "skills" from disk.
///
/// A skill is a **directory** containing a `SKILL.md` with YAML frontmatter
/// (`name`, `description`) plus any number of sibling assets (scripts,
/// templates, images, data files). This is the agentskills.io format used by
/// Claude Code, Cursor, Codex, Hermes Agent, and the rest of the standard-
/// compliant ecosystem, so skills author here are portable to those harnesses
/// and vice versa.
///
/// Canonical layout:
/// ```
/// ~/.config/briglia/skills/pdf/
///   SKILL.md          ← frontmatter + body
///   render.py         ← asset, invoked by the body via the bash tool
///   template.html     ← another asset
/// ```
///
/// A backward-compatibility shim also accepts the legacy single-file format
/// (`~/.config/briglia/skills/pdf.md`) so user skills written before the migration
/// keep working. Flat files have no assets.
///
/// Skills are NOT loaded into the system prompt — only an index (name +
/// description, one line each) is exposed at the tail of the system prefix.
/// When the agent decides a skill applies, it calls the `skill` tool with the
/// skill's name; the registry returns the body plus a listing of the skill's
/// assets (absolute paths). The body stays in context for the remainder of
/// the session.
///
/// Why tool_result instead of injection into the system prompt:
///   - System-prompt mutation mid-session invalidates the prompt cache. Tool
///     results are append-only and preserve the cache breakpoint.
///   - Skills persist in the message chain once loaded, so the procedure
///     stays available across multi-turn tasks.
///
/// The `skill` tool only READS. Skill authoring happens through the normal
/// filesystem tools: the system prompt tells the main agent where user
/// skills live and that it may create/edit/delete them on request.
enum SkillsRegistry {

    // MARK: - Types

    /// Where a skill was loaded from. Affects Settings-UI capabilities:
    /// bundled skills are read-only (no delete button), user skills can be
    /// edited and deleted like any file.
    enum Origin: Equatable {
        /// Ships inside the app bundle at `Contents/Resources/BundledSkills/`.
        case bundled
        /// Lives in `~/.config/briglia/skills/`. User-authored. Overrides a
        /// bundled skill with the same name.
        case user
    }

    /// A parsed skill with its metadata, body, and any sibling assets.
    struct Skill: Equatable, Identifiable {
        var id: String { name }

        /// Canonical short name — matches the directory name and is how the
        /// agent invokes the skill via the `skill` tool.
        let name: String

        /// One-line description. Surfaced in the system-prompt index so the
        /// agent can decide whether to invoke this skill.
        let description: String

        /// Markdown body of the skill (everything after the frontmatter).
        let body: String

        /// Path to the SKILL.md file itself. Useful for the Settings UI.
        let fileURL: URL

        /// Directory containing the skill (or `nil` for legacy flat-file
        /// skills that have no directory and no assets).
        let directoryURL: URL?

        /// Sibling files alongside SKILL.md — scripts, templates, data. The
        /// agent can invoke these via the bash tool. Empty for flat-file
        /// skills.
        let assets: [URL]

        /// Source of the skill. Bundled skills can't be deleted from the UI.
        let origin: Origin

        /// Optional UserDefaults bool key (frontmatter `requires_toggle:`).
        /// When set and the key reads false/absent, the skill is hidden from
        /// the system-prompt index — used by skills that instruct tools which
        /// are themselves feature-gated (e.g. Legal Research (Italy)). The
        /// skill can still be loaded explicitly by name.
        let requiresToggle: String?

        /// Size of the body in bytes — surfaced in the UI so the user sees
        /// which skills are bloated and should be trimmed.
        var bodyByteCount: Int { body.utf8.count }
    }

    // MARK: - Public API

    /// All skills currently on disk, sorted by name.
    static func allSkills() -> [Skill] {
        ensureDirectoryExists()
        return scanDisk()
    }

    /// Look up a skill by its canonical name. Case-insensitive.
    static func skill(named name: String) -> Skill? {
        let lower = name.lowercased()
        return allSkills().first { $0.name.lowercased() == lower }
    }

    /// No-op retained for API compatibility with call sites that used to
    /// invalidate a cache.
    static func reload() {}

    /// Delete a user-authored skill. For directory-format skills the whole
    /// directory (including assets) is removed. Flat-file skills just remove
    /// the .md. Bundled skills cannot be deleted.
    @discardableResult
    static func delete(_ name: String) -> Bool {
        guard let skill = skill(named: name), skill.origin == .user else {
            return false
        }
        let target = skill.directoryURL ?? skill.fileURL
        do {
            try FileManager.default.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    /// Compact index surfaced in the system prompt. One line per skill.
    static func systemPromptIndex() -> String {
        let skills = allSkills()
        guard !skills.isEmpty else { return "" }

        let visible = skills.filter { skill in
            guard let toggleKey = skill.requiresToggle else { return true }
            return Prefs.store.object(forKey: toggleKey) as? Bool ?? false
        }
        guard !visible.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("**Skills available** (curated procedural memory). When the user's request matches a skill's description, invoke the `skill` tool with that name to load the full procedure into context before starting. Skills are reference material, not replacements for your own judgment.")
        lines.append("")
        for skill in visible {
            lines.append("- `\(skill.name)`: \(skill.description)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Disk scanning

    /// Union of bundled + user skills. User entries override bundled entries
    /// with the same name.
    private static func scanDisk() -> [Skill] {
        var byName: [String: Skill] = [:]
        for skill in scanBundled() { byName[skill.name.lowercased()] = skill }
        for skill in scanUser()    { byName[skill.name.lowercased()] = skill }
        return byName.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func scanBundled() -> [Skill] {
        guard let resourceURL = Bundle.module.resourceURL else { return [] }
        let dir = resourceURL.appendingPathComponent("BundledSkills", isDirectory: true)
        return scanDirectory(dir, origin: .bundled)
    }

    private static func scanUser() -> [Skill] {
        scanDirectory(skillsDirectoryURL(), origin: .user)
    }

    /// Scan a root directory for skills. Two layouts are recognized:
    /// 1. `<root>/<name>/SKILL.md` — canonical agentskills.io directory form
    /// 2. `<root>/<name>.md`       — legacy flat-file form (backward compat)
    ///
    /// If both layouts define the same skill name, the directory form wins.
    private static func scanDirectory(_ root: URL, origin: Origin) -> [Skill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var byName: [String: Skill] = [:]

        // Pass 1: legacy flat-file skills.
        for url in entries where url.pathExtension.lowercased() == "md" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let parsed = parse(
                raw,
                fileURL: url,
                directoryURL: nil,
                assets: [],
                origin: origin
            ) else { continue }
            byName[parsed.name.lowercased()] = parsed
        }

        // Pass 2: directory-form skills (override flat files with same name).
        for url in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillMd = url.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillMd.path) else { continue }
            guard let raw = try? String(contentsOf: skillMd, encoding: .utf8) else { continue }

            let assets = discoverAssets(in: url, excluding: skillMd)
            guard let parsed = parse(
                raw,
                fileURL: skillMd,
                directoryURL: url,
                assets: assets,
                origin: origin
            ) else { continue }
            byName[parsed.name.lowercased()] = parsed
        }

        return Array(byName.values)
    }

    /// Collect files (not subdirectories) inside a skill directory, excluding
    /// SKILL.md itself. Paths are returned absolute for direct use from the
    /// bash tool. Hidden files are skipped.
    private static func discoverAssets(in dir: URL, excluding skillMd: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "SKILL.md", fileURL.deletingLastPathComponent().path == dir.path {
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            out.append(fileURL)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Parse a SKILL.md (or legacy flat .md) with YAML frontmatter. Only
    /// `name` and `description` are interpreted; unknown keys are ignored.
    private static func parse(
        _ raw: String,
        fileURL: URL,
        directoryURL: URL?,
        assets: [URL],
        origin: Origin
    ) -> Skill? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[0].trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        var frontmatterEnd = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                frontmatterEnd = i
                break
            }
        }
        guard frontmatterEnd > 0 else { return nil }

        var name = ""
        var description = ""
        var requiresToggle: String?
        for i in 1..<frontmatterEnd {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "name": name = value
            case "description": description = value
            case "requires_toggle": requiresToggle = value.isEmpty ? nil : value
            default: continue
            }
        }

        // Fall back to directory name (or filename stem) if frontmatter omits `name`.
        if name.isEmpty {
            name = directoryURL?.lastPathComponent
                ?? fileURL.deletingPathExtension().lastPathComponent
        }
        guard !name.isEmpty, !description.isEmpty else { return nil }

        let bodyStart = frontmatterEnd + 1
        let body = lines[bodyStart...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Skill(
            name: name,
            description: description,
            body: body,
            fileURL: fileURL,
            directoryURL: directoryURL,
            assets: assets,
            origin: origin,
            requiresToggle: requiresToggle
        )
    }

    /// Canonical skills directory: `~/.config/briglia/skills/`.
    static func skillsDirectoryURL() -> URL {
        StoragePaths.configRoot
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Ensure the skills directory exists.
    @discardableResult
    static func ensureDirectoryExists() -> Bool {
        let dir = skillsDirectoryURL()
        if FileManager.default.fileExists(atPath: dir.path) { return true }
        do {
            // Under the config root: owner-only like every other root child.
            try PrivateStorage.ensureDirectory(dir)
            return true
        } catch {
            return false
        }
    }
}
