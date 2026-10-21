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
                   "({op: add|remove, platform, step, reason}).",
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
        if a.get("op") == "add":
            exp.append(canon(a["step"]))
        elif a.get("op") == "remove":
            exp.remove(canon(a["step"]))
        else:
            raise ValueError(f"unknown amendment op {a.get('op')!r}")
    return exp


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
        for pos, step in rest:
            c = canon(step)
            if c in all_setup_canon:
                errors.append(f"{jid}: setup step outside the setup prefix at position {pos}: {step.get('name') or step.get('uses')}")
                continue
            if c == canon(INVENTORY_STEP):
                inv_count += 1
                continue
            placed[plat].append((jid, pos, step))
        if jid in CORE_JOBS:
            if inv_count != 1:
                errors.append(f"{jid}: the inventory step must appear exactly once (found {inv_count})")
            elif canon(steps[len(prefix)]) != canon(INVENTORY_STEP):
                errors.append(f"{jid}: the inventory step must come right after the setup prefix")
        elif inv_count:
            errors.append(f"{jid}: inventory step only belongs in the core jobs")

    for plat in ("linux", "macos"):
        frozen = [canon(t) for t in fixture["platforms"][plat]["tests"]]
        try:
            exp = collections.Counter(expected_tests(fixture, plat))
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
        builds = [(j, p) for j, p, s in placed[plat] if s.get("run") == "swift build"]
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
    """Run the aggregator script like GitHub's default Linux shell does."""
    if cache is not None and script in cache:
        return cache[script]
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "agg.sh")
        with open(path, "w", encoding="utf-8") as f:
            f.write(script)

        def run(case):
            label, needs, expect = case
            env = dict(os.environ, NEEDS_JSON=json.dumps(needs))
            p = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", path], env=env,
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


def _tamper_fixture(fx):
    fx = copy.deepcopy(fx)
    fx["platforms"]["linux"]["tests"][-1]["run"] = fx["platforms"]["linux"]["tests"][-1]["run"].replace("menu_browser_test.py", "menu_browser_tests.py")
    return fx


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
        if errs:
            print(f"  BREAK {name}: caught — {errs[0]}")
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
    return 0 if not (pfail or prov or errs or missed) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
