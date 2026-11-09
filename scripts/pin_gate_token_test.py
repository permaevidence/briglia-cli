#!/usr/bin/env python3
"""The release pin gate's GitHub advisory lookups are authenticated.

v0.2.68 burned (signed run 42515577358): the sign job's pin gate called
GET /repos/agentmail-to/agentmail-cli/security-advisories anonymously (the
step bound only BRIGLIA_PIN_GATE_ISSUES_TOKEN; scripts/pin_gate.py reads the
advisory token from GITHUB_TOKEN), shared the runner IP's 60/h anonymous
limit and got HTTP 403 after the phone approval. Both pin gate invocations in
.github/workflows/release-signed.yml must now give the gate process this
run's own token (`${{ github.token }}`, workflow permissions contents: read).

Checks (no network, no GitHub calls):
  * static: the workflow has exactly the two expected invocations (authorize:
    --mode precheck, sign: --mode signed); no step binds GITHUB_TOKEN to a
    secret; the sign step's issues token is unchanged;
  * execution: each invocation's own shell command (backslash continuations
    joined) runs under bash with ONLY the env GitHub would give that step
    (workflow + job + step env, `${{ … }}` replaced by sentinels) and a
    `python3` shim on PATH that records GITHUB_TOKEN; the gate must see the
    github.token sentinel, never empty and never a secret;
  * code path: pin_gate.py feeds GITHUB_TOKEN to the advisory lookup, and
    security_watch.repo_advisories sends `Authorization: Bearer <token>`
    (local fake API on 127.0.0.1) — and none when the token is empty, which
    is exactly what the workflow must never let happen.
Deliberate breaks (in-memory workflow copies): the sign step's GITHUB_TOKEN
line removed, the authorize env line removed, the authorize command prefix
removed, GITHUB_TOKEN bound to a secret, bound to an empty string, the
prefix reading a misspelled variable — each must be rejected.

Also (0.2.70, Codex note on 0.2.69): the Authorize job's release-history
download (`.github/scripts/release_security.py fetch-history`) lists
releases through the GitHub API; anonymous, it shares the same 60/h runner
limit and a refusal there burns the tag before signing. Its one command must
see this run's github.token too (never a secret, never empty), the script
must send it to the API listing only (never to the asset download), and the
same kind of deliberate breaks must be rejected.
Exit 0 = all checks passed.
"""
import http.server
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release-signed.yml")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
GH_SENTINEL = "sentinel-github-token"
EXPECTED = {"authorize": "precheck", "sign": "signed"}

PASSED = 0
FAILED = 0


def check(label, ok, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print(f"  ✓ {label}")
    else:
        FAILED += 1
        print(f"  ✖ {label}")
        if detail:
            print("    " + str(detail).replace("\n", "\n    ")[:2000])


def jobs_of(text):
    body = text.split("\njobs:\n", 1)[1] if "\njobs:\n" in text else ""
    out = {}
    for chunk in re.split(r"\n(?=  [A-Za-z0-9_-]+:\n)", "\n" + body):
        m = re.match(r"\n?  ([A-Za-z0-9_-]+):\n", chunk)
        if m:
            out[m.group(1)] = chunk
    return out


def split_job(job_text):
    if "\n    steps:\n" not in job_text:
        return job_text, []
    head, steps = job_text.split("\n    steps:\n", 1)
    parts = re.split(r"\n(?=      - )", "\n" + steps)
    return head, [p.strip("\n") for p in parts if p.strip()]


def env_block(text, indent):
    """`env:` mapping at the given indentation (comments ignored)."""
    pad = " " * indent
    m = re.search(rf"(?:^|\n){pad}env:\n((?:{pad}  .*\n?)+)", text + "\n")
    env = {}
    if not m:
        return env
    for line in m.group(1).splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        k, _, v = s.partition(":")
        env[k.strip()] = v.strip()
    return env


def resolve(value):
    v = value.strip()
    if v.startswith(("'", '"')) and v.endswith(v[0]) and len(v) >= 2:
        v = v[1:-1]
    m = re.fullmatch(r"\$\{\{\s*(.+?)\s*\}\}", v)
    if not m:
        return v
    expr = m.group(1)
    if expr == "github.token":
        return GH_SENTINEL
    if expr.startswith("secrets."):
        return "sentinel-secret-" + expr[len("secrets."):]
    return "sentinel-ctx-" + re.sub(r"[^A-Za-z0-9]", "-", expr)


def step_script(step):
    m = re.search(r"\n        run: \|\n((?:(?:          .*)?\n?)+)", step + "\n")
    if not m:
        return None
    return "\n".join(l[10:] if l.startswith("          ") else l.strip() for l in m.group(1).splitlines())


def gate_commands(script, needle="scripts/pin_gate.py"):
    """Each logical shell line (continuations joined) that runs `needle`."""
    logical, cur = [], ""
    for line in script.splitlines():
        if line.rstrip().endswith("\\"):
            cur += line.rstrip()[:-1] + " "
            continue
        logical.append(cur + line)
        cur = ""
    if cur:
        logical.append(cur)
    return [l.strip() for l in logical if needle in l and not l.strip().startswith("#")]


def invocations(text, needle="scripts/pin_gate.py"):
    """[(job id, step text, merged env, command)] for every call of `needle`."""
    out = []
    wf_env = env_block(text.split("\njobs:\n", 1)[0], 0)
    for job_id, job in jobs_of(text).items():
        head, steps = split_job(job)
        job_env = env_block(head, 4)
        for step in steps:
            script = step_script(step)
            if not script or needle not in script:
                continue
            env = {}
            for src in (wf_env, job_env, env_block(step, 8)):
                env.update({k: resolve(v) for k, v in src.items()})
            for cmd in gate_commands(script, needle):
                out.append((job_id, step, env, cmd))
    return out


def run_with_shim(cmd, env):
    """Run one gate command with a python3 shim; return what GITHUB_TOKEN it saw."""
    with tempfile.TemporaryDirectory() as tmp:
        record = os.path.join(tmp, "seen")
        shim = os.path.join(tmp, "python3")
        with open(shim, "w") as f:
            f.write('#!/bin/sh\nprintf "%s" "${GITHUB_TOKEN-<unset>}" > "$PIN_GATE_TOKEN_TEST_RECORD"\n')
        os.chmod(shim, stat.S_IRWXU)
        full = {"PATH": tmp + ":/usr/bin:/bin", "HOME": tmp, "GITHUB_SHA": "0" * 40,
                "GITHUB_STEP_SUMMARY": os.path.join(tmp, "summary"), "PIN_GATE_TOKEN_TEST_RECORD": record}
        full.update(env)
        r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-c", "set -o pipefail\n" + cmd],
                           capture_output=True, text=True, env=full, cwd=tmp, timeout=30)
        if not os.path.exists(record):
            return None, f"gate shim never ran (rc={r.returncode}): {r.stdout}{r.stderr}"
        return open(record).read(), ""


def token_errors(text):
    errs = []
    inv = invocations(text)
    found = {}
    for job_id, step, env, cmd in inv:
        m = re.search(r"--mode\s+(\S+)", cmd)
        found.setdefault(job_id, []).append(m.group(1) if m else "?")
    if found != {k: [v] for k, v in EXPECTED.items()}:
        errs.append(f"expected exactly one gate call per job {EXPECTED}, found {found}")
    for job_id, step, env, cmd in inv:
        raw = env_block(step, 8)
        if "secrets." in raw.get("GITHUB_TOKEN", ""):
            errs.append(f"{job_id}: GITHUB_TOKEN must be this run's github.token, not a secret")
        seen, why = run_with_shim(cmd, env)
        if seen is None:
            errs.append(f"{job_id}: {why}")
        elif seen != GH_SENTINEL:
            errs.append(f"{job_id}: the gate process saw GITHUB_TOKEN={seen!r}, expected the github.token "
                        f"(anonymous advisory lookups hit the runner-IP rate limit)")
        if job_id == "sign" and raw.get("BRIGLIA_PIN_GATE_ISSUES_TOKEN") != "${{ secrets.BRIGLIA_PIN_GATE_ISSUES_TOKEN }}":
            errs.append("sign: the C2 issues token binding changed")
        if job_id == "sign" and "--issues-token-env BRIGLIA_PIN_GATE_ISSUES_TOKEN" not in cmd:
            errs.append("sign: C2 must keep reading BRIGLIA_PIN_GATE_ISSUES_TOKEN, not GITHUB_TOKEN")
    return errs


HISTORY_NEEDLE = ".github/scripts/release_security.py fetch-history"


def history_errors(text):
    """The Authorize job's release-history download sees this run's token."""
    errs = []
    inv = invocations(text, HISTORY_NEEDLE)
    jobs = [job_id for job_id, _, _, _ in inv]
    if jobs != ["authorize"]:
        errs.append(f"expected exactly one release-history download, in authorize; found {jobs}")
    for job_id, step, env, cmd in inv:
        raw = env_block(step, 8)
        for k, v in raw.items():
            if "secrets." in v and k in ("GITHUB_TOKEN", "RELEASE_HISTORY_GITHUB_TOKEN"):
                errs.append(f"{job_id}: {k} must be this run's github.token, not a secret")
        seen, why = run_with_shim(cmd, env)
        if seen is None:
            errs.append(f"{job_id}: {why}")
        elif seen != GH_SENTINEL:
            errs.append(f"{job_id}: fetch-history saw GITHUB_TOKEN={seen!r}, expected the github.token "
                        f"(an anonymous release listing hits the runner-IP rate limit before signing)")
    return errs


class HistoryAPI(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        HistoryAPI.seen.append((self.path.split("?")[0], self.headers.get("Authorization")))
        port = self.server.server_address[1]
        if self.path.startswith("/repos/") and "page=1" in self.path:
            body = json.dumps([{"tag_name": "v9.9.9", "draft": False, "prerelease": False,
                                "assets": [{"name": "manifest.sig.json",
                                            "browser_download_url": f"http://127.0.0.1:{port}/asset/manifest.sig.json"}]}]).encode()
        elif self.path.startswith("/repos/"):
            body = b"[]"
        else:
            body = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def history_code_path_checks():
    sys.path.insert(0, os.path.join(ROOT, ".github", "scripts"))
    import release_security as rs
    srv = http.server.HTTPServer(("127.0.0.1", 0), HistoryAPI)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    old = os.environ.get("GITHUB_TOKEN")
    try:
        api = f"http://127.0.0.1:{srv.server_address[1]}"
        with tempfile.TemporaryDirectory() as tmp:
            refuse = os.path.join(tmp, "verify.sh")
            with open(refuse, "w") as f:
                f.write("#!/bin/sh\nexit 1\n")
            os.chmod(refuse, stat.S_IRWXU)
            for token, expect in (("tok-history", "Bearer tok-history"), ("", None)):
                HistoryAPI.seen = []
                os.environ["GITHUB_TOKEN"] = token
                try:
                    rs.fetch_history("o/r", "unused.pem", "cli", tmp, api, refuse)
                except Exception:
                    pass   # the fake release does not verify: refused after the download
                listing = [a for p, a in HistoryAPI.seen if p.startswith("/repos/")]
                assets = [a for p, a in HistoryAPI.seen if p.startswith("/asset/")]
                if token:
                    check("fetch-history sends Authorization: Bearer <GITHUB_TOKEN> to the API listing",
                          listing == [expect], HistoryAPI.seen)
                    check("fetch-history never sends the token to the asset download", assets == [None], HistoryAPI.seen)
                else:
                    check("fetch-history is anonymous with an empty GITHUB_TOKEN (why the workflow must bind it)",
                          listing == [None], HistoryAPI.seen)
    finally:
        if old is None:
            os.environ.pop("GITHUB_TOKEN", None)
        else:
            os.environ["GITHUB_TOKEN"] = old
        srv.shutdown()


class FakeAPI(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        FakeAPI.seen.append(self.headers.get("Authorization"))
        body = b"[]"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def code_path_checks():
    gate = open(os.path.join(ROOT, "scripts", "pin_gate.py"), encoding="utf-8").read()
    check("pin_gate.py: the advisory token is GITHUB_TOKEN, handed to repo_advisories",
          'args.token = os.environ.get("GITHUB_TOKEN", "")' in gate
          and "watch.repo_advisories(c, args.github_api, args.token)" in gate)
    import security_watch as watch
    srv = http.server.HTTPServer(("127.0.0.1", 0), FakeAPI)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        api = f"http://127.0.0.1:{srv.server_address[1]}"
        comp = {"name": "example/tool", "version": "1.0.0"}
        FakeAPI.seen = []
        watch.repo_advisories(comp, api, "tok-123")
        check("repo_advisories sends Authorization: Bearer <token> when given one", FakeAPI.seen == ["Bearer tok-123"], FakeAPI.seen)
        FakeAPI.seen = []
        watch.repo_advisories(comp, api, "")
        check("repo_advisories is anonymous with an empty token (why the workflow must bind it)", FakeAPI.seen == [None], FakeAPI.seen)
    finally:
        srv.shutdown()


def main():
    text = open(WORKFLOW, encoding="utf-8").read()
    print("— release-signed.yml: pin gate advisory lookups authenticated —")
    errs = token_errors(text)
    check("both gate calls (authorize precheck, sign signed) see this run's github.token; C2 token unchanged",
          not errs, "\n".join(errs))
    code_path_checks()
    if errs:
        print("  (deliberate breaks skipped: the real workflow is not valid)")
        print(f"\n{FAILED} FAILED, {PASSED} passed")
        return 1

    sign_line = "          GITHUB_TOKEN: ${{ github.token }}\n"
    auth_line = "          PIN_GATE_GITHUB_TOKEN: ${{ github.token }}\n"
    prefix = 'GITHUB_TOKEN="$PIN_GATE_GITHUB_TOKEN" python3 scripts/pin_gate.py --mode precheck'
    for needle in (sign_line, auth_line, prefix):
        if text.count(needle) != 1:
            check(f"break anchor present exactly once: {needle.strip()!r}", False)
    breaks = [
        ("sign step GITHUB_TOKEN removed", text.replace(sign_line, "", 1)),
        ("sign step GITHUB_TOKEN bound to a secret",
         text.replace(sign_line, "          GITHUB_TOKEN: ${{ secrets.BRIGLIA_PIN_GATE_ISSUES_TOKEN }}\n", 1)),
        ("sign step GITHUB_TOKEN empty", text.replace(sign_line, "          GITHUB_TOKEN: ''\n", 1)),
        ("sign step issues token removed", text.replace(
            "          BRIGLIA_PIN_GATE_ISSUES_TOKEN: ${{ secrets.BRIGLIA_PIN_GATE_ISSUES_TOKEN }}\n", "", 1)),
        ("authorize env line removed", text.replace(auth_line, "", 1)),
        ("authorize command prefix removed", text.replace(prefix, "python3 scripts/pin_gate.py --mode precheck", 1)),
        ("authorize prefix reads a misspelled variable",
         text.replace(prefix, prefix.replace("$PIN_GATE_GITHUB_TOKEN", "$PIN_GATE_GH_TOKEN"), 1)),
        ("authorize token bound to a secret",
         text.replace(auth_line, "          PIN_GATE_GITHUB_TOKEN: ${{ secrets.SOMETHING }}\n", 1)),
    ]
    caught = 0
    for label, mutated in breaks:
        if mutated == text:
            check(f"break applies: {label}", False)
            continue
        if token_errors(mutated):
            caught += 1
        else:
            check(f"break caught: {label}", False)
    check(f"deliberate breaks caught: {caught}/{len(breaks)}", caught == len(breaks))

    print("— release-signed.yml: release-history download authenticated —")
    herrs = history_errors(text)
    check("the authorize release-history download sees this run's github.token", not herrs, "\n".join(herrs))
    history_code_path_checks()
    if herrs:
        print("  (history deliberate breaks skipped: the real workflow is not valid)")
        print(f"\n{FAILED} FAILED, {PASSED} passed")
        return 1
    h_line = "          RELEASE_HISTORY_GITHUB_TOKEN: ${{ github.token }}\n"
    h_prefix = 'GITHUB_TOKEN="$RELEASE_HISTORY_GITHUB_TOKEN" python3 .github/scripts/release_security.py fetch-history'
    for needle in (h_line, h_prefix):
        if text.count(needle) != 1:
            check(f"break anchor present exactly once: {needle.strip()!r}", False)
    hbreaks = [
        ("history env line removed", text.replace(h_line, "", 1)),
        ("history command prefix removed", text.replace(h_prefix, "python3 .github/scripts/release_security.py fetch-history", 1)),
        ("history prefix reads a misspelled variable",
         text.replace(h_prefix, h_prefix.replace("$RELEASE_HISTORY_GITHUB_TOKEN", "$RELEASE_HISTORY_GH_TOKEN"), 1)),
        ("history token bound to a secret",
         text.replace(h_line, "          RELEASE_HISTORY_GITHUB_TOKEN: ${{ secrets.SOMETHING }}\n", 1)),
        ("history token empty", text.replace(h_line, "          RELEASE_HISTORY_GITHUB_TOKEN: ''\n", 1)),
        ("history prefix clears the token", text.replace(h_prefix, 'GITHUB_TOKEN="" python3 .github/scripts/release_security.py fetch-history', 1)),
        ("history download moved out of authorize (duplicated into a second command)",
         text.replace(h_prefix, "python3 .github/scripts/release_security.py fetch-history --dry\n          " + h_prefix, 1)),
    ]
    hcaught = 0
    for label, mutated in hbreaks:
        if mutated == text:
            check(f"break applies: {label}", False)
            continue
        if history_errors(mutated):
            hcaught += 1
        else:
            check(f"break caught: {label}", False)
    check(f"history deliberate breaks caught: {hcaught}/{len(hbreaks)}", hcaught == len(hbreaks))
    print(f"\n{FAILED} FAILED, {PASSED} passed")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
