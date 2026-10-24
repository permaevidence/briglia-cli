#!/usr/bin/env python3
"""Security plan v16 Phase 3 core (§9.5: known-vulnerability check of the
user's own tools), end to end and hermetic:

  1. `briglia __local-tools-selftest` (verification, matching, F3 trimming,
     inventory on fake machines, send-once rules, delivery, service);
  2. scripts/advisory_publish_test.py (publisher rules + deliberate breaks);
  3. publisher → client parity: every payload the publisher validates
     parses in the client (synthetic bundles plus a structural fuzz);
  4. signing parity: an envelope from the Swift test signer verifies with
     .github/scripts/verify-advisory.sh, and one from sign-advisory.sh
     verifies in the client (skipped without an Ed25519-capable openssl);
  5. a signed fake advisory channel driving the real binary: one message,
     no repeat, one identical GET with no query and no package names,
     `upgradecheck off` making ZERO requests;
  6. the native Debian ordering against `dpkg --compare-versions` when dpkg
     exists (Linux CI);
  7. static: every development-only command refuses in stamped builds; the
     compiled advisory key set is still the marked placeholder.

Every step runs with temporary HOME/XDG roots. Usage: security_phase3_test.py <briglia>
"""
import http.server
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import advisory_publish as pub          # noqa: E402
import advisory_publish_test as fx      # noqa: E402

SEED = "22" * 32
passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"✔ {label}")
    else:
        failed += 1
        print(f"✖ {label}" + (f" — {str(detail)[-600:]}" if detail else ""))


def scratch_env(tmp):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "SM_"))}
    env.update(HOME=f"{tmp}/home", XDG_CONFIG_HOME=f"{tmp}/config", XDG_DATA_HOME=f"{tmp}/data",
               XDG_STATE_HOME=f"{tmp}/state", TMPDIR=f"{tmp}/tmp")
    for d in ("home", "config", "data", "state", "tmp"):
        os.makedirs(f"{tmp}/{d}", exist_ok=True)
    return env


def run(cmd, env=None, timeout=300, stdin=None):
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout, input=stdin)
    return p.returncode, p.stdout + p.stderr


def selftests(binary):
    with tempfile.TemporaryDirectory() as tmp:
        rc, out = run([binary, "__local-tools-selftest"], env=scratch_env(tmp), timeout=600)
        tail = [l for l in out.splitlines() if "LOCAL TOOLS CHECKS" in l or "FAILED" in l]
        check("selftest: __local-tools-selftest", rc == 0 and any("PASSED" in l for l in tail), out)
        print("    " + (tail[-1] if tail else "?"))
    rc, out = run([sys.executable, str(ROOT / "scripts/advisory_publish_test.py")])
    check("publisher: rules and deliberate breaks", rc == 0, out)
    print("    " + out.strip().splitlines()[-1])
    # v17-v20 (§9.5.10, §9.5.11): Node and LibreOffice sources, publish job.
    for script, label in (("advisory_node_test.py", "Node.js vendor advisories"),
                          ("advisory_libreoffice_test.py", "LibreOffice CNA adapter + platform disposition"),
                          ("advisory_publish_job_test.py", "separate publish job (fake contents API)")):
        rc, out = run([sys.executable, str(ROOT / "scripts" / script)])
        check(f"publisher: {label}", rc == 0, out)
        print("    " + (out.strip().splitlines() or ["?"])[-1])


def vendor_parity(binary):
    """The real watchlist built from the frozen 2026-10-24 Node and
    LibreOffice feeds (deb rows absent → failed) parses in the client and fits."""
    import advisory_node as an
    import advisory_libreoffice as al
    fixn, fixl = ROOT / "scripts/fixtures/node-advisories", ROOT / "scripts/fixtures/libreoffice-advisories"
    with tempfile.TemporaryDirectory() as tmp:
        env = scratch_env(tmp)
        recs = json.load(open(fixl / "records.json"))
        page = (fixl / "page.html").read_bytes()

        def get(url, limit):
            if "libreoffice.org" in url:
                return page
            cve = url.rsplit("/", 1)[1][:-5]
            if cve not in recs:
                import urllib.error
                raise urllib.error.HTTPError(url, 404, "nf", None, None)
            return json.dumps(recs[cve]).encode()
        sources = al.fetch_all("2026-10-24T00:00:00Z", get=get)
        sources.update({"nodejs-security-wg": {"status": "ok", "checkedAt": "2026-10-24T00:00:00Z", "data": an._shape_wg(json.load(open(fixn / "core-index.json")))},
                        "nodejs-dist": {"status": "ok", "checkedAt": "2026-10-24T00:00:00Z", "data": an._shape_dist(json.load(open(fixn / "dist-index.json")))},
                        "nodejs-schedule": {"status": "ok", "checkedAt": "2026-10-24T00:00:00Z", "data": an._shape_schedule(json.load(open(fixn / "schedule.json")))},
                        "cisa-kev": {"status": "ok", "checkedAt": "2026-10-24T00:00:00Z", "cves": {"CVE-2099-0001": "2026-01-01"}}})
        bundle = {"schema": 1, "fetchedAt": "2026-10-24T00:00:00Z", "sources": sources, "results": []}
        data = pub.build(str(ROOT / "security/local-tools.json"), bundle, None, fx.NOW)
        p = f"{tmp}/real.json"
        open(p, "wb").write(data)
        r = parse_payload(binary, env, p)
        doc = json.loads(data)
        cov = {(c["identity"], c["source"]): c["status"] for c in doc["coverage"]}
        vendor_ok = all(cov[(i, s)] == "ok" for i in ("vendor:nodejs.org:node:darwin:official", "vendor:nodejs.org:node:linux:official")
                        for s in ("nodejs-security-wg", "nodejs-dist", "nodejs-schedule", "cisa-kev"))
        lo_ok = all(cov[("vendor:documentfoundation:libreoffice:darwin:official", s)] == "ok" for s in ("tdf-advisories", "cve-cna", "cisa-kev"))
        check("vendor parity: the real watchlist from the frozen Node/LibreOffice feeds parses in the client",
              r.get("ok") is True and len(r.get("identities", [])) == 59, r)
        check("vendor parity: vendor coverage ok, deb coverage failed (no deb rows), size within 256 KiB",
              vendor_ok and lo_ok and all(v == "failed" for (i, src), v in cov.items() if i.startswith("deb:") and src.startswith("osv:")) and len(data) <= 262144,
              (len(data), [k for k, v in cov.items() if not k[0].startswith("deb:") and v != "ok"]))


def parse_payload(binary, env, path):
    rc, out = run([binary, "__advisory-list-parse", "--payload", path], env=env)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"ok": False, "reason": out}


def parity(binary):
    with tempfile.TemporaryDirectory() as tmp:
        env = scratch_env(tmp)
        w = fx.watchlist(tmp, identities=(("debian", "12", "ffmpeg"), ("debian", "12", "curl")))
        bundles = [
            fx.bundle([fx.row([fx.rec(1), fx.rec(2, fixed=None)]), fx.row([fx.rec(3)], ident=("debian", "12", "curl"))]),
            fx.bundle([fx.row([fx.rec(i) for i in range(80)])], kev={"CVE-2099-0004": "2026-01-01"}),
            fx.bundle([fx.row([], status="failed")], kev_ok=False),
        ]
        for i, b in enumerate(bundles):
            p = f"{tmp}/p{i}.json"
            open(p, "wb").write(pub.build(w, b, None, fx.NOW))
            r = parse_payload(binary, env, p)
            check(f"parity: publisher payload {i} parses in the client", r.get("ok") is True, r)
        # Structural fuzz: whenever the publisher's check still accepts a
        # mutated payload, the client must parse it too.
        base = json.loads(pub.build(w, bundles[0], None, fx.NOW))
        rnd = random.Random(20261024)
        accepted = mismatches = 0
        for n in range(150):
            d = json.loads(json.dumps(base))
            mutate(d, rnd)
            data = json.dumps(d).encode()
            try:
                pub.check_payload(data)
            except Exception:
                continue
            accepted += 1
            p = f"{tmp}/f.json"
            open(p, "wb").write(data)
            if parse_payload(binary, env, p).get("ok") is not True:
                mismatches += 1
        check(f"parity fuzz: every payload the publisher accepts parses in the client ({accepted} accepted of 150)",
              mismatches == 0 and accepted > 10, f"{mismatches} mismatches")
        # N1: boundary cases decided identically by the signing gate and the
        # client (both accept or both reject).
        cases = boundary_cases(base)
        disagree = []
        for label, d in cases:
            data = json.dumps(d, ensure_ascii=False).encode()
            try:
                pub.check_payload(data)
                gate = True
            except Exception:
                gate = False
            p = f"{tmp}/b.json"
            open(p, "wb").write(data)
            client = parse_payload(binary, env, p).get("ok") is True
            if gate != client:
                disagree.append((label, gate, client))
        check(f"parity boundaries: signing gate and client agree on {len(cases)} byte/type/control cases", not disagree, disagree)


def boundary_cases(base):
    def with_(path_fn, value, label):
        d = json.loads(json.dumps(base))
        path_fn(d, value)
        return label, d

    def rtype(d, v):
        d["entries"][0]["advisories"][0]["affected"]["ranges"][0]["type"] = v

    def ev(d, v):
        d["entries"][0]["advisories"][0]["affected"]["ranges"][0]["events"][0] = {"introduced": v}

    def kevadded(d, v):
        d["entries"][0]["advisories"][0]["kevAdded"] = v

    def ident(d, v):
        d["coverage"][0]["identity"] = v

    def idv(d, v):
        d["entries"][0]["advisories"][0]["ids"][0] = v

    def kev(d, v):
        d["entries"][0]["advisories"][0]["kev"] = v

    def seq(d, v):
        d["sequence"] = v

    out = [
        with_(rtype, "é" * 16, "range type 32 UTF-8 bytes"),
        with_(rtype, "é" * 17, "range type 34 UTF-8 bytes (Codex N1)"),
        with_(rtype, "é" * 20, "range type 40 UTF-8 bytes"),
        with_(ev, "1" * 512, "event version 512 bytes"),
        with_(ev, "1" * 513, "event version 513 bytes"),
        with_(ev, "é" * 256, "event version 512 UTF-8 bytes"),
        with_(ev, "é" * 257, "event version 514 UTF-8 bytes"),
        with_(ev, "1.0\n", "event version with a newline"),
        with_(ev, "1.0\u200b", "event version with a format character"),
        with_(ev, "", "empty event version"),
        with_(kevadded, "2026-01-01\t", "kevAdded with a tab"),
        with_(ident, "x" * 513, "coverage identity 513 bytes"),
        with_(idv, "CVE-2099-0001\n", "ID with a trailing newline"),
        with_(idv, "C", "ID too short"),
        with_(kev, 1, "kev as an integer"),
        with_(seq, True, "sequence as a bool"),
        with_(seq, 2 ** 53, "sequence 2^53"),
        with_(seq, 2 ** 53 - 1, "sequence 2^53 - 1"),
    ]
    return out


def mutate(d, rnd):
    e = d["entries"][rnd.randrange(len(d["entries"]))]
    choice = rnd.randrange(8)
    if choice == 0 and e["advisories"]:
        e["advisories"][0]["severity"] = rnd.choice(["recommended", "critical"])
    elif choice == 1 and e["advisories"]:
        e["advisories"][0]["remediation"] = None
        e["advisories"][0]["noFixReason"] = rnd.choice(["no-dsa", "postponed", "unknown"])
    elif choice == 2:
        d["coverage"][rnd.randrange(len(d["coverage"]))]["status"] = rnd.choice(["ok", "failed", "partial", "not-covered"])
    elif choice == 3 and e["advisories"]:
        e["advisories"][0]["affected"] = "unknown"
    elif choice == 4 and e["advisories"]:
        e["advisories"][0]["kev"] = True
        e["advisories"][0]["kevAdded"] = "2026-01-01"
    elif choice == 5:
        e["advisories"] = e["advisories"][: rnd.randrange(len(e["advisories"]) + 1)]
    elif choice == 6 and e["advisories"]:
        e["advisories"][0]["withdrawn"] = True
    else:
        d["sequence"] = rnd.randrange(0, 2 ** 40)


def openssl():
    for c in ("/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", shutil.which("openssl") or ""):
        if c and os.path.exists(c):
            rc, _ = run([c, "genpkey", "-algorithm", "ed25519", "-out", os.devnull])
            if rc == 0:
                return c
    return None


def signing(binary):
    ossl = openssl()
    if not ossl:
        print("· signing parity skipped: no Ed25519-capable openssl")
        return
    with tempfile.TemporaryDirectory() as tmp:
        env = scratch_env(tmp)
        w = fx.watchlist(tmp)
        payload = f"{tmp}/payload.json"
        open(payload, "wb").write(pub.build(w, fx.bundle([fx.row([fx.rec(1)])]), None, fx.NOW))
        rc, out = run([binary, "__test-sign-advisory", payload, f"{tmp}/swift.sig.json", "--seed-hex", SEED], env=env)
        pubhex = re.search(r"publicKeyHex=([0-9a-f]{64})", out).group(1)
        der = bytes.fromhex("302a300506032b6570032100" + pubhex)
        open(f"{tmp}/swift.der", "wb").write(der)
        run([ossl, "pkey", "-pubin", "-inform", "DER", "-in", f"{tmp}/swift.der", "-out", f"{tmp}/swift.pub.pem"])
        venv = dict(env, OPENSSL_BIN=ossl)
        rc, out = run(["bash", str(ROOT / ".github/scripts/verify-advisory.sh"), f"{tmp}/swift.sig.json", f"{tmp}/swift.pub.pem"], env=venv)
        check("signing parity: Swift test signer → verify-advisory.sh", rc == 0 and "VERIFIED" in out, out)
        run([ossl, "genpkey", "-algorithm", "ed25519", "-out", f"{tmp}/k.pem"])
        run([ossl, "pkey", "-in", f"{tmp}/k.pem", "-pubout", "-out", f"{tmp}/k.pub.pem"])
        senv = dict(venv, EXPECTED_PUBKEY_PEM=f"{tmp}/k.pub.pem")
        rc, out = run(["bash", str(ROOT / ".github/scripts/sign-advisory.sh"), f"{tmp}/k.pem", payload, f"{tmp}/sh.sig.json"], env=senv)
        check("signing: sign-advisory.sh signs a validated payload", rc == 0, out)
        rc2, out2 = run(["bash", str(ROOT / ".github/scripts/sign-advisory.sh"), f"{tmp}/k.pem", payload, f"{tmp}/x.json"],
                        env=dict(venv, EXPECTED_PUBKEY_PEM=f"{tmp}/missing.pem"))
        check("signing: refuses while the key is not provisioned", rc2 == 3 and "not provisioned" in out2, out2)
        run([ossl, "genpkey", "-algorithm", "ed25519", "-out", f"{tmp}/other.pem"])
        rc3, out3 = run(["bash", str(ROOT / ".github/scripts/sign-advisory.sh"), f"{tmp}/other.pem", payload, f"{tmp}/y.json"], env=senv)
        check("signing: refuses a private key that is not the committed one", rc3 != 0 and "DIFFERENT" in out3, out3)
        bad = json.loads(open(payload).read())
        bad["coverage"].append(dict(bad["coverage"][0]))
        open(f"{tmp}/dup.json", "w").write(json.dumps(bad))
        rc4, out4 = run(["bash", str(ROOT / ".github/scripts/sign-advisory.sh"), f"{tmp}/k.pem", f"{tmp}/dup.json", f"{tmp}/z.json"], env=senv)
        check("signing: refuses a payload with a duplicate (identity, source) pair", rc4 != 0, out4)
        raw = subprocess.run([ossl, "pkey", "-pubin", "-in", f"{tmp}/k.pub.pem", "-outform", "DER"], capture_output=True).stdout[-32:]
        keyid = json.load(open(f"{tmp}/sh.sig.json"))["keyId"]
        cenv = dict(env, BRIGLIA_ADVISORY_TEST_KEY=f"{keyid}:{raw.hex()}")
        rc5, out5 = run([binary, "__advisory-list-parse", f"{tmp}/sh.sig.json", "--now", str(int(fx.NOW))], env=cenv)
        check("signing parity: sign-advisory.sh envelope verifies in the client", '"ok":true' in out5, out5)


class Channel:
    def __init__(self):
        self.body = b""
        self.requests = []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                outer.requests.append((self.path, sorted((k.lower(), v) for k, v in self.headers.items() if k.lower() != "host")))
                self.send_response(200)
                self.send_header("Content-Length", str(len(outer.body)))
                self.end_headers()
                self.wfile.write(outer.body)

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_port}/advisories/v1/local-tools.sig.json"


def fixture_inventory(version):
    inst = {"toolId": "ffmpeg",
            "identity": {"kind": "deb", "distro": "debian", "release": "12", "source": "ffmpeg"},
            "installedVersion": version, "compareVersion": version, "binaries": ["ffmpeg", "libavcodec59"],
            "candidates": {"deb": {"list": [{"binary": b, "version": "7:5.1.7-0+deb12u1", "sourceName": "ffmpeg", "sourceVersion": "7:5.1.7-0+deb12u1",
                                             "originOK": True, "pocket": "archive"} for b in ("ffmpeg", "libavcodec59")],
                                   "asOf": fx.NOW + 600}},
            "usedPath": "/usr/bin/ffmpeg"}
    return [{"present": {"_0": inst}}, {"absent": {"toolId": "pandoc"}}]


def e2e(binary):
    with tempfile.TemporaryDirectory() as tmp:
        env = scratch_env(tmp)
        ch = Channel()
        w = fx.watchlist(tmp)
        payload = f"{tmp}/payload.json"
        open(payload, "wb").write(pub.build(w, fx.bundle([fx.row([fx.rec(1)])]), None, fx.NOW))
        rc, out = run([binary, "__test-sign-advisory", payload, f"{tmp}/list.sig.json", "--seed-hex", SEED], env=env)
        keyid = re.search(r"keyId=(\S+)", out).group(1)
        pubhex = re.search(r"publicKeyHex=([0-9a-f]{64})", out).group(1)
        ch.body = open(f"{tmp}/list.sig.json", "rb").read()
        env.update(BRIGLIA_ADVISORY_URL=ch.url, BRIGLIA_ADVISORY_TEST_KEY=f"{keyid}:{pubhex}")
        fixture = f"{tmp}/inv.json"
        json.dump(fixture_inventory("7:5.1.6-0+deb12u1"), open(fixture, "w"))
        now = str(int(fx.NOW) + 600)
        rc, out = run([binary, "__local-tools-check-once", "--fixture", fixture, "--now", now], env=env)
        notices = [l for l in out.splitlines() if l.startswith("NOTICE: ")]
        check("e2e: one message for an affected, fixable tool", rc == 0 and len(notices) == 1
              and "sudo apt-get install --only-upgrade ffmpeg libavcodec59" in notices[0], out)
        check("e2e: exactly one GET", len(ch.requests) == 1, ch.requests)
        rc, out = run([binary, "__local-tools-check-once", "--fixture", fixture, "--now", now], env=env)
        check("e2e: the next pass sends nothing and fetches nothing (once a day)",
              "NOTICE: " not in out and "FETCHES: 0" in out and len(ch.requests) == 1, out)
        later = str(int(fx.NOW) + 25 * 3600)
        rc, out = run([binary, "__local-tools-check-once", "--fixture", fixture, "--now", later], env=env)
        check("e2e: next day one more fetch, still no repeat", "NOTICE: " not in out and len(ch.requests) == 2, out)
        path0, headers0 = ch.requests[0]
        check("privacy: same path every time, no query string, no package name",
              all(p == path0 for p, _ in ch.requests) and "?" not in path0 and "ffmpeg" not in path0
              and not any("ffmpeg" in v for _, h in ch.requests for _, v in h), ch.requests)
        check("privacy: identical request headers on every fetch", all(h == headers0 for _, h in ch.requests), ch.requests)
        state = Path(tmp) / "data/briglia/update"
        lv = state / "localvuln.json"
        obs = state / "advisory-list.json"
        check("e2e: state in ~/.local/share/briglia/update (mode 0600)",
              lv.exists() and obs.exists() and (lv.stat().st_mode & 0o777) == 0o600 and (obs.stat().st_mode & 0o777) == 0o600)
        check("e2e: no notice.json written by the tool check", not (state / "notice.json").exists())
        rc, out = run([binary, "upgradecheck", "off"], env=env)
        days = str(int(fx.NOW) + 60 * 3600)
        json.dump(fixture_inventory("7:5.1.5-0+deb12u1"), open(fixture, "w"))
        before = len(ch.requests)
        rc, out = run([binary, "__local-tools-check-once", "--fixture", fixture, "--now", days], env=env)
        check("e2e: upgradecheck off → zero requests, no message",
              len(ch.requests) == before and "NOTICE: " not in out and "FETCHES: 0" in out, out)
        rc, out = run([binary, "__local-tools-check-once"], env={k: v for k, v in env.items() if k != "XDG_DATA_HOME"})
        check("e2e: the stateful driver refuses without isolated roots", rc == 2, out)
        ch.srv.shutdown()


def dpkg_parity(binary):
    if not shutil.which("dpkg"):
        print("· dpkg ordering cross-check skipped: no dpkg on this machine (runs on Linux CI)")
        return
    pairs = [("1.0", "1.0-1"), ("1.0~rc1", "1.0"), ("1:0.9", "2.0"), ("1.0-1", "1.0-1+b1"), ("1.2.3", "1.2.3-0"),
             ("1.0a", "1.0"), ("1.0.0", "1.0"), ("1.0+dfsg", "1.0"), ("0001", "1"), ("2.30-2", "2.3-9"), ("1.0~~", "1.0~"),
             ("7:5.1.6-0+deb12u1", "7:5.1.6-0+deb12u2"), ("7:6.1.1-3ubuntu5", "7:6.1.1-3ubuntu5+esm1"),
             ("1.2-3-4", "1.2-3-5"), ("1.0.0~beta1+dfsg-2", "1.0.0-1"), ("9.53.3~dfsg-7+deb12u1", "9.53.3~dfsg-7")]
    rnd = random.Random(7)
    parts = ["0", "1", "2", "9", "10", "a", "b", "~", "+", ".", "-", "1:", "~rc", "+b1", "dfsg"]
    for _ in range(200):
        def v():
            s = rnd.choice(["1", "2", "0"]) + "".join(rnd.choice(parts[:10]) for _ in range(rnd.randrange(1, 5)))
            return s + (("-" + rnd.choice(["1", "2", "0ubuntu1", "1+b1"])) if rnd.random() < 0.5 else "")
        pairs.append((v(), v()))
    stdin = "\n".join(f"{a} {b}" for a, b in pairs) + "\n"
    rc, out = run([binary, "__local-tools-version-compare", "--scheme", "deb"], stdin=stdin)
    ours = out.strip().splitlines()
    bad = []
    for (a, b), mine in zip(pairs, ours):
        valid = subprocess.run(["dpkg", "--validate-version", a]).returncode == 0 and subprocess.run(["dpkg", "--validate-version", b]).returncode == 0
        if not valid:
            if mine != "unknown" and mine not in ("-1", "0", "1"):
                bad.append((a, b, mine))
            continue
        lt = subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0
        eq = subprocess.run(["dpkg", "--compare-versions", a, "eq", b]).returncode == 0
        want = "-1" if lt else "0" if eq else "1"
        if mine != want:
            bad.append((a, b, mine, want))
    check(f"dpkg parity: native Debian ordering matches dpkg on {len(pairs)} pairs", not bad and len(ours) == len(pairs), bad[:10])


def static():
    src = (ROOT / "TelegramConcierge/CLI/LocalToolsCommands.swift").read_text()
    cmds = re.findall(r"struct (\w+): (?:Async)?ParsableCommand", src)
    gated = all(f'guard adaCLIVersion.hasSuffix("-dev")' in block
                for block in re.split(r"\nstruct ", src)[1:])
    check(f"static: every development-only driver refuses in stamped builds ({len(cmds)})", gated and len(cmds) == 5, cmds)
    keys = (ROOT / "TelegramConcierge/Services/LocalAdvisoryList.swift").read_text()
    block = keys[keys.index("ADVISORY-KEYS-BEGIN"):keys.index("ADVISORY-KEYS-END")]
    check("static: the compiled advisory key set is the marked placeholder (not provisioned)",
          "placeholderKeyId" in block and re.search(r'"[0-9a-f]{64}"', block) is None)
    check("static: no committed advisory public key yet (publisher stays unarmed)",
          not (ROOT / "security/advisory-signing-pubkey.pem").exists())
    # v18-v20 §9.5.11: the publish job is separate, in its own environment,
    # with only the scoped token; the signing job never sees that token.
    wf = (ROOT / ".github/workflows/advisory-publish.yml").read_text()
    jobs = wf[wf.index("\njobs:"):]
    sign = jobs[jobs.index("  publish-sign:"):jobs.index("\n  publish:")]
    publish = jobs[jobs.index("\n  publish:"):]
    check("static: the publish job is separate, needs the signing job and uses environment advisory-publish",
          "needs: publish-sign" in publish and "environment: advisory-publish" in publish and "environment: advisory-sign" in sign)
    check("static: the publish job holds only the publish token; the signing job only the signing key",
          re.findall(r"secrets\.(\w+)", publish) == ["BRIGLIA_ADVISORY_PUBLISH_TOKEN"]
          and re.findall(r"secrets\.(\w+)", sign) == ["BRIGLIA_ADVISORY_SIGNING_KEY"])
    check("static: publication is armed only by the key AND the exact repository variable",
          "needs.publish-sign.outputs.armed == 'true' && vars.ADVISORY_PUBLISH_REPO == 'permaevidence/briglia-advisories'" in publish)
    check("static: the publish job checks out without persisted credentials", "persist-credentials: false" in publish)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    binary = os.path.abspath(sys.argv[1])
    selftests(binary)
    parity(binary)
    vendor_parity(binary)
    signing(binary)
    e2e(binary)
    dpkg_parity(binary)
    static()
    print(f"\n{'ALL SECURITY PHASE 3 CHECKS PASSED' if failed == 0 else f'{failed} FAILED'} ({passed} passed)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
