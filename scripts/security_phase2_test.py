#!/usr/bin/env python3
"""Security plan v8 Phase 2 (signed security metadata + update-available
notice) end to end, hermetic:

  1. `briglia __update-notice-selftest` (state machine, store, classifier);
  2. scripts/release_security_test.py (release tooling);
  3. a signed fake release channel (local HTTP, test key via the dev-only
     BRIGLIA_RELEASE_TEST_KEY) driving the real binary's notice path:
     one notice, no repeat, security wording, an invalid security block
     giving plain wording + attention, `upgradecheck off` making ZERO
     requests, and the anti-rollback trust file byte-identical throughout;
  4. one-attempt Telegram sends against a fake Bot API that counts wire
     requests (accepted, 429, 5xx with ok:false, accept-then-drop, refused
     connection);
  5. old-client compatibility of a manifest carrying the new fields:
     verify-envelope.sh, get-briglia.sh's manifest check, and — when
     --old-binary names a v0.2.59 build — its update check.

Every step runs with temporary HOME/XDG roots; nothing outside them is
read or written. Usage: security_phase2_test.py <briglia> [--old-binary <v0.2.59 dev build>]
"""
import argparse
import base64
import http.server
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEED = "11" * 32
passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"✔ {label}")
    else:
        failed += 1
        print(f"✖ {label}" + (f" — {detail[-600:]}" if detail else ""))


class Channel:
    """Serves one signed envelope at /manifest.sig.json; counts requests."""

    def __init__(self):
        self.envelope = b""
        self.hits = 0
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                outer.hits += 1
                self.send_response(200)
                self.send_header("Content-Length", str(len(outer.envelope)))
                self.end_headers()
                self.wfile.write(outer.envelope)

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_port}/manifest.sig.json"


def manifest(seq, security=None):
    v = f"0.3.{seq}"
    m = {"schema": 1, "channel": "briglia-cli", "sequence": seq, "version": v,
         "published": "2026-10-01T00:00:00Z", "expires": "2030-01-01T00:00:00Z",
         "platforms": {p: {"url": f"https://example.invalid/download/v{v}/briglia-{p}.tar.gz", "sha256": "a" * 64, "size": 10}
                       for p in ("macos-arm64", "linux-x64", "linux-arm64")}}
    if security is not None:
        m["security"] = security
    return m


def sign(binary, env, tmp, m):
    src, out = Path(tmp) / "m.json", Path(tmp) / "m.sig.json"
    src.write_text(json.dumps(m, sort_keys=True))
    res = subprocess.run([binary, "__test-sign-envelope", str(src), str(out), "--seed-hex", SEED],
                         env=env, capture_output=True, text=True)
    key = dict(line.split("=", 1) for line in res.stdout.splitlines() if "=" in line)
    return out.read_bytes(), key


def scratch_env(tmp):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "SM_"))}
    for d in ("home", "config", "data", "state", "tmp"):
        (Path(tmp) / d).mkdir(parents=True, exist_ok=True)
    env.update(HOME=f"{tmp}/home", XDG_CONFIG_HOME=f"{tmp}/config", XDG_DATA_HOME=f"{tmp}/data",
               XDG_STATE_HOME=f"{tmp}/state", TMPDIR=f"{tmp}/tmp")
    return env


def run(binary, args, env, timeout=120):
    res = subprocess.run([binary] + args, env=env, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    return res.returncode, res.stdout + res.stderr


def selftests(binary):
    with tempfile.TemporaryDirectory() as tmp:
        rc, out = run(binary, ["__update-notice-selftest"], scratch_env(tmp), timeout=600)
        m = re.search(r"ALL (\d+) UPDATE NOTICE CHECKS PASSED", out)
        check(f"update-notice selftest ({m.group(1) if m else '?'} checks)", rc == 0 and m is not None, out)
    res = subprocess.run([sys.executable, str(ROOT / "scripts/release_security_test.py")], capture_output=True, text=True)
    m = re.search(r"ALL (\d+) RELEASE SECURITY CHECKS PASSED", res.stdout)
    check(f"release tooling tests ({m.group(1) if m else '?'} checks)", res.returncode == 0 and m is not None, res.stdout + res.stderr)


def notice_e2e(binary):
    with tempfile.TemporaryDirectory() as tmp:
        env = scratch_env(tmp)
        ch = Channel()
        ch.envelope, key = sign(binary, env, tmp, manifest(121))
        trust = Path(tmp) / "trust.json"
        trust.write_text('{"domains":{"elsewhere":7},"schema":2}')
        before = trust.read_bytes()
        env.update(BRIGLIA_ENVELOPE_URL=ch.url, BRIGLIA_RELEASE_TEST_KEY=f"{key['keyId']}:{key['publicKeyHex']}",
                   BRIGLIA_RELEASE_URL_PREFIX="https://example.invalid/download/v{version}/", BRIGLIA_RELEASE_TRUST_FILE=str(trust))
        t0 = int(time.time())
        rc, out = run(binary, ["__update-check-once", "--now", str(t0)], env)
        check("e2e: a signed newer release → exactly one notice", out.count("NOTICE[") == 1 and "Briglia 0.3.121 is available." in out, out)
        notice = Path(tmp) / "data/briglia/update/notice.json"
        check("e2e: state written to ~/.local/share/briglia/update/notice.json (mode 0600)",
              notice.exists() and (notice.stat().st_mode & 0o777) == 0o600)
        rc, out = run(binary, ["__update-check-once", "--now", str(t0 + 7 * 3600)], env)
        check("e2e: next check (same release) → no notice", "NOTICE[" not in out and "FETCHES: 1" in out, out)
        ch.envelope, _ = sign(binary, env, tmp, manifest(122, {"cumulative": [
            {"id": "CVE-2026-4242", "aliases": [], "level": "recommended", "affectsFromSequence": 100, "fixedInSequence": 122}],
            "securityFloor": {"recommended": 0, "critical": 0}, "summary": "Fixes a TLS problem"}))
        rc, out = run(binary, ["__update-check-once", "--now", str(t0 + 14 * 3600)], env)
        check("e2e: a release with a security fix for this version → immediate security notice with the summary",
              "includes security fixes for your version" in out and "Fixes a TLS problem" in out, out)
        ch.envelope, _ = sign(binary, env, tmp, manifest(130, {"cumulative": [{"id": "CVE-2026-1", "level": "urgent",
                                                                               "affectsFromSequence": 1, "fixedInSequence": 2}],
                                                                "securityFloor": {"recommended": 0, "critical": 0}}))
        rc, out = run(binary, ["__update-check-once", "--now", str(t0 + 30 * 86400)], env)
        check("e2e: invalid security block → plain notice + attention, never a claim",
              "Briglia 0.3.130 is available." in out and "includes security" not in out.split("STATUS")[0]
              and "security information of Briglia 0.3.130 could not be read" in out, out)
        check("e2e: the anti-rollback trust file is byte-identical after every notice check", trust.read_bytes() == before)
        rc, out = run(binary, ["upgradecheck", "off"], env)
        hits = ch.hits
        rc2, out2 = run(binary, ["__update-check-once", "--now", str(t0 + 60 * 86400)], env)
        check("e2e: `briglia upgradecheck off` → no request at all, nothing sent",
              rc == 0 and ch.hits == hits and "FETCHES: 0" in out2 and "NOTICE[" not in out2 and "update checks: off" in out2, out + out2)
        rc, out = run(binary, ["upgradecheck"], env)
        check("e2e: `briglia upgradecheck` shows the setting and the scope disclosure",
              "update checks: off" in out and "never installs anything by itself" in out, out)
        ch.srv.shutdown()


class FakeBotAPI:
    """mode: ok | 429 | 502 | drop (read the request, close without reply)."""

    def __init__(self, mode):
        self.mode, self.requests = mode, 0
        probe = socket.socket(); probe.bind(("127.0.0.1", 0)); self.dead_port = probe.getsockname()[1]; probe.close()
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            data = b""
            conn.settimeout(5)
            try:
                while b"\r\n\r\n" not in data:
                    data += conn.recv(65536)
                head, body = data.split(b"\r\n\r\n", 1)
                length = int(re.search(rb"(?i)content-length:\s*(\d+)", head).group(1))
                while len(body) < length:
                    body += conn.recv(65536)
                if b"POST" in head[:8]:
                    self.requests += 1
                replies = {"ok": (200, b'{"ok":true,"result":{"message_id":1}}'),
                           "429": (429, b'{"ok":false,"error_code":429,"parameters":{"retry_after":17}}'),
                           "502": (502, b'{"ok":false,"description":"Bad Gateway"}'),
                           "307": (307, b''), "308": (308, b''), "307-dead": (307, b'')}
                if self.mode != "drop":
                    status, payload = replies[self.mode]
                    location = ""
                    if self.mode in ("307", "308"):
                        location = f"Location: http://127.0.0.1:{self.port}/second\r\n"
                    elif self.mode == "307-dead":
                        location = f"Location: http://127.0.0.1:{self.dead_port}/second\r\n"
                    conn.sendall(f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n{location}Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode() + payload)
            except Exception:
                pass
            finally:
                conn.close()


def telegram_e2e(binary):
    with tempfile.TemporaryDirectory() as tmp:
        env = scratch_env(tmp)
        for mode, expect in (("ok", "accepted"), ("429", "refused(retryAfterSeconds: Optional(17)"),
                             ("502", "ambiguous"), ("drop", "ambiguous"),
                             ("307", "ambiguous"), ("308", "ambiguous"), ("307-dead", "ambiguous")):
            api = FakeBotAPI(mode)
            env["BRIGLIA_TELEGRAM_API_BASE"] = f"http://127.0.0.1:{api.port}/bot"
            rc, out = run(binary, ["__update-notice-send-once"], env, timeout=60)
            time.sleep(0.2)
            label = {"307": "307 redirect (refused, never followed)", "308": "308 redirect (refused, never followed)",
                     "307-dead": "redirect to a dead port (no second hop, so no false 'nothing sent')"}.get(mode, mode)
            check(f"telegram wire: {label} → {expect.split('(')[0]}, exactly one wire request",
                  expect in out and api.requests == 1, f"{out} requests={api.requests}")
            api.sock.close()
        s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
        env["BRIGLIA_TELEGRAM_API_BASE"] = f"http://127.0.0.1:{port}/bot"
        rc, out = run(binary, ["__update-notice-send-once"], env, timeout=60)
        check("telegram wire: connection refused (nothing written) → refused (retryable)", "refused(" in out, out)


def parity(binary):
    """Round-1 R2: whatever release_security.py authorizes and emits, the
    client parses as known (no unknown block, no unknown component)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("release_security", ROOT / ".github/scripts/release_security.py")
    rs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rs)
    hist = [{"schema": 1, "channel": "briglia-cli", "sequence": 136, "version": "0.3.136"}]
    base = dict(schema=1, forSequence=137, cumulative=[], securityFloor={"recommended": 0, "critical": 0},
                aliasLookup="skipped: parity fixture")
    cve = dict(id="CVE-2026-1000", aliases=["GHSA-aaaa-bbbb-cccc"], level="critical", affectsFromSequence=101, fixedInSequence=137)
    comps = [
        dict(ecosystem="deb", identity={"distro": "ubuntu", "release": "noble", "arch": "arm64", "sourcePackage": "ffmpeg"},
             minimumSafe="7:6.1.1-3ubuntu5.2", advisories=["USN-7000-1"], level="recommended"),
        dict(ecosystem="brew", identity={"tap": "homebrew/core", "formula": "ffmpeg", "versionScheme": 0},
             minimumSafe="7.1.1_2", advisories=["CVE-2026-1001"], level="recommended"),
        dict(ecosystem="npm", identity={"package": "playwright-core"}, minimumSafe="1.55.1", advisories=["GHSA-zzzz-yyyy-xxxx"], level="critical"),
        dict(ecosystem="pypi", identity={"distribution": "weasyprint"}, minimumSafe="66.0", advisories=["PYSEC-2026-1"], level="recommended"),
        dict(ecosystem="binary", identity={"vendor": "nodejs", "product": "node", "platform": "aarch64-apple-darwin"},
             minimumSafe="22.20.0", advisories=["CVE-2026-1002"], level="recommended"),
    ]
    intro = [dict(id="CVE-2026-1000", level="critical", component="playwright-core")]
    e = dict(id="CVE-2026-1000", aliases=[], level="recommended", affectsFromSequence=101, fixedInSequence=137)
    many = [dict(id=f"CVE-2026-{2000 + i}", aliases=[f"GHSA-{i:04d}-xxxx-yyyy"], level="recommended",
                 affectsFromSequence=101, fixedInSequence=137) for i in range(64)]
    candidates = {
        "full block (critical CVE+GHSA, floors, summary, introduces, all five component ecosystems)":
            dict(base, cumulative=[cve], introduces=intro, securityFloor={"recommended": 120, "critical": 110},
                 summary="Fixes a browser sandbox escape", componentAdvisories=comps),
        "64 cumulative entries, 16-ID identity": dict(base, cumulative=many[:63] + [dict(many[63], aliases=[f"GHSA-{i:04d}-aaaa-bbbb" for i in range(15)])]),
        "R2 introduces merging to 19 IDs": dict(base, cumulative=[e], introduces=[
            dict(id="CVE-2026-1000", level="recommended", aliases=[f"ADV-{p}{i}" for i in range(9)]) for p in ("A", "B")]),
        "R2 65 raw aliases": dict(base, cumulative=[dict(e, aliases=["CVE-2026-1000"] * 65)]),
        "R2 component identity value not a string": dict(base, componentAdvisories=[dict(comps[2], identity={"package": 123})]),
        "R2 component minimumSafe of 129 bytes": dict(base, componentAdvisories=[dict(comps[2], minimumSafe="1" * 129)]),
        "R2 summary: null": dict(base, cumulative=[e], summary=None),
        "R2 introduces component: null": dict(base, cumulative=[e], introduces=[dict(id="CVE-2026-1000", level="recommended", component=None)]),
        "R2 componentAdvisories: null": dict(base, cumulative=[e], componentAdvisories=None),
        "single entry, no optional fields (positive control)": dict(base, cumulative=[e]),
    }
    with tempfile.TemporaryDirectory() as tmp:
        env = scratch_env(tmp)
        allowed = 0
        for label, c in candidates.items():
            reasons = rs.authorize(c, 137, hist, alias_lookup=lambda ids, base: set())
            if reasons:
                check(f"parity: {label} → refused by the tooling", label.startswith("R2"), "; ".join(reasons))
                continue
            allowed += 1
            payload = dict(manifest(137), **rs.emit(c))
            path = Path(tmp) / "payload.json"
            path.write_text(json.dumps(payload))
            rc, out = run(binary, ["__release-security-parse", str(path)], env)
            try:
                got = json.loads(out.strip().splitlines()[-1])
            except Exception:
                got = {}
            check(f"parity: {label} → authorized AND parsed as known by the client",
                  not label.startswith("R2") and got.get("security") == "known" and got.get("componentsUnknown") == 0
                  and got.get("componentsInvalid") is False, out)
        check("parity: the valid candidates were authorized", allowed == 3)
        fuzz_parity(binary, rs, hist, candidates["full block (critical CVE+GHSA, floors, summary, introduces, all five component ecosystems)"], env, tmp)


def fuzz_parity(binary, rs, hist, valid, env, tmp, rounds=400, seed=20261023):
    """Deterministic structural fuzz of the parity contract: replace, delete
    or add one value anywhere in a valid candidate; whenever the tooling
    still authorizes it, the client must parse the emitted metadata as known."""
    import copy
    import random
    rnd = random.Random(seed)
    values = [None, True, False, 0, -1, 2 ** 53, 2 ** 63, 1.5, "", "x" * 600, "CVE-2026-9999", [], {}, ["CVE-2026-9999"],
              {"k": 1}, "critical", "recommended", "1.0", "\u0007"]

    def paths(node, prefix=()):
        out = [prefix]
        if isinstance(node, dict):
            for k, v in node.items():
                out += paths(v, prefix + (k,))
        elif isinstance(node, list):
            for i, v in enumerate(node):
                out += paths(v, prefix + (i,))
        return out

    allowed = mismatches = 0
    first = ""
    skip = {("schema",), ("forSequence",), ("aliasLookup",)}
    candidates_paths = [p for p in paths(valid) if p and p not in skip]
    for n in range(rounds):
        c = copy.deepcopy(valid)
        path = rnd.choice(candidates_paths)
        parent = c
        for key in path[:-1]:
            parent = parent[key]
        last = path[-1]
        op = rnd.random()
        if op < 0.15 and isinstance(parent, dict):
            del parent[last]
        elif op < 0.25 and isinstance(parent, dict):
            parent["unexpected"] = rnd.choice(values)
        else:
            parent[last] = copy.deepcopy(rnd.choice(values))
        try:
            if rs.authorize(c, 137, hist, alias_lookup=lambda ids, base: set()):
                continue
        except Exception as ex:   # the tooling must refuse, never crash
            mismatches += 1
            first = first or f"authorize crashed on {path}: {ex!r}"
            continue
        allowed += 1
        payload = dict(manifest(137), **rs.emit(c))
        path_file = Path(tmp) / f"fuzz-{n}.json"
        path_file.write_text(json.dumps(payload))
        rc, out = run(binary, ["__release-security-parse", str(path_file)], env)
        path_file.unlink()
        try:
            got = json.loads(out.strip().splitlines()[-1])
        except Exception:
            got = {}
        if not (got.get("security") == "known" and got.get("componentsUnknown") == 0 and got.get("componentsInvalid") is False):
            mismatches += 1
            first = first or f"{path} → {json.dumps(c)[:300]} → {out.strip()[:200]}"
    check(f"parity fuzz: {rounds} single mutations, {allowed} still authorized — every one parsed as known by the client",
          mismatches == 0 and allowed > 0, first)


def compat(binary, old_binary):
    with tempfile.TemporaryDirectory() as tmp:
        env = scratch_env(tmp)
        sec = {"introduces": [{"id": "CVE-2026-4242", "level": "critical", "component": "playwright-core"}],
               "cumulative": [{"id": "CVE-2026-4242", "aliases": ["GHSA-abcd-efgh-ijkl"], "level": "critical",
                               "affectsFromSequence": 100, "fixedInSequence": 125}],
               "securityFloor": {"recommended": 110, "critical": 100}, "summary": "Fixes a browser sandbox escape"}
        m = manifest(125, sec)
        m["componentAdvisories"] = [{"ecosystem": "deb", "identity": {"distro": "ubuntu", "release": "noble", "arch": "arm64",
                                                                   "sourcePackage": "ffmpeg"},
                                     "minimumSafe": "7:6.1.1-3ubuntu5.2", "advisories": ["USN-7000-1"], "level": "recommended"}]
        envelope, key = sign(binary, env, tmp, m)
        env_path = Path(tmp) / "manifest.sig.json"
        env_path.write_bytes(envelope)
        der = bytes.fromhex("302a300506032b6570032100" + key["publicKeyHex"])
        (Path(tmp) / "pub.der").write_bytes(der)
        ossl = subprocess.run(["bash", "-c", f". {ROOT}/.github/scripts/openssl-resolve.sh && resolve_openssl && echo $OPENSSL"],
                              capture_output=True, text=True).stdout.strip().splitlines()
        if ossl:
            subprocess.run([ossl[-1], "pkey", "-pubin", "-inform", "DER", "-in", str(Path(tmp) / "pub.der"), "-out", str(Path(tmp) / "pub.pem")],
                           capture_output=True)
            res = subprocess.run(["bash", str(ROOT / ".github/scripts/verify-envelope.sh"), str(env_path), str(Path(tmp) / "pub.pem"),
                                  "briglia-cli", str(Path(tmp) / "payload")], capture_output=True, text=True)
            check("compat: verify-envelope.sh accepts a manifest carrying security + componentAdvisories",
                  res.returncode == 0 and "VERIFIED" in res.stdout, res.stdout + res.stderr)
        else:
            check("compat: openssl with Ed25519 available for verify-envelope.sh", False)
        script = (ROOT / "scripts/get-briglia.sh").read_text()
        body = re.search(r"cat > \"\$TMP/manifest_check.py\" <<'PYEOF'\n(.*?)\nPYEOF", script, re.S).group(1)
        (Path(tmp) / "manifest_check.py").write_text(body)
        (Path(tmp) / "payload").write_text(json.dumps(m))
        res = subprocess.run([sys.executable, str(Path(tmp) / "manifest_check.py"), tmp, "linux-x64", "https://example.invalid"],
                             capture_output=True, text=True)
        check("compat: get-briglia.sh's manifest check accepts the new fields",
              res.returncode == 0 and res.stdout.splitlines()[0] == "0.3.125", res.stdout + res.stderr)
        if old_binary:
            ch = Channel()
            ch.envelope = envelope
            env.update(BRIGLIA_ENVELOPE_URL=ch.url, BRIGLIA_RELEASE_TEST_KEY=f"{key['keyId']}:{key['publicKeyHex']}",
                       BRIGLIA_RELEASE_URL_PREFIX="https://example.invalid/download/v{version}/",
                       BRIGLIA_RELEASE_TRUST_FILE=str(Path(tmp) / "old-trust.json"))
            rc, out = run(old_binary, ["upgrade"], env)
            check("compat: a real v0.2.59 build's update check accepts the manifest (Update available, then cancelled)",
                  ("Update available" in out or "upgrading replaces it with the prebuilt release" in out)
                  and "0.3.125" in out and "Cancelled" in out, out)
            ch.srv.shutdown()
        else:
            print("· compat: no --old-binary given — the v0.2.59 client check was not run here")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--old-binary")
    args = ap.parse_args()
    binary = str(Path(args.binary).resolve())
    selftests(binary)
    notice_e2e(binary)
    telegram_e2e(binary)
    parity(binary)
    compat(binary, args.old_binary)
    print(f"\n{'ALL' if failed == 0 else 'FAILED:'} {passed if failed == 0 else failed} SECURITY PHASE 2 CHECKS {'PASSED' if failed == 0 else f'of {passed + failed}'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
