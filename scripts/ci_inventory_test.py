#!/usr/bin/env python3
"""CI inventory test: nothing dropped, nothing weakened.

The pre-split workflow (one Linux job, one macOS job) is frozen in
scripts/fixtures/ci-inventory.json, recorded from an exact commit. This test
re-derives that fixture from the commit itself (so it provably came from the
pre-split file) and then checks the current .github/workflows/ci.yml:

  * workflow keys exactly {name, on, jobs}; name and the raw `on:` text frozen;
  * the five test jobs and the `CI complete` aggregator, with closed key sets,
    exact runs-on/container, an exact setup prefix per job;
  * per platform, the multiset of COMPLETE step mappings equals the frozen one
    (every key: name, run/uses/with, env, shell, working-directory, if,
    continue-on-error, timeout-minutes, ...), so nothing is lost, duplicated,
    altered or moved to the other platform;
  * `job-setup` amendments: a fixed extra setup step (e.g. host swap) that must
    sit, exactly once and unchanged, right after the setup prefix (and the
    inventory step) of every job of its platform, and on no other job;
  * frozen relative order inside each job, and co-location of prerequisites
    (build before its binary consumers, Playwright before the browser tests,
    Linux smoke with Node, each artifact upload with and after its producer);
  * the aggregator's exact structure, plus a behavioural truth table of its
    script over 1,026 synthetic `needs` contexts;
  * deliberate breaks: mutated copies of ci.yml (and of the fixture) must fail.

The YAML is read by ONE small strict parser for exactly the subset ci.yml
uses. Anything outside the subset is an error, never skipped.

Modes:
  (no argument)            full check (CI mode)
  --precheck               pre-split self-check: provenance + parser tests +
                           the current ci.yml still equals the recorded one
  --record COMMIT          (re)write the fixture from COMMIT:.github/workflows/ci.yml
  --psych REF [REF ...]    one-time oracle comparison against Ruby Psych
                           (REF is a file path or COMMIT:PATH); not a CI path
"""
import collections
import concurrent.futures
import copy
import hashlib
import itertools
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW_PATH = ".github/workflows/ci.yml"
FIXTURE_PATH = os.path.join(ROOT, "scripts", "fixtures", "ci-inventory.json")


# ---------------------------------------------------------------------------
# Strict YAML-subset parser
# ---------------------------------------------------------------------------

class ParseError(Exception):
    pass


KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_.-]*):(?:$| (.*)$)")
# YAML 1.1 words a full YAML loader would turn into booleans or null.
AMBIGUOUS_WORDS = {
    "y", "Y", "yes", "Yes", "YES", "n", "N", "no", "No", "NO",
    "on", "On", "ON", "off", "Off", "OFF",
    "True", "TRUE", "False", "FALSE",
    "null", "Null", "NULL", "~",
}
INT_RE = re.compile(r"^-?(0|[1-9][0-9]*)$")
PLAIN_FORBIDDEN_START = set("[]{}&*!|>'\"%@`#,?<")


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _is_blank(line):
    return line.strip(" ") == ""


def _is_comment(line):
    return line.lstrip(" ").startswith("#")


class _Parser:
    def __init__(self, text):
        if "\r" in text:
            raise ParseError("carriage return in file")
        if "\ufeff" in text:
            raise ParseError("byte-order mark in file")
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        for no, line in enumerate(lines, 1):
            if line == "---" or line.startswith("--- ") or line == "..." or line.startswith("... "):
                raise ParseError(f"line {no}: document marker (multiple documents are not supported)")
            if line.startswith("%"):
                raise ParseError(f"line {no}: directive")
        self.lines = lines
        self.n = len(lines)

    def err(self, i, msg):
        return ParseError(f"line {i + 1}: {msg}: {self.lines[i]!r}" if i < self.n else f"end of file: {msg}")

    def skip(self, i):
        while i < self.n and (_is_blank(self.lines[i]) or _is_comment(self.lines[i])):
            i += 1
        return i

    # -- top level: a mapping at column 0; `on:` kept as raw text -----------
    def parse_workflow(self):
        doc = {}
        i = self.skip(0)
        while i < self.n:
            line = self.lines[i]
            if "\t" in line:
                raise self.err(i, "tab character")
            if _indent(line) != 0:
                raise self.err(i, "unexpected indentation at top level")
            m = KEY_RE.match(line)
            if not m:
                raise self.err(i, "unrecognised line")
            key = m.group(1)
            if key in doc:
                raise self.err(i, f"duplicate key {key!r}")
            if key == "on":
                j = i + 1
                while j < self.n and not (self.lines[j] != "" and self.lines[j][0] not in " #"):
                    j += 1
                doc["on"] = "\n".join(self.lines[i:j]) + "\n"
                i = self.skip(j)
                continue
            if key in AMBIGUOUS_WORDS:
                raise self.err(i, f"ambiguous key {key!r}")
            value, i = self.parse_value(i, 0, m.group(2))
            doc[key] = value
        return doc

    def parse_block(self, i, ind):
        content = self.lines[i][ind:]
        if content == "-" or content.startswith("- "):
            return self.parse_seq(i, ind)
        return self.parse_map(i, ind)

    def parse_map(self, i, ind):
        result = {}
        while i < self.n:
            line = self.lines[i]
            li = _indent(line)
            if li < ind:
                break
            if "\t" in line:
                raise self.err(i, "tab character")
            if li > ind:
                raise self.err(i, "inconsistent indentation")
            content = line[ind:]
            if content == "-" or content.startswith("- "):
                raise self.err(i, "sequence entry where a mapping key was expected")
            m = KEY_RE.match(content)
            if not m:
                raise self.err(i, "unrecognised line")
            key = m.group(1)
            if key in AMBIGUOUS_WORDS:
                raise self.err(i, f"ambiguous key {key!r}")
            if key in result:
                raise self.err(i, f"duplicate key {key!r}")
            value, i = self.parse_value(i, ind, m.group(2))
            result[key] = value
        return result, i

    def parse_seq(self, i, ind):
        items = []
        while i < self.n:
            line = self.lines[i]
            li = _indent(line)
            if li < ind:
                break
            if "\t" in line:
                raise self.err(i, "tab character")
            if li > ind:
                raise self.err(i, "inconsistent indentation")
            content = line[ind:]
            if not (content == "-" or content.startswith("- ")):
                raise self.err(i, "mapping key where a sequence entry was expected")
            if content == "-":
                j = self.skip(i + 1)
                if j >= self.n or _indent(self.lines[j]) <= ind:
                    raise self.err(i, "empty sequence entry")
                value, i = self.parse_block(j, _indent(self.lines[j]))
                items.append(value)
                continue
            rest = content[2:]
            if rest.startswith(" "):
                raise self.err(i, "more than one space after '-'")
            if KEY_RE.match(rest):
                # `- key: value` opens a mapping whose keys sit at ind + 2.
                self.lines[i] = " " * (ind + 2) + rest
                value, i = self.parse_map(i, ind + 2)
                items.append(value)
                continue
            value = self.parse_scalar(i, rest)
            j = self.skip(i + 1)
            if j < self.n and _indent(self.lines[j]) > ind:
                raise self.err(j, "continuation lines of a plain scalar are not supported")
            items.append(value)
            i = j
        return items, i

    def parse_value(self, i, ind, rest):
        if rest is None or rest.strip(" ") == "" or rest.lstrip(" ").startswith("#"):
            j = self.skip(i + 1)
            if j >= self.n or _indent(self.lines[j]) <= ind:
                raise self.err(i, "empty value")
            return self.parse_block(j, _indent(self.lines[j]))
        if rest == "|":
            return self.parse_literal(i, ind)
        if rest[0] in "|>":
            raise self.err(i, "unsupported block scalar (only plain '|' is allowed)")
        value = self.parse_scalar(i, rest)
        j = self.skip(i + 1)
        if j < self.n and _indent(self.lines[j]) > ind:
            raise self.err(j, "continuation lines of a plain scalar are not supported")
        return value, j

    def parse_literal(self, i, ind):
        j = i + 1
        k = j
        while k < self.n and _is_blank(self.lines[k]):
            k += 1
        if k >= self.n or _indent(self.lines[k]) <= ind:
            raise self.err(i, "empty block scalar")
        bi = _indent(self.lines[k])
        out = []
        while j < self.n:
            line = self.lines[j]
            if _is_blank(line):
                if len(line) > bi:
                    raise self.err(j, "whitespace-only line deeper than the block indentation")
                out.append("")
                j += 1
                continue
            li = _indent(line)
            if li < bi:
                if li > ind and not _is_comment(line):
                    raise self.err(j, "inconsistent indentation in block scalar")
                break
            out.append(line[bi:])
            j += 1
        while out and out[-1] == "":
            out.pop()
        return "\n".join(out) + "\n", self.skip(j)

    def parse_scalar(self, i, s):
        if "\t" in s:
            raise self.err(i, "tab character")
        if s.startswith("'") or s.startswith('"'):
            q = s[0]
            end = s.find(q, 1)
            if end < 0:
                raise self.err(i, "unterminated quoted scalar")
            value = s[1:end]
            tail = s[end + 1:]
            if tail and not re.match(r"^ +(#.*)?$", tail):
                raise self.err(i, "text after a quoted scalar (escapes and '' are not supported)")
            if q == '"' and "\\" in value:
                raise self.err(i, "backslash escape in double-quoted scalar")
            return value
        k = s.find(" #")
        if k >= 0:
            s = s[:k]
        s = s.rstrip(" ")
        if s == "":
            raise self.err(i, "empty scalar")
        if s[0] in PLAIN_FORBIDDEN_START:
            raise self.err(i, f"unsupported indicator {s[0]!r} at the start of a plain scalar")
        if s == "-" or s.startswith("- "):
            raise self.err(i, "unsupported plain scalar")
        if ": " in s or s.endswith(":"):
            raise self.err(i, "plain scalar containing ': '")
        if s in ("true", "false"):
            return s == "true"
        if s in AMBIGUOUS_WORDS:
            raise self.err(i, f"ambiguous plain scalar {s!r}")
        if INT_RE.match(s):
            return int(s)
        if re.match(r"^[-+]?\.?[0-9]", s) or re.match(r"^[-+]?\.(inf|Inf|INF|nan|NaN|NAN)$", s):
            raise self.err(i, f"numeric-looking plain scalar {s!r} (quote it)")
        return s


def parse_workflow(text):
    return _Parser(text).parse_workflow()


def parse_document(text):
    """Parse a generic document (used by the parser tests): a column-0 mapping."""
    p = _Parser(text)
    i = p.skip(0)
    if i >= p.n:
        raise ParseError("empty document")
    value, i = p.parse_block(i, 0)
    if i < p.n:
        raise p.err(i, "trailing content")
    return value


def canon(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


# ---------------------------------------------------------------------------
# Fixture: derive the frozen inventory from the pre-split workflow
# ---------------------------------------------------------------------------

def _is_checkout(step):
    return isinstance(step.get("uses"), str) and step["uses"].startswith("actions/checkout@") \
        and step.get("with") == {"fetch-depth": 0}


# The explicit setup list (plan §5.2). Anything else is a test step.
SETUP_SPEC = {
    "linux": [
        ("checkout", _is_checkout),
        ("safe-directory", lambda s: s.get("name") == "Trust the exact checkout in the Swift container"),
        ("deps", lambda s: s.get("name") == "Install runtime dependencies"),
        ("node", lambda s: isinstance(s.get("name"), str) and s["name"].startswith("Install Node.js LTS")),
    ],
    "macos": [
        ("checkout", _is_checkout),
    ],
}


def derive_inventory(text):
    doc = parse_workflow(text)
    if set(doc) != {"name", "on", "jobs"}:
        raise ParseError(f"pre-split workflow keys {sorted(doc)}")
    jobs = doc["jobs"]
    if set(jobs) != {"linux", "macos"}:
        raise ParseError(f"pre-split job ids {sorted(jobs)}")
    platforms = {}
    for plat in ("linux", "macos"):
        job = jobs[plat]
        allowed = {"name", "runs-on", "container", "steps"} if plat == "linux" else {"name", "runs-on", "steps"}
        if set(job) != allowed:
            raise ParseError(f"pre-split job {plat} keys {sorted(job)}")
        steps = job["steps"]
        spec = SETUP_SPEC[plat]
        setup = []
        for (sid, pred), step in zip(spec, steps):
            if not pred(step):
                raise ParseError(f"{plat}: setup step {sid!r} not found at position {len(setup)}")
            setup.append({"id": sid, "step": step})
        tests = steps[len(spec):]
        for t in tests:
            for sid, pred in spec:
                if pred(t):
                    raise ParseError(f"{plat}: setup-like step {sid!r} among test steps")
        keys = [canon(t) for t in tests]
        if len(set(keys)) != len(keys):
            raise ParseError(f"{plat}: duplicate test step in the pre-split job")
        platforms[plat] = {
            "source_job": plat,
            "runs_on": job["runs-on"],
            "container": job.get("container"),
            "setup": setup,
            "tests": tests,
        }
    return {
        "workflow": {"name": doc["name"], "on_raw": doc["on"]},
        "platforms": platforms,
    }


def git(*args, binary=False):
    p = subprocess.run(["git", *args], cwd=ROOT, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {p.stderr.decode(errors='replace').strip()}")
    return p.stdout if binary else p.stdout.decode()


def record(commit):
    full = git("rev-parse", "--verify", f"{commit}^{{commit}}").strip()
    blob = git("show", f"{full}:{WORKFLOW_PATH}", binary=True)
    inv = derive_inventory(blob.decode("utf-8"))
    fixture = {
        "comment": "Frozen inventory of the pre-split CI workflow. Re-derived from source.commit by "
                   "scripts/ci_inventory_test.py on every run. Later CI changes go in `amendments` "
                   "({op: add|remove|replace|job-setup, platform, step, reason}).",
        "schema": 1,
        "source": {"commit": full, "path": WORKFLOW_PATH, "sha256": hashlib.sha256(blob).hexdigest()},
        **inv,
        "amendments": [],
    }
    with open(FIXTURE_PATH, "w", encoding="utf-8") as f:
        json.dump(fixture, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    print(f"recorded {FIXTURE_PATH} from {full} (sha256 {fixture['source']['sha256']})")


def load_fixture():
    with open(FIXTURE_PATH, encoding="utf-8") as f:
        return json.load(f)


def verify_provenance(fixture):
    errors = []
    src = fixture.get("source", {})
    commit = src.get("commit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit or ""):
        return [f"fixture source commit {commit!r} is not a full SHA"]
    try:
        git("cat-file", "-e", f"{commit}^{{commit}}")
        subprocess.run(["git", "merge-base", "--is-ancestor", commit, "HEAD"], cwd=ROOT, check=True,
                       capture_output=True)
    except (RuntimeError, subprocess.CalledProcessError):
        return [f"fixture source commit {commit} is not an ancestor of HEAD (full history checked out?)"]
    blob = git("show", f"{commit}:{src.get('path')}", binary=True)
    digest = hashlib.sha256(blob).hexdigest()
    if digest != src.get("sha256"):
        errors.append(f"source file sha256 {digest} != fixture {src.get('sha256')}")
    try:
        derived = derive_inventory(blob.decode("utf-8"))
    except ParseError as e:
        return errors + [f"cannot re-derive the fixture: {e}"]
    for key in ("workflow", "platforms"):
        if canon(derived[key]) != canon(fixture.get(key)):
            errors.append(f"fixture {key!r} differs from the inventory re-derived from {commit[:12]}")
    return errors


# ---------------------------------------------------------------------------
# Checks on the new workflow
# ---------------------------------------------------------------------------

LAYOUT = {
    "linux-core": ("linux", ["checkout", "safe-directory", "deps", "node"]),
    "linux-gates-a": ("linux", ["checkout", "safe-directory", "deps"]),
    "linux-gates-b": ("linux", ["checkout", "safe-directory", "deps"]),
    "macos-core": ("macos", ["checkout"]),
    "macos-gates": ("macos", ["checkout"]),
}
CORE_JOBS = ("linux-core", "macos-core")
AGG_ID = "ci-complete"
AGG_NAME = "CI complete"
INVENTORY_STEP = {
    "name": "CI inventory (every pre-split step still runs, unchanged)",
    "run": "python3 scripts/ci_inventory_test.py",
}
RESULTS = ("success", "failure", "cancelled", "skipped")
# Build commands the prerequisite check recognises; which one each platform must use is
# fixed by the frozen inventory plus its `replace` amendment (Linux: -j 2, macOS: plain).
BUILD_RUNS = ("swift build", "swift build -j 2")


def _strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _strings(v)


def _mentions(step, needle):
    return any(needle in s for s in _strings(step))


def expected_tests(fixture, plat):
    exp = [canon(t) for t in fixture["platforms"][plat]["tests"]]
    for a in fixture.get("amendments", []):
        if a.get("platform") != plat:
            continue
        if not a.get("reason"):
            raise ValueError("amendment without a reason")
        if a.get("op") == "job-setup":
            continue  # validated and placed by job_setup_steps(), not a test step
        if a.get("op") == "add":
            exp.append(canon(a["step"]))
        elif a.get("op") == "remove":
            exp.remove(canon(a["step"]))
        elif a.get("op") == "replace":
            # In-place edit of one frozen step (keeps its position for the order check).
            # Deliberately narrow: only the `run` value may change; every other key and
            # value (name, if, env, shell, continue-on-error, ...) must stay identical.
            old, new = a["step"], a["with"]
            if not isinstance(old, dict) or not isinstance(new, dict):
                raise ValueError("replace amendment needs mapping `step` and `with`")
            if {k: v for k, v in old.items() if k != "run"} != {k: v for k, v in new.items() if k != "run"} \
                    or set(old) != set(new) or "run" not in old:
                raise ValueError("replace amendment may change only the `run` value of a step")
            if not isinstance(new["run"], str) or not new["run"]:
                raise ValueError("replace amendment `run` must be a non-empty string")
            exp[exp.index(canon(old))] = canon(new)
        else:
            raise ValueError(f"unknown amendment op {a.get('op')!r}")
    return exp


JOB_SETUP_KEYS = {"name", "run"}
# Exact, reviewed job-setup commands. A literal "no swift build" test let
# `swift  build` or an indirectly building script through (Codex, swap review
# 2026-10-21 note 2); a new setup command now needs its own entry here.
APPROVED_JOB_SETUP_RUNS = frozenset({"python3 scripts/ci_host_swap.py"})


def job_setup_steps(fixture):
    """{platform: [canon(step), ...]} from the `job-setup` amendments, validated.

    Deliberately narrow: the step is exactly {name, run} (no if/env/shell/
    continue-on-error/...), its run is one of APPROVED_JOB_SETUP_RUNS (exact
    string), and it is not a frozen setup, test or inventory step.
    """
    frozen = {canon(s["step"]) for p in ("linux", "macos") for s in fixture["platforms"][p]["setup"]}
    frozen |= {canon(t) for p in ("linux", "macos") for t in fixture["platforms"][p]["tests"]}
    frozen.add(canon(INVENTORY_STEP))
    out = {"linux": [], "macos": []}
    for a in fixture.get("amendments", []):
        if a.get("op") != "job-setup":
            continue
        step = a.get("step")
        if set(a) != {"op", "platform", "step", "reason"} or a.get("platform") not in out \
                or not isinstance(a.get("reason"), str) or not a["reason"]:
            raise ValueError("job-setup amendment must be exactly {op, platform, step, reason} with a known platform")
        if not isinstance(step, dict) or set(step) != JOB_SETUP_KEYS \
                or not all(isinstance(step[k], str) and step[k] for k in JOB_SETUP_KEYS):
            raise ValueError("job-setup amendment step must be exactly {name, run} with non-empty strings")
        if step["run"] not in APPROVED_JOB_SETUP_RUNS:
            raise ValueError("job-setup amendment step run is not an approved setup command")
        c = canon(step)
        if c in frozen or any(c in v for v in out.values()):
            raise ValueError("job-setup amendment step duplicates a frozen or another job-setup step")
        out[a["platform"]].append(c)
    return out


def check_workflow(text, fixture, truth_cache=None):
    """Return a list of human-readable errors (empty = pass)."""
    try:
        doc = parse_workflow(text)
    except ParseError as e:
        return [f"parse error: {e}"]
    errors = []
    if set(doc) != {"name", "on", "jobs"}:
        errors.append(f"workflow keys must be exactly name/on/jobs, got {sorted(doc)}")
    if doc.get("name") != fixture["workflow"]["name"]:
        errors.append(f"workflow name {doc.get('name')!r} != frozen {fixture['workflow']['name']!r}")
    if doc.get("on") != fixture["workflow"]["on_raw"]:
        errors.append("raw `on:` text differs from the frozen text")
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        return errors + ["jobs is not a mapping"]
    want_ids = set(LAYOUT) | {AGG_ID}
    if set(jobs) != want_ids:
        errors.append(f"job ids {sorted(jobs)} != {sorted(want_ids)}")

    setup_records = {plat: {s["id"]: s["step"] for s in fixture["platforms"][plat]["setup"]}
                     for plat in ("linux", "macos")}
    all_setup_canon = {canon(s) for recs in setup_records.values() for s in recs.values()}
    placed = {"linux": [], "macos": []}  # (job, position-in-job, step)
    node_jobs = []
    try:
        job_setup = job_setup_steps(fixture)
    except (ValueError, KeyError) as e:
        errors.append(f"fixture amendments invalid: {e}")
        job_setup = {"linux": [], "macos": []}
    job_setup_plat = {c: p for p, cs in job_setup.items() for c in cs}

    for jid, (plat, prefix) in LAYOUT.items():
        job = jobs.get(jid)
        if not isinstance(job, dict):
            errors.append(f"{jid}: missing or not a mapping")
            continue
        pf = fixture["platforms"][plat]
        allowed = {"name", "runs-on", "container", "steps"} if plat == "linux" else {"name", "runs-on", "steps"}
        if set(job) != allowed:
            errors.append(f"{jid}: job keys {sorted(job)} != {sorted(allowed)}")
        name = job.get("name")
        if not isinstance(name, str) or not name or name == AGG_NAME:
            errors.append(f"{jid}: job name {name!r} invalid (must be a non-empty string, not {AGG_NAME!r})")
        if job.get("runs-on") != pf["runs_on"] or not isinstance(job.get("runs-on"), str):
            errors.append(f"{jid}: runs-on {job.get('runs-on')!r} != frozen {pf['runs_on']!r}")
        if plat == "linux" and (not isinstance(job.get("container"), str) or job.get("container") != pf["container"]):
            errors.append(f"{jid}: container {job.get('container')!r} != frozen {pf['container']!r}")
        steps = job.get("steps")
        if not isinstance(steps, list) or not all(isinstance(s, dict) for s in steps):
            errors.append(f"{jid}: steps must be a list of mappings")
            continue
        for k, sid in enumerate(prefix):
            want = setup_records[plat][sid]
            if k >= len(steps) or canon(steps[k]) != canon(want):
                errors.append(f"{jid}: setup position {k} must be exactly the frozen {sid!r} step")
        if "node" in prefix:
            node_jobs.append(jid)
        rest = list(enumerate(steps))[len(prefix):]
        inv_count = 0
        js_count = collections.Counter()
        for pos, step in rest:
            c = canon(step)
            if c in all_setup_canon:
                errors.append(f"{jid}: setup step outside the setup prefix at position {pos}: {step.get('name') or step.get('uses')}")
                continue
            if c == canon(INVENTORY_STEP):
                inv_count += 1
                continue
            if c in job_setup_plat:
                js_count[c] += 1
                continue
            placed[plat].append((jid, pos, step))
        if jid in CORE_JOBS:
            if inv_count != 1:
                errors.append(f"{jid}: the inventory step must appear exactly once (found {inv_count})")
            elif canon(steps[len(prefix)]) != canon(INVENTORY_STEP):
                errors.append(f"{jid}: the inventory step must come right after the setup prefix")
        elif inv_count:
            errors.append(f"{jid}: inventory step only belongs in the core jobs")
        for c, p2 in job_setup_plat.items():
            nm = json.loads(c).get("name")
            if p2 != plat and js_count[c]:
                errors.append(f"{jid}: per-job setup step {nm!r} belongs only on {p2} jobs")
            elif p2 == plat and js_count[c] != 1:
                errors.append(f"{jid}: per-job setup step {nm!r} must appear exactly once (found {js_count[c]})")
        start = len(prefix) + (1 if jid in CORE_JOBS else 0)
        want = job_setup[plat]
        if want and [canon(s) for s in steps[start:start + len(want)]] != want:
            errors.append(f"{jid}: per-job setup steps must come right after the setup prefix"
                          f"{' and the inventory step' if jid in CORE_JOBS else ''}, in amendment order")

    for plat in ("linux", "macos"):
        try:
            # frozen order = the recorded tests with in-place `replace` amendments applied
            frozen = expected_tests(fixture, plat)
            exp = collections.Counter(frozen)
        except (ValueError, KeyError) as e:
            errors.append(f"fixture amendments invalid: {e}")
            continue
        got = collections.Counter(canon(s) for _, _, s in placed[plat])
        for c, n in (exp - got).items():
            errors.append(f"{plat}: frozen step missing or altered ({n}x): {json.loads(c).get('name') or c}")
        for c, n in (got - exp).items():
            errors.append(f"{plat}: step not in the frozen inventory ({n}x): {json.loads(c).get('name') or c}")
        # frozen relative order within each job
        by_job = collections.defaultdict(list)
        for jid, pos, step in placed[plat]:
            by_job[jid].append((pos, step))
        for jid, items in by_job.items():
            idx = [frozen.index(canon(s)) for _, s in sorted(items, key=lambda t: t[0]) if canon(s) in frozen]
            if idx != sorted(idx) or len(set(idx)) != len(idx):
                errors.append(f"{jid}: test steps are not in their frozen relative order")
        # prerequisites
        builds = [(j, p) for j, p, s in placed[plat] if s.get("name") == "Build" and s.get("run") in BUILD_RUNS]
        if len(builds) != 1:
            errors.append(f"{plat}: expected exactly one Build step, found {len(builds)}")
        else:
            bj, bp = builds[0]
            for j, p, s in placed[plat]:
                if _mentions(s, ".build/debug/briglia") and not (j == bj and p > bp):
                    errors.append(f"{plat}: {s.get('name')!r} uses .build/debug/briglia but is not after Build in {bj}")
        providers = [(j, p) for j, p, s in placed[plat] if "playwright install" in (s.get("run") or "")]
        for j, p, s in placed[plat]:
            run = s.get("run") or ""
            if re.search(r"_browser_test\.py|browser_settings_test\.py", run):
                if not any(pj == j and pp <= p for pj, pp in providers):
                    errors.append(f"{plat}: browser step {s.get('name')!r} is not with/after a Playwright install step")
        for j, p, s in placed[plat]:
            uses = s.get("uses")
            if isinstance(uses, str) and uses.startswith("actions/upload-artifact@"):
                path = (s.get("with") or {}).get("path")
                if not any(pj == j and pp < p and f"--save-reference {path}" in (ps.get("run") or "")
                           for pj, pp, ps in placed[plat]):
                    errors.append(f"{plat}: upload {s.get('name')!r} is not in the same job after the step producing {path!r}")
            m = re.search(r"--save-reference (\S+)", s.get("run") or "")
            if m:
                if not any(pj == j and pp > p and isinstance(ps.get("uses"), str)
                           and ps["uses"].startswith("actions/upload-artifact@")
                           and (ps.get("with") or {}).get("path") == m.group(1)
                           for pj, pp, ps in placed[plat]):
                    errors.append(f"{plat}: {s.get('name')!r} produces {m.group(1)!r} but its upload is not later in the same job")
        if plat == "linux":
            smoke = [j for j, p, s in placed[plat] if s.get("name") == "Smoke test"]
            if len(node_jobs) != 1 or smoke != node_jobs:
                errors.append(f"linux: smoke {smoke} must be in the one job holding the Node setup {node_jobs}")

    errors.extend(check_aggregator(jobs.get(AGG_ID), truth_cache))
    return errors


def check_aggregator(agg, truth_cache=None):
    errors = []
    if not isinstance(agg, dict):
        return [f"{AGG_ID}: missing or not a mapping"]
    if set(agg) != {"name", "runs-on", "if", "needs", "steps"}:
        errors.append(f"{AGG_ID}: job keys {sorted(agg)} != [if, name, needs, runs-on, steps]")
    if agg.get("name") != AGG_NAME:
        errors.append(f"{AGG_ID}: name must be {AGG_NAME!r}")
    if agg.get("runs-on") != "ubuntu-latest":
        errors.append(f"{AGG_ID}: runs-on must be ubuntu-latest")
    if agg.get("if") != "${{ always() }}":
        errors.append(f"{AGG_ID}: job if must be exactly '${{{{ always() }}}}'")
    needs = agg.get("needs")
    if not isinstance(needs, list) or len(needs) != len(LAYOUT) or set(needs) != set(LAYOUT):
        errors.append(f"{AGG_ID}: needs must be exactly the five test jobs, got {needs!r}")
    steps = agg.get("steps")
    if not isinstance(steps, list) or len(steps) != 1 or not isinstance(steps[0], dict):
        return errors + [f"{AGG_ID}: must have exactly one step"]
    step = steps[0]
    if set(step) != {"name", "env", "run"}:
        errors.append(f"{AGG_ID}: step keys {sorted(step)} != [env, name, run] (no if/shell/continue-on-error/...)")
    if step.get("env") != {"NEEDS_JSON": "${{ toJSON(needs) }}"}:
        errors.append(f"{AGG_ID}: step env must be exactly NEEDS_JSON: ${{{{ toJSON(needs) }}}}")
    if not isinstance(step.get("run"), str):
        return errors + [f"{AGG_ID}: step run must be a script"]
    if errors:
        return errors
    return truth_table(step["run"], truth_cache)


def _needs_cases():
    jobs = list(LAYOUT)
    for combo in itertools.product(RESULTS, repeat=len(jobs)):
        yield "/".join(combo), {j: {"result": r, "outputs": {}} for j, r in zip(jobs, combo)}, all(r == "success" for r in combo)
    missing = {j: {"result": "success", "outputs": {}} for j in jobs[:-1]}
    yield "missing-key", missing, False
    extra = {j: {"result": "success", "outputs": {}} for j in jobs}
    extra["extra-job"] = {"result": "success", "outputs": {}}
    yield "extra-key", extra, False


def truth_table(script, cache=None):
    """Run the aggregator script exactly as GitHub runs a step with no `shell:`.

    The aggregator sets no shell, so GitHub uses its default `bash -e {0}`
    (no pipefail). Running it here with pipefail would let an edit such as
    piping the script through `cat` pass this test yet go green in CI.
    """
    if cache is not None and script in cache:
        return cache[script]
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "agg.sh")
        with open(path, "w", encoding="utf-8") as f:
            f.write(script)

        def run(case):
            label, needs, expect = case
            env = dict(os.environ, NEEDS_JSON=json.dumps(needs))
            p = subprocess.run(["bash", "-e", path], env=env,
                               capture_output=True, timeout=60)
            return label, expect, p.returncode == 0

        cases = list(_needs_cases())
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
            results = list(ex.map(run, cases))
    wrong = [(label, expect) for label, expect, ok in results if ok != expect]
    accepted = sum(1 for _, _, ok in results if ok)
    out = []
    if len(results) != 1026:
        out.append(f"{AGG_ID}: truth table ran {len(results)} cases, expected 1026")
    if wrong:
        out.append(f"{AGG_ID}: truth table: {len(wrong)} wrong verdicts of {len(results)} "
                   f"(accepted {accepted}); first: {wrong[0][0]} expected {'accept' if wrong[0][1] else 'refuse'}")
    if cache is not None:
        cache[script] = out
    return out


# ---------------------------------------------------------------------------
# Deliberate breaks
# ---------------------------------------------------------------------------

class BreakSetupError(Exception):
    pass


def _job_span(text, jid):
    m = re.search(rf"^  {re.escape(jid)}:\n", text, re.M)
    if not m:
        raise BreakSetupError(f"job {jid} not found")
    nxt = re.search(r"^  [A-Za-z0-9_-]+:\n", text[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(text)
    return m.start(), end


def sub_once(text, old, new, job=None):
    lo, hi = _job_span(text, job) if job else (0, len(text))
    seg = text[lo:hi]
    if seg.count(old) != 1:
        raise BreakSetupError(f"anchor found {seg.count(old)}x (want 1) in {job or 'file'}: {old[:60]!r}")
    return text[:lo] + seg.replace(old, new) + text[hi:]


def step_text(text, job, name_line):
    """Return the exact text of the step starting with `      - name: <...>` in job."""
    lo, hi = _job_span(text, job)
    seg = text[lo:hi]
    start = seg.find(name_line)
    if start < 0 or seg.count(name_line) != 1:
        raise BreakSetupError(f"step {name_line!r} not unique in {job}")
    nxt = re.search(r"^      - ", seg[start + 1:], re.M)
    end = start + 1 + nxt.start() if nxt else len(seg)
    return seg[start:end]


def remove_step(text, job, name_line):
    st = step_text(text, job, name_line)
    return sub_once(text, st, "", job=job), st


def append_to_job(text, job, block):
    lo, hi = _job_span(text, job)
    seg = text[lo:hi].rstrip("\n") + "\n" + block.rstrip("\n") + "\n"
    tail = text[hi:]
    return text[:lo] + seg + ("\n" if tail else "") + tail


def _move(text, src, dst, name_line):
    text, st = remove_step(text, src, name_line)
    return append_to_job(text, dst, st)


def _insert_after(text, job, anchor, insertion):
    return sub_once(text, anchor, anchor + insertion, job=job)


ACTIVE = "      - name: Active-turn compaction owners and negative controls\n"
SNAPSHOT = "      - name: Snapshot owner transactions and Mind transfer\n"
RESPONSES = "      - name: Responses real-owner lifecycle\n"
WIRE_NEG = "      - name: Wire comparator negative tests\n"
BROWSER_LINUX = "      - name: Quick-setup browser test\n"
PLAYWRIGHT_LINUX = "      - name: Install Playwright (browser test of the quick-setup page)\n"
SMOKE = "      - name: Smoke test\n"
BROWSER_SETTINGS_MAC = "      - name: Browser settings browser test\n"
WIRE_UPLOAD = "      - name: Preserve pinned-release reference\n"
INV_LINE = "      - name: CI inventory (every pre-split step still runs, unchanged)\n        run: python3 scripts/ci_inventory_test.py\n"
CHECKOUT = "      - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0\n        with:\n          fetch-depth: 0\n"
NODE_STEP_START = "      - name: Install Node.js LTS"


def _swap_browser(t):
    t, pw = remove_step(t, "linux-core", PLAYWRIGHT_LINUX)
    return append_to_job(t, "linux-core", pw)


def _node_into_gate(t):
    node = step_text(t, "linux-core", NODE_STEP_START)
    return _insert_after(t, "linux-gates-a", "        run: git config --global --add safe.directory \"$GITHUB_WORKSPACE\"\n", node)


def _reorder_gates_b(t):
    t, snap = remove_step(t, "linux-gates-b", SNAPSHOT)
    return sub_once(t, ACTIVE, snap + ACTIVE, job="linux-gates-b")


# The reason each break must be caught for (a substring of one reported error),
# so a break caught only incidentally by another rule does not count.
# 0.2.59: the add amendment verifying the immutable ConversationManager split (C1 -> C2).
SPLIT_STEP = ("      - name: ConversationManager split moved-lines check (C1 to C2, through 0.2.60)\n"
              "        run: python3 scripts/cm_split_check.py --verify-commit 8bd2718465e1b2150cfcaac03d8274a59e56039e"
              " --c1 47865661a67cbaefe969cf60e7652e3f310bbcdd\n")

EXPECT = {
    "01": "missing or altered", "02": "not in the frozen inventory", "03": "missing or altered",
    "04": "macos: step not in the frozen inventory", "05": "missing or altered", "06": "missing or altered",
    "07": "missing or altered", "08": "missing or altered", "09": "missing or altered",
    "10": "missing or altered", "11": "missing or altered", "12": "missing or altered",
    "13": "job keys", "14": "workflow keys", "15": "workflow keys", "16": "job keys", "17": "job keys",
    "18": "job keys", "19": "job keys", "20a": "container", "20b": "job keys", "20c": "container",
    "21": "runs-on", "22": "setup position", "23": "uses .build/debug/briglia but is not after Build",
    "24": "not with/after a Playwright install", "25": "uses .build/debug/briglia but is not after Build",
    "26": "holding the Node setup", "27": "inventory step must appear exactly once",
    "28": "needs must be exactly", "29": "job keys", "30": "step keys", "31": "truth table",
    "32": "truth table", "33": "raw `on:`", "34": "re-derived", "35": "upload",
    "36": "inventory step must appear exactly once", "37": "setup", "38": "job name",
    "39": "frozen relative order", "40": "truth table",
    "41": "linux: frozen step missing or altered", "42": "macos: step not in the frozen inventory",
    "43": "replace amendment may change only", "44": "frozen relative order",
    "45": "per-job setup step 'Add host swap (Linux compiler memory headroom)' must appear exactly once",
    "46": "belongs only on linux jobs", "47": "must come right after the setup prefix and the inventory step",
    "48": "linux: step not in the frozen inventory", "49": "job-setup amendment step must be exactly {name, run}",
    "50": "must come right after the setup prefix, in amendment order",
    "51": "linux: frozen step missing or altered (1x): ConversationManager split moved-lines check",
    "52": "linux: frozen step missing or altered (1x): ConversationManager split moved-lines check",
    "53": "macos: step not in the frozen inventory (1x): ConversationManager split moved-lines check",
    "54": "job-setup amendment step run is not an approved setup command",
    "55": "job-setup amendment step run is not an approved setup command",
    "P1": "duplicate key", "P2": "indicator '&'", "P3": "unrecognised line", "P4": "indicator '{'",
    "P5": "tab character", "P6": "unsupported block scalar", "P7": "document marker",
}


def _tamper_fixture(fx):
    fx = copy.deepcopy(fx)
    fx["platforms"]["linux"]["tests"][-1]["run"] = fx["platforms"]["linux"]["tests"][-1]["run"].replace("menu_browser_test.py", "menu_browser_tests.py")
    return fx


def _amend_more_than_run(fx):
    fx = copy.deepcopy(fx)
    for a in fx.get("amendments", []):
        if a.get("op") == "replace":
            a["with"] = dict(a["with"], **{"continue-on-error": True})
            return fx
    raise BreakSetupError("no replace amendment in the fixture")


SWAP_STEP = "      - name: Add host swap (Linux compiler memory headroom)\n        run: python3 scripts/ci_host_swap.py\n"
SWAP_NAME = "      - name: Add host swap (Linux compiler memory headroom)\n"


def _swap_after_build(t):
    t = sub_once(t, SWAP_STEP, "", job="linux-core")
    b = "      - name: Build\n        run: swift build -j 2\n"
    return sub_once(t, b, b + SWAP_STEP, job="linux-core")


def _swap_to_macos(t):
    return _insert_after(t, "macos-core", INV_LINE, SWAP_STEP)


def _job_setup_widened(fx):
    fx = copy.deepcopy(fx)
    for a in fx.get("amendments", []):
        if a.get("op") == "job-setup":
            a["step"] = dict(a["step"], **{"continue-on-error": True})
            return fx
    raise BreakSetupError("no job-setup amendment in the fixture")


def _job_setup_run(run):
    def mutate(fx):
        fx = copy.deepcopy(fx)
        for a in fx.get("amendments", []):
            if a.get("op") == "job-setup":
                a["step"] = dict(a["step"], run=run)
                return fx
        raise BreakSetupError("no job-setup amendment in the fixture")
    return mutate


def _swap_after_first_gate_test(t):
    t = sub_once(t, SWAP_STEP, "", job="linux-gates-b")
    st = step_text(t, "linux-gates-b", ACTIVE)
    return sub_once(t, st, st + SWAP_STEP, job="linux-gates-b")


def _build_after_smoke(t):
    lo, hi = _job_span(t, "linux-core")
    seg = t[lo:hi]
    b = "      - name: Build\n        run: swift build -j 2\n"
    if b not in seg:
        raise BreakSetupError("linux-core Build step not found")
    seg = seg.replace(b, "", 1)
    k = seg.index("      - name: Smoke test\n")
    k2 = seg.index("      - name:", k + 1)
    return t[:lo] + seg[:k2] + b + seg[k2:] + t[hi:]


def breaks():
    """(name, text_mutation, fixture_mutation_or_None)."""
    agg = "ci-complete"
    B = [
        ("01 remove a test step", lambda t: remove_step(t, "linux-gates-b", SNAPSHOT)[0]),
        ("02 duplicate a test step into another job",
         lambda t: append_to_job(t, "linux-gates-b", step_text(t, "linux-gates-a", RESPONSES))),
        ("03 change one character of a command",
         lambda t: sub_once(t, "run: python3 scripts/user_context_wire_test.py\n", "run: python3 scripts/user_context_wire_test.pz\n", job="linux-gates-b")),
        ("04 move a Linux test step to a macOS job", lambda t: _move(t, "linux-gates-a", "macos-gates", RESPONSES)),
        ("05 add step if: false", lambda t: _insert_after(t, "linux-gates-b", ACTIVE, "        if: ${{ false }}\n")),
        ("06 change the lifecycle upload if", lambda t: sub_once(t, "if: ${{ !cancelled() }}", "if: ${{ always() }}", job="linux-gates-a")),
        ("07 add step continue-on-error", lambda t: _insert_after(t, "linux-gates-b", SNAPSHOT, "        continue-on-error: true\n")),
        ("08 remove the macOS best-effort continue-on-error", lambda t: sub_once(t, "        continue-on-error: true\n", "", job="macos-core")),
        ("09 add step shell: bash {0}", lambda t: _insert_after(t, "linux-gates-b", ACTIVE, "        shell: bash {0}\n")),
        ("10 add step working-directory", lambda t: _insert_after(t, "linux-gates-b", SNAPSHOT, "        working-directory: scripts\n")),
        ("11 add step timeout-minutes", lambda t: _insert_after(t, "linux-gates-a", RESPONSES, "        timeout-minutes: 5\n")),
        ("12 add step env PYTHONOPTIMIZE", lambda t: _insert_after(t, "linux-gates-b", ACTIVE, "        env:\n          PYTHONOPTIMIZE: \"1\"\n")),
        ("13 job-level env PYTHONOPTIMIZE", lambda t: _insert_after(t, "linux-gates-b", "    container: swift:6.1-jammy\n", "    env:\n      PYTHONOPTIMIZE: \"1\"\n")),
        ("14 workflow-level env", lambda t: sub_once(t, "\njobs:\n", "\nenv:\n  PYTHONOPTIMIZE: \"1\"\n\njobs:\n")),
        ("15 workflow defaults run shell", lambda t: sub_once(t, "\njobs:\n", "\ndefaults:\n  run:\n    shell: bash {0}\n\njobs:\n")),
        ("16 job defaults", lambda t: _insert_after(t, "macos-gates", "    runs-on: macos-15\n", "    defaults:\n      run:\n        shell: bash {0}\n")),
        ("17 job-level continue-on-error", lambda t: _insert_after(t, "linux-gates-a", "    container: swift:6.1-jammy\n", "    continue-on-error: true\n")),
        ("18 job-level if", lambda t: _insert_after(t, "macos-gates", "    runs-on: macos-15\n", "    if: ${{ github.event_name != 'pull_request' }}\n")),
        ("19 job strategy matrix", lambda t: _insert_after(t, "linux-gates-b", "    container: swift:6.1-jammy\n", "    strategy:\n      matrix:\n        shard:\n          - one\n")),
        ("20a container changed", lambda t: sub_once(t, "    container: swift:6.1-jammy\n", "    container: swift:6.2-jammy\n", job="linux-gates-b")),
        ("20b container removed", lambda t: sub_once(t, "    container: swift:6.1-jammy\n", "", job="linux-gates-a")),
        ("20c container in mapping form", lambda t: sub_once(t, "    container: swift:6.1-jammy\n", "    container:\n      image: swift:6.1-jammy\n", job="linux-core")),
        ("21 runs-on changed", lambda t: sub_once(t, "    runs-on: macos-15\n", "    runs-on: macos-14\n", job="macos-gates")),
        ("22 unknown step in the setup position", lambda t: _insert_after(t, "linux-gates-a", CHECKOUT, "      - run: pip install x\n")),
        ("23 binary consumer moved to a gate job", lambda t: _move(t, "linux-core", "linux-gates-a", WIRE_NEG)),
        ("24 browser block before the Playwright install", _swap_browser),
        ("25 macOS browser-settings step moved to macos-gates", lambda t: _move(t, "macos-core", "macos-gates", BROWSER_SETTINGS_MAC)),
        ("26 smoke moved away from the Node job", lambda t: _move(t, "linux-core", "linux-gates-b", SMOKE)),
        ("27 inventory step removed from one core job", lambda t: sub_once(t, INV_LINE, "", job="macos-core")),
        ("28 aggregator: job dropped from needs", lambda t: sub_once(t, "      - macos-gates\n", "", job=agg)),
        ("29 aggregator: if always() removed", lambda t: sub_once(t, "    if: ${{ always() }}\n", "", job=agg)),
        ("30 aggregator step gated on success()", lambda t: _insert_after(t, agg, "      - name: Require every job to have succeeded\n", "        if: ${{ success() }}\n")),
        ("31 aggregator script replaced by true", lambda t: _replace_agg_script(t, "true\n")),
        ("32 aggregator script ignores one job", lambda t: sub_once(sub_once(t, ', "macos-gates"}', "}", job=agg), "if set(needs) != expected or bad:", "if bad:", job=agg)),
        ("33 on: changed", lambda t: sub_once(t, "'wip/release-*']", "'wip/release-*', 'wip/other-*']")),
        ("34 fixture tampered (one recorded step edited)", lambda t: t, _tamper_fixture),
        ("35 artifact upload moved away from its producer", lambda t: _move(t, "linux-gates-a", "linux-gates-b", WIRE_UPLOAD)),
        ("36 inventory step altered (extra env)", lambda t: sub_once(t, INV_LINE, INV_LINE + "        env:\n          CI_INVENTORY_SKIP: \"1\"\n", job="linux-core")),
        ("37 Node setup copied into a gate job", _node_into_gate),
        ("38 a test job named CI complete", lambda t: sub_once(t, "    name: macOS gates", "    name: CI complete", job="macos-gates")),
        ("39 two steps reordered inside a job", _reorder_gates_b),
        ("40 aggregator output piped through cat", lambda t: sub_once(t, "python3 - <<'PY'\n", "python3 - <<'PY' | cat\n", job=agg)),
        ("41 Linux Build back to unbounded swift build", lambda t: sub_once(t, "        run: swift build -j 2\n", "        run: swift build\n", job="linux-core")),
        ("42 macOS Build silently given -j 2", lambda t: sub_once(t, "        run: swift build\n", "        run: swift build -j 2\n", job="macos-core")),
        ("43 Build amendment widened beyond `run`", lambda t: t, _amend_more_than_run),
        ("44 Linux Build moved after smoke", _build_after_smoke),
        ("45 host swap step missing from a Linux gate job", lambda t: sub_once(t, SWAP_STEP, "", job="linux-gates-b")),
        ("46 host swap step added to a macOS job", _swap_to_macos),
        ("47 host swap step moved after the Linux Build", _swap_after_build),
        ("48 host swap step given continue-on-error", lambda t: _insert_after(t, "linux-gates-a", SWAP_STEP, "        continue-on-error: true\n")),
        ("49 job-setup amendment widened beyond {name, run}", lambda t: t, _job_setup_widened),
        ("50 host swap step moved after a gate test", _swap_after_first_gate_test),
        ("51 split moved-lines check removed", lambda t: sub_once(t, SPLIT_STEP, "", job="linux-core")),
        ("52 split moved-lines check pointed at another commit", lambda t: sub_once(t, "--verify-commit 8bd2718", "--verify-commit 0000000", job="linux-core")),
        ("53 split moved-lines check moved to macOS", lambda t: sub_once(sub_once(t, SPLIT_STEP, "", job="linux-core"), "        run: python3 scripts/browser_settings_test.py .build/debug/briglia\n", "        run: python3 scripts/browser_settings_test.py .build/debug/briglia\n" + SPLIT_STEP, job="macos-core")),
        ("54 job-setup amendment builds with two spaces (swift  build)", lambda t: t, _job_setup_run("swift  build -j 2")),
        ("55 job-setup amendment runs a script that builds indirectly", lambda t: t, _job_setup_run("python3 scripts/responses_lifecycle_test.py")),
        ("P1 parser: duplicate key", lambda t: _insert_after(t, "macos-gates", "    runs-on: macos-15\n", "    runs-on: macos-15\n")),
        ("P2 parser: anchor and alias", lambda t: sub_once(sub_once(t, "    runs-on: macos-15\n", "    runs-on: &rn macos-15\n", job="macos-core"), "    runs-on: macos-15\n", "    runs-on: *rn\n", job="macos-gates")),
        ("P3 parser: merge key", lambda t: _insert_after(t, "macos-gates", "    runs-on: macos-15\n", "    <<: *base\n")),
        ("P4 parser: flow mapping", lambda t: sub_once(t, "        with:\n          fetch-depth: 0\n", "        with: {fetch-depth: 0}\n", job="macos-gates")),
        ("P5 parser: tab indentation", lambda t: sub_once(t, "    runs-on: macos-15\n", "\truns-on: macos-15\n", job="macos-gates")),
        ("P6 parser: |- block scalar", lambda t: sub_once(t, "        run: |\n", "        run: |-\n", job=agg)),
        ("P7 parser: second document", lambda t: t + "---\nname: other\n"),
    ]
    return [(b[0], b[1], b[2] if len(b) > 2 else None) for b in B]


def _replace_agg_script(t, script):
    lo, hi = _job_span(t, "ci-complete")
    seg = t[lo:hi]
    k = seg.index("        run: |\n")
    return t[:lo] + seg[:k] + "        run: |\n" + "".join("          " + ln + "\n" for ln in script.splitlines()) + t[hi:]


def run_breaks(text, fixture, cache):
    passed_breaks = []
    count = 0
    for name, mut_text, mut_fx in breaks():
        count += 1
        try:
            t = mut_text(text)
        except BreakSetupError as e:
            passed_breaks.append(f"{name}: could not be applied ({e})")
            print(f"  BREAK {name}: NOT APPLIED ({e})")
            continue
        fx = mut_fx(fixture) if mut_fx else fixture
        if t == text and fx is fixture:
            passed_breaks.append(f"{name}: mutation changed nothing")
            continue
        errs = []
        if mut_fx:
            # The fixture is checked against its source commit on every run.
            errs += provenance_against(fx, fixture)
        errs += check_workflow(t, fx, cache)
        want = EXPECT.get(name.split(" ", 1)[0])
        hit = [e for e in errs if want and want in e]
        if errs and want is None:
            passed_breaks.append(f"{name}: no expected reason defined")
            print(f"  BREAK {name}: NO EXPECTED REASON")
        elif hit:
            print(f"  BREAK {name}: caught — {hit[0]}")
        elif errs:
            passed_breaks.append(f"{name}: caught only for another reason ({errs[0]})")
            print(f"  BREAK {name}: WRONG REASON — {errs[0]}")
        else:
            passed_breaks.append(name)
            print(f"  BREAK {name}: NOT CAUGHT")
    return count, passed_breaks


def provenance_against(fx, real):
    """verify_provenance for a mutated in-memory fixture (no file write)."""
    errs = []
    if fx.get("source") != real.get("source"):
        errs.append("fixture source changed")
    blob = git("show", f"{real['source']['commit']}:{real['source']['path']}", binary=True)
    derived = derive_inventory(blob.decode("utf-8"))
    for key in ("workflow", "platforms"):
        if canon(derived[key]) != canon(fx.get(key)):
            errs.append(f"fixture {key!r} differs from the inventory re-derived from the source commit")
    return errs


# ---------------------------------------------------------------------------
# Parser fidelity tests
# ---------------------------------------------------------------------------

PARSER_POSITIVE = [
    ("block scalar: deeper lines, inner blank line, trailing blanks clipped, literal # { : ${{ }}",
     "a:\n  run: |\n    line one\n      deeper: x # not a comment\n\n    {\"k\": 1} ${{ e }}\n\n\n  b: c\n",
     {"a": {"run": "line one\n  deeper: x # not a comment\n\n{\"k\": 1} ${{ e }}\n", "b": "c"}}),
    ("quoted and plain expressions",
     "a: \"${{ toJSON(needs) }}\"\nb: ${{ always() }}\nc: '${{ x }}'\n",
     {"a": "${{ toJSON(needs) }}", "b": "${{ always() }}", "c": "${{ x }}"}),
    ("trailing comment after uses",
     "s:\n  - uses: a/b@0123abc # v1.2.3\n    with:\n      fetch-depth: 0\n",
     {"s": [{"uses": "a/b@0123abc", "with": {"fetch-depth": 0}}]}),
    ("scalar typing: int, bool, quoted string",
     "a: 0\nb: \"0\"\nc: true\nd: '1'\ne: swift:6.1-jammy\nf: .build/debug/x y\n",
     {"a": 0, "b": "0", "c": True, "d": "1", "e": "swift:6.1-jammy", "f": ".build/debug/x y"}),
    ("comments between keys and sequence entries",
     "a:\n  # c1\n  - p: 1\n    # c2\n    q: 2\n# c3\n  - z\n",
     {"a": [{"p": 1, "q": 2}, "z"]}),
    ("block sequence of scalars",
     "needs:\n  - one\n  - two-b\n",
     {"needs": ["one", "two-b"]}),
]

PARSER_NEGATIVE = [
    ("duplicate key", "a: 1\na: 2\n"),
    ("duplicate nested key", "a:\n  b: 1\n  b: 1\n"),
    ("anchor", "a: &x 1\n"),
    ("alias", "a: *x\n"),
    ("merge key", "a:\n  <<: *x\n"),
    ("flow sequence", "a: [1, 2]\n"),
    ("flow mapping", "a: {b: 1}\n"),
    ("tag", "a: !!str x\n"),
    ("folded scalar", "a: >\n  x\n"),
    ("strip chomping", "a: |-\n  x\n"),
    ("keep chomping", "a: |+\n  x\n"),
    ("explicit indentation", "a: |2\n  x\n"),
    ("tab indentation", "a:\n\tb: 1\n"),
    ("tab after colon", "a:\t1\n"),
    ("inconsistent indentation", "a:\n  b: 1\n   c: 2\n"),
    ("document start", "a: 1\n---\nb: 2\n"),
    ("document end", "a: 1\n...\n"),
    ("directive", "%YAML 1.2\na: 1\n"),
    ("backslash escape", "a: \"x\\ny\"\n"),
    ("single-quote escape", "a: 'it''s'\n"),
    ("plain scalar with colon-space", "a: b: c\n"),
    ("ambiguous boolean", "a: yes\n"),
    ("null", "a: ~\n"),
    ("float", "a: 6.1\n"),
    ("date", "a: 2026-10-21\n"),
    ("quoted key", "'a': 1\n"),
    ("ambiguous key", "a:\n  on: 1\n"),
    ("empty value", "a:\nb: 1\n"),
    ("multi-line plain scalar", "a: one\n  two\n"),
    ("carriage return", "a: 1\r\n"),
    ("sequence item with two spaces", "a:\n  -  x\n"),
    ("whitespace-only deep line in block", "a: |\n  x\n      \n  y\n"),
]


def parser_tests():
    failures = []
    for name, text, want in PARSER_POSITIVE:
        try:
            got = parse_document(text)
        except ParseError as e:
            failures.append(f"positive {name!r}: rejected ({e})")
            continue
        if canon(got) != canon(want) or type(got) is not type(want):
            failures.append(f"positive {name!r}: got {got!r}")
    for name, text in PARSER_NEGATIVE:
        try:
            parse_document(text)
            failures.append(f"negative {name!r}: accepted")
        except ParseError:
            pass
    # workflow-level: the raw `on:` block is kept verbatim and not interpreted.
    wf = "name: X\n\non:\n  push:\n    branches: [main, 'a-*']\n  workflow_dispatch:\n\njobs:\n  j:\n    steps:\n      - run: x\n"
    try:
        d = parse_workflow(wf)
        if d["on"] != "on:\n  push:\n    branches: [main, 'a-*']\n  workflow_dispatch:\n\n":
            failures.append(f"raw on: {d['on']!r}")
    except ParseError as e:
        failures.append(f"workflow parse failed: {e}")
    n = len(PARSER_POSITIVE) + len(PARSER_NEGATIVE) + 1
    return n, failures


# ---------------------------------------------------------------------------
# Psych oracle (one-time evidence, not a CI path)
# ---------------------------------------------------------------------------

def read_ref(ref):
    if ":" in ref and not os.path.exists(ref):
        commit, path = ref.split(":", 1)
        return git("show", f"{commit}:{path}", binary=True).decode("utf-8")
    with open(ref, encoding="utf-8") as f:
        return f.read()


def psych(refs):
    ok = True
    for ref in refs:
        text = read_ref(ref)
        mine = parse_workflow(text)
        p = subprocess.run(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load(STDIN.read))"],
                           input=text.encode(), capture_output=True, check=True)
        theirs = json.loads(p.stdout)
        # Psych resolves the unquoted top-level `on` key to boolean true; JSON
        # renders it as "true". Only that key is treated specially: `name` and
        # `jobs` must be identical, and `on:` is checked as raw text elsewhere.
        top_ok = set(theirs) == {"name", "true", "jobs"}
        same = canon(theirs.get("name")) == canon(mine["name"]) and canon(theirs.get("jobs")) == canon(mine["jobs"])
        raw_on_ok = mine["on"].startswith("on:\n") and text.count(mine["on"]) == 1
        digest = hashlib.sha256(text.encode()).hexdigest()
        print(f"psych {ref} sha256={digest[:16]}: top-level keys {sorted(theirs)} ({'ok' if top_ok else 'UNEXPECTED'}); "
              f"name+jobs {'IDENTICAL' if same else 'DIFFERENT'}; raw on: block {len(mine['on'])} bytes")
        ok = ok and top_ok and same and raw_on_ok
    return ok


# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Host swap helper contract (scripts/ci_host_swap.py)
# ---------------------------------------------------------------------------
# The workflow step is frozen above; this pins what the script it runs may
# delete and how it behaves (Codex swap reviews 2026-10-21/22 notes). The host
# shell logic runs for real inside a scratch root with stub host commands
# (df/free/swapon/fallocate/mkswap/mountpoint/rm); nothing outside the scratch
# root is touched and no swap is created.

SWAP_SCRIPT = os.path.join(ROOT, "scripts", "ci_host_swap.py")
# The reviewed allow-list, pinned here: widening it is a reviewed test edit.
SWAP_APPROVED = (
    "/usr/local/lib/android", "/usr/share/dotnet", "/opt/ghc", "/usr/local/.ghcup",
    "/usr/local/share/boost", "/usr/local/share/powershell", "/usr/share/swift",
)
# Well-formed but not approved: refused by the allow-list.
SWAP_UNAPPROVED_PATHS = ("/usr/sbin", "/root", "/usr/lib64", "/usr/bin", "/var/lib/docker", "/opt/hostedtoolcache")
# Malformed: refused by the path grammar even if an allow-list contained them.
SWAP_BAD_GRAMMAR_PATHS = ("//usr/bin", "/usr/share/swift\t", "/usr/share/../share/swift", "/usr/share/swift/",
                          "/opt/./ghc", "/USR/share/swift", "/", "", "usr/share/swift", "/usr/share/swift dotnet")

STUBS = {
    "df": r"""#!/bin/sh
if [ "$1" = "-Pk" ]; then
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
  case "$2" in */mnt) a="${STUB_DF_MNT:-0}" ;; *) a="${STUB_DF_ROOT:-0}" ;; esac
  echo "stub 100 0 $a 0% $2"; exit 0
fi
echo "df $*"
""",
    "free": "#!/bin/sh\necho free\n",
    "swapon": r"""#!/bin/sh
case "$1" in
  --show*) [ -n "${STUB_ACTIVE:-}" ] && printf '%s\n' "$STUB_ACTIVE"; exit 0 ;;
  *) echo "swapon $1" >> "$STUB_LOG" ;;
esac
""",
    "fallocate": "#!/bin/sh\necho \"fallocate $*\" >> \"$STUB_LOG\"\n: > \"$3\"\n",
    "mkswap": "#!/bin/sh\necho \"mkswap $1\" >> \"$STUB_LOG\"\n",
    "mountpoint": r"""#!/bin/sh
[ "$1" = "-q" ] || exit 2
for m in ${STUB_MOUNTS:-}; do [ "$m" = "$2" ] && exit 0; done
exit 1
""",
    "rm": r"""#!/bin/sh
if [ "$1" = "-rf" ] && [ "$2" = "--one-file-system" ] && [ "$3" = "--" ] && [ $# -eq 4 ]; then
  for f in ${STUB_RM_FAIL:-}; do [ "$f" = "$4" ] && exit 1; done
  echo "rm $4" >> "$STUB_LOG"; exec /bin/rm -rf -- "$4"
fi
if [ "$1" = "-f" ] && [ $# -eq 2 ]; then exec /bin/rm -f "$2"; fi
echo "unexpected rm $*" >&2; exit 2
""",
}


def load_swap_module(source=None):
    import types
    if source is None:
        with open(SWAP_SCRIPT, encoding="utf-8") as f:
            source = f.read()
    mod = types.ModuleType("ci_host_swap_under_test")
    mod.__file__ = SWAP_SCRIPT
    exec(compile(source, SWAP_SCRIPT, "exec"), mod.__dict__)
    return mod


def _host_scenarios(mod, base):
    """Run the rendered host script in scratch roots; return error strings."""
    errs = []
    stubdir = os.path.join(base, "stubs")
    os.makedirs(stubdir)
    for name, body in STUBS.items():
        path = os.path.join(stubdir, name)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o755)
    # Hermetic PATH: the stubs plus the few real tools the script needs, so a
    # host's real mountpoint/swapon/df can never be reached.
    import shutil
    for tool in ("awk", "grep", "chmod"):
        real = shutil.which(tool)
        if not real:
            return [f"swap: {tool} not found for the host-script scenarios"]
        os.symlink(real, os.path.join(stubdir, tool))
    big, small = str(40 * 1024 * 1024), str(1024 * 1024)

    def run(tag, setup, env_extra, no_mountpoint=False):
        root = os.path.join(base, tag)
        assert root.startswith(base + os.sep) and os.path.isdir(base)
        for p in SWAP_APPROVED:
            os.makedirs(root + p)
            with open(os.path.join(root + p, "payload"), "w") as f:
                f.write("x")
        os.makedirs(os.path.join(root, "mnt"))
        log = os.path.join(base, tag + ".log")
        open(log, "w").close()
        setup(root)
        sd = stubdir
        if no_mountpoint:
            sd = os.path.join(base, tag + "-stubs")
            os.makedirs(sd)
            for n in os.listdir(stubdir):
                if n != "mountpoint":
                    os.symlink(os.path.join(stubdir, n), os.path.join(sd, n))
        env = {"PATH": sd, "STUB_LOG": log, "LC_ALL": "C"}
        env.update({k: v.replace("@ROOT@", root) for k, v in env_extra.items()})
        script = mod.render_host_script(root, mod.CLEANUP_PATHS)
        r = subprocess.run(["/bin/sh", "-c", script], env=env, capture_output=True, text=True, timeout=60)
        with open(log) as f:
            calls = f.read().splitlines()
        present = [p for p in SWAP_APPROVED if os.path.lexists(root + p)]
        return r, calls, present, root

    # a) clean run: every path removed, one swap file allocated under /mnt.
    r, calls, present, root = run("a", lambda root: None, {"STUB_DF_MNT": big, "STUB_DF_ROOT": big})
    swap = root + "/mnt/briglia-ci.swap"
    if r.returncode != 0 or present or f"swapon {swap}" not in calls or not any(c.startswith("fallocate") for c in calls):
        errs.append(f"swap: clean run did not remove every path and allocate the swap file under /mnt (exit {r.returncode}, {len(present)} path(s) left; {r.stderr.strip()[:120]})")

    def refused(tag, setup, extra, what, **kw):
        r, calls, present, _ = run(tag, setup, dict({"STUB_DF_MNT": big, "STUB_DF_ROOT": big}, **extra), **kw)
        removed = [c for c in calls if c.startswith("rm ")]
        if r.returncode == 0 or removed:
            errs.append(f"swap: {what} was not refused before any deletion (exit {r.returncode}, {len(removed)} path(s) removed)")

    def ancestor_link(root):
        os.rename(root + "/usr/local", root + "/usr/local-real")
        os.symlink(root + "/usr/local-real", root + "/usr/local")
    refused("b", ancestor_link, {}, "a symlinked ancestor")

    def final_link(root):  # last path in the list: earlier paths must survive
        import shutil
        shutil.rmtree(root + "/usr/share/swift")
        os.symlink(root + "/opt", root + "/usr/share/swift")
    refused("c", final_link, {}, "a symlinked final path (late in the list)")
    refused("d", lambda root: None, {"STUB_MOUNTS": "@ROOT@/usr/share/dotnet"}, "a path that is a mount point")
    refused("e", lambda root: None, {}, "cleanup without mountpoint(1)", no_mountpoint=True)

    # f/g) idempotent: an active file is reused even with no free space left.
    for tag, active in (("f", "@ROOT@/mnt/briglia-ci.swap"), ("g", "@ROOT@/briglia-ci.swap")):
        r, calls, _, _ = run(tag, lambda root: None, {"STUB_DF_MNT": small, "STUB_DF_ROOT": small, "STUB_ACTIVE": active})
        if r.returncode != 0 or any(c.startswith(("fallocate", "swapon")) for c in calls):
            errs.append(f"swap: already-active {active.replace('@ROOT@', '')} was not reused (exit {r.returncode}, allocated {any(c.startswith('fallocate') for c in calls)})")
    # h) no room anywhere and nothing active: fail loudly.
    r, calls, _, _ = run("h", lambda root: None, {"STUB_DF_MNT": small, "STUB_DF_ROOT": small})
    if r.returncode == 0 or any(c.startswith("fallocate") for c in calls):
        errs.append(f"swap: no room for the swap file did not fail the step (exit {r.returncode})")
    # i) one removal fails: the step fails.
    r, calls, _, _ = run("i", lambda root: None, {"STUB_DF_MNT": big, "STUB_DF_ROOT": big, "STUB_RM_FAIL": "@ROOT@/usr/share/dotnet"})
    if r.returncode == 0:
        errs.append("swap: a failed removal did not fail the step")
    return errs


def swap_contract_errors(source=None):
    errs = []
    try:
        mod = load_swap_module(source)
    except Exception as e:  # noqa: BLE001 - any load failure is a contract failure
        return [f"swap: script does not load: {e}"]
    approved = getattr(mod, "APPROVED_CLEANUP_PATHS", None)
    if approved != frozenset(SWAP_APPROVED):
        errs.append(f"swap: allow-list differs from the reviewed pin: {sorted(set(approved or ()) ^ set(SWAP_APPROVED))}")
    try:
        mod.check_cleanup_paths(mod.CLEANUP_PATHS, mod.APPROVED_CLEANUP_PATHS)
    except Exception as e:  # noqa: BLE001
        errs.append(f"swap: the shipped cleanup list is refused: {e}")
    if not set(getattr(mod, "CLEANUP_PATHS", ())) <= set(SWAP_APPROVED):
        errs.append("swap: cleanup list goes beyond the reviewed allow-list")
    probes = [(bad, mod.APPROVED_CLEANUP_PATHS, "pinned allow-list") for bad in SWAP_UNAPPROVED_PATHS + SWAP_BAD_GRAMMAR_PATHS]
    probes += [(bad, frozenset({bad}), "allow-list containing it") for bad in SWAP_BAD_GRAMMAR_PATHS]
    probes += [(("/opt/ghc", "/opt/ghc"), mod.APPROVED_CLEANUP_PATHS, "duplicate")]
    for bad, appr, how in probes:
        try:
            mod.check_cleanup_paths(bad if isinstance(bad, tuple) else (bad,), appr)
            errs.append(f"swap: path guard accepted {bad!r} ({how})")
        except ValueError:
            pass
    # Validation precedes every Docker call.
    calls = []
    mod.api = lambda *a, **k: calls.append(a) or {"Config": {"Image": "x"}, "Id": "x", "StatusCode": 0}
    mod.os = type("O", (), {"path": type("P", (), {"exists": staticmethod(lambda p: True)})})
    mod.swap_total_kib = lambda: 0
    mod.CLEANUP_PATHS = ("/root",)
    try:
        with _quiet():
            mod.main()
        errs.append("swap: main() accepted a cleanup list outside the allow-list")
    except ValueError:
        pass
    if calls:
        errs.append(f"swap: main() called Docker before validating the cleanup list ({calls[0][:2]})")
    # A lost create response: the helper is found by its label and removed.
    mod = load_swap_module(source)
    seen = []
    lost = TimeoutError("response lost")

    def api(method, path, body=None, **k):
        seen.append((method, path, body))
        if method == "POST" and path == "/containers/create":
            raise lost
        if method == "GET" and path.startswith("/containers/json"):
            return [{"Id": "orphan"}]
        return {"Config": {"Image": "x"}}
    mod.api = api
    mod.os = type("O", (), {"path": type("P", (), {"exists": staticmethod(lambda p: True)})})
    mod.swap_total_kib = lambda: 0
    try:
        with _quiet():
            rc = mod.main()
    except TimeoutError as e:
        if e is not lost:
            errs.append("swap: lost create response raised a different TimeoutError instead of the original error")
    except Exception as e:  # noqa: BLE001
        errs.append(f"swap: lost create response raised {type(e).__name__} instead of the original error")
    else:
        errs.append(f"swap: lost create response was swallowed (main() returned {rc!r} instead of raising the original error)")
    created = [b for m, p, b in seen if p == "/containers/create"]
    label = (created[0] or {}).get("Labels", {}).get(getattr(mod, "HELPER_LABEL", ""), "") if created else ""
    listed = [p for m, p, _ in seen if m == "GET" and p.startswith("/containers/json")]
    if not label or not any(urllib_quote_label(label) in p for p in listed) or ("DELETE", "/containers/orphan?force=1", None) not in seen:
        errs.append("swap: a helper created behind a lost response is not found by its label and removed")
    import tempfile as _tf
    with _tf.TemporaryDirectory(prefix="briglia-swap-contract-") as base:
        errs += _host_scenarios(mod, os.path.realpath(base))
    return errs


def _quiet():
    import contextlib
    import io
    stack = contextlib.ExitStack()
    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
    return stack


def urllib_quote_label(token):
    import urllib.parse
    return urllib.parse.quote(token)


def _swap_sub(old, new):
    def mutate(src):
        if old not in src:
            raise BreakSetupError(f"swap source anchor not found: {old[:60]!r}")
        return src.replace(old, new, 1)
    return mutate


SWAP_BREAKS = [
    ("S1 allow-list widened with /root (list and set together)",
     lambda src: _swap_sub('    "/usr/share/swift",\n})', '    "/usr/share/swift",\n    "/root",\n})')(
         _swap_sub('    "/usr/share/swift",           # host Swift; the jobs use the container\'s\n)',
                   '    "/usr/share/swift",           # host Swift; the jobs use the container\'s\n    "/root",\n)')(src)),
     "allow-list differs from the reviewed pin"),
    ("S2 allow-list check disabled", _swap_sub("        if p not in approved:\n", "        if False:\n"), "path guard accepted '/usr/sbin'"),
    ("S3 path grammar check removed", _swap_sub("not _PLAIN_PATH.match(p) or ", ""), "path guard accepted '//usr/bin'"),
    ("S4 validation moved after the Docker inspect",
     lambda src: _swap_sub('    image = me["Config"]["Image"]\n', '    image = me["Config"]["Image"]\n    check_cleanup_paths(CLEANUP_PATHS)\n')(
         _swap_sub('    check_cleanup_paths(CLEANUP_PATHS)\n    script = render_host_script("", CLEANUP_PATHS)\n', '    script = None\n')(src).replace(
             '"Cmd": ["--target", "1", "--mount", "--", "/bin/sh", "-c", script]', '"Cmd": ["--target", "1", "--mount", "--", "/bin/sh", "-c", render_host_script("", CLEANUP_PATHS)]')),
     "called Docker before validating"),
    ("S5 symlink check removed", _swap_sub('    if [ -L "$a" ]; then echo "refusing: $a is a symlink" >&2; exit 1; fi\n', ''), "a symlinked ancestor"),
    ("S6 mount-point check removed", _swap_sub('    if mountpoint -q "$t"; then echo "refusing: $t is a mount point" >&2; exit 1; fi\n', ''), "a path that is a mount point"),
    ("S7 missing mountpoint(1) no longer refused", _swap_sub('command -v mountpoint >/dev/null 2>&1 || { echo "mountpoint(1) missing; refusing to delete anything" >&2; exit 1; }\n', ''), "cleanup without mountpoint(1)"),
    ("S8 deletion interleaved with the checks", _swap_sub('    present="$present $t"\n', '    rm -rf --one-file-system -- "$t"\n    present="$present $t"\n'), "a symlinked final path (late in the list)"),
    ("S9 idempotence check dropped", _swap_sub('  if swapon --show=NAME --noheadings | grep -qx "$c"; then SWAP="$c"; echo "$SWAP already active"; break; fi\n', ''), "was not reused"),
    ("S10 rm without --one-file-system", _swap_sub('rm -rf --one-file-system -- "$t" &', 'rm -rf -- "$t" &'), "clean run did not remove every path"),
    ("S11 lost create response no longer cleaned up", _swap_sub("            remove_labelled_helpers(token)\n", "            pass\n"), "not found by its label"),
    ("S12 lost create error swallowed", _swap_sub('            print(f"warning: helper lookup by label failed: {e}", file=sys.stderr)\n        raise\n',
                                                 '            print(f"warning: helper lookup by label failed: {e}", file=sys.stderr)\n        return 0\n'), "was swallowed"),
]


def run_swap_breaks():
    with open(SWAP_SCRIPT, encoding="utf-8") as f:
        src = f.read()
    missed = []
    for name, mutate, want in SWAP_BREAKS:
        try:
            mutated = mutate(src)
        except BreakSetupError as e:
            missed.append(f"{name}: could not be applied ({e})")
            print(f"  BREAK {name}: NOT APPLIED ({e})")
            continue
        if mutated == src:
            missed.append(f"{name}: mutation changed nothing")
            continue
        errs = swap_contract_errors(mutated)
        hit = [e for e in errs if want in e]
        if hit:
            print(f"  BREAK {name}: caught — {hit[0]}")
        elif errs:
            missed.append(f"{name}: caught only for another reason ({errs[0]})")
            print(f"  BREAK {name}: WRONG REASON — {errs[0]}")
        else:
            missed.append(name)
            print(f"  BREAK {name}: NOT CAUGHT")
    return len(SWAP_BREAKS), missed



def main(argv):
    if argv[:1] == ["--record"] and len(argv) == 2:
        record(argv[1])
        return 0
    if argv[:1] == ["--psych"] and len(argv) >= 2:
        return 0 if psych(argv[1:]) else 1

    n, pfail = parser_tests()
    print(f"parser tests: {n - len(pfail)}/{n}")
    for f in pfail:
        print(f"  FAIL {f}")
    fixture = load_fixture()
    prov = verify_provenance(fixture)
    print(f"fixture provenance ({fixture['source']['commit'][:12]}): {'ok' if not prov else 'FAILED'}")
    for e in prov:
        print(f"  {e}")
    with open(os.path.join(ROOT, WORKFLOW_PATH), encoding="utf-8") as f:
        text = f.read()

    if argv == ["--precheck"]:
        errs = []
        try:
            cur = derive_inventory(text)
            for key in ("workflow", "platforms"):
                if canon(cur[key]) != canon(fixture[key]):
                    errs.append(f"current ci.yml {key!r} differs from the fixture")
        except ParseError as e:
            errs.append(f"current ci.yml: {e}")
        print(f"pre-split self-check: {'ok' if not errs else 'FAILED'}")
        for e in errs:
            print(f"  {e}")
        return 0 if not (pfail or prov or errs) else 1
    if argv:
        print(__doc__)
        return 2

    cache = {}
    errs = check_workflow(text, fixture, cache)
    counts = {p: len(fixture["platforms"][p]["tests"]) for p in ("linux", "macos")}
    print(f"inventory of {WORKFLOW_PATH}: {'ok' if not errs else 'FAILED'} "
          f"(frozen test steps: linux {counts['linux']}, macos {counts['macos']}; aggregator truth table 1026 cases)")
    for e in errs:
        print(f"  {e}")
    print("deliberate breaks:")
    nb, missed = run_breaks(text, fixture, cache)
    print(f"deliberate breaks caught: {nb - len(missed)}/{nb}")
    for m in missed:
        print(f"  NOT CAUGHT: {m}")
    swap_errs = swap_contract_errors()
    print(f"host swap helper contract (scripts/ci_host_swap.py): {'ok' if not swap_errs else 'FAILED'}")
    for e in swap_errs:
        print(f"  {e}")
    print("host swap helper deliberate breaks:")
    ns, smissed = run_swap_breaks()
    print(f"host swap helper breaks caught: {ns - len(smissed)}/{ns}")
    for m in smissed:
        print(f"  NOT CAUGHT: {m}")
    return 0 if not (pfail or prov or errs or missed or swap_errs or smissed) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
