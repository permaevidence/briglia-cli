#!/usr/bin/env python3
"""Shared paths and edit helpers for the ConversationManager split (0.2.59).

`TelegramConcierge/Services/ConversationManager.swift` is one file on every
pinned historical release and, from 0.2.59 on, the main file of a 15-file
family. Test scripts that instrument or mutate ConversationManager text use
the helpers below so they work on BOTH layouts:

- `cm_paths(tree)`: the explicitly enumerated family present in `tree` (main
  first). No glob decides membership; a partial or mixed layout is refused.
- `replace_once(tree, old, new)`: single-anchor edit. The anchor must occur
  exactly once across the whole family; the file holding it is rewritten.
- `replace_all_counted(tree, old, new, expected)`: the separately counted bulk
  rewrite (UserDefaults redirection). Every occurrence across the family is
  rewritten and the total must equal `expected`.
- `*_in(sources, ...)`: the same for an in-memory {relative path: text} map.
- `anchor_variants(decl)`: a declaration anchor in its base spelling, or with
  exactly one approved access modifier deleted, nothing else.

These helpers are for ConversationManager text only. Instrumentation of other
files keeps its own code. `python3 scripts/cm_split_paths.py --selftest` runs
the helper self-test, including the lint over the adapted scripts.
"""
import ast
import os
import re
import sys
from pathlib import Path

SERVICES = "TelegramConcierge/Services"
MAIN = SERVICES + "/ConversationManager.swift"
GROUPS = ("Channels", "Inbound", "MidTurn", "ControlCommands", "ModelCommands", "Stop", "ToolLoop",
          "Pruning", "PruneSummaries", "Ambient", "Persistence", "Archive", "BackgroundPrune", "SelftestSeams")
NAMINGS = ("conventional", "feature-first")


def split_path(group, naming):
    if group not in GROUPS:
        raise ValueError("unknown group " + repr(group))
    if naming == "conventional":
        return f"{SERVICES}/ConversationManager+{group}.swift"
    if naming == "feature-first":
        return f"{SERVICES}/{group}+ConversationManager.swift"
    raise ValueError("unknown naming " + repr(naming))


def family(naming):
    """The 15 enumerated paths of one naming, main first."""
    return [MAIN] + [split_path(g, naming) for g in GROUPS]


ALL_SPLIT_PATHS = tuple(split_path(g, n) for n in NAMINGS for g in GROUPS)


def layout(present):
    """Classify a set of relative paths: (naming or None, [family paths, main first]).

    Raises on a missing main file, a partial layout or both namings at once."""
    present = set(present)
    if MAIN not in present:
        raise RuntimeError("ConversationManager.swift is missing")
    found = {n: [p for p in family(n)[1:] if p in present] for n in NAMINGS}
    namings = [n for n in NAMINGS if found[n]]
    if len(namings) > 1:
        raise RuntimeError("mixed ConversationManager split namings: " + ", ".join(found["conventional"][:1] + found["feature-first"][:1]))
    if not namings:
        return None, [MAIN]
    naming = namings[0]
    if len(found[naming]) != len(GROUPS):
        missing = sorted(set(family(naming)[1:]) - present)
        raise RuntimeError("partial ConversationManager split layout; missing: " + ", ".join(missing))
    return naming, family(naming)


def cm_paths(tree):
    tree = Path(tree)
    present = [p for p in (MAIN,) + ALL_SPLIT_PATHS if (tree / p).is_file()]
    return layout(present)[1]


def cm_text(tree):
    """Read-only concatenation of the family (main first, then GROUPS order)."""
    return "".join((Path(tree) / p).read_text() for p in cm_paths(tree))


def _locate(texts, old):
    hits = [(p, t.count(old)) for p, t in texts if old in t]
    total = sum(c for _, c in hits)
    if total != 1:
        raise RuntimeError(f"ConversationManager anchor must occur exactly once across the family, found {total}: {old[:100]!r}")
    return hits[0][0]


def replace_once(tree, old, new):
    tree = Path(tree)
    paths = cm_paths(tree)
    texts = [(p, (tree / p).read_text()) for p in paths]
    target = _locate(texts, old)
    text = dict(texts)[target]
    i = text.index(old)  # the only occurrence across the family (checked above)
    (tree / target).write_text(text[:i] + new + text[i + len(old):])
    return target


def replace_all_counted(tree, old, new, expected):
    tree = Path(tree)
    total = 0
    for p in cm_paths(tree):
        text = (tree / p).read_text()
        n = text.count(old)
        if n:
            (tree / p).write_text(text.replace(old, new))
            total += n
    if total != expected:
        raise RuntimeError(f"bulk rewrite count {total} != expected {expected}: {old!r}")
    return total


def cm_keys(sources):
    return layout([k for k in sources if k == MAIN or k in ALL_SPLIT_PATHS])[1]


def replace_once_in(sources, old, new):
    keys = cm_keys(sources)
    target = _locate([(k, sources[k]) for k in keys], old)
    text = sources[target]
    i = text.index(old)  # the only occurrence across the family (checked above)
    sources[target] = text[:i] + new + text[i + len(old):]
    return target


def replace_all_counted_in(sources, old, new, expected):
    total = 0
    for k in cm_keys(sources):
        n = sources[k].count(old)
        if n:
            sources[k] = sources[k].replace(old, new)
            total += n
    if total != expected:
        raise RuntimeError(f"bulk rewrite count {total} != expected {expected}: {old!r}")
    return total


def main_key():
    return MAIN


def anchor_variants(decl):
    """Base spelling plus each spelling with exactly one access modifier deleted."""
    out = [decl]
    for mod in ("private(set) ", "fileprivate ", "private "):
        i = decl.find(mod)
        while i >= 0:
            # only a whole word at a token boundary
            if (i == 0 or not (decl[i - 1].isalnum() or decl[i - 1] == "_")) and not (mod == "private " and decl[i:].startswith("private(set) ")):
                v = decl[:i] + decl[i + len(mod):]
                if v not in out:
                    out.append(v)
            i = decl.find(mod, i + 1)
    return out


def replace_variant_once(tree, decl, new_suffix):
    """Insert `new_suffix` after whichever single spelling of `decl` exists (exactly one overall)."""
    tree = Path(tree)
    texts = [(p, (tree / p).read_text()) for p in cm_paths(tree)]
    def spans(t, v):
        out, i = [], t.find(v)
        while i >= 0:
            out.append((i, i + len(v)))
            i = t.find(v, i + 1)
        return out
    variants = anchor_variants(decl)
    found = []
    for p, t in texts:
        occ = [(v, a, b) for v in variants for a, b in spans(t, v)]
        # a shorter spelling inside a longer spelling's occurrence is the same declaration
        for v, a, b in occ:
            if not any((a2 <= a and b <= b2) and (a2, b2) != (a, b) for _, a2, b2 in occ):
                found.append((v, p))
    if len(found) != 1:
        raise RuntimeError(f"declaration anchor must occur in exactly one spelling, once: {decl!r} ({len(found)} found)")
    v, p = found[0]
    text = dict(texts)[p]
    (tree / p).write_text(text.replace(v, v + new_suffix))
    return p, v


def canonical(rel):
    """Scanner key: every enumerated split path is accounted as the main file."""
    return MAIN if rel in ALL_SPLIT_PATHS else rel


# ----------------------------------------------------------------------------- lint
CM_PATH_LITERAL = re.compile(r"ConversationManager(\+\w+)?\.swift|\w+\+ConversationManager\.swift")
LINTED = ("chat_lifecycle_baseline.py", "responses_lifecycle_test.py", "active_turn_compaction_test.py",
          "prune_archive_owner_test.py", "background_archive_inline_test.py", "keep_summaries_mutation_test.py",
          "bg_prune_behaviour_mutation_test.py", "chat_persistence_contract.py", "model_request_scan.py",
          "private_storage_scan.py")
# Append-only uses of the main path (seams are appended to the main file).
APPEND_ONLY_HELPERS = {"main_path", "main_key"}


def main_path(tree):
    return Path(tree) / MAIN


# Read sources whose text is ConversationManager text (or a path to it).
TAINT_SOURCES = APPEND_ONLY_HELPERS | {"MAIN", "cm_text", "cm_paths", "cm_keys"}
# Text-mutating methods/functions that must go through the helpers.
MUTATORS = {"replace", "sub", "subn"}


def _mentions(node):
    return {n.id for n in ast.walk(node) if isinstance(n, ast.Name)} | {n.attr for n in ast.walk(node) if isinstance(n, ast.Attribute)}


def _target_names(t):
    if isinstance(t, ast.Name):
        return [t.id]
    if isinstance(t, (ast.Tuple, ast.List)):
        return [n for e in t.elts for n in _target_names(e)]
    if isinstance(t, ast.Starred):
        return _target_names(t.value)
    return []


def lint_source(name, source):
    """Problems: a ConversationManager path literal outside comments, or any
    text mutation whose subject derives from ConversationManager text.

    Taint starts at `main_path`, `main_key`, `MAIN`, `cm_text`, `cm_paths` and
    `cm_keys`. It is tracked in source order per scope: assignments, augmented
    assignments, walrus, `for`/comprehension targets and `with ... as` taint
    their names when the bound value is tainted and clear them when it is not
    (a rebinding to unrelated text is not CM text). Branches are merged as
    "tainted on any path"; loop bodies run to a fixed point; a function body
    starts from the enclosing taint with its parameters cleared. Flagged on a
    tainted subject: any `.replace` / `.sub` / `.subn` attribute, called OR
    merely bound (e.g. `r = s.replace`), `getattr(x, "replace"|"sub"|"subn")`,
    and the unbound forms `str.replace(x, ...)` / `re.sub(p, r, x)` /
    `pattern.sub(r, x)` where any argument is tainted.
    Not covered (documented limit): taint through function return values,
    containers filled elsewhere, attributes of other objects, `eval`/`exec`.
    The immutable C1->C2 checker stays the proof for the split itself."""
    problems = []
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and CM_PATH_LITERAL.search(node.value):
            problems.append(f"{name}:{node.lineno}: ConversationManager path literal (use cm_split_paths)")

    def is_tainted(node, tainted):
        return bool(_mentions(node) & (tainted | TAINT_SOURCES))

    def bind(target, value_tainted, tainted):
        for n in _target_names(target):
            if value_tainted:
                tainted.add(n)
            else:
                tainted.discard(n)

    def check_expr(expr, tainted):
        """Flag mutations in one expression; comprehension/walrus targets bound
        inside it are tainted locally (fixed point). Returns walrus bindings."""
        local = set(tainted)
        changed = True
        while changed:
            changed = False
            for node in ast.walk(expr):
                pair = None
                if isinstance(node, ast.comprehension):
                    pair = (node.target, node.iter)
                elif isinstance(node, ast.NamedExpr):
                    pair = (node.target, node.value)
                if pair and is_tainted(pair[1], local):
                    for n in _target_names(pair[0]):
                        if n not in local:
                            local.add(n); changed = True
        for node in ast.walk(expr):
            hit = False
            if isinstance(node, ast.Attribute) and node.attr in MUTATORS and is_tainted(node.value, local):
                hit = True  # bound or called method on tainted text (e.g. `r = s.replace`)
            if isinstance(node, ast.Call):
                f = node.func
                if (isinstance(f, ast.Name) and f.id == "getattr" and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant)
                        and node.args[1].value in MUTATORS and is_tainted(node.args[0], local)):
                    hit = True
                if isinstance(f, ast.Attribute) and f.attr in MUTATORS and any(is_tainted(x, local) for x in list(node.args) + [k.value for k in node.keywords]):
                    hit = True  # str.replace(text, ...), re.sub(p, r, text), pattern.sub(r, text)
            if hit:
                problems.append(f"{name}:{node.lineno}: text mutation on ConversationManager text outside the helpers")
        walrus = {}
        for node in ast.walk(expr):
            if isinstance(node, ast.NamedExpr):
                walrus[node.target.id] = is_tainted(node.value, local)
        return walrus

    def header_exprs(stmt):
        out = []
        for field, value in ast.iter_fields(stmt):
            if field in ("body", "orelse", "finalbody", "handlers", "cases", "decorator_list", "args", "returns", "type_params"):
                continue
            if isinstance(value, ast.AST) and not isinstance(value, (ast.stmt, ast.expr_context, ast.withitem)):
                out.append(value)
            elif isinstance(value, list):
                out += [v for v in value if isinstance(v, ast.expr)]
        return out

    def run(stmts, tainted):
        for stmt in stmts:
            if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                for d in stmt.decorator_list:
                    check_expr(d, tainted)
                inner = set(tainted)
                for arg in ast.walk(stmt.args):
                    if isinstance(arg, ast.arg):
                        inner.discard(arg.arg)
                for d in stmt.args.defaults + [d for d in stmt.args.kw_defaults if d is not None]:
                    check_expr(d, tainted)
                run(stmt.body, inner)
                tainted.discard(stmt.name)
                continue
            if isinstance(stmt, ast.ClassDef):
                run(stmt.body, set(tainted))
                tainted.discard(stmt.name)
                continue
            for e in header_exprs(stmt):
                for n, t in check_expr(e, tainted).items():
                    bind(ast.Name(id=n), t, tainted)
            if isinstance(stmt, ast.Assign):
                t = is_tainted(stmt.value, tainted)
                for target in stmt.targets:
                    bind(target, t, tainted)
            elif isinstance(stmt, ast.AnnAssign):
                if stmt.value is not None:
                    bind(stmt.target, is_tainted(stmt.value, tainted), tainted)
            elif isinstance(stmt, ast.AugAssign):
                if is_tainted(stmt.value, tainted):
                    bind(stmt.target, True, tainted)
            elif isinstance(stmt, (ast.For, ast.AsyncFor, ast.While)):
                if isinstance(stmt, (ast.For, ast.AsyncFor)):
                    bind(stmt.target, is_tainted(stmt.iter, tainted), tainted)
                before = None
                body = set(tainted)
                while before != body:  # loop body to a fixed point (taint only grows here)
                    before = set(body)
                    trial = set(body)
                    run(stmt.body, trial)
                    body |= trial
                tainted |= body
                run(stmt.orelse, tainted)
            elif isinstance(stmt, (ast.With, ast.AsyncWith)):
                for item in stmt.items:
                    check_expr(item.context_expr, tainted)
                    if item.optional_vars is not None:
                        bind(item.optional_vars, is_tainted(item.context_expr, tainted), tainted)
                run(stmt.body, tainted)
            elif isinstance(stmt, ast.If):
                a, b = set(tainted), set(tainted)
                run(stmt.body, a); run(stmt.orelse, b)
                tainted.clear(); tainted |= a | b
            elif isinstance(stmt, (ast.Try, getattr(ast, "TryStar", ast.Try))):
                branches = []
                body = set(tainted); run(stmt.body, body); branches.append(body)
                for h in stmt.handlers:
                    hb = set(tainted) | body; run(h.body, hb); branches.append(hb)
                ob = set(body); run(stmt.orelse, ob); branches.append(ob)
                merged = set().union(*branches)
                run(stmt.finalbody, merged)
                tainted.clear(); tainted |= merged
            elif isinstance(stmt, getattr(ast, "Match", ())):
                merged = set(tainted)
                for case in stmt.cases:
                    c = set(tainted); run(case.body, c); merged |= c
                tainted.clear(); tainted |= merged

    # Two passes so module-level names bound after a function definition are
    # visible inside it (functions run later); findings are de-duplicated.
    module_taint = set()
    run(tree.body, module_taint)
    run(tree.body, set(module_taint))
    return sorted(set(problems))


def lint(root):
    out = []
    for name in LINTED:
        out += lint_source(name, (Path(root) / "scripts" / name).read_text())
    return out


def _selftest():
    import tempfile
    failures = []

    def check(label, ok):
        print(("✔ " if ok else "✖ ") + label)
        if not ok:
            failures.append(label)

    def raises(fn):
        try:
            fn()
        except RuntimeError:
            return True
        return False

    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        (t / SERVICES).mkdir(parents=True)
        (t / MAIN).write_text("A\nprivate func foo() {}\nUserDefaults.standard\n")
        check("unsplit tree: family is the main file only", cm_paths(t) == [MAIN])
        for g in GROUPS:
            (t / split_path(g, "conventional")).write_text(f"// {g}\n")
        (t / split_path("ToolLoop", "conventional")).write_text("B\nfunc bar() {}\nUserDefaults.standard\n")
        check("split tree: 15 enumerated paths, main first", cm_paths(t) == family("conventional"))
        check("replace_once edits the file that holds the anchor",
              replace_once(t, "func bar() {}", "func bar() { x }") == split_path("ToolLoop", "conventional")
              and "x" in (t / split_path("ToolLoop", "conventional")).read_text())
        check("replace_once: a replacement that is a prefix of the anchor (deletion) splices exactly once",
              replace_once(t, "func bar() { x }", "func bar() {") and "func bar() {\n" in (t / split_path("ToolLoop", "conventional")).read_text()
              and "{ x }" not in (t / split_path("ToolLoop", "conventional")).read_text())
        check("replace_once: an empty replacement deletes the single occurrence",
              replace_once(t, "B\n", "") and not (t / split_path("ToolLoop", "conventional")).read_text().startswith("B"))
        check("replace_once refuses an anchor present twice across files",
              raises(lambda: replace_once(t, "UserDefaults.standard", "Z")))
        check("replace_once refuses a missing anchor", raises(lambda: replace_once(t, "nothing here", "Z")))
        check("replace_all_counted rewrites across the family with the exact total",
              replace_all_counted(t, "UserDefaults.standard", "P.defaults", 2) == 2)
        check("replace_all_counted refuses a wrong total", raises(lambda: replace_all_counted(t, "P.defaults", "Q", 3)))
        check("replace_variant_once finds the promoted spelling",
              replace_variant_once(t, "private func foo() {", "\n  hook()")[1] == "private func foo() {")
        (t / MAIN).write_text("func foo() {\n")
        check("replace_variant_once finds the base spelling after promotion",
              replace_variant_once(t, "private func foo() {", "\n  hook()")[1] == "func foo() {")
        (t / split_path("Stop", "feature-first")).write_text("")
        check("mixed namings refused", raises(lambda: cm_paths(t)))
        (t / split_path("Stop", "feature-first")).unlink()
        (t / split_path("Stop", "conventional")).unlink()
        check("partial layout refused", raises(lambda: cm_paths(t)))
        sources = {MAIN: "one\n", "TelegramConcierge/CLI/X.swift": "one\n"}
        check("replace_once_in ignores non-family files", replace_once_in(sources, "one", "two") == MAIN and sources["TelegramConcierge/CLI/X.swift"] == "one\n")
    check("anchor_variants: base + one deletion only",
          anchor_variants("    private func a(_ x: Int) {") == ["    private func a(_ x: Int) {", "    func a(_ x: Int) {"])
    check("anchor_variants: private(set) deleted whole",
          anchor_variants("    @Published private(set) var x = 1") == ["    @Published private(set) var x = 1", "    @Published var x = 1"])
    check("canonical maps split paths to main", canonical(split_path("Archive", "feature-first")) == MAIN and canonical("X.swift") == "X.swift")
    bad = 'p = "TelegramConcierge/Services/ConversationManager+Stop.swift"\n'
    check("lint: path literal flagged", bool(lint_source("bad.py", bad)))
    bad2 = "m = main_path(tree)\ns = m.read_text()\nm.write_text(s.replace('a', 'b'))\n"
    check("lint: .replace on main-path text flagged (taint)", bool(lint_source("bad2.py", bad2)))
    bad3 = "m = main_path(tree)\nr = getattr(m.read_text(), 'replace')\n"
    check("lint: getattr replace flagged", bool(lint_source("bad3.py", bad3)))
    # Codex implementation-review note 1 (2026-10-22): the two indirect forms it found.
    bad4 = "m = cmp.main_path(tree)\ns = m.read_text()\nr = s.replace\nr('a', 'b')\n"
    check("lint: bound .replace method on main-path text flagged", bool(lint_source("bad4.py", bad4)))
    bad5 = "s = cmp.cm_text(tree)\ns = s.replace('a', 'b')\n"
    check("lint: .replace on cm_text() text flagged", bool(lint_source("bad5.py", bad5)))
    bad6 = "s = cmp.cm_text(tree)\nt = str.replace(s, 'a', 'b')\n"
    check("lint: unbound str.replace on cm_text() text flagged", bool(lint_source("bad6.py", bad6)))
    bad7 = "import re\ns = cmp.cm_text(tree)\nt = re.sub('a', 'b', s)\n"
    check("lint: re.sub on cm_text() text flagged", bool(lint_source("bad7.py", bad7)))
    bad8 = "for p in cmp.cm_paths(t):\n    x = open(p).read()\n    open(p, 'w').write(x.replace('a', 'b'))\n"
    check("lint: .replace on text read via a cm_paths() loop flagged", bool(lint_source("bad8.py", bad8)))
    bad9 = "with open(cmp.main_path(t)) as f:\n    g = getattr(f.read(), 'sub')\n"
    check("lint: getattr sub via with-as flagged", bool(lint_source("bad9.py", bad9)))
    ok2 = "s = cmp.cm_text(tree)\nif 'x' in s:\n    pass\nother = 'abc'.replace('a', 'b')\n"
    check("lint: read-only cm_text use and unrelated replace pass", not lint_source("ok2.py", ok2))
    ok3 = "for path in (cmp.main_path(t), other):\n    pass\nfor path in t.rglob('*.swift'):\n    path.write_text(path.read_text().replace('a', 'b'))\n"
    check("lint: a name rebound to unrelated files is no longer tainted", not lint_source("ok3.py", ok3))
    ok4 = "def replace(path, old, new):\n    path.write_text(path.read_text().replace(old, new))\nfor path in (cmp.main_path(t),):\n    pass\n"
    check("lint: function parameters start untainted", not lint_source("ok4.py", ok4))
    bad10 = "def edit():\n    TEXT.replace('a', 'b')\nTEXT = cmp.cm_text(t)\n"
    check("lint: module-level CM text mutated inside a function flagged", bool(lint_source("bad10.py", bad10)))
    bad11 = "if cond:\n    s = cmp.cm_text(t)\nelse:\n    s = ''\nfix = s.replace\n"
    check("lint: taint on any branch survives the merge", bool(lint_source("bad11.py", bad11)))
    # Deliberate breaks injected into the real adapted scripts must be caught.
    for script, inject in (("chat_lifecycle_baseline.py", "\n_r = cmp.main_path(ROOT).read_text().replace\n"),
                           ("active_turn_compaction_test.py", "\n_s = cmp.cm_text(ROOT)\n_s = _s.replace('a', 'b')\n")):
        text = (root / "scripts" / script).read_text() + inject
        check(f"lint: deliberate break appended to {script} flagged", bool(lint_source(script, text)))
    ok = "m = main_path(tree)\nm.write_text(m.read_text() + seam)\n"
    check("lint: append-only seam use passes", not lint_source("ok.py", ok))
    problems = lint(root)
    check("lint: adapted scripts clean" + ("" if not problems else " — " + "; ".join(problems)), not problems)
    print(f"\ncm_split_paths selftest: {'PASS' if not failures else 'FAIL ' + str(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(_selftest())
    print(__doc__)
