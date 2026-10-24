import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The S1 watchlist (security plan §9.5.2) and the read-only inventory that
/// resolves, per watched tool, the instance Briglia actually uses: the
/// executable it would run (PATH resolution, as the agent's tools do today;
/// Phase 1's `selected.json` replaces this seam) and the package that owns
/// it. Only read-only queries run: `dpkg-query`, `apt-cache` with its binary
/// caches disabled, `--version` probes; Homebrew is read as files, never run.
/// Names used later in commands come only from these local reads.
extension LocalTools {
    struct MacApp {
        var path: String
        var vendor: String
        var product: String
        var flavour: String
        var caskToken: String?
    }

    struct WatchTool {
        var id: String
        var name: String
        var executables: [String] = []
        /// Linux: binary packages to look up when no executable is used
        /// (libraries such as pango, read from dpkg).
        var debPackages: [String] = []
        /// Linux: a library Briglia itself loads (from /proc/self/maps).
        var mappedLibrary: String? = nil
        var brewFormulae: [String] = []
        var macApp: MacApp? = nil
        var vendorNode = false
        var vendorPython = false
        var rendererBrowser = false
        var mitigation: Text
    }

    /// `Resources/BundledSkills/pdf/render_pdf.py` `find_chrome()`, in its
    /// order: these names on PATH (`shutil.which`), then these app bundles.
    static let rendererBrowserNames = ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]
    static let rendererBrowserApps: [(path: String, executable: String, vendor: String, product: String, flavour: String)] = [
        ("/Applications/Chromium.app", "Chromium", "chromium.org", "chromium", "official"),
        ("/Applications/Google Chrome.app", "Google Chrome", "google", "chrome", "stable"),
        ("/Applications/Microsoft Edge.app", "Microsoft Edge", "microsoft", "edge", "stable"),
    ]

    enum PathLookup: Equatable { case found(String), notFound, ambiguous }

    /// Python's `shutil.which` as the renderer uses it: PATH entries in
    /// order; an EMPTY entry means the renderer's current directory, which
    /// Briglia cannot know here → ambiguous (the browser is then unknown).
    static func rendererWhich(_ p: Probe, _ name: String) -> PathLookup {
        for dir in p.pathEntries {
            if dir.isEmpty { return .ambiguous }
            let candidate = (dir.hasSuffix("/") ? dir : dir + "/") + name
            if p.isExecutable(candidate) { return .found(candidate) }
        }
        return .notFound
    }

    /// The first renderer PATH browser, or nil / ambiguous.
    static func rendererPathBrowser(_ p: Probe) -> PathLookup {
        for name in rendererBrowserNames {
            switch rendererWhich(p, name) {
            case .found(let path): return .found(path)
            case .ambiguous: return .ambiguous
            case .notFound: continue
            }
        }
        return .notFound
    }

    static let mediaMitigation: (String) -> Text = { tool in
        Text("Until it is updated, avoid processing untrusted files with \(tool).",
             "Finché non è aggiornato, evita di elaborare file non affidabili con \(tool).")
    }
    static let noWorkaround = Text("No workaround is known; Briglia will tell you when a fix is available.",
                                   "Non è nota una soluzione temporanea; Briglia ti avviserà quando la correzione sarà disponibile.")

    /// About 20 identities per platform (§9.5.2 S1).
    static let watchlist: [WatchTool] = [
        WatchTool(id: "ffmpeg", name: "ffmpeg", executables: ["ffmpeg"], brewFormulae: ["ffmpeg"], mitigation: mediaMitigation("ffmpeg")),
        WatchTool(id: "imagemagick", name: "ImageMagick", executables: ["magick", "convert"], brewFormulae: ["imagemagick"], mitigation: mediaMitigation("ImageMagick")),
        WatchTool(id: "poppler", name: "poppler", executables: ["pdftoppm"], brewFormulae: ["poppler"], mitigation: mediaMitigation("poppler")),
        WatchTool(id: "pandoc", name: "pandoc", executables: ["pandoc"], brewFormulae: ["pandoc"], mitigation: mediaMitigation("pandoc")),
        WatchTool(id: "ghostscript", name: "Ghostscript", executables: ["gs"], brewFormulae: ["ghostscript"], mitigation: mediaMitigation("Ghostscript")),
        WatchTool(id: "libreoffice", name: "LibreOffice", executables: ["soffice", "libreoffice"],
                  macApp: MacApp(path: "/Applications/LibreOffice.app", vendor: "documentfoundation", product: "libreoffice",
                                 flavour: "official", caskToken: "libreoffice"),
                  mitigation: mediaMitigation("LibreOffice")),
        WatchTool(id: "pango", name: "pango", debPackages: ["libpango-1.0-0"], brewFormulae: ["pango"], mitigation: noWorkaround),
        WatchTool(id: "cairo", name: "cairo", debPackages: ["libcairo2"], brewFormulae: ["cairo"], mitigation: noWorkaround),
        WatchTool(id: "gdk-pixbuf", name: "gdk-pixbuf", debPackages: ["libgdk-pixbuf-2.0-0", "libgdk-pixbuf2.0-0"],
                  brewFormulae: ["gdk-pixbuf"], mitigation: mediaMitigation("gdk-pixbuf")),
        WatchTool(id: "node", name: "Node.js", executables: ["node"], brewFormulae: ["node"], vendorNode: true, mitigation: noWorkaround),
        WatchTool(id: "python", name: "Python", executables: ["python3"], vendorPython: true, mitigation: noWorkaround),
        WatchTool(id: "git", name: "git", executables: ["git"], brewFormulae: ["git"], mitigation: noWorkaround),
        WatchTool(id: "curl", name: "curl", executables: ["curl"], brewFormulae: ["curl"], mitigation: noWorkaround),
        WatchTool(id: "openssl", name: "OpenSSL", mappedLibrary: "libssl.so", mitigation: noWorkaround),
        WatchTool(id: "libcurl", name: "libcurl", mappedLibrary: "libcurl.so", mitigation: noWorkaround),
        WatchTool(id: "libxml2", name: "libxml2", mappedLibrary: "libxml2.so", mitigation: noWorkaround),
        // The browser the PDF renderer falls back to (render_pdf.find_chrome):
        // resolved in exactly its order by `rendererBrowser`, not here.
        WatchTool(id: "chrome", name: "the rendering browser", rendererBrowser: true,
                  mitigation: Text("Until it is updated, avoid opening untrusted websites or documents in this browser.",
                                   "Finché non è aggiornato, evita di aprire siti o documenti non affidabili con questo browser.")),
        WatchTool(id: "unzip", name: "unzip", executables: ["unzip"], brewFormulae: ["unzip"], mitigation: mediaMitigation("unzip")),
        WatchTool(id: "zip", name: "zip", executables: ["zip"], brewFormulae: ["zip"], mitigation: noWorkaround),
        WatchTool(id: "tar", name: "tar", executables: ["tar"], brewFormulae: ["gnu-tar"], mitigation: mediaMitigation("tar")),
    ]

    static func tool(_ id: String) -> WatchTool? { watchlist.first { $0.id == id } }

    // MARK: - Probe

    enum Platform: String { case macOS, linux, ubuntuTouch }

    struct Probe {
        var platform: Platform
        var now: () -> Date
        var environment: [String: String]
        var home: String
        var readData: (String) -> Data?
        var listDirectory: (String) -> [String]?
        var modificationDate: (String) -> Date?
        /// realpath(3); nil when the path does not exist.
        var resolve: (String) -> String?
        var findBinary: (String) -> String?
        /// The raw PATH entries (empty entries kept) and an executable test:
        /// the renderer's `shutil.which` lookup is rebuilt from these.
        var pathEntries: [String]
        var isExecutable: (String) -> Bool
        var run: (String, [String], TimeInterval) -> (Int32, String)
        /// Briglia's own copies (the managed Node root, the userdata
        /// toolchain): never a user tool here (§9.5.6, Phase 1).
        var brigliaOwnedRoots: [String]

        static var live: Probe {
            let fm = FileManager.default
            #if os(macOS)
            let platform = Platform.macOS
            #else
            let platform: Platform = AgentServiceSupport.isUbuntuTouch() ? .ubuntuTouch : .linux
            #endif
            return Probe(
                platform: platform, now: { Date() }, environment: ProcessInfo.processInfo.environment,
                home: NSHomeDirectory(),
                readData: { fm.contents(atPath: $0) },
                listDirectory: { try? fm.contentsOfDirectory(atPath: $0) },
                modificationDate: { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date },
                resolve: { path in
                    guard let r = realpath(path, nil) else { return nil }
                    defer { free(r) }
                    return String(cString: r)
                },
                findBinary: { PlatformBinary.find($0) },
                pathEntries: (ProcessInfo.processInfo.environment["PATH"] ?? "")
                    .split(separator: ":", omittingEmptySubsequences: false).map(String.init),
                isExecutable: { fm.isExecutableFile(atPath: $0) },
                run: { exe, args, timeout in
                    let r = UserdataToolchain.run(exe, args, timeout: timeout)
                    return (r.exitCode, r.output)
                },
                brigliaOwnedRoots: [NodeInstaller.installRoot.resolvingSymlinksInPath().path,
                                    UserdataToolchain.root.resolvingSymlinksInPath().path])
        }

        func owned(_ path: String) -> Bool {
            brigliaOwnedRoots.contains { !$0.isEmpty && (path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")) }
        }

        /// A userdata-toolchain wrapper in ~/.local/bin (a small script that
        /// executes a binary inside the toolchain prefix).
        func isToolchainWrapper(_ path: String) -> Bool {
            guard let data = readData(path), data.count < 64 * 1024 else { return false }
            let text = String(decoding: data.prefix(8192), as: UTF8.self)
            return brigliaOwnedRoots.contains { !$0.isEmpty && text.contains($0) }
        }
    }

    static let probeTimeout: TimeInterval = 20
    static let debNamePattern = "^[a-z0-9][a-z0-9+.-]{0,127}(:[a-z0-9-]{1,32})?$"
    static let brewNamePattern = "^[a-z0-9][a-z0-9@+._-]{0,127}$"

    static func validDebName(_ s: String) -> Bool { s.range(of: debNamePattern, options: .regularExpression) != nil }
    static func validBrewName(_ s: String) -> Bool { s.range(of: brewNamePattern, options: .regularExpression) != nil }

    /// Every watched tool → one resolution (present / absent / unknown).
    static func inventory(_ p: Probe) -> [Resolution] {
        switch p.platform {
        case .macOS: return MacInventory(probe: p).run()
        case .linux, .ubuntuTouch: return DebInventory(probe: p).run()
        }
    }
}
