#!/usr/bin/env python3
"""O1 / O9 / F1 differential for background pruning (BACKGROUND_PRUNE_PLAN
v4.1 §16.1–16.2; Codex implementation review round 1, item 2 and F1).

Builds two scratch trees, never committed or shipped:
  base  = `git archive` of the pinned 0.2.56 commit (26f8c2c)
  cand  = a copy of this working tree
and applies the SAME mechanical patch to both:
  * scripts/bg_prune_diff/BgPruneOffDiffDriver.swift copied unchanged into
    TelegramConcierge/CLI/ and registered in AdaMain's subcommand list;
  * O9 instrumentation: one `BgPruneDiffRecorder.record("...")` line at the
    entry of clearResponsesMidTurnBatch ("responses-clear"),
    clearInFlightMidTurnBatchIfCarried ("chat-clear"),
    restoreInFlightMidTurnBatch ("restore") and
    stripCurrentTurnAnnotations ("strip").
Both are built (`swift build --build-system native`) and every scenario runs
in a fresh process in its own scratch home (XDG_CONFIG_HOME/XDG_DATA_HOME
included) against a loopback provider. No network, no paid call, no live
install.

O1 (switch OFF, key absent) compares, per scenario: every request (target,
kind, body, in order), the in-memory history, every file under the data
and config roots (conversation, snapshots/manifests, description store,
settings), UserDefaults written by the product, notices, command replies,
the error, sampled maintenance activities and stage-marker records.
Scenarios: both prune sites (pre-request, mid-loop) x summary success /
request failure (fallback) / rejected reply (fallback) / tool-call replies
(fallback) / exhausted -> compaction / snapshot-write failure /
history-write failure / /stop during the inline prune.

O9 compares the ordered receipt calls OFF: tool loop and forced final x
Chat Completions and Responses x success and image-rejection resend, plus
the HarnessAnnotationRenderError path (tool loop, both protocols).
Control: the candidate tree with Codex's 8686/8687-style insertion (an
`if` between the tool loop's Responses clear and its `else`) must show
["responses-clear", "chat-clear"] where 0.2.56 shows ["responses-clear"],
and the differential must report it.

F1 (exact): the candidate with the switch ON (freeze, worker, apply at the
next boundary with nothing appended to the frozen range) against 0.2.56's
inline prune on the same inputs: the frozen prefix (seeded messages and the
trigger, all metadata kept: pruneArchiveReferences, coverage,
measuredTokens, demotion) and every snapshot file must be byte-identical
after the documented normalisation. Cases: basic, and three existing full
anchors + compact logs + measured tokens (fourth-anchor demotion).

Normalisation (R3-2: located seams only). Every JSON payload is parsed
losslessly (raw tokens, string spellings and every whitespace run kept) and
compared through a per-payload Profile:
  * the run's environment: scratch root, loopback port, endpoint
    fingerprint (random per run); UUIDs numbered consistently;
  * product clocks at named locations only: Message.timestamp (except the
    user's own text messages), tool-round issuedAt/completedAt, named
    timestamp fields of usage/diagnostic/stop files, and clock phrases in
    the exact anchored form the product writes ("[System Note: Current time
    is now …]", "[System Note: The following tool calls were issued at …",
    a line "Assistant reply time: …", day-heading lines, round/delivery
    header lines) inside message-content strings — never in tool arguments
    or other data. This is a TEMPLATE seam, not provenance: text of exactly
    that form at such a location is masked whoever wrote it. The fixture
    corpus is checked to contain none (so no fixture input is ever masked),
    and phrases quoted mid-line are not masked;
  * the Bash tool's own pid/running_for_seconds/waited_seconds inside a
    saved Bash result (located through its tool-call id);
  * free member order only in payloads written from unordered dictionaries
    (base-vs-base evidence), with each member keeping its own whitespace
    and the separators after members order-free only when uniform
    (non-uniform separators: compared in written order); an embedded Bash
    JSON result keeps its own outer whitespace;
    main/summary/maintenance request bodies stay byte-exact;
  * stage markers: clock fields dropped, order kept per call and per stage
    family, plus the round's happens-after edges (all_tools_finished /
    execution_complete after their calls' records).
Command discovery compares stdout/stderr/exit plus every file the run
created in its isolated root and its throwaway preference domain, piped and
terminal-attached (stdout on an 80-column PTY; stdin/stdout/stderr on it).

Usage: bg_prune_off_differential_test.py [--only o1|o9|f1|control] [--keep]
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BASE_COMMIT = "26f8c2c4b411ca1da8238daf934b09366da0b412"
DRIVER = os.path.join(HERE, "bg_prune_diff", "BgPruneOffDiffDriver.swift")
CM = "TelegramConcierge/Services/ConversationManager.swift"
MAIN = "TelegramConcierge/CLI/AdaMain.swift"

INSTRUMENT = [
    ("    private func clearResponsesMidTurnBatch(_ response: LLMResponse) {\n", "responses-clear"),
    ("    private func clearInFlightMidTurnBatchIfCarried(by interactions: [ToolInteraction]?) {\n", "chat-clear"),
    ("    private func restoreInFlightMidTurnBatch(in toolInteractions: inout [ToolInteraction]) {\n", "restore"),
    ("    private func stripCurrentTurnAnnotations(in toolInteractions: inout [ToolInteraction]) {\n", "strip"),
]
CONTROL_LINE = "                if responsesExecution != nil { clearResponsesMidTurnBatch(response) }\n"

O1 = [f"o1:{site}:{v}" for site in ("pre", "mid")
      for v in ("success", "error", "rejected", "tools", "exhausted", "snapshot-fault", "history-fault", "stop")]
O9 = [f"o9:{path}:{proto}:{v}" for path in ("loop", "final") for proto in ("chat", "responses")
      for v in ("success", "image")] + ["o9:loop:chat:render", "o9:loop:responses:render"]
F1 = ["f1:basic", "f1:rich", "f1:media", "f1:descfail", "f1:descfail-first", "f1:fallback", "f1:demotefail",
      "f1:error", "f1:rejected", "f1:tools",
      "f1:reasoning", "f1:compactlogs", "f1:synthetic"]

failures = 0
total = 0


def check(label, ok, detail=""):
    global failures, total
    total += 1
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else f" — {detail}"), flush=True)
    if not ok:
        failures += 1


def sh(cmd, cwd=None, **kw):
    return subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), check=True, **kw)


def patch_tree(tree):
    shutil.copy2(DRIVER, os.path.join(tree, "TelegramConcierge/CLI/BgPruneOffDiffDriver.swift"))
    main = os.path.join(tree, MAIN)
    text = open(main, encoding="utf-8").read()
    anchor = "AdaService.self, "
    assert text.count(anchor) == 1, "AdaMain anchor"
    open(main, "w", encoding="utf-8").write(text.replace(anchor, anchor + "BgPruneOffDiffDriver.self, "))
    cm = os.path.join(tree, CM)
    text = open(cm, encoding="utf-8").read()
    for sig, name in INSTRUMENT:
        assert text.count(sig) == 1, f"instrumentation anchor {name}"
        text = text.replace(sig, sig + f'        BgPruneDiffRecorder.record("{name}")\n')
    open(cm, "w", encoding="utf-8").write(text)


def make_trees(scratch):
    base = os.path.join(scratch, "base")
    cand = os.path.join(scratch, "cand")
    os.makedirs(base)
    archive = subprocess.run(["git", "-C", ROOT, "archive", BASE_COMMIT], check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", base], input=archive, check=True)
    shutil.copytree(ROOT, cand, symlinks=True, ignore=shutil.ignore_patterns(".build", ".git"))
    # Reuse the resolved package checkouts only (no network; build products
    # are not reused because module caches embed absolute paths).
    for tree in (base, cand):
        os.makedirs(os.path.join(tree, ".build"))
        for name in ("checkouts", "repositories", "workspace-state.json"):
            src = os.path.join(ROOT, ".build", name)
            dst = os.path.join(tree, ".build", name)
            if os.path.isdir(src):
                shutil.copytree(src, dst, symlinks=True)
            elif os.path.exists(src):
                shutil.copy2(src, dst)
    return base, cand


def build_command():
    """`swift build`, plus `--build-system native` on Swift >= 6.4 (whose
    default build system misplaces the resource bundle), plus
    BGPRUNE_DIFF_BUILD_ARGS (e.g. `-j 1` on a memory-tight Linux host)."""
    cmd = ["swift", "build"]
    version = subprocess.run(["swift", "--version"], capture_output=True, text=True).stdout + \
        subprocess.run(["swift", "--version"], capture_output=True, text=True).stderr
    m = re.search(r"Swift version (\d+)\.(\d+)", version)
    if m and (int(m.group(1)), int(m.group(2))) >= (6, 4):
        cmd += ["--build-system", "native"]
    return cmd + os.environ.get("BGPRUNE_DIFF_BUILD_ARGS", "").split()


def build(tree, label):
    proc = subprocess.run(build_command(), cwd=tree, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout[-4000:] + proc.stderr[-4000:])
        raise SystemExit(f"{label}: build failed")
    return os.path.join(tree, ".build/debug/briglia")


def run(binary, scenario, out_dir, mode="off"):
    os.makedirs(out_dir, exist_ok=True)
    tag = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(binary))))
    out = os.path.join(out_dir, re.sub(r"[^A-Za-z0-9_.-]", "_", scenario) + f".{tag}.{mode}.json")
    proc = subprocess.run([binary, "__bgprune-off-diff", "--scenario", scenario, "--out", out, "--mode", mode],
                          capture_output=True, text=True, timeout=300)
    if proc.returncode != 0 or not os.path.exists(out):
        return {"__failed__": f"exit {proc.returncode}: {proc.stdout[-1500:]} {proc.stderr[-1500:]}"}
    with open(out, encoding="utf-8") as fh:
        return json.load(fh)


# ------------------------------------------------- normalisation (R3-2)
#
# Codex implementation review round 3, R3-2: every seam is located. A JSON
# container is parsed losslessly (raw tokens and every whitespace run kept)
# and a per-container Profile names the exact paths where a product clock,
# the Bash tool's measured pid/durations, or a free member order applies.
# Nothing is inferred from a value's shape or from the run's time window.

UUID_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
ENDPOINT_RE = re.compile(r"#127\.0\.0\.1-[0-9a-f]{8}")
WS = " \t\n\r"


class JSONSyntax(ValueError):
    pass


NUMBER_RE = re.compile(r"-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?")


def jparse(text):
    """Lossless JSON parse: every token keeps its raw spelling and every
    whitespace run is kept. Nodes: ("obj", members, empty_ws) with members
    [ws_before_key, raw_key, ws_before_colon, ws_after_colon, value,
    ws_after_value]; ("arr", items, empty_ws) with items [ws_before, value,
    ws_after]; ("str", raw); ("num", raw); ("lit", raw). Returns
    (leading_ws, node, trailing_ws)."""
    n = len(text)
    i = 0

    def ws():
        nonlocal i
        j = i
        while i < n and text[i] in WS:
            i += 1
        return text[j:i]

    def expect(c):
        nonlocal i
        if i >= n or text[i] != c:
            raise JSONSyntax(f"expected {c!r} at {i}")
        i += 1

    def string():
        nonlocal i
        j = i
        expect('"')
        while True:
            if i >= n:
                raise JSONSyntax("unterminated string")
            c = text[i]
            if c == "\\":
                i += 2
                continue
            i += 1
            if c == '"':
                return text[j:i]

    def value():
        nonlocal i
        if i >= n:
            raise JSONSyntax("unexpected end")
        c = text[i]
        if c == "{":
            i += 1
            w0 = ws()
            if i < n and text[i] == "}":
                i += 1
                return ("obj", [], w0)
            members = []
            while True:
                key = string()
                w1 = ws()
                expect(":")
                w2 = ws()
                v = value()
                w3 = ws()
                members.append([w0, key, w1, w2, v, w3])
                if i < n and text[i] == ",":
                    i += 1
                    w0 = ws()
                    continue
                expect("}")
                return ("obj", members, None)
        if c == "[":
            i += 1
            w0 = ws()
            if i < n and text[i] == "]":
                i += 1
                return ("arr", [], w0)
            items = []
            while True:
                v = value()
                w3 = ws()
                items.append([w0, v, w3])
                if i < n and text[i] == ",":
                    i += 1
                    w0 = ws()
                    continue
                expect("]")
                return ("arr", items, None)
        if c == '"':
            return ("str", string())
        m = NUMBER_RE.match(text, i)
        if m and m.end() > i:
            i = m.end()
            return ("num", m.group(0))
        for lit in ("true", "false", "null"):
            if text.startswith(lit, i):
                i += len(lit)
                return ("lit", lit)
        raise JSONSyntax(f"unexpected {c!r} at {i}")

    lead = ws()
    node = value()
    trail = ws()
    if i != n:
        raise JSONSyntax("trailing data")
    return lead, node, trail


def enc_styles(decoded):
    """Raw spellings the products use for a JSON string (Foundation's
    encoders escape '/', Python-style does not)."""
    plain = json.dumps(decoded, ensure_ascii=False)
    return {"plain": plain, "slash": plain.replace("/", "\\/")}




# ---------------------------------------------------------------- seams
# Product clock phrases (templates). This is a TEMPLATE-MATCHING seam, not a
# provenance proof (Codex impl round 4): a template masks only the clock
# part of a phrase whose exact product-written form (with its fixed
# leading context: a "[System Note: " / "[Run clock: " bracket, or the start
# of a line for the line-shaped notes) matches at a string location a
# profile lists — never tool arguments or other data. Text that is not the
# product's but has exactly that shape at such a location (a user quoting a
# whole "[System Note: Current time is now 10:00]" line, say) would be
# masked too; the guarantee therefore does not extend to clock-shaped
# phrases inside arbitrary user/tool content. Two things bound it:
#   * fixture_corpus_controls(): none of the fixture-authored text (user
#     messages, tool outputs, provider replies — all in the driver source)
#     contains any template match, so no fixture input is ever masked;
#   * the anchored forms do not match a phrase quoted mid-line (Codex's
#     "quote: Assistant reply time: …" control is reported).
ISO = r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?"
DATE_LONG = r"(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), \d{1,2} [A-Z][a-z]+ \d{4}"
TEMPLATES = {
    "issued": re.compile(r"(\[System Note: The following tool calls were issued at )\d{2}:\d{2}:\d{2}(?: on " + DATE_LONG + ")?"),
    "round-issued": re.compile(r"(?m)(^COMPLETE TOOL ROUND \(issued )\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC[+-]\d{2}(?::?\d{2})?"),
    "now": re.compile(r"(\[System Note: Current time is now )\d{2}:\d{2}(?::\d{2})?(?=\])"),
    "delivered": re.compile(r"(?m)(^Result \S+ \(delivered )\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC[+-]\d{2}(?::?\d{2})?"),
    "result-delivered": re.compile(r"(?m)^(Result delivered: )" + ISO + "$"),
    "reply-time": re.compile(r"(?m)(^Assistant reply time: )\d{2}:\d{2}(?::\d{2})?$"),
    "run-clock": re.compile(r"(\[Run clock: this run started at )\d{2}:\d{2}:\d{2} on " + DATE_LONG + r" \(UTC[+-]\d{2}(?::?\d{2})?\)"),
    "day-heading": re.compile(r"(?m)(^--- )" + DATE_LONG + r"(?= ---$)"),
    "free-space": re.compile(r"(\. Available space: )\d+(?= bytes)"),
}
CHAT_TEXT = ("issued", "round-issued", "now", "delivered", "reply-time", "run-clock", "day-heading")


def templ(s, names):
    for name in names:
        s = TEMPLATES[name].sub(lambda m, n=name: m.group(1) + f"<{n.upper()}>", s)
    return s


def match(path, pattern):
    """Path segments vs a '/'-separated pattern; '*' matches one segment."""
    pat = pattern.split("/")
    return len(pat) == len(path) and all(p == "*" or p == s for p, s in zip(pat, path))


class Profile:
    """Where the documented seams apply inside one JSON container.
    permute: object member order is free (only for payloads written from
      unordered dictionaries on 0.2.56, proven by the base-vs-base runs);
    numbers: [(pattern, predicate(parent) | None)] masked numeric values;
    strings: [(pattern, predicate | None)] whole string values masked;
    texts: [(pattern, template names)] product clock phrases in strings;
    embedded: [(pattern, predicate | None, Profile)] strings holding JSON."""

    def __init__(self, permute=False, numbers=(), strings=(), texts=(), embedded=()):
        self.permute, self.numbers, self.strings = permute, list(numbers), list(strings)
        self.texts, self.embedded = list(texts), list(embedded)


def _rule(rules, path, parent):
    for r in rules:
        if match(path, r[0]) and (r[1] is None or r[1](parent)):
            return r
    return None


def _decoded(node):
    try:
        return json.loads(node[1]) if node[0] == "str" else None
    except ValueError:
        return None


def rep(node, profile, path=(), parent=None):
    """A comparable, lossless representation: raw tokens and every
    whitespace run are kept; only the profile's located seams change."""
    kind = node[0]
    if kind == "obj":
        if not node[1]:
            return ["{}", node[2]]
        decoded = {}
        for m in node[1]:
            try:
                decoded[json.loads(m[1])] = _decoded(m[4]) if m[4][0] == "str" else m[4][1] if m[4][0] in ("num", "lit") else None
            except ValueError:
                pass
        members = []
        for w0, key, w1, w2, value, w3 in node[1]:
            k = json.loads(key)
            members.append([w0, key, w1, w2, rep(value, profile, path + (k,), decoded), w3])
        if not profile.permute:
            return ["{", members]
        # Order-free, lossless otherwise (Codex impl round 4 note): each
        # member keeps its own leading/colon whitespace. The whitespace after
        # each non-last member (before its comma) is order-free only when it
        # is one uniform run for the whole object — then a permutation cannot
        # move it and it is kept once with its count; the closing whitespace
        # is kept separately. Non-uniform separators lose the order freedom:
        # the object is compared in written order, every run attached to
        # its member (fail-closed).
        seps = [m[5] for m in members[:-1]]
        if len(set(seps)) > 1:
            return ["{", members]
        body = sorted(([m[0], m[1], m[2], m[3], m[4]] for m in members),
                      key=lambda m: UUID_RE.sub("<U>", json.dumps(m, sort_keys=True, ensure_ascii=False)))
        return ["{~", body, [seps[0] if seps else None, len(seps)], members[-1][5]]
    if kind == "arr":
        if not node[1]:
            return ["[]", node[2]]
        return ["[", [[w0, rep(v, profile, path + ("*",), parent), w3] for w0, v, w3 in node[1]]]
    if kind == "num":
        if _rule(profile.numbers, path, parent):
            return "<NUM>"
        return ["#", node[1]]
    if kind == "lit":
        return ["#", node[1]]
    raw = node[1]
    if _rule(profile.strings, path, parent):
        return "<STR>"
    emb = _rule(profile.embedded, path, parent)
    texts = next((t for t in profile.texts if match(path, t[0])), None)
    if emb or texts:
        decoded = _decoded(node)
        style = next((k for k, v in enc_styles(decoded).items() if v == raw), None) if isinstance(decoded, str) else None
        if style is not None:
            if emb:
                try:
                    # The embedded document's own leading/trailing
                    # whitespace stays exact (Codex impl round 4 note).
                    lead, inner, trail = jparse(decoded)
                    return ["<json>", style, lead, rep(inner, emb[2]), trail]
                except JSONSyntax:
                    pass
            if texts:
                masked = templ(decoded, texts[1])
                if masked != decoded:
                    return ["<text>", style, masked]
    return raw


def unparse(node):
    """Inverse of jparse for one node (used by the comparator controls)."""
    kind = node[0]
    if kind == "obj":
        if not node[1]:
            return "{" + node[2] + "}"
        return "{" + ",".join(w0 + k + w1 + ":" + w2 + unparse(v) + w3 for w0, k, w1, w2, v, w3 in node[1]) + "}"
    if kind == "arr":
        if not node[1]:
            return "[" + node[2] + "]"
        return "[" + ",".join(w0 + unparse(v) + w3 for w0, v, w3 in node[1]) + "]"
    return node[1]


def rep_text(text, profile):
    try:
        lead, node, trail = jparse(text)
    except JSONSyntax:
        return ["<not json>", text]
    return [lead, rep(node, profile), trail]


def _not_fixture_user(parent):
    # Message.timestamp is a product clock except on the user's own text
    # messages, whose times the fixtures fix (and which stay exact).
    return not (isinstance(parent, dict) and parent.get("role") == "user" and parent.get("kind") in (None, "userText"))


def _bash_result(bash_ids):
    return lambda parent: isinstance(parent, dict) and parent.get("tool_call_id") in bash_ids


BASH_RESULT = Profile(numbers=[("pid", None), ("running_for_seconds", None), ("waited_seconds", None)])


def bash_call_ids(text):
    """Ids of tool calls whose function is the Bash tool (ordinary JSON
    decode of the same document; used only to locate Bash results)."""
    ids = set()
    def walk(v):
        if isinstance(v, dict):
            f = v.get("function")
            if isinstance(f, dict) and f.get("name") == "bash" and isinstance(v.get("id"), str):
                ids.add(v["id"])
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    try:
        walk(json.loads(text))
    except ValueError:
        pass
    return ids


def message_profile(text, permute):
    bash = _bash_result(bash_call_ids(text))
    return Profile(
        permute=permute,
        numbers=[("*/timestamp", _not_fixture_user),
                 ("*/toolInteractions/*/assistantMessage/issuedAt", None),
                 ("*/toolInteractions/*/results/*/completedAt", None)],
        texts=[("*/content", CHAT_TEXT + ("free-space",))],
        embedded=[("*/toolInteractions/*/results/*/content", bash, BASH_RESULT)])


# Request bodies: string locations that carry conversation text the
# product renders (message content), never tool-call arguments.
REQUEST_TEXT = [(p, CHAT_TEXT) for p in ("messages/*/content", "messages/*/content/*/text",
                                         "input/*/content", "input/*/content/*/text", "input/*/output",
                                         "input/*/output/*/text")]
# Files written from unordered dictionaries: member order differs between
# two runs of the same 0.2.56 binary (base-vs-base evidence, see the
# calibration checks); everything else in them stays exact.
PERMUTED_FILES = {"conversation.json", "context_usage.json", "bash_jobs_stats.json", "pending_midturn.json",
                  "prune-archive-settlements/legacy.json", "offdiff-descriptions.json"}
FILE_PROFILES = {
    "context_usage.json": Profile(permute=True, numbers=[("updatedAt", None)]),
    "bash_jobs_stats.json": Profile(permute=True, numbers=[("wait.total_ms", None), ("wait.max_ms", None)]),
    "mcp-routing-diagnostics.json": Profile(strings=[("generatedAt", None)]),
    "responses_usage.json": Profile(numbers=[("records/*/durationMs", None), ("records/*/timestamp", None)]),
    "stop-marker.json": Profile(numbers=[("entries/*/at", None)]),
    "prune-archive-settlements/legacy.json": Profile(permute=True),
    "offdiff-descriptions.json": Profile(permute=True),
}
MESSAGE_FILES = {"conversation.json", "pending_midturn.json"}
SNAPSHOT_HEADER = re.compile(r"^(=== MESSAGE \d+ \| .*\| role=(\w+) \| kind=(\w+) \| time=)(" + ISO + r")", re.M)


def snapshot_text(text):
    """Snapshot files: the product's own clock lines (result delivery and
    the times of product-written messages); user text times stay exact."""
    text = templ(text, ("result-delivered",))
    return SNAPSHOT_HEADER.sub(lambda m: m.group(0) if (m.group(2), m.group(3)) == ("user", "userText")
                               else m.group(1) + "<TIME>", text)


STAGE_CLOCK_FIELDS = {"seq", "t", "mono_ms", "pid", "elapsed_ms"}
# Round records emitted after the round's tool tasks have returned
# (ToolExecutor.executeParallel awaits the group; ConversationManager
# completes the round after execution). round.dispatched is emitted after
# the tasks are added and races with them, so it carries no edge.
ROUND_AFTER = {"round.all_tools_finished", "round.execution_complete"}


def stages(raw):
    """Stage markers. Clock fields of each record are dropped (record
    top level only). Records are grouped by tool call (`call`), or by stage
    family for records without a call; order within a group is kept and ids
    are renamed per group. Cross-group causality is kept for the round
    coordinator: each round.all_tools_finished / round.execution_complete
    record (ROUND_AFTER) carries, for each call, how many of that call's
    records preceded it. round.dispatched carries no edge (calls may emit
    records before that marker). Interleaving between unrelated calls
    stays free."""
    groups, ids, seen = {}, {}, {}
    for line in raw.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            groups.setdefault("<unparsed>", []).append(line)
            continue
        if not isinstance(record, dict):
            groups.setdefault("<unparsed>", []).append(line)
            continue
        out = {k: v for k, v in record.items() if k not in STAGE_CLOCK_FIELDS}
        call = out.get("call")
        stage = str(out.get("stage", ""))
        key = f"call:{call}" if call else "stage:" + stage.split(".")[0]
        if "id" in out:
            local = ids.setdefault(key, {})
            out["id"] = local.setdefault(out["id"], f"<S{len(local)}>")
        if not call and stage in ROUND_AFTER:
            out["_after"] = sorted([c, n] for c, n in seen.items())
        if call:
            seen[call] = seen.get(call, 0) + 1
        groups.setdefault(key, []).append(out)
    return groups


class Normaliser:
    def __init__(self, result):
        self.result = result
        self.port = str(result.get("port", ""))
        data = result.get("dataRoot", "")
        roots = set()
        m = re.search(r"^(.*bgprune-offdiff-[0-9A-Fa-f-]{36})", data)
        if m:
            root = m.group(1)
            roots.add(root)
            if root.startswith("/private/var/"):
                roots.add(root[len("/private"):])
            elif root.startswith("/var/"):
                roots.add("/private" + root)
        self.roots = sorted(roots, key=len, reverse=True)
        self.uuids = {}

    def env(self, s):
        """The run's own environment: scratch root, loopback port and the
        endpoint fingerprint derived from it. These are random per run and
        cannot occur in fixture data by coincidence."""
        for root in self.roots:
            for form in (root, root.replace("/", "\\/"), root.replace("/", "\\\\\\/")):
                s = s.replace(form, "<SCRATCH>")
        if self.port:
            s = s.replace("127.0.0.1:" + self.port, "127.0.0.1:<PORT>")
        return ENDPOINT_RE.sub("#127.0.0.1-<EP>", s)

    def request(self, r):
        body = self.env(r["body"])
        profile = Profile(permute=r["kind"] == "description", texts=REQUEST_TEXT)
        return {"target": self.env(r["target"]), "kind": r["kind"], "body": rep_text(body, profile)}

    def file(self, rel, text):
        text = self.env(text)
        if text.startswith("b64:"):
            return text
        if rel.startswith("prune-archives/") and rel.endswith(".txt"):
            return snapshot_text(text)
        if rel in MESSAGE_FILES:
            return rep_text(text, message_profile(text, rel in PERMUTED_FILES))
        if rel in FILE_PROFILES:
            return rep_text(text, FILE_PROFILES[rel])
        return text

    def run(self):
        r = self.result
        out = {"requests": [self.request(x) for x in r.get("requests", [])]}
        history = self.env(r.get("history", ""))
        out["history"] = rep_text(history, message_profile(history, False)) if history else history
        out["files"] = {k: self.file(k, v) for k, v in r.get("files", {}).items()}
        out["config"] = {k: self.env(v) for k, v in r.get("config", {}).items()}
        for k in ("notices", "replies", "maintenanceNotices"):
            out[k] = [templ(self.env(x), ("free-space",)) for x in r.get(k, [])]
        err = r.get("error")
        out["error"] = templ(self.env(err), ("free-space",)) if isinstance(err, str) else err
        for k in ("notes", "activities", "receipts"):
            out[k] = [self.env(x) for x in r.get(k, [])]
        out["defaults"] = {k: self.env(v) for k, v in r.get("defaults", {}).items()}
        out["stages"] = stages(self.env(r.get("stages", "")))
        extra = set(r) - set(out) - {"dataRoot", "configRoot", "port", "startedAt", "endedAt"}
        for k in sorted(extra):
            out[k] = r[k]
        return self.number(out)

    def number(self, v):
        """UUIDs renamed consistently, in canonical walk order."""
        if isinstance(v, dict):
            return {k: self.number(v[k]) for k in sorted(v)}
        if isinstance(v, list):
            return [self.number(x) for x in v]
        if isinstance(v, str):
            return UUID_RE.sub(self.uuid, v)
        return v

    def uuid(self, m):
        key = m.group(0).upper()
        if key not in self.uuids:
            self.uuids[key] = f"<UUID{len(self.uuids)}>"
        return self.uuids[key]


def normalise(result):
    if "__failed__" in result:
        return result
    return Normaliser(result).run()


def first_diff(a, b, path=""):
    if type(a) != type(b):
        return f"{path}: type {type(a).__name__} vs {type(b).__name__}"
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return f"{path}/{k}: only in {'cand' if k not in a else 'base'}"
            d = first_diff(a[k], b[k], f"{path}/{k}")
            if d:
                return d
        return None
    if isinstance(a, list):
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff(x, y, f"{path}[{i}]")
            if d:
                return d
        if len(a) != len(b):
            return f"{path}: length {len(a)} vs {len(b)}"
        return None
    if a != b:
        sa, sb = str(a), str(b)
        i = next((i for i, (x, y) in enumerate(zip(sa, sb)) if x != y), min(len(sa), len(sb)))
        return f"{path}: …{sa[max(0, i - 80):i + 120]!r} vs …{sb[max(0, i - 80):i + 120]!r}"
    return None


def kinds(result):
    return [r["kind"] for r in result.get("requests", [])]


SELFTEST_FILE = "TelegramConcierge/CLI/BackgroundPruneSelftest.swift"
SELFTEST_CONFIG = """    static let configuration = CommandConfiguration(
        commandName: "__background-prune-selftest",
        abstract: "Internal: verify background pruning.",
        shouldDisplay: false
    )"""
# Codex impl round 2, R2-1: the newline variant of the closure initializer.
NEWLINE_MUTANT = """    static
    let configuration: CommandConfiguration = {
        print("CODEX_OFF_DISCOVERY_SIDE_EFFECT")
        return CommandConfiguration(
            commandName: "__background-prune-selftest",
            abstract: "Internal: verify background pruning.",
            shouldDisplay: false
        )
    }()"""
# Codex impl round 3, R3-1: a static factory that shadows the imported
# CommandConfiguration initialiser and writes a file at --help.
FACTORY_MUTANT = """    static func CommandConfiguration(
        commandName: String, abstract: String, shouldDisplay: Bool
    ) -> ArgumentParser.CommandConfiguration {
        if ProcessInfo.processInfo.arguments.contains("--help") {
            let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]!
            try? "CODEX_OFF_FACTORY_SIDE_EFFECT".write(
                toFile: root + "/codex-off-discovery.txt",
                atomically: true, encoding: .utf8)
        }
        return ArgumentParser.CommandConfiguration(
            commandName: commandName, abstract: abstract,
            shouldDisplay: shouldDisplay)
    }

"""
RUN_LINE = "    @MainActor func run() async throws {"
# Codex impl round 4, R4-1, verbatim.
SYMBOL_PROBE = """import Foundation

struct BackgroundPruneSymbolProbe {
    @_silgen_name("$s6Darwin5ioctlys5Int32VAD_SuSvtF")
    static func bgPruneIoctl(
        _ fd: Int32, _ request: UInt, _ ptr: UnsafeMutableRawPointer
    ) -> Int32 {
        if isatty(fd) == 1,
           let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            try? "CODEX_OFF_SYMBOL_SIDE_EFFECT".write(
                toFile: root + "/codex-off-symbol.txt",
                atomically: true, encoding: .utf8)
        }
        return -1
    }
}
"""
DISCOVERY_ARGS = [["--help"], ["help"], ["__bgprune-off-diff", "--help"]]
# Codex impl round 4, R4-1: discovery also runs terminal-attached. "pipe":
# stdout/stderr piped (the earlier coverage); "pty-stdout": stdout on a fresh
# 80x24 pseudo-terminal, stderr piped; "pty-all": stdin, stdout and stderr all
# on the pseudo-terminal (an interactive shell). ArgumentParser queries the
# terminal size only when stdout is a terminal.
DISCOVERY_MODES = ("pipe", "pty-stdout", "pty-all")


def _run_pty(argv, env, mode, timeout=60):
    """Run argv with stdout (and for pty-all also stdin/stderr) on a fresh
    80-column pseudo-terminal; returns (exit, terminal output, piped stderr)."""
    import fcntl
    import pty
    import struct
    import termios
    import threading
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    chunks = []

    def drain():
        while True:
            try:
                data = os.read(master, 65536)
            except OSError:
                return
            if not data:
                return
            chunks.append(data)

    reader = threading.Thread(target=drain, daemon=True)
    try:
        if mode == "pty-all":
            proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
        else:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=slave, stderr=subprocess.PIPE, env=env)
        os.close(slave)
        slave = None
        reader.start()
        try:
            _, err = proc.communicate(timeout=timeout) if mode != "pty-all" else (None, b"")
            if mode == "pty-all":
                proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            err = b"<timeout>"
        reader.join(timeout=10)
    finally:
        if slave is not None:
            os.close(slave)
        os.close(master)
    return proc.returncode, b"".join(chunks).decode("utf-8", "replace"), (err or b"").decode("utf-8", "replace")


# A throwaway preference domain (TestPrefsDomains prefix "briglia-mw-"):
# never the live install's domain.
DISCOVERY_LINK = "briglia-mw-bgprune-discovery"


def _effects(root, skip):
    """Every file and directory the run left under its isolated root, with
    content hashes (R3-1: the discovery comparison observes writes, not just
    stdout/stderr/exit)."""
    import hashlib
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames) + sorted(filenames):
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, root)
            if rel in skip:
                continue
            if os.path.islink(p):
                out[rel] = "link:" + os.readlink(p)
            elif os.path.isdir(p):
                out[rel] = "dir"
            else:
                with open(p, "rb") as fh:
                    out[rel] = hashlib.sha256(fh.read()).hexdigest()
    return out


def _prefs_domain(name, purge):
    """The throwaway domain's persisted settings (macOS cfprefsd keeps them
    under the passwd home whatever HOME says; Linux under $HOME, already in
    the tree). Read-only except the purge of this one test domain."""
    if sys.platform != "darwin":
        return None
    proc = subprocess.run(["defaults", "export", name, "-"], capture_output=True, text=True)
    plist = os.path.expanduser(f"~/Library/Preferences/{name}.plist")
    state = {"exported": proc.stdout if proc.returncode == 0 else f"<exit {proc.returncode}>",
             "file": os.path.exists(plist)}
    if purge:
        subprocess.run(["defaults", "delete", name], capture_output=True)
        if os.path.exists(plist):
            os.remove(plist)
    return state


def discovery(binary):
    """Command discovery in an isolated home: what ArgumentParser evaluates
    for every registered command before any feature code runs. Compared:
    stdout, stderr, exit status, every file/directory created under the
    isolated root (home, XDG roots, TMPDIR) and the throwaway preference
    domain the binary runs under."""
    outs = []
    _prefs_domain(DISCOVERY_LINK, purge=True)
    for mode, args in [(m, a) for m in DISCOVERY_MODES for a in DISCOVERY_ARGS]:
        root = tempfile.mkdtemp(prefix="bgprune-discovery-")
        try:
            env = {k: v for k, v in os.environ.items()
                   if not (k.startswith("BRIGLIA_") or k.startswith("ADA_") or k.startswith("SM_"))}
            home = os.path.join(root, "home")
            for sub in (".config", ".local/share", ".local/state", ".cache", "tmp"):
                os.makedirs(os.path.join(home, sub))
            env.update(HOME=home, CFFIXED_USER_HOME=home, XDG_CONFIG_HOME=home + "/.config",
                       XDG_DATA_HOME=home + "/.local/share", XDG_STATE_HOME=home + "/.local/state",
                       XDG_CACHE_HOME=home + "/.cache", TMPDIR=home + "/tmp/")
            link = os.path.join(root, DISCOVERY_LINK)
            try:
                os.link(binary, link)
            except OSError:
                shutil.copy2(binary, link)
            skip = {DISCOVERY_LINK}
            bundle = os.path.join(os.path.dirname(binary), "briglia-cli_briglia.bundle")
            if os.path.exists(bundle):
                os.symlink(bundle, os.path.join(root, "briglia-cli_briglia.bundle"))
                skip.add("briglia-cli_briglia.bundle")
            before = _effects(root, skip)
            if mode == "pipe":
                proc = subprocess.run([link] + args, capture_output=True, text=True, env=env, timeout=60)
                status, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
            else:
                status, stdout, stderr = _run_pty([link] + args, env, mode)
            effects = _effects(root, skip)
            created = {k: v for k, v in effects.items() if before.get(k) != v}
            outs.append({"mode": mode, "args": args, "exit": status,
                         "stdout": stdout.replace(root, "<ROOT>"), "stderr": stderr.replace(root, "<ROOT>"),
                         "effects": created, "prefs": _prefs_domain(DISCOVERY_LINK, purge=True)})
        finally:
            shutil.rmtree(root, ignore_errors=True)
    return outs


def comparator_controls(sample_text, sample_binary):
    """Negative controls for the comparator itself (Codex round 2, R2-3):
    each change below must be reported; an unchanged copy must compare equal."""
    import base64
    import copy
    base = sample_text
    check("comparator: an unchanged copy compares equal", first_diff(normalise(base), normalise(copy.deepcopy(base))) is None)
    mains = [i for i, r in enumerate(base["requests"]) if r["kind"] == "main"]
    reformatted = copy.deepcopy(base)
    body = reformatted["requests"][mains[0]]["body"]
    reformatted["requests"][mains[0]]["body"] = json.dumps(json.loads(body), indent=1, sort_keys=True)
    check("comparator: a re-formatted request body (same JSON) is reported",
          first_diff(normalise(base), normalise(reformatted)) is not None)
    idx = next(i for i, r in enumerate(base["requests"]) if '\\"command\\"' in r["body"])
    a, b = copy.deepcopy(base), copy.deepcopy(base)
    a["requests"][idx]["body"] = a["requests"][idx]["body"].replace('\\"command\\"', '\\"timeout\\":1,\\"command\\"', 1)
    b["requests"][idx]["body"] = b["requests"][idx]["body"].replace('\\"command\\"', '\\"timeout\\":999,\\"command\\"', 1)
    check("comparator: a numeric tool argument 1 → 999 is reported", first_diff(normalise(a), normalise(b)) is not None)
    lines = base["stages"].splitlines()
    calls = {}
    for n, line in enumerate(lines):
        try:
            call = json.loads(line).get("call")
        except ValueError:
            continue
        if call:
            calls.setdefault(call, []).append(n)
    call, positions = max(calls.items(), key=lambda kv: len(kv[1]))
    reversed_lines = list(lines)
    for p, q in zip(positions, reversed(positions)):
        reversed_lines[p] = lines[q]
    rev = copy.deepcopy(base)
    rev["stages"] = "\n".join(reversed_lines) + "\n"
    check(f"comparator: reversing the {len(positions)} stage records of one call ({call}) is reported",
          len(positions) >= 2 and first_diff(normalise(base), normalise(rev)) is not None)
    name, value = next((k, v) for k, v in sample_binary["files"].items() if v.startswith("b64:"))
    raw = bytearray(base64.b64decode(value[4:]))
    raw[len(raw) // 2] ^= 0x01
    flipped = copy.deepcopy(sample_binary)
    flipped["files"][name] = "b64:" + base64.b64encode(bytes(raw)).decode()
    check(f"comparator: an equal-size binary change in {name} is reported",
          first_diff(normalise(sample_binary), normalise(flipped)) is not None)


def located_seam_controls(sample, round_sample):
    """Codex implementation review round 3, R3-2: the seams are located.
    Each probe below changes data at a place no seam covers and must be
    reported; the positive controls show the seams still absorb the
    product's own nondeterminism (and nothing else)."""
    import copy
    import datetime

    def differs(a, b):
        return first_diff(normalise(a), normalise(b)) is not None

    idx = next(i for i, r in enumerate(sample["requests"]) if '\\"command\\"' in r["body"])
    # (1) Bash-result field names inserted into a tool call's arguments.
    for key in ("pid", "waited_seconds", "running_for_seconds"):
        a, b = copy.deepcopy(sample), copy.deepcopy(sample)
        a["requests"][idx]["body"] = a["requests"][idx]["body"].replace('\\"command\\"', f'\\"{key}\\":1,\\"command\\"', 1)
        b["requests"][idx]["body"] = b["requests"][idx]["body"].replace('\\"command\\"', f'\\"{key}\\":999,\\"command\\"', 1)
        check(f"R3-2 control: `{key}` 1 → 999 inserted into tool-call arguments is reported", differs(a, b))
    # (2) Two distinct in-window clock values in command text.
    t = float(sample["startedAt"])
    for label, fmt in (("ISO timestamps", "%Y-%m-%dT%H:%M:%SZ"), ("clock times", "%H:%M:%S")):
        stamps = [datetime.datetime.fromtimestamp(t + k, datetime.timezone.utc).strftime(fmt) for k in (1, 2)]
        a, b = copy.deepcopy(sample), copy.deepcopy(sample)
        for x, stamp in ((a, stamps[0]), (b, stamps[1])):
            x["requests"][idx]["body"] = x["requests"][idx]["body"].replace(
                '\\"command\\":\\"', '\\"command\\":\\"echo ' + stamp + '; ', 1)
        check(f"R3-2 control: two in-window {label} in command text are reported", differs(a, b))
    # (3) Swapped top-level members of a main request body (byte-exact).
    main = next(i for i, r in enumerate(sample["requests"]) if r["kind"] == "main")
    lead, node, trail = jparse(sample["requests"][main]["body"])
    members = list(node[1])
    members[0], members[1] = [members[1][0]] + members[1][1:5] + [members[0][5]], [members[0][0]] + members[0][1:5] + [members[1][5]]
    swapped = copy.deepcopy(sample)
    swapped["requests"][main]["body"] = lead + unparse(("obj", members, None)) + trail
    same_meaning = json.loads(swapped["requests"][main]["body"]) == json.loads(sample["requests"][main]["body"])
    check("R3-2 control: two swapped top-level members of a main request body (same JSON) are reported",
          same_meaning and swapped["requests"][main]["body"] != sample["requests"][main]["body"] and differs(sample, swapped))
    # (4) Whitespace moved between members of a payload whose member order
    #     is free: reported. A pure member swap there: equal.
    usage = sample["files"]["context_usage.json"]
    keys = re.findall(r'"([A-Za-z]+)":', usage)
    a, b = copy.deepcopy(sample), copy.deepcopy(sample)
    a["files"]["context_usage.json"] = usage.replace(f'"{keys[0]}":', f'"{keys[0]}": ', 1)
    b["files"]["context_usage.json"] = usage.replace(f'"{keys[1]}":', f'"{keys[1]}": ', 1)
    check("R3-2 control: whitespace moved between two members of a free-order payload is reported", differs(a, b))
    lead, node, trail = jparse(usage)
    m = list(node[1])
    m[0], m[1] = [m[1][0]] + m[1][1:5] + [m[0][5]], [m[0][0]] + m[0][1:5] + [m[1][5]]
    perm = copy.deepcopy(sample)
    perm["files"]["context_usage.json"] = lead + unparse(("obj", m, None)) + trail
    check("R3-2 positive control: a pure member swap of that payload compares equal",
          perm["files"]["context_usage.json"] != usage and not differs(sample, perm))
    # (5) Round records moved to the front: the round's happens-after edges
    #     (all_tools_finished / execution_complete after their calls) break.
    lines = round_sample["stages"].splitlines()
    rounds = [l for l in lines if json.loads(l).get("stage", "").startswith("round.") and not json.loads(l).get("call")]
    moved = copy.deepcopy(round_sample)
    moved["stages"] = "\n".join(rounds + [l for l in lines if l not in rounds]) + "\n"
    check(f"R3-2 control: the {len(rounds)} round records moved to the front are reported",
          len(rounds) >= 2 and differs(round_sample, moved))
    # (6) The Bash tool's own measured fields in its saved result: absorbed;
    #     any other field of that result: reported.
    conv = sample["files"]["conversation.json"]
    pid = re.search(r'\\"pid\\":(\d+)', conv)
    a = copy.deepcopy(sample)
    a["files"]["conversation.json"] = conv.replace(pid.group(0), pid.group(0).replace(pid.group(1), str(int(pid.group(1)) + 7)), 1)
    check("R3-2 positive control: the Bash result's own pid in conversation.json is a seam", pid is not None and not differs(sample, a))
    b = copy.deepcopy(sample)
    b["files"]["conversation.json"] = conv.replace('\\"exit_code\\":0', '\\"exit_code\\":1', 1)
    check("R3-2 control: another field of the same Bash result (exit_code) is reported",
          b["files"]["conversation.json"] != conv and differs(sample, b))


PRODUCT_CLOCK_PREFIXES = ("System Note", "Assistant reply time", "Run clock", "TOOL ROUND", "(delivered ",
                          "Result delivered", "Available space", "--- ")


def fixture_corpus_controls():
    """Codex impl round 4 (template seam): every fixture-authored text — user
    messages, tool commands/outputs, provider replies, seeded history — comes
    from the driver source. None of it may contain a clock template match or
    even one of the product's clock-note prefixes, so the template seam can
    never mask fixture input; any masked phrase in a capture was rendered by
    the product (or is identical on both sides)."""
    src = open(DRIVER, encoding="utf-8").read()
    hits = {k: [m.group(0) for m in t.finditer(src)] for k, t in TEMPLATES.items()}
    hits = {k: v for k, v in hits.items() if v}
    prefixes = [p for p in PRODUCT_CLOCK_PREFIXES if p in src]
    check("template seam: the fixture corpus (driver source) contains no clock template match and none of the "
          "product's clock-note prefixes", not hits and not prefixes, f"{hits} {prefixes}")


def template_seam_controls(sample):
    """Codex impl round 4, three comparator controls (verbatim inputs); each
    must be reported. Plus one disclosed-residual row: a whole line in the
    product's exact note form is masked wherever a listed location holds it."""
    import copy

    def differs(a, b):
        return first_diff(normalise(a), normalise(b)) is not None

    # (1) Trailing member whitespace moved without any member permutation.
    a, b = copy.deepcopy(sample), copy.deepcopy(sample)
    a["files"]["context_usage.json"] = '{"a":1 ,"b":2\t,"c":3}'
    b["files"]["context_usage.json"] = '{"a":1\t,"b":2 ,"c":3}'
    check("R4 comparator control: trailing member whitespace moved in a free-order payload is reported", differs(a, b))
    a, b = copy.deepcopy(sample), copy.deepcopy(sample)
    a["files"]["context_usage.json"] = '{"a":1 ,"b":2 ,"c":3}'
    b["files"]["context_usage.json"] = '{"b":2 ,"c":3 ,"a":1}'
    check("R4 comparator positive control: a pure permutation with uniform separators compares equal", not differs(a, b))
    # (2) Outer whitespace of an embedded Bash JSON result.
    conv = sample["files"]["conversation.json"]
    content = None
    for msg in json.loads(conv):
        for inter in (msg.get("toolInteractions") or []):
            for res in inter.get("results", []):
                if isinstance(res.get("content"), str) and '"pid"' in res["content"]:
                    content = res["content"]
                    break
    raw = spelled = None
    if content is not None:
        for style, enc in enc_styles(content).items():
            if enc in conv:
                raw, spelled = enc, enc_styles(" " + content + " ")[style]
                break
    padded = copy.deepcopy(sample)
    if raw:
        padded["files"]["conversation.json"] = conv.replace(raw, spelled, 1)
    check("R4 comparator control: outer whitespace added around a saved Bash result's JSON is reported",
          raw is not None and differs(sample, padded), "Bash result not located" if raw is None else "")
    # (3) A quoted clock phrase in an appended user message.
    main = next(i for i, r in enumerate(sample["requests"]) if r["kind"] == "main")

    def with_user(text):
        lead, node, trail = jparse(sample["requests"][main]["body"])
        members = [list(m) for m in node[1]]
        k = next(i for i, m in enumerate(members) if json.loads(m[1]) == "messages")
        arr = members[k][4]
        item = ["", ("obj", [["", '"role"', "", "", ("str", '"user"'), ""],
                             ["", '"content"', "", "", ("str", json.dumps(text)), ""]], None), ""]
        members[k][4] = ("arr", list(arr[1]) + [item], None)
        x = copy.deepcopy(sample)
        x["requests"][main]["body"] = lead + unparse(("obj", members, None)) + trail
        return x
    check("R4 comparator control: 'quote: Assistant reply time: 01:02:03' vs '…22:33:44' in an appended user "
          "message is reported", differs(with_user("quote: Assistant reply time: 01:02:03"),
                                         with_user("quote: Assistant reply time: 22:33:44")))
    check("R4 comparator control: a reply-time phrase quoted mid-line in a user message is reported",
          differs(with_user("she said Assistant reply time: 01:02 yesterday"),
                  with_user("she said Assistant reply time: 22:33 yesterday")))
    residual = not differs(with_user("Assistant reply time: 01:02:03"), with_user("Assistant reply time: 22:33:44"))
    check("R4 disclosed residual (template seam, not provenance): a whole line in the product's exact note form "
          f"is masked at a listed location (masked: {residual})", residual)


def o1(base_bin, cand_bin, out):
    # Comparator calibration: the same 0.2.56 binary run twice.
    first, second = run(base_bin, "o1:pre:success", out), run(base_bin, "o1:pre:success", out + "/again")
    if "__failed__" not in first and "__failed__" not in second:
        raw_differs = any(first["files"].get(k) != second["files"].get(k) for k in first["files"])
        check(f"comparator: 0.2.56 run twice compares equal after normalisation "
              f"(raw persisted JSON key order differs between runs: {raw_differs})",
              first_diff(normalise(first), normalise(second)) is None, first_diff(normalise(first), normalise(second)) or "")
    # More calibration: the seams absorb exactly the product's own run-to-run
    # nondeterminism (clocks, pid, member order) on the paths that carry it.
    for scenario in ("o1:mid:error", "o9:loop:responses:render", "f1:rich"):
        x, y = run(base_bin, scenario, out + "/cal1"), run(base_bin, scenario, out + "/cal2")
        if "__failed__" in x or "__failed__" in y:
            check(f"comparator: 0.2.56 {scenario} run twice", False, x.get("__failed__") or y.get("__failed__"))
            continue
        d = first_diff(normalise(x), normalise(y))
        check(f"comparator: 0.2.56 {scenario} run twice compares equal (raw differs: {x != y})", d is None, d or "")
    bd, cd = discovery(base_bin), discovery(cand_bin)
    check("O1 command discovery (--help, help, driver --help; piped, stdout on an 80-column PTY, all on the PTY): "
          "output, written files and settings ≡ 0.2.56", bd == cd,
          first_diff(bd, cd) or "")
    for scenario in O1:
        b = normalise(run(base_bin, scenario, out))
        c = normalise(run(cand_bin, scenario, out))
        if "__failed__" in b or "__failed__" in c:
            check(f"O1 {scenario}", False, f"run failed: {b.get('__failed__') or c.get('__failed__')}")
            continue
        site, variant = scenario.split(":")[1:3]
        error = b.get("error") or ""
        exercised = {
            # Pre site with nothing prunable: today's "cannot fit" error.
            "exhausted": ("other" in kinds(b)) if site == "mid" else "context budget cannot fit" in error,
            "stop": bool(b.get("replies")) and "summary" in kinds(b),
            "snapshot-fault": "injected snapshot fault" in error or "injected snapshot fault" in json.dumps(b.get("notices")),
            "history-fault": "summary" in kinds(b),
        }.get(variant, "summary" in kinds(b))
        check(f"O1 {scenario}: the scenario exercised its path on 0.2.56 (requests {kinds(b)})", exercised,
              f"notes {b.get('notes')} error {b.get('error')}")
        d = first_diff(b, c)
        check(f"O1 {scenario}: candidate OFF ≡ 0.2.56 (requests, history, files, settings, notices, replies, error, activities, stages)",
              d is None, d or "")


def o9(base_bin, cand_bin, out):
    raws = {}
    for scenario in O9:
        raws[scenario] = run(base_bin, scenario, out)
        b = normalise(raws[scenario])
        c = normalise(run(cand_bin, scenario, out))
        if "__failed__" in b or "__failed__" in c:
            check(f"O9 {scenario}", False, f"run failed: {b.get('__failed__') or c.get('__failed__')}")
            continue
        variant = scenario.split(":")[3]
        needed = {"render": "restore", "image": None, "success": None}[variant]
        if needed:
            check(f"O9 {scenario}: the render-error path ran on 0.2.56", needed in b["receipts"], f"{b['receipts']}")
        if variant == "image":
            check(f"O9 {scenario}: the image-rejection resend ran on 0.2.56",
                  any("rejected an image" in n for n in b.get("notices", [])), f"{b.get('notices')} {kinds(b)}")
        check(f"O9 {scenario}: ordered receipt calls identical {b['receipts']}", b["receipts"] == c["receipts"],
              f"base {b['receipts']} cand {c['receipts']}")
        d = first_diff(b, c)
        check(f"O9 {scenario}: everything else identical too", d is None, d or "")
    text_sample, binary_sample = raws.get("o9:loop:chat:render"), raws.get("o9:loop:chat:image")
    round_sample = raws.get("o9:loop:chat:success")
    if all(x and "__failed__" not in x for x in (text_sample, binary_sample, round_sample)):
        comparator_controls(text_sample, binary_sample)
        located_seam_controls(text_sample, round_sample)
        template_seam_controls(text_sample)


def prefix_index(raw):
    if "__failed__" in raw or not raw.get("history"):
        return None
    history = json.loads(raw["history"])
    return next((i for i, m in enumerate(history) if m.get("content") == "over the maximum"), None)


def frozen_prefix(raw):
    """The in-memory history (driver encoder, sorted keys) up to and
    including the trigger, losslessly represented with the message seams,
    UUIDs numbered within the prefix alone."""
    idx = prefix_index(raw)
    if idx is None:
        return None, None
    nz = Normaliser(raw)
    text = nz.env(raw["history"])
    node = jparse(text)[1]
    profile = message_profile(text, False)
    rep_items = [[w0, rep(v, profile, ("*",)), w3] for w0, v, w3 in node[1][:idx + 1]]
    return json.loads(raw["history"])[:idx + 1], nz.number(rep_items)


def snapshots(raw):
    out = {}
    for k, v in sorted(raw["files"].items()):
        if k.startswith("prune-archives/"):
            nz = Normaliser(raw)
            out[k] = nz.number(nz.file(k, v))
    return out


def f1(base_bin, cand_bin, out):
    for scenario in F1:
        rb, rc = run(base_bin, scenario, out, mode="off"), run(cand_bin, scenario, out, mode="on")
        b, c = normalise(rb), normalise(rc)
        if "__failed__" in b or "__failed__" in c:
            check(f"F1 {scenario}", False, f"run failed: {b.get('__failed__') or c.get('__failed__')}")
            continue
        (decoded_b, pb), (_, pc) = frozen_prefix(rb), frozen_prefix(rc)
        pruned = decoded_b is not None and any(m.get("prunedContextSummary") for m in decoded_b if isinstance(m, dict))
        check(f"F1 {scenario}: 0.2.56 pruned inline (a summary anchor in the prefix)", pruned, f"{kinds(b)}")
        bm = [r["body"] for r in b["requests"] if r["kind"] == "main"]
        cm = [r["body"] for r in c["requests"] if r["kind"] == "main"]
        cand_markers = set(re.findall(r"RESULT-[A-Za-z0-9-]+ ", json.dumps(cm[0]))) if cm else set()
        base_markers = set(re.findall(r"RESULT-[A-Za-z0-9-]+ ", json.dumps(bm[0]))) if bm else set()
        check(f"F1 {scenario}: the candidate ran ON (first request unpruned, frozen job applied later); 0.2.56 inline (first request pruned)",
              bool(cand_markers - base_markers),
              f"base kinds {kinds(b)} cand kinds {kinds(c)}")
        if scenario == "f1:rich":
            text = json.dumps(decoded_b)
            check("F1 f1:rich: the oldest of four full anchors was demoted on 0.2.56 (stub + snapshot link)",
                  "Older fixture summary 0" not in text and "Older fixture summary 2" in text, "")
        d = first_diff(pb, pc)
        check(f"F1 {scenario}: frozen prefix identical, metadata kept (references, coverage, measuredTokens, demotion)",
              pb is not None and d is None, d or "missing prefix")
        sb, sc = snapshots(rb), snapshots(rc)
        check(f"F1 {scenario}: every snapshot file identical ({len(sb)} files)", bool(sb) and sb == sc,
              first_diff(sb, sc) or f"base {sorted(sb)} cand {sorted(sc)}")
        descriptions = [r for r in c["requests"] if r["kind"] == "description"]
        base_descriptions = [r for r in b["requests"] if r["kind"] == "description"]
        if scenario in ("f1:media", "f1:descfail", "f1:descfail-first", "f1:fallback"):
            check(f"F1 {scenario}: 0.2.56 made description requests ({len(base_descriptions)})",
                  len(base_descriptions) >= 1, f"{kinds(b)}")
        f1_path_checks(scenario, rb, rc)
        check(f"F1 {scenario}: description requests identical (count, order, bytes)", descriptions == base_descriptions,
              first_diff(base_descriptions, descriptions) or "")
        store = "offdiff-descriptions.json"
        check(f"F1 {scenario}: saved descriptions identical", b["files"].get(store) == c["files"].get(store),
              first_diff(b["files"].get(store), c["files"].get(store)) or "")


def described_files(body):
    m = re.search(r"Files: ([^\\\n]*)", body)
    return [x.strip() for x in m.group(1).split(",")] if m else []


def f1_path_checks(scenario, rb, rc):
    """Path-exercised assertions on 0.2.56's run of each fault variant
    (Codex impl round 3, R3-3); the candidate's equality is checked above."""
    descs = [r for r in rb["requests"] if r["kind"] == "description"]
    store = json.loads(rb["files"].get("offdiff-descriptions.json", "{}") or "{}")
    if scenario == "f1:descfail":
        shared = [i for i, r in enumerate(descs) if "shared-report.txt" in described_files(r["body"])]
        winner = store.get("shared-report.txt", "")
        m = re.match(r"description-(\d+) of shared-report\.txt\.$", winner)
        check("F1 f1:descfail: the first request for the repeated file failed, the later action requested it "
              f"again (requests {[i + 1 for i in shared]}) and the second request's value was saved ({winner!r})",
              len(shared) == 2 and m is not None and int(m.group(1)) == shared[1] + 1
              and descs[shared[0]]["body"] != descs[shared[1]]["body"],
              f"shared {shared} winner {winner!r}")
    if scenario == "f1:descfail-first":
        check("F1 f1:descfail-first: the failed first request's file has no saved description; the others do",
              "f1-user.png" not in store and "shared-report.txt" in store, f"{store}")
    if scenario == "f1:fallback":
        skipped = sorted(k for k, v in store.items() if v == "File skipped (batch limit of 8 reached)")
        large = store.get("fb-big.txt", "")
        pdf = store.get("fb-pages.pdf", "")
        sent = sorted({f for r in descs for f in described_files(r["body"])})
        # The 12-page PDF goes through the page-cap branch (> 10 pages) and is
        # rendered to page images for the description request on macOS; a
        # platform that cannot open it sends no pages (both builds alike).
        pdf_pages = sum(r["body"].count("data:image\\/jpeg") for r in descs if described_files(r["body"]) == ["fb-pages.pdf"])
        pdf_ok = pdf_pages >= 1 if sys.platform == "darwin" else bool(pdf)
        check(f"F1 f1:fallback: batch-limit fallbacks {skipped}, large-file fallback {large!r}, PDF {pdf!r} "
              f"(rendered page images sent: {pdf_pages})",
              skipped == ["fb-8.txt", "fb-9.txt"] and large.startswith("Large file (") and bool(pdf) and pdf_ok
              and "fb-9.txt" not in sent and "fb-big.txt" not in sent and "fb-1.txt" in sent,
              f"store {store} sent {sent}")
        check("F1 f1:fallback: files already saved earlier in the prune were not requested again (overlay)",
              sum(f == "fb-0.txt" for r in descs for f in described_files(r["body"])) == 1
              and sum(f == "fb-1.txt" for r in descs for f in described_files(r["body"])) == 1, f"{[described_files(r['body']) for r in descs]}")
    if scenario == "f1:demotefail":
        for label, r in (("0.2.56", rb), ("candidate ON", rc)):
            history = json.loads(r["history"])
            kept = "Older fixture summary 0" in json.dumps(history)
            noticed = sum(n.startswith("Older summaries stay in full for now") for n in r.get("maintenanceNotices", [])) == 1
            committed = any(m.get("prunedContextSummary") and "Fixture prune summary" in m["prunedContextSummary"]
                            for m in history if isinstance(m, dict))
            check(f"F1 f1:demotefail [{label}]: demotion snapshot failed → full summaries kept, one notice, the prune still committed",
                  kept and noticed and committed, f"kept {kept} noticed {noticed} committed {committed} notices {r.get('notices')}")


NOTICE = "so I can keep going. This can take a few minutes on a local model."


def control(cand_tree, base_bin, out):
    """Positive controls on a separately patched candidate (one rebuild):
    O9 — Codex's capture; O1 — a one-word change in the OFF prune notice.
    Each differential must report its defect."""
    patch_cm = os.path.join(cand_tree, CM)
    pristine = open(patch_cm, encoding="utf-8").read()
    text = pristine
    # The first occurrence is the tool loop's (0.2.56 lines 8686/8687); the
    # second is the forced final's.
    assert text.count(CONTROL_LINE) == 2 and text.count(NOTICE) == 1
    text = text.replace(CONTROL_LINE, CONTROL_LINE + "                if backgroundPruneEngaged { _ = 0 }\n", 1)
    text = text.replace(NOTICE, NOTICE.replace("keep going", "carry on"))
    open(patch_cm, "w", encoding="utf-8").write(text)
    # R2-1 compiled control: the newline variant of the closure initializer.
    st_path = os.path.join(cand_tree, SELFTEST_FILE)
    st_pristine = open(st_path, encoding="utf-8").read()
    assert st_pristine.count(SELFTEST_CONFIG) == 1
    open(st_path, "w", encoding="utf-8").write(st_pristine.replace(SELFTEST_CONFIG, NEWLINE_MUTANT, 1))
    try:
        bad = build(cand_tree, "control")
    finally:
        open(patch_cm, "w", encoding="utf-8").write(pristine)
        open(st_path, "w", encoding="utf-8").write(st_pristine)
    gate_root = tempfile.mkdtemp(prefix="bgprune-gatecopy-")
    try:
        for name in ("TelegramConcierge", "Package.swift", "Package.resolved"):
            src = os.path.join(ROOT, name)
            (shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, os.path.join(gate_root, name))
        g = os.path.join(gate_root, SELFTEST_FILE)
        source = open(g, encoding="utf-8").read()
        assert source.count(SELFTEST_CONFIG) == 1
        open(g, "w", encoding="utf-8").write(source.replace(SELFTEST_CONFIG, NEWLINE_MUTANT, 1))
        spec = importlib.util.spec_from_file_location("bgp_gate", os.path.join(HERE, "bg_prune_off_identity_test.py"))
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        findings = gate.validate(gate_root)
    finally:
        shutil.rmtree(gate_root, ignore_errors=True)
    check("R2-1 control: the structural gate rejects the compiled newline initializer",
          any("selftest configuration must be a plain" in f for f in findings), f"{findings}")
    bd, cd = discovery(base_bin), discovery(bad)
    check("R2-1 control: the discovery differential reports the side effect independently of the gate",
          bd != cd and any("CODEX_OFF_DISCOVERY_SIDE_EFFECT" in o["stdout"] for o in cd), first_diff(bd, cd) or "no difference")
    b1 = normalise(run(base_bin, "o1:pre:success", out))
    c1 = normalise(run(bad, "o1:pre:success", out))
    d = first_diff(b1, c1)
    check("O1 control: a changed OFF notice word is reported", d is not None and "notices" in d, d or "no difference")
    scenario = "o9:loop:responses:success"
    b = normalise(run(base_bin, scenario, out))
    c = normalise(run(bad, scenario, out))
    # Codex's capture: a statement between the tool loop's Responses clear and
    # its `else` makes the `else` bind to it (gate bypassed for this fixture).
    check("O9 control: 0.2.56 calls only responses-clear on Responses", bool(b.get("receipts"))
          and set(b.get("receipts", [])) == {"responses-clear"}, f"{b.get('receipts')}")
    check("O9 control: the capture shows an extra chat-clear after responses-clear",
          "chat-clear" in c.get("receipts", []), f"{c.get('receipts')}")
    check("O9 control: the differential reports the defect", b.get("receipts") != c.get("receipts"))
    # R3-1 compiled control: the shadowing factory (second, incremental build).
    st_pristine = open(st_path, encoding="utf-8").read()
    assert st_pristine.count(RUN_LINE) == 1
    open(st_path, "w", encoding="utf-8").write(st_pristine.replace(RUN_LINE, FACTORY_MUTANT + RUN_LINE, 1))
    try:
        factory = build(cand_tree, "control (factory)")
    finally:
        open(st_path, "w", encoding="utf-8").write(st_pristine)
    gate_root = tempfile.mkdtemp(prefix="bgprune-gatecopy-")
    try:
        for name in ("TelegramConcierge", "Package.swift", "Package.resolved"):
            src = os.path.join(ROOT, name)
            (shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, os.path.join(gate_root, name))
        g = os.path.join(gate_root, SELFTEST_FILE)
        source = open(g, encoding="utf-8").read()
        open(g, "w", encoding="utf-8").write(source.replace(RUN_LINE, FACTORY_MUTANT + RUN_LINE, 1))
        findings = gate.validate(gate_root)
    finally:
        shutil.rmtree(gate_root, ignore_errors=True)
    check("R3-1 control: the structural gate rejects the shadowing CommandConfiguration factory",
          any("shadows reserved name 'CommandConfiguration'" in f for f in findings), f"{findings}")
    bd, fd = discovery(base_bin), discovery(factory)
    streams_equal = [(o["exit"], o["stdout"], o["stderr"]) for o in bd] == [(o["exit"], o["stdout"], o["stderr"]) for o in fd]
    marker = [o["args"] for o in fd if any(k.endswith("codex-off-discovery.txt") for k in o["effects"])]
    check("R3-1 control: the discovery differential reports the factory's help-time write through the "
          f"observed effects (stdout/stderr/exit identical: {streams_equal}; written at {marker})",
          bd != fd and len(marker) == 2 * len(DISCOVERY_MODES), first_diff(bd, fd) or "no difference")
    # R4-1 compiled control (Codex impl round 4, verbatim): a nested
    # @_silgen_name redefining the Darwin overlay ioctl symbol (third,
    # incremental build). The gate must reject it; on macOS the
    # terminal-attached discovery must observe its write.
    probe_rel = "TelegramConcierge/Services/BackgroundPruneSymbolProbe.swift"
    probe_path = os.path.join(cand_tree, probe_rel)
    open(probe_path, "w", encoding="utf-8").write(SYMBOL_PROBE)
    try:
        probe_bin = build(cand_tree, "control (symbol probe)")
    finally:
        os.remove(probe_path)
    gate_root = tempfile.mkdtemp(prefix="bgprune-gatecopy-")
    try:
        for name in ("TelegramConcierge", "Package.swift", "Package.resolved"):
            src = os.path.join(ROOT, name)
            (shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, os.path.join(gate_root, name))
        open(os.path.join(gate_root, probe_rel), "w", encoding="utf-8").write(SYMBOL_PROBE)
        findings = gate.validate(gate_root)
    finally:
        shutil.rmtree(gate_root, ignore_errors=True)
    check("R4-1 control: the structural gate rejects Codex's nested @_silgen_name ioctl override",
          any("attribute @_silgen_name not allowed" in f for f in findings), f"{findings}")
    bd, pd = discovery(base_bin), discovery(probe_bin)
    marked = [(o["mode"], o["args"]) for o in pd if any(k.endswith("codex-off-symbol.txt") for k in o["effects"])]
    pipe_equal = [o for o in bd if o["mode"] == "pipe"] == [o for o in pd if o["mode"] == "pipe"]
    if sys.platform == "darwin":
        check("R4-1 control: the terminal-attached discovery reports the override's write "
              f"(piped discovery alone sees nothing: {pipe_equal}; written at {marked})",
              bd != pd and bool(marked) and all(m != "pipe" for m, _ in marked), first_diff(bd, pd) or "no difference")
    else:
        print(f"- R4-1 note: the probe's symbol is the Darwin overlay's; on this platform it is inert "
              f"(written at {marked}); the gate rejection above is the platform-independent check")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["o1", "o9", "f1", "control"])
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--reuse", help="development only: reuse trees kept by an earlier --keep run "
                                    "(the driver file is re-copied, then an incremental build)")
    ap.add_argument("--scenario", help="development only: run one scenario name")
    args = ap.parse_args()
    scratch = args.reuse or tempfile.mkdtemp(prefix="bgprune-offdiff-trees-")
    if args.scenario:
        global O1, O9, F1
        O1 = [x for x in O1 if x == args.scenario]
        O9 = [x for x in O9 if x == args.scenario]
        F1 = [x for x in F1 if x == args.scenario]
    try:
        if args.reuse:
            base, cand = os.path.join(scratch, "base"), os.path.join(scratch, "cand")
            for tree in (base, cand):
                shutil.copy2(DRIVER, os.path.join(tree, "TelegramConcierge/CLI/BgPruneOffDiffDriver.swift"))
            shutil.rmtree(os.path.join(scratch, "out"), ignore_errors=True)
        else:
            base, cand = make_trees(scratch)
            patch_tree(base)
            patch_tree(cand)
        print("building 0.2.56 + driver …", flush=True)
        base_bin = build(base, "base")
        print("building candidate + driver …", flush=True)
        cand_bin = build(cand, "candidate")
        out = os.path.join(scratch, "out")
        os.makedirs(out)
        fixture_corpus_controls()
        if args.only in (None, "o1"):
            o1(base_bin, cand_bin, out)
        if args.only in (None, "o9"):
            o9(base_bin, cand_bin, out)
        if args.only in (None, "f1"):
            f1(base_bin, cand_bin, out)
        if args.only in (None, "control"):
            control(cand, base_bin, out)
    finally:
        if args.keep or args.reuse:
            print(f"kept {scratch}")
        else:
            shutil.rmtree(scratch, ignore_errors=True)
    print(f"\n{total - failures}/{total} differential checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
