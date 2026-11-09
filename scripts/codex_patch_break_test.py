#!/usr/bin/env python3
"""Deliberate breaks for the GPT apply_patch engine, stage S1
(GPT_APPLY_PATCH_PLAN §14.11; the S2/S3 breaks join with those stages).

Same method as keyless_web_break_test.py: copy the tree to a scratch
directory, build once (positive control: `__codex-patch-selftest` passes),
then apply one mutation at a time (one or more source edits), rebuild
incrementally and require the NAMED check to be reported as failed (✖), not
just a non-zero exit. The repository is never modified.

Usage: python3 scripts/codex_patch_break_test.py [--keep-build DIR] [--only P1,P2] [--verbose]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINUX_JOBS = ["-j", "2"] if sys.platform.startswith("linux") else []
C = "TelegramConcierge/Services/CodexPatch/"
FIXTURES = ROOT / "scripts/fixtures/codex-apply-patch"

# (label, check id that must fail, [(file, old, new), ...])
BREAKS = [
    ("P1 no forward cursor", "E.M2", [(C + "CodexPatchSeek.swift",
        "            lineIndex = startIdx + patternArr.count\n", "            lineIndex = 0\n")]),
    ("P2 no trim_end pass", "E.M3", [(C + "CodexPatchSeek.swift",
        "        for i in searchStart...upper where (0..<pattern.count).allSatisfy({ RustStr.eq(RustStr.trimEnd(lines[i + $0]), trimEndPattern[$0]) }) {\n            return (i, .trimEnd)\n        }\n", "        _ = trimEndPattern\n")]),
    ("P3 no Unicode normalization", "F.59", [(C + "CodexPatchSeek.swift",
        "        for i in searchStart...upper where (0..<pattern.count).allSatisfy({ RustStr.eq(normalise(lines[i + $0]), normPattern[$0]) }) {\n            return (i, .punctuation)\n        }\n", "        _ = normPattern\n")]),
    ("P4 EOF search falls back to start", "E.M1", [(C + "CodexPatchSeek.swift",
        "            return (i, .punctuation)\n        }\n        return nil\n", "            return (i, .punctuation)\n        }\n        return eof ? seekWithLevel(lines, pattern, start: start, eof: false) : nil\n")]),
    ("P5 pure insertion inserted at the cursor", "F.58", [(C + "CodexPatchSeek.swift",
        "replacements.append(Replacement(start: originalLines.count, oldLength: 0, newLines: chunk.newLines))",
        "replacements.append(Replacement(start: lineIndex, oldLength: 0, newLines: chunk.newLines))")]),
    ("P6 LF for inserted lines in CRLF files", "E.T1", [(C + "CodexPatchTextFile.swift",
        "out.append(contentsOf: r.newLines.map { Line(text: $0, ending: preferredEnding) })",
        "out.append(contentsOf: r.newLines.map { Line(text: $0, ending: .lf) })")]),
    ("P7 BOM dropped", "E.T4", [(C + "CodexPatchTextFile.swift",
        "            if hadBOM { data.append(contentsOf: Self.bom) }\n", "")]),
    ("P8 Add without final newline", "F.50", [(C + "CodexPatchParser.swift",
        "                    hunks[idx].contents += \"\\n\"\n", "")]),
    ("P9 relative path accepted", "E.P1", [(C + "CodexPatchEngine.swift",
        "        guard display.hasPrefix(\"/\") else {", "        guard true else {")]),
    ("P10 duplicate targets allowed", "E.P4", [(C + "CodexPatchEngine.swift",
        "            if seen[r.key] != nil {", "            if false {")]),
    ("P11 rollback disabled", "T.10", [(C + "CodexPatchEngine.swift",
        "            let report = await CodexPatchTransaction.rollback(journal)",
        "            let report = CodexPatchTransaction.RollbackReport(); _ = journal")]),
    ("P12 per-operation revalidation removed", "T.2", [(C + "CodexPatchTransaction.swift",
        "            guard try matches(target, expected) else {\n                discard(staged, journal: journal)",
        "            guard true else {\n                discard(staged, journal: journal)")]),
    ("P24 cancellation ignored at the end of preflight", "E.L6", [(C + "CodexPatchEngine.swift",
        "        if request.isCancelled() {", "        if false {")]),
    ("P25 Add over a stale file allowed", "K.6", [(C + "CodexPatchEngine.swift",
        "                    try await requireFresh(r, id: pre.identity, message: \"\\(r.display) already exists — read it first, or use *** Update File\")\n", "")]),
    ("P26 Delete without knowledge allowed", "K.1", [(C + "CodexPatchEngine.swift",
        "                try await requireFresh(r, id: pre.identity, message: \"read \\(r.display) before deleting it\")\n", "")]),
    ("P27 secret-store Delete allowed", "S.3", [(C + "CodexPatchEngine.swift",
        "                if EditProtections.isSecretStore(r.display) {\n                    throw Refusal(category: .protected, text: verificationFailure(HarnessSecretStore.deleteOrMoveRefusal))\n                }\n                switch r.leafID?.kind {",
        "                switch r.leafID?.kind {")]),
    ("P28 a Codex error string changed", "G.1", [(C + "CodexPatchSeek.swift",
        "message: \"Failed to find expected lines in \\(path):", "message: \"Failed to find the expected lines in \\(path):")]),
    ("P38 rollback overwrites a concurrent edit", "T.11", [(C + "CodexPatchTransaction.swift",
        "                                                 expected: .state(post.identity, hash: post.hash), pre: nil, journal: tmp)",
        "                                                 expected: ((try? CodexPatchFS.stateAndHash(path, limit: hashLimit)) ?? nil).map { .state($0.0, hash: $0.1) } ?? .absent, pre: nil, journal: tmp)")]),
    ("P39 PrivateStorage policy bypassed inside the roots", "T.7a", [(C + "CodexPatchEngine.swift",
        "func newFileMode(_ r: ResolvedPath) -> mode_t? { writeScope(r) ? 0o600 : nil }",
        "func newFileMode(_ r: ResolvedPath) -> mode_t? { nil }")]),
    ("P44 directory receipts dropped on partial failure", "T.10", [(C + "CodexPatchTransaction.swift",
        "            journal.record(.createdDirectory(path: dir, device: id.device, inode: id.inode, mode: id.mode))\n", "")]),
    ("P45 revalidation before staging instead of after", "T.2", [
        (C + "CodexPatchTransaction.swift",
         "            guard try matches(target, expected) else {\n                discard(staged, journal: journal)",
         "            guard true else {\n                discard(staged, journal: journal)"),
        (C + "CodexPatchEngine.swift",
         "        let staged = try CodexPatchTransaction.stage(w.data,",
         "        guard try CodexPatchTransaction.matches(w.target, w.pre.map { .state($0.identity, hash: $0.hash) } ?? .absent) else { throw CodexPatchTransaction.StepError.conflict(\"\\(w.display) changed during the patch\") }\n        let staged = try CodexPatchTransaction.stage(w.data,")]),
    ("P46 legacy record accepted for a GPT Delete", "K.2", [(C + "CodexPatchFS.swift",
        "        guard let record = await FileTimeTracker.shared.gptRecord(forKey: key) else { return .none }",
        "        guard let record = await FileTimeTracker.shared.gptRecord(forKey: key) else { return await FileTimeTracker.shared.standardSnapshotForTesting(path: key) != nil ? .fresh : .none }")]),
    ("P52 .gptPatch record built from a later stat", "K.12", [(C + "CodexPatchEngine.swift",
        "            guard let now = try? FileIdentity.lstatPath(receipt.key), now.sameState(as: receipt.identity) else { continue }\n            await FileTimeTracker.shared.publishGPT(receipt)",
        "            guard let now = try? FileIdentity.lstatPath(receipt.key) else { continue }\n            await FileTimeTracker.shared.publishGPT(GPTEvidence.Receipt(key: receipt.key, identity: now, source: .gptPatch))")]),
    ("P53 rollback compares only inode and hash", "T.12", [(C + "CodexPatchTransaction.swift",
        "        case (.state(let id, let hash), .some(let (cur, curHash))): return id.sameState(as: cur) && hash == curHash",
        "        case (.state(let id, let hash), .some(let (cur, curHash))): return id.inode == cur.inode && hash == curHash")]),
    ("P54 created directory removed by emptiness alone", "T.13", [(C + "CodexPatchTransaction.swift",
        "                      id.device == device, id.inode == inode, id.mode == mode,\n", "                      true,\n")]),
    ("P55 removed file restored over a recreated name", "T.14", [(C + "CodexPatchTransaction.swift",
        "                        try revalidateAndReplace(staged, target: path, display: display, expected: .absent, pre: nil, journal: tmp)",
        "                        _ = rename(staged.tempPath, path)")]),
    ("P56 symlink retarget not checked", "T.4", [(C + "CodexPatchTransaction.swift",
        "            if let linkGuard {\n                guard let now", "            if let linkGuard, false {\n                guard let now")]),
    ("P57 canonical equivalence used for matching", "E.T12", [(C + "CodexPatchParser.swift",
        "    static func eq(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }",
        "    static func eq(_ a: String, _ b: String) -> Bool { a == b }")]),
    ("P58 BOM not stripped before matching", "E.T4", [(C + "CodexPatchTextFile.swift",
        "            if hadBOM { bytes.removeFirst(3) }\n", "")]),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    r = run(["swift", "build", "--build-system", "native", *LINUX_JOBS, "--scratch-path", str(scratch)], tree, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


def selftest(binary, workdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BRIGLIA_")}
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    return run([str(binary), "__codex-patch-selftest", "--fixtures", str(FIXTURES)], workdir, timeout=900, env=env)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-build")
    ap.add_argument("--only")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="briglia-cpbreak-"))
    tree = work / "tree"
    tree.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / name, tree / name)
    shutil.copytree(ROOT / "TelegramConcierge", tree / "TelegramConcierge")
    scratch = Path(args.keep_build) if args.keep_build else work / "build"
    failures = executed = 0
    try:
        binary = build(tree, scratch)
        r = selftest(binary, work)
        ok = r.returncode == 0
        print(("✔" if ok else "✖") + " positive control: the unmodified copy passes", flush=True)
        if not ok:
            print((r.stdout + r.stderr)[-3000:])
            return 1
        for label, check_id, edits in BREAKS:
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            originals = {}
            try:
                for rel, old, new in edits:
                    path = tree / rel
                    text = path.read_text()
                    if text.count(old) != 1:
                        raise RuntimeError(f"break anchor moved: {label}: {rel}: {old[:80]!r} (found {text.count(old)})")
                    originals.setdefault(rel, text)
                    path.write_text(text.replace(old, new))
                binary = build(tree, scratch)
                r = selftest(binary, work)
                failed = [l for l in r.stdout.splitlines() if l.startswith("✖")]
                caught = r.returncode != 0 and any(l.startswith(f"✖ {check_id} ") for l in failed)
                print(("✔" if caught else "✖") + f" {label}: {check_id} fails"
                      + (f" ({len(failed)} failing check(s))" if failed else ""), flush=True)
                failures += 0 if caught else 1
                executed += 1
                if not caught and args.verbose:
                    print((r.stdout + r.stderr)[-6000:])
            finally:
                for rel, text in originals.items():
                    (tree / rel).write_text(text)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
