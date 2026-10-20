#!/usr/bin/env python3
"""Deliberate mutations the background-prune OFF-identity gate must catch
(BACKGROUND_PRUNE_PLAN v4.1 §15.2 F, test O8).

Copies the candidate tree to a scratch directory once, applies one mutation
at a time, runs the gate's `validate` against the copy and requires a
finding with the expected reason; the copy is restored after each case.
Context rules (C2) and the T-SPLIT range rules are also exercised directly
on the baseline text, so an anchor failure can never mask a context failure
(Codex round-4 note 5). Positive controls: the unmodified candidate passes,
also with `git` absent from PATH, and whole-file stripping alone accepts
Codex's real-source capture (so the anchor/context checks are what reject it).
"""
import copy
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("gate", os.path.join(HERE, "bg_prune_off_identity_test.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

CM = gate.CM
REG = gate.REG
failures = 0
total = 0


def check(label, ok, detail=""):
    global failures, total
    total += 1
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else f" — {detail}"))
    if not ok:
        failures += 1


def main():
    scratch = tempfile.mkdtemp(prefix="bgprune-gate-")
    try:
        for name in ("TelegramConcierge", "Package.swift", "Package.resolved"):
            src = os.path.join(ROOT, name)
            dst = os.path.join(scratch, name)
            if os.path.isdir(src):
                shutil.copytree(src, dst, symlinks=True)
            else:
                shutil.copy2(src, dst)
        run(scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    print(f"\n{total - failures}/{total} gate mutation checks passed")
    return 1 if failures else 0


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def write(root, rel, text):
    with open(os.path.join(root, rel), "w", encoding="utf-8") as fh:
        fh.write(text)


CONF = '''    static let configuration = CommandConfiguration(
        commandName: "__background-prune-selftest",
        abstract: "Internal: verify background pruning.",
        shouldDisplay: false
    )'''


# Codex impl round 3, R3-1: a static factory shadowing the imported
# CommandConfiguration initialiser, with a help-time file write.
FACTORY_MUTANT = '''    static func CommandConfiguration(
        commandName: String, abstract: String, shouldDisplay: Bool
    ) -> ArgumentParser.CommandConfiguration {
        if ProcessInfo.processInfo.arguments.contains("--help") {
            let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]!
            try? "CODEX_OFF_FACTORY_SIDE_EFFECT".write(
                toFile: root + "/codex-off-discovery.txt",
                atomically: true, encoding: .utf8)
        }
        return ArgumentParser.CommandConfiguration(
            commandName: commandName, abstract: abstract,
            shouldDisplay: shouldDisplay)
    }'''


# Codex impl round 4, R4-1, verbatim: a nested @_silgen_name that defines
# the Darwin overlay ioctl symbol ArgumentParser's terminal-size query uses.
SYMBOL_PROBE = """import Foundation

struct BackgroundPruneSymbolProbe {
    @_silgen_name("$s6Darwin5ioctlys5Int32VAD_SuSvtF")
    static func bgPruneIoctl(
        _ fd: Int32, _ request: UInt, _ ptr: UnsafeMutableRawPointer
    ) -> Int32 {
        if isatty(fd) == 1,
           let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            try? "CODEX_OFF_SYMBOL_SIDE_EFFECT".write(
                toFile: root + "/codex-off-symbol.txt",
                atomically: true, encoding: .utf8)
        }
        return -1
    }
}
"""


def mutate(root, label, rel, fn, expect, manifest=None):
    """Apply fn(text) -> text to rel, validate, require a finding matching
    `expect` (regex), restore."""
    path = os.path.join(root, rel)
    existed = os.path.exists(path)
    original = read(root, rel) if existed else None
    try:
        new = fn(original)
        if new is None:
            os.remove(path)
        else:
            write(root, rel, new)
        errs = gate.validate(root, manifest)
        ok = any(re.search(expect, e) for e in errs)
        check(f"O8 {label} → rejected", ok, f"findings: {errs[:4]}")
    finally:
        if existed:
            write(root, rel, original)
        elif os.path.exists(path):
            os.remove(path)


def region(text, rid):
    """(start_line_index, end_line_index) of a region's marker lines."""
    lines = text.split("\n")
    start = next(i for i, l in enumerate(lines) if l.strip() == f"// BGPRUNE{{ {rid}")
    end = next(i for i in range(start, len(lines)) if lines[i].strip() == "// }BGPRUNE")
    return start, end


def replace_region_body(text, rid, body_lines):
    lines = text.split("\n")
    s, e = region(text, rid)
    indent = lines[s][:len(lines[s]) - len(lines[s].lstrip())]
    return "\n".join(lines[:s + 1] + [indent + b if b else "" for b in body_lines] + lines[e:])


def baseline_line_to_candidate(text, k):
    """Candidate line index just after baseline line k (1-based)."""
    lines = text.split("\n")
    base = 0
    inside = False
    for i, l in enumerate(lines):
        s = l.strip()
        if s.startswith("// BGPRUNE{"):
            inside = True
            continue
        if s == "// }BGPRUNE":
            inside = False
            continue
        if inside:
            continue
        base += 1
        if base == k:
            return i + 1
    raise ValueError(k)


def move_region(text, rid, after_baseline_line):
    lines = text.split("\n")
    s, e = region(text, rid)
    block = lines[s:e + 1]
    rest = lines[:s] + lines[e + 1:]
    joined = "\n".join(rest)
    at = baseline_line_to_candidate(joined, after_baseline_line)
    rest = joined.split("\n")
    return "\n".join(rest[:at] + block + rest[at:])


def run(root):
    errs = gate.validate(root)
    check("positive control: the unmodified candidate passes", errs == [], f"{errs[:5]}")
    env = dict(os.environ)
    env["PATH"] = "/nonexistent"
    proc = subprocess.run([sys.executable, os.path.join(HERE, "bg_prune_off_identity_test.py"), "--root", root],
                          env=env, capture_output=True, text=True)
    check("positive control: validation runs without git on PATH and passes", proc.returncode == 0, proc.stdout[-500:])

    cm = read(root, CM)
    # A. protected inputs
    mutate(root, "unmarked one-character change in an allow-listed file", CM,
           lambda t: t.replace("Context budget OK", "Context budget Ok", 1), r"unmarked change")
    mutate(root, "change in another protected Swift file", "TelegramConcierge/Services/OpenRouterService.swift",
           lambda t: t + "\n// harmless?\n", r"protected file changed")
    res = next(p for p in sorted(gate.list_files(root)) if p.startswith("TelegramConcierge/Resources/") and not p.endswith(".swift"))
    mutate(root, "change in a protected resource", res, lambda t: t + " ", r"protected file changed")
    mutate(root, "change in Package.swift", "Package.swift", lambda t: t + "\n", r"protected file changed")
    mutate(root, "change in Package.resolved", "Package.resolved", lambda t: t + "\n", r"protected file changed")
    mutate(root, "deleted baseline file", "TelegramConcierge/Services/OpenRouterProviderPin.swift", lambda t: None, r"protected file missing")
    mutate(root, "new file at a non-allowed path", "TelegramConcierge/Services/Extra.swift",
           lambda t: "import Foundation\n", r"unexpected file")
    # B/C. regions and templates
    mutate(root, "Codex: guard, close, unconditional statement, reopen", CM,
           lambda t: replace_region_body(t, "A-T0", ["if backgroundPruneEngaged {", "}", 'print("escaped")',
                                                     "if backgroundPruneEngaged {", "}"]), r"depth reaches 0")
    mutate(root, "side block reaching depth 0 before its last line", CM,
           lambda t: replace_region_body(t, "A-GEN1", ["if backgroundPruneEngaged {", "}", "}"]), r"depth|unbalanced|lexer")
    mutate(root, "split without its closing region", CM,
           lambda t: "\n".join(l for i, l in enumerate(t.split("\n"))
                               if not (region(t, "A-M/close")[0] <= i <= region(t, "A-M/close")[1])),
           r"unmarked change|split needs")
    mutate(root, "region marker hidden inside a raw string", CM,
           lambda t: replace_region_body(t, "A-GEN1", ["if backgroundPruneEngaged {",
                                                       '    let bgPruneS = #"""', "    // BGPRUNE{ A-HIDDEN", '    """#',
                                                       "    _ = bgPruneS", "}"]), r"marker")
    mutate(root, "#if inside a region", CM,
           lambda t: replace_region_body(t, "A-GEN1", ["if backgroundPruneEngaged {", "#if DEBUG",
                                                       "    backgroundPruneHistoryReplaced()", "#endif", "}"]), r"'#if' inside a region")
    mutate(root, "T-STORE with a non-literal initialiser", CM,
           lambda t: t.replace("private var backgroundPruneFallbackDue: Bool = false",
                               "private var backgroundPruneFallbackDue: Bool = bgPruneStart()", 1), r"T-STORE line not allowed")
    mutate(root, "T-STORE with @Published", CM,
           lambda t: t.replace("private var backgroundPrunePendingOff: Bool = false",
                               "@Published private var backgroundPrunePendingOff: Bool = false", 1), r"T-STORE line not allowed")
    mutate(root, "T-STORE with a non-listed type", CM,
           lambda t: t.replace("private var backgroundPrunePendingOff: Bool = false",
                               "private var backgroundPrunePendingOff: [Message] = []", 1), r"T-STORE line not allowed")
    mutate(root, "T-LOCAL with a baseline type", CM,
           lambda t: t.replace("var bgPruneFinalBase: Int = 0", "var bgPruneFinalBase: SomeBaselineType = nil", 1), r"T-LOCAL")
    mutate(root, "T-EXT unprefixed function (baseline-name overload)", CM,
           lambda t: t.replace("    var backgroundPruneEngaged: Bool {",
                               "    func configuredMaxContextTokens(_ x: Int) -> Int { x }\n    var backgroundPruneEngaged: Bool {", 1),
           r"member header not allowed")
    mutate(root, "T-EXT declaration mid-line at member level", CM,
           lambda t: t.replace("    var backgroundPruneEngaged: Bool {",
                               "    var backgroundPruneEngaged: Bool {", 1).replace(
                               "    var backgroundPruneSwitchOn: Bool {", "    ; func sneaky() {}\n    var backgroundPruneSwitchOn: Bool {", 1),
           r"member|unexpected token")
    mutate(root, "T-CMD with an extra line", CM,
           lambda t: t.replace("    await backgroundPruneCommand(argument: commandArgument(from: text))",
                               "    await backgroundPruneCommand(argument: commandArgument(from: text))\n    print(\"x\")", 1),
           r"T-CMD")
    mutate(root, "T-ARM with a second label", CM,
           lambda t: t.replace('case .pruneWait(let since):', 'case .pruneWait(let since):\n        return ""\n        case .model(let since):', 1),
           r"T-ARM|another case")
    mutate(root, "T-REG with interpolation", REG,
           lambda t: t.replace('description: "Prune old tool output', 'description: "\\(1) Prune old tool output', 1), r"T-REG")
    mutate(root, "duplicated anchor id", CM,
           lambda t: t.replace("// BGPRUNE{ A-GEN2", "// BGPRUNE{ A-GEN1", 1), r"duplicated anchor id|missing anchor region A-GEN2")
    mutate(root, "missing anchor region", CM,
           lambda t: "\n".join(l for i, l in enumerate(t.split("\n"))
                               if not (region(t, "A-GEN2")[0] <= i <= region(t, "A-GEN2")[1])), r"missing anchor region A-GEN2")
    mutate(root, "new file containing 'extension Message'", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
           lambda t: "import Foundation\n\nextension Message {\n    var x: Int { 0 }\n}\n", r"only struct/enum|extension")
    mutate(root, "new file with an unlisted #if", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
           lambda t: "import Foundation\n#if DEBUG\nenum BackgroundPruneExtra {}\n#endif\n", r"directive")
    # Codex impl round 4, R4-1: the attribute vocabulary is closed at every depth.
    probe_path = "TelegramConcierge/Services/BackgroundPruneSymbolProbe.swift"
    mutate(root, "R4-1 Codex's nested @_silgen_name ioctl override (verbatim)", probe_path,
           lambda t: SYMBOL_PROBE, r"attribute @_silgen_name not allowed")
    nested = lambda attr, decl="static func bgPruneX() {}": (
        "import Foundation\n\nstruct BackgroundPruneExtra {\n    enum Inner {\n        " + attr + "\n        "
        + decl + "\n    }\n}\n")
    for attr, decl in (('@_cdecl("bgPruneX")', "static func bgPruneX() {}"),
                       ("@_dynamicReplacement(for: bgPruneY)", "static func bgPruneX() {}"),
                       ("@_transparent", "static func bgPruneX() {}"),
                       ("@inline(__always)", "static func bgPruneX() {}"),
                       ("@usableFromInline", "static func bgPruneX() {}"),
                       ("@objc", "static func bgPruneX() {}"),
                       ("@available(*, deprecated)", "static func bgPruneX() {}"),
                       ("@_spi(Bg)", "static func bgPruneX() {}")):
        mutate(root, f"R4-1 nested {attr.split('(')[0]} two levels deep", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
               lambda t, a=attr, d=decl: nested(a, d), r"not on the attribute allowlist")
    mutate(root, "R4-1 @_silgen_name on a local function inside a method body", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
           lambda t: ("import Foundation\n\nenum BackgroundPruneExtra {\n    static func bgPruneRun() {\n"
                      '        @_silgen_name("bgPruneZ") func bgPruneLocal() -> Int32\n        _ = bgPruneLocal()\n    }\n}\n'),
           r"attribute @_silgen_name not allowed")
    mutate(root, "R4-1 underscored attribute in a type header", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
           lambda t: "import Foundation\n\nstruct BackgroundPruneExtra: @_unsafeInheritExecutor Sendable {}\n",
           r"in a type header")
    mutate(root, "R4-1 @unchecked not followed by Sendable", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
           lambda t: "import Foundation\n\nstruct BackgroundPruneExtra {\n    var x: @unchecked Int = 0\n}\n",
           r"@unchecked only as")
    mutate(root, "R4-1 @Flag outside the selftest file", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
           lambda t: "import Foundation\n\nstruct BackgroundPruneExtra {\n    @Flag var bgPruneX = false\n}\n",
           r"attribute @Flag not allowed")
    mutate(root, "R4-1 nested @_silgen_name inside a T-EXT region", CM,
           lambda t: t.replace("    var backgroundPruneEngaged: Bool {",
                               '    @_silgen_name("bgPruneW") static func backgroundPruneW() -> Int32\n    var backgroundPruneEngaged: Bool {', 1),
           r"attribute @_silgen_name inside a region")
    mutate(root, "R4-1 @objc inside a T-EXT region", CM,
           lambda t: t.replace("    var backgroundPruneEngaged: Bool {",
                               "    @objc func backgroundPruneW() {}\n    var backgroundPruneEngaged: Bool {", 1),
           r"attribute @objc inside a region")
    mutate(root, "new file top-level type without the prefix", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
           lambda t: "import Foundation\n\nenum Helper {}\n", r"lacks the BackgroundPrune prefix")
    mutate(root, "selftest without shouldDisplay: false", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace("shouldDisplay: false", "shouldDisplay: true", 1), r"shouldDisplay")
    mutate(root, "selftest with a non-literal static property", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace('    static let rootPrefix = "briglia-bg-prune-"',
                               '    static let rootPrefix = "briglia-bg-prune-"\n    static let eager = ConversationManager.self', 1),
           r"static property")
    # Codex impl review R3a/R3b: both compiled bypasses must be rejected.
    mutate(root, "R3a configuration built by a closure (discovery side effect)", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace('''    static let configuration = CommandConfiguration(
        commandName: "__background-prune-selftest",
        abstract: "Internal: verify background pruning.",
        shouldDisplay: false
    )''', '''    static let configuration: CommandConfiguration = {
        print("CODEX_OFF_DISCOVERY_SIDE_EFFECT")
        return CommandConfiguration(
            commandName: "__background-prune-selftest",
            abstract: "Internal: verify background pruning.",
            shouldDisplay: false
        )
    }()''', 1), r"selftest configuration must be a plain")
    mutate(root, "R3a configuration argument with an interpolated side effect", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace('''        abstract: "Internal: verify background pruning.",''',
                               '''        abstract: "Internal: \\(sideEffect())",''', 1), r"selftest configuration must be a plain")
    mutate(root, "R3a configuration with an extra argument", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace('''        abstract: "Internal: verify background pruning.",''',
                               '''        abstract: "Internal: verify background pruning.",
        subcommands: [Eager.self],''', 1), r"selftest configuration must be a plain")
    # Codex impl round 2, R2-1: declaration discovery on the token stream.
    mutate(root, "R2-1 newline between static and let, closure initializer (compiled control)",
           "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(CONF, '''    static
    let configuration: CommandConfiguration = {
        print("CODEX_OFF_DISCOVERY_SIDE_EFFECT")
        return CommandConfiguration(
            commandName: "__background-prune-selftest",
            abstract: "Internal: verify background pruning.",
            shouldDisplay: false
        )
    }()''', 1), r"selftest configuration must be a plain")
    mutate(root, "R2-1 comment between static and let", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(CONF, CONF.replace("static let configuration", "static /* x */ let configuration", 1)
                               .replace("CommandConfiguration(", "eager(CommandConfiguration(", 1) + ")", 1),
           r"selftest configuration must be a plain")
    mutate(root, "R2-1 modifier between static and let", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace("    static let configuration = CommandConfiguration(",
                               "    nonisolated(unsafe) static\n    var configuration = CommandConfiguration(", 1),
           r"selftest configuration must be a plain")
    mutate(root, "R2-1 static literal continued on the next line", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace('    static let rootPrefix = "briglia-bg-prune-"',
                               '    static let rootPrefix = "briglia-bg-prune-"\n        .appending(eager())', 1),
           r"static property")
    mutate(root, "R2-1 static literal split across lines", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace('    static let rootPrefix = "briglia-bg-prune-"',
                               '    static\n    let rootPrefix = eager()', 1),
           r"static property")
    mutate(root, "R2-1 command option with a side-effect default", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace("    @Option(name: .long, help: .hidden) var only: String?",
                               "    @Option(name: .long, help: .hidden) var only: String? = eager()", 1),
           r"command property not allowed")
    mutate(root, "R2-1 extra command instance property", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace("    @Option(name: .long, help: .hidden) var only: String?",
                               "    @Option(name: .long, help: .hidden) var only: String?\n    var probe = eager()", 1),
           r"command property not allowed")
    mutate(root, "R2-1 second configuration declaration", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(CONF, CONF + "\n    static let configuration2 = eager()", 1),
           r"static property")
    # Codex impl round 3, R3-1: name resolution (shadowing the imported names).
    run_line = "    @MainActor func run() async throws {"
    mutate(root, "R3-1 static func CommandConfiguration shadowing the constructor (Codex's compiled mutant)", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(run_line, FACTORY_MUTANT + "\n\n" + run_line, 1), r"shadows reserved name 'CommandConfiguration'")
    mutate(root, "R3-1 backtick-escaped static func `CommandConfiguration`", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(run_line, "    static func `CommandConfiguration`(commandName: String, abstract: String, shouldDisplay: Bool) -> Int { 0 }\n" + run_line, 1),
           r"shadows reserved name 'CommandConfiguration'")
    mutate(root, "R3-1 nested type named CommandConfiguration", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(run_line, "    struct CommandConfiguration { init(commandName: String, abstract: String, shouldDisplay: Bool) {} }\n" + run_line, 1),
           r"shadows reserved name 'CommandConfiguration'")
    mutate(root, "R3-1 typealias CommandConfiguration", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(run_line, "    typealias CommandConfiguration = BackgroundPruneSelftestHarness\n" + run_line, 1),
           r"shadows reserved name 'CommandConfiguration'")
    mutate(root, "R3-1 generic parameter named CommandConfiguration on the command type", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace("struct BackgroundPruneSelftest: AsyncParsableCommand {",
                               "struct BackgroundPruneSelftest<CommandConfiguration>: AsyncParsableCommand {", 1),
           r"shadows reserved name 'CommandConfiguration'|outside its approved position")
    mutate(root, "R3-1 property-wrapper type Flag shadowed by a nested type", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(run_line, "    @propertyWrapper struct Flag { var wrappedValue: Bool }\n" + run_line, 1),
           r"shadows reserved name 'Flag'")
    mutate(root, "R3-1 enum case list binding Option", "TelegramConcierge/Services/BackgroundPruneTypes.swift",
           lambda t: t + "\nenum BackgroundPruneProbeCases { case first, Option }\n", r"shadows reserved name 'Option'")
    mutate(root, "R3-1 literal-type alias changing default literal types", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(run_line, "    typealias StringLiteralType = BackgroundPruneSelftestHarness\n" + run_line, 1),
           r"shadows reserved name 'StringLiteralType'")
    mutate(root, "R3-1 shadowed String used by a hidden @Option type", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(run_line, "    struct String {}\n" + run_line, 1), r"shadows reserved name 'String'")
    mutate(root, "R3-1 @Option of a custom value type", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace("@Option(name: .long, help: .hidden) var only: String?",
                               "@Option(name: .long, help: .hidden) var only: BackgroundPruneProbe?", 1),
           r"command property not allowed")
    mutate(root, "R3-1 qualified ArgumentParser.CommandConfiguration lookup in a helper", "TelegramConcierge/Services/BackgroundPruneTypes.swift",
           lambda t: t + "\nenum BackgroundPruneProbeLookup { static func f() -> Any { ArgumentParser.CommandConfiguration.self } }\n",
           r"outside its approved position")
    mutate(root, "R3-1 tuple pattern binding a reserved name", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace(run_line, "    let (probeA, Int) = (1, 2)\n" + run_line, 1), r"shadows reserved name 'Int'|command property not allowed")
    mutate(root, "R3-1 reserved declaration inside a marked region", CM,
           lambda t: t.replace("    var backgroundPruneEngaged: Bool {",
                               "    func bgPruneProbe() { struct CommandConfiguration {} }\n    var backgroundPruneEngaged: Bool {", 1),
           r"shadows reserved name 'CommandConfiguration'")
    mutate(root, "R3b valid header then an unprefixed overload on the same line", CM,
           lambda t: t.replace("    var backgroundPruneEngaged: Bool {",
                               "    func bgPruneProbe() {} ; private func sendText(_ text: String) async throws { print(\"CODEX_OFF_OVERLOAD\") }\n    var backgroundPruneEngaged: Bool {", 1),
           r"second declaration on one line|';' at member level")
    mutate(root, "R3b second prefixed declaration on one line", CM,
           lambda t: t.replace("    var backgroundPruneEngaged: Bool {",
                               "    func bgPruneProbe() {} ; func bgPruneProbe2() {}\n    var backgroundPruneEngaged: Bool {", 1),
           r"second declaration on one line|';' at member level")
    # pinned anchors
    mutate(root, "Codex's real-source capture at 8686|8687 (tool-loop catch/else)", CM,
           lambda t: move_region(t, "A-GEN1", 8686), r"A-GEN1: region not at its pinned insertion point")
    mutate(root, "Codex's real-source capture at 9203|9204 (forced-final)", CM,
           lambda t: move_region(t, "A-GEN1", 9203), r"A-GEN1: region not at its pinned insertion point")
    mutate(root, "valid T-SIDE at an unpinned legal statement position", CM,
           lambda t: move_region(t, "A-GEN1", 13299), r"not at its pinned insertion point")
    mutate(root, "pinned anchor shifted by one line", CM,
           lambda t: move_region(t, "A-STATUS", 6638), r"A-STATUS: region not at its pinned insertion point")
    mutate(root, "A-M split one line long (close after the next line)", CM,
           lambda t: move_region(t, "A-M/close", 9072), r"split regions not at the pinned range|not consecutive")
    mutate(root, "T-ARM placed in a different switch", CM,
           lambda t: move_region(t, "A-ARM", 4398), r"A-ARM")
    manifest = gate.load_manifest()
    altered = copy.deepcopy(manifest)
    for a in altered["anchors"]:
        if a["id"] == "A-T0":
            key = next(iter(a["neighbors"]))
            a["neighbors"][key] = "0" * 64
    errs = gate.validate(root, altered)
    check("O8 neighbouring baseline line hash altered → rejected",
          any("A-T0: neighbouring baseline line" in e for e in errs), f"{errs[:3]}")
    # wrong manifest hash
    mpath = os.path.join(HERE, gate.MANIFEST_NAME)
    with open(mpath, "rb") as fh:
        original = fh.read()
    try:
        with open(mpath, "wb") as fh:
            fh.write(original + b" ")
        errs = gate.validate(root)
        check("O8 wrong manifest hash → rejected", any("manifest hash mismatch" in e for e in errs), f"{errs[:2]}")
    finally:
        with open(mpath, "wb") as fh:
            fh.write(original)

    # C2 rules exercised directly on the baseline (independent of anchors).
    stripped, _ = gate.extract_regions(cm, CM)
    b = gate.Baseline(stripped)
    whole = gate.sha(stripped.encode()) == gate.load_manifest()["files"][CM]
    check("positive control: whole-file stripping alone reproduces the baseline (so it cannot reject a capture)", whole)
    for k in (8686, 9203):
        errs = gate.context_errors(b, k, "statement", f"capture@{k}")
        check(f"C2 the next-token rule rejects an insertion at {k}|{k + 1} (next token 'else' or 'catch')",
              any("continues the previous statement" in e for e in errs), f"{errs}")
    found = {}
    for idx, t in enumerate(b.ctoks):
        first_on_line = idx == 0 or b.ctoks[idx - 1].end_line < t.line
        if not first_on_line:
            continue
        key = "catch" if t.text == "catch" else "." if t.text.startswith(".") and t.kind == "op" else "{" if t.text == "{" else None
        if key and key not in found and gate.ends_statement(b.ctoks[idx - 1] if idx else None):
            found[key] = t.line - 1
    for key in (".", "{", "catch"):
        if key in found:
            errs = gate.context_errors(b, found[key], "statement", f"before-{key}")
            check(f"C2 T-SIDE before a baseline line starting with {key!r} (line {found[key] + 1}) → rejected",
                  any("continues" in e for e in errs), f"{errs}")
        else:
            print(f"- C2 note: the baseline has no statement-position line starting with {key!r}; covered by the next-token unit cases")
    for nxt, ok in (("else", False), ("catch", False), ("{", False), (".", False), ("let", True)):
        t = gate.Tok("word" if nxt.isalpha() else ("punct" if nxt == "{" else "op"), nxt, 1)
        check(f"C2 next-token rule: {nxt!r} → {'allowed' if ok else 'rejected'}", gate.next_allowed(t) == ok)
    errs = gate.split_range_errors(b, 8452, 8462, "A-T1-short")
    check("C2 A-T1 wrapped without its consumer → binding escape", any("escapes the wrapped range" in e for e in errs), f"{errs}")
    errs = gate.split_range_errors(b, 9033, 9070, "A-M-short")
    check("C2 A-M wrapped one line short → rejected", errs != [], f"{errs}")
    errs = gate.split_range_errors(b, 8453, 8471, "A-T1-in-args")
    check("C2 T-SPLIT starting inside an argument list → rejected", errs != [], f"{errs}")
    defer_line = next(i + 1 for i, l in enumerate(b.lines) if l.strip().startswith("defer { endMaintenance(pruneActivityId) }"))
    errs = gate.split_range_errors(b, defer_line, defer_line, "defer")
    check("C2 wrapped range with a depth-0 defer → rejected", any("defer" in e for e in errs), f"{errs}")
    reg_text, _ = gate.extract_regions(read(root, REG), REG)
    rb = gate.Baseline(reg_text)
    last_elem = max(i + 1 for i, l in enumerate(rb.lines) if l.strip().endswith("category: \"System\"),") or l.strip().endswith("),"))
    close_line = next(i + 1 for i, l in enumerate(rb.lines) if l.strip() == "]")
    errs = gate.context_errors(rb, close_line - 1, "element", "after-last")
    check("C2 element region after an element without trailing comma / before ']' → rejected", errs != [], f"{errs}")
    errs = gate.split_range_errors(b, 8452, 8471, "A-T1") + gate.split_range_errors(b, 8639, 8695, "A-SEND") \
        + gate.split_range_errors(b, 9033, 9071, "A-M") + gate.split_range_errors(b, 9158, 9212, "A-FFSEND")
    check("positive control: the four pinned T-SPLIT ranges pass C2", errs == [], f"{errs}")
    _ = last_elem


if __name__ == "__main__":
    sys.exit(main())
