#!/usr/bin/env python3
"""Repository scan for the private-by-default storage invariant.

Every file-creating call in `TelegramConcierge/**` — writes, directory
creation, copies/moves/renames/links (they carry the SOURCE's mode), and
child-process launches (a child creates files under its own umask) — must
either go through `PrivateStorage` or be listed — with a reason — in
`scripts/private-storage-allowlist.txt`. For a child process the reason
states where it writes and which umask it gets. The allowlist keys on the file path
plus the trimmed source line, so it survives line moves but not edits to the
call itself (an edited call is a new call and gets reviewed again).

Usage:
  private_storage_scan.py            check; exit 1 on any unlisted call or
                                     any entry still marked "unreviewed"
  private_storage_scan.py --regen    append every unlisted call as an
                                     "unreviewed" entry (for the routing work)
  private_storage_scan.py --prune    drop entries whose call no longer exists
"""
import os
import re
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cm_split_paths as cmp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "TelegramConcierge")
ALLOWLIST = os.path.join(ROOT, "scripts", "private-storage-allowlist.txt")

PATTERN = re.compile(
    r"\.write\(to:|\.write\(toFile:|createFile\(|createDirectory\(|"
    r"FileHandle\(forWritingTo|FileHandle\(forUpdating|"
    r"\bfopen\(|O_CREAT\b|\bmkdir\(|\bmkdirat\(|\bopenat\(|"
    r"\bcopyItem\(|\bmoveItem\(|\breplaceItemAt\(|\brename\(|\blinkItem\(|\bcreateSymbolicLink\(|"
    r"\bsymlink\(|\bProcess\(\)|\bposix_spawn\("
)
SKIP_FILE = re.compile(r"Selftest|PrivateStorage\.swift$|selftest", re.IGNORECASE)
UNREVIEWED = "unreviewed"


def source_files():
    for dirpath, _, names in os.walk(SRC):
        for name in sorted(names):
            if name.endswith(".swift"):
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, ROOT)
                if SKIP_FILE.search(rel):
                    continue
                # 0.2.59: the ConversationManager split family is accounted under
                # the main file's path (explicitly enumerated paths only), so the
                # allowlist entries and their match multiplicities are unchanged.
                yield cmp.canonical(rel), path


def call_sites():
    sites = {}
    for rel, path in source_files():
        with open(path, encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                stripped = line.strip()
                if stripped.startswith("//"):
                    continue
                if PATTERN.search(stripped):
                    sites.setdefault((rel, stripped), []).append(lineno)
    return sites


def read_allowlist():
    entries = {}
    if not os.path.exists(ALLOWLIST):
        return entries
    with open(ALLOWLIST, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split(" :: ")
            if len(parts) < 3:
                print(f"malformed allowlist line: {line}")
                sys.exit(2)
            entries[(parts[0], parts[1])] = " :: ".join(parts[2:])
    return entries


def write_allowlist(entries):
    header = [
        "# Private-storage allowlist — file-creating calls under TelegramConcierge/ that do",
        "# NOT go through PrivateStorage. Format: <path> :: <trimmed source line> :: <reason>.",
        "# A reason of 'unreviewed' fails the scan: replace it (or route the call) before release.",
        "# Regenerate missing entries with scripts/private_storage_scan.py --regen; prune stale",
        "# ones with --prune. Sorted by path so merges are trivial.",
    ]
    lines = header + [
        f"{path} :: {code} :: {reason}"
        for (path, code), reason in sorted(entries.items())
    ]
    with open(ALLOWLIST, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    sites = call_sites()
    entries = read_allowlist()
    if mode == "--regen":
        added = 0
        for key in sites:
            if key not in entries:
                entries[key] = UNREVIEWED
                added += 1
        write_allowlist(entries)
        print(f"added {added} unreviewed entr{'y' if added == 1 else 'ies'} ({len(entries)} total)")
        return
    if mode == "--prune":
        stale = [k for k in entries if k not in sites]
        for k in stale:
            del entries[k]
        write_allowlist(entries)
        print(f"pruned {len(stale)} stale entr{'y' if len(stale) == 1 else 'ies'} ({len(entries)} total)")
        return
    problems = 0
    for (rel, code), linenos in sorted(sites.items()):
        reason = entries.get((rel, code))
        if reason is None:
            print(f"UNLISTED  {rel}:{','.join(map(str, linenos))}  {code}")
            problems += 1
        elif reason.strip().lower().startswith(UNREVIEWED):
            print(f"UNREVIEWED  {rel}:{','.join(map(str, linenos))}  {code}")
            problems += 1
    stale = [k for k in entries if k not in sites]
    for rel, code in sorted(stale):
        print(f"STALE     {rel}  {code}")
        problems += 1
    print(f"{len(sites)} call sites, {len(entries)} allowlist entries, {problems} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
