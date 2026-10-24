#!/usr/bin/env python3
"""Tests for the separate publish job (.github/scripts/publish-advisory.py,
security plan v18-v20 §9.5.11, §15 item 21) against a fake GitHub contents
API; real Ed25519 signing with a throwaway key (needs an OpenSSL 3 binary,
else skipped). No network. Deliberate breaks must each fail a test.

Usage: advisory_publish_job_test.py
"""
import base64
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, ".github", "scripts", "publish-advisory.py")
sys.path.insert(0, HERE)
import advisory_publish as pub          # noqa: E402
import advisory_publish_test as fx      # noqa: E402
passed = failed = 0
REPO = "permaevidence/briglia-advisories"


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"✔ {label}")
    else:
        failed += 1
        print(f"✖ {label}" + (f" — {str(detail)[:300]}" if detail else ""))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


def openssl():
    for c in (os.environ.get("OPENSSL_BIN"), "/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "openssl"):
        if not c:
            continue
        try:
            r = subprocess.run([c, "genpkey", "-algorithm", "ed25519"], capture_output=True)
            if r.returncode == 0:
                return c
        except OSError:
            continue
    return None


class Resp(io.BytesIO):
    def __init__(self, status, body):
        super().__init__(body)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def blob(content):
    return hashlib.sha1(b"blob %d\0" % len(content) + content).hexdigest()


class FakeGitHub:
    """GET/PUT /repos/<repo>/contents/<path>; records every request. GET with
    the object media type inlines base64 content only up to `inline_max`
    bytes (GitHub: 1 MB), else `encoding: none` + empty content; GET with the
    raw media type returns the bytes. The SHA is the real git blob SHA unless
    a test overrides it."""
    def __init__(self, content=None, sha=None, get_status=None, put_status=None, not_found_body=True,
                 inline_max=1_000_000, raw_status=None, raw_override=None):
        self.content = content
        self.sha = sha if sha is not None else (blob(content) if content is not None else None)
        self.get_status, self.put_status, self.not_found_body = get_status, put_status, not_found_body
        self.inline_max, self.raw_status, self.raw_override = inline_max, raw_status, raw_override
        self.requests = []

    def __call__(self, req, timeout=30):
        accept = req.get_header("Accept")
        self.requests.append((req.get_method(), req.full_url, req.data, accept))
        if req.get_method() == "GET":
            if self.get_status:
                raise urllib.error.HTTPError(req.full_url, self.get_status, "x", {}, io.BytesIO(b"{}"))
            if self.content is None:
                body = json.dumps({"message": "Not Found"} if self.not_found_body else {}).encode()
                raise urllib.error.HTTPError(req.full_url, 404, "nf", {}, io.BytesIO(body))
            if accept == "application/vnd.github.raw+json":
                if self.raw_status:
                    raise urllib.error.HTTPError(req.full_url, self.raw_status, "x", {}, io.BytesIO(b"{}"))
                return Resp(200, self.raw_override if self.raw_override is not None else self.content)
            inline = len(self.content) <= self.inline_max
            return Resp(200, json.dumps({"type": "file", "sha": self.sha, "size": len(self.content),
                                         "encoding": "base64" if inline else "none",
                                         "content": base64.b64encode(self.content).decode() if inline else ""}).encode())
        body = json.loads(req.data)
        if self.put_status:
            raise urllib.error.HTTPError(req.full_url, self.put_status, "x", {}, io.BytesIO(b"{}"))
        if body.get("sha") != (self.sha if self.content is not None else None):
            raise urllib.error.HTTPError(req.full_url, 409, "conflict", {}, io.BytesIO(b"{}"))
        self.content = base64.b64decode(body["content"])
        self.sha = blob(self.content)
        return Resp(201, b"{}")

    def puts(self):
        return [r for r in self.requests if r[0] == "PUT"]


def run_tests(m, env, only=None):
    res = {}

    def t(name, fn):
        if only and name not in only:
            return
        try:
            ok, detail = fn()
        except Exception as e:      # noqa: BLE001
            ok, detail = False, repr(e)
        res[name] = bool(ok)
        if not only:
            check(name, ok, detail)

    def ok_first():
        gh = FakeGitHub(content=None)
        r = m.publish(env["c101"], env["pub"], REPO, "t", opener=gh)
        put = gh.puts()
        return (r.startswith("published sequence") and len(put) == 1 and put[0][1].endswith("/contents/v1/local-tools.sig.json")
                and "sha" not in json.loads(put[0][2])), (r, gh.requests)
    t("publish: first publication only on a positive 404, one PUT of the one path, no sha", ok_first)

    def higher():
        gh = FakeGitHub(content=open(env["c100"], "rb").read())
        r = m.publish(env["c101"], env["pub"], REPO, "t", opener=gh)
        return r.startswith("published") and json.loads(gh.puts()[0][2]).get("sha") == blob(open(env["c100"], "rb").read()), r
    t("publish: a higher sequence replaces the file with compare-and-swap on the read SHA", higher)

    def lower_equal():
        out = []
        for cand in ("c100", "c099"):
            gh = FakeGitHub(content=open(env["c100"], "rb").read())
            try:
                m.publish(env[cand], env["pub"], REPO, "t", opener=gh)
                out.append("published")
            except m.Stop as e:
                out.append("stop" if not gh.puts() and "not higher" in str(e) else "other")
        return out == ["stop", "stop"], out
    t("publish: an equal (even identical) or lower sequence is refused, nothing written", lower_equal)

    def bad_candidate():
        out = []
        for cand in ("tampered", "otherkey", "badpayload"):
            gh = FakeGitHub(content=None)
            try:
                m.publish(env[cand], env["pub"], REPO, "t", opener=gh)
                out.append("published")
            except m.Stop:
                out.append("stop" if not gh.requests else "contacted")
        return out == ["stop"] * 3, out
    t("publish: a tampered, foreign-key or invalid-payload candidate is refused before any request", bad_candidate)

    def unverifiable_current():
        gh = FakeGitHub(content=b'{"format":"x"}')
        try:
            m.publish(env["c101"], env["pub"], REPO, "t", opener=gh)
            return False, "published"
        except m.Stop as e:
            return not gh.puts() and "does not verify" in str(e), str(e)
    t("publish: an existing file that does not verify stops ordinary publication", unverifiable_current)

    def read_failures():
        out = []
        for gh in (FakeGitHub(get_status=500), FakeGitHub(get_status=403), FakeGitHub(content=None, not_found_body=False)):
            try:
                m.publish(env["c101"], env["pub"], REPO, "t", opener=gh)
                out.append("published")
            except m.Stop:
                out.append("stop" if not gh.puts() else "wrote")
        return out == ["stop"] * 3, out
    t("publish: a 5xx, a 403 or a bare 404 is never treated as 'first publication'", read_failures)

    def conflict():
        gh = FakeGitHub(content=open(env["c100"], "rb").read())
        orig = gh.__call__

        class Racing(FakeGitHub):
            pass
        gh2 = FakeGitHub(content=open(env["c100"], "rb").read())

        def racing(req, timeout=30):
            if req.get_method() == "PUT":
                gh2.sha = "sha-concurrent"
            return gh2(req, timeout)
        try:
            m.publish(env["c101"], env["pub"], REPO, "t", opener=racing)
            return False, "published"
        except m.Stop as e:
            return len(gh2.puts()) == 1 and "concurrent" in str(e), (str(e), gh2.requests)
        finally:
            del orig, Racing
    t("publish: a concurrent writer makes the PUT fail; it is not retried with a new SHA", conflict)

    def large_current():
        # L1: a published file above GitHub's 1 MB inline limit is read with
        # the raw media type; its bytes must hash to the reported blob SHA.
        c100 = open(env["c100"], "rb").read()
        gh = FakeGitHub(content=c100, inline_max=16)
        r = m.publish(env["c101"], env["pub"], REPO, "t", opener=gh)
        accepts = [q[3] for q in gh.requests if q[0] == "GET"]
        return (r.startswith("published") and accepts == ["application/vnd.github.object+json", "application/vnd.github.raw+json"]
                and json.loads(gh.puts()[0][2]).get("sha") == blob(c100)), (r, accepts)
    t("publish: a file GitHub does not inline is read raw and CAS uses the blob SHA of the verified bytes", large_current)

    def mismatched_bytes():
        c100, c101 = open(env["c100"], "rb").read(), open(env["c101"], "rb").read()
        out = []
        for gh in (FakeGitHub(content=c100, inline_max=16, raw_override=c101),       # changed between the two reads
                   FakeGitHub(content=c100, sha="0" * 40),                            # inline bytes, wrong SHA
                   FakeGitHub(content=c100, inline_max=16, raw_status=500)):          # raw read fails
            try:
                m.publish(env["c101"], env["pub"], REPO, "t", opener=gh)
                out.append("published")
            except m.Stop:
                out.append("stop" if not gh.puts() else "wrote")
        return out == ["stop"] * 3, out
    t("publish: bytes that do not match the blob SHA, or an unreadable raw body, stop before any write", mismatched_bytes)

    def oversized():
        big = os.path.join(os.path.dirname(env["c101"]), "big.sig.json")
        open(big, "wb").write(b" " * (m.MAX_BYTES + 1))
        gh = FakeGitHub(content=None)
        try:
            m.publish(big, env["pub"], REPO, "t", opener=gh)
            return False, "published"
        except m.Stop as e:
            return m.MAX_BYTES == 2949120 and not gh.requests and "too large" in str(e), str(e)
    t("publish: the envelope cap is 2,949,120 bytes (2 MiB payload, L1); a larger candidate is refused before any request", oversized)

    def wrong_repo():
        try:
            m.publish(env["c101"], env["pub"], "permaevidence/briglia-cli", "t", opener=FakeGitHub())
            return False, "published"
        except m.Stop:
            return True, None
    t("publish: refuses any repository but the dedicated one", wrong_repo)
    return res


BREAKS = [
    ("publish: first publication only on a positive 404, one PUT of the one path, no sha", 'PATH = "v1/local-tools.sig.json"', 'PATH = "v1/other.json"'),
    ("publish: a higher sequence replaces the file with compare-and-swap on the read SHA", '            body["sha"] = sha', '            pass'),
    ("publish: an equal (even identical) or lower sequence is refused, nothing written", "            if cand_seq <= pub_seq:", "            if cand_seq < pub_seq:"),
    ("publish: a tampered, foreign-key or invalid-payload candidate is refused before any request", "        cand_seq = verify(cand, pubkey, work)", "        cand_seq = 10 ** 9"),
    ("publish: an existing file that does not verify stops ordinary publication", "                pub_seq = verify(published, pubkey, work)", "                pub_seq = -1"),
    ("publish: a 5xx, a 403 or a bare 404 is never treated as 'first publication'", '        if msg == "Not Found":', '        if True:'),
    ("publish: a concurrent writer makes the PUT fail; it is not retried with a new SHA", "        if status == 409 or status == 422:", "        if False:"),
    ("publish: refuses any repository but the dedicated one", "    if repo != REPO_RE:", "    if False:"),
    ("publish: a file GitHub does not inline is read raw and CAS uses the blob SHA of the verified bytes",
     '        status, content = api("GET", url, token, opener=opener, accept=RAW)', '        status, content = 200, b""'),
    ("publish: bytes that do not match the blob SHA, or an unreadable raw body, stop before any write",
     "    if len(content) != size or blob_sha(content) != sha:", "    if False:"),
    ("publish: the envelope cap is 2,949,120 bytes (2 MiB payload, L1); a larger candidate is refused before any request",
     "MAX_BYTES = 2949120", "MAX_BYTES = 2949121"),
]


def main():
    ossl = openssl()
    if not ossl:
        print("· skipped: no Ed25519-capable OpenSSL")
        return 0
    tmp = tempfile.mkdtemp(prefix="advisory-publish-job-")
    try:
        run = lambda a, **k: subprocess.run(a, capture_output=True, text=True, **k)  # noqa: E731
        run([ossl, "genpkey", "-algorithm", "ed25519", "-out", f"{tmp}/k.pem"])
        run([ossl, "pkey", "-in", f"{tmp}/k.pem", "-pubout", "-out", f"{tmp}/k.pub.pem"])
        run([ossl, "genpkey", "-algorithm", "ed25519", "-out", f"{tmp}/o.pem"])
        run([ossl, "pkey", "-in", f"{tmp}/o.pem", "-pubout", "-out", f"{tmp}/o.pub.pem"])
        os.environ["OPENSSL_BIN"] = ossl
        w = fx.watchlist(tmp)
        base = json.loads(pub.build(w, fx.bundle([fx.row([fx.rec(1)])]), None, fx.NOW))
        env = {"pub": f"{tmp}/k.pub.pem"}
        for name, seq in (("c099", 99), ("c100", 100), ("c101", 101)):
            d = dict(base, sequence=seq)
            open(f"{tmp}/{name}.json", "w").write(json.dumps(d, separators=(",", ":"), sort_keys=True))
            r = run(["bash", f"{ROOT}/.github/scripts/sign-advisory.sh", f"{tmp}/k.pem", f"{tmp}/{name}.json", f"{tmp}/{name}.sig.json"],
                    env=dict(os.environ, EXPECTED_PUBKEY_PEM=f"{tmp}/k.pub.pem"))
            if r.returncode != 0:
                print("✖ signing setup failed", r.stdout, r.stderr)
                return 1
            env[name] = f"{tmp}/{name}.sig.json"
        e = json.load(open(env["c101"]))
        e["signature"] = base64.b64encode(bytes(64)).decode()
        open(f"{tmp}/tampered.sig.json", "w").write(json.dumps(e))
        env["tampered"] = f"{tmp}/tampered.sig.json"
        r = run(["bash", f"{ROOT}/.github/scripts/sign-advisory.sh", f"{tmp}/o.pem", f"{tmp}/c101.json", f"{tmp}/other.sig.json"],
                env=dict(os.environ, EXPECTED_PUBKEY_PEM=f"{tmp}/o.pub.pem"))
        env["otherkey"] = f"{tmp}/other.sig.json"
        bad = dict(base, sequence=102)
        bad["coverage"] = bad["coverage"] + [dict(bad["coverage"][0])]       # duplicate pair: check refuses
        raw = json.dumps(bad, separators=(",", ":")).encode()
        # A validly SIGNED envelope over an invalid payload (signed directly with openssl).
        sig_in = f"{tmp}/badin"
        keyid = json.load(open(env["c101"]))["keyId"]
        open(sig_in, "wb").write(b"briglia-advisory-envelope-v1\0briglia-local-tool-advisories-v1\0" + keyid.encode() + b"\0" + raw)
        run([ossl, "pkeyutl", "-sign", "-rawin", "-inkey", f"{tmp}/k.pem", "-in", sig_in, "-out", f"{tmp}/bad.sig"])
        open(f"{tmp}/badpayload.sig.json", "w").write(json.dumps({"format": "briglia-advisory-envelope-v1", "domain": "briglia-local-tool-advisories-v1",
            "keyId": keyid, "payload": base64.b64encode(raw).decode(), "signature": base64.b64encode(open(f"{tmp}/bad.sig", "rb").read()).decode()}))
        env["badpayload"] = f"{tmp}/badpayload.sig.json"
        run_tests(load(SRC, "publish_advisory_real"), env)
        caught = 0
        src = open(SRC).read()
        for i, (name, old, new) in enumerate(BREAKS):
            if old not in src:
                check(f"break anchor present: {name}", False, old)
                continue
            # The mutated copy lives in a disposable tree with its helper
            # scripts (never inside the checkout: it may be read-only).
            tree = os.path.join(tmp, f"tree{i}")
            os.makedirs(os.path.join(tree, ".github", "scripts"))
            os.makedirs(os.path.join(tree, "scripts"))
            for f in ("verify-advisory.sh", "openssl-resolve.sh"):
                shutil.copy(os.path.join(ROOT, ".github", "scripts", f), os.path.join(tree, ".github", "scripts", f))
            for f in ("advisory_publish.py", "advisory_fetch.py", "advisory_node.py", "advisory_libreoffice.py"):
                shutil.copy(os.path.join(ROOT, "scripts", f), os.path.join(tree, "scripts", f))
            p = os.path.join(tree, ".github", "scripts", "publish-advisory.py")
            open(p, "w").write(src.replace(old, new, 1))
            try:
                ok = run_tests(load(p, f"publish_advisory_b{i}"), env, only={name}).get(name) is False
            except Exception:       # noqa: BLE001
                ok = True
            caught += ok
            check(f"deliberate break caught: {name}", ok)
        print(f"\n{passed} passed, {failed} failed ({caught}/{len(BREAKS)} deliberate breaks caught)")
        return 1 if failed else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
