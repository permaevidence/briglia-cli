#!/usr/bin/env python3
"""Source-fidelity gate for the GPT apply_patch engine (GPT_APPLY_PATCH_PLAN §14.1).

1. The vendored pinned Codex sources match codex-pinned.SHA256SUMS exactly
   (every listed file present with its hash, no unlisted file).
2. Every #[test] / #[tokio::test] in parser.rs, streaming_parser.rs,
   seek_sequence.rs, file_update_tests.rs, text_file.rs and lib.rs has a
   Swift check tagged `rust:<module>::<test>` in the CodexPatch selftest, or a
   recorded exemption with a reason (fidelity-exemptions.txt).
3. No exemption names a test that does not exist, and no tag names one.

Usage: python3 scripts/codex_patch_fidelity_check.py
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "scripts/fixtures/codex-apply-patch"
PINNED = FIX / "pinned"
MODULES = ["parser", "streaming_parser", "seek_sequence", "file_update_tests", "text_file", "lib"]
SELFTESTS = sorted((ROOT / "TelegramConcierge/CLI").glob("CodexPatchSelftest*.swift"))


def check_hashes():
    problems = []
    listed = {}
    for line in (FIX / "codex-pinned.SHA256SUMS").read_text().splitlines():
        digest, rel = line.split(None, 1)
        listed[rel.strip().lstrip("./")] = digest
    for rel, digest in listed.items():
        p = PINNED / rel
        if not p.exists():
            problems.append(f"missing vendored file {rel}")
        elif hashlib.sha256(p.read_bytes()).hexdigest() != digest:
            problems.append(f"hash mismatch {rel}")
    for p in PINNED.rglob("*"):
        if p.is_file():
            rel = str(p.relative_to(PINNED))
            if rel not in listed:
                problems.append(f"unlisted vendored file {rel}")
    return problems, len(listed)


def rust_tests():
    tests = []
    for mod in MODULES:
        text = (PINNED / "src" / f"{mod}.rs").read_text()
        for m in re.finditer(r"#\[(?:tokio::)?test\][^\n]*\n(?:\s*#\[[^\]]*\]\s*\n)*\s*(?:async\s+)?fn\s+(\w+)", text):
            tests.append(f"{mod}::{m.group(1)}")
    return tests


def main():
    problems, nfiles = check_hashes()
    tests = rust_tests()
    swift = "\n".join(p.read_text() for p in SELFTESTS)
    tags = set(re.findall(r"rust:(\w+::\w+)", swift))
    exemptions = {}
    for line in (FIX / "fidelity-exemptions.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            name, _, reason = line.partition(" — ")
            if not reason.strip():
                problems.append(f"exemption without a reason: {line}")
            exemptions[name.strip()] = reason.strip()
    covered = 0
    for t in tests:
        if t in tags:
            covered += 1
        elif t in exemptions:
            pass
        else:
            problems.append(f"Rust test without a Swift counterpart or exemption: {t}")
    for e in exemptions:
        if e not in tests:
            problems.append(f"exemption names an unknown test: {e}")
    for tag in tags:
        if tag not in tests:
            problems.append(f"Swift tag names an unknown Rust test: {tag}")
    for p in problems:
        print("✖", p)
    print(f"{'✔' if not problems else '✖'} vendored files: {nfiles} hashed; Rust tests: {len(tests)} "
          f"({covered} ported, {len(tests) - covered} exempt with reasons)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
