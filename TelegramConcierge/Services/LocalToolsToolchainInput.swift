import Foundation

/// The advisory list as ONE MORE INPUT to the userdata toolchain's own
/// policy (security plan v16 §9.5.6). Toolchain prefix packages never get
/// `localvuln.json` rows (the inventory skips Briglia-owned paths); their
/// advisories feed the §9.4 UT table in `notice.json`, keyed by advisory
/// class, with the release manifest's `componentAdvisories` as the other
/// source.
///
/// Status in this build: v0.2.61 parses `componentAdvisories` but has no
/// §9.4 UT advisory table or notice yet ("UT advisory notices arrive with
/// Phase 3", `UpdateNoticeModel.swift`). This file therefore provides the
/// conversion and the cross-source merge as pure, tested functions; the UT
/// table, its closure-evidence gate and its notice are the §9.4 work that
/// consumes them. Nothing here sends anything.
extension LocalTools {
    struct ToolchainAdvisoryInput: Equatable {
        var source: String
        var ids: [String]
        var affected: LocalAdvisory.Affected
        var fixedVersion: String?
        var withdrawn: Bool
    }

    /// List entries for the DEVICE's base release (never a hard-coded
    /// `noble`), as row inputs: identity, IDs, ranges, fixed version.
    static func toolchainInputs(_ doc: LocalAdvisory.Document, base: OSRelease) -> [ToolchainAdvisoryInput] {
        var out: [ToolchainAdvisoryInput] = []
        for e in doc.entries where e.identity.kind == .deb && e.identity.distro == base.id && e.identity.release == base.versionId {
            for a in e.advisories {
                out.append(ToolchainAdvisoryInput(source: e.identity.source ?? "?", ids: a.ids, affected: a.affected,
                                                  fixedVersion: a.remediation?.fixed.first(where: { $0.line == nil })?.version
                                                      ?? a.remediation?.fixed.first?.version,
                                                  withdrawn: a.withdrawn))
            }
        }
        return out
    }

    /// One advisory class of the UT table as both sources know it.
    struct ToolchainClass: Equatable {
        var source: String
        var ids: [String]
        /// The higher fixed version when the sources disagree (conservative).
        var fixedVersion: String?
        var inManifest: Bool
        var inList: Bool
    }

    /// Cross-source merge (§9.5.6): an advisory seen in the release manifest
    /// and in the list (by any shared ID, for the same source package) is ONE
    /// class, whichever was seen first; a source that omits a class never
    /// erases it; a class leaves only when the list withdraws it and no
    /// release source still carries it (the §9.4 positive version rules are
    /// applied by the table, not here). IDs merge up to 16.
    static func mergeToolchainClasses(existing: [ToolchainClass], manifest: [ReleaseSecurity.ComponentAdvisory],
                                      list: [ToolchainAdvisoryInput], base: OSRelease) -> [ToolchainClass] {
        var classes = existing.map { c -> ToolchainClass in var c = c; c.inManifest = false; c.inList = false; return c }
        func absorb(source: String, ids: [String], fixed: String?, fromManifest: Bool) {
            let upper = ids.map { $0.uppercased() }
            let matches = classes.indices.filter { classes[$0].source == source && !Set(classes[$0].ids).isDisjoint(with: upper) }
            if matches.isEmpty {
                classes.append(ToolchainClass(source: source, ids: Array(upper.prefix(16)), fixedVersion: fixed,
                                              inManifest: fromManifest, inList: !fromManifest))
                return
            }
            var survivor = classes[matches[0]]
            for i in matches.dropFirst() {
                for id in classes[i].ids where !survivor.ids.contains(id) && survivor.ids.count < 16 { survivor.ids.append(id) }
                survivor.fixedVersion = higher(survivor.fixedVersion, classes[i].fixedVersion)
                survivor.inManifest = survivor.inManifest || classes[i].inManifest
                survivor.inList = survivor.inList || classes[i].inList
            }
            for id in upper where !survivor.ids.contains(id) && survivor.ids.count < 16 { survivor.ids.append(id) }
            survivor.fixedVersion = higher(survivor.fixedVersion, fixed)
            if fromManifest { survivor.inManifest = true } else { survivor.inList = true }
            for i in matches.reversed() { classes.remove(at: i) }
            classes.insert(survivor, at: min(matches[0], classes.count))
        }
        for c in manifest where c.ecosystem == "deb" && c.identity["distro"] == base.id && c.identity["release"] == base.versionId {
            guard let source = c.identity["sourcePackage"] ?? c.identity["binaryPackage"] else { continue }
            absorb(source: source, ids: c.advisories, fixed: c.minimumSafe, fromManifest: true)
        }
        var withdrawnIds: [(String, Set<String>)] = []
        for a in list {
            if a.withdrawn { withdrawnIds.append((a.source, Set(a.ids))); continue }
            absorb(source: a.source, ids: a.ids, fixed: a.fixedVersion, fromManifest: false)
        }
        classes.removeAll { c in
            !c.inManifest && !c.inList && withdrawnIds.contains { $0.0 == c.source && !$0.1.isDisjoint(with: c.ids) }
        }
        return classes
    }

    private static func higher(_ a: String?, _ b: String?) -> String? {
        guard let a else { return b }
        guard let b else { return a }
        guard let c = LocalToolsVersion.debCompare(a, b) else { return a }
        return c >= 0 ? a : b
    }
}
