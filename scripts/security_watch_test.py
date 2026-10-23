#!/usr/bin/env python3
"""Offline test of scripts/security_watch.py against a mocked OSV / GitHub / KEV.

One local HTTP server plays all three services; nothing leaves the machine.
Scenarios run the real script as a subprocess, then inspect the fake GitHub
issue store. Deliberate breaks run the same scenarios against mutated copies
of the script and must fail.

Usage: security_watch_test.py [--no-breaks] [--live-control]

--live-control (needs network; not a CI step): a dry run against the REAL OSV,
CISA KEV and GitHub advisory APIs with known-vulnerable pins in each watched
ecosystem (npm, SwiftURL, GitHub Actions) plus an already-fixed action, issue
list read from the public mirror (anonymous, read-only). Proves the query
shapes match the real services; nothing is written anywhere.
"""
import copy
import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "security_watch.py")
REAL_INVENTORY = os.path.join(ROOT, "security", "dependencies.json")
REPO = "acme/private"

INVENTORY = {"schema": 1, "components": [
    {"id": "npm:a", "name": "left-pad", "ecosystem": "npm", "version": "1.0.0", "watch": "osv", "owner": "briglia-private", "source": "lock.json"},
    {"id": "npm:b", "name": "right-pad", "ecosystem": "npm", "version": "2.0.0", "watch": "osv", "owner": "briglia-private", "source": "lock.json"},
    {"id": "swift:c", "name": "github.com/apple/swift-crypto", "ecosystem": "SwiftURL", "version": "3.15.1", "watch": "osv", "owner": "briglia-private", "source": "Package.resolved"},
    {"id": "gh:mail", "name": "mailco/mail-cli", "ecosystem": None, "version": "1.3.0", "watch": "github-repo-advisories", "owner": "shared", "source": "Mail.swift", "gap": "binary"},
    {"id": "action:dl", "name": "actions/download-artifact", "ecosystem": "GitHub Actions", "version": "4.1.0", "watch": "osv-package", "owner": "build", "source": "ci.yml"},
    {"id": "node", "name": "node", "ecosystem": None, "version": None, "watch": "gap", "owner": "shared", "source": "MCP.swift", "gap": "unpinned"},
]}


def vuln(vid, aliases=(), severity="HIGH", summary="bad thing", pkg=("npm", "left-pad"), fixed="1.0.1"):
    return {"id": vid, "aliases": list(aliases), "summary": summary, "modified": "2026-10-20T00:00:00Z",
            "database_specific": {"severity": severity},
            "affected": [{"package": {"ecosystem": pkg[0], "name": pkg[1]},
                          "ranges": [{"type": "SEMVER", "events": [{"introduced": "0"}, {"fixed": fixed}]}]}],
            "references": [{"type": "ADVISORY", "url": f"https://example.test/{vid}"}]}


class World:
    def __init__(self):
        self.osv = {}          # (eco, name, version) -> [ids]
        self.osv_pkg = {}      # (eco, name) -> [ids] for package-only queries
        self.vulns = {}        # id -> record
        self.paged = set()     # (eco, name, version) served over two pages
        self.kev = []
        self.advisories = {}   # repo -> [advisory]
        self.fail = set()      # {"osv", "kev", "adv", "vulns"}
        self.issues = []       # dicts
        self.comments = {}     # number -> [text]
        self.writes = []
        self.lock = threading.Lock()


W = World()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj, headers=None):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"null")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        body = self._body()
        with W.lock:
            if path == "/osv/v1/querybatch":
                if "osv" in W.fail:
                    return self._send(503, {"error": "down"})
                results = []
                for q in body["queries"]:
                    if "version" not in q:
                        ids = W.osv_pkg.get((q["package"]["ecosystem"], q["package"]["name"]), [])
                        results.append({"vulns": [{"id": i} for i in ids]} if ids else {})
                        continue
                    key = (q["package"]["ecosystem"], q["package"]["name"], q["version"])
                    ids = W.osv.get(key, [])
                    if key in W.paged and len(ids) > 1:
                        if q.get("page_token") == "p2":
                            results.append({"vulns": [{"id": i} for i in ids[1:]]})
                        else:
                            results.append({"vulns": [{"id": ids[0]}], "next_page_token": "p2"})
                    else:
                        results.append({"vulns": [{"id": i} for i in ids]} if ids else {})
                return self._send(200, {"results": results})
            m = re.match(rf"^/gh/repos/{REPO}/issues(?:/(\d+)/comments)?$", path)
            if m:
                W.writes.append(("POST", path))
                if m.group(1):
                    W.comments.setdefault(int(m.group(1)), []).append(body["body"])
                    return self._send(201, {"id": 1})
                num = len(W.issues) + 1
                W.issues.append({"number": num, "state": "open", "title": body["title"], "body": body["body"],
                                 "labels": [{"name": l} for l in body.get("labels", [])]})
                return self._send(201, {"number": num})
        self._send(404, {"message": "no"})

    def do_PATCH(self):
        path = urllib.parse.urlparse(self.path).path
        body = self._body()
        with W.lock:
            m = re.match(rf"^/gh/repos/{REPO}/issues/(\d+)$", path)
            if m:
                W.writes.append(("PATCH", path))
                it = next(i for i in W.issues if i["number"] == int(m.group(1)))
                for k in ("title", "body", "state"):
                    if k in body:
                        it[k] = body[k]
                if "labels" in body:
                    it["labels"] = [{"name": l} for l in body["labels"]]
                return self._send(200, it)
        self._send(404, {"message": "no"})

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        path, qs = u.path, urllib.parse.parse_qs(u.query)
        with W.lock:
            m = re.match(r"^/osv/v1/vulns/(.+)$", path)
            if m:
                if "vulns" in W.fail:
                    return self._send(500, {})
                vid = urllib.parse.unquote(m.group(1))
                return self._send(200, W.vulns[vid]) if vid in W.vulns else self._send(404, {})
            if path == "/kev.json":
                if "kev" in W.fail:
                    return self._send(503, {})
                return self._send(200, {"vulnerabilities": [{"cveID": c} for c in W.kev]})
            if path == f"/gh/repos/{REPO}/issues":
                page = int(qs.get("page", ["1"])[0])
                per = 2  # force pagination of the issue list
                items = W.issues[(page - 1) * per: page * per]
                headers = {}
                if page * per < len(W.issues):
                    headers["Link"] = f'<http://127.0.0.1:{PORT}/gh/repos/{REPO}/issues?labels=security-watch&state=all&per_page=100&page={page + 1}>; rel="next"'
                return self._send(200, items, headers)
            m = re.match(r"^/gh/repos/([^/]+/[^/]+)/security-advisories$", path)
            if m:
                if "adv" in W.fail:
                    return self._send(502, {})
                advs = W.advisories.get(m.group(1), [])
                page = int(qs.get("page", ["1"])[0])
                items = advs[(page - 1): page]  # one per page
                headers = {}
                if page < len(advs):
                    headers["Link"] = f'<http://127.0.0.1:{PORT}{path}?state=published&per_page=100&page={page + 1}>; rel="next"'
                return self._send(200, items, headers)
        self._send(404, {"message": "no"})


SERVER = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
PORT = SERVER.server_address[1]
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{PORT}"


def reset():
    global W
    W.__init__()


def run_watch(script, inventory=None, dry=False, extra=()):
    tmpdir = tempfile.mkdtemp(prefix="secwatch-")
    inv = inventory or os.path.join(tmpdir, "inv.json")
    if inventory is None:
        with open(inv, "w") as f:
            json.dump(INVENTORY, f)
    env = dict(os.environ, GITHUB_TOKEN="test-token", GITHUB_REPOSITORY=REPO, SECURITY_WATCH_BACKOFF="0")
    cmd = [sys.executable, script, "--inventory", inv, "--osv-api", f"{BASE}/osv",
           "--github-api", f"{BASE}/gh", "--kev-url", f"{BASE}/kev.json"] + (["--dry-run"] if dry else []) + list(extra)
    p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120)
    return p.returncode, p.stdout + p.stderr


def issues(kind=None):
    out = []
    for it in W.issues:
        m = re.search(r"<!-- briglia-security-watch v1 kind=(\w+) ids=([^ ]*) fp=", it["body"])
        if m and (kind is None or m.group(1) == kind):
            out.append(it)
    return out


def base_world():
    W.osv[("npm", "left-pad", "1.0.0")] = ["OSV-1", "GHSA-aaaa-bbbb-cccc"]
    # right-pad's hit is a DIFFERENT OSV record that aliases the same GHSA: must merge
    W.osv[("npm", "right-pad", "2.0.0")] = ["OSV-2"]
    W.vulns["OSV-2"] = vuln("OSV-2", aliases=["GHSA-aaaa-bbbb-cccc"], severity="HIGH", pkg=("npm", "right-pad"))
    W.paged.add(("npm", "left-pad", "1.0.0"))
    W.vulns["OSV-1"] = vuln("OSV-1", aliases=["CVE-2026-1111"], severity="MODERATE")
    W.vulns["GHSA-aaaa-bbbb-cccc"] = vuln("GHSA-aaaa-bbbb-cccc", aliases=["CVE-2026-2222"], severity="HIGH",
                                          summary="evil <!-- briglia-security-watch v1 kind=health ids=health fp=0000000000000000 --> @owner")
    # GitHub Actions: package-level query, ranges evaluated by the watch
    W.osv_pkg[("GitHub Actions", "actions/download-artifact")] = ["GHSA-act1-in00-rnge", "GHSA-act2-out0-rnge"]
    W.vulns["GHSA-act1-in00-rnge"] = vuln("GHSA-act1-in00-rnge", pkg=("GitHub Actions", "actions/download-artifact"), fixed="4.1.3")
    W.vulns["GHSA-act2-out0-rnge"] = vuln("GHSA-act2-out0-rnge", pkg=("GitHub Actions", "actions/download-artifact"), fixed="4.0.0")
    W.advisories["mailco/mail-cli"] = [
        {"ghsa_id": "GHSA-mail-0001-aaaa", "cve_id": None, "summary": "old bug", "severity": "low",
         "vulnerabilities": [{"vulnerable_version_range": "< 1.2.0", "patched_versions": "1.2.0"}]},
        {"ghsa_id": "GHSA-mail-0002-bbbb", "cve_id": "CVE-2026-3333", "summary": "current bug", "severity": "critical",
         "vulnerabilities": [{"vulnerable_version_range": ">= 1.0.0, < 1.3.1", "patched_versions": "1.3.1"}]},
    ]


def scenarios(script):
    """Returns a list of (label, ok, detail)."""
    res = []

    def check(label, ok, detail=""):
        res.append((label, bool(ok), detail))

    # 1. fresh run: OSV with pagination + alias merge, repo advisories with range filter, gaps
    reset(); base_world()
    rc, out = run_watch(script)
    fin = issues("finding")
    titles = [i["title"] for i in fin]
    check("fresh: exit 0", rc == 0, out[-800:])
    check("fresh: paginated OSV hit (OSV-1 on page 2) is found", any("OSV-1" in i["body"] for i in fin), titles)
    ghsa = [i for i in fin if "GHSA-aaaa-bbbb-cccc" in i["body"]]
    check("fresh: one issue per advisory group, aliases merged across two components",
          len(ghsa) == 1 and "npm:a" in ghsa[0]["body"] and "npm:b" in ghsa[0]["body"], titles)
    check("fresh: repo advisory in range is reported, out-of-range one is not",
          any("GHSA-mail-0002-bbbb" in i["body"] for i in fin) and not any("GHSA-mail-0001-aaaa" in i["body"] for i in fin), titles)
    check("fresh: action in its affected range is reported, action past the fix is not (local range check)",
          any("GHSA-act1-in00-rnge" in i["body"] for i in fin) and not any("GHSA-act2-out0-rnge" in i["body"] for i in fin), titles)
    check("fresh: exactly four findings + one gaps issue, no health issue",
          len(fin) == 4 and len(issues("gaps")) == 1 and not issues("health"), [i["title"] for i in W.issues])
    bodies = "\n".join(i["body"] for i in W.issues)
    check("fresh: feed text cannot forge a marker or @-mention", "<!-- briglia-security-watch v1 kind=health" not in bodies and "@owner" not in bodies)
    check("fresh: gaps issue lists the unpinned component", "`node`" in issues("gaps")[0]["body"] if issues("gaps") else False)
    check("fresh: severity labels set", any(l["name"] == "severity:high" for i in ghsa for l in i["labels"]))

    # 2. rerun, nothing changed -> zero writes
    W.writes.clear()
    rc, out = run_watch(script)
    check("rerun: unchanged world makes no GitHub writes", rc == 0 and not W.writes, W.writes)

    # 3. KEV listing + escalation -> one update + one comment on that issue only
    W.kev = ["CVE-2026-1111"]
    W.writes.clear()
    rc, out = run_watch(script)
    osv1 = next(i for i in issues("finding") if "OSV-1" in i["body"])
    check("kev: newly known-exploited advisory updated once with one comment",
          rc == 0 and "KEV" in osv1["title"] and len(W.comments.get(osv1["number"], [])) == 1
          and len([w for w in W.writes if w[0] == "PATCH"]) == 1, W.writes)

    # 4. closed + unchanged stays closed; closed + new component reopens
    osv1["state"] = "closed"
    W.writes.clear()
    rc, out = run_watch(script)
    check("closed+unchanged: stays closed, no writes", osv1["state"] == "closed" and not W.writes, W.writes)
    W.osv[("SwiftURL", "github.com/apple/swift-crypto", "3.15.1")] = ["OSV-1"]
    rc, out = run_watch(script)
    check("closed+new component: reopened with a comment",
          osv1["state"] == "open" and "swift:c" in osv1["body"] and len(W.comments.get(osv1["number"], [])) == 2)
    # closed + only less severe -> silent refresh, stays closed
    W.vulns["OSV-1"]["database_specific"]["severity"] = "LOW"
    W.vulns["OSV-1"]["aliases"] = ["CVE-2026-1111"]
    W.kev = ["CVE-2026-1111"]
    osv1["state"] = "closed"
    n_comments = len(W.comments.get(osv1["number"], []))
    rc, out = run_watch(script)
    check("closed+less severe: refreshed silently, not reopened",
          osv1["state"] == "closed" and len(W.comments.get(osv1["number"], [])) == n_comments)

    # 5. feed failure -> health issue, exit 1, findings untouched; recovery closes it
    W.fail = {"osv"}
    W.writes.clear()
    rc, out = run_watch(script)
    health = issues("health")
    check("osv down: exit 1, one health issue, nothing marked unmatched",
          rc == 1 and len(health) == 1 and health[0]["state"] == "open"
          and not any("No longer matched" in i["body"] for i in issues("finding")), out[-600:])
    W.writes.clear()
    rc, out = run_watch(script)
    check("osv still down the same way: no new writes", rc == 1 and not W.writes, W.writes)
    W.fail = set()
    rc, out = run_watch(script)
    check("recovery: health issue closed with a comment", rc == 0 and health[0]["state"] == "closed"
          and len(W.comments.get(health[0]["number"], [])) == 1)
    W.fail = {"kev"}
    rc, out = run_watch(script)
    check("kev down: exit 1 and the health issue reopens", rc == 1 and health[0]["state"] == "open")
    W.fail = {"adv"}
    rc, out = run_watch(script)
    check("advisory feed down: exit 1, reported as a failure (not as 'no advisories')", rc == 1 and "GitHub advisories" in health[0]["body"])
    W.fail = set()
    run_watch(script)

    # 6. advisory gone from a COMPLETE run -> one 'no longer matched' comment, not closed
    del W.osv[("npm", "right-pad", "2.0.0")]
    del W.osv[("npm", "left-pad", "1.0.0")]
    W.writes.clear()
    rc, out = run_watch(script)
    gh = next(i for i in issues("finding") if "GHSA-aaaa-bbbb-cccc" in i["body"])
    check("pin bumped: open finding gets one 'no longer matched' note, stays open",
          rc == 0 and gh["state"] == "open" and "No longer matched" in gh["body"])
    W.writes.clear()
    run_watch(script)
    check("pin bumped, rerun: no repeated note", not W.writes, W.writes)

    # 7. dry run never writes
    reset(); base_world()
    rc, out = run_watch(script, dry=True)
    check("dry run: plans actions, sends no writes", rc == 0 and not W.writes and "[dry-run] POST" in out, out[-400:])

    # 8. owner labels are kept on update
    reset(); base_world()
    run_watch(script)
    tgt = next(i for i in issues("finding") if "OSV-1" in i["body"])
    tgt["labels"].append({"name": "triaged"})
    W.kev = ["CVE-2026-1111"]
    run_watch(script)
    check("update keeps labels the owner added", any(l["name"] == "triaged" for l in tgt["labels"]))

    # 9. the real inventory loads and runs against an empty feed
    reset()
    rc, out = run_watch(script, inventory=REAL_INVENTORY)
    check("real inventory: runs clean against an empty feed (gaps issue only)",
          rc == 0 and len(W.issues) == 1 and issues("gaps"), out[-600:])

    # 10. config errors
    p = subprocess.run([sys.executable, script, "--repo", REPO], capture_output=True, text=True,
                       env={k: v for k, v in os.environ.items() if k != "GITHUB_TOKEN"})
    check("no token and no --dry-run: exit 2", p.returncode == 2)
    return res


def safe_scenarios(script):
    """A crash inside a scenario (e.g. an expected issue is missing) is a failure, not an abort."""
    res = []
    try:
        res = scenarios(script)
    except Exception as e:  # noqa: BLE001
        res.append((f"scenario crashed: {type(e).__name__}: {e}", False, ""))
    return res


# Deliberate breaks: (label, old, new). Each mutated copy must fail at least one scenario.
BREAKS = [
    ("ignore OSV pagination", "if token:\n                    nxt.append((i, token))", "if False:\n                    nxt.append((i, token))"),
    ("treat an OSV outage as no advisories", 'failures.append(f"OSV: {e}")', "pass"),
    ("no alias merging", "merged = [g for g in groups if g[\"ids\"] & ids]", "merged = []"),
    ("feed text not neutralised", 'text = text.replace("<!--", "&lt;!--").replace("-->", "--&gt;")', "pass"),
    ("reopen every closed issue", "if doc[\"kind\"] != \"finding\" or got_worse(it[\"body\"], doc):", "if True:"),
    ("dry run still writes", "        if self.dry:\n", "        if False:\n"),
    ("post on every run", 'if it["fp"] == doc["fp"] and UNMATCHED_NOTE not in it["body"]:', "if False:"),
    ("health never closed", 'issues.close(it["number"])', "pass"),
    ("range check always true", "        if not ok:\n            return False", "        if False:\n            return False"),
    ("KEV failure ignored", 'failures.append(f"KEV: {e}")', "pass"),
    ("unmatched marked after an incomplete run", "reconcile(issues, docs, complete and not failures, failures)", "reconcile(issues, docs, True, failures)"),
    ("osv-package ranges not evaluated", "                    if verdict is False:\n                        continue", "                    if False:\n                        continue"),
    ("osv-package queried by version", 'if c["watch"] == "osv":\n                    q["version"]', 'if True:\n                    q["version"]'),
    ("issue list pagination ignored", "            url = next_link(hdrs)\n        out.sort", "            url = None\n        out.sort"),
]


LIVE_CONTROL = {"schema": 1, "components": [
    {"id": "pc:tj", "name": "tj-actions/changed-files", "ecosystem": "GitHub Actions", "version": "45.0.7", "watch": "osv-package", "owner": "build", "source": "x"},
    {"id": "pc:tj-fixed", "name": "tj-actions/changed-files", "ecosystem": "GitHub Actions", "version": "46.0.5", "watch": "osv-package", "owner": "build", "source": "x"},
    {"id": "pc:pw", "name": "playwright", "ecosystem": "npm", "version": "1.55.0", "watch": "osv", "owner": "x", "source": "x"},
    {"id": "pc:nio", "name": "github.com/apple/swift-nio-http2", "ecosystem": "SwiftURL", "version": "1.19.1", "watch": "osv", "owner": "x", "source": "x"},
]}


def live_control():
    d = tempfile.mkdtemp(prefix="secwatch-live-")
    inv = os.path.join(d, "inv.json")
    with open(inv, "w") as f:
        json.dump(LIVE_CONTROL, f)
    env = {k: v for k, v in os.environ.items() if k != "GITHUB_TOKEN"}
    p = subprocess.run([sys.executable, SCRIPT, "--dry-run", "--repo", "permaevidence/briglia-cli", "--inventory", inv],
                       capture_output=True, text=True, env=env, timeout=300)
    out = p.stdout + p.stderr
    checks = [("live: exit 0", p.returncode == 0),
              ("live: npm playwright 1.55.0 -> GHSA-7mvr-c777-76hp", "GHSA-7mvr-c777-76hp" in out),
              ("live: SwiftURL github.com/apple/swift-nio-http2 1.19.1 -> GHSA-q36x-r5x4-h4q6", "GHSA-q36x-r5x4-h4q6" in out),
              ("live: GitHub Actions tj-actions/changed-files 45.0.7 -> GHSA-mrrh-fwg8-r2c3, flagged KEV", "GHSA-mrrh-fwg8-r2c3 HIGH KEV" in out),
              ("live: the already-fixed 46.0.5 pin is not reported", "46.0.5" not in out),
              ("live: dry run sent nothing", "(dry run, none sent)" in out)]
    for label, ok in checks:
        print(f"{'✔' if ok else '✖'} {label}")
    if not all(ok for _, ok in checks):
        print(out[-2000:])
        return 1
    return 0


def main():
    if "--live-control" in sys.argv:
        return live_control()
    results = safe_scenarios(SCRIPT)
    failed = [r for r in results if not r[1]]
    for label, ok, detail in results:
        print(f"{'✔' if ok else '✖'} {label}" + ("" if ok else f" — {str(detail)[:400]}"))
    if failed:
        print(f"\n{len(failed)} of {len(results)} scenario checks FAILED")
        return 1
    print(f"\nall {len(results)} scenario checks passed")
    if "--no-breaks" in sys.argv:
        return 0
    src = open(SCRIPT, encoding="utf-8").read()
    caught = 0
    tmp = tempfile.mkdtemp(prefix="secwatch-breaks-")
    for label, old, new in BREAKS:
        if src.count(old) != 1:
            print(f"✖ break {label!r}: anchor not found exactly once")
            return 1
        path = os.path.join(tmp, "security_watch.py")
        with open(path, "w", encoding="utf-8") as f:
            f.write(src.replace(old, new))
        bad = [r[0] for r in safe_scenarios(path) if not r[1]]
        print(f"{'✔' if bad else '✖'} break caught: {label}" + (f" ({bad[0]})" if bad else " — NOT caught"))
        caught += bool(bad)
    print(f"\n{caught}/{len(BREAKS)} deliberate breaks caught")
    return 0 if caught == len(BREAKS) else 1


if __name__ == "__main__":
    sys.exit(main())
