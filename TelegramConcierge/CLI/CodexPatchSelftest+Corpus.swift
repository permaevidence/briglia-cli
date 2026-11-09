import Foundation

/// §14.4 Codex scenario corpus and §14.5 golden differential corpus.
extension CodexPatchSelftest {

    // MARK: Scenarios

    /// Briglia expectations that differ from Codex (divergence IDs, §6.9).
    /// Every other scenario must match Codex's `expected/` byte for byte.
    static let scenarioDivergences: [String: String] = [
        "010_move_overwrites_existing_destination": "D3 (refused without knowledge; the fresh variant must match Codex)",
        "011_add_overwrites_existing_file": "D3 (refused without knowledge; the fresh variant must match Codex)",
        "015_failure_after_partial_success_leaves_changes": "TX (rolled back; Codex leaves the Add behind)",
    ]

    /// The only transformation: relative paths in the four header kinds are
    /// rewritten to absolute paths under the scenario's temp root.
    static func absolutize(_ patch: String, root: String) -> String {
        let markers = ["*** Add File: ", "*** Delete File: ", "*** Update File: ", "*** Move to: "]
        var out: [String] = []
        for line in patch.components(separatedBy: "\n") {
            var rewritten = line
            for marker in markers {
                if let range = line.range(of: marker) {
                    let lead = line[line.startIndex..<range.lowerBound]
                    if lead.allSatisfy({ $0 == " " || $0 == "\t" }) {
                        let rest = String(line[range.upperBound...])
                        rewritten = String(lead) + marker + root + "/" + rest
                    }
                    break
                }
            }
            out.append(rewritten)
        }
        return out.joined(separator: "\n")
    }

    static func copyTree(_ from: String, _ to: String) {
        try? FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: from),
              let names = try? FileManager.default.contentsOfDirectory(atPath: from) else { return }
        for name in names {
            try? FileManager.default.copyItem(atPath: from + "/" + name, toPath: to + "/" + name)
        }
    }

    static func seedAll(_ t: CPTest, _ root: String) async {
        for (rel, entry) in snapshot(root) where entry.kind == "f" { await t.seed(root + "/" + rel) }
    }

    /// Content and type only (Codex's expected trees carry no modes).
    static func contentTree(_ root: String) -> [String: String] {
        snapshot(root).mapValues { e in e.kind == "f" ? "f:" + e.payload.base64EncodedString() : e.kind }
    }

    static func runScenario(_ t: CPTest, _ dir: String, seed: Bool) async -> (root: String, result: CodexPatch.Result) {
        let root = t.dir("sc")
        copyTree(dir + "/input", root)
        if seed { await seedAll(t, root) }
        let patch = String(decoding: FileManager.default.contents(atPath: dir + "/patch.txt") ?? Data(), as: UTF8.self)
        return (root, await t.apply(absolutize(patch, root: root)))
    }

    static func scenarioCorpus(_ t: CPTest) async {
        let base = t.fixtures + "/pinned/scenarios"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).filter { $0.first?.isNumber == true }.sorted()
        t.check("C.0 all 25 pinned scenario directories are present", names.count == 25, "\(names.count): \(names)")
        await FileTimeTracker.shared.resetGPTForTesting()
        for name in names {
            let dir = base + "/" + name
            let expectedTree = contentTree(dir + "/expected")
            if let divergence = scenarioDivergences[name] {
                let inputTree = contentTree(dir + "/input")
                let (root, r) = await runScenario(t, dir, seed: false)
                t.check("C.\(name) Briglia expectation: \(divergence)", contentTree(root) == inputTree && r.outcome.status != .applied, r.text)
                if name != "015_failure_after_partial_success_leaves_changes" {
                    let (root2, r2) = await runScenario(t, dir, seed: true)
                    t.check("C.\(name)+fresh matches Codex once the target is known", contentTree(root2) == expectedTree, r2.text)
                }
                continue
            }
            let (root, r) = await runScenario(t, dir, seed: true)
            t.check("C.\(name) matches Codex's expected tree", contentTree(root) == expectedTree,
                    "\(r.text) — tree \(contentTree(root).keys.sorted()) vs \(expectedTree.keys.sorted())")
        }
        await FileTimeTracker.shared.resetGPTForTesting()
    }

    // MARK: Golden differential corpus

    struct GoldenCase: Decodable {
        let id: String
        let files: [String: String]          // rel → base64
        let patch: String                    // {ROOT} placeholder
        let codex: CodexOutcome
        let divergence: String?
        let briglia: BrigliaExpectation?     // only for divergences
        struct CodexOutcome: Decodable {
            let exit: Int
            let stdout: String
            let stderr: String
            let tree: [String: String]
        }
        struct BrigliaExpectation: Decodable {
            let applied: Bool
            let tree: [String: String]
        }
    }

    static func goldenTree(_ root: String) -> [String: String] {
        snapshot(root).compactMapValues { e in e.kind == "f" ? e.payload.base64EncodedString() : nil }
    }

    /// Codex's standalone stderr → the engine message Briglia reports after
    /// `apply_patch verification failed: ` (parse errors are formatted by
    /// `apply_patch_with_options`; the verifier uses the Display form).
    static func codexMessageCore(_ stderr: String) -> String {
        var s = stderr
        if s.hasSuffix("\n") { s.removeLast() }   // exactly the `writeln!` newline
        if s.hasPrefix("Invalid patch: ") { return "invalid patch: " + s.dropFirst("Invalid patch: ".count) }
        if s.hasPrefix("Invalid patch hunk on line "), let colon = s.range(of: ": ") {
            let n = s["Invalid patch hunk on line ".endIndex..<colon.lowerBound]
            return "invalid hunk at line \(n), " + s[colon.upperBound...]
        }
        return s
    }

    static func brigliaMessageCore(_ text: String) -> String? {
        let prefix = "apply_patch verification failed: "
        guard text.hasPrefix(prefix) else { return nil }
        var core = String(text.dropFirst(prefix.count))
        for cut in ["\nNearest lines in the file:", "\nnote: ", " Hint: "] {
            if let r = core.range(of: cut) { core = String(core[..<r.lowerBound]) }
        }
        return core
    }

    static func goldenCorpus(_ t: CPTest) async {
        let path = t.fixtures + "/golden/cases.jsonl"
        guard let data = FileManager.default.contents(atPath: path) else {
            t.check("G.0 golden corpus present", false, path); return
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        var cases: [GoldenCase] = []
        for line in lines {
            if let c = try? JSONDecoder().decode(GoldenCase.self, from: Data(line.utf8)) { cases.append(c) }
        }
        t.check("G.0 golden corpus decodes (\(cases.count) cases)", cases.count == lines.count && cases.count >= 2000, "\(cases.count)/\(lines.count)")
        var ok = 0
        var failures: [String] = []
        var byOutcome: [String: Int] = [:]
        for c in cases {
            await FileTimeTracker.shared.resetGPTForTesting()
            let root = t.dir("g")
            for (rel, b64) in c.files { t.write(root + "/" + rel, Data(base64Encoded: b64) ?? Data()) }
            await seedAll(t, root)
            let r = await t.apply(c.patch.replacingOccurrences(of: "{ROOT}", with: root))
            let tree = goldenTree(root)
            let input = c.files
            var pass = false
            var why = ""
            if let expectation = c.briglia {
                pass = (r.outcome.status == .applied) == expectation.applied && tree == expectation.tree
                why = "divergence \(c.divergence ?? "?"): status \(r.outcome.status) tree-match \(tree == expectation.tree)"
                byOutcome["divergence:" + (c.divergence ?? "?"), default: 0] += 1
            } else if c.codex.exit == 0 {
                let codexOut = c.codex.stdout.replacingOccurrences(of: "{ROOT}", with: root).trimmingCharacters(in: .newlines)
                let summary = r.text.components(separatedBy: "\n").filter { !$0.hasPrefix("note: ") }.joined(separator: "\n")
                pass = r.outcome.status == .applied && tree == c.codex.tree && summary == codexOut
                why = "status \(r.outcome.status) tree-match \(tree == c.codex.tree) summary-match \(summary == codexOut): \(r.text.prefix(300))"
                byOutcome["applied", default: 0] += 1
            } else {
                let engineError = r.outcome.category == .parse || r.outcome.category == .context
                let core = brigliaMessageCore(r.text)
                let codexCore = codexMessageCore(c.codex.stderr.replacingOccurrences(of: "{ROOT}", with: root))
                pass = r.outcome.status != .applied && tree == input && (!engineError || core == codexCore)
                why = "status \(r.outcome.status) unchanged \(tree == input) msg [\(core ?? "nil")] vs [\(codexCore)]"
                byOutcome["refused:" + (r.outcome.category?.rawValue ?? "?"), default: 0] += 1
            }
            if pass { ok += 1 } else { failures.append("\(c.id): \(why)") }
            try? FileManager.default.removeItem(atPath: root)
        }
        await FileTimeTracker.shared.resetGPTForTesting()
        t.check("G.1 the Swift engine reproduces every pinned Codex outcome (\(ok)/\(cases.count); \(byOutcome.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))",
                ok == cases.count && !cases.isEmpty, failures.prefix(40).joined(separator: " || "))
    }
}
