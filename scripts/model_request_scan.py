#!/usr/bin/env python3
"""Repository scan for the session-affinity invariant (SESSION_AFFINITY_PLAN §7.2).

Every `URLRequest(url` built in `TelegramConcierge/**` (selftests excluded)
must either be decorated in the same function — a following line within
the function body calls `SessionAffinity.decorate(` or
`SessionAffinity.headers(` — or be listed, with a reason, in
`scripts/model-request-allowlist.txt` (a request that is NOT a model
request: Telegram, AgentMail, balances, release downloads, ...).

The allowlist keys on the file path plus the trimmed source line, so it
survives line moves but not edits to the call itself.

Usage:
  model_request_scan.py            check; exit 1 on any unlisted, undecorated
                                   site or any entry still marked "unreviewed"
  model_request_scan.py --regen    append every unlisted site as "unreviewed"
  model_request_scan.py --prune    drop entries whose site no longer exists
"""
import os
import re
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cm_split_paths as cmp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "TelegramConcierge")
ALLOWLIST = os.path.join(ROOT, "scripts", "model-request-allowlist.txt")

REQUEST = re.compile(r"\bURLRequest\(url")
DECORATED = re.compile(r"SessionAffinity\.(decorate|headers)\(")
FUNC = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|static|nonisolated|override|mutating)\s+)*func\s")
SKIP_FILE = re.compile(r"Selftest|selftest|SessionAffinity\.swift$", re.IGNORECASE)
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


def indent(line):
    return len(line) - len(line.lstrip(" "))


def undecorated_sites():
    """(rel, stripped line) -> [line numbers] for every URLRequest(url that is
    not followed by a decorator call inside the same function body."""
    sites = {}
    for rel, path in source_files():
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("//") or not REQUEST.search(stripped):
                continue
            # Walk forward to the end of the enclosing function: the next
            # `func` declaration at an indentation no deeper than this
            # statement's enclosing function, approximated as the next
            # `func` line with indentation < this line's indentation.
            here = indent(line)
            decorated = False
            for j in range(i + 1, len(lines)):
                nxt = lines[j]
                if FUNC.match(nxt) and indent(nxt) < here:
                    break
                if DECORATED.search(nxt) and not nxt.strip().startswith("//"):
                    decorated = True
                    break
            if not decorated:
                sites.setdefault((rel, stripped), []).append(i + 1)
    return sites


def load_allowlist():
    entries = {}
    order = []
    if not os.path.exists(ALLOWLIST):
        return entries, order
    with open(ALLOWLIST, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                order.append((None, line))
                continue
            parts = line.split(" :: ", 2)
            if len(parts) != 3:
                print(f"malformed allowlist line: {line}")
                sys.exit(2)
            key = (parts[0], parts[1])
            entries[key] = parts[2]
            order.append((key, line))
    return entries, order


def write_allowlist(entries):
    header = [
        "# Model-request allowlist — URLRequest(url sites under TelegramConcierge/ that are",
        "# NOT decorated by SessionAffinity in the same function. Format:",
        "# <path> :: <trimmed source line> :: <reason>. A reason of 'unreviewed' fails the scan.",
        "# Regenerate missing entries with scripts/model_request_scan.py --regen; prune stale",
        "# ones with --prune. Sorted by path so merges are trivial.",
    ]
    body = [f"{k[0]} :: {k[1]} :: {v}" for k, v in sorted(entries.items())]
    with open(ALLOWLIST, "w", encoding="utf-8") as f:
        f.write("\n".join(header + body) + "\n")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    sites = undecorated_sites()
    entries, _ = load_allowlist()
    if mode == "--regen":
        added = 0
        for key in sites:
            if key not in entries:
                entries[key] = UNREVIEWED
                added += 1
        write_allowlist(entries)
        print(f"added {added} unreviewed entr{'y' if added == 1 else 'ies'}")
        return 0
    if mode == "--prune":
        stale = [k for k in entries if k not in sites]
        for k in stale:
            del entries[k]
        write_allowlist(entries)
        print(f"pruned {len(stale)} stale entr{'y' if len(stale) == 1 else 'ies'}")
        return 0
    problems = 0
    for key, linenos in sorted(sites.items()):
        reason = entries.get(key)
        if reason is None:
            problems += 1
            print(f"UNDECORATED {key[0]}:{','.join(map(str, linenos))}: {key[1]}")
        elif reason.strip() == UNREVIEWED:
            problems += 1
            print(f"UNREVIEWED  {key[0]}:{','.join(map(str, linenos))}: {key[1]}")
    stale = [k for k in entries if k not in sites]
    for k in sorted(stale):
        print(f"STALE       {k[0]}: {k[1]} (allowlisted but no longer an undecorated site)")
    problems += len(stale)
    decorated_total = 0
    for rel, path in source_files():
        with open(path, encoding="utf-8") as f:
            decorated_total += len(REQUEST.findall(f.read()))
    print(f"model-request scan: {decorated_total} URLRequest site(s), {len(sites)} undecorated "
          f"({len(sites) - problems if problems <= len(sites) else 0} allowlisted), {problems} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
