#!/usr/bin/env python3
"""Offline test of scripts/pin_gate.py (plan v22 §3.5.2, owner requirement P).

Reuses security_watch_test.py's local fake of OSV / GitHub / Node (nothing
leaves the machine). Every case runs the real gate as a subprocess against a
throwaway git repository holding the candidate's inventory and overrides.
Deliberate breaks run the same cases against mutated copies of the gate and
must fail at least one.

Usage: pin_gate_test.py [--no-breaks]
"""
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import security_watch_test as fake  # noqa: E402  (starts the local fake server)
import security_watch as watch  # noqa: E402

GATE = os.path.join(HERE, "pin_gate.py")
NOW = "2026-10-25T12:00:00Z"
TODAY = "2026-10-25"

PINS = [
    {"id": "npm:playwright-tree:playwright", "name": "playwright", "ecosystem": "npm", "version": "1.63.0",
     "pin_kind": "exact", "owner": "briglia-private", "converges": "startup", "watch": "osv", "source": "lock.json"},
    {"id": "pypi:venv:pillow==12.3.0", "name": "pillow", "ecosystem": "PyPI", "version": "12.3.0",
     "pin_kind": "exact", "owner": "briglia-private", "converges": "startup", "watch": "osv", "source": "requirements.lock"},
    {"id": "swift:swift-crypto", "name": "github.com/apple/swift-crypto", "ecosystem": "SwiftURL", "version": "3.15.1",
     "pin_kind": "exact", "owner": "briglia-private", "converges": "bundle", "watch": "osv", "source": "Package.resolved"},
    {"id": "github-release:agentmail-cli", "name": "mailco/mail-cli", "ecosystem": None, "version": "1.3.1",
     "pin_kind": "exact", "owner": "briglia-private", "converges": "startup", "watch": "github-repo-advisories", "source": "AgentMail.swift"},
    {"id": "runtime:node", "name": "node", "ecosystem": None, "version": "24.9.1",
     "pin_kind": "exact", "owner": "briglia-private", "converges": "startup", "watch": "node-releases", "source": "NodeRuntime.swift"},
    # not client-delivered: never gated
    {"id": "action:dl", "name": "actions/download-artifact", "ecosystem": "GitHub Actions", "version": "4.1.0",
     "pin_kind": "exact", "owner": "build", "converges": "never", "watch": "osv-package", "source": "ci.yml"},
]


def ovr(component, blocker, approved=TODAY, expires="2026-11-08", reason="not reachable from Briglia", by="Matteo", **extra):
    o = {"component": component, "blocker": blocker, "reason": reason, "approvedBy": by, "approvedOn": approved, "expires": expires}
    o.update(extra)
    return o


class Repo:
    """A throwaway git repo: the candidate commit."""
    def __init__(self, gate=GATE):
        self.dir = tempfile.mkdtemp(prefix="pingate-")
        os.makedirs(os.path.join(self.dir, "security"))
        os.makedirs(os.path.join(self.dir, "scripts"))
        for name in ("security_watch.py", "advisory_node.py"):
            shutil.copy(os.path.join(HERE, name), os.path.join(self.dir, "scripts", name))
        shutil.copy(gate, os.path.join(self.dir, "scripts", "pin_gate.py"))
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.test")
        self.git("config", "user.name", "t")

    def git(self, *a):
        return subprocess.run(["git", "-C", self.dir] + list(a), capture_output=True, text=True, check=True).stdout.strip()

    def commit(self, pins=PINS, overrides=None, overrides_raw=None):
        with open(os.path.join(self.dir, "security", "dependencies.json"), "w") as f:
            json.dump({"schema": 1, "components": pins}, f)
        path = os.path.join(self.dir, "security", "pin-gate-overrides.json")
        if overrides_raw is not None:
            with open(path, "w") as f:
                f.write(overrides_raw)
        elif overrides is not None:
            with open(path, "w") as f:
                json.dump({"schema": 1, "overrides": overrides}, f)
        elif os.path.exists(path):
            os.remove(path)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "candidate", "--allow-empty")
        return self.git("rev-parse", "HEAD")


def run(repo, mode, sha, now=NOW, record_out=None, tag_record=None, extra=(), issues_repo=None, issues_token="issues-token"):
    env = dict(os.environ, GITHUB_TOKEN="test-token", SECURITY_WATCH_BACKOFF="0")
    env.pop("BRIGLIA_PIN_GATE_ISSUES_TOKEN", None)
    if issues_token is not None:
        env["BRIGLIA_PIN_GATE_ISSUES_TOKEN"] = issues_token
    gate = os.path.join(repo.dir, "scripts", "pin_gate.py")
    cmd = [sys.executable, gate, "--mode", mode, "--now", now,
           "--osv-api", f"{fake.BASE}/osv", "--github-api", f"{fake.BASE}/gh",
           "--node-index", f"{fake.BASE}/node/index.json", "--node-schedule", f"{fake.BASE}/node/schedule.json",
           "--node-wg", f"{fake.BASE}/node/wg.json"]
    cmd += ["--issues-repo", issues_repo or fake.REPO, "--issues-token-env", "BRIGLIA_PIN_GATE_ISSUES_TOKEN"]
    if mode == "promoter":
        cmd += ["--source", f"git:{sha}"]
        if record_out:
            cmd += ["--record-out", record_out]
    else:
        cmd += ["--source", f"dir:{repo.dir}", "--commit", sha, "--tag-record", tag_record or "/nonexistent"]
    p = subprocess.run(cmd + list(extra), capture_output=True, text=True, env=env, cwd=repo.dir, timeout=120)
    return p.returncode, p.stdout + p.stderr


def heartbeat(ts, number=None):
    fake.W.issues.append({"number": number or len(fake.W.issues) + 1, "state": "open", "title": "[security-watch] heartbeat",
                          "body": f"x\n\nlast-run: {ts}\n\n<!-- briglia-security-watch v1 kind=heartbeat ids=heartbeat fp=0000000000000000 -->",
                          "labels": [{"name": "security-watch"}], "created_at": "2026-10-01T00:00:00Z"})


def finding(ids, lines, state="open", kind="finding", body=None):
    n = len(fake.W.issues) + 1
    nxt = "Fixed versions in the feed: 9.9.9" if kind == "finding" else "Newest security release on the pinned line: v9.9.9"
    if body is None:
        body = "x\n\nAffected inventory components:\n" + "\n".join(lines) + f"\n\n{nxt}\n" + \
            f"\n<!-- briglia-security-watch v1 kind={kind} ids={','.join(ids)} fp=0000000000000000 -->"
    fake.W.issues.append({"number": n, "state": state, "title": "t", "body": body,
                          "labels": [{"name": "security-watch"}], "created_at": "2026-10-01T00:00:00Z"})
    return n


def line(cid, name, version):
    return f"- `{cid}` — {name} {version} · owner briglia-private · x.swift"


def clean_world():
    fake.reset()
    heartbeat("2026-10-25T06:00:00Z")


def cases(gate):
    res = []

    def check(label, ok, detail=""):
        res.append((label, bool(ok), detail))

    repo = Repo(gate)
    sha = repo.commit()

    # --- C1
    clean_world()
    rc, out = run(repo, "promoter", sha)
    check("clean world: exit 0, five client pins checked (the build pin is not gated)", rc == 0 and "5 client-delivered pins" in out, out[-500:])
    rc, out = run(repo, "signed", sha, tag_record=None)
    check("signed mode without a tag record -> refused (exit 1)", rc == 1 and "carries no pin-gate record" in out, out[-300:])

    clean_world()
    fake.W.osv[("npm", "playwright", "1.63.0")] = ["GHSA-play-0000-0001"]
    fake.W.vulns["GHSA-play-0000-0001"] = fake.vuln("GHSA-play-0000-0001", aliases=["CVE-2026-4001"], pkg=("npm", "playwright"))
    rc, out = run(repo, "promoter", sha)
    check("C1: OSV advisory on the Playwright pin -> exit 1 naming it", rc == 1 and "GHSA-play-0000-0001" in out, out[-500:])
    fake.W.vulns["GHSA-play-0000-0001"]["withdrawn"] = "2026-10-24T00:00:00Z"
    rc, out = run(repo, "promoter", sha)
    check("C1: a withdrawn OSV record is ignored", rc == 0, out[-300:])

    clean_world()
    fake.W.osv[("PyPI", "pillow", "12.3.0")] = ["PYSEC-2026-1"]
    fake.W.vulns["PYSEC-2026-1"] = dict(fake.vuln("PYSEC-2026-1", pkg=("PyPI", "pillow")), affected=[
        {"package": {"ecosystem": "PyPI", "name": "pillow"}, "ranges": [{"type": "ECOSYSTEM", "events": [{"introduced": "0"}]}]}])
    rc, out = run(repo, "promoter", sha)
    check("C1: UNFIXED OSV advisory on a Python lock entry -> blocks (no fix required)", rc == 1 and "PYSEC-2026-1" in out, out[-400:])

    clean_world()
    fake.W.osv[("SwiftURL", "github.com/apple/swift-crypto", "3.15.1")] = ["GHSA-swft-0000-0001"]
    fake.W.vulns["GHSA-swft-0000-0001"] = fake.vuln("GHSA-swft-0000-0001", pkg=("SwiftURL", "github.com/apple/swift-crypto"))
    rc, out = run(repo, "signed", sha, tag_record=None)
    check("C1 still evaluated after a refused record? (signed refuses on the record first)", rc == 1, out[-200:])

    clean_world()
    fake.W.advisories["mailco/mail-cli"] = [
        {"ghsa_id": "GHSA-mail-0002-bbbb", "cve_id": "CVE-2026-3333", "summary": "current", "severity": "critical",
         "vulnerabilities": [{"vulnerable_version_range": ">= 1.0.0, < 1.3.2", "patched_versions": "1.3.2"}]}]
    rc, out = run(repo, "promoter", sha)
    check("C1: GitHub advisory range covering the AgentMail pin -> blocks", rc == 1 and "GHSA-mail-0002-bbbb" in out, out[-400:])
    fake.W.advisories["mailco/mail-cli"][0]["vulnerabilities"][0]["vulnerable_version_range"] = "< 1.3.1"
    rc, out = run(repo, "promoter", sha)
    check("C1: GitHub advisory range excluding the pin -> clear", rc == 0, out[-300:])
    fake.W.advisories["mailco/mail-cli"][0]["vulnerabilities"][0]["vulnerable_version_range"] = "~1.3"
    rc, out = run(repo, "promoter", sha)
    check("C1: GitHub advisory range the gate cannot evaluate -> blocks (applicability unknown)", rc == 1 and "unknown" in out, out[-400:])

    clean_world()
    fake.W.node.insert(0, {"version": "v24.9.2", "lts": "Krypton", "security": True})
    rc, out = run(repo, "promoter", sha)
    check("C1: Node pin behind its line's security release -> node-behind:v24.9.2", rc == 1 and "node-behind:v24.9.2" in out, out[-400:])
    clean_world()
    fake.W.schedule["v24"]["end"] = "2026-10-25"
    rc, out = run(repo, "promoter", sha)
    check("C1: Node line ending today -> node-eol:24", rc == 1 and "node-eol:24" in out, out[-400:])
    clean_world()
    fake.W.wg["8"] = {"cve": ["CVE-2026-8888"], "vulnerable": "24.x", "patched": "", "severity": "high", "affectedEnvironments": ["all"]}
    rc, out = run(repo, "promoter", sha)
    check("C1: unfixed Node Security WG advisory on the pin -> blocks", rc == 1 and "CVE-2026-8888" in out, out[-400:])

    for feed, label in (("osv", "OSV"), ("adv", "GitHub advisories"), ("node", "Node index"), ("schedule", "Node schedule"), ("wg", "Node WG")):
        clean_world()
        fake.W.fail = {feed}
        rc, out = run(repo, "promoter", sha)
        check(f"C1: {label} unavailable -> exit 2, 'nothing can override this'", rc == 2 and "nothing can override" in out, out[-300:])
    clean_world()
    fake.W.osv_override = {"vulns": "not-a-list"}
    rc, out = run(repo, "promoter", sha)
    check("C1: malformed OSV response -> exit 2", rc == 2, out[-300:])

    # --- C2
    clean_world()
    finding(["GHSA-old0-0000-0001"], [line("npm:playwright-tree:playwright", "playwright", "1.63.0")])
    rc, out = run(repo, "promoter", sha)
    check("C2: open finding at the candidate's version -> blocks", rc == 1 and "issue #2" in out, out[-400:])
    rc, out = run(repo, "promoter", sha, issues_token=None)
    check("C2: no issues token -> exit 2 (never C1-only)", rc == 2 and "never C1-only" in out, out[-300:])
    clean_world()
    finding(["GHSA-old0-0000-0001"], [line("npm:playwright-tree:playwright", "playwright", "1.62.0")])
    rc, out = run(repo, "promoter", sha)
    check("C2: open finding at an OLDER version (pin bumped) -> clear", rc == 0, out[-300:])
    clean_world()
    finding(["GHSA-old0-0000-0001"], [line("npm:playwright-tree:playwright", "playwright", "1.63.0")], state="closed")
    rc, out = run(repo, "promoter", sha)
    check("C2: closed finding -> clear", rc == 0, out[-300:])
    clean_world()
    finding(["GHSA-gone-0000-0001"], [line("npm:removed:x", "x", "1.0.0")])
    rc, out = run(repo, "promoter", sha)
    check("C2: finding for a component the candidate no longer ships -> clear", rc == 0, out[-300:])
    clean_world()
    finding(["runtime:node"], [line("runtime:node", "node", "24.9.1")], kind="pin")
    rc, out = run(repo, "promoter", sha)
    check("C2: open pin issue without reason tokens -> blocks (unreadable, fail closed)", rc == 1 and "malformed reason tokens" in out, out[-300:])

    # --- R6: rendered pin issues block per exact reason, each overridable on its own
    node_pin = next(c for c in PINS if c["id"] == "runtime:node")

    def pin_issue(reasons, body_edit=None):
        doc = watch.pin_doc(node_pin, reasons, "v24.9.2", "2026-10-25")
        body = body_edit(doc["body"]) if body_edit else doc["body"]
        finding(doc["ids"], [], kind="pin", body=body)

    clean_world()
    pin_issue(["node-behind:v24.9.2"])
    rc, out = run(repo, "promoter", sha)
    check("C2 (R6): rendered pin issue, C1 clear -> blocker node-behind:v24.9.2 (not the grouping id)",
          rc == 1 and "node-behind:v24.9.2" in out and "runtime:node runtime:node" not in out, out[-400:])
    s_one = repo.commit(overrides=[ovr("runtime:node", "node-behind:v24.9.2")])
    rec1 = os.path.join(repo.dir, "..", os.path.basename(repo.dir) + "-record-r6one.txt")
    rc, out = run(repo, "promoter", s_one, record_out=rec1)
    tag1 = os.path.join(repo.dir, "..", os.path.basename(repo.dir) + "-tag-r6one.txt")
    with open(tag1, "w") as f:
        f.write("Briglia v9.9.9\n\n" + (open(rec1).read() if os.path.exists(rec1) else ""))
    check("C2 (R6): the exact (runtime:node, node-behind:v24.9.2) override clears the open watch issue", rc == 0, out[-400:])
    s_grp = repo.commit(overrides=[ovr("runtime:node", "GHSA-zzzz-zzzz-zzzz")])
    rc, out = run(repo, "promoter", s_grp)
    check("C2 (R6): an override for some other blocker does not clear it", rc == 1 and "node-behind:v24.9.2" in out, out[-400:])
    clean_world()
    fake.W.node.insert(0, {"version": "v24.9.2", "lts": "Krypton", "security": True})
    fake.W.schedule["v24"]["end"] = "2026-10-25"
    pin_issue(["node-behind:v24.9.2", "node-eol:24"])
    rc, out = run(repo, "promoter", s_one)
    check("C2 (R6): behind + EOL, only behind overridden -> still blocked by node-eol:24", rc == 1 and "node-eol:24" in out, out[-400:])
    s_both = repo.commit(overrides=[ovr("runtime:node", "node-behind:v24.9.2"), ovr("runtime:node", "node-eol:24")])
    rec2 = os.path.join(repo.dir, "..", os.path.basename(repo.dir) + "-record-r6.txt")
    rc, out = run(repo, "promoter", s_both, record_out=rec2)
    check("C2 (R6): behind + EOL, both overridden -> clear (C1 and C2)", rc == 0, out[-400:])
    tag2 = os.path.join(repo.dir, "..", os.path.basename(repo.dir) + "-tag-r6.txt")
    with open(tag2, "w") as f:
        f.write("Briglia v9.9.9\n\n" + (open(rec2).read() if os.path.exists(rec2) else ""))
    rc, out = run(repo, "signed", s_both, now="2026-10-25T13:00:00Z", tag_record=tag2)
    check("C2 (R6): signed mode, same issue and overrides -> clear", rc == 0 and "OVERRIDE APPLIED" in out, out[-400:])
    repo.git("checkout", "-q", s_one)   # signed mode reads the tagged tree from the working directory
    clean_world()
    pin_issue(["node-behind:v24.9.2"], lambda b: b.replace("(blocker `node-behind:v24.9.2`)", "(blocker `node-behind:latest`)"))
    rc, out = run(repo, "promoter", s_one)
    check("C2 (R6): a malformed reason token -> blocks even with the override (fail closed)", rc == 1 and "malformed reason tokens" in out, out[-400:])
    rc, out = run(repo, "signed", s_one, now="2026-10-25T13:00:00Z", tag_record=tag1)
    check("C2 (R6): signed mode (valid record for this commit), malformed reason token -> refused by C2", rc == 1 and "malformed reason tokens" in out, out[-300:])
    # Round 2: a malformed SECOND reason must not vanish when the first is intact and overridden.
    for label, edit in (("indented EOL line", lambda b: b.replace("\n- end of life:", "\n  - end of life:")),
                        ("unbulleted EOL line", lambda b: b.replace("\n- end of life:", "\nend of life:")),
                        ("EOL token disagreeing with its text", lambda b: b.replace("(blocker `node-eol:24`)", "(blocker `node-eol:22`)")),
                        ("an unexpected extra line", lambda b: b.replace("\n\nAffected inventory", "\nsee also: notes\n\nAffected inventory"))):
        clean_world()
        pin_issue(["node-behind:v24.9.2", "node-eol:24"], edit)
        rc, out = run(repo, "promoter", s_one)
        check(f"C2 (R6 r2): behind overridden + {label} -> refused (promoter)", rc == 1 and "malformed reason tokens" in out, out[-300:])
        rc, out = run(repo, "signed", s_one, now="2026-10-25T13:00:00Z", tag_record=tag1)
        check(f"C2 (R6 r2): behind overridden + {label} -> refused (signed, valid record)", rc == 1 and "malformed reason tokens" in out, out[-300:])
    sha = repo.commit()
    clean_world()
    fake.W.issues.append({"number": 2, "state": "open", "title": "h", "labels": [], "created_at": "2026-10-01T00:00:00Z",
                          "body": "x\n<!-- briglia-security-watch v1 kind=health ids=health fp=0000000000000000 -->"})
    rc, out = run(repo, "promoter", sha)
    check("C2: open health issue -> watch-health", rc == 1 and "incomplete data" in out, out[-300:])
    fake.reset(); heartbeat("2026-10-23T23:00:00Z")
    rc, out = run(repo, "promoter", sha)
    check("C2: heartbeat 37 h old -> watch-stale", rc == 1 and "older than 36 h" in out, out[-300:])
    fake.reset()
    rc, out = run(repo, "promoter", sha)
    check("C2: no heartbeat issue -> watch-stale", rc == 1 and "heartbeat issue is missing" in out, out[-300:])
    fake.reset(); heartbeat("2026-10-25T13:00:00Z")
    rc, out = run(repo, "promoter", sha)
    check("C2: heartbeat dated in the future -> watch-stale", rc == 1 and "in the future" in out, out[-300:])
    fake.reset()
    fake.W.issues.append({"number": 1, "state": "open", "title": "hb", "labels": [], "created_at": "2026-10-01T00:00:00Z",
                          "body": "no time here\n<!-- briglia-security-watch v1 kind=heartbeat ids=heartbeat fp=0000000000000000 -->"})
    rc, out = run(repo, "promoter", sha)
    check("C2: heartbeat without a readable last-run -> watch-stale", rc == 1 and "no readable last-run" in out, out[-300:])
    clean_world()
    finding(["GHSA-garb-0000-0001"], ["- garbled line"])
    rc, out = run(repo, "promoter", sha)
    check("C2: open finding with no readable component line -> watch-unreadable", rc == 1 and "watch-unreadable:#2" in out, out[-300:])
    # R23-1: the whole section must be the generated format
    obsolete = line("npm:playwright-tree:playwright", "playwright", "1.62.0")
    for label, lines in (
            ("a record that lost its backticks", [obsolete, "- runtime:node — node 24.9.1 · owner briglia-private · x.swift"]),
            ("a record that lost its list marker", [obsolete, "`runtime:node` — node 24.9.1 · owner briglia-private · x.swift"]),
            ("an indented record", [obsolete, "  " + line("runtime:node", "node", "24.9.1")]),
            ("an unexpected line in the section", [obsolete, "see also the other issue"])):
        clean_world()
        finding(["GHSA-strc-0000-0001"], lines)
        rc, out = run(repo, "promoter", sha)
        check(f"C2 strict section: {label} -> watch-unreadable (even with one valid record)", rc == 1 and "watch-unreadable:#2" in out, out[-300:])
    for label, body in (
            ("two section headings", "Affected inventory components:\n" + obsolete + "\n\nFixed versions in the feed: x\n\nAffected inventory components:\n" + obsolete + "\n\nFixed versions in the feed: x\n"),
            ("no blank line before the next section", "Affected inventory components:\n" + obsolete + "\nFixed versions in the feed: x\n"),
            ("an unexpected section after the block", "Affected inventory components:\n" + obsolete + "\n\nSomething else\n")):
        clean_world()
        finding(["GHSA-strc-0000-0002"], [], body=body + "\n<!-- briglia-security-watch v1 kind=finding ids=GHSA-strc-0000-0002 fp=0000000000000000 -->")
        rc, out = run(repo, "promoter", sha)
        check(f"C2 strict section: {label} -> watch-unreadable", rc == 1 and "watch-unreadable:#2" in out, out[-300:])
    clean_world()
    finding(["GHSA-strc-0000-0003"], [obsolete, line("swift:old", "x", "1.0.0")])
    rc, out = run(repo, "promoter", sha)
    check("C2 strict section: a fully valid issue listing only obsolete versions passes", rc == 0, out[-300:])
    clean_world()
    finding(["GHSA-strc-0000-0004"], [obsolete, line("runtime:node", "node", "24.9.1")])
    rc, out = run(repo, "promoter", sha)
    check("C2 strict section: a fully valid record at the candidate's version is an ordinary blocker", rc == 1 and "lists runtime:node at 24.9.1" in out, out[-300:])
    clean_world()
    finding(["GHSA-mark-0000-0001"], [obsolete], body="no marker here\n")
    rc, out = run(repo, "promoter", sha)
    check("C2: a labelled open issue without a marker -> watch-unreadable", rc == 1 and "no single valid marker" in out, out[-300:])
    clean_world()
    finding(["GHSA-mark-0000-0002"], [obsolete], body="Affected inventory components:\n" + obsolete + "\n\nFixed versions in the feed: x\n\n<!-- briglia-security-watch v1 kind=finding ids=A fp=0000000000000000 -->\n<!-- briglia-security-watch v1 kind=finding ids=B fp=0000000000000000 -->")
    rc, out = run(repo, "promoter", sha)
    check("C2: two markers in one issue -> watch-unreadable", rc == 1 and "no single valid marker" in out, out[-300:])
    clean_world()
    heartbeat("2026-10-25T07:00:00Z")
    rc, out = run(repo, "promoter", sha)
    check("C2: two heartbeat issues -> watch-stale", rc == 1 and "more than one heartbeat" in out, out[-300:])
    clean_world()
    finding(["GHSA-conf-0000-0001"], [line("runtime:node", "node", "24.9.1"), line("runtime:node", "node", "24.9.0")])
    rc, out = run(repo, "promoter", sha)
    check("C2: conflicting component lines -> watch-unreadable", rc == 1 and "watch-unreadable" in out, out[-300:])
    clean_world()
    rc, out = run(repo, "promoter", sha, issues_repo="other/repo")   # the fake 404s this issue list
    check("C2: issue list unreadable -> exit 2", rc == 2, out[-300:])

    # --- overrides
    clean_world()
    finding(["GHSA-play-0000-0009", "CVE-2026-9009"], [line("npm:playwright-tree:playwright", "playwright", "1.63.0")])
    sha_o = repo.commit(overrides=[ovr("npm:playwright-tree:playwright", "CVE-2026-9009")])
    rc, out = run(repo, "promoter", sha_o)
    check("override: an alias of the blocker clears it and is printed as APPLIED", rc == 0 and "OVERRIDE APPLIED" in out, out[-400:])
    sha_w = repo.commit(overrides=[ovr("pypi:venv:pillow==12.3.0", "CVE-2026-9009")])
    rc, out = run(repo, "promoter", sha_w)
    check("override: the right blocker on the WRONG component does not clear it (printed unused)", rc == 1 and "unused" in out, out[-400:])
    sha_e = repo.commit(overrides=[ovr("npm:playwright-tree:playwright", "CVE-2026-9009", approved="2026-10-01", expires="2026-10-25")])
    rc, out = run(repo, "promoter", sha_e)
    check("override: expiring TODAY is no longer valid (expiry day not covered)", rc == 1 and "EXPIRED" in out, out[-400:])
    sha_e2 = repo.commit(overrides=[ovr("npm:playwright-tree:playwright", "CVE-2026-9009", approved="2026-10-01", expires="2026-10-26")])
    rc, out = run(repo, "promoter", sha_e2)
    check("override: expiring tomorrow is still valid", rc == 0, out[-300:])
    clean_world()
    sha_g = repo.commit(overrides=[ovr("watch", "watch-stale")])
    fake.reset(); heartbeat("2026-10-23T23:00:00Z")
    rc, out = run(repo, "promoter", sha_g)
    check("override: reserved component 'watch' clears a global watch-stale blocker", rc == 0 and "OVERRIDE APPLIED: watch watch-stale" in out, out[-400:])
    bad_overrides = [
        ("future approval date", [ovr("runtime:node", "node-eol:24", approved="2030-01-01", expires="2030-01-31")], "future"),
        ("more than 30 days", [ovr("runtime:node", "node-eol:24", approved=TODAY, expires="2026-11-25")], "at most 30 days"),
        ("expires before approval", [ovr("runtime:node", "node-eol:24", approved=TODAY, expires="2026-10-24")], "after approvedOn"),
        ("unknown key", [ovr("runtime:node", "node-eol:24", ticket="X-1")], "exactly the keys"),
        ("empty reason", [ovr("runtime:node", "node-eol:24", reason=" ")], "non-empty"),
        ("not the owner", [ovr("runtime:node", "node-eol:24", by="Claude")], "must be the owner"),
        ("not a real date", [ovr("runtime:node", "node-eol:24", approved="2026-02-30")], "real date"),
        ("bad blocker token", [ovr("runtime:node", "node-everything")], "neither an advisory id"),
        ("duplicate pair", [ovr("runtime:node", "node-eol:24"), ovr("runtime:node", "node-eol:24")], "duplicate"),
        ("65 entries", [ovr("runtime:node", f"GHSA-aaaa-bbbb-{i:04d}") for i in range(65)], "more than 64"),
    ]
    for label, overrides, needle in bad_overrides:
        clean_world()
        s = repo.commit(overrides=overrides)
        rc, out = run(repo, "promoter", s)
        check(f"override refused: {label} -> exit 2", rc == 2 and needle in out, out[-300:])
    for label, raw in (("malformed JSON", "{"), ("extra top-level key", '{"schema": 1, "overrides": [], "note": "x"}'), ("schema 2", '{"schema": 2, "overrides": []}')):
        clean_world()
        s = repo.commit(overrides_raw=raw)
        rc, out = run(repo, "promoter", s)
        check(f"override refused: {label} -> exit 2", rc == 2, out[-300:])
    clean_world()
    finding(["GHSA-play-0000-0009", "CVE-2026-9009"], [line("npm:playwright-tree:playwright", "playwright", "1.63.0")])
    s_plain = repo.commit()
    with open(os.path.join(repo.dir, "security", "pin-gate-overrides.json"), "w") as f:
        json.dump({"schema": 1, "overrides": [ovr("npm:playwright-tree:playwright", "CVE-2026-9009")]}, f)
    rc, out = run(repo, "promoter", s_plain)
    check("inputs come from the candidate commit: an override only in the working tree is not seen", rc == 1, out[-300:])
    os.remove(os.path.join(repo.dir, "security", "pin-gate-overrides.json"))

    # --- inventory
    for label, pins, needle in (
            ("a client pin without converges", [dict(PINS[0], converges=None)], "converges"),
            ("a client pin outside the covered watch kinds", [dict(PINS[0], watch="gap")], "covers only"),
            ("no client pins at all", [PINS[-1]], "no client-delivered pins"),
            ("the reserved id 'watch'", [dict(PINS[0], id="watch")], "reserved")):
        clean_world()
        s = repo.commit(pins=pins)
        rc, out = run(repo, "promoter", s)
        check(f"inventory refused: {label} -> exit 2", rc == 2 and needle in out, out[-300:])

    # --- the tag record (R21-2)
    clean_world()
    sha_r = repo.commit(overrides=[ovr("watch", "watch-stale")])
    fake.reset(); heartbeat("2026-10-23T23:00:00Z")
    rec = os.path.join(repo.dir, "..", os.path.basename(repo.dir) + "-record.txt")
    rc, out = run(repo, "promoter", sha_r, record_out=rec)
    text = open(rec).read() if os.path.exists(rec) else ""
    check("record: a clear promoter run writes the record with the commit, the bound blobs and the applied override",
          rc == 0 and f"commit: {sha_r}" in text and "blob scripts/pin_gate.py: " in text
          and "override: watch watch-stale" in text and f"blob security/dependencies.json: {repo.git('rev-parse', sha_r + ':security/dependencies.json')}" in text,
          out[-300:] + text)
    tagmsg = os.path.join(repo.dir, "..", os.path.basename(repo.dir) + "-tag.txt")
    with open(tagmsg, "w") as f:
        f.write("Briglia v9.9.9\n\n" + text)
    rc, out = run(repo, "signed", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: signed mode accepts the record and re-runs C1 + C2 (clear, quoted override applied)", rc == 0 and "OVERRIDE APPLIED" in out, out[-400:])
    clean_world()
    fake.W.issues.append({"number": 2, "state": "open", "title": "h", "labels": [], "created_at": "2026-10-01T00:00:00Z",
                          "body": "x\n<!-- briglia-security-watch v1 kind=health ids=health fp=0000000000000000 -->"})
    forged = text.replace("override: watch watch-stale — not reachable from Briglia (approved by Matteo on 2026-10-25, expires 2026-11-08)\n", "")
    with open(tagmsg, "w") as f:
        f.write(forged)
    rc, out = run(repo, "signed", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("R22-1: C1 clear, C2 blocking (open health issue), a correct fresh self-authored clear record -> signing refused",
          rc == 1 and "incomplete data" in out, out[-300:])
    rc, out = run(repo, "signed", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg, issues_token=None)
    check("signed mode without the issues token -> exit 2", rc == 2, out[-300:])
    rc, out = run(repo, "precheck", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg, issues_token=None)
    check("precheck (authorize job, no token): C1 + record structure only, and says it is NOT an authorization",
          rc == 0 and "NOT an authorization" in out, out[-300:])
    clean_world()
    fake.reset(); heartbeat("2026-10-23T23:00:00Z")
    with open(tagmsg, "w") as f:
        f.write(forged)
    rc, out = run(repo, "signed", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: an override applied at signing but not quoted in the record -> refused", rc == 1 and "did not disclose" in out, out[-300:])
    with open(tagmsg, "w") as f:
        f.write(text)
    other = repo.commit(overrides=[ovr("watch", "watch-stale")])   # same tree, new commit
    rc, out = run(repo, "signed", other, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: for another commit -> refused", rc == 1 and "names commit" in out, out[-300:])
    s_changed = repo.commit(pins=PINS[:-1] + [dict(PINS[-1], version="4.1.1")], overrides=[ovr("watch", "watch-stale")])
    with open(tagmsg, "w") as f:
        f.write(text.replace(f"commit: {sha_r}", f"commit: {s_changed}"))
    rc, out = run(repo, "signed", s_changed, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: the tagged tree's inventory differs from what passed -> refused", rc == 1 and "differs from the tagged tree" in out, out[-300:])
    repo.git("checkout", "-q", sha_r)
    with open(tagmsg, "w") as f:
        f.write(text.replace("override: watch watch-stale — not reachable", "override: watch watch-stale — edited"))
    rc, out = run(repo, "signed", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: quoting an override the tree does not contain -> refused", rc == 1 and "does not contain" in out, out[-300:])
    with open(tagmsg, "w") as f:
        f.write(text + text)
    rc, out = run(repo, "signed", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: two blocks -> refused", rc == 1 and "exactly one" in out, out[-300:])
    with open(tagmsg, "w") as f:
        f.write(text.replace("result: clear", "result: blocked"))
    rc, out = run(repo, "signed", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: not a clear result -> refused", rc == 1, out[-300:])
    with open(tagmsg, "w") as f:
        f.write(text)
    fake.W.osv[("npm", "playwright", "1.63.0")] = ["GHSA-late-0000-0001"]
    fake.W.vulns["GHSA-late-0000-0001"] = fake.vuln("GHSA-late-0000-0001", pkg=("npm", "playwright"))
    rc, out = run(repo, "signed", sha_r, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: valid record but a NEW advisory since -> C1 refuses at signing", rc == 1 and "GHSA-late-0000-0001" in out, out[-300:])
    clean_world()
    sha_u = repo.commit(overrides=[ovr("watch", "watch-stale"), ovr("npm:playwright-tree:playwright", "GHSA-late-0000-0001")])
    rc, out = run(repo, "promoter", sha_u, record_out=rec)
    text_u = open(rec).read()
    repo.git("checkout", "-q", sha_u)
    with open(tagmsg, "w") as f:
        f.write(text_u)
    fake.W.osv[("npm", "playwright", "1.63.0")] = ["GHSA-late-0000-0001"]
    fake.W.vulns["GHSA-late-0000-0001"] = fake.vuln("GHSA-late-0000-0001", pkg=("npm", "playwright"))
    rc, out = run(repo, "signed", sha_u, now="2026-10-25T13:00:00Z", tag_record=tagmsg)
    check("record: an override needed at signing but not disclosed in the record -> refused",
          rc == 1 and "did not disclose" in out, out[-300:])
    shutil.rmtree(repo.dir, ignore_errors=True)
    for p in (rec, tagmsg):
        try:
            os.remove(p)
        except OSError:
            pass
    return res


def safe(gate):
    try:
        return cases(gate)
    except Exception as e:  # noqa: BLE001
        return [(f"cases crashed: {type(e).__name__}: {e}", False, "")]


BREAKS = [
    ("C2 version match ignored", 'if comp is not None and version == comp["version"]:', "if comp is not None:"),
    ("health issue ignored", '            general.append({"ids": {"watch-health"}', '            pass  # ({"ids": {"watch-health"}'),
    ("stale heartbeat accepted", "elif (now - beat).total_seconds() > watch.HEARTBEAT_GAP_HOURS * 3600:", "elif False:"),
    ("expiry day covered", "live = [o for o in overrides if today < o[\"_expires\"]]", "live = [o for o in overrides if today <= o[\"_expires\"]]"),
    ("future approval allowed", "        if approved > today:", "        if False:"),
    ("feed failure read as clear", "nothing can override this — retry\", file=sys.stderr)\n        return 2", "nothing can override this — retry\", file=sys.stderr)\n        return 0"),
    ("record commit not checked", '    if rec["commit"] != commit:', "    if False:"),
    ("record blobs not checked", '        if rec["blobs"][p] != blobs[p]:', "        if False:"),
    ("signed mode skips C2", "        extra, general, c2 = issue_blockers(pins, args, now)", "        extra, general, c2 = {}, [], {\"issues\": 0, \"heartbeat\": \"n/a\"}"),
    ("strict section: malformed records skipped", "        if not m:\n            return None", "        if not m:\n            i += 1\n            continue"),
    ("next section not required", "not lines[i + 1].startswith(NEXT_SECTION[kind])", "False"),
    ("markerless issues skipped", "            if it[\"state\"] == \"open\":\n                general.append({\"ids\": {f\"watch-unreadable:#{it['number']}\"}", "            if False:\n                general.append({\"ids\": {f\"watch-unreadable:#{it['number']}\"}"),
    ("missing issues token falls back to C1", 'raise ConfigError(f"the issues token ({args.issues_token_env}) is not set: C2 cannot run, refusing (never C1-only)")', "pass"),
    ("Node WG not checked by the gate", "            for f in watch.node_pin_findings(c, wg, rows):", "            for f in []:"),
    ("unreadable issue lines ignored", "        if parsed is None:", "        if False:"),
    ("override matches any component", 'if o["component"] == cid and o["blocker"] in b["ids"]', 'if o["blocker"] in b["ids"]'),
    ("signed mode skips the record", "            rec = parse_record(tag_text)\n            verify_record(rec, commit, blobs, now, overrides)", "            rec = None"),
    ("undisclosed override accepted", "        if undisclosed:", "        if False:"),
    ("withdrawn OSV records block", '            if rec.get("withdrawn"):\n                continue', '            if False:\n                continue'),
    ("R6 pin reasons collapsed to the grouping id", "                    for r in reasons:\n                        out[cid].append({\"ids\": {r}",
     "                    for r in reasons[:0] + [None]:\n                        out[cid].append({\"ids\": set(it[\"ids\"])"),
    ("R6 malformed reason tokens accepted", "            if not (m and m.group(1) == m.group(2)):\n                return None",
     "            if not m:\n                continue"),
    ("missing heartbeat accepted", '            general.append({"ids": {"watch-stale"}, "why": "the security watch heartbeat issue is missing"})', "            pass"),
]


def main():
    results = safe(GATE)
    failed = [r for r in results if not r[1]]
    for label, ok, detail in results:
        print(f"{'✔' if ok else '✖'} {label}" + ("" if ok else f" — {str(detail)[:500]}"))
    if failed:
        print(f"\n{len(failed)} of {len(results)} pin-gate checks FAILED")
        return 1
    print(f"\nall {len(results)} pin-gate checks passed")
    if "--no-breaks" in sys.argv:
        return 0
    src = open(GATE, encoding="utf-8").read()
    tmp = tempfile.mkdtemp(prefix="pingate-breaks-")
    caught = 0
    for label, old, new in BREAKS:
        if src.count(old) != 1:
            print(f"✖ break {label!r}: anchor not found exactly once")
            return 1
        path = os.path.join(tmp, "pin_gate.py")
        with open(path, "w", encoding="utf-8") as f:
            f.write(src.replace(old, new))
        bad = [r[0] for r in safe(path) if not r[1]]
        print(f"{'✔' if bad else '✖'} break caught: {label}" + (f" ({bad[0]})" if bad else " — NOT caught"))
        caught += bool(bad)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{caught}/{len(BREAKS)} deliberate gate breaks caught")
    return 0 if caught == len(BREAKS) else 1


if __name__ == "__main__":
    sys.exit(main())
