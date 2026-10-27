#!/usr/bin/env python3
"""Preferences accessor lint (MULTI_ASSISTANT_PLAN v5 §3.6).

Every production preferences access must go through `Prefs.store` (the
selected assistant's suite; `UserDefaults.standard` for default) or
`Prefs.domains` (named-domain API). A direct `UserDefaults.standard` or a
`UserDefaults = .standard` default anywhere else would silently share one
setting between every assistant on the computer.

Selftests are exempt (they run in throwaway domains). Comment lines are
ignored. `--self-test` proves the lint catches planted violations.
"""
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ACCESSOR = "TelegramConcierge/Utilities/Prefs.swift"
PATTERNS = [re.compile(r"UserDefaults\s*\.\s*standard"), re.compile(r"UserDefaults\s*=\s*\.standard"),
            re.compile(r":\s*UserDefaults\s*=\s*\.\s*standard")]


def violations(root):
    found = []
    for path in sorted((root / "TelegramConcierge").rglob("*.swift")):
        rel = str(path.relative_to(root))
        if rel == ACCESSOR or "selftest" in path.name.lower():
            continue
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            code = line.split("//", 1)[0] if '"' not in line else line
            if any(p.search(code) for p in PATTERNS):
                found.append(f"{rel}:{n}: {line.strip()}")
    return found


def self_test():
    ok = True
    cases = {
        "direct": "let x = UserDefaults.standard.bool(forKey: \"a\")\n",
        "spaced": "let x = UserDefaults .standard\n",
        "default-arg": "func f(d: UserDefaults = .standard) {}\n",
    }
    for label, body in cases.items():
        with tempfile.TemporaryDirectory() as t:
            t = pathlib.Path(t)
            (t / "TelegramConcierge/Services").mkdir(parents=True)
            (t / "TelegramConcierge/Services/X.swift").write_text(body)
            caught = bool(violations(t))
            print(("✔" if caught else "✖") + f" lint catches {label}")
            ok &= caught
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        (t / "TelegramConcierge/Services").mkdir(parents=True)
        (t / "TelegramConcierge/Services/X.swift").write_text("// UserDefaults.standard in a comment\nlet x = Prefs.store\n")
        (t / "TelegramConcierge/Services/FooSelftest.swift").write_text("let x = UserDefaults.standard\n")
        clean = not violations(t)
        print(("✔" if clean else "✖") + " comments, Prefs.store and selftests pass")
        ok &= clean
    return ok


def main():
    if "--self-test" in sys.argv:
        sys.exit(0 if self_test() else 1)
    found = violations(ROOT)
    if found:
        print("✖ direct preferences access outside Prefs (use Prefs.store / Prefs.domains):")
        print("\n".join("  " + f for f in found))
        sys.exit(1)
    print("✔ every production preferences access goes through Prefs")


if __name__ == "__main__":
    main()
