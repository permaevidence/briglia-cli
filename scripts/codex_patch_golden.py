#!/usr/bin/env python3
"""Golden differential corpus for the GPT apply_patch engine
(GPT_APPLY_PATCH_PLAN §14.5).

Generates seeded cases (mixed line endings, BOM, trailing whitespace,
typographic punctuation, repeated short lines, canonical Codex patches with
three context lines, @@ anchors, EOF hunks, pure insertions, multi-file
patches with moves, adds and deletes, and corrupted variants), runs each ONCE
through the pinned Codex standalone `apply_patch` binary
(codex-rs/apply-patch/src/main.rs -> lib.rs apply path), and writes the inputs
and the raw Codex outcome (exit, stdout, stderr, resulting tree) to
cases.jsonl. The Swift selftest (`__codex-patch-selftest`, group G) replays
every case through the port. Expectations are never regenerated from the
port; a reference update is a reviewed change.

Only the temporary root path is normalised (to {ROOT}).

Divergences (§6.9) keep the raw Codex result next to a Briglia expectation:
  TX   Codex failed after applying earlier hunks; Briglia applies nothing.
  BOM  a UTF-8 BOM file whose first line takes part in matching; the Briglia
       expectation is the oracle's result on the BOM-stripped input with the
       BOM restored on the updated (or moved) file.

Usage:
  python3 scripts/codex_patch_golden.py generate --oracle PATH [--seed 20261109] [--count 2000]
  python3 scripts/codex_patch_golden.py verify --oracle PATH      # re-run the oracle, compare
"""
import argparse
import base64
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

GENERATOR_VERSION = 1
ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "scripts/fixtures/codex-apply-patch/golden"
PINNED_COMMIT = "4e4767ffa763ec0d0a19e04cf8ff0163a987297b"

WORDS = ["alpha", "beta", "gamma", "delta", "value", "count", "items", "result", "config", "self",
         "return", "print", "total", "index", "name", "data", "path", "user", "node", "cache"]
TYPO = ["–", "—", "‘", "’", "“", "”", " ", "‑"]
ASCII_OF = {"–": "-", "—": "-", "‑": "-", "‘": "'", "’": "'", "“": '"', "”": '"', " ": " "}
SHORT = ["}", "", "end", "return x", "pass", "{", "fi", "done"]


def make_line(rng):
    r = rng.random()
    if r < 0.22:
        return rng.choice(SHORT)
    indent = " " * rng.choice([0, 0, 2, 4, 4, 8]) if rng.random() < 0.9 else "\t"
    words = [rng.choice(WORDS) for _ in range(rng.randint(1, 5))]
    line = indent + " ".join(words)
    if rng.random() < 0.15:
        pos = rng.randint(0, len(line))
        line = line[:pos] + rng.choice(TYPO) + line[pos:]
    if rng.random() < 0.08:
        line += " naïve café"
    if rng.random() < 0.12:
        line += rng.choice([" ", "  ", "\t"])
    return line


def make_file(rng):
    n = rng.randint(3, 30)
    lines = [make_line(rng) for _ in range(n)]
    style = rng.random()
    if style < 0.70:
        endings = ["\n"] * n
    elif style < 0.85:
        endings = ["\r\n"] * n
    elif style < 0.88:
        endings = ["\r"] * n
    else:
        endings = [rng.choice(["\n", "\r\n"]) for _ in range(n)]
    if rng.random() < 0.2:
        endings[-1] = ""
    body = "".join(l + e for l, e in zip(lines, endings))
    bom = rng.random() < 0.05
    return lines, body, bom


def perturb(rng, line, mode):
    if mode == "trim_end":
        return line.rstrip(" \t")
    if mode == "trim":
        return "  " + line.strip(" \t") if rng.random() < 0.5 else line.strip(" \t")
    if mode == "ascii":
        return "".join(ASCII_OF.get(c, c) for c in line)
    return line


def update_chunks(rng, lines, allow_eof=True):
    """Canonical chunks with up to three context lines; regions in order."""
    n = len(lines)
    chunks = []
    cursor = 0
    for _ in range(rng.randint(1, 3)):
        if cursor >= n:
            break
        start = rng.randint(cursor, max(cursor, n - 1))
        removed = rng.randint(0, min(3, n - start))
        added = [make_line(rng) for _ in range(rng.randint(0 if removed else 1, 3))]
        before = lines[max(0, start - 3):start]
        after = lines[start + removed:start + removed + 3]
        mode = rng.choice(["exact"] * 6 + ["trim_end", "trim", "ascii"])
        body = []
        if rng.random() < 0.25 and start - len(before) - 1 >= 0:
            anchor_idx = rng.randint(0, start - len(before) - 1)
            body.append("@@ " + lines[anchor_idx])
        else:
            body.append("@@")
        body += [" " + perturb(rng, l, mode) for l in before]
        body += ["-" + perturb(rng, l, mode) for l in lines[start:start + removed]]
        body += ["+" + l for l in added]
        body += [" " + perturb(rng, l, mode) for l in after]
        if allow_eof and start + removed + len(after) == n and rng.random() < 0.5 and (before or removed or after):
            body.append("*** End of File")
        chunks.append(body)
        cursor = start + removed + len(after) + 1
    if rng.random() < 0.1:
        chunks.append(["@@", "+" + make_line(rng)])   # pure insertion -> appended at EOF
    return chunks


def corrupt(rng, patch_lines):
    kind = rng.choice(["context", "header", "end", "empty_update", "bad_line", "missing_file"])
    idx = [i for i, l in enumerate(patch_lines) if l[:1] in "- " and not l.startswith("***")]
    if kind == "context" and idx:
        i = rng.choice(idx)
        patch_lines[i] = patch_lines[i][0] + "zzz " + make_line(rng)
    elif kind == "header":
        heads = [i for i, l in enumerate(patch_lines) if l.startswith("*** ") and "Patch" not in l]
        if heads:
            i = rng.choice(heads)
            patch_lines[i] = patch_lines[i].replace("File:", "Fiel:", 1)
    elif kind == "end":
        patch_lines.pop()
    elif kind == "empty_update":
        patch_lines.insert(len(patch_lines) - 1, "*** Update File: {ROOT}/empty_update.txt")
    elif kind == "bad_line":
        if idx:
            patch_lines.insert(rng.choice(idx) + 1, "garbage line")
    elif kind == "missing_file":
        patch_lines.insert(len(patch_lines) - 1, "*** Update File: {ROOT}/no/such/file.txt\n@@\n-x\n+y")
    return kind


def make_case(rng, case_no):
    nfiles = rng.randint(1, 3)
    files = {}
    meta = {}
    for i in range(nfiles):
        rel = rng.choice(["", "src/", "lib/deep/"]) + f"f{i}.txt"
        lines, body, bom = make_file(rng)
        files[rel] = (b"\xef\xbb\xbf" if bom else b"") + body.encode()
        meta[rel] = {"lines": lines, "bom": bom}
    patch = ["*** Begin Patch"]
    touched_bom = {}
    used = set(files)
    for rel in sorted(files):
        r = rng.random()
        info = meta[rel]
        if r < 0.62:
            patch.append(f"*** Update File: {{ROOT}}/{rel}")
            dest = None
            if rng.random() < 0.15:
                dest = rng.choice(["moved/", "", "a/b/"]) + "m_" + Path(rel).name
                if dest in used:
                    dest = None
                else:
                    used.add(dest)
                    patch.append(f"*** Move to: {{ROOT}}/{dest}")
            for chunk in update_chunks(rng, info["lines"]):
                patch += chunk
            if info["bom"]:
                touched_bom[rel] = ("update", dest)
        elif r < 0.75:
            patch.append(f"*** Delete File: {{ROOT}}/{rel}")
            if info["bom"]:
                touched_bom[rel] = ("delete", None)
        elif r < 0.85:
            patch.append(f"*** Add File: {{ROOT}}/{rel}")
            patch += ["+" + make_line(rng) for _ in range(rng.randint(0, 5))]
            if info["bom"]:
                touched_bom[rel] = ("add", None)
        # else: untouched
    if rng.random() < 0.35:
        new = rng.choice(["new/", "", "src/"]) + f"added{case_no}.txt"
        if new not in used:
            used.add(new)
            patch.append(f"*** Add File: {{ROOT}}/{new}")
            patch += ["+" + make_line(rng) for _ in range(rng.randint(1, 6))]
    patch.append("*** End Patch")
    corruption = None
    if rng.random() < 0.12:
        corruption = corrupt(rng, patch)
    text = "\n".join(patch)
    if rng.random() < 0.1:
        text += "\n"
    return files, text, touched_bom, corruption


def tree(root):
    out = {}
    for dirpath, _, names in os.walk(root):
        for name in names:
            p = Path(dirpath) / name
            if p.is_symlink() or not p.is_file():
                continue
            out[str(p.relative_to(root))] = base64.b64encode(p.read_bytes()).decode()
    return out


def run_oracle(oracle, files, patch):
    work = Path(tempfile.mkdtemp(prefix="cpg-"))
    root = (work / "r").resolve()
    root.mkdir()
    root = Path(os.path.realpath(root))
    try:
        for rel, data in files.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        text = patch.replace("{ROOT}", str(root))
        r = subprocess.run([oracle, text], cwd=root, capture_output=True, timeout=60)
        norm = lambda s: s.decode("utf-8", "replace").replace(str(root), "{ROOT}")
        return {"exit": r.returncode, "stdout": norm(r.stdout), "stderr": norm(r.stderr), "tree": tree(root)}
    finally:
        shutil.rmtree(work, ignore_errors=True)


def b64files(files):
    return {k: base64.b64encode(v).decode() for k, v in files.items()}


def build_case(oracle, rng, n):
    files, patch, touched_bom, corruption = make_case(rng, n)
    codex = run_oracle(oracle, files, patch)
    case = {"id": f"g{n:05d}", "files": b64files(files), "patch": patch, "codex": codex,
            "divergence": None, "briglia": None, "corruption": corruption}
    input_tree = b64files(files)
    if touched_bom and any(kind == "update" for kind, _ in touched_bom.values()):
        stripped = {k: (v[3:] if v.startswith(b"\xef\xbb\xbf") else v) for k, v in files.items()}
        alt = run_oracle(oracle, stripped, patch)
        if alt["exit"] == 0:
            expect = dict(alt["tree"])
            for rel, (kind, dest) in touched_bom.items():
                target = dest if (kind == "update" and dest) else rel
                if kind == "update" and target in expect:
                    expect[target] = base64.b64encode(b"\xef\xbb\xbf" + base64.b64decode(expect[target])).decode()
            # untouched BOM files keep their bytes
            for rel, v in files.items():
                if v.startswith(b"\xef\xbb\xbf") and rel not in touched_bom and rel in expect:
                    expect[rel] = base64.b64encode(v).decode()
            briglia = {"applied": True, "tree": expect}
        else:
            briglia = {"applied": False, "tree": input_tree}
        same = codex["exit"] == 0 and codex["tree"] == briglia["tree"] and briglia["applied"]
        if not same:
            case["divergence"] = "BOM"
            case["briglia"] = briglia
    if case["divergence"] is None and codex["exit"] != 0 and codex["tree"] != input_tree:
        case["divergence"] = "TX"
        case["briglia"] = {"applied": False, "tree": input_tree}
    return case


def toolchain_info(oracle):
    rustc = subprocess.run(["rustc", "--version"], capture_output=True, text=True).stdout.strip()
    cargo = subprocess.run(["cargo", "--version"], capture_output=True, text=True).stdout.strip()
    oracle_sha = hashlib.sha256(Path(oracle).read_bytes()).hexdigest()
    lock = Path(oracle).resolve()
    lock_hash = None
    for parent in lock.parents:
        cand = parent / "codex/codex-rs/Cargo.lock"
        if cand.exists():
            lock_hash = hashlib.sha256(cand.read_bytes()).hexdigest()
            break
    return {"rustc": rustc, "cargo": cargo, "oracle_sha256": oracle_sha, "cargo_lock_sha256": lock_hash}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["generate", "verify"])
    ap.add_argument("--oracle", required=True)
    ap.add_argument("--seed", type=int, default=20261109)
    ap.add_argument("--count", type=int, default=2000)
    args = ap.parse_args()
    if args.command == "generate":
        rng = random.Random(args.seed)
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        stats = {}
        with open(OUT_DIR / "cases.jsonl", "w") as f:
            for n in range(args.count):
                case = build_case(args.oracle, rng, n)
                key = case["divergence"] or ("ok" if case["codex"]["exit"] == 0 else "err")
                stats[key] = stats.get(key, 0) + 1
                f.write(json.dumps(case, ensure_ascii=False, sort_keys=True) + "\n")
        manifest = {
            "generator": "scripts/codex_patch_golden.py", "generator_version": GENERATOR_VERSION,
            "seed": args.seed, "count": args.count, "pinned_commit": PINNED_COMMIT,
            "oracle_entry_point": "codex-rs/apply-patch/src/main.rs -> standalone_executable::main -> lib.rs apply_patch",
            "build_recipe": "git fetch --depth 1 https://github.com/openai/codex.git " + PINNED_COMMIT
                            + "; cd codex-rs; cargo build -p codex-apply-patch --bin apply_patch --release",
            "toolchain": toolchain_info(args.oracle), "stats": stats,
            "cases_sha256": hashlib.sha256((OUT_DIR / "cases.jsonl").read_bytes()).hexdigest(),
        }
        (OUT_DIR / "MANIFEST.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(json.dumps(stats, sort_keys=True))
        return 0
    # verify: re-run the oracle on the committed inputs; outcomes must be identical.
    bad = 0
    total = 0
    for line in (OUT_DIR / "cases.jsonl").read_text().splitlines():
        case = json.loads(line)
        files = {k: base64.b64decode(v) for k, v in case["files"].items()}
        again = run_oracle(args.oracle, files, case["patch"])
        total += 1
        if again != case["codex"]:
            bad += 1
            print("mismatch", case["id"])
    print(f"{total - bad}/{total} cases reproduce")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
