#!/usr/bin/env python3
"""Self-test of cm_split_check.py (plan v3 §7): inventory validation against the
real base, lexer cases, and deliberate breaks. Every break must fail with its
own stated check id; the positive layouts must pass. Run through
`cm_split_check.py --selftest [--c1 SHA] [--c2 SHA]`.

Layouts:
- the committed representative layout `scripts/fixtures/cm-split/selftest-layout.json`
  (a small non-empty split of the real base: every file non-empty, a mixed file
  whose existing extension carries an approved promotion, a `private(set)`
  edit, retained stored statics, whole moved extensions, real seam references),
  with its own fixed reviewed edit list;
- from C2 on, the real manifest against the C1 reviewed list.
"""
import copy
import hashlib
import json
import sys

import cm_split_paths as P
import cm_split_swift as S


def run_selftest(C, base, c1, c2):
    results = []

    def check(label, ok, detail=""):
        results.append(ok)
        print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + str(detail)[:400]), flush=True)

    # ------------------------------------------------------------------ inventory
    inv = base.inv
    cm = inv.class_members
    kinds = {}
    for m in cm:
        kinds.setdefault(C.member_kind(m), []).append(m)
    by = {}
    for m in cm:
        by.setdefault(m.name, []).append(m)

    def one(name):
        return by[name][0]
    check("inventory: 152 stored instance properties", len(kinds.get("stored-property", [])) == 152, len(kinds.get("stored-property", [])))
    check("inventory: 45 stored static properties", len(kinds.get("static-stored-property", [])) == 45, len(kinds.get("static-stored-property", [])))
    check("inventory: 2 computed static properties (telegramAPIBase 5234, triageLaneCooldownSeconds 12701)",
          sorted((m.name, m.start_line) for m in kinds.get("static-computed-property", [])) == [("telegramAPIBase", 5234), ("triageLaneCooldownSeconds", 12701)],
          [(m.name, m.start_line) for m in kinds.get("static-computed-property", [])])
    check("inventory: one init (1491) and no deinit", [m.start_line for m in kinds.get("init", [])] == [1491] and not kinds.get("deinit"))
    check("inventory: class body 18..15517; extension headers 15587 16006 16231 16334 16382 16423 16464",
          inv.class_open_line == 18 and inv.class_close_line == 15517 and [h for _, h, _ in inv.extensions] == [15587, 16006, 16231, 16334, 16382, 16423, 16464])
    check("classification: observer-bearing `activeRunId` (didSet) is stored", C.member_kind(one("activeRunId")) == "stored-property")
    check("classification: `@Published private(set) var lastPromptTokens` with didSet is stored", C.member_kind(one("lastPromptTokens")) == "stored-property")
    check("classification: closure-initialized `appFolder` is stored", C.member_kind(one("appFolder")) == "stored-property")
    check("classification: `@TaskLocal private static var commandCapture` is a stored static",
          C.member_kind(one("commandCapture")) == "static-stored-property")
    check("classification: `nonisolated(unsafe) static var openStagesProviderForTesting` is a stored static",
          C.member_kind(one("openStagesProviderForTesting")) == "static-stored-property")
    check("classification: `subscriptionLoginInProgress { … }` is computed", C.member_kind(one("subscriptionLoginInProgress")) == "computed-property")
    check("classification: `nonisolated static func copyRegularFile` is a static func", C.member_kind(one("copyRegularFile")) == "static-func")
    check("classification: `@Published var messages` (line 19) is stored and starts the body",
          cm[0].name == "messages" and cm[0].trivia_line == 19 and C.member_kind(cm[0]) == "stored-property")
    ext_members = {(h, m.name): m for _, h, mems in inv.extensions for m in mems}
    want = [(15587, "recordDeliveredUserMessages", 15588), (15587, "writeTurnCheckpoint", 15596), (15587, "recordCompactionCalibration", 15643),
            (15587, "compactActiveTurn", 15661), (15587, "summarizeActivePrefix", 15783), (15587, "boundInterruptedCheckpoint", 15932),
            (15587, "discardTurnRecoveryForReplacement", 15949), (15587, "preserveInterruptedCheckpoint", 15961),
            (15587, "recoverTurnCheckpoint", 15979), (16464, "promptMeasurement", 17432)]
    check("inventory: the ten existing-extension members of plan §4 with their scopes and lines",
          all((h, n) in ext_members and inv.toks[ext_members[(h, n)].kw].line == ln for h, n, ln in want))
    # member extents tile the class body exactly
    tiles = all(cm[i].end_line + 1 == cm[i + 1].trivia_line for i in range(len(cm) - 1)) and cm[0].trivia_line == 19
    check("inventory: class members tile the body without gaps (trivia → next member)", tiles)

    # ------------------------------------------------------------------ lexer
    src = 'let a = "x \\(foo) y"\nlet b = #"raw \\#(bar) \\(notcode)"#\nlet c = """\n  m \\(baz)\n  """\n// qux\n/* /* quux */ */\n'
    toks, _ = S.lex(src)
    ids = {t.text for t in toks if t.kind == "id"}
    check("lexer: interpolations are code (ordinary, raw `\\#(`, multiline); raw `\\(` is text; comments skipped",
          {"foo", "bar", "baz"} <= ids and "notcode" not in ids and "qux" not in ids and "quux" not in ids, sorted(ids))
    check("lexer: interpolation tokens are marked", all(t.interp for t in toks if t.text in ("foo", "bar", "baz")))

    # ------------------------------------------------------------------ representative layout
    root = C.ROOT
    if c1:
        c1_files = C.commit_files(c1)
        layout = json.loads(C.git_blob(c1, C.LAYOUT_REL))
        seam_blobs = C.seam_blobs_of(c1)
    else:
        c1_files = C.tree_files(root)
        for rel in list(c1_files):
            if rel in P.ALL_SPLIT_PATHS or rel == C.MANIFEST_REL:
                del c1_files[rel]
        c1_files[P.MAIN] = base.raw
        layout = json.loads((root / C.LAYOUT_REL).read_text())
        seam_blobs = {rel: hashlib.sha1(b"blob %d\0" % len(c1_files[rel]) + c1_files[rel]).hexdigest() for rel in C.SEAM_FILES}
    lay_man, lay_reviewed = layout["manifest"], layout["reviewed_access_edits"]

    def candidate(man, extra=None, drop=()):
        files = {k: v for k, v in c1_files.items() if k != P.MAIN and k not in drop}
        files.update(C.construct(base, man))
        files[C.MANIFEST_REL] = json.dumps(man, indent=1).encode()
        if extra:
            files.update(extra)
        return files

    def changed_for(man, extra=()):
        return P.family(man["naming"]) + [C.MANIFEST_REL] + list(extra)

    def attempt(man, reviewed, files=None, changed=None, bytes_manifest=None):
        files = candidate(man) if files is None else files
        mb = bytes_manifest if bytes_manifest is not None else files.get(C.MANIFEST_REL, json.dumps(man).encode())
        try:
            C.run_checks(base, C.Candidate(files, mb), reviewed, c1_files, changed if changed is not None else changed_for(man), seam_blobs)
            return None
        except C.CheckFailure as e:
            return e

    def passes(label, man, reviewed, **kw):
        e = attempt(man, reviewed, **kw)
        check(label, e is None, e)

    def breaks(label, expect, man, reviewed, **kw):
        e = attempt(man, reviewed, **kw)
        ok = e is not None and e.check in (expect if isinstance(expect, tuple) else (expect,))
        check("break: " + label + f" → [{expect if isinstance(expect, str) else '|'.join(expect)}]", ok, e if e is not None else "PASSED (break not caught)")

    for name, man, reviewed in [("representative layout", lay_man, lay_reviewed)] + (
            [("real manifest (C2)", json.loads(C.git_blob(c2, C.MANIFEST_REL)), C.reviewed_from(c1))] if c2 else []):
        print(f"\n— breaks on the {name} —")
        passes(f"{name}: passes unmodified (incl. approved existing-extension promotions and real seam references)", man, reviewed)
        files0 = candidate(man)
        fam = P.family(man["naming"])
        split_files = [f for f in man["files"] if f["role"] == "split"]
        f_cb = next(f for f in split_files if f["class_body_ranges"])
        f_ext = next(f for f in split_files if f["extension_ranges"])
        path_cb = f_cb["path"]

        def mutate_bytes(path, fn):
            files = dict(files0)
            files[path] = fn(files[path].decode()).encode()
            return files
        lines_of = lambda t: t.split("\n")
        # --- byte breaks
        def one_char(t):
            ls = t.split("\n")
            k = 16 + 1 + 1  # header (15) + opener, then the second moved line
            ls[k] = ls[k] + "x" if ls[k] else "x"
            return "\n".join(ls)
        breaks("one-character edit inside a moved range", "4", man, reviewed, files=mutate_bytes(path_cb, one_char))
        def swap_first_two_ranges(t):
            a, b = f_cb["class_body_ranges"][0], f_cb["class_body_ranges"][1] if len(f_cb["class_body_ranges"]) > 1 else None
            ls = t.split("\n")
            if b is None:
                return t.replace("\n", "\n\n", 1)
            h = 16
            ra = ls[h:h + (a[1] - a[0] + 1)]
            rb = ls[h + (a[1] - a[0] + 1):h + (a[1] - a[0] + 1) + (b[1] - b[0] + 1)]
            return "\n".join(ls[:h] + rb + ra + ls[h + len(ra) + len(rb):])
        breaks("swapped ranges", "4", man, reviewed, files=mutate_bytes(path_cb, swap_first_two_ranges))
        breaks("dropped line", "4", man, reviewed, files=mutate_bytes(path_cb, lambda t: "\n".join(lines_of(t)[:20] + lines_of(t)[21:])))
        breaks("duplicated line", "4", man, reviewed, files=mutate_bytes(path_cb, lambda t: "\n".join(lines_of(t)[:20] + [lines_of(t)[20]] + lines_of(t)[20:])))
        breaks("whitespace added in a generated wrapper", "4", man, reviewed,
               files=mutate_bytes(path_cb, lambda t: t.replace(C.OPENER, "extension ConversationManager  {\n", 1)))
        # Either reason is legitimate: the declaration inventory (7) also sees members vanish into the nested block.
        breaks("nested generated extensions", ("4", "7"), man, reviewed,
               files=mutate_bytes(path_cb, lambda t: t.replace(C.OPENER, C.OPENER + C.OPENER, 1) + C.CLOSER))
        if f_cb["extension_ranges"] or f_ext["class_body_ranges"]:
            mixed = f_cb if f_cb["extension_ranges"] else f_ext
            def ext_first(t, mixed=mixed):
                h = base.header
                body = t[len(h):]
                i = body.index("\n" + C.CLOSER) + 1 + len(C.CLOSER)
                return h + body[i:] + body[:i]
            breaks("class-body range placed after an extension range (mixed file)", "4", man, reviewed, files=mutate_bytes(mixed["path"], ext_first))
        edit_main = [e for e in man["access_edits"] if all(not (a <= e["line"] <= b) for f in split_files for k in ("class_body_ranges", "extension_ranges") for a, b in f[k])]
        if edit_main:
            e0 = edit_main[0]
            def extra_byte(t, e0=e0):
                ls = lines_of(t)
                target = base.lines[e0["line"] - 1].replace(e0["delete"], "", 1)
                i = ls.index(target)
                ls[i] = ls[i].replace(" ", "", 1) if ls[i].startswith(" ") else ls[i][1:]
                return "\n".join(ls)
            breaks("an edit deleting the modifier plus another byte", "4", man, reviewed, files=mutate_bytes(P.MAIN, extra_byte))
            def not_deleted(t, e0=e0):
                target = base.lines[e0["line"] - 1].replace(e0["delete"], "", 1)
                return t.replace(target + "\n", base.lines[e0["line"] - 1] + "\n", 1)
            breaks("a listed edit not applied in the candidate", "4", man, reviewed, files=mutate_bytes(P.MAIN, not_deleted))
        ext_edit = [e for e in man["access_edits"] if e["scope"] != "class-body"]
        if ext_edit:
            e1 = ext_edit[0]
            home = next(f["path"] for f in split_files for a, b in f["extension_ranges"] if a <= e1["line"] <= b)
            def ext_extra(t, e1=e1):
                target = base.lines[e1["line"] - 1].replace(e1["delete"], "", 1)
                return t.replace(target + "\n", target.replace("func ", "func  ", 1) + "\n", 1)
            breaks("unauthorized edit of an existing-extension member: another byte", "4", man, reviewed, files=mutate_bytes(home, ext_extra))
        # --- structural manifest breaks (candidate rebuilt from the mutated manifest)
        def mm(fn):
            m2 = copy.deepcopy(man)
            fn(m2)
            return m2

        def rebuilt(label, expect, fn, reviewed_fn=None):
            m2 = mm(fn)
            r2 = copy.deepcopy(reviewed)
            if reviewed_fn:
                reviewed_fn(r2)
            try:
                files = candidate(m2)
            except C.CheckFailure as e:
                ok = e.check in (expect if isinstance(expect, tuple) else (expect,))
                check("break: " + label + f" → [{expect if isinstance(expect, str) else '|'.join(expect)}]", ok, e)
                return
            breaks(label, expect, m2, r2, files=files)

        def mbreak(label, fn, expect="manifest", reviewed_fn=None):
            m2 = mm(fn)
            r2 = copy.deepcopy(reviewed)
            if reviewed_fn:
                reviewed_fn(r2)
            breaks(label, expect, m2, r2, files=dict(files0, **{C.MANIFEST_REL: json.dumps(m2).encode()}), bytes_manifest=json.dumps(m2).encode())
        units = base.class_units()
        def unit_of(kind):
            return next((a, b, m) for a, b, m in units if C.member_kind(m) == kind)
        def add_range(m2, r, path=path_cb, key="class_body_ranges"):
            f = next(f for f in m2["files"] if f["path"] == path)
            rs = [x for x in f[key]] + [list(r)]
            # remove r from any other file
            for g in m2["files"]:
                for k in ("class_body_ranges", "extension_ranges"):
                    g[k] = [x for x in g[k] if not (x[0] <= r[0] and r[1] <= x[1])]
            f[key] = sorted(rs)
        a, b, m = unit_of("stored-property")
        rebuilt("a stored instance property moved out", "3", lambda m2: add_range(m2, (a, b)))
        a, b, m = unit_of("static-stored-property")
        rebuilt("a stored static property moved out", "3", lambda m2: add_range(m2, (a, b)))
        a, b, m = next((a, b, m) for a, b, m in units if m.kind in ("struct", "enum"))
        rebuilt("a nested type moved out", "3", lambda m2: add_range(m2, (a, b)))
        rebuilt("the class-closing brace moved", ("2", "3"), lambda m2: add_range(m2, (15517, 15517)))
        mv = f_cb["class_body_ranges"][0]
        rebuilt("a partial member at a range edge", "2", lambda m2: next(f for f in m2["files"] if f["path"] == path_cb)["class_body_ranges"].__setitem__(0, [mv[0] + 1, mv[1]]))
        er = f_ext["extension_ranges"][0]
        rebuilt("an existing extension block split", "2", lambda m2: next(f for f in m2["files"] if f["path"] == f_ext["path"])["extension_ranges"].__setitem__(0, [er[0], er[0] + 5]))
        # --- access-edit breaks
        def add_edit(e):
            return lambda lst: (lst.append(e), lst.sort(key=lambda x: (x["line"], x["name"])))
        promoted = {e["name"] for e in man["access_edits"]}
        # an unlisted private class member referenced from another file textually
        tok = {p: {t.text.lstrip("$") for t in S.lex(files0[p].decode())[0] if t.kind == "id"} for p in fam}
        line_home = {n: f["path"] for f in man["files"] for k in ("class_body_ranges", "extension_ranges") for a2, b2 in f[k] for n in range(a2, b2 + 1)}
        cand_same = None
        for scope, mbr in base.direct():
            if mbr.name in promoted or scope != "class-body":
                continue
            mods = [(ti, t) for ti, t in mbr.modifiers if t == "private"]
            if len(mods) != 1:
                continue
            ln = inv.toks[mods[0][0]].line
            home = line_home.get(ln, P.MAIN)
            users = sorted(p for p in fam if p != home and mbr.name in tok[p])
            if users:
                cand_same = {"line": ln, "name": mbr.name, "member_kind": C.member_kind(mbr), "scope": "class-body", "delete": "private ", "reason": {"type": "cross-file", "files": users}}
                break
        if cand_same:
            mbreak("an unrelated same-name identifier (textual evidence exists, compiler never required it): manifest-only edit",
                   lambda m2: add_edit(cand_same)(m2["access_edits"]), "6-reviewed")
        nonexist = {"line": 20, "name": "noSuchMember", "member_kind": "stored-property", "scope": "class-body", "delete": "private ", "reason": {"type": "cross-file", "files": [fam[1]]}}
        mbreak("wrong reason: a nonexistent name (manifest only)", lambda m2: add_edit(nonexist)(m2["access_edits"]), "6-reviewed")
        rebuilt("wrong reason: a nonexistent name (also in a corrupted reference)", "6-edit",
                lambda m2: add_edit(nonexist)(m2["access_edits"]), lambda r2: add_edit(nonexist)(r2))
        e_any = man["access_edits"][0]
        mbreak("a removed edit (manifest only)", lambda m2: m2["access_edits"].pop(0), "6-reviewed")
        rebuilt("a duplicated edit", "manifest", lambda m2: m2["access_edits"].insert(0, copy.deepcopy(e_any)))
        def wrong_files(lst):
            for e in lst:
                if e["reason"]["type"] == "cross-file":
                    home = line_home.get(e["line"], P.MAIN)
                    nofile = [p for p in fam if p != home and e["name"] not in tok[p]]
                    if nofile:
                        e["reason"]["files"] = sorted([nofile[0]]); return
        rebuilt("a reason naming a file without a reference (also in the reference)", "6-reason",
                lambda m2: wrong_files(m2["access_edits"]), lambda r2: wrong_files(r2))
        def changed_reason(lst):
            for e in lst:
                if e["reason"]["type"] == "cross-file" and len(e["reason"]["files"]) > 1:
                    e["reason"]["files"] = e["reason"]["files"][:1]; return
            lst[0]["reason"] = {"type": "test-seam", "seam": C.SEAM_FILES[0]}
        mbreak("a candidate edit's reason changed (reference fixed)", lambda m2: changed_reason(m2["access_edits"]), "6-reviewed")
        # nested-type member
        nested = None
        for a2, b2, mbr in units:
            if mbr.kind in ("struct", "enum", "class"):
                o = S.body_open(inv.toks, mbr)
                for sub in S.members(base.text, inv.toks, None, o, mbr.last):
                    if any(t == "private" for _, t in sub.modifiers):
                        ti = next(ti for ti, t in sub.modifiers if t == "private")
                        nested = {"line": inv.toks[ti].line, "name": sub.name, "member_kind": C.member_kind(sub), "scope": "class-body", "delete": "private ", "reason": {"type": "cross-file", "files": [fam[1]]}}
                        break
            if nested:
                break
        if nested:
            rebuilt("an edit on a nested-type member (in both lists)", "6-edit",
                    lambda m2: add_edit(nested)(m2["access_edits"]), lambda r2: add_edit(nested)(r2))
        if ext_edit:
            def wrong_scope(lst):
                for e in lst:
                    if e["scope"] != "class-body":
                        e["scope"] = {"extension": 16464 if e["scope"]["extension"] != 16464 else 15587}; return
            rebuilt("an edit whose scope names the wrong block (in both lists)", ("6-edit", "6-scope"),
                    lambda m2: wrong_scope(m2["access_edits"]), lambda r2: wrong_scope(r2))
            def scope_as_class(lst):
                for e in lst:
                    if e["scope"] != "class-body":
                        e["scope"] = "class-body"; return
            mbreak("a changed scope (manifest only)", lambda m2: scope_as_class(m2["access_edits"]), "6-reviewed")
            unlisted_ext = None
            for _, h, mems in inv.extensions:
                for mbr in mems:
                    mods = [(ti, t) for ti, t in mbr.modifiers if t == "private"]
                    if mbr.name not in promoted and len(mods) == 1:
                        unlisted_ext = {"line": inv.toks[mods[0][0]].line, "name": mbr.name, "member_kind": C.member_kind(mbr), "scope": {"extension": h}, "delete": "private ", "reason": {"type": "cross-file", "files": [fam[1]]}}
                        break
                if unlisted_ext:
                    break
            if unlisted_ext:
                mbreak("unauthorized edit of an existing-extension member not in the reviewed list (manifest only)",
                       lambda m2: add_edit(unlisted_ext)(m2["access_edits"]), "6-reviewed")
                rebuilt("unauthorized edit of an existing-extension member applied in the candidate (in both lists, no textual evidence)",
                        ("6-reason", "6-edit"), lambda m2: add_edit(dict(unlisted_ext, reason={"type": "cross-file", "files": [p for p in fam if p != next((f["path"] for f in m2["files"] for a2, b2 in f["extension_ranges"] if a2 <= unlisted_ext["line"] <= b2), P.MAIN) and unlisted_ext["name"] not in tok[p]][:1]}))(m2["access_edits"]),
                        lambda r2: add_edit(dict(unlisted_ext, reason={"type": "cross-file", "files": [p for p in fam if p != next((f["path"] for f in man["files"] for a2, b2 in f["extension_ranges"] if a2 <= unlisted_ext["line"] <= b2), P.MAIN) and unlisted_ext["name"] not in tok[p]][:1]}))(r2))
        # --- check 7
        p0 = sorted(promoted)[0]
        cli = "TelegramConcierge/CLI/ZZSplitBreak.swift"
        breaks("a new module top-level declaration of a promoted name", "7", man, reviewed,
               files=dict(files0, **{cli: f"func {p0}() {{}}\n".encode()}), changed=changed_for(man, [cli]))
        breaks("an unapproved `extension ConversationManager` file", "7", man, reviewed,
               files=dict(files0, **{cli: b"extension ConversationManager {\n    func zzUnapproved() {}\n}\n"}), changed=changed_for(man, [cli]))
        breaks("a promoted name declared in an unapproved extension file", "7", man, reviewed,
               files=dict(files0, **{cli: f"extension ConversationManager {{\n    func {p0}(zz: Int) {{}}\n}}\n".encode()}), changed=changed_for(man, [cli]))
        seam = C.SEAM_FILES[3]
        breaks("a new declaration of a promoted name in a seam file", "7", man, reviewed,
               files=dict(files0, **{seam: files0[seam] + f"\nextension ConversationManager {{\n    func {p0}(zz: Int) {{}}\n}}\n".encode()}), changed=changed_for(man, [seam]))
        breaks("a changed seam blob", "7", man, reviewed,
               files=dict(files0, **{seam: files0[seam] + b"\n// changed\n"}), changed=changed_for(man, [seam]))
        # second declaration (new overload) across the 15 files
        def add_overload(t):
            return t.rstrip("\n") + f"\n\nextension ConversationManager {{\n    func {p0}(zzOverload: Int) {{}}\n}}\n"
        breaks("a new overload of a promoted name across the 15 files", ("7", "4"), man, reviewed, files=mutate_bytes(path_cb, add_overload))
        # --- check 8 (setter guard), each form through an out-of-file receiver
        forms = {
            "plain assignment": "func zz(_ m: ConversationManager) { m.turnActivity = nil }",
            "compound assignment": "func zz(_ m: ConversationManager) { m.lastPromptTokens? += 1 }",
            "nil-coalescing assignment": "func zz(_ m: ConversationManager) { m.lastPromptTokens = m.lastPromptTokens ?? 0 }",
            "mutating call": "func zz(_ m: ConversationManager) { m.pendingMidTurnMessages.removeAll() }",
            "subscript mutation": "func zz(_ m: ConversationManager, _ id: UUID) { m.stoppedRunsFinishing[id] = nil }",
            "inout": "func zz(_ m: ConversationManager) { swap(&m.isRestoringMind, &m.isRestoringMind) }",
            "writable key path": "let zzKey = \\ConversationManager.isRestoringMind",
            "projected $name": "func zz(_ m: ConversationManager) { _ = m.$turnActivity }",
            "multiline expression": "func zz(_ m: ConversationManager) {\n    m.pendingMidTurnMessages\n        .removeAll()\n}",
            "interpolation": "func zz(_ m: ConversationManager) -> String { \"\\(m.lastPromptTokens ?? 0)\" }",
        }
        for label, code in forms.items():
            breaks(f"setter guard: {label} through an out-of-file receiver", "8", man, reviewed,
                   files=dict(files0, **{cli: (code + "\n").encode()}), changed=None)
        # --- check 9
        other = "TelegramConcierge/Services/OpenRouterService.swift"
        breaks("a non-manifest file touched", "9", man, reviewed, files=dict(files0, **{other: files0[other] + b"\n"}), changed=changed_for(man, [other]))
        xtra = "TelegramConcierge/Services/ConversationManager+Extra.swift"
        breaks("an extra split file", "9", man, reviewed, files=dict(files0, **{xtra: base.header.encode()}), changed=changed_for(man, [xtra]))
        wrong_naming = P.split_path(P.GROUPS[0], "feature-first" if man["naming"] == "conventional" else "conventional")
        breaks("an extra file of the other naming", "9", man, reviewed, files=dict(files0, **{wrong_naming: base.header.encode()}), changed=changed_for(man, [wrong_naming]))
        breaks("a split file missing", "9", man, reviewed, files={k: v for k, v in files0.items() if k != fam[-1]})
        # --- manifest mutations
        mbreak("manifest: changed base hash", lambda m2: m2["base"].__setitem__("sha256", "0" * 64))
        mbreak("manifest: overlapping ranges", lambda m2: next(f for f in m2["files"] if f["path"] == path_cb)["class_body_ranges"].append(list(f_cb["class_body_ranges"][0])))
        mbreak("manifest: out-of-bounds range", lambda m2: next(f for f in m2["files"] if f["path"] == path_cb)["class_body_ranges"].append([18050, 18060]))
        mbreak("manifest: unknown key", lambda m2: m2.__setitem__("note", "x"))
        mbreak("manifest: missing key", lambda m2: m2.pop("seam_files"))
        mbreak("manifest: changed naming", lambda m2: m2.__setitem__("naming", "feature-first" if man["naming"] == "conventional" else "conventional"))
        mbreak("manifest: changed seam_files list", lambda m2: m2["seam_files"].pop())
        mbreak("manifest: main entry with ranges", lambda m2: m2["files"][0]["class_body_ranges"].append([19, 19]))
        if man["setter_read_sites"]:
            def alter(m2):
                m2["setter_read_sites"][0]["count"] += 1
            def add(m2):
                s = dict(m2["setter_read_sites"][-1]); s["line_text"] = s["line_text"] + " "
                m2["setter_read_sites"].append(s); m2["setter_read_sites"].sort(key=lambda x: (x["name"], x["file"], x["line_text"]))
            mbreak("manifest: altered setter_read_sites entry (vs the C1-derived census)", alter, "8")
            mbreak("manifest: added setter_read_sites entry", add, "8")
            mbreak("manifest: removed setter_read_sites entry", lambda m2: m2["setter_read_sites"].pop(0), "8")
        # --- --unsplit on the split tree
        try:
            C.check_unsplit(files0)
            check("break: --unsplit on the split tree → [10]", False, "PASSED")
        except C.CheckFailure as e:
            check("break: --unsplit on the split tree → [10]", e.check == "10", e)
        try:
            C.check_unsplit({k: v for k, v in c1_files.items()})
            check("--unsplit passes on the unsplit C1 tree", True)
        except C.CheckFailure as e:
            check("--unsplit passes on the unsplit C1 tree", False, e)

    failed = results.count(False)
    print(f"\ncm_split_check selftest: {len(results) - failed}/{len(results)} {'PASS' if not failed else 'FAIL'}")
    return 1 if failed else 0
