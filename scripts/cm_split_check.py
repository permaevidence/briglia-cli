#!/usr/bin/env python3
"""Moved-lines checker for the 0.2.59 ConversationManager split (plan v3 §7).

The split must be purely mechanical: whole members cut from the immutable base
(`59860aa:TelegramConcierge/Services/ConversationManager.swift`, SHA-256 pinned
below) and pasted unchanged into 14 files, with three generated strings only
(the header H = base lines 1-15, `extension ConversationManager {\\n`, `}\\n`)
and the reviewed access-modifier deletions. This tool:

- builds the expected bytes of every file from the BASE and the manifest and
  compares the candidate with them (never the other way round);
- inventories the base independently of the manifest (its own lexer);
- takes the reviewed access-edit list from a fixed reference, a git object of
  the pinned C1 commit (`scripts/fixtures/cm-split/reviewed-access-edits.json`),
  never from the manifest under test;
- derives the setter read-site census and the seam blobs from C1 objects.

Modes
  --unsplit [--tree DIR]                 C1: no manifest, no split file, main == base
  --tree DIR --c1 SHA                    candidate working tree against C1 objects
  --verify-commit C2 --c1 C1             the immutable C1 -> C2 transformation (CI)
  --selftest [--c1 SHA] [--c2 SHA]       deliberate breaks (representative layout,
                                         and the real manifest when --c2 is given)
  --materialize MANIFEST --out DIR       write the files a manifest describes (tooling)
"""
import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cm_split_paths as P  # noqa: E402
import cm_split_swift as S  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BASE_COMMIT = "59860aa"
BASE_COMMIT_FULL = None  # resolved lazily
BASE_PATH = P.MAIN
BASE_SHA256 = "53a62833c86204607b7132cc1b47be778a672fd38c36bec974fd3eb372067b63"
BASE_LINES = 18052
HEADER = [1, 15]
OPENER = "extension ConversationManager {\n"
CLOSER = "}\n"
MANIFEST_REL = "scripts/fixtures/cm-split/manifest.json"
REVIEWED_REL = "scripts/fixtures/cm-split/reviewed-access-edits.json"
LAYOUT_REL = "scripts/fixtures/cm-split/selftest-layout.json"
SEAM_FILES = sorted([
    "scripts/fixtures/active-compaction/ManagerSeam.swift",
    "scripts/fixtures/active-compaction/SummaryBoundsSeam.swift",
    "scripts/fixtures/background-archive/ManagerSeam.swift",
    "scripts/fixtures/chat-lifecycle/ManagerSeam.swift",
    "scripts/fixtures/prune-archives/ManagerSeam.swift",
    "scripts/fixtures/responses/ManagerSeam.swift",
])
WIDENED_SETTERS = ("isRestoringMind", "lastPromptTokens", "pendingMidTurnMessages", "stoppedRunsFinishing", "turnActivity")
DELETIONS = ("private ", "fileprivate ", "private(set) ")
MANIFEST_KEYS = {"schema", "base", "header", "naming", "files", "access_edits", "seam_files", "setter_read_sites"}
EDIT_KEYS = {"line", "name", "member_kind", "scope", "delete", "reason"}
FILE_KEYS = {"path", "role", "class_body_ranges", "extension_ranges"}


class CheckFailure(Exception):
    def __init__(self, check, message):
        super().__init__(f"[{check}] {message}")
        self.check = check


def fail(check, message):
    raise CheckFailure(check, message)


def git(*args, cwd=ROOT, binary=False):
    out = subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE)
    return out if binary else out.decode()


def git_blob(commit, path, cwd=ROOT):
    return git("show", f"{commit}:{path}", cwd=cwd, binary=True)


def git_tree_files(commit, cwd=ROOT):
    return [p for p in git("ls-tree", "-r", "--name-only", commit, cwd=cwd).split("\n") if p]


# ----------------------------------------------------------------------------- base
class Base:
    def __init__(self, raw):
        if hashlib.sha256(raw).hexdigest() != BASE_SHA256:
            fail("base", "base bytes do not match the pinned SHA-256")
        self.raw = raw
        self.text = raw.decode("utf-8")
        self.lines = self.text.split("\n")[:-1]  # keep newline-terminated lines
        if len(self.lines) != BASE_LINES or not self.text.endswith("\n"):
            fail("base", "unexpected base line count")
        self.inv = S.Inventory(self.text)
        self.line_start = [0]
        for ln in self.lines:
            self.line_start.append(self.line_start[-1] + len(ln.encode("utf-8")) + 1)
        self.header = "".join(l + "\n" for l in self.lines[HEADER[0] - 1:HEADER[1]])
        self._direct = None

    @classmethod
    def load(cls):
        return cls(git_blob(BASE_COMMIT, BASE_PATH))

    def line(self, n):
        return self.lines[n - 1] + "\n"

    def direct(self):
        """{(scope, line of the member's first code line ... ) } helper: list of (scope, member)."""
        if self._direct is None:
            self._direct = self.inv.all_direct()
        return self._direct

    # unit boundaries -------------------------------------------------------
    def class_units(self):
        return [(m.trivia_line, m.end_line, m) for m in self.inv.class_members]

    def ext_blocks(self):
        return [(blk.trivia_line, blk.end_line if blk is not self.inv.top[-1] else BASE_LINES, header)
                for blk, header, _ in self.inv.extensions]

    def retained(self, m):
        return (m.kind in ("var", "let") and m.stored) or m.kind in ("struct", "enum", "class", "actor",
                                                                      "protocol", "typealias", "init", "deinit")


def member_kind(m):
    if m.kind in ("var", "let"):
        return ("static-" if m.static else "") + ("stored-property" if m.stored else "computed-property")
    if m.kind == "func":
        return "static-func" if m.static else "func"
    return m.kind


# ----------------------------------------------------------------------------- manifest
def validate_manifest(man):
    """Strict schema; returns nothing, raises CheckFailure('manifest', ...)."""
    def need(cond, msg):
        if not cond:
            fail("manifest", msg)
    need(isinstance(man, dict) and set(man) == MANIFEST_KEYS, "unknown or missing top-level keys: " + str(sorted(set(man) ^ MANIFEST_KEYS) if isinstance(man, dict) else man))
    need(man["schema"] == 1, "schema must be 1")
    need(man["base"] == {"commit": BASE_COMMIT, "path": BASE_PATH, "sha256": BASE_SHA256, "lines": BASE_LINES}, "base block differs from the pinned base")
    need(man["header"] == HEADER, "header must be [1, 15]")
    need(man["naming"] in P.NAMINGS, "naming")
    files = man["files"]
    need(isinstance(files, list) and all(isinstance(f, dict) and set(f) == FILE_KEYS for f in files), "file entries: wrong keys")
    paths = [f["path"] for f in files]
    need(paths == P.family(man["naming"]), "files must be exactly the 15 paths of the naming, main first, in group order")
    for f in files:
        need(f["role"] == ("main" if f["path"] == P.MAIN else "split"), "role of " + f["path"])
        for key in ("class_body_ranges", "extension_ranges"):
            rs = f[key]
            need(isinstance(rs, list) and all(isinstance(r, list) and len(r) == 2 and all(type(x) is int for x in r) and 1 <= r[0] <= r[1] <= BASE_LINES for r in rs), f"{key} of {f['path']}: malformed or out of bounds")
            need(all(rs[i][1] < rs[i + 1][0] for i in range(len(rs) - 1)), f"{key} of {f['path']}: unsorted or overlapping")
        if f["role"] == "main":
            need(not f["class_body_ranges"] and not f["extension_ranges"], "main entry must have no ranges")
        else:
            need(f["class_body_ranges"] or f["extension_ranges"], "empty split file " + f["path"])
    edits = man["access_edits"]
    need(isinstance(edits, list), "access_edits")
    for e in edits:
        need(isinstance(e, dict) and set(e) == EDIT_KEYS, "edit keys: " + str(e))
        need(type(e["line"]) is int and isinstance(e["name"], str) and isinstance(e["member_kind"], str), "edit field types")
        need(e["delete"] in DELETIONS, "edit delete must be one access modifier")
        need(e["scope"] == "class-body" or (isinstance(e["scope"], dict) and set(e["scope"]) == {"extension"} and type(e["scope"]["extension"]) is int), "edit scope")
        r = e["reason"]
        need(isinstance(r, dict) and (
            (set(r) == {"type", "files"} and r["type"] == "cross-file" and isinstance(r["files"], list) and r["files"] and r["files"] == sorted(set(r["files"]))) or
            (set(r) == {"type", "seam"} and r["type"] == "test-seam" and isinstance(r["seam"], str))), "edit reason: " + str(r))
    keys = [(e["line"], e["name"]) for e in edits]
    need(keys == sorted(keys) and len(set(e["line"] for e in edits)) == len(edits), "access_edits unsorted, duplicated or two edits on one line")
    need(man["seam_files"] == SEAM_FILES, "seam_files differ from the six pinned seam fixtures")
    sites = man["setter_read_sites"]
    need(isinstance(sites, list) and all(isinstance(s, dict) and set(s) == {"name", "file", "line_text", "count"} for s in sites), "setter_read_sites keys")
    for s in sites:
        need(s["name"] in WIDENED_SETTERS and isinstance(s["file"], str) and isinstance(s["line_text"], str) and "\n" not in s["line_text"]
             and type(s["count"]) is int and s["count"] > 0 and s["file"] not in P.family(man["naming"]), "setter_read_sites entry " + str(s)[:120])
    k = [(s["name"], s["file"], s["line_text"]) for s in sites]
    need(k == sorted(k) and len(set(k)) == len(k), "setter_read_sites unsorted or duplicated")


# ----------------------------------------------------------------------------- construction
def resolve_edits(base, edits):
    """{base line: (byte column, deleted text, scope, member)} after validating each edit (check 6, purity part)."""
    by_scope = {}
    for scope, m in base.direct():
        by_scope.setdefault(scope, []).append(m)
    out = {}
    for e in edits:
        scope = e["scope"] if e["scope"] == "class-body" else e["scope"]["extension"]
        if scope not in by_scope:
            fail("6-scope", f"edit {e['name']}@{e['line']}: scope {scope} is not the class body or an existing extension header line")
        cands = [m for m in by_scope[scope] if m.name == e["name"]]
        hit = [m for m in cands if base.inv.modifier_at(m, e["line"], e["delete"]) is not None]
        if len(hit) != 1:
            other = [s for s, m in base.direct() if m.name == e["name"] and base.inv.modifier_at(m, e["line"], e["delete"]) is not None]
            why = f"wrong scope (the member belongs to {other[0]})" if other else "no direct member of that name declares that modifier on that line (nested-type member or wrong line/name)"
            fail("6-edit", f"edit {e['name']}@{e['line']} '{e['delete'].strip()}': {why}")
        m = hit[0]
        if member_kind(m) != e["member_kind"]:
            fail("6-edit", f"edit {e['name']}@{e['line']}: member_kind {e['member_kind']} != {member_kind(m)}")
        off = base.inv.modifier_at(m, e["line"], e["delete"])
        col = len(base.text[:off].encode("utf-8")) - base.line_start[e["line"] - 1]
        out[e["line"]] = (col, e["delete"], scope, m)
    return out


def edited_line(base, n, edits):
    raw = base.line(n)
    if n not in edits:
        return raw
    col, d, _, _ = edits[n]
    b = raw.encode("utf-8")
    if b[col:col + len(d)] != d.encode():
        fail("6-edit", f"line {n}: modifier bytes not at the recorded column")
    return (b[:col] + b[col + len(d):]).decode("utf-8")


def construct(base, man, edits=None):
    """Expected bytes of every family file, built from the base."""
    if edits is None:
        edits = resolve_edits(base, man["access_edits"])
    moved = set()
    out = {}
    for f in man["files"]:
        if f["role"] == "main":
            continue
        parts = [base.header]
        if f["class_body_ranges"]:
            parts.append(OPENER)
            for a, b in f["class_body_ranges"]:
                parts += [edited_line(base, n, edits) for n in range(a, b + 1)]
                moved.update(range(a, b + 1))
            parts.append(CLOSER)
        for a, b in f["extension_ranges"]:
            parts += [edited_line(base, n, edits) for n in range(a, b + 1)]
            moved.update(range(a, b + 1))
        out[f["path"]] = "".join(parts).encode("utf-8")
    out[P.MAIN] = "".join(edited_line(base, n, edits) for n in range(1, BASE_LINES + 1) if n not in moved).encode("utf-8")
    return out


def reassemble(base, man, files):
    """Check 5 (secondary): put every range back in base order and restore the deleted modifiers."""
    pieces = {}
    main_lines = files[P.MAIN].decode("utf-8").split("\n")[:-1]
    moved = []
    for f in man["files"]:
        if f["role"] == "main":
            continue
        lines = files[f["path"]].decode("utf-8").split("\n")[:-1]
        k = HEADER[1]
        if f["class_body_ranges"]:
            k += 1
            for a, b in f["class_body_ranges"]:
                for n in range(a, b + 1):
                    pieces[n] = lines[k]; k += 1
                moved.append((a, b))
            k += 1
        for a, b in f["extension_ranges"]:
            for n in range(a, b + 1):
                pieces[n] = lines[k]; k += 1
            moved.append((a, b))
        if k != len(lines):
            fail("5", f"{f['path']}: trailing bytes after the last range")
    mv = set(n for a, b in moved for n in range(a, b + 1))
    rest = [n for n in range(1, BASE_LINES + 1) if n not in mv]
    if len(rest) != len(main_lines):
        fail("5", "main file line count does not fit the partition")
    for n, ln in zip(rest, main_lines):
        pieces[n] = ln
    for e in man["access_edits"]:
        n = e["line"]
        orig = base.lines[n - 1]
        # restore: the deleted modifier must be re-insertable at exactly one position
        cand = pieces[n]
        ok = [i for i in range(len(cand) + 1) if cand[:i] + e["delete"] + cand[i:] == orig]
        if not ok:
            fail("5", f"line {n}: deleted modifier cannot be restored")
        pieces[n] = orig
    text = "".join(pieces[n] + "\n" for n in range(1, BASE_LINES + 1))
    if hashlib.sha256(text.encode("utf-8")).hexdigest() != BASE_SHA256:
        fail("5", "reassembled bytes do not hash to the pinned base")


# ----------------------------------------------------------------------------- structure checks
def check_partition_and_boundaries(base, man):
    cover = {}
    class_units = base.class_units()
    starts = {a: (a, b, m) for a, b, m in class_units}
    ends = {b for a, b, m in class_units}
    blocks = base.ext_blocks()
    for f in man["files"]:
        for kind in ("class_body_ranges", "extension_ranges"):
            for a, b in f[kind]:
                for n in range(a, b + 1):
                    if n in cover:
                        fail("1", f"line {n} assigned twice ({cover[n]} and {f['path']})")
                    cover[n] = f["path"]
                if kind == "class_body_ranges":
                    if not (base.inv.class_open_line < a and b < base.inv.class_close_line):
                        fail("2", f"class-body range {a}-{b} outside the class body")
                    if a not in starts or b not in ends:
                        fail("2", f"class-body range {a}-{b} does not start and end on member boundaries (partial member)")
                    for ua, ub, m in class_units:
                        if a <= ua <= b and base.retained(m):
                            fail("3", f"{member_kind(m)} {m.name} (line {m.start_line}) must stay in the main file")
                else:
                    # one or more whole existing extension blocks
                    covered = [blk for blk in blocks if a <= blk[0] and blk[1] <= b]
                    if not covered or covered[0][0] != a or covered[-1][1] != b or any(covered[i][1] + 1 != covered[i + 1][0] for i in range(len(covered) - 1)):
                        fail("2", f"extension range {a}-{b} is not a run of whole existing extension blocks")
    # class decl, brace, SpendLimitCommand and header stay; nothing outside class/extension bodies moves
    spend = [m for m in base.inv.top if m.name == "SpendLimitCommand"][0]
    for n in list(range(1, base.inv.class_open_line + 1)) + [base.inv.class_close_line] + list(range(spend.trivia_line, spend.end_line + 1)):
        if n in cover:
            fail("3", f"line {n} (header, class declaration, class brace or SpendLimitCommand) moved out of main")


def lex_file_decls(text):
    """(top-level declaration names, [direct member names of each `extension ConversationManager`])."""
    toks, _ = S.lex(text)
    names, ext_members, ext_count = [], [], 0
    depth = 0
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.kind == "punct" and t.text in "{([":
            depth += 1
        elif t.kind == "punct" and t.text in "})]":
            depth -= 1
        elif depth == 0 and t.kind == "id" and t.text in ("func", "var", "let", "struct", "enum", "class", "actor", "protocol", "typealias") and i + 1 < len(toks):
            names.append(toks[i + 1].text)
        elif depth == 0 and t.kind == "id" and t.text == "extension" and i + 1 < len(toks):
            if toks[i + 1].text == "ConversationManager":
                ext_count += 1
                j = i + 2
                while not (toks[j].kind == "punct" and toks[j].text == "{"):
                    j += 1
                close = S.find_close(toks, j)
                fake = text
                mem = S.members(fake, toks, None, j, close)
                ext_members += [m.name for m in mem]
                i = close + 1
                continue
        i += 1
    return names, ext_members, ext_count


def class_and_ext_member_names(text):
    """Multiset of direct member names of the class and all its extensions in one file."""
    toks, _ = S.lex(text)
    out = []
    depth = 0
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.kind == "punct" and t.text in "{([":
            depth += 1
        elif t.kind == "punct" and t.text in "})]":
            depth -= 1
        elif depth == 0 and t.kind == "id" and t.text in ("extension", "class") and i + 1 < len(toks) and toks[i + 1].text == "ConversationManager":
            j = i + 2
            while not (toks[j].kind == "punct" and toks[j].text == "{"):
                j += 1
            close = S.find_close(toks, j)
            out += [m.name for m in S.members(text, toks, None, j, close)]
            i = close + 1
            continue
        i += 1
    return out


def identifier_tokens(text):
    toks, _ = S.lex(text)
    return toks


# ----------------------------------------------------------------------------- setter census
SETTER_RE = None


def setter_census(files):
    """{(name, file, line_text): count} of identifier tokens (incl. `$name`, interpolations, key paths)."""
    out = {}
    for rel, text in files.items():
        if not rel.endswith(".swift"):
            continue
        toks = identifier_tokens(text)
        lines = text.split("\n")
        for t in toks:
            if t.kind == "id" and t.text.lstrip("$") in WIDENED_SETTERS:
                key = (t.text.lstrip("$"), rel, lines[t.line - 1])
                out[key] = out.get(key, 0) + 1
    return out


def census_sites(census):
    return [{"name": n, "file": f, "line_text": l, "count": c} for (n, f, l), c in sorted(census.items())]


WRITE_FORMS = [
    ("assignment", r"\b{n}\b\s*(?:\.[A-Za-z_]\w*\s*)*(?:\[[^\]]*\]\s*)*(?:&?[-+*/%|^]|\?\?|<<|>>)?=(?!=)"),
    ("inout", r"&\s*(?:[A-Za-z_]\w*\.)*{n}\b"),
    ("key path", r"\\(?:ConversationManager)?\.{n}\b"),
    ("projected", r"\${n}\b"),
    ("mutating call", r"\b{n}\s*\??\.\s*(?:append|insert|remove\w*|merge|sort|reverse|swapAt|formUnion|subtract|update\w*|popLast|removeAll|replaceSubrange)\s*\("),
]


def write_form(name, line):
    for label, pat in WRITE_FORMS:
        if re.search(pat.replace("{n}", re.escape(name)), line):
            return label
    return "read or unclassified"


# ----------------------------------------------------------------------------- the full check
class Candidate:
    """A candidate: {rel path: bytes} for every tracked file that matters, plus the manifest."""

    def __init__(self, files, manifest_bytes):
        self.files = files
        self.manifest_bytes = manifest_bytes


def module_swift(files):
    return {k: v for k, v in files.items() if k.startswith("TelegramConcierge/") and k.endswith(".swift")}


def run_checks(base, cand, reviewed, c1_files, changed_paths=None, seam_blobs=None):
    """All checks. `reviewed` = the fixed reference edit list (from C1); `c1_files` = {rel: bytes} of the
    pre-split tree (setter census baseline, seam blobs); `changed_paths` = git diff C1..C2 when known."""
    try:
        man = json.loads(cand.manifest_bytes)
    except Exception as e:  # noqa: BLE001
        fail("manifest", "unreadable manifest: " + str(e))
    validate_manifest(man)
    naming = man["naming"]
    fam = P.family(naming)
    # reviewed list is the authority (check 6, minimality/resolution part)
    if man["access_edits"] != reviewed:
        a = {json.dumps(e, sort_keys=True) for e in man["access_edits"]}
        b = {json.dumps(e, sort_keys=True) for e in reviewed}
        fail("6-reviewed", f"access_edits differ from the reviewed reference list (C1): +{sorted(a - b)[:2]} -{sorted(b - a)[:2]}")
    check_partition_and_boundaries(base, man)
    edits = resolve_edits(base, man["access_edits"])
    expected = construct(base, man, edits)
    # check 9 first part: exact file set in the module
    present_family = [p for p in (P.MAIN,) + P.ALL_SPLIT_PATHS if p in cand.files]
    if sorted(present_family) != sorted(fam):
        fail("9", f"family files present {sorted(set(present_family) ^ set(fam))} differ from the 15 paths of '{naming}'")
    # check 7: no conflicting declarations
    promoted = {e["name"] for e in man["access_edits"]}
    base_names = {}
    for nm in [m.name for _, m in base.direct()]:
        base_names[nm] = base_names.get(nm, 0) + 1
    fam_names = {}
    for p in fam:
        for nm in class_and_ext_member_names(cand.files[p].decode()):
            fam_names[nm] = fam_names.get(nm, 0) + 1
    for nm in promoted:
        if fam_names.get(nm, 0) != base_names.get(nm, 0):
            fail("7", f"{nm}: {fam_names.get(nm, 0)} declarations across the 15 files, base has {base_names.get(nm, 0)} (new overload)")
    for rel, data in module_swift(cand.files).items():
        if rel in fam:
            continue
        names, ext_members, ext_count = lex_file_decls(data.decode())
        hit = promoted & set(names)
        if hit:
            fail("7", f"{rel}: module-level declaration of promoted name(s) {sorted(hit)}")
        if ext_count:
            fail("7", f"{rel}: `extension ConversationManager` outside the 15 files and the pinned seams")
    for rel in SEAM_FILES:
        if rel not in cand.files:
            fail("7", f"pinned seam file missing: {rel}")
        names, ext_members, _ = lex_file_decls(cand.files[rel].decode())
        hit = promoted & (set(names) | set(ext_members))
        if hit:
            fail("7", f"{rel}: seam declares promoted name(s) {sorted(hit)}")
        if seam_blobs is not None and hashlib.sha1(b"blob %d\0" % len(cand.files[rel]) + cand.files[rel]).hexdigest() != seam_blobs[rel]:
            fail("7", f"{rel}: seam blob differs from the pinned C1 blob")
    # check 8: setter census (supplementary to check 9)
    outside = {k: v.decode("utf-8", "replace") for k, v in cand.files.items() if k.endswith(".swift") and k not in fam
               and (k.startswith("TelegramConcierge/") or k.startswith("scripts/fixtures/"))}
    c1_outside = {k: v.decode("utf-8", "replace") for k, v in c1_files.items() if k.endswith(".swift") and k not in P.family(naming) and k != P.MAIN
                  and (k.startswith("TelegramConcierge/") or k.startswith("scripts/fixtures/"))}
    baseline = census_sites(setter_census(c1_outside))
    if man["setter_read_sites"] != baseline:
        a = {json.dumps(s, sort_keys=True) for s in man["setter_read_sites"]}
        b = {json.dumps(s, sort_keys=True) for s in baseline}
        fail("8", f"manifest setter_read_sites differ from the census derived from C1: +{sorted(a - b)[:1]} -{sorted(b - a)[:1]}")
    now = census_sites(setter_census(outside))
    if now != baseline:
        a = {json.dumps(s, sort_keys=True): s for s in now}
        b = {json.dumps(s, sort_keys=True): s for s in baseline}
        new = [a[k] for k in a if k not in b]
        gone = [b[k] for k in b if k not in a]
        detail = "; ".join(f"{s['file']}: {write_form(s['name'], s['line_text'])} of {s['name']}: {s['line_text'].strip()[:90]!r}" for s in new[:3])
        fail("8", f"widened-setter occurrence changed outside the 15 files: new [{detail}] removed {len(gone)}")
    # check 4: exact construction
    for path in fam:
        got = cand.files[path]
        if got != expected[path]:
            gl, el = got.decode("utf-8", "replace").split("\n"), expected[path].decode("utf-8", "replace").split("\n")
            k = next((i for i, (x, y) in enumerate(zip(gl, el)) if x != y), min(len(gl), len(el)))
            fail("4", f"{path} differs from the base-derived bytes at line {k + 1}: got {gl[k] if k < len(gl) else '<EOF>'!r} expected {el[k] if k < len(el) else '<EOF>'!r}")
    reassemble(base, man, cand.files)
    # check 6: textual evidence for every reason
    tokens = {p: {t.text.lstrip("$") for t in identifier_tokens(cand.files[p].decode()) if t.kind == "id"} for p in fam}
    seam_tokens = {p: {t.text.lstrip("$") for t in identifier_tokens(cand.files[p].decode()) if t.kind == "id"} for p in SEAM_FILES if p in cand.files}
    line_home = {}
    for f in man["files"]:
        for key in ("class_body_ranges", "extension_ranges"):
            for a, b in f[key]:
                for n in range(a, b + 1):
                    line_home[n] = f["path"]
    for e in man["access_edits"]:
        home = line_home.get(e["line"], P.MAIN)
        r = e["reason"]
        if r["type"] == "cross-file":
            if home in r["files"] or any(f not in fam for f in r["files"]):
                fail("6-reason", f"{e['name']}: reason files must be other family files than the declaring {home}")
            for f in r["files"]:
                if e["name"] not in tokens[f]:
                    fail("6-reason", f"{e['name']}: no identifier reference in {f}")
        else:
            if r["seam"] not in SEAM_FILES or e["name"] not in seam_tokens.get(r["seam"], set()):
                fail("6-reason", f"{e['name']}: test-seam reason without a reference in a pinned seam file")
            if home == P.MAIN:
                fail("6-reason", f"{e['name']}: a seam-only promotion must be of a member that left the main file")
    # check 9 second part: nothing else changed
    if changed_paths is not None:
        allowed = set(fam) | {MANIFEST_REL}
        if set(changed_paths) != allowed:
            fail("9", f"C1..C2 changes must be exactly the 15 Swift paths plus the manifest; extra {sorted(set(changed_paths) - allowed)} missing {sorted(allowed - set(changed_paths))}")
    for rel in module_swift(cand.files):
        if rel not in fam and (rel in P.ALL_SPLIT_PATHS or re.search(r"ConversationManager", Path(rel).name)):
            fail("9", f"extra ConversationManager-named file {rel}")
    return man


# ----------------------------------------------------------------------------- loaders
def tree_files(tree, tracked_from=None):
    """{rel: bytes} for TelegramConcierge/**, scripts/fixtures/** and the manifest in a working tree."""
    tree = Path(tree)
    out = {}
    for top in ("TelegramConcierge", "scripts/fixtures"):
        for p in (tree / top).rglob("*"):
            if p.is_file() and ".build" not in p.parts:
                out[str(p.relative_to(tree))] = p.read_bytes()
    return out


def commit_files(commit, cwd=ROOT):
    out = {}
    for rel in git_tree_files(commit, cwd):
        if rel.startswith("TelegramConcierge/") or rel.startswith("scripts/fixtures/"):
            out[rel] = git_blob(commit, rel, cwd)
    return out


def reviewed_from(commit):
    return json.loads(git_blob(commit, REVIEWED_REL))["access_edits"]


def seam_blobs_of(commit):
    out = {}
    for rel in SEAM_FILES:
        out[rel] = git("rev-parse", f"{commit}:{rel}").strip()
    return out


def check_unsplit(files):
    for rel in P.ALL_SPLIT_PATHS:
        if rel in files:
            fail("10", f"--unsplit refused: split file {rel} exists")
    if MANIFEST_REL in files:
        fail("10", "--unsplit refused: a split manifest exists")
    if hashlib.sha256(files[P.MAIN]).hexdigest() != BASE_SHA256:
        fail("10", "--unsplit: ConversationManager.swift differs from the pinned base")


# ----------------------------------------------------------------------------- self-test
def materialize(base, man):
    return construct(base, man)


def selftest(base, c1=None, c2=None):
    from cm_split_selftest import run_selftest
    return run_selftest(sys.modules[__name__], base, c1, c2)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--unsplit", action="store_true")
    ap.add_argument("--tree", type=Path)
    ap.add_argument("--c1")
    ap.add_argument("--verify-commit", dest="c2")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--materialize", type=Path)
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()
    base = Base.load()
    try:
        if args.materialize:
            man = json.loads(args.materialize.read_text())
            validate_manifest(man)
            for path, data in construct(base, man).items():
                dest = args.out / path
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
            print(f"materialized {len(man['files'])} files under {args.out}")
            return 0
        if args.selftest:
            return selftest(base, args.c1, args.c2)
        if args.unsplit:
            check_unsplit(tree_files(args.tree or ROOT))
            print("cm_split_check --unsplit: PASS (no manifest, no split file, main == pinned base)")
            return 0
        if not args.c1:
            ap.error("--c1 is required")
        c1 = git("rev-parse", "--verify", args.c1 + "^{commit}").strip()
        c1_files = commit_files(c1)
        check_unsplit(c1_files)  # C1 itself must be the unsplit pinned base
        reviewed = reviewed_from(c1)
        if args.c2:
            c2 = git("rev-parse", "--verify", args.c2 + "^{commit}").strip()
            parents = git("rev-list", "--parents", "-n", "1", c2).split()
            if parents[1:] != [c1]:
                fail("9", f"C2 {c2[:12]} must have exactly one parent, C1 {c1[:12]}")
            files = commit_files(c2)
            changed = [p for p in git("diff", "--no-renames", "--name-only", c1, c2).split("\n") if p]
        else:
            files = tree_files(args.tree or ROOT)
            changed = None
        if MANIFEST_REL not in files:
            fail("manifest", "no manifest in the candidate")
        cand = Candidate(files, files[MANIFEST_REL])
        man = run_checks(base, cand, reviewed, c1_files, changed, seam_blobs_of(c1))
        moved = sum(b - a + 1 for f in man["files"] for k in ("class_body_ranges", "extension_ranges") for a, b in f[k])
        print(f"cm_split_check: PASS — {len(man['files'])} files ({man['naming']}), {moved} lines moved, "
              f"{len(man['access_edits'])} reviewed access edits, base {BASE_SHA256[:12]} reassembled")
        if args.c2:
            return selftest(base, c1, c2)
        return 0
    except CheckFailure as e:
        print(f"cm_split_check: FAIL {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
