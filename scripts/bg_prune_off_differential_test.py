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

Normalisation (documented seams only): scratch paths and loopback ports;
UUIDs renamed by first appearance; wall-clock timestamps (ISO strings,
clock times, numeric date fields) replaced by a token; stage-marker
sequence/token/clock fields dropped. Nothing else (no metadata, routing,
request or extra-request normalisation).

Usage: bg_prune_off_differential_test.py [--only o1|o9|f1|control] [--keep]
"""
import argparse
import hashlib
import importlib.util
import calendar
import time
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
F1 = ["f1:basic", "f1:rich", "f1:media", "f1:descfail", "f1:error", "f1:rejected", "f1:tools",
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


UUID_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
ISO_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?")
NUM_RE = re.compile(r"(?<![\w.])(\d{9,10}(?:\.\d+)?|\d{13})(?![\w])")
CLOCK_RE = re.compile(r"(?<![\d:.])(\d{1,2}):(\d{2})(?::(\d{2}))?(?![\d:])")
FREE_RE = re.compile(r"Available space: \d+ bytes")
# Endpoint fingerprint of the loopback base URL (derived from its random port).
ENDPOINT_RE = re.compile(r"#127\.0\.0\.1-[0-9a-f]{8}")
# Measured fields of the Bash tool's own result object (its process id and
# measured wait/run durations). Only these three keys of the bash result.
PID_RE = re.compile(r'(\\?"(?:pid|waited_seconds|running_for_seconds)\\?":)[0-9.]+')
REFERENCE_DATE = 978307200  # Foundation's reference date (2001-01-01) as Unix time
STAGE_CLOCK_FIELDS = {"seq", "t", "mono_ms", "pid", "elapsed_ms"}
# Measured durations, located by file and field (never by field name alone).
FILE_DURATION_FIELDS = {
    "bash_jobs_stats.json": re.compile(r'("[A-Za-z_.]*_ms"\s*:\s*)\d+'),
    "responses_usage.json": re.compile(r'("durationMs"\s*:\s*)\d+'),
}


class Normaliser:
    """Narrow, location-scoped substitutions on the raw strings (round-2
    R2-3): nothing is re-encoded, no field name anywhere in request/user/
    tool data is used to drop a value. The seams are:
      * the run's own scratch paths, loopback port and the endpoint
        fingerprint derived from it, free-disk bytes in one message;
      * wall-clock values that fall inside this run's own time window
        (ISO strings, clock times, Unix/Foundation numeric dates); fixed
        fixture times are outside the window and compared exactly;
      * UUIDs renamed consistently by first appearance (relations kept);
      * the Bash tool's reported pid; `*_ms` counters in bash_jobs_stats.json;
      * stage markers: clock fields dropped, ids renamed consistently,
        order kept within each call / stage family (see stages()).
    """

    def __init__(self, result):
        self.result = result
        self.start = float(result.get("startedAt", 0)) - 120
        self.end = float(result.get("endedAt", 0)) + 120
        self.port = str(result.get("port", ""))
        self.data = result.get("dataRoot", "")
        self.config = result.get("configRoot", "")
        self.home = os.path.dirname(os.path.dirname(os.path.dirname(self.data))) if self.data else ""
        self.uuids = {}
        # The run's scratch root (all its paths live under it), with the
        # macOS /var ↔ /private/var alias.
        aliases = set()
        m = re.search(r"^(.*bgprune-offdiff-[0-9A-Fa-f-]{36})", self.data)
        if m:
            root = m.group(1)
            aliases.add(root)
            if root.startswith("/private/var/"):
                aliases.add(root[len("/private"):])
            elif root.startswith("/var/"):
                aliases.add("/private" + root)
        self.scratch_aliases = sorted(aliases, key=len, reverse=True)
        clocks = set()
        t = self.start
        while t <= self.end:
            lt = time.localtime(t)
            ut = time.gmtime(t)
            clocks.add((lt.tm_hour, lt.tm_min))
            clocks.add((ut.tm_hour, ut.tm_min))
            t += 30
        self.clocks = clocks

    def in_window(self, v):
        return self.start <= v <= self.end

    def iso(self, m):
        y, mo, d, h, mi, sec, off = m.groups()
        try:
            base = calendar.timegm((int(y), int(mo), int(d), int(h), int(mi), int(sec or 0)))
        except (ValueError, OverflowError):
            return m.group(0)
        candidates = []
        if off and off != "Z":
            sign = 1 if off[0] == "+" else -1
            hh, mm = off[1:3], off[-2:]
            candidates.append(base - sign * (int(hh) * 3600 + int(mm) * 60))
        else:
            candidates += [base, time.mktime((int(y), int(mo), int(d), int(h), int(mi), int(sec or 0), 0, 0, -1))]
        return "<TS>" if any(self.in_window(c) for c in candidates) else m.group(0)

    def num(self, m):
        v = float(m.group(1))
        for c in (v, v + REFERENCE_DATE, v / 1000):
            if self.in_window(c):
                return "-1"
        return m.group(0)

    def clock(self, m):
        h, mi = int(m.group(1)), int(m.group(2))
        return "<HM>" if (h, mi) in self.clocks else m.group(0)

    def uuid(self, m):
        key = m.group(0).upper()
        if key not in self.uuids:
            self.uuids[key] = f"<UUID{len(self.uuids)}>"
        return self.uuids[key]

    def subs(self, s):
        """Phase A: order-independent substitutions (no UUID numbering)."""
        for path, token in ((self.data, "<DATA>"), (self.config, "<CONFIG>"), (self.home, "<HOME>")):
            if path:
                s = s.replace(path, token).replace(path.replace("/", "\\/"), token)
        for alias in self.scratch_aliases:
            for form in (alias, alias.replace("/", "\\/"), alias.replace("/", "\\\\\\/")):
                s = s.replace(form, "<SCRATCH>")
        if self.port:
            s = s.replace("127.0.0.1:" + self.port, "127.0.0.1:<PORT>")
        s = ENDPOINT_RE.sub("#127.0.0.1-<EP>", s)
        s = FREE_RE.sub("Available space: <N> bytes", s)
        s = PID_RE.sub(r"\1<PID>", s)
        s = ISO_RE.sub(self.iso, s)
        s = NUM_RE.sub(self.num, s)
        s = CLOCK_RE.sub(self.clock, s)
        return s

    def canonical(self, s):
        """Product JSON written from unsorted dictionaries has a key order
        that varies between two runs of the SAME binary (the base-vs-base
        control demonstrates it). Such payloads are compared as JSON with
        order-insensitive objects (arrays stay ordered) PLUS a signature of
        the raw text's character multiset (UUIDs blanked): re-indentation,
        added/removed whitespace or any value change is still reported;
        only a pure key reordering compares equal."""
        t = s.strip()
        if t[:1] not in "[{":
            return s
        try:
            obj = json.loads(s)
        except ValueError:
            return s
        chars = hashlib.sha256("".join(sorted(UUID_RE.sub("<U>", s))).encode("utf-8")).hexdigest()
        return {"__json__": json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":")), "__chars__": chars}

    def phase_a(self, v):
        if isinstance(v, dict):
            return {k: self.phase_a(v[k]) for k in sorted(v)}
        if isinstance(v, list):
            return [self.phase_a(x) for x in v]
        if isinstance(v, str):
            return self.canonical(self.subs(v))
        return v

    def number_uuids(self, v):
        """Phase B: consistent UUID numbering, in canonical walk order."""
        if isinstance(v, dict):
            return {k: self.number_uuids(v[k]) for k in sorted(v)}
        if isinstance(v, list):
            return [self.number_uuids(x) for x in v]
        if isinstance(v, str):
            return UUID_RE.sub(self.uuid, v)
        return v

    def walk(self, v):
        return self.number_uuids(self.phase_a(v))

    def stages(self, raw):
        """Ordered per call id (records of one tool call) and per stage
        family (the part before the first '.') for records without a call:
        enter/exit order and pairing within a call are kept; only the
        interleaving between different calls/families is free. Ids are
        renamed by first appearance, so enter/exit pairs stay paired."""
        groups = {}
        ids = {}
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
            key = f"call:{out['call']}" if out.get("call") else "stage:" + str(out.get("stage", "")).split(".")[0]
            if "id" in out:
                local = ids.setdefault(key, {})
                out["id"] = local.setdefault(out["id"], f"<S{len(local)}>")
            groups.setdefault(key, []).append(out)
        return groups

    def run(self):
        r = dict(self.result)
        for k in ("dataRoot", "configRoot", "port", "startedAt", "endedAt"):
            r.pop(k, None)
        stages = r.pop("stages", "")
        files = r.pop("files", {})
        files = {k: (FILE_DURATION_FIELDS[os.path.basename(k)].sub(r"\1-1", v)
                     if os.path.basename(k) in FILE_DURATION_FIELDS else v) for k, v in files.items()}
        r = dict(r, files=files)
        r["stages"] = self.stages(stages)
        return self.walk(r)


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
DISCOVERY_ARGS = [["--help"], ["help"], ["__bgprune-off-diff", "--help"]]


def discovery(binary):
    """Command discovery output in an isolated home: what ArgumentParser
    evaluates for every registered command before any feature code runs."""
    outs = []
    for args in DISCOVERY_ARGS:
        root = tempfile.mkdtemp(prefix="bgprune-discovery-")
        try:
            env = {k: v for k, v in os.environ.items()
                   if not (k.startswith("BRIGLIA_") or k.startswith("ADA_") or k.startswith("SM_"))}
            home = os.path.join(root, "home")
            for sub in (".config", ".local/share", ".local/state", ".cache"):
                os.makedirs(os.path.join(home, sub))
            env.update(HOME=home, CFFIXED_USER_HOME=home, XDG_CONFIG_HOME=home + "/.config",
                       XDG_DATA_HOME=home + "/.local/share", XDG_STATE_HOME=home + "/.local/state",
                       XDG_CACHE_HOME=home + "/.cache", TMPDIR=root + "/")
            proc = subprocess.run([binary] + args, capture_output=True, text=True, env=env, timeout=60)
            outs.append({"args": args, "exit": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr})
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


def o1(base_bin, cand_bin, out):
    # Comparator calibration: the same 0.2.56 binary run twice.
    first, second = run(base_bin, "o1:pre:success", out), run(base_bin, "o1:pre:success", out + "/again")
    if "__failed__" not in first and "__failed__" not in second:
        raw_differs = any(first["files"].get(k) != second["files"].get(k) for k in first["files"])
        check(f"comparator: 0.2.56 run twice compares equal after normalisation "
              f"(raw persisted JSON key order differs between runs: {raw_differs})",
              first_diff(normalise(first), normalise(second)) is None, first_diff(normalise(first), normalise(second)) or "")
    bd, cd = discovery(base_bin), discovery(cand_bin)
    check("O1 command discovery (--help, help, driver --help): candidate output ≡ 0.2.56", bd == cd,
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
    if text_sample and binary_sample and "__failed__" not in text_sample and "__failed__" not in binary_sample:
        comparator_controls(text_sample, binary_sample)


def frozen_prefix(result):
    # The in-memory history as encoded by the driver itself (sorted keys,
    # identical encoder on both sides), canonicalised like every JSON payload.
    history = json.loads(result["history"]["__json__"])
    idx = next((i for i, m in enumerate(history) if m.get("content") == "over the maximum"), None)
    return None if idx is None else history[:idx + 1]


def snapshots(result):
    return {k: v for k, v in result["files"].items() if k.startswith("prune-archives/")}


def f1(base_bin, cand_bin, out):
    for scenario in F1:
        b = normalise(run(base_bin, scenario, out, mode="off"))
        c = normalise(run(cand_bin, scenario, out, mode="on"))
        if "__failed__" in b or "__failed__" in c:
            check(f"F1 {scenario}", False, f"run failed: {b.get('__failed__') or c.get('__failed__')}")
            continue
        pb, pc = frozen_prefix(b), frozen_prefix(c)
        pruned = pb is not None and any(m.get("prunedContextSummary") for m in pb if isinstance(m, dict))
        check(f"F1 {scenario}: 0.2.56 pruned inline (a summary anchor in the prefix)", pruned, f"{kinds(b)}")
        bm = [r["body"] for r in b["requests"] if r["kind"] == "main"]
        cm = [r["body"] for r in c["requests"] if r["kind"] == "main"]
        cand_markers = set(re.findall(r"RESULT-[A-Za-z0-9-]+ ", json.dumps(cm[0]))) if cm else set()
        base_markers = set(re.findall(r"RESULT-[A-Za-z0-9-]+ ", json.dumps(bm[0]))) if bm else set()
        check(f"F1 {scenario}: the candidate ran ON (first request unpruned, frozen job applied later); 0.2.56 inline (first request pruned)",
              bool(cand_markers - base_markers),
              f"base kinds {kinds(b)} cand kinds {kinds(c)}")
        if scenario == "f1:rich":
            text = json.dumps(pb)
            check("F1 f1:rich: the oldest of four full anchors was demoted on 0.2.56 (stub + snapshot link)",
                  "Older fixture summary 0" not in text and "Older fixture summary 2" in text, "")
        d = first_diff(pb, pc)
        check(f"F1 {scenario}: frozen prefix identical, metadata kept (references, coverage, measuredTokens, demotion)",
              pb is not None and d is None, d or "missing prefix")
        sb, sc = snapshots(b), snapshots(c)
        check(f"F1 {scenario}: every snapshot file identical ({len(sb)} files)", bool(sb) and sb == sc,
              first_diff(sb, sc) or f"base {sorted(sb)} cand {sorted(sc)}")
        descriptions = [r for r in c["requests"] if r["kind"] == "description"]
        base_descriptions = [r for r in b["requests"] if r["kind"] == "description"]
        if scenario in ("f1:media", "f1:descfail"):
            check(f"F1 {scenario}: 0.2.56 made description requests ({len(base_descriptions)})",
                  len(base_descriptions) >= (2 if scenario == "f1:descfail" else 1), f"{kinds(b)}")
        check(f"F1 {scenario}: description requests identical (count, order, bytes)", descriptions == base_descriptions,
              first_diff(base_descriptions, descriptions) or "")
        store = "offdiff-descriptions.json"
        check(f"F1 {scenario}: saved descriptions identical", b["files"].get(store) == c["files"].get(store),
              first_diff(b["files"].get(store), c["files"].get(store)) or "")


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
