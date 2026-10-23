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
import datetime
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
        self.kev = ["CVE-2000-0001"]   # the real catalogue is never empty
        self.node = [  # nodejs.org/dist/index.json shape, newest first
            {"version": "v24.9.1", "lts": "Krypton", "security": True},
            {"version": "v24.9.0", "lts": "Krypton", "security": False},
            {"version": "v25.1.0", "lts": False, "security": True},          # current line, not LTS
            {"version": "v22.20.0", "lts": "Jod", "security": True},
            {"version": "v18.20.9", "lts": "Hydrogen", "security": True},     # below the minimum major
        ]
        self.heartbeat_writes = 0
        self.advisories = {}   # repo -> [advisory]
        self.fail = set()      # {"osv", "kev", "adv", "vulns", "node"}
        self.fail_ids = set()  # OSV record ids whose GET fails
        self.adv_override = None  # raw advisory list served instead (malformed-success cases)
        self.osv_override = None  # raw querybatch result served for every query instead
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
                if W.osv_override is not None:
                    return self._send(200, {"results": [copy.deepcopy(W.osv_override) for _ in body["queries"]]})
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
                                 "labels": [{"name": l} for l in body.get("labels", [])],
                                 "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
                return self._send(201, {"number": num})
        self._send(404, {"message": "no"})

    def do_PATCH(self):
        path = urllib.parse.urlparse(self.path).path
        body = self._body()
        with W.lock:
            m = re.match(rf"^/gh/repos/{REPO}/issues/(\d+)$", path)
            if m:
                it = next(i for i in W.issues if i["number"] == int(m.group(1)))
                if "kind=heartbeat" in it["body"]:
                    W.heartbeat_writes += 1   # the per-run heartbeat body edit is counted apart
                else:
                    W.writes.append(("PATCH", path))
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
                vid = urllib.parse.unquote(m.group(1))
                if "vulns" in W.fail or vid in W.fail_ids:
                    return self._send(500, {})
                return self._send(200, W.vulns[vid]) if vid in W.vulns else self._send(404, {})
            if path == "/kev.json":
                if "kev" in W.fail:
                    return self._send(503, {})
                return self._send(200, {"vulnerabilities": [{"cveID": c} for c in W.kev]})
            if path == "/node/index.json":
                if "node" in W.fail:
                    return self._send(503, {})
                return self._send(200, W.node)
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
                if W.adv_override is not None:
                    return self._send(200, W.adv_override)
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
           "--github-api", f"{BASE}/gh", "--kev-url", f"{BASE}/kev.json",
           "--node-index", f"{BASE}/node/index.json"] + (["--dry-run"] if dry else []) + list(extra)
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


def load_module(script):
    import importlib.util
    spec = importlib.util.spec_from_file_location("watch_under_test", script)
    mod = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(mod)
    return mod


def unit_checks(script, check):
    w = load_module(script)
    act = {"name": "actions/checkout", "ecosystem": "GitHub Actions"}

    def affects(version, *ranges, eco="GitHub Actions", rtype="SEMVER"):
        comp = dict(act, version=version, ecosystem=eco)
        rec = {"affected": [{"package": {"name": comp["name"], "ecosystem": eco},
                             "ranges": [{"type": rtype, "events": list(r)} for r in ranges]}]}
        return w.osv_affects(rec, comp)

    I = lambda v: {"introduced": v}
    F = lambda v: {"fixed": v}
    L = lambda v: {"limit": v}
    LA = lambda v: {"last_affected": v}
    check("range: ordered two-interval range, version in the second interval", affects("5.0.0", [I("0"), F("4.0.0"), I("5.0.0"), F("6.0.0")]) is True)
    check("range: the same range with events received UNSORTED is evaluated after sorting",
          affects("5.0.0", [I("0"), I("5.0.0"), F("4.0.0"), F("6.0.0")]) is True
          and affects("4.5.0", [F("6.0.0"), I("5.0.0"), F("4.0.0"), I("0")]) is False)
    check("range: below ANY limit is eligible (two limits); at/above every limit is not",
          affects("3.0.0", [I("0"), L("2.0.0"), L("4.0.0")]) is True and affects("4.0.0", [I("0"), L("2.0.0"), L("4.0.0")]) is False)
    check("range: limit '*' is infinity", affects("9.9.9", [I("1.0.0"), L("*")]) is True)
    check("range: last_affected is inclusive", affects("2.0.0", [I("0"), LA("2.0.0")]) is True and affects("2.0.1", [I("0"), LA("2.0.0")]) is False)
    check("range: malformed / ambiguous / non-local ecosystem -> unknown, never 'not affected'",
          affects("1.0.0", [I("0"), {"fixed": "2.0.0", "introduced": "1.0.0"}]) is None
          and affects("1.0.0", [I("1.0.0"), F("1.0.0")]) is None
          and affects("1.0.0", [F("2.0.0")]) is None
          and affects("1.0.0", [I("0"), F("not-a-version")]) is None
          and affects("1.0.0", [I("0"), F("2.0.0")], eco="PyPI") is None
          and affects("1.0.0", [I("0"), F("2.0.0")], rtype="GIT") is None)

    def feed(payload):
        w.http = lambda *a, **kw: (200, payload, {})
    cases = [
        ("advisories: a record without a GHSA id", [{}], lambda: w.repo_advisories({"name": "acme/repo", "version": "1.3.0"}, "u", "")),
        ("advisories: a record without a vulnerabilities list", [{"ghsa_id": "GHSA-aaaa-bbbb-cccc"}], lambda: w.repo_advisories({"name": "acme/repo", "version": "1.3.0"}, "u", "")),
        ("Node: an LTS row without the security field", [{"version": "v24.0.0", "lts": "Krypton"}], lambda: w.node_security_releases("u")),
        ("Node: truncated index (no security release on a supported LTS line)", [{"version": "v24.0.0", "lts": "Krypton", "security": False}], lambda: w.node_security_releases("u")),
        ("KEV: a malformed catalogue row", {"vulnerabilities": [{"cveID": "CVE-2000-0001"}, {}]}, lambda: w.kev_set("u")),
        ("OSV: a present vulns field that is not a list", {"results": [{"vulns": {}}]},
         lambda: w.osv_query([dict(act, id="a", version="5.0.0", watch="osv-package")], "u")),
        ("OSV: a non-string next_page_token", {"results": [{"vulns": [], "next_page_token": 7}]},
         lambda: w.osv_query([dict(act, id="a", version="5.0.0", watch="osv-package")], "u")),
        ("advisories: a valid out-of-range row mixed with a malformed one",
         [{"ghsa_id": "GHSA-aaaa-bbbb-cccc", "vulnerabilities": [{"vulnerable_version_range": "< 1.2.0"}, 42]}],
         lambda: w.repo_advisories({"name": "acme/repo", "version": "1.3.0"}, "u", "")),
        ("advisories: a vulnerability range that is not a string",
         [{"ghsa_id": "GHSA-aaaa-bbbb-cccc", "vulnerabilities": [{"vulnerable_version_range": 5}]}],
         lambda: w.repo_advisories({"name": "acme/repo", "version": "1.3.0"}, "u", "")),
    ]
    for label, payload, call in cases:
        feed(payload)
        try:
            call()
            ok = False
        except w.FeedError:
            ok = True
        check(f"malformed success is a feed failure: {label}", ok)
    feed([])
    try:
        ok = w.repo_advisories({"name": "acme/repo", "version": "1.3.0"}, "u", "") == []
    except w.FeedError:
        ok = False
    check("advisories: a genuinely empty list stays a healthy empty result", ok)
    feed({"results": [{}]})
    try:
        ok = w.osv_query([dict(act, id="a", version="5.0.0", watch="osv-package")], "u") == {}
    except w.FeedError:
        ok = False
    check("OSV: an omitted vulns field stays a healthy 'no advisories'", ok)


def scenarios(script):
    """Returns a list of (label, ok, detail)."""
    res = []

    def check(label, ok, detail=""):
        res.append((label, bool(ok), detail))

    unit_checks(script, check)

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

    # heartbeat + node issue on the first run
    hb = issues("heartbeat")
    check("fresh: one heartbeat issue with the run time and every feed ok",
          len(hb) == 1 and re.search(r"^last-run: \d{4}-\d\d-\d\dT", hb[0]["body"], re.M)
          and "- OSV: ok" in hb[0]["body"] and "- CISA KEV: ok" in hb[0]["body"] and "FAILED" not in hb[0]["body"],
          hb[0]["body"] if hb else "none")
    node = issues("node")
    check("fresh: Node issue lists the newest security release of LTS lines >= 20 only",
          len(node) == 1 and "Node 24: v24.9.1" in node[0]["body"] and "Node 22: v22.20.0" in node[0]["body"]
          and "v25" not in node[0]["body"] and "Node 18" not in node[0]["body"], node[0]["body"] if node else "none")

    # 2. rerun, nothing changed -> zero writes besides the heartbeat body
    W.writes.clear(); W.heartbeat_writes = 0
    rc, out = run_watch(script)
    check("rerun: unchanged world makes no GitHub writes", rc == 0 and not W.writes, W.writes)
    check("rerun: the heartbeat body is rewritten exactly once, with no comment",
          W.heartbeat_writes == 1 and not W.comments.get(hb[0]["number"]))
    # a missed day: previous heartbeat older than 36 h -> one gap comment
    hb[0]["body"] = re.sub(r"^last-run: .*$", "last-run: 2020-01-01T00:00:00Z", hb[0]["body"], flags=re.M)
    run_watch(script)
    check("heartbeat: a gap of more than 36 h since the previous run gets one comment",
          len(W.comments.get(hb[0]["number"], [])) == 1 and "Gap" in W.comments[hb[0]["number"]][0])
    run_watch(script)
    check("heartbeat: no repeated gap comment on the next on-time run", len(W.comments.get(hb[0]["number"], [])) == 1)

    # Node: a new security release is news (body + one comment); feed down -> failure, issue untouched
    W.node.insert(0, {"version": "v24.10.1", "lts": "Krypton", "security": True})
    W.writes.clear()
    run_watch(script)
    check("node: a new security release updates the issue once with one comment",
          "Node 24: v24.10.1" in node[0]["body"] and len(W.comments.get(node[0]["number"], [])) == 1, W.writes)
    W.node.insert(0, {"version": "v24.10.2", "lts": "Krypton", "security": False})
    W.writes.clear()
    run_watch(script)
    check("node: a non-security release is not news", not W.writes, W.writes)

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
    hb = issues("heartbeat")
    check("osv down: the heartbeat still records the run, with OSV FAILED", hb and "- OSV: FAILED" in hb[0]["body"])
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
    saved_kev, W.kev = W.kev, []
    rc, out = run_watch(script)
    check("empty KEV catalogue: a failure, not 'nothing exploited'", rc == 1 and "empty catalogue" in health[0]["body"], out[-400:])
    W.kev = saved_kev
    W.fail = {"node"}
    node_body = issues("node")[0]["body"]
    rc, out = run_watch(script)
    check("node feed down: exit 1, health names it, Node issue untouched",
          rc == 1 and "Node releases" in health[0]["body"] and issues("node")[0]["body"] == node_body)
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
    check("dry run: plans actions, sends no writes", rc == 0 and not W.writes and not W.issues and "[dry-run] POST" in out, out[-400:])

    # 7b. reachability triage deadlines
    reset(); base_world()
    run_watch(script)
    old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
    high = next(i for i in issues("finding") if "GHSA-aaaa-bbbb-cccc" in i["body"])        # HIGH
    moderate = next(i for i in issues("finding") if "OSV-1" in i["body"])                  # MODERATE
    high["created_at"] = moderate["created_at"] = old
    W.writes.clear()
    run_watch(script)
    lab = lambda it: [l["name"] for l in it["labels"]]
    check("triage: HIGH finding unlabelled after 8 days -> triage-overdue + one comment; MODERATE not yet (30 days)",
          "triage-overdue" in lab(high) and len(W.comments.get(high["number"], [])) == 1
          and "triage-overdue" not in lab(moderate) and not W.comments.get(moderate["number"]), (lab(high), lab(moderate)))
    W.writes.clear()
    run_watch(script)
    check("triage: no repeated overdue comment", not W.writes and len(W.comments.get(high["number"], [])) == 1, W.writes)
    high["labels"].append({"name": "not-reachable"})
    run_watch(script)
    check("triage: once the owner labels reachability the overdue label is removed (no comment)",
          "triage-overdue" not in lab(high) and "not-reachable" in lab(high) and len(W.comments.get(high["number"], [])) == 1, lab(high))

    # 8. owner labels are kept on update
    reset(); base_world()
    run_watch(script)
    tgt = next(i for i in issues("finding") if "OSV-1" in i["body"])
    tgt["labels"].append({"name": "triaged"})
    W.kev = ["CVE-2026-1111"]
    run_watch(script)
    check("update keeps labels the owner added", any(l["name"] == "triaged" for l in tgt["labels"]))

    # 8b. a failed KEV feed must not erase established exploitation; recovery is not "worse"
    reset(); base_world()
    W.kev = ["CVE-2026-1111"]
    run_watch(script)
    osv1 = next(i for i in issues("finding") if "OSV-1" in i["body"])
    before_body, before_labels = osv1["body"], [l["name"] for l in osv1["labels"]]
    W.fail = {"kev"}
    W.writes.clear()
    rc, out = run_watch(script)
    check("kev down: existing findings untouched (KEV label and statement kept, no comment)",
          rc == 1 and osv1["body"] == before_body and [l["name"] for l in osv1["labels"]] == before_labels
          and not W.comments.get(osv1["number"]), W.writes)
    osv1["state"] = "closed"
    W.fail = set()
    W.writes.clear()
    rc, out = run_watch(script)
    check("kev recovered, nothing changed: the closed finding is NOT reopened, no finding write",
          rc == 0 and osv1["state"] == "closed" and not [x for x in W.writes if x[1].endswith(f"/issues/{osv1['number']}")], W.writes)

    # 8c. a partial OSV pass (one record of an alias group fails) never shrinks a group
    reset(); base_world()
    run_watch(script)
    ghsa = next(i for i in issues("finding") if "GHSA-aaaa-bbbb-cccc" in i["body"])
    body = ghsa["body"]
    W.fail_ids = {"OSV-2"}
    rc, out = run_watch(script)
    check("partial OSV: exit 1, the merged finding keeps both components", rc == 1 and ghsa["body"] == body
          and "npm:b" in ghsa["body"], out[-400:])
    W.fail_ids = set()

    # 8d. a malformed but HTTP-200 advisory feed is a failure, not "no advisories"
    reset(); base_world()
    run_watch(script)
    mail = next(i for i in issues("finding") if "GHSA-mail-0002-bbbb" in i["body"])
    W.adv_override = [{}]
    rc, out = run_watch(script)
    hb = issues("heartbeat")
    check("malformed advisory feed: exit 1, health open, finding not marked unmatched, heartbeat says FAILED",
          rc == 1 and issues("health") and issues("health")[0]["state"] == "open" and "No longer matched" not in mail["body"]
          and "GitHub advisories mailco/mail-cli: FAILED" in hb[0]["body"], out[-400:])
    W.adv_override = None

    # 8e. an affected pin bumped to another affected version updates the issue body
    reset(); base_world()
    tmp = tempfile.mkdtemp(prefix="secwatch-inv-")
    inv = os.path.join(tmp, "inv.json")
    data = copy.deepcopy(INVENTORY)
    with open(inv, "w") as f:
        json.dump(data, f)
    run_watch(script, inventory=inv)
    act = next(i for i in issues("finding") if "GHSA-act1-in00-rnge" in i["body"])
    next(c for c in data["components"] if c["id"] == "action:dl")["version"] = "4.1.1"
    with open(inv, "w") as f:
        json.dump(data, f)
    run_watch(script, inventory=inv)
    check("pin bumped but still affected: the finding shows the new version", "4.1.1" in act["body"] and "4.1.0" not in act["body"])

    # 8f. malformed NESTED HTTP-200 content after a known finding and an outage: no false recovery
    for label, setup in [("OSV result with vulns: {}", lambda: setattr(W, "osv_override", {"vulns": {}})),
                         ("advisory with a malformed vulnerability row",
                          lambda: setattr(W, "adv_override", [{"ghsa_id": "GHSA-mail-0002-bbbb", "cve_id": None, "summary": "x",
                                                               "severity": "critical",
                                                               "vulnerabilities": [{"vulnerable_version_range": "< 1.0.0"}, 42]}]))]:
        reset(); base_world()
        run_watch(script)
        W.fail = {"osv", "adv"}
        run_watch(script)
        W.fail = set()
        setup()
        rc, out = run_watch(script)
        hb = issues("heartbeat")
        check(f"malformed nested feed ({label}): exit 1, health stays open, nothing marked unmatched, heartbeat FAILED",
              rc == 1 and issues("health")[0]["state"] == "open"
              and not any("No longer matched" in i["body"] for i in issues("finding")) and "FAILED" in hb[0]["body"], out[-400:])
        W.osv_override = W.adv_override = None

    # 8g. triage waits for a complete run like every other finding change
    reset(); base_world()
    run_watch(script)
    high = next(i for i in issues("finding") if "GHSA-aaaa-bbbb-cccc" in i["body"])
    high["created_at"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
    W.fail = {"kev"}
    run_watch(script)
    check("triage: no overdue label or comment during an incomplete run",
          "triage-overdue" not in [l["name"] for l in high["labels"]] and not W.comments.get(high["number"]))
    W.fail = set()
    run_watch(script)
    check("triage: applied on the next complete run", "triage-overdue" in [l["name"] for l in high["labels"]])

    # 9. the real inventory loads and runs against an empty feed
    reset()
    rc, out = run_watch(script, inventory=REAL_INVENTORY)
    check("real inventory: runs clean against an empty feed (gaps, Node and heartbeat issues only)",
          rc == 0 and len(W.issues) == 3 and issues("gaps") and issues("node") and issues("heartbeat")
          and "runtime:node" in issues("gaps")[0]["body"], out[-600:])

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
    ("unmatched marked after an incomplete run", "    reconcile(issues, docs, complete, failures, feeds=", "    reconcile(issues, docs, True, failures, feeds="),
    ("osv-package ranges not evaluated", "                    if verdict is False:\n                        continue", "                    if False:\n                        continue"),
    ("osv-package queried by version", 'if c["watch"] == "osv":\n                    q["version"]', 'if True:\n                    q["version"]'),
    ("issue list pagination ignored", "            url = next_link(hdrs)\n        out.sort", "            url = None\n        out.sort"),
    ("no heartbeat", "    if feeds is not None:\n        beats", "    if False:\n        beats"),
    ("heartbeat gap never reported", "if prev is not None and (now - prev).total_seconds() > HEARTBEAT_GAP_HOURS * 3600:", "if False:"),
    ("empty KEV accepted", "    if not out:\n        raise FeedError(\"CISA KEV", "    if False:\n        raise FeedError(\"CISA KEV"),
    ("Node security flag ignored", 'rel["security"] is not True', "False"),
    ("Node feed failure ignored", 'failures.append(f"Node releases: {e}")', "pass"),
    ("triage never overdue", "return labels + [OVERDUE] if (now - created).total_seconds() > days * 86400 else None", "return None"),
    ("triage overdue on day one", "days = TRIAGE_DAYS_URGENT if urgent else TRIAGE_DAYS", "days = 0"),
    ("events not sorted", "    for b, kind in sorted(ordered):", "    for b, kind in ordered:"),
    ("limits ignored", "    if limits and not any(l is None or v < l for l in limits):", "    if False:"),
    ("limits require ALL", "not any(l is None or v < l for l in limits)", "not all(l is None or v < l for l in limits)"),
    ("ties evaluated", "    if len(set(keys)) != len(keys):\n        return None", "    if False:\n        return None"),
    ("any ecosystem evaluated as SemVer", 'or component["ecosystem"] not in LOCAL_RANGE_ECOSYSTEMS ', ''),
    ("KEV failure updates existing findings", "        kev = set()  # NEW findings are still posted (KEV unknown); existing ones are left as they are\n        complete = False", "        kev = set()"),
    ("incomplete runs still update findings", '        if doc["kind"] == "finding" and not complete:\n            continue', '        if False:\n            continue'),
    ("partial OSV results used", "        raw += osv_raw   # only a complete OSV pass", "        pass   # only a complete OSV pass"),
    ("malformed advisory skipped", "raise FeedError(f\"advisories of {component['name']}: malformed advisory record\")", "continue"),
    ("Node rows without security accepted", 'not isinstance(rel.get("security"), bool)', "False"),
    ("component versions not fingerprinted", '[[c, by_id[c].get("version")] for c in comps]', "comps"),
    ("OSV vulns type not checked", "if not isinstance(vulns, list) or (token is not None and not isinstance(token, str)):", "if False:"),
    ("malformed vulnerability rows skipped", "            if not all(isinstance(v, dict) and isinstance(v.get(\"vulnerable_version_range\"), (str, type(None)))", "            if False and all(isinstance(v, dict) and isinstance(v.get(\"vulnerable_version_range\"), (str, type(None)))"),
    ("triage during incomplete runs", '        if not complete or it["kind"] != "finding" or it["state"] != "open":', '        if it["kind"] != "finding" or it["state"] != "open":'),
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
              ("live: the real Node release index parsed (LTS security releases found)", "[dry-run] POST /issues: create node node-security" in out),
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
