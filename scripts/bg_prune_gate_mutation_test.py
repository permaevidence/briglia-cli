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
    mutate(root, "new file top-level type without the prefix", "TelegramConcierge/Services/BackgroundPruneExtra.swift",
           lambda t: "import Foundation\n\nenum Helper {}\n", r"lacks the BackgroundPrune prefix")
    mutate(root, "selftest without shouldDisplay: false", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace("shouldDisplay: false", "shouldDisplay: true", 1), r"shouldDisplay")
    mutate(root, "selftest with a non-literal static property", "TelegramConcierge/CLI/BackgroundPruneSelftest.swift",
           lambda t: t.replace('    static let rootPrefix = "briglia-bg-prune-"',
                               '    static let rootPrefix = "briglia-bg-prune-"\n    static let eager = ConversationManager.self', 1),
           r"static property")
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
