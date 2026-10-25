#!/usr/bin/env python3
"""Briglia's private Python lock (security plan v24 §7.9.4).

TelegramConcierge/Resources/PythonEnv/requirements.lock is ONE universal lock
(every wheel hash of every platform, versions forked by environment markers)
generated from requirements.in next to it:

  uv pip compile requirements.in --universal --generate-hashes \
     --only-binary :all: --python-version 3.11 --no-header

Briglia installs it with `pip install --require-hashes --no-deps
--only-binary=:all:` into a new venv and proves the closure per platform with
`pip check` plus an installed-distribution comparison.

  python_lock.py --regenerate   rewrite the lock with uv (needs uv + network)
  python_lock.py --check        CI: the header binds the committed input bytes
                                and the generator settings; every requirement is
                                ==-pinned with sha256 hashes; every input is
                                present; the bootstrap distributions are not in
                                it. Standard library only, offline.
  python_lock.py --entries      print the locked (name, version, marker) rows
"""
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "TelegramConcierge", "Resources", "PythonEnv")
IN = os.path.join(DIR, "requirements.in")
LOCK = os.path.join(DIR, "requirements.lock")
FLAGS = ["--universal", "--generate-hashes", "--only-binary", ":all:", "--python-version", "3.11", "--no-header"]
MAGIC = "# briglia-python-lock v1"
BOOTSTRAP = {"pip", "setuptools", "wheel"}
REQ_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;\\]+)(?:\s*;\s*([^\\]+?))?\s*\\?$")


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def inputs(text):
    out = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", line):
                raise ValueError(f"requirements.in: only bare names are allowed, got {line!r}")
            out.append(norm(line))
    return out


def entries(lock_text):
    """[(name, version, marker or None, [hashes])] from the lock body."""
    rows, cur = [], None
    for raw in lock_text.splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if not raw.startswith(" "):
            m = REQ_RE.match(line)
            if not m:
                raise ValueError(f"unexpected lock line: {line[:80]!r}")
            cur = [norm(m.group(1)), m.group(2), (m.group(3) or "").strip() or None, []]
            rows.append(cur)
            continue
        m = re.match(r"^\s+--hash=sha256:([0-9a-f]{64})\s*\\?$", line)
        if not m or cur is None:
            raise ValueError(f"unexpected continuation line: {line[:80]!r}")
        cur[3].append(m.group(1))
    return [tuple(r) for r in rows]


def header(in_bytes, uv_version):
    return [MAGIC,
            f"# input-sha256: {hashlib.sha256(in_bytes).hexdigest()}",
            f"# generator: uv {uv_version}",
            "# command: uv pip compile requirements.in " + " ".join(FLAGS)]


def check():
    with open(IN, "rb") as f:
        in_bytes = f.read()
    with open(LOCK, encoding="utf-8") as f:
        text = f.read()
    lines = text.splitlines()
    problems = []
    if len(lines) < 4 or lines[0] != MAGIC:
        problems.append("lock header missing")
    else:
        want = f"# input-sha256: {hashlib.sha256(in_bytes).hexdigest()}"
        if lines[1] != want:
            problems.append("requirements.in changed since the lock was generated (input-sha256 mismatch): run python_lock.py --regenerate")
        if not re.match(r"^# generator: uv \d+\.\d+\.\d+$", lines[2]):
            problems.append("generator line malformed")
        if lines[3] != "# command: uv pip compile requirements.in " + " ".join(FLAGS):
            problems.append("generation flags differ from the reviewed ones")
    try:
        rows = entries(text)
    except ValueError as e:
        problems.append(str(e))
        rows = []
    names = {r[0] for r in rows}
    for r in rows:
        if not r[3]:
            problems.append(f"{r[0]}=={r[1]} has no sha256 hash")
        if r[0] in BOOTSTRAP:
            problems.append(f"bootstrap distribution {r[0]} must not be in the lock")
    for name in inputs(in_bytes.decode()):
        if name not in names:
            problems.append(f"input {name} missing from the lock")
    keys = [(r[0], r[1], r[2]) for r in rows]
    if len(keys) != len(set(keys)):
        problems.append("duplicate (name, version, marker) rows")
    if problems:
        for p in problems:
            print(f"✖ python lock: {p}", file=sys.stderr)
        return 1
    print(f"✔ python lock current: {len(rows)} entries ({len(names)} distributions), {sum(len(r[3]) for r in rows)} hashes")
    return 0


def regenerate():
    with open(IN, "rb") as f:
        in_bytes = f.read()
    uv = subprocess.run(["uv", "--version"], capture_output=True, text=True, check=True).stdout.split()[1]
    out = subprocess.run(["uv", "pip", "compile", "requirements.in"] + FLAGS, cwd=DIR, capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stderr, file=sys.stderr)
        return 1
    with open(LOCK, "w", encoding="utf-8") as f:
        f.write("\n".join(header(in_bytes, uv)) + "\n" + out.stdout)
    return check()


def main(argv):
    if "--regenerate" in argv:
        return regenerate()
    if "--entries" in argv:
        with open(LOCK, encoding="utf-8") as f:
            for name, version, marker, _ in entries(f.read()):
                print(name, version, marker or "")
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
