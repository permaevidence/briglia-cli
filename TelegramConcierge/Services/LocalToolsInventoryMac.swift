import Foundation

/// macOS inventory: Homebrew kegs read from the Cellar and their install
/// receipts (brew is never run, §9.5.1/§7.4: tap + formula + version_scheme
/// identity, HEAD → unknown, the keg the resolved executable lives in is the
/// one compared); vendor builds from their bundles. Apple's own tools
/// (/usr/bin/git, curl, tar …) are Apple's: unknown here.
struct MacInventory {
    let probe: LocalTools.Probe
    typealias T = LocalTools

    var brewPrefix: String? {
        if let p = probe.environment["HOMEBREW_PREFIX"] { return p }
        guard let brew = probe.findBinary("brew") else { return nil }
        return ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    func run() -> [T.Resolution] {
        let prefix = brewPrefix
        let cellar = probe.environment["HOMEBREW_CELLAR"] ?? prefix.map { $0 + "/Cellar" }
        let catalogue = prefix != nil ? brewCatalogue() : nil
        return T.watchlist.map { resolve($0, cellar: cellar, catalogue: catalogue) }
    }

    /// Homebrew's cached catalogue (name → current version) and its date.
    func brewCatalogue() -> (versions: [String: String], asOf: Date?)? {
        let cache = probe.environment["HOMEBREW_CACHE"] ?? probe.home + "/Library/Caches/Homebrew"
        let ssProbe = SecurityStatus.Probe(
            isMacOS: true, isUbuntuTouch: false, home: probe.home, environment: probe.environment, now: probe.now,
            fileExists: { probe.readData($0) != nil || probe.listDirectory($0) != nil },
            readData: probe.readData, modificationDate: probe.modificationDate, listDirectory: probe.listDirectory,
            findBinary: probe.findBinary, run: probe.run)
        guard let path = SecurityStatus.brewCataloguePath(ssProbe, cache: cache), let data = probe.readData(path),
              let versions = SecurityStatus.parseBrewCatalogue(data) else { return nil }
        return (versions, probe.modificationDate(path))
    }

    func resolve(_ tool: T.WatchTool, cellar: String?, catalogue: (versions: [String: String], asOf: Date?)?) -> T.Resolution {
        // Apps first (LibreOffice cask / bundle, Chrome).
        if let app = tool.macApp, let r = resolveApp(tool, app, cellar: cellar) { return r }
        var path: String? = nil
        for exe in tool.executables { if let p = probe.findBinary(exe) { path = p; break } }
        if path == nil, let cellar {
            // Libraries (pango, cairo, gdk-pixbuf): the opt-linked keg.
            for formula in tool.brewFormulae {
                if let keg = probe.resolve((cellar as NSString).deletingLastPathComponent + "/opt/" + formula),
                   keg.hasPrefix(cellar + "/") {
                    return brewInstance(tool, path: keg, cellar: cellar, catalogue: catalogue)
                }
            }
        }
        guard let p = path else {
            if tool.macApp != nil || tool.executables.isEmpty && tool.brewFormulae.isEmpty { return .absent(toolId: tool.id) }
            // Positive absence needs a readable Cellar (or no Homebrew at all).
            if let cellar, probe.listDirectory(cellar) == nil {
                return .unknown(toolId: tool.id, reason: T.Text("Homebrew's Cellar cannot be read", "la Cellar di Homebrew non si può leggere"))
            }
            return .absent(toolId: tool.id)
        }
        let real = probe.resolve(p) ?? p
        if probe.owned(real) || probe.owned(p) {
            return .unknown(toolId: tool.id, reason: T.Text("Briglia's own copy (updated with Briglia)", "copia di Briglia (aggiornata con Briglia)"))
        }
        if let cellar, real.hasPrefix(cellar + "/") {
            return brewInstance(tool, path: real, cellar: cellar, catalogue: catalogue)
        }
        if real.hasPrefix("/usr/bin/") || real.hasPrefix("/bin/") || real.hasPrefix("/System/") || real.hasPrefix("/Library/Developer/CommandLineTools/") || real.contains("/Xcode.app/") {
            return .unknown(toolId: tool.id, reason: T.Text("provided by macOS (Software Update keeps it current); not covered here",
                                                           "fornito da macOS (lo aggiorna Aggiornamento Software); non coperto qui"))
        }
        if tool.vendorNode, let v = versionOutput(p, ["--version"]), LocalToolsVersion.parseSemver(v) != nil {
            return vendorInstance(tool, vendor: "nodejs.org", product: "node", flavour: "official",
                                  version: String(v.drop(while: { $0 == "v" })), path: p)
        }
        if tool.vendorPython, real.contains("/Library/Frameworks/Python.framework/"),
           let v = versionOutput(p, ["--version"]).map({ $0.replacingOccurrences(of: "Python ", with: "") }),
           LocalToolsVersion.dottedCompare(v, v) != nil {
            return vendorInstance(tool, vendor: "python.org", product: "cpython", flavour: "official", version: v, path: p)
        }
        return .unknown(toolId: tool.id, reason: T.Text("\(p) is not from Homebrew or a recognised vendor build",
                                                       "\(p) non viene da Homebrew né da una build riconosciuta del produttore"))
    }

    /// `<cellar>/<formula>/<keg>/...` → a brew instance.
    func brewInstance(_ tool: T.WatchTool, path: String, cellar: String,
                      catalogue: (versions: [String: String], asOf: Date?)?) -> T.Resolution {
        let rel = path.dropFirst(cellar.count + 1).split(separator: "/")
        guard rel.count >= 2 else { return .unknown(toolId: tool.id, reason: T.Text("unrecognised Homebrew layout", "struttura di Homebrew non riconosciuta")) }
        let formula = String(rel[0]), keg = String(rel[1])
        guard T.validBrewName(formula) else {
            return .unknown(toolId: tool.id, reason: T.Text("unrecognised Homebrew formula name", "nome di formula Homebrew non riconosciuto"))
        }
        let kegPath = cellar + "/" + formula + "/" + keg
        let receipt = probe.readData(kegPath + "/INSTALL_RECEIPT.json")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let source = receipt?["source"] as? [String: Any]
        let tap = source?["tap"] as? String
        let versions = source?["versions"] as? [String: Any]
        let scheme = (versions?["version_scheme"] as? Int) ?? 0
        var problem: T.Text? = nil
        if keg.uppercased().hasPrefix("HEAD") || versions?["head"] is String && (versions?["stable"] == nil) {
            problem = T.Text("a HEAD build (not a released version)", "una build HEAD (non una versione rilasciata)")
        } else if tap == nil {
            problem = T.Text("the Homebrew install receipt does not name its tap", "la ricevuta di installazione di Homebrew non indica il tap")
        } else if tap != "homebrew/core" {
            problem = T.Text("installed from another Homebrew tap (\(tap!))", "installato da un altro tap di Homebrew (\(tap!))")
        } else if LocalToolsVersion.parseBrew(keg) == nil {
            problem = T.Text("the installed version cannot be compared", "la versione installata non si può confrontare")
        }
        let identity = LocalAdvisory.Identity(kind: .brew, tap: tap ?? "?", formula: formula, versionScheme: scheme)
        let current = catalogue?.versions[formula]
        return .present(T.Instance(toolId: tool.id, identity: identity, installedVersion: keg, compareVersion: keg,
                                   originProblem: problem, binaries: [formula],
                                   candidates: .brew(version: current, asOf: catalogue?.asOf), usedPath: path,
                                   statusOnly: nil))
    }

    func resolveApp(_ tool: T.WatchTool, _ app: T.MacApp, cellar: String?) -> T.Resolution? {
        if let token = app.caskToken, let cellar {
            let caskroom = (cellar as NSString).deletingLastPathComponent + "/Caskroom/" + token
            if let kegs = probe.listDirectory(caskroom)?.filter({ !$0.hasPrefix(".") }) {
                guard kegs.count == 1, T.validBrewName(token), LocalToolsVersion.dottedCompare(kegs[0], kegs[0]) != nil else {
                    return .unknown(toolId: tool.id, reason: T.Text("the Homebrew cask's installed version is unclear", "la versione installata del cask di Homebrew non è chiara"))
                }
                return .present(T.Instance(toolId: tool.id, identity: LocalAdvisory.Identity(kind: .cask, token: token),
                                           installedVersion: kegs[0], compareVersion: kegs[0], originProblem: nil,
                                           binaries: [token], candidates: .unavailable(T.Text("Homebrew casks are not checked for updates here", "qui non si controllano gli aggiornamenti dei cask di Homebrew")),
                                           usedPath: app.path, statusOnly: nil))
            }
        }
        guard let data = probe.readData(app.path + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String else {
            return nil
        }
        guard LocalToolsVersion.dottedCompare(version, version) != nil else {
            return .unknown(toolId: tool.id, reason: T.Text("the app's version cannot be compared", "la versione dell'app non si può confrontare"))
        }
        return vendorInstance(tool, vendor: app.vendor, product: app.product, flavour: app.flavour, version: version, path: app.path)
    }

    func vendorInstance(_ tool: T.WatchTool, vendor: String, product: String, flavour: String, version: String,
                        path: String) -> T.Resolution {
        .present(T.Instance(toolId: tool.id,
                            identity: LocalAdvisory.Identity(kind: .vendor, vendor: vendor, product: product,
                                                             platform: "darwin", flavour: flavour),
                            installedVersion: version, compareVersion: version, originProblem: nil, binaries: [],
                            candidates: .vendor, usedPath: path, statusOnly: nil))
    }

    func versionOutput(_ exe: String, _ args: [String]) -> String? {
        let (st, out) = probe.run(exe, args, 10)
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard st == 0, !t.isEmpty, t.count < 64, !t.contains("\n") else { return nil }
        return t
    }
}
