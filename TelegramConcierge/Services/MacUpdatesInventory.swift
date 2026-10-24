import Foundation

/// Read-only evidence for the macOS weekly "updates are waiting" message
/// (§9.5.9): Homebrew's cached catalogue (formulae AND casks), the Cellar
/// keg the inventory resolved, the Caskroom, `var/homebrew/pinned`, the
/// LibreOffice app bundle, and Apple's cached Software Update record. Files
/// only: `brew` is never executed, nothing goes to the network.
extension MacUpdates {
    struct Catalogue: Equatable {
        var formulae: [String: String]
        /// nil = a legacy formula-only catalogue (casks are then unknown).
        var casks: [String: (version: String, autoUpdates: Bool)]?
        var asOf: Date?

        static func == (a: Catalogue, b: Catalogue) -> Bool {
            a.formulae == b.formulae && a.asOf == b.asOf
                && a.casks?.mapValues { "\($0.version)|\($0.autoUpdates)" } == b.casks?.mapValues { "\($0.version)|\($0.autoUpdates)" }
        }
    }

    /// `{"payload": "<json>"}` with `formulae` and (Homebrew 5+) `casks`.
    static func parseCatalogue(_ data: Data, asOf: Date?) -> Catalogue? {
        guard let formulae = SecurityStatus.parseBrewCatalogue(data) else { return nil }
        var casks: [String: (version: String, autoUpdates: Bool)]? = nil
        if let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = outer["payload"] as? String, let pd = text.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: pd) as? [String: Any],
           let raw = payload["casks"] as? [String: Any] {
            var out: [String: (version: String, autoUpdates: Bool)] = [:]
            for (token, v) in raw {
                guard let c = v as? [String: Any], let version = c["version"] as? String else { continue }
                out[token] = (version, (c["auto_updates"] as? Bool) ?? false)
            }
            casks = out
        }
        return Catalogue(formulae: formulae, casks: casks, asOf: asOf)
    }

    /// A cask version as a plain dotted version: an optional ",build" suffix
    /// is ignored; anything else is not comparable.
    static func caskVersion(_ raw: String) -> String? {
        let base = String(raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard base.range(of: "^[0-9]{1,6}(\\.[0-9]{1,6}){0,4}$", options: .regularExpression) != nil else { return nil }
        return base
    }

    static func threeParts(_ v: String) -> String? {
        let p = v.split(separator: ".")
        guard p.count >= 2, p.allSatisfy({ Int($0) != nil }) else { return nil }
        return p.prefix(3).joined(separator: ".")
    }

    static func line(_ v: String) -> String? {
        let p = v.split(separator: ".")
        guard p.count >= 2 else { return nil }
        return "\(p[0]).\(p[1])"
    }

    /// LibreOffice from the website (§9.5.9, branch-aware, v18): true =
    /// waiting, false = positively not waiting, nil = no evidence.
    static func libreOfficeWaiting(installed: String, fresh: String?, still: String?) -> (Bool, String?)? {
        guard let inst = threeParts(installed), let il = line(inst),
              let f = fresh.flatMap(caskVersion).flatMap(threeParts), let s = still.flatMap(caskVersion).flatMap(threeParts),
              let fl = line(f), let sl = line(s) else { return nil }
        func cmp(_ a: String, _ b: String) -> Int? { LocalToolsVersion.dottedCompare(a, b) }
        if il == fl { guard let c = cmp(f, inst) else { return nil }; return (c > 0, f) }
        if il == sl { guard let c = cmp(s, inst) else { return nil }; return (c > 0, s) }
        guard let a = cmp(il + ".0", sl + ".0"), let b = cmp(il + ".0", fl + ".0") else { return nil }
        if a < 0 && b < 0 { return (true, s) }      // older than both lines
        return (false, nil)                          // newer than both, or between: no reference
    }

    struct SoftwareUpdate: Equatable {
        struct Entry: Equatable { var key: String; var name: String }
        var entries: [Entry]
        var asOf: Date
    }

    static func safeDisplayName(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.count <= 80, !s.contains("`"), !s.contains("\n"), !s.contains("\r"),
              s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return s
    }

    /// Apple's cached record; nil when unreadable, undated, stale or in the future.
    static func softwareUpdate(_ plist: [String: Any]?, now: Date) -> SoftwareUpdate? {
        guard let plist, let asOf = plist["LastSuccessfulDate"] as? Date,
              now.timeIntervalSince(asOf) <= freshness, asOf.timeIntervalSince(now) <= futureSkew,
              let list = plist["RecommendedUpdates"] as? [Any] else { return nil }
        var out: [SoftwareUpdate.Entry] = []
        for raw in list {
            guard let u = raw as? [String: Any] else { return nil }
            let id = (u["Product Key"] as? String) ?? (u["Identifier"] as? String)
            guard let id, id.range(of: "^[A-Za-z0-9 ._:+-]{1,96}$", options: .regularExpression) != nil else { return nil }
            out.append(.init(key: "macos:" + id, name: safeDisplayName(u["Display Name"] as? String) ?? "an update"))
        }
        return SoftwareUpdate(entries: Array(out.prefix(16)), asOf: asOf)
    }

    /// The whole evaluation from already-read inputs (pure; fake-able).
    static func evaluate(resolutions: [LocalTools.Resolution], catalogue: Catalogue?, pinned: (String) -> Bool?,
                         softwareUpdatePlist: [String: Any]?, softwareUpdateReadable: Bool, now: Date) -> Evaluation {
        var waiting: [Item] = [], resolved: [String] = [], tools: [ToolLine] = [], problems: [LocalTools.Text] = []
        var complete = true
        let fresh: Bool = {
            guard let c = catalogue, let at = c.asOf else { return false }
            return now.timeIntervalSince(at) <= freshness && at.timeIntervalSince(now) <= futureSkew
        }()
        if catalogue == nil {
            problems.append(.init("Homebrew's catalogue is not on disk (run `brew update` once)", "il catalogo di Homebrew non è sul disco (esegui `brew update` una volta)"))
        } else if !fresh {
            problems.append(.init("Homebrew's catalogue is more than 7 days old (run `brew update`)", "il catalogo di Homebrew ha più di 7 giorni (esegui `brew update`)"))
        }
        if !fresh { complete = false }
        func unknownLine(_ tool: LocalTools.WatchTool, _ i: LocalTools.Instance?, _ why: LocalTools.Text, kind: Kind?) {
            complete = false
            tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i?.installedVersion, available: nil,
                                  state: .unknown, reason: why, command: nil, kind: kind))
        }
        for r in resolutions {
            guard let tool = LocalTools.tool(r.toolId) else { continue }
            switch r {
            case .absent:
                for f in tool.brewFormulae { resolved.append("brew:" + f) }
                for t in tool.macApp?.caskTokens ?? [] { resolved.append("cask:" + t) }
                if tool.macApp != nil { resolved.append("app:" + tool.id) }
            case .unknown(_, let why):
                if tool.brewFormulae.isEmpty && tool.macApp == nil { continue }
                complete = false
                tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: nil, available: nil, state: .unknown,
                                      reason: why, command: nil, kind: nil))
            case .present(let i):
                switch i.identity.kind {
                case .brew:
                    let formula = i.identity.formula ?? "?"
                    let key = "brew:" + formula
                    if let why = i.originProblem { unknownLine(tool, i, why, kind: .formula); continue }
                    guard LocalTools.validBrewName(formula) else {
                        unknownLine(tool, i, .init("unrecognised formula name", "nome di formula non riconosciuto"), kind: .formula); continue
                    }
                    if pinned(formula) == true {
                        tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i.installedVersion, available: nil,
                                              state: .pinned, reason: nil, command: formula, kind: .formula))
                        resolved.append(key)
                        continue
                    }
                    guard pinned(formula) != nil else {
                        unknownLine(tool, i, .init("Homebrew's pin records cannot be read", "le informazioni di blocco di Homebrew non si possono leggere"), kind: .formula); continue
                    }
                    guard fresh, let cat = catalogue?.formulae[formula] else {
                        unknownLine(tool, i, fresh ? .init("not in Homebrew's catalogue", "non è nel catalogo di Homebrew") : .init("no fresh Homebrew catalogue", "nessun catalogo di Homebrew aggiornato"), kind: .formula); continue
                    }
                    guard let c = LocalToolsVersion.brewCompare(cat, i.installedVersion) else {
                        unknownLine(tool, i, .init("the versions cannot be compared", "le versioni non si possono confrontare"), kind: .formula); continue
                    }
                    if c > 0 {
                        waiting.append(Item(key: key, kind: .formula, toolId: tool.id, name: tool.name,
                                            installed: i.installedVersion, available: cat, command: formula))
                        tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i.installedVersion, available: cat,
                                              state: .waiting, reason: nil, command: formula, kind: .formula))
                    } else {
                        resolved.append(key)
                        tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i.installedVersion, available: cat,
                                              state: .current, reason: nil, command: formula, kind: .formula))
                    }
                case .cask:
                    let token = i.identity.token ?? "?"
                    let key = "cask:" + token
                    guard fresh, let casks = catalogue?.casks else {
                        unknownLine(tool, i, catalogue?.casks == nil && fresh
                                    ? .init("Homebrew's catalogue has no cask data", "il catalogo di Homebrew non ha dati sui cask")
                                    : .init("no fresh Homebrew catalogue", "nessun catalogo di Homebrew aggiornato"), kind: .cask); continue
                    }
                    guard let entry = casks[token], let cat = caskVersion(entry.version), let inst = caskVersion(i.installedVersion),
                          let c = LocalToolsVersion.dottedCompare(cat, inst) else {
                        unknownLine(tool, i, .init("the cask versions cannot be compared", "le versioni del cask non si possono confrontare"), kind: .cask); continue
                    }
                    if entry.autoUpdates {
                        resolved.append(key)
                        tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i.installedVersion, available: cat,
                                              state: .current, reason: .init("updates itself", "si aggiorna da solo"), command: token, kind: .cask))
                    } else if c > 0 {
                        waiting.append(Item(key: key, kind: .cask, toolId: tool.id, name: tool.name,
                                            installed: i.installedVersion, available: cat, command: token))
                        tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i.installedVersion, available: cat,
                                              state: .waiting, reason: nil, command: token, kind: .cask))
                    } else {
                        resolved.append(key)
                        tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i.installedVersion, available: cat,
                                              state: .current, reason: nil, command: token, kind: .cask))
                    }
                case .vendor where i.vendorVia == "app" && tool.macApp != nil:
                    let key = "app:" + tool.id
                    guard fresh, let casks = catalogue?.casks,
                          let w = libreOfficeWaiting(installed: i.installedVersion, fresh: casks["libreoffice"]?.version,
                                                     still: casks["libreoffice-still"]?.version) else {
                        unknownLine(tool, i, .init("no fresh reference versions in Homebrew's catalogue", "nessuna versione di riferimento aggiornata nel catalogo di Homebrew"), kind: .app); continue
                    }
                    if w.0 {
                        waiting.append(Item(key: key, kind: .app, toolId: tool.id, name: tool.name,
                                            installed: i.installedVersion, available: w.1, command: nil))
                        tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i.installedVersion, available: w.1,
                                              state: .waiting, reason: nil, command: nil, kind: .app))
                    } else {
                        resolved.append(key)
                        tools.append(ToolLine(toolId: tool.id, name: tool.name, installed: i.installedVersion, available: nil,
                                              state: .current, reason: nil, command: nil, kind: .app))
                    }
                default:
                    continue        // vendor Node / Python / browsers / deb: not this message
                }
            }
        }
        let su = softwareUpdate(softwareUpdatePlist, now: now)
        var suAsOf: Date? = nil
        if let su {
            suAsOf = su.asOf
            for e in su.entries {
                waiting.append(Item(key: e.key, kind: .macos, toolId: nil, name: e.name, installed: nil, available: nil, command: nil))
            }
            resolved.append("macos:*")     // every other macOS key: positively gone from a fresh record
        } else {
            complete = false
            problems.append(.init(softwareUpdateReadable ? "macOS Software Update has no recent record" : "macOS Software Update status cannot be read",
                                  softwareUpdateReadable ? "Aggiornamento Software di macOS non ha un controllo recente" : "lo stato di Aggiornamento Software di macOS non si può leggere"))
        }
        return Evaluation(at: now, waiting: waiting, resolved: resolved, complete: complete,
                          catalogueAsOf: catalogue?.asOf, softwareUpdateAsOf: suAsOf, tools: tools, problems: problems)
    }

    /// Live inputs (macOS only).
    static func liveEvaluation(_ p: LocalTools.Probe, now: Date) -> Evaluation {
        let resolutions = LocalTools.inventory(p)
        let mac = MacInventory(probe: p)
        let prefix = mac.brewPrefix
        var catalogue: Catalogue? = nil
        if prefix != nil {
            let cache = p.environment["HOMEBREW_CACHE"] ?? p.home + "/Library/Caches/Homebrew"
            let ss = SecurityStatus.Probe(
                isMacOS: true, isUbuntuTouch: false, home: p.home, environment: p.environment, now: p.now,
                fileExists: { p.readData($0) != nil || p.listDirectory($0) != nil },
                readData: p.readData, modificationDate: p.modificationDate, listDirectory: p.listDirectory,
                findBinary: p.findBinary, run: { _, _, _ in (127, "") })
            if let path = SecurityStatus.brewCataloguePath(ss, cache: cache), let data = p.readData(path) {
                catalogue = parseCatalogue(data, asOf: p.modificationDate(path))
            }
        }
        let pinnedDir = prefix.map { $0 + "/var/homebrew/pinned" }
        let pins: [String]?? = pinnedDir.map { dir in p.listDirectory(dir) ?? (p.resolve(dir) == nil ? [] : nil) }
        let suData = p.readData("/Library/Preferences/com.apple.SoftwareUpdate.plist")
        let plist = suData.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return evaluate(resolutions: resolutions, catalogue: catalogue,
                        pinned: { f in
                            guard let pins else { return false }      // no Homebrew prefix: nothing pinned
                            guard let list = pins else { return nil }
                            return list.contains(f)
                        },
                        softwareUpdatePlist: plist, softwareUpdateReadable: plist != nil, now: now)
    }
}
