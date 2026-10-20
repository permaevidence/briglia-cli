#!/usr/bin/env python3
"""Structural OFF-identity gate for opt-in background pruning.

BACKGROUND_PRUNE_PLAN v4.1 §15.2-§15.3. A fail-closed regression check
(complemented by the behavioural O-group tests), not a proof of
noninterference:

  A. Every baseline file under TelegramConcierge/ plus Package.swift and
     Package.resolved is listed in an embedded manifest with its SHA-256.
     Every listed file must exist and be byte-identical, except the three
     allow-listed files. A file not in the manifest may exist only under
     Services/BackgroundPrune*.swift or CLI/BackgroundPruneSelftest*.swift.
  B. In the allow-listed files every change sits in a marked region
     (`// BGPRUNE{ <anchor-id>` ... `// }BGPRUNE`). Stripping the regions
     must reproduce the baseline bytes exactly.
  C. Every region sits at its pinned anchor (§15.3), passes the context
     validation (C2) and matches exactly the template its anchor names.
  D. New files follow the restricted grammar; reserved name prefixes are
     absent from the baseline.
  E. Validation reads only the manifest (never Git). `--verify-manifest`
     regenerates the manifest from a baseline tree and requires equality.

Usage:
  bg_prune_off_identity_test.py [--root DIR]            validate (exit 1 on any finding)
  bg_prune_off_identity_test.py --write-manifest BASE   regenerate the manifest from a baseline tree
  bg_prune_off_identity_test.py --verify-manifest BASE  regenerate and require byte equality
"""
import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST_NAME = "bg_prune_baseline_manifest.json"
# SHA-256 of the committed manifest bytes. Changing the manifest without
# changing this constant (or vice versa) fails the gate.
MANIFEST_SHA256 = "918efa5a459a01c154188371a0473d1c28566a7d36ded5a0e8578eceed9e9cc4"
BASELINE_COMMIT = "26f8c2c4b411ca1da8238daf934b09366da0b412"

CM = "TelegramConcierge/Services/ConversationManager.swift"
REG = "TelegramConcierge/Services/ChatCommandRegistry.swift"
MAIN = "TelegramConcierge/CLI/AdaMain.swift"
ALLOW_LISTED = (CM, REG, MAIN)
NEW_FILE_PATTERNS = (
    re.compile(r"^TelegramConcierge/Services/BackgroundPrune[A-Za-z0-9+_-]*\.swift$"),
    re.compile(r"^TelegramConcierge/CLI/BackgroundPruneSelftest[A-Za-z0-9+_-]*\.swift$"),
)
SELFTEST_PATTERN = re.compile(r"^TelegramConcierge/CLI/BackgroundPruneSelftest[A-Za-z0-9+_-]*\.swift$")
PREFIX_RE = re.compile(r"\b(backgroundPrune|bgPrune|BackgroundPrune)")

# §15.3: the closed anchor table. `after` = inserted between baseline lines
# k and k+1; `range` = a T-SPLIT's wrapped baseline lines [a, b].
ANCHORS = [
    {"id": "A-STORE", "file": CM, "template": "T-STORE", "context": "member", "after": 120},
    {"id": "A-CASE", "file": CM, "template": "T-CASE", "context": "case-list", "after": 118},
    {"id": "A-ARM", "file": CM, "template": "T-ARM", "context": "switch-arm", "after": 7485},
    {"id": "A-CMD", "file": CM, "template": "T-CMD", "context": "switch-arm", "after": 4398},
    {"id": "A-RST", "file": CM, "template": "T-SIDE", "context": "statement", "after": 5437},
    {"id": "A-UPG", "file": CM, "template": "T-SIDE", "context": "statement", "after": 5486},
    {"id": "A-STATUS", "file": CM, "template": "T-SIDE", "context": "statement", "after": 6637},
    {"id": "A-PRUNE", "file": CM, "template": "T-SIDE", "context": "statement", "after": 6833},
    {"id": "A-STOP1", "file": CM, "template": "T-SIDE", "context": "statement", "after": 7302},
    {"id": "A-STOP2", "file": CM, "template": "T-SIDE", "context": "statement", "after": 7340},
    {"id": "A-T0", "file": CM, "template": "T-SIDE", "context": "statement", "after": 8239},
    {"id": "A-T1", "file": CM, "template": "T-SPLIT", "context": "statement", "range": [8452, 8471]},
    {"id": "A-D1", "file": CM, "template": "T-SIDE", "context": "statement", "after": 8615},
    {"id": "A-SEND", "file": CM, "template": "T-SPLIT", "context": "statement", "range": [8639, 8695]},
    {"id": "A-M", "file": CM, "template": "T-SPLIT", "context": "statement", "range": [9033, 9071]},
    {"id": "A-FF1", "file": CM, "template": "T-LOCAL", "context": "statement", "after": 9146},
    {"id": "A-FF2", "file": CM, "template": "T-SIDE", "context": "statement", "after": 9146},
    {"id": "A-FFD", "file": CM, "template": "T-SIDE", "context": "statement", "after": 9156},
    {"id": "A-FFSEND", "file": CM, "template": "T-SPLIT", "context": "statement", "range": [9158, 9212]},
    {"id": "A-GEN1", "file": CM, "template": "T-SIDE", "context": "statement", "after": 13293},
    {"id": "A-GEN2", "file": CM, "template": "T-SIDE", "context": "statement", "after": 13856},
    {"id": "A-ARCR", "file": CM, "template": "T-SIDE", "context": "statement", "after": 14104},
    {"id": "A-ARCC", "file": CM, "template": "T-SIDE", "context": "statement", "after": 14244},
    {"id": "A-EXT", "file": CM, "template": "T-EXT", "context": "file-top", "after": 15580},
    {"id": "A-REG", "file": REG, "template": "T-REG", "context": "element", "after": 51},
    {"id": "A-SUB", "file": MAIN, "template": "T-SUB", "context": "element", "after": 33},
]
# Regions sharing an insertion point appear in this order.
SAME_POINT_ORDER = ["A-FF1", "A-FF2"]


class GateError(Exception):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def line_sha(text):
    return sha(text.encode("utf-8"))


# ----------------------------------------------------------------- lexer

KEYWORDS = {
    "if", "else", "guard", "for", "while", "repeat", "do", "catch", "switch", "case", "default",
    "func", "init", "deinit", "subscript", "var", "let", "return", "throw", "try", "await",
    "in", "where", "as", "is", "defer", "fallthrough", "break", "continue", "class", "struct",
    "enum", "extension", "protocol", "actor", "import", "typealias", "static", "private",
    "fileprivate", "internal", "public", "open", "get", "set", "willSet", "didSet",
}
OP_CHARS = set("/=-+!*%<>&|^~?.")
PUNCT = set("{}()[],:;")


class Tok:
    __slots__ = ("kind", "text", "line", "end_line")

    def __init__(self, kind, text, line, end_line=None):
        self.kind = kind          # word, num, str, op, punct, comment, directive, attr
        self.text = text
        self.line = line
        self.end_line = end_line if end_line is not None else line

    def __repr__(self):
        return f"Tok({self.kind},{self.text!r},{self.line})"


def lex(src, base_line=1):
    """Tokenises Swift source. Fails closed (GateError) on anything it
    cannot classify: an unterminated literal or comment, an unknown
    delimiter form, a regex literal."""
    toks = []
    i = 0
    n = len(src)
    line = base_line

    def string_at(i, line):
        # returns (end_index, end_line)
        j = i
        hashes = 0
        while j < n and src[j] == "#":
            hashes += 1
            j += 1
        if j >= n or src[j] != '"':
            raise GateError(f"lexer: unknown delimiter form at line {line}")
        multi = src.startswith('"""', j)
        j += 3 if multi else 1
        close = ('"""' if multi else '"') + "#" * hashes
        esc = "\\" + "#" * hashes
        cur = line
        while True:
            if j >= n:
                raise GateError(f"lexer: unterminated string literal starting at line {line}")
            if src.startswith(close, j):
                return j + len(close), cur
            c = src[j]
            if c == "\n":
                if not multi:
                    raise GateError(f"lexer: unterminated string literal at line {cur}")
                cur += 1
                j += 1
                continue
            if src.startswith(esc, j):
                k = j + len(esc)
                if k < n and src[k] == "(":
                    # interpolation: lex nested code to the matching ')'
                    depth = 0
                    m = k
                    while True:
                        if m >= n:
                            raise GateError(f"lexer: unterminated interpolation at line {cur}")
                        ch = src[m]
                        if ch == "(":
                            depth += 1
                            m += 1
                        elif ch == ")":
                            depth -= 1
                            m += 1
                            if depth == 0:
                                break
                        elif ch == '"' or (ch == "#" and m + 1 < n and src[m + 1] in '#"'):
                            m, cur = string_at(m, cur)
                        elif ch == "\n":
                            cur += 1
                            m += 1
                        else:
                            m += 1
                    j = m
                    continue
                if k < n and src[k] == "\n":
                    cur += 1  # line continuation inside a multi-line string
                j = k + 1  # escaped character
                continue
            j += 1

    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r":
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            toks.append(Tok("comment", src[i:j], line))
            i = j
            continue
        if src.startswith("/*", i):
            depth = 0
            j = i
            start = line
            while True:
                if j >= n:
                    raise GateError(f"lexer: unterminated block comment at line {start}")
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    if src[j] == "\n":
                        line += 1
                    j += 1
            toks.append(Tok("comment", src[i:j], start, line))
            i = j
            continue
        if c == '"' or (c == "#" and i + 1 < n and src[i + 1] in '#"'):
            # raw strings start with #...#" ; '##' followed by non-quote fails inside
            start = line
            j, line = string_at(i, line)
            toks.append(Tok("str", src[i:j], start, line))
            i = j
            continue
        if c == "#":
            if i + 1 < n and src[i + 1] == "/":
                raise GateError(f"lexer: regex literal at line {line}")
            m = re.match(r"#[A-Za-z_][A-Za-z0-9_]*", src[i:])
            if not m:
                raise GateError(f"lexer: unknown '#' form at line {line}")
            toks.append(Tok("directive", m.group(0), line))
            i += len(m.group(0))
            continue
        if c == "@":
            m = re.match(r"@[A-Za-z_][A-Za-z0-9_]*", src[i:])
            if not m:
                raise GateError(f"lexer: unknown '@' form at line {line}")
            toks.append(Tok("attr", m.group(0), line))
            i += len(m.group(0))
            continue
        if c == "`":
            j = src.find("`", i + 1)
            if j < 0 or "\n" in src[i:j]:
                raise GateError(f"lexer: unterminated backtick identifier at line {line}")
            toks.append(Tok("word", src[i + 1:j], line))
            i = j + 1
            continue
        if c.isalpha() or c == "_" or c == "$":
            m = re.match(r"[A-Za-z_$][A-Za-z0-9_$]*", src[i:])
            toks.append(Tok("word", m.group(0), line))
            i += len(m.group(0))
            continue
        if c.isdigit():
            m = re.match(r"0x[0-9A-Fa-f_]+|0b[01_]+|0o[0-7_]+|[0-9][0-9_]*(\.[0-9][0-9_]*)?([eE][+-]?[0-9]+)?", src[i:])
            toks.append(Tok("num", m.group(0), line))
            i += len(m.group(0))
            continue
        if c in PUNCT:
            toks.append(Tok("punct", c, line))
            i += 1
            continue
        if c in OP_CHARS:
            j = i
            while j < n and src[j] in OP_CHARS and not src.startswith("//", j) and not src.startswith("/*", j):
                j += 1
            toks.append(Tok("op", src[i:j], line))
            i = j
            continue
        if c == "\\":
            # key-path expression
            toks.append(Tok("op", "\\", line))
            i += 1
            continue
        raise GateError(f"lexer: unclassifiable character {c!r} at line {line}")
    return toks


def code(toks):
    return [t for t in toks if t.kind != "comment"]


# ------------------------------------------------- structure (baseline view)

TYPE_KW = {"class", "struct", "enum", "extension", "protocol", "actor"}
FUNC_KW = {"func", "init", "deinit", "subscript"}
ACCESSOR_KW = {"get", "set", "willSet", "didSet"}
CONTROL_KW = {"if", "guard", "while", "for", "catch", "switch"}
CONTROL_PREV = {"else", "do", "repeat", "defer"}


def classify_brace(ctoks, idx):
    """Class of the `{` at ctoks[idx]: function, accessor, control, switch,
    type:<kw>:<name>, closure. Heuristic, fail-closed by construction (an
    unknown header is a closure, which no statement context accepts)."""
    prev = ctoks[idx - 1] if idx > 0 else None
    if prev is None:
        return "closure"
    if prev.kind == "word" and prev.text in CONTROL_PREV:
        return "control"
    if prev.kind == "word" and prev.text in ACCESSOR_KW:
        return "accessor"
    if prev.kind == "word" and prev.text == "in":
        return "closure"
    if (prev.kind == "op" and prev.text not in ("?", "!")) or (prev.kind == "punct" and prev.text in "(,[:=") or (prev.kind == "word" and prev.text in ("return", "try", "await")):
        return "closure"
    j = idx - 1
    depth = 0
    while j >= 0:
        t = ctoks[j]
        if t.kind == "punct" and t.text in ")]":
            depth += 1
        elif t.kind == "punct" and t.text in "([":
            if depth == 0:
                return "closure"
            depth -= 1
        elif depth == 0:
            if t.kind == "punct" and t.text in "{};":
                return "closure"
            if t.kind == "word":
                if t.text in FUNC_KW:
                    return "function"
                if t.text in TYPE_KW:
                    name = ctoks[j + 1].text if j + 1 < len(ctoks) else ""
                    return f"type:{t.text}:{name}"
                if t.text == "switch":
                    return "switch"
                if t.text in CONTROL_KW:
                    return "control"
                if t.text == "var":
                    return "accessor"
        j -= 1
    return "closure"


def structure(ctoks):
    """For every code token index: the open-delimiter stack before it, as a
    list of (char, class, tokindex)."""
    stack = []
    stacks = []
    for idx, t in enumerate(ctoks):
        stacks.append(list(stack))
        if t.kind == "punct":
            if t.text == "{":
                stack.append(("{", classify_brace(ctoks, idx), idx))
            elif t.text in "([":
                stack.append((t.text, None, idx))
            elif t.text in "})]":
                want = {"}": "{", ")": "(", "]": "["}[t.text]
                if not stack or stack[-1][0] != want:
                    raise GateError(f"unbalanced '{t.text}' at line {t.line}")
                stack.pop()
    stacks.append(list(stack))
    if stack:
        raise GateError("unbalanced delimiters at end of file")
    return stacks


FORBIDDEN_PREV_WORDS = {"else", "do", "try", "await", "return", "throw", "guard", "case", "in",
                        "if", "while", "for", "switch", "catch", "let", "var", "where", "as", "is"}
FORBIDDEN_NEXT_WORDS = {"else", "catch", "where", "as", "is", "in"}


def ends_statement(t):
    if t is None:
        return False
    if t.kind == "punct":
        return t.text in "{};)]"
    if t.kind in ("str", "num"):
        return True
    if t.kind == "word":
        return t.text not in FORBIDDEN_PREV_WORDS
    if t.kind == "op":
        return t.text in ("?", "!")
    return False


def next_allowed(t):
    if t is None:
        return True
    if t.kind == "word":
        return t.text not in FORBIDDEN_NEXT_WORDS
    if t.kind == "punct":
        return t.text in "}"
    if t.kind == "op":
        return False
    return True


class Baseline:
    def __init__(self, text):
        self.text = text
        self.lines = text.split("\n")
        self.toks = lex(text)
        self.ctoks = code(self.toks)
        self.stacks = structure(self.ctoks)

    def prev_index(self, k):
        """Index of the last code token ending on a line <= k (or -1)."""
        best = -1
        for idx, t in enumerate(self.ctoks):
            if t.end_line <= k:
                best = idx
            else:
                break
        return best

    def next_index(self, k):
        for idx, t in enumerate(self.ctoks):
            if t.line >= k + 1:
                # a multi-line token straddling the boundary is not a boundary
                return idx
        return len(self.ctoks)

    def straddles(self, k):
        return any(t.line <= k < t.end_line for t in self.toks)


def context_errors(b, k, ctx, anchor):
    """C2 context validation at the point between baseline lines k and k+1."""
    errs = []
    if b.straddles(k):
        return [f"{anchor}: insertion point inside a multi-line literal or comment"]
    p = b.prev_index(k)
    nx = b.next_index(k)
    prev = b.ctoks[p] if p >= 0 else None
    nxt = b.ctoks[nx] if nx < len(b.ctoks) else None
    stack = b.stacks[nx] if nx <= len(b.ctoks) else []
    inner = stack[-1] if stack else None
    if ctx == "statement":
        if not inner or inner[0] != "{" or inner[1] not in ("function", "accessor", "control", "switch"):
            errs.append(f"{anchor}: context: innermost delimiter is not a statement body ({inner[1] if inner else 'top level'})")
        if not ends_statement(prev):
            errs.append(f"{anchor}: context: previous baseline token {prev.text if prev else None!r} does not end a statement")
        if not next_allowed(nxt):
            errs.append(f"{anchor}: context: next baseline token {nxt.text!r} continues the previous statement (else/catch/continuation)")
    elif ctx == "member":
        if not inner or inner[0] != "{" or inner[1] != "type:class:ConversationManager":
            errs.append(f"{anchor}: context: not in the ConversationManager class body")
        if not ends_statement(prev):
            errs.append(f"{anchor}: context: previous token does not close a declaration")
        if nxt is not None and not (nxt.kind in ("word", "attr") or (nxt.kind == "punct" and nxt.text == "}")):
            errs.append(f"{anchor}: context: next token does not start a declaration")
    elif ctx == "case-list":
        if not inner or inner[1] != "type:enum:RunPhase":
            errs.append(f"{anchor}: context: not in enum RunPhase")
        if b.lines[k - 1].strip() != "case archiveWait(Date)":
            errs.append(f"{anchor}: context: not after case archiveWait(Date)")
    elif ctx == "switch-arm":
        if not inner or inner[1] != "switch":
            errs.append(f"{anchor}: context: innermost delimiter is not a switch")
        if nxt is None or nxt.kind != "word" or nxt.text not in ("case", "default"):
            errs.append(f"{anchor}: context: next token is not case/default")
        if not (prev is not None and ((prev.kind == "punct" and prev.text == "{") or ends_statement(prev))):
            errs.append(f"{anchor}: context: previous arm not complete")
    elif ctx == "element":
        if not inner or inner[0] != "[":
            errs.append(f"{anchor}: context: not inside an array literal")
        if prev is None or prev.text != ",":
            errs.append(f"{anchor}: context: previous token is not ','")
        if nxt is None or nxt.kind != "word":
            errs.append(f"{anchor}: context: next token does not start an element")
    elif ctx == "file-top":
        if stack:
            errs.append(f"{anchor}: context: not at file top level")
    else:
        errs.append(f"{anchor}: unknown context class {ctx}")
    return errs


def split_range_errors(b, a, z, anchor):
    """T-SPLIT wrapped baseline range [a, z] (C2)."""
    errs = []
    errs += context_errors(b, a - 1, "statement", anchor + "/start")
    errs += context_errors(b, z, "statement", anchor + "/end")
    first = b.next_index(a - 1)
    last = b.prev_index(z)
    if first > last:
        return errs + [f"{anchor}: empty wrapped range"]
    start_stack = b.stacks[first]
    end_stack = b.stacks[last + 1]
    if len(start_stack) != len(end_stack):
        errs.append(f"{anchor}: wrapped range does not return to its starting depth")
    base = len(start_stack)
    names = set()
    for idx in range(first, last + 1):
        st = b.stacks[idx]
        if len(st) < base:
            errs.append(f"{anchor}: wrapped range leaves its enclosing block")
            break
        if len(st) > base and any(s[0] in "([" for s in st[base:]) and idx == first:
            errs.append(f"{anchor}: wrapped range starts inside an argument list")
        t = b.ctoks[idx]
        if len(st) == base and t.kind == "word":
            if t.text in ("defer", "guard", "fallthrough"):
                errs.append(f"{anchor}: wrapped range contains '{t.text}' at its own depth")
            if t.text in ("let", "var"):
                j = idx + 1
                if j <= last and b.ctoks[j].kind == "word":
                    names.add(b.ctoks[j].text)
                elif j <= last and b.ctoks[j].text == "(":
                    d = 0
                    while j <= last:
                        tt = b.ctoks[j]
                        if tt.text == "(":
                            d += 1
                        elif tt.text == ")":
                            d -= 1
                            if d == 0:
                                break
                        elif tt.kind == "word" and tt.text != "_":
                            names.add(tt.text)
                        j += 1
            nxt = b.ctoks[idx + 1] if idx + 1 < len(b.ctoks) else None
            if nxt is not None and nxt.text == ":" and idx + 2 < len(b.ctoks) and \
               b.ctoks[idx + 2].text in ("for", "while", "repeat", "do", "switch", "if"):
                errs.append(f"{anchor}: wrapped range contains a label")
    # binding escape: no wrapped depth-0 name after the range up to the
    # enclosing block's closing brace
    j = last + 1
    while j < len(b.ctoks) and len(b.stacks[j]) >= base:
        t = b.ctoks[j]
        if len(b.stacks[j]) == base and t.kind == "punct" and t.text == "}":
            break
        if t.kind == "word" and t.text in names:
            errs.append(f"{anchor}: binding '{t.text}' escapes the wrapped range (used at line {t.line})")
            break
        j += 1
    return errs


# ------------------------------------------------------------- templates

CLOSED_TYPES = {"Bool": {"false"}, "Int": {"0"}, "UInt64": {"0"}, "Double": {"0"}, "[String: Int]": {"[:]"}}
OPTIONAL_BASES = {"Bool", "Int", "UUID", "Date"}


def literal_ok(typ, lit, new_types):
    typ = typ.strip()
    lit = lit.strip()
    if typ in CLOSED_TYPES:
        return lit in CLOSED_TYPES[typ]
    if typ.endswith("?") and lit == "nil":
        base = typ[:-1]
        return base in OPTIONAL_BASES or (re.fullmatch(r"BackgroundPrune[A-Za-z0-9]*", base) is not None and base in new_types)
    return False


def code_lines(text):
    out = []
    for raw in text.split("\n"):
        s = raw.strip()
        if not s or s.startswith("//"):
            continue
        out.append(s)
    return out


def depth_profile(ctoks):
    """Relative brace depth after each code token."""
    d = 0
    prof = []
    for t in ctoks:
        if t.kind == "punct" and t.text == "{":
            d += 1
        elif t.kind == "punct" and t.text == "}":
            d -= 1
        prof.append(d)
    return prof


FORBIDDEN_IN_REGION_DIRECTIVES = ("#if", "#elseif", "#else", "#endif", "#sourceLocation")
# Codex impl round 4, R4-1: closed attribute vocabularies (allowlists,
# checked at every nesting depth). Anything else — every underscored
# attribute (@_silgen_name, @_cdecl, @_dynamicReplacement, @_exported,
# @_implementationOnly, @_transparent …), @main, @objc, @inline,
# @usableFromInline, @available, @dynamicCallable, @propertyWrapper,
# @resultBuilder, @globalActor, attached macros — is rejected.
REGION_ATTRIBUTES = frozenset({"@MainActor", "@Sendable", "@escaping"})
NEW_FILE_ATTRIBUTES = frozenset({"@MainActor", "@Sendable", "@escaping", "@autoclosure",
                                 "@discardableResult", "@unchecked"})
SELFTEST_ATTRIBUTES = frozenset({"@Flag", "@Option"})


def common_region_errors(text, ctoks, anchor, allow_extension=False):
    errs = []
    for t in ctoks:
        if t.kind == "directive" and t.text in FORBIDDEN_IN_REGION_DIRECTIVES:
            errs.append(f"{anchor}: '{t.text}' inside a region")
        if t.kind == "attr" and t.text not in REGION_ATTRIBUTES:
            errs.append(f"{anchor}: attribute {t.text} inside a region (not on the attribute allowlist)")
        if t.kind == "word" and t.text in ("operator", "precedencegroup", "import"):
            errs.append(f"{anchor}: '{t.text}' inside a region")
        if t.kind == "word" and t.text == "extension" and not allow_extension:
            errs.append(f"{anchor}: 'extension' inside a region")
    return errs


def check_side(text, ctoks, anchor, split_open=False):
    errs = []
    lines = code_lines(text)
    if not lines or lines[0] != "if backgroundPruneEngaged {":
        return [f"{anchor}: first code line must be 'if backgroundPruneEngaged {{'"]
    want_last = "} else {" if split_open else "}"
    if lines[-1] != want_last:
        return [f"{anchor}: last code line must be '{want_last}'"]
    prof = depth_profile(ctoks)
    if split_open:
        # the last line is `} else {`: its `}` closes to 0, `else {` reopens
        if len(ctoks) < 3 or [t.text for t in ctoks[-3:]] != ["}", "else", "{"]:
            return [f"{anchor}: malformed split opening"]
        body = prof[2:-3]
        if any(d < 1 for d in body):
            errs.append(f"{anchor}: brace depth reaches 0 before the region's last line")
        if prof[-3] != 0 or prof[-1] != 1:
            errs.append(f"{anchor}: split opening does not end in an open else")
    else:
        if any(d < 1 for d in prof[2:-1]) or prof[-1] != 0:
            errs.append(f"{anchor}: brace depth reaches 0 before the region's last line")
        if any(t.kind == "word" and t.text == "else" and prof[i - 1] == 0 for i, t in enumerate(ctoks) if i > 0):
            errs.append(f"{anchor}: 'else' at the region's top level")
    return errs


EXT_HEADER_RES = [
    re.compile(r"^(private |fileprivate )?func (backgroundPrune|bgPrune)[A-Za-z0-9]*\b"),
    re.compile(r"^(private )?var (backgroundPrune|bgPrune)[A-Za-z0-9]*: [^=]+ \{$"),
    re.compile(r"^nonisolated\(unsafe\) static var bgPrune[A-Za-z0-9]*ForTesting: .+\? = nil$"),
]
DECL_START = {"func", "var", "let", "init", "deinit", "subscript", "typealias", "struct", "class", "enum", "actor",
              "protocol", "extension", "static", "private", "fileprivate", "internal", "public", "open",
              "nonisolated", "override", "convenience", "required", "lazy", "mutating", "final", "case",
              "operator", "precedencegroup", "associatedtype", "dynamic", "weak", "unowned"}


def check_ext(text, ctoks, anchor):
    errs = []
    lines = [l for l in text.split("\n")]
    cl = code_lines(text)
    if not cl or cl[0] != "extension ConversationManager {" or cl[-1] != "}":
        return [f"{anchor}: T-EXT must be exactly one 'extension ConversationManager {{ ... }}'"]
    errs += common_region_errors(text, ctoks[1:], anchor)
    d = 0
    pd = 0
    seen_lines = set()
    first_on_line = set()
    validated_lines = set()
    for i, t in enumerate(ctoks):
        is_first = t.line not in first_on_line
        first_on_line.add(t.line)
        # Every declaration is validated, not one header per physical line
        # (Codex impl R3b): no ';' at member level and no declaration that
        # follows a closed member on the same line.
        if i > 0 and d == 1 and pd == 0:
            prev = ctoks[i - 1]
            if t.kind == "punct" and t.text == ";":
                errs.append(f"{anchor}: ';' at member level (line {t.line})")
            if (t.kind == "attr" or (t.kind == "word" and t.text in DECL_START)) and prev.line == t.line \
               and prev.kind == "punct" and prev.text in "};":
                errs.append(f"{anchor}: second declaration on one line (line {t.line})")
        if not is_first:
            if i > 0 and d == 1 and pd == 0 and (t.kind == "attr" or (t.kind == "word" and t.text in DECL_START)) \
               and t.line not in validated_lines:
                errs.append(f"{anchor}: declaration keyword {t.text!r} mid-line at member level (line {t.line})")
            seen_lines.add(t.line)
        if i > 0 and d == 1 and pd == 0 and t.line not in seen_lines and \
           (t.kind == "attr" or (t.kind == "word" and t.text in DECL_START)):
            seen_lines.add(t.line)
            header = lines[t.line - 1].strip()
            if not any(r.match(header) for r in EXT_HEADER_RES):
                errs.append(f"{anchor}: member header not allowed: {header!r}")
            else:
                validated_lines.add(t.line)
        elif i > 0 and d == 1 and pd == 0 and t.line not in seen_lines and t.kind == "word":
            seen_lines.add(t.line)
            errs.append(f"{anchor}: unexpected token at member level: {t.text!r} (line {t.line})")
        if t.kind == "punct":
            if t.text == "{":
                d += 1
            elif t.text == "}":
                d -= 1
            elif t.text in "([":
                pd += 1
            elif t.text in ")]":
                pd -= 1
        if i < len(ctoks) - 1 and d <= 0 and i > 2:
            errs.append(f"{anchor}: extension closes before its last line")
            break
    return errs


def template_errors(template, text, anchor, new_types):
    try:
        toks = lex(text)
    except GateError as e:
        return [f"{anchor}: {e}"]
    ctoks = code(toks)
    cl = code_lines(text)
    if template == "T-EXT":
        return check_ext(text, ctoks, anchor)
    errs = common_region_errors(text, ctoks, anchor)
    if template == "T-SIDE":
        errs += check_side(text, ctoks, anchor)
    elif template == "T-SPLIT/open":
        errs += check_side(text, ctoks, anchor, split_open=True)
    elif template == "T-SPLIT/close":
        if cl != ["}"]:
            errs.append(f"{anchor}: split closing region must be exactly '}}'")
    elif template == "T-LOCAL":
        m = re.fullmatch(r"var (bgPrune[A-Za-z0-9]*): (.+?) = (.+)", cl[0]) if len(cl) == 1 else None
        if not m or not literal_ok(m.group(2), m.group(3), new_types):
            errs.append(f"{anchor}: T-LOCAL must be one inert 'var bgPrune…: T = literal' line")
    elif template == "T-STORE":
        if not cl:
            errs.append(f"{anchor}: empty T-STORE")
        for l in cl:
            if l == 'static let backgroundPruneDefaultsKey = "ada.pruneBackground"':
                continue
            m = re.fullmatch(r"private var ((backgroundPrune|bgPrune)[A-Za-z0-9]*): (.+?) = (.+)", l)
            if not m or not literal_ok(m.group(3), m.group(4), new_types):
                errs.append(f"{anchor}: T-STORE line not allowed: {l!r}")
    elif template == "T-CASE":
        if cl != ["case pruneWait(Date)"]:
            errs.append(f"{anchor}: T-CASE must be exactly 'case pruneWait(Date)'")
    elif template == "T-ARM":
        if not cl or cl[0] != "case .pruneWait(let since):":
            errs.append(f"{anchor}: T-ARM first line must be 'case .pruneWait(let since):'")
        prof = depth_profile(ctoks)
        if any(d < 0 for d in prof):
            errs.append(f"{anchor}: T-ARM depth negative")
        labels = [t for i, t in enumerate(ctoks) if t.kind == "word" and t.text in ("case", "default")
                  and (i == 0 or prof[i - 1] == 0)]
        if len(labels) != 1:
            errs.append(f"{anchor}: T-ARM has another case/default label at its depth")
    elif template == "T-CMD":
        if cl != ['case "/prunebackground":',
                  "await backgroundPruneCommand(argument: commandArgument(from: text))",
                  "return true"]:
            errs.append(f"{anchor}: T-CMD must be exactly the three dispatch lines")
    elif template == "T-REG":
        ok = len(cl) == 2 and re.fullmatch(r'ChatCommand\(name: "prunebackground", description: "[^"\\]*",', cl[0]) \
            and cl[1] == 'usage: "[on|off]", inMenu: false, category: "System"),'
        if not ok:
            errs.append(f"{anchor}: T-REG must be exactly the two registry lines (no interpolation)")
    elif template == "T-SUB":
        if cl != ["BackgroundPruneSelftest.self,"]:
            errs.append(f"{anchor}: T-SUB must be exactly 'BackgroundPruneSelftest.self,'")
    else:
        errs.append(f"{anchor}: unknown template {template}")
    return errs


# ---------------------------------------------------------------- regions

MARK_OPEN = re.compile(r"^// BGPRUNE\{ (\S+)$")
MARK_CLOSE = re.compile(r"^// \}BGPRUNE$")
MARK_LOOSE = re.compile(r"BGPRUNE")


def extract_regions(text, path):
    """Returns (stripped_text, regions). Each region: dict(id, k, text,
    open_line). Markers must be real full-line comment tokens."""
    toks = lex(text)
    comment_lines = {}
    for t in toks:
        if t.kind == "comment" and t.text.startswith("//"):
            comment_lines[t.line] = t.text.strip()
    lines = text.split("\n")
    # lines that contain any code token
    code_on_line = set()
    for t in toks:
        if t.kind != "comment":
            for ln in range(t.line, t.end_line + 1):
                code_on_line.add(ln)
    out = []
    regions = []
    cur = None
    for no, raw in enumerate(lines, start=1):
        s = raw.strip()
        is_open = MARK_OPEN.match(s)
        is_close = MARK_CLOSE.match(s)
        if MARK_LOOSE.search(raw) and not (is_open or is_close):
            raise GateError(f"{path}:{no}: marker text that is not an exact region marker line")
        if is_open or is_close:
            real = comment_lines.get(no) == s and no not in code_on_line
            if not real:
                raise GateError(f"{path}:{no}: region marker inside a literal or comment (not a real comment token)")
        if is_open:
            if cur is not None:
                raise GateError(f"{path}:{no}: nested region")
            cur = {"id": is_open.group(1), "k": len(out), "lines": [], "open_line": no}
            continue
        if is_close:
            if cur is None:
                raise GateError(f"{path}:{no}: region close without open")
            cur["text"] = "\n".join(cur["lines"])
            regions.append(cur)
            cur = None
            continue
        if cur is not None:
            cur["lines"].append(raw)
        else:
            out.append(raw)
    if cur is not None:
        raise GateError(f"{path}: unterminated region {cur['id']}")
    return "\n".join(out), regions


# ---------------------------------------------------------------- manifest

def list_files(root):
    files = {}
    for top in ("TelegramConcierge",):
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
            dirnames.sort()
            for f in sorted(filenames):
                p = os.path.join(dirpath, f)
                rel = os.path.relpath(p, root).replace(os.sep, "/")
                files[rel] = p
    for f in ("Package.swift", "Package.resolved"):
        files[f] = os.path.join(root, f)
    return files


def build_manifest(base_root):
    files = {}
    for rel, p in sorted(list_files(base_root).items()):
        with open(p, "rb") as fh:
            files[rel] = sha(fh.read())
    anchors = []
    texts = {}
    for a in ANCHORS:
        if a["file"] not in texts:
            with open(os.path.join(base_root, a["file"]), encoding="utf-8") as fh:
                texts[a["file"]] = fh.read()
        lines = texts[a["file"]].split("\n")
        if "range" in a:
            x, y = a["range"]
            nb = [x - 1, x, y, y + 1]
        else:
            k = a["after"]
            nb = [k, k + 1]
        entry = dict(a)
        entry["neighbors"] = {str(n): line_sha(lines[n - 1]) if 1 <= n <= len(lines) else "EOF" for n in nb}
        anchors.append(entry)
    for rel, text in texts.items():
        if PREFIX_RE.search(text):
            raise GateError(f"baseline already contains a reserved prefix in {rel}")
    for rel, p in list_files(base_root).items():
        if rel.endswith(".swift"):
            with open(p, encoding="utf-8", errors="replace") as fh:
                if PREFIX_RE.search(fh.read()):
                    raise GateError(f"baseline already contains a reserved prefix in {rel}")
    return {"baseline": BASELINE_COMMIT, "files": files, "anchors": anchors}


def manifest_bytes(manifest):
    return (json.dumps(manifest, indent=1, sort_keys=True) + "\n").encode("utf-8")


def load_manifest():
    path = os.path.join(HERE, MANIFEST_NAME)
    with open(path, "rb") as fh:
        data = fh.read()
    if sha(data) != MANIFEST_SHA256:
        raise GateError(f"manifest hash mismatch: {sha(data)} != pinned {MANIFEST_SHA256}")
    return json.loads(data)


# ---------------------------------------------------------------- new files

ALLOWED_HEADER_LINES = {"import ArgumentParser", "import Foundation"}
PLATFORM_BLOCKS = [
    ["#if canImport(FoundationNetworking)", "import FoundationNetworking", "#endif"],
    ["#if canImport(Glibc)", "import Glibc", "#else", "import Darwin", "#endif"],
]


def new_file_errors(rel, text):
    errs = []
    try:
        toks = lex(text)
    except GateError as e:
        return [f"{rel}: {e}"], set()
    ctoks = code(toks)
    lines = text.split("\n")
    # header
    i = 0
    cl = [(n + 1, l.strip()) for n, l in enumerate(lines) if l.strip() and not l.strip().startswith("//")]
    header_end_line = 0
    while i < len(cl):
        no, s = cl[i]
        if s in ALLOWED_HEADER_LINES:
            header_end_line = no
            i += 1
            continue
        matched = False
        for block in PLATFORM_BLOCKS:
            if [x[1] for x in cl[i:i + len(block)]] == block:
                header_end_line = cl[i + len(block) - 1][0]
                i += len(block)
                matched = True
                break
        if not matched:
            break
    types = set()
    d = 0
    expecting_decl = True
    j = 0
    while j < len(ctoks):
        t = ctoks[j]
        if t.line <= header_end_line:
            j += 1
            continue
        if t.kind == "directive":
            errs.append(f"{rel}:{t.line}: directive {t.text} outside the fixed import header")
        # Codex impl round 4, R4-1: the attribute vocabulary is closed at
        # every nesting depth, not only at the top level. Linkage and
        # code-generation attributes (@_silgen_name, @_cdecl,
        # @_dynamicReplacement, @objc, @inline, @usableFromInline, macros,
        # property wrappers other than the selftest's fixed @Flag/@Option…)
        # could replace or alias a symbol protected code relies on.
        if t.kind == "attr":
            allowed = NEW_FILE_ATTRIBUTES | (SELFTEST_ATTRIBUTES if SELFTEST_PATTERN.match(rel) else set())
            if t.text not in allowed:
                errs.append(f"{rel}:{t.line}: attribute {t.text} not allowed (not on the attribute allowlist)")
            elif t.text == "@unchecked" and not (j + 1 < len(ctoks) and ctoks[j + 1].text == "Sendable"):
                errs.append(f"{rel}:{t.line}: @unchecked only as '@unchecked Sendable'")
        if d == 0:
            if t.kind == "attr":
                j += 1
                continue
            kw = t.text
            if kw == "final" and j + 1 < len(ctoks) and ctoks[j + 1].text == "class":
                j += 1
                kw = "class"
            if kw in ("struct", "enum", "actor", "class"):
                if kw == "class" and ctoks[j - 1].text != "final":
                    errs.append(f"{rel}:{t.line}: top-level class must be final")
                name = ctoks[j + 1].text if j + 1 < len(ctoks) else ""
                if not re.fullmatch(r"BackgroundPrune[A-Za-z0-9]*", name):
                    errs.append(f"{rel}:{t.line}: top-level type {name!r} lacks the BackgroundPrune prefix")
                types.add(name)
                # skip the header to the body's '{', then enter the body
                j += 2
                while j < len(ctoks) and not (ctoks[j].kind == "punct" and ctoks[j].text == "{"):
                    if ctoks[j].kind == "word" and ctoks[j].text in ("extension", "protocol"):
                        errs.append(f"{rel}:{ctoks[j].line}: '{ctoks[j].text}' in a type header")
                    if ctoks[j].kind == "attr" and ctoks[j].text not in ("@unchecked", "@MainActor", "@Sendable"):
                        errs.append(f"{rel}:{ctoks[j].line}: attribute {ctoks[j].text} in a type header (not on the attribute allowlist)")
                    if ctoks[j].kind == "attr" and ctoks[j].text == "@unchecked" and not (
                            j + 1 < len(ctoks) and ctoks[j + 1].text == "Sendable"):
                        errs.append(f"{rel}:{ctoks[j].line}: @unchecked only as '@unchecked Sendable'")
                    j += 1
                d = 1
                j += 1
                continue
            errs.append(f"{rel}:{t.line}: only struct/enum/final class/actor declarations allowed at top level (found {t.text!r})")
            j += 1
            continue
        if t.kind == "word" and t.text in ("extension", "protocol", "operator", "precedencegroup", "import"):
            errs.append(f"{rel}:{t.line}: '{t.text}' not allowed in a new file")
        if t.kind == "punct" and t.text == "{":
            d += 1
        elif t.kind == "punct" and t.text == "}":
            d -= 1
        j += 1
        continue
    # brace accounting for the top-level '{' we skipped to
    return errs, types


DECL_MODIFIERS = {"nonisolated", "private", "fileprivate", "internal", "public", "final", "lazy",
                  "override", "dynamic", "unsafe", "(", ")"}
# Tokens that may follow a complete static literal declaration: the start
# of the next declaration or the end of the enclosing body.
NEXT_DECL = {"static", "class", "let", "var", "func", "init", "deinit", "subscript", "struct", "enum",
             "final", "private", "fileprivate", "internal", "public", "nonisolated", "case", "typealias",
             "lazy", "override", "mutating", "}"}
CONFIG_LABELS = {"commandName", "abstract", "discussion"}
COMMAND_PROPERTY_FORMS = (
    re.compile(r"@Flag \( name : \. long , help : \. hidden \) var [A-Za-z_][A-Za-z0-9_]* = false"),
    re.compile(r"@Option \( name : \. long , help : \. hidden \) var [A-Za-z_][A-Za-z0-9_]* : (String|Int|Double) \?"),
)


def _plain_string(tok):
    """A single-line, non-raw string literal without interpolation."""
    return (tok.kind == "str" and tok.text.startswith('"') and not tok.text.startswith('"""')
            and tok.line == tok.end_line and "\\(" not in tok.text)


def _next_starts_decl(toks, k, after_line):
    if k >= len(toks):
        return True
    t = toks[k]
    if t.kind == "attr":
        return t.line > after_line
    return t.text in NEXT_DECL and (t.line > after_line or t.text == "}")


def selftest_errors(rel, text):
    """Hidden and inert during command discovery (Codex impl R3a, round-2
    R2-1). Works on the lexed token stream, so whitespace, newlines and
    comments between modifiers cannot hide a declaration:
      * every `static`/`class` stored property is either the exact
        `static let configuration = CommandConfiguration(...)` literal
        (literal commandName/abstract/discussion, exactly one
        `shouldDisplay: false`) or `static let NAME [: Type] = <literal>`;
        anything unrecognised is rejected, never skipped;
      * every instance property of a ParsableCommand type is one of the
        fixed hidden @Flag/@Option forms (ArgumentParser evaluates them
        during discovery and --help)."""
    errs = []
    if ("ParsableCommand" in text or "CommandConfiguration" in text) and "shouldDisplay: false" not in text:
        errs.append(f"{rel}: selftest configuration must use shouldDisplay: false")
    try:
        toks = code(lex(text))
    except GateError as e:
        return [f"{rel}: {e}"]
    n = len(toks)
    configs = 0
    depth = 0
    command_depths = []          # body depths of ParsableCommand types
    pending_command = False
    i = 0
    while i < n:
        t = toks[i]
        if t.kind == "punct" and t.text == "{":
            depth += 1
            if pending_command:
                command_depths.append(depth)
                pending_command = False
            i += 1
            continue
        if t.kind == "punct" and t.text == "}":
            if command_depths and command_depths[-1] == depth:
                command_depths.pop()
            depth -= 1
            i += 1
            continue
        if t.kind == "word" and t.text in ("struct", "class", "enum", "actor") and i + 1 < n \
                and toks[i + 1].kind == "word" and toks[i + 1].text not in ("var", "let", "func", "subscript"):
            k = i + 2
            while k < n and not (toks[k].kind == "punct" and toks[k].text == "{"):
                if toks[k].text in ("ParsableCommand", "AsyncParsableCommand"):
                    pending_command = True
                k += 1
            i += 1
            continue
        if t.kind == "word" and t.text in ("static", "class"):
            k = i + 1
            while k < n and (toks[k].text in DECL_MODIFIERS or toks[k].kind == "attr"):
                k += 1
            if k >= n:
                break
            kw = toks[k].text
            if kw in ("func", "subscript", "init"):
                i = k
                continue
            if kw not in ("let", "var"):
                if t.text == "static":
                    errs.append(f"{rel}:{t.line}: unrecognised static declaration ({kw!r})")
                i += 1
                continue
            name = toks[k + 1] if k + 1 < n else None
            if name is None or name.kind != "word":
                errs.append(f"{rel}:{t.line}: static declaration without a plain name")
                i = k + 1
                continue
            if name.text == "configuration":
                configs += 1
                ok = (kw == "let" and t.text == "static" and k == i + 1 and k + 4 < n
                      and toks[k + 2].text == "=" and toks[k + 3].text == "CommandConfiguration"
                      and toks[k + 4].text == "(")
                m = k + 5
                labels = []
                while ok:
                    if m < n and toks[m].text == ")":
                        break
                    if m + 2 >= n:
                        ok = False
                        break
                    label, colon, value = toks[m], toks[m + 1], toks[m + 2]
                    if colon.text != ":":
                        ok = False
                        break
                    if label.text in CONFIG_LABELS and _plain_string(value):
                        labels.append(label.text)
                    elif label.text == "shouldDisplay" and value.text == "false":
                        labels.append("shouldDisplay")
                    else:
                        ok = False
                        break
                    m += 3
                    if m < n and toks[m].text == ",":
                        m += 1
                if ok and (m >= n or toks[m].text != ")" or labels.count("shouldDisplay") != 1
                           or len(set(labels)) != len(labels) or not _next_starts_decl(toks, m + 1, toks[m].line)):
                    ok = False
                if not ok:
                    errs.append(f"{rel}:{t.line}: selftest configuration must be a plain "
                                f"`static let configuration = CommandConfiguration(...)` literal")
                    i = k + 2
                    continue
                i = m + 1
                continue
            # any other static/class stored property: literal constant only
            m = k + 2
            if m < n and toks[m].text == ":":
                m += 2 if m + 1 < n and toks[m + 1].kind == "word" else 1
            ok = kw == "let" and t.text == "static" and m < n and toks[m].text == "="
            m += 1
            if ok and m < n and toks[m].kind == "op" and toks[m].text == "-":
                m += 1
            ok = ok and m < n and (_plain_string(toks[m]) or toks[m].kind == "num" or toks[m].text in ("true", "false"))
            if ok:
                ok = _next_starts_decl(toks, m + 1, toks[m].end_line)
            if not ok:
                errs.append(f"{rel}:{t.line}: selftest static property must be `configuration` "
                            f"or a literal constant (`{name.text}`)")
            i = m + 1
            continue
        # instance properties of a ParsableCommand type
        if command_depths and depth == command_depths[-1] and (
                t.kind == "attr" or (t.kind == "word" and t.text in ("var", "let"))):
            line = t.line
            q = i
            while q < n and toks[q].line == line and (toks[q].kind == "attr" or toks[q].text in DECL_MODIFIERS
                                                       or (q > i and toks[q - 1].kind == "attr" and toks[q].text == "(")):
                if toks[q].kind == "attr" and q + 1 < n and toks[q + 1].text == "(":
                    # skip the attribute's argument list
                    d2 = 0
                    q += 1
                    while q < n:
                        if toks[q].text == "(":
                            d2 += 1
                        elif toks[q].text == ")":
                            d2 -= 1
                            if d2 == 0:
                                break
                        q += 1
                q += 1
            if q >= n or toks[q].text not in ("var", "let"):
                i += 1
                continue
            k = i
            while k < n and toks[k].line == line:
                k += 1
            joined = " ".join(x.text for x in toks[i:k])
            if not any(f.fullmatch(joined) for f in COMMAND_PROPERTY_FORMS) or not _next_starts_decl(toks, k, line):
                errs.append(f"{rel}:{line}: command property not allowed: {joined!r}")
            i = k
            continue
        i += 1
    if "ParsableCommand" in text and configs != 1:
        errs.append(f"{rel}: a selftest command needs exactly one configuration declaration (found {configs})")
    return errs


# ------------------------------------------------- reserved names (R3-1)

# Codex impl round 3, R3-1: name resolution. Command discovery evaluates
# `static let configuration = CommandConfiguration(...)` and the @Flag/@Option
# property-wrapper initialisers; which declarations those names resolve to is
# decided by lookup, not by spelling. A new member/type/typealias/generic
# parameter called `CommandConfiguration` (or `Flag`, `Option`, a literal-type
# alias, `String`, ...) would shadow the imported declaration. Lookup from the
# command type reaches: its own members and generic parameters, the module's
# top level, and the fixed imports. Protected files are byte-identical to
# 0.2.56 and new files may only add `BackgroundPrune*` top-level types, so the
# only way to shadow is a declaration in NEW code. Therefore:
#   * no declaration in new code (files and marked regions) may bind a name in
#     RESERVED_DECL, in any declaration position (`func/var/let/struct/class/
#     enum/actor/typealias/case/associatedtype/protocol/macro/for NAME`, enum
#     case lists, tuple patterns, generic parameter lists);
#   * the ArgumentParser-specific names in AP_POSITIONAL may appear only at
#     their single approved position: `import ArgumentParser`, the approved
#     configuration call, and the command type's inheritance clause. Any other
#     occurrence (including a qualified `ArgumentParser.X` lookup) is rejected.
# The approved configuration call therefore resolves to ArgumentParser's
# `CommandConfiguration` initialiser by exhaustion.
AP_POSITIONAL = {"CommandConfiguration", "ArgumentParser", "ParsableCommand", "AsyncParsableCommand",
                 "ParsableArguments", "Flag", "Option", "Argument", "OptionGroup", "ArgumentHelp",
                 "NameSpecification", "ArgumentVisibility", "ExpressibleByArgument", "EnumerableFlag",
                 "CommandGroup", "ArgumentArrayParsingStrategy", "SingleValueParsingStrategy",
                 "ArrayParsingStrategy", "FlagInversion", "FlagExclusivity", "CompletionKind",
                 "ParsableArgumentsValidator"}
RESERVED_DECL = AP_POSITIONAL | {
    "ExitCode", "CleanExit", "ValidationError",
    "String", "Int", "Double", "Float", "Bool", "Character", "Substring", "Optional", "Array",
    "Dictionary", "Set", "Never", "Void", "Any", "AnyObject", "Error",
    "Swift", "Foundation", "FoundationNetworking", "Glibc", "Darwin",
    "StringLiteralType", "IntegerLiteralType", "FloatLiteralType", "BooleanLiteralType",
    "ExtendedGraphemeClusterLiteralType", "UnicodeScalarLiteralType",
}
DECL_INTRODUCERS = {"func", "var", "let", "struct", "class", "enum", "actor", "typealias", "case",
                    "associatedtype", "protocol", "macro", "for"}
GENERIC_HOSTS = {"struct", "class", "enum", "actor", "func", "typealias", "protocol"}


def _bracket_end(toks, i, open_, close):
    """Index of the token closing the bracket opened at toks[i]."""
    d = 0
    for j in range(i, len(toks)):
        if toks[j].text == open_ or (open_ == "<" and toks[j].kind == "op" and toks[j].text.startswith("<")):
            d += toks[j].text.count(open_) if open_ == "<" else 1
        elif toks[j].text == close or (close == ">" and toks[j].kind == "op" and set(toks[j].text) == {">"}):
            d -= toks[j].text.count(close) if close == ">" else 1
            if d <= 0:
                return j
    return len(toks) - 1


def reserved_name_errors(where, toks, selftest=False):
    """toks: code tokens (comments removed). `selftest`: the file may hold the
    approved configuration / command inheritance (BackgroundPruneSelftest*)."""
    errs = []
    n = len(toks)
    bound = []                                   # (token index) of binding names

    def bind(j):
        if 0 <= j < n and toks[j].kind == "word":
            bound.append(j)

    for i, t in enumerate(toks):
        if t.kind != "word":
            continue
        prev = toks[i - 1] if i > 0 else None
        # 1. NAME right after a declaration introducer
        if t.text in DECL_INTRODUCERS:
            bind(i + 1)
            # tuple pattern: let (a, b) / case let (a, b) / for (a, b) in
            if i + 1 < n and toks[i + 1].text == "(" and t.text in ("var", "let", "for"):
                e = _bracket_end(toks, i + 1, "(", ")")
                for j in range(i + 2, e):
                    if toks[j - 1].text in ("(", ",") and toks[j].kind == "word":
                        bind(j)
            # enum case list: case a, b(Int), c = 1
            if t.text == "case" and i + 1 < n and toks[i + 1].kind == "word" \
                    and toks[i + 1].text not in ("let", "var", "is", "_"):
                line = toks[i].line
                pd = 0
                for j in range(i + 1, n):
                    if toks[j].line != line:
                        break
                    if toks[j].text in "([":
                        pd += 1
                    elif toks[j].text in ")]":
                        pd -= 1
                    elif toks[j].text == ":" and pd == 0:
                        break                     # a switch label, not a declaration
                    elif toks[j].text == "," and pd == 0:
                        bind(j + 1)
            # generic parameter list: KW NAME < P1, P2: C, ... >
            if t.text in GENERIC_HOSTS and i + 2 < n and toks[i + 2].kind == "op" and toks[i + 2].text.startswith("<"):
                e = _bracket_end(toks, i + 2, "<", ">")
                depth = 0
                for j in range(i + 2, e + 1):
                    if toks[j].kind == "op" and toks[j].text.startswith("<"):
                        depth += toks[j].text.count("<")
                        if depth == 1:
                            bind(j + 1)
                    elif toks[j].kind == "op" and set(toks[j].text) == {">"}:
                        depth -= len(toks[j].text)
                    elif toks[j].text == "," and depth == 1:
                        bind(j + 1)
        if t.text in ("init", "subscript") and i + 1 < n and toks[i + 1].kind == "op" and toks[i + 1].text.startswith("<"):
            e = _bracket_end(toks, i + 1, "<", ">")
            for j in range(i + 1, e):
                if toks[j].text in (",",) or (toks[j].kind == "op" and toks[j].text.startswith("<")):
                    bind(j + 1)
        # 2. ArgumentParser-specific names: only at their approved position
        if t.text in AP_POSITIONAL:
            approved = False
            if t.text == "ArgumentParser":
                approved = prev is not None and prev.text == "import"
            elif t.text == "CommandConfiguration" and selftest:
                approved = (i >= 4 and [x.text for x in toks[i - 4:i]] == ["static", "let", "configuration", "="]
                            and i + 1 < n and toks[i + 1].text == "(")
            elif t.text in ("ParsableCommand", "AsyncParsableCommand") and selftest:
                approved = (i >= 3 and toks[i - 1].text == ":" and toks[i - 2].kind == "word"
                            and toks[i - 3].text == "struct" and i + 1 < n and toks[i + 1].text == "{")
            if not approved:
                errs.append(f"{where}:{t.line}: ArgumentParser name {t.text!r} outside its approved position "
                            f"(R3-1: it must resolve to the imported declaration)")
    for j in bound:
        if toks[j].text in RESERVED_DECL:
            errs.append(f"{where}:{toks[j].line}: declaration shadows reserved name {toks[j].text!r} (R3-1)")
    return errs


# ---------------------------------------------------------------- validate

def validate(root, manifest=None):
    errs = []
    try:
        manifest = manifest or load_manifest()
    except GateError as e:
        return [str(e)]
    files = manifest["files"]
    present = list_files(root)
    new_types = set()
    new_files = []
    for rel, p in sorted(present.items()):
        if rel in files:
            continue
        if not os.path.exists(p):
            continue
        if any(r.match(rel) for r in NEW_FILE_PATTERNS):
            new_files.append(rel)
        else:
            errs.append(f"unexpected file outside the allowed new-file paths: {rel}")
    for rel in new_files:
        with open(present[rel], encoding="utf-8") as fh:
            text = fh.read()
        e, types = new_file_errors(rel, text)
        errs += e
        new_types |= types
        try:
            errs += reserved_name_errors(rel, code(lex(text)), selftest=bool(SELFTEST_PATTERN.match(rel)))
        except GateError as e:
            errs.append(f"{rel}: {e}")
        if SELFTEST_PATTERN.match(rel):
            errs += selftest_errors(rel, text)
    for rel, digest in sorted(files.items()):
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            errs.append(f"protected file missing: {rel}")
            continue
        if rel in ALLOW_LISTED:
            continue
        with open(p, "rb") as fh:
            if sha(fh.read()) != digest:
                errs.append(f"protected file changed: {rel}")
    anchors = {a["id"]: a for a in manifest["anchors"]}
    seen = {}
    for rel in ALLOW_LISTED:
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8") as fh:
            text = fh.read()
        try:
            stripped, regions = extract_regions(text, rel)
        except GateError as e:
            errs.append(str(e))
            continue
        if sha(stripped.encode("utf-8")) != files[rel]:
            errs.append(f"{rel}: stripping the marked regions does not reproduce the baseline (an unmarked change)")
            continue
        if PREFIX_RE.search(stripped):
            errs.append(f"{rel}: reserved prefix in baseline text")
        try:
            b = Baseline(stripped)
        except GateError as e:
            errs.append(f"{rel}: {e}")
            continue
        # group split regions
        by_id = {}
        order = []
        for r in regions:
            rid = r["id"]
            base_id, _, part = rid.partition("/")
            by_id.setdefault(base_id, []).append((part, r))
            order.append(base_id)
        for r in regions:
            try:
                errs += reserved_name_errors(f"{rel} region {r['id']}", code(lex(r["text"])))
            except GateError:
                pass                              # reported by template_errors
        for base_id, parts in by_id.items():
            a = anchors.get(base_id)
            if a is None:
                errs.append(f"{rel}: region with unknown anchor id {base_id!r}")
                continue
            if a["file"] != rel:
                errs.append(f"{rel}: anchor {base_id} belongs to {a['file']}")
                continue
            if base_id in seen:
                errs.append(f"{rel}: duplicated anchor id {base_id}")
                continue
            seen[base_id] = True
            lines = b.lines
            for n, h in a["neighbors"].items():
                n = int(n)
                actual = line_sha(lines[n - 1]) if 1 <= n <= len(lines) else "EOF"
                if actual != h:
                    errs.append(f"{rel}: anchor {base_id}: neighbouring baseline line {n} hash mismatch")
            if a["template"] == "T-SPLIT":
                ids = [p for p, _ in parts]
                if ids != ["open", "close"]:
                    errs.append(f"{rel}: anchor {base_id}: split needs exactly an /open then a /close region")
                    continue
                ro, rc = parts[0][1], parts[1][1]
                x, y = a["range"]
                if ro["k"] != x - 1 or rc["k"] != y:
                    errs.append(f"{rel}: anchor {base_id}: split regions not at the pinned range [{x}, {y}] (at {ro['k'] + 1}..{rc['k']})")
                # consecutive regions
                io = regions.index(ro)
                if io + 1 >= len(regions) or regions[io + 1] is not rc:
                    errs.append(f"{rel}: anchor {base_id}: split regions are not consecutive")
                errs += template_errors("T-SPLIT/open", ro["text"], base_id + "/open", new_types)
                errs += template_errors("T-SPLIT/close", rc["text"], base_id + "/close", new_types)
                errs += split_range_errors(b, x, y, base_id)
            else:
                if [p for p, _ in parts] != [""]:
                    errs.append(f"{rel}: anchor {base_id}: expected exactly one region")
                    continue
                r = parts[0][1]
                if r["k"] != a["after"]:
                    errs.append(f"{rel}: anchor {base_id}: region not at its pinned insertion point (after baseline line {a['after']}, found after {r['k']})")
                errs += template_errors(a["template"], r["text"], base_id, new_types)
                errs += context_errors(b, a["after"], a["context"], base_id)
                if a["template"] == "T-ARM":
                    # the pinned switch: the line before is the switch opener
                    if not b.lines[a["after"] - 1].strip().startswith("switch "):
                        errs.append(f"{rel}: anchor {base_id}: not the pinned switch")
                if a["template"] in ("T-REG", "T-SUB") and not r["text"].rstrip().endswith(","):
                    errs.append(f"{rel}: anchor {base_id}: element region must end with ','")
        # same-point order
        pos = [rid for rid in order if rid in SAME_POINT_ORDER]
        if pos and pos != [x for x in SAME_POINT_ORDER if x in pos]:
            errs.append(f"{rel}: regions at the shared insertion point out of order")
    for a in manifest["anchors"]:
        if a["id"] not in seen:
            errs.append(f"missing anchor region {a['id']}")
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.dirname(HERE))
    ap.add_argument("--write-manifest")
    ap.add_argument("--verify-manifest")
    args = ap.parse_args()
    if args.write_manifest:
        data = manifest_bytes(build_manifest(args.write_manifest))
        with open(os.path.join(HERE, MANIFEST_NAME), "wb") as fh:
            fh.write(data)
        print(f"manifest written; sha256 {sha(data)}")
        return 0
    if args.verify_manifest:
        data = manifest_bytes(build_manifest(args.verify_manifest))
        with open(os.path.join(HERE, MANIFEST_NAME), "rb") as fh:
            committed = fh.read()
        if data != committed:
            print("✖ verify-manifest: regenerated manifest differs from the committed one")
            return 1
        if sha(committed) != MANIFEST_SHA256:
            print("✖ verify-manifest: committed manifest hash differs from the pinned constant")
            return 1
        print(f"✔ verify-manifest: manifest regenerated from the baseline tree is byte-identical ({len(json.loads(committed)['files'])} files, {len(ANCHORS)} anchors)")
        return 0
    errs = validate(args.root)
    if errs:
        for e in errs:
            print("✖ " + e)
        print(f"\nOFF-identity gate FAILED ({len(errs)} finding(s))")
        return 1
    print(f"✔ OFF-identity gate: {len(ANCHORS)} anchors, all protected files identical, regions valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
