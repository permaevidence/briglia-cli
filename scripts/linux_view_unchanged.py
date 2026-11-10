#!/usr/bin/env python3
"""Linux view unchanged (owner scope, 2026-11-10): a macOS-only change must
leave every Swift file exactly as a Linux build sees it.

A source-comparison heuristic, not a compiler (Codex plan review r2): it is
line-based, so `#if`/`//` text inside a multiline string literal would be
taken for a directive or a comment. Linux CI on the release candidate stays
the authority. The Linux view of a Swift file approximates what a Linux build
compiles:
  * `#if / #elseif / #else / #endif` chains whose conditions use only
    os(...), canImport(...), true/false with !, &&, || and parentheses are
    evaluated for Linux (os(Linux), canImport(Glibc) and
    canImport(FoundationNetworking) are true; Apple OSes, Windows, Android and
    canImport(Darwin) are false) and only the taken branch is kept;
  * a chain with ANY other condition (DEBUG, swift(...), compiler(...),
    arch(...), an unknown module) is kept verbatim, every branch, directives
    included (conservative);
  * blank lines and whole-line `//` comments are dropped (never compiled).
The views at the base and at the candidate must be identical for every
changed, added, deleted or renamed Swift file. An added file must have an
empty Linux view (imports aside). Non-Swift changes are listed and must be
on the allowlist below (scripts and docs that no Linux build or CI job reads).

Usage:
  python3 scripts/linux_view_unchanged.py [--base 981eec5] [--head HEAD | --worktree]
  python3 scripts/linux_view_unchanged.py --self-test
"""
import argparse
import difflib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRUE_ATOMS = {"os(Linux)", "canImport(Glibc)", "canImport(FoundationNetworking)", "true"}
FALSE_ATOMS = {"os(macOS)", "os(iOS)", "os(tvOS)", "os(watchOS)", "os(visionOS)", "os(Windows)", "os(Android)",
               "os(FreeBSD)", "os(OpenBSD)", "os(WASI)", "canImport(Darwin)", "canImport(Musl)", "canImport(WinSDK)",
               "canImport(Android)", "canImport(Bionic)", "false"}
# Non-Swift files this branch may add or change, each with why it leaves the
# Linux product unchanged (printed with the result so a reviewer sees them).
NON_SWIFT_ALLOW = {
    "scripts/linux_view_unchanged.py": "this check (not run by ci.yml)",
    "scripts/python_autoinstall_break_test.py": "macOS deliberate breaks (not run by ci.yml)",
    "scripts/security_inventory.py": "inventory: adds the macOS-only Homebrew python@3.<max> entry",
    "security/dependencies.json": "inventory output (regenerated; ci.yml checks it is current)",
}

DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


def strip_comment(cond):
    i = cond.find("//")
    return (cond[:i] if i >= 0 else cond).strip()


def tokens(cond):
    out, i = [], 0
    while i < len(cond):
        c = cond[i]
        if c.isspace():
            i += 1
        elif cond.startswith("&&", i) or cond.startswith("||", i):
            out.append(cond[i:i + 2]); i += 2
        elif c in "!()":
            out.append(c); i += 1
        else:
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*(\([^()]*\))?", cond[i:])
            if not m:
                return None
            out.append(m.group(0)); i += len(m.group(0))
    return out


def evaluate(cond):
    """True/False for a decidable Linux condition, None otherwise."""
    toks = tokens(strip_comment(cond))
    if not toks:
        return None
    pos = 0

    def atom():
        nonlocal pos
        if pos >= len(toks):
            raise ValueError
        t = toks[pos]; pos += 1
        if t == "!":
            v = atom()
            return None if v is None else (not v)
        if t == "(":
            v = expr()
            if pos >= len(toks) or toks[pos] != ")":
                raise ValueError
            pos += 1
            return v
        if t in TRUE_ATOMS:
            return True
        if t in FALSE_ATOMS:
            return False
        return None

    def conj():
        nonlocal pos
        vals = [atom()]
        while pos < len(toks) and toks[pos] == "&&":
            pos += 1; vals.append(atom())
        if any(v is False for v in vals):
            return None if any(v is None for v in vals) else False
        return None if any(v is None for v in vals) else True

    def expr():
        nonlocal pos
        vals = [conj()]
        while pos < len(toks) and toks[pos] == "||":
            pos += 1; vals.append(conj())
        if any(v is None for v in vals):
            return None
        return any(vals)

    try:
        v = expr()
        return v if pos == len(toks) else None
    except ValueError:
        return None


def parse(lines, i=0, nested=False):
    """[('line', text) | ('chain', [(directive, cond|None, body)], endif)], index."""
    nodes = []
    while i < len(lines):
        m = DIRECTIVE.match(lines[i])
        if not m:
            nodes.append(("line", lines[i])); i += 1; continue
        kind = m.group(1)
        if kind in ("elseif", "else", "endif"):
            if not nested:
                raise ValueError(f"line {i + 1}: #{kind} without #if")
            return nodes, i
        branches = []
        directive, cond = lines[i], m.group(2)
        i += 1
        while True:
            body, i = parse(lines, i, nested=True)
            branches.append((directive, cond, body))
            if i >= len(lines):
                raise ValueError("unterminated #if")
            m2 = DIRECTIVE.match(lines[i])
            k2 = m2.group(1)
            if k2 == "endif":
                nodes.append(("chain", branches, lines[i])); i += 1; break
            directive, cond = lines[i], (m2.group(2) if k2 == "elseif" else None)
            i += 1
    return nodes, i


def render(nodes, out):
    for node in nodes:
        if node[0] == "line":
            out.append(node[1]); continue
        _, branches, endif = node
        values = [True if cond is None else evaluate(cond) for _, cond, _ in branches]
        if any(v is None for v in values):
            for directive, _, body in branches:
                out.append(directive)
                render(body, out)
            out.append(endif)
            continue
        for v, (_, _, body) in zip(values, branches):
            if v:
                render(body, out); break


def linux_view(text):
    nodes, _ = parse(text.splitlines())
    out = []
    render(nodes, out)
    return [l.rstrip() for l in out if l.strip() and not l.strip().startswith("//")]


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def file_at(ref, path):
    r = subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def compare(base, head, worktree):
    diff_args = ["diff", "--name-status", "-M", base] + ([] if worktree else [head])
    changed = [l.split("\t") for l in git(*diff_args).splitlines() if l.strip()]
    if worktree:
        untracked = git("ls-files", "--others", "--exclude-standard").splitlines()
        changed += [["A", p] for p in untracked]
    problems, swift = [], 0
    for entry in changed:
        status, paths = entry[0], entry[1:]
        old_path, new_path = paths[0], paths[-1]
        if not any(p.endswith(".swift") for p in paths):
            for p in paths:
                if p not in NON_SWIFT_ALLOW:
                    problems.append(f"non-Swift change not on the allowlist: {p} ({status})")
            continue
        swift += 1
        if status.startswith("D"):
            problems.append(f"{old_path}: deleted Swift file")
            continue
        old = file_at(base, old_path) if not status.startswith("A") else None
        if worktree:
            new = (ROOT / new_path).read_text() if (ROOT / new_path).exists() else ""
        else:
            new = file_at(head, new_path) or ""
        old_view = linux_view(old) if old is not None else []
        new_view = linux_view(new)
        if old is None:
            residue = [l for l in new_view if not l.strip().startswith("import ")]
            if residue:
                problems.append(f"{new_path}: added file has a Linux view:\n  " + "\n  ".join(residue[:20]))
            continue
        if old_view != new_view:
            d = "\n".join(difflib.unified_diff(old_view, new_view, f"{base}:{old_path}", f"{'worktree' if worktree else head}:{new_path}", lineterm="", n=2))
            problems.append(f"{new_path}: Linux view changed\n{d}")
    return swift, problems


def self_test():
    cases = []

    def same(a, b):
        return linux_view(a) == linux_view(b)

    base = "let a = 1\n#if os(macOS)\nlet m = 1\n#else\nlet l = 1\n#endif\n#if DEBUG\nlet d = 1\n#endif\n#if os(Linux)\n#if os(macOS)\nlet x = 1\n#endif\nlet y = 1\n#elseif canImport(Darwin)\nlet z = 1\n#endif\n"
    cases.append(("a change outside any #if is caught", not same(base, base.replace("let a = 1", "let a = 2"))))
    cases.append(("a change inside #if os(macOS) is ignored", same(base, base.replace("let m = 1", "let m = 2\nlet extra = 3"))))
    cases.append(("a change in the macOS branch of #if os(Linux) #else is ignored",
                  same("#if os(Linux)\nlet l = 1\n#else\nlet m = 1\n#endif\n", "#if os(Linux)\nlet l = 1\n#else\nlet m = 2\n#endif\n")))
    cases.append(("a change in the Linux branch (#else of os(macOS)) is caught", not same(base, base.replace("let l = 1", "let l = 2"))))
    cases.append(("an unknown condition (DEBUG) is kept verbatim and caught", not same(base, base.replace("let d = 1", "let d = 2"))))
    cases.append(("a nested os(macOS) inside os(Linux) is ignored", same(base, base.replace("let x = 1", "let x = 9"))))
    cases.append(("the Linux side of a nested chain is caught", not same(base, base.replace("let y = 1", "let y = 9"))))
    cases.append(("an #elseif canImport(Darwin) branch is ignored", same(base, base.replace("let z = 1", "let z = 9"))))
    cases.append(("wrapping existing code in #if os(macOS) … #else <it> #endif is invisible",
                  same("func f() {\n    return 1\n}\n", "func f() {\n    #if os(macOS)\n    return 2\n    #else\n    return 1\n    #endif\n}\n")))
    cases.append(("a new #if os(macOS) block is invisible", same("let a = 1\n", "let a = 1\n#if os(macOS)\nlet b = 2\n#endif\n")))
    cases.append(("whole-line comments and blank lines are ignored", same("let a = 1\n", "\n// note\nlet a = 1\n   /// doc\n")))
    cases.append(("a trailing comment change is caught", not same("let a = 1\n", "let a = 1 // x\n")))
    cases.append(("an unknown condition mixed with Linux (os(Linux) && DEBUG) is verbatim and caught",
                  not same("#if os(Linux) && DEBUG\nlet a = 1\n#endif\n", "#if os(Linux) && DEBUG\nlet a = 2\n#endif\n")))
    cases.append(("!os(macOS) counts as Linux", not same("#if !os(macOS)\nlet a = 1\n#endif\n", "#if !os(macOS)\nlet a = 2\n#endif\n")))
    cases.append(("os(macOS) || os(Linux) counts as Linux", not same("#if os(macOS) || os(Linux)\nlet a = 1\n#endif\n", "#if os(macOS) || os(Linux)\nlet a = 2\n#endif\n")))
    cases.append(("a directive moved into the Linux view (#if os(macOS) → #if true) is caught",
                  not same("#if os(macOS)\nlet a = 1\n#endif\n", "#if true\nlet a = 1\n#endif\n")))
    failed = [name for name, ok in cases if not ok]
    for name, ok in cases:
        print(("✔ " if ok else "✖ ") + name)
    print(f"\nlinux-view self-test: {len(cases) - len(failed)}/{len(cases)}")
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="981eec5")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--worktree", action="store_true", help="compare the working tree (incl. untracked files) instead of --head")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    swift, problems = compare(a.base, a.head, a.worktree)
    changed_non_swift = sorted(p for p in NON_SWIFT_ALLOW if p in git("diff", "--name-only", a.base, *([] if a.worktree else [a.head])).split()
                               + (git("ls-files", "--others", "--exclude-standard").split() if a.worktree else []))
    for p in changed_non_swift:
        print(f"· allowed non-Swift change: {p} — {NON_SWIFT_ALLOW[p]}")
    for p in problems:
        print("✖ " + p)
    print(f"\nlinux view: {swift} changed Swift file(s) checked against {a.base}; "
          + ("UNCHANGED for Linux" if not problems else f"{len(problems)} problem(s)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
