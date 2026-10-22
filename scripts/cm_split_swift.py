#!/usr/bin/env python3
"""Minimal Swift lexer and declaration inventory for the ConversationManager split checker.

Not a Swift parser: it tokenizes (comments, ordinary/multiline/raw strings with
their interpolations lexed as code, nested block comments, attributes,
backtick identifiers) and finds the direct members of a brace-delimited
container with their full line extents. The checker validates the result
against the real base (counts and samples) in its self-test.
"""
import re

KEYWORDS_DECL = {"func", "init", "deinit", "subscript", "var", "let", "struct", "enum", "class", "actor",
                 "protocol", "typealias", "extension", "case"}
MODIFIERS = {"private", "fileprivate", "internal", "public", "open", "static", "final", "lazy", "weak",
             "unowned", "nonisolated", "override", "convenience", "required", "mutating", "nonmutating",
             "dynamic", "optional", "indirect", "isolated", "consuming", "borrowing", "package"}
TYPE_KW = {"struct", "enum", "class", "actor", "protocol", "extension"}
BODY_KW = {"func", "init", "deinit", "subscript"} | TYPE_KW
ACCESS_DELETIONS = ("private ", "fileprivate ", "private(set) ")

_ID = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUM = re.compile(r"[0-9][0-9A-Za-z_]*(?:\.[0-9][0-9A-Za-z_]*)?")
_OPCH = set("/=-+!*%<>&|^~?.")


class Tok:
    __slots__ = ("kind", "text", "start", "end", "line", "interp")

    def __init__(self, kind, text, start, end, line, interp=False):
        self.kind, self.text, self.start, self.end, self.line, self.interp = kind, text, start, end, line, interp

    def __repr__(self):
        return f"Tok({self.kind},{self.text!r},L{self.line})"


class LexError(Exception):
    pass


def lex(src):
    """Code tokens of `src`. String literal contents are skipped, except
    interpolations, whose expressions are lexed as code (tokens marked
    `interp=True`). Comments are skipped. Kinds: id, attr, num, punct, op, str."""
    line_starts = [0]
    for m in re.finditer("\n", src):
        line_starts.append(m.end())
    import bisect

    def line_of(off):
        return bisect.bisect_right(line_starts, off)

    toks = []
    n = len(src)

    def lex_code(i, stop_on_paren, interp):
        depth = 0
        while i < n:
            c = src[i]
            if c in " \t\r\n":
                i += 1; continue
            if src.startswith("//", i):
                j = src.find("\n", i)
                i = n if j < 0 else j
                continue
            if src.startswith("/*", i):
                d, j = 1, i + 2
                while d and j < n:
                    if src.startswith("/*", j): d += 1; j += 2
                    elif src.startswith("*/", j): d -= 1; j += 2
                    else: j += 1
                if d: raise LexError("unterminated block comment at line %d" % line_of(i))
                i = j; continue
            # raw / ordinary / multiline string
            m = re.compile(r'(#*)("""|")').match(src, i)
            if m and (m.group(1) or c == '"'):
                i = lex_string(i, len(m.group(1)), m.group(2) == '"""', interp)
                continue
            if c == "@":
                m = _ID.match(src, i + 1)
                if m:
                    toks.append(Tok("attr", "@" + m.group(), i, m.end(), line_of(i), interp)); i = m.end(); continue
            if c == "#":
                m = _ID.match(src, i + 1)
                if m:
                    toks.append(Tok("id", "#" + m.group(), i, m.end(), line_of(i), interp)); i = m.end(); continue
            if c == "`":
                j = src.find("`", i + 1)
                toks.append(Tok("id", src[i + 1:j], i, j + 1, line_of(i), interp)); i = j + 1; continue
            if c == "$":
                m = re.compile(r"\$[A-Za-z0-9_]+").match(src, i)
                if m:
                    toks.append(Tok("id", m.group(), i, m.end(), line_of(i), interp)); i = m.end(); continue
            m = _ID.match(src, i)
            if m:
                toks.append(Tok("id", m.group(), i, m.end(), line_of(i), interp)); i = m.end(); continue
            m = _NUM.match(src, i)
            if m:
                toks.append(Tok("num", m.group(), i, m.end(), line_of(i), interp)); i = m.end(); continue
            if c in "{}[](),:;\\":
                if stop_on_paren:
                    if c == "(": depth += 1
                    elif c == ")":
                        if depth == 0: return i + 1
                        depth -= 1
                toks.append(Tok("punct", c, i, i + 1, line_of(i), interp)); i += 1; continue
            if c in _OPCH:
                j = i
                while j < n and src[j] in _OPCH and not src.startswith("//", j) and not src.startswith("/*", j):
                    j += 1
                if j == i: j = i + 1
                toks.append(Tok("op", src[i:j], i, j, line_of(i), interp)); i = j; continue
            toks.append(Tok("op", c, i, i + 1, line_of(i), interp)); i += 1
        if stop_on_paren: raise LexError("unterminated interpolation")
        return i

    def lex_string(i, hashes, multi, interp):
        start = i
        i += hashes + (3 if multi else 1)
        close = ('"""' if multi else '"') + "#" * hashes
        esc = "\\" + "#" * hashes
        while i < n:
            if src.startswith(esc, i):
                k = i + len(esc)
                if k < n and src[k] == "(":
                    i = lex_code(k + 1, True, True)
                    continue
                i = k + 1
                continue
            if src.startswith(close, i):
                i += len(close)
                toks.append(Tok("str", src[start:i] if not multi else '"""', start, i, line_of(start), interp))
                return i
            if not multi and src[i] == "\n":
                raise LexError("newline in string at line %d" % line_of(start))
            i += 1
        raise LexError("unterminated string at line %d" % line_of(start))

    lex_code(0, False, False)
    toks.sort(key=lambda t: t.start)
    return toks, line_of


OPENERS = {"{": "}", "(": ")", "[": "]"}


class Member:
    def __init__(self):
        self.first = None      # index of first token
        self.last = None       # index of last token
        self.kw = None         # decl keyword token index
        self.kind = None
        self.name = None
        self.modifiers = []    # [(token index, modifier text)]; private(set) as 'private(set)'
        self.start_line = None  # first code line
        self.end_line = None
        self.trivia_line = None  # first line of leading trivia
        self.stored = None
        self.static = False

    def as_dict(self):
        return {"name": self.name, "kind": self.kind, "start": self.start_line, "end": self.end_line,
                "trivia": self.trivia_line, "static": self.static}


def members(src, toks, line_of, open_idx, close_idx):
    """Direct members of the container whose `{` is toks[open_idx] and `}` toks[close_idx]."""
    out = []
    stack = []
    cur = None
    i = open_idx + 1
    lines = src.split("\n")

    def line_text(ln):
        return lines[ln - 1]

    def finish(m, last):
        m.last = last
        m.end_line = toks[last].line
        out.append(m)

    while i < close_idx:
        t = toks[i]
        level0 = not stack
        if level0 and cur is None:
            starter = t.kind == "attr" or (t.kind == "id" and (t.text in MODIFIERS or t.text in KEYWORDS_DECL or t.text in {"class"}))
            if not starter:
                raise LexError(f"unexpected token {t.text!r} between members at line {t.line}")
            cur = Member()
            cur.first = i
            cur.start_line = t.line
            prev_end = out[-1].end_line if out else toks[open_idx].line
            if out and out[-1].end_line == t.line:
                raise LexError(f"two members on line {t.line}")
            cur.trivia_line = prev_end + 1
        if cur is not None and cur.kw is None and level0:
            if t.kind == "attr":
                # attribute arguments
                if i + 1 < close_idx and toks[i + 1].text == "(" and toks[i + 1].start == t.end:
                    pass
            elif t.kind == "id" and t.text in MODIFIERS:
                if t.text in ("private", "fileprivate", "internal", "public", "open") and i + 1 < close_idx and toks[i + 1].text == "(" and toks[i + 1].start == t.end:
                    # private(set)
                    cur.modifiers.append((i, src[t.start:toks[i + 3].end]))
                else:
                    cur.modifiers.append((i, t.text))
                if t.text == "static":
                    cur.static = True
            elif t.kind == "id" and t.text == "class" and i + 1 < close_idx and toks[i + 1].kind == "id" and toks[i + 1].text in ("func", "var", "let", "subscript"):
                cur.modifiers.append((i, "class")); cur.static = True
            elif t.kind == "id" and t.text in KEYWORDS_DECL:
                cur.kw = i
                cur.kind = t.text
                if t.text in ("init", "deinit", "subscript"):
                    cur.name = t.text
                else:
                    nt = toks[i + 1]
                    cur.name = nt.text
        # nesting
        if t.kind == "punct" and t.text in OPENERS:
            stack.append(t.text)
        elif t.kind == "punct" and t.text in ("}", ")", "]"):
            if not stack:
                raise LexError(f"unbalanced {t.text} at line {t.line}")
            stack.pop()
            if not stack and cur is not None and cur.kw is not None and t.text == "}" and cur.kind in BODY_KW:
                # body closed iff this brace closes the first level-0 brace after the keyword
                finish(cur, i); cur = None
                i += 1
                continue
        # end-of-line termination for var/let/typealias/case
        if cur is not None and cur.kw is not None and cur.kind not in BODY_KW and not stack:
            nxt = toks[i + 1] if i + 1 <= close_idx else None
            if nxt is None or nxt.line != t.line:
                cont_end = (t.kind == "op" and not re.fullmatch(r"[>?!]+", t.text)) or t.text in (",", ":", "\\") or (t.kind == "id" and t.text in ("as", "is", "in", "where"))
                cont_next = nxt is not None and nxt.line != t.line and (
                    (nxt.kind == "op" and not re.fullmatch(r"[!]+", nxt.text)) or (nxt.kind == "punct" and nxt.text == "{"))
                if nxt is toks[close_idx]:
                    cont_next = False
                if not cont_end and not cont_next:
                    finish(cur, i); cur = None
        i += 1
    if cur is not None:
        raise LexError(f"unterminated member {cur.name} at line {cur.start_line}")
    # classify stored/computed for var/let
    for m in out:
        if m.kind == "let":
            m.stored = True
        elif m.kind == "var":
            m.stored = _var_is_stored(toks, m)
        else:
            m.stored = False
    return out


def _var_is_stored(toks, m):
    depth = 0
    saw_eq = False
    for j in range(m.kw + 1, m.last + 1):
        t = toks[j]
        if t.kind == "punct" and t.text in ("(", "["):
            depth += 1
        elif t.kind == "punct" and t.text in (")", "]"):
            depth -= 1
        elif depth == 0 and t.kind == "op" and t.text == "=":
            saw_eq = True
        elif depth == 0 and t.kind == "punct" and t.text == "{":
            if saw_eq:
                return True  # closure initializer
            first = toks[j + 1]
            return first.kind == "id" and first.text in ("willSet", "didSet")
    return True


def find_close(toks, open_idx):
    depth = 0
    for j in range(open_idx, len(toks)):
        t = toks[j]
        if t.kind == "punct" and t.text in OPENERS:
            depth += 1
        elif t.kind == "punct" and t.text in ("}", ")", "]"):
            depth -= 1
            if depth == 0:
                return j
    raise LexError("unbalanced container")


def body_open(toks, m):
    """Index of the `{` opening member m's body (types/extensions)."""
    depth = 0
    for j in range(m.kw + 1, m.last + 1):
        t = toks[j]
        if t.kind == "punct" and t.text in ("(", "["):
            depth += 1
        elif t.kind == "punct" and t.text in (")", "]"):
            depth -= 1
        elif depth == 0 and t.kind == "punct" and t.text == "{":
            return j
    raise LexError("no body for " + str(m.name))


class Inventory:
    """Top-level blocks of a file (after its header) and the direct members of the class and of every extension."""

    def __init__(self, src, header_lines=15, class_name="ConversationManager"):
        self.src = src
        self.lines = src.split("\n")
        if self.lines and self.lines[-1] == "":
            self.lines = self.lines[:-1]
        self.nlines = len(self.lines)
        self.toks, self.line_of = lex(src)
        # pseudo container: whole file after header
        self.header_lines = header_lines
        start = next(i for i, t in enumerate(self.toks) if t.line > header_lines)
        fake_open = start - 1
        top = []
        stack = []
        cur = None
        i = start
        # reuse members() by framing the top level with virtual brackets
        self.toks.insert(start, Tok("punct", "{", self.toks[start].start, self.toks[start].start, header_lines))
        self.toks.append(Tok("punct", "}", len(src), len(src), self.nlines + 1))
        top = members(src, self.toks, self.line_of, start, len(self.toks) - 1)
        self.top = top
        for m in top:
            m.trivia_line = max(m.trivia_line, header_lines + 1)
        classes = [m for m in top if m.kind == "class" and m.name == class_name]
        if len(classes) != 1:
            raise LexError("class not found once")
        self.cls = classes[0]
        o = body_open(self.toks, self.cls)
        self.class_open_line = self.toks[o].line
        self.class_close_line = self.toks[self.cls.last].line
        self.class_members = members(src, self.toks, self.line_of, o, self.cls.last)
        self.extensions = []
        for m in top:
            if m.kind == "extension":
                if m.name != class_name:
                    raise LexError("unexpected extension of " + m.name)
                eo = body_open(self.toks, m)
                header_line = self.toks[m.kw].line
                self.extensions.append((m, header_line, members(src, self.toks, self.line_of, eo, m.last)))

    def all_direct(self):
        """[(scope, member)] with scope 'class-body' or the extension header line."""
        out = [("class-body", m) for m in self.class_members]
        for blk, header, mems in self.extensions:
            out += [(header, m) for m in mems]
        return out

    def modifier_at(self, member, line, delete):
        """Absolute byte offset of the modifier `delete` (e.g. 'private ') of member on `line`."""
        want = delete.rstrip(" ")
        hits = [(ti, txt) for ti, txt in member.modifiers if txt == want and self.toks[ti].line == line]
        if len(hits) != 1:
            return None
        ti, _ = hits[0]
        off = self.toks[ti].start
        if self.src[off:off + len(delete)] != delete:
            return None
        return off
