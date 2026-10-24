#!/usr/bin/env python3
"""Publish an already-signed advisory list to the dedicated public repository
(security plan v18-v20 §9.5.11, owner direction H4 = option A). Runs in the
SEPARATE `publish` job of advisory-publish.yml, whose only secret is a
fine-grained token with contents: write on that one repository; it never sees
the signing key and never signs anything.

Steps, all fail-closed:
 1. verify the candidate envelope with the committed public key
    (verify-advisory.sh) AND its payload (advisory_publish.py check);
 2. read the currently published file through the contents API of `main`
    (one response: its bytes and its blob SHA); a positive 404 means "first
    publication"; any other failure stops; an existing file that does not
    verify stops (recovery is a separate manual step);
 3. refuse a candidate whose sequence is not strictly higher than the
    published one (expiry is irrelevant: an outage never lowers the floor);
 4. one PUT of exactly `v1/local-tools.sig.json` on `main` with the read SHA
    (compare-and-swap). A conflict is never retried with a freshly read SHA
    here: the next scheduled run starts again from step 1.

Usage: publish-advisory.py --candidate FILE --pubkey PEM --repo OWNER/NAME [--api URL] [--dry-run]
Env:   BRIGLIA_ADVISORY_PUBLISH_TOKEN
Exit:  0 published (or nothing to do in --dry-run), 1 refused/failed.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PATH = "v1/local-tools.sig.json"
MAX_BYTES = 368640
REPO_RE = "permaevidence/briglia-advisories"


class Stop(Exception):
    pass


def verify(envelope_bytes, pubkey, work):
    """→ the verified payload's sequence (envelope signature + payload rules)."""
    env_path = os.path.join(work, "env.json")
    out_path = os.path.join(work, "payload.json")
    with open(env_path, "wb") as f:
        f.write(envelope_bytes)
    r = subprocess.run(["bash", os.path.join(HERE, "verify-advisory.sh"), env_path, pubkey, out_path],
                       capture_output=True, text=True)
    if r.returncode != 0 or "VERIFIED" not in r.stdout:
        raise Stop(f"envelope does not verify: {(r.stdout + r.stderr).strip()[:300]}")
    r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "advisory_publish.py"), "check", out_path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise Stop(f"payload is invalid: {(r.stdout + r.stderr).strip()[:300]}")
    with open(out_path, "rb") as f:
        seq = json.loads(f.read()).get("sequence")
    if type(seq) is not int or seq < 0:
        raise Stop("payload has no sequence")
    return seq


def api(method, url, token, body=None, opener=None):
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                                          "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "briglia-advisory-publish"})
    try:
        with (opener or urllib.request.urlopen)(req, timeout=30) as r:
            raw = r.read(2 * MAX_BYTES)
            return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read(65536)


def current(base, repo, token, opener=None):
    """→ (bytes, sha) of the published file, or (None, None) on a positive 404."""
    status, raw = api("GET", f"{base}/repos/{repo}/contents/{PATH}?ref=main", token, opener=opener)
    if status == 404:
        try:
            msg = json.loads(raw).get("message", "")
        except ValueError:
            msg = ""
        if msg == "Not Found":
            return None, None
        raise Stop("404 without the API's 'Not Found' body (not a positive absence)")
    if status != 200:
        raise Stop(f"reading the published file failed: HTTP {status}")
    try:
        d = json.loads(raw)
        if d.get("type") != "file" or d.get("encoding") != "base64" or type(d.get("sha")) is not str:
            raise ValueError
        content = base64.b64decode(d["content"].replace("\n", ""), validate=True)
    except (ValueError, KeyError, AttributeError, TypeError):
        raise Stop("the contents API response is malformed")
    if len(content) > MAX_BYTES:
        raise Stop("the published file is too large")
    return content, d["sha"]


def publish(candidate, pubkey, repo, token, base="https://api.github.com", dry_run=False, opener=None):
    if repo != REPO_RE:
        raise Stop(f"refusing to publish to {repo!r} (only {REPO_RE})")
    with open(candidate, "rb") as f:
        cand = f.read()
    if len(cand) > MAX_BYTES:
        raise Stop("candidate too large")
    with tempfile.TemporaryDirectory() as work:
        cand_seq = verify(cand, pubkey, work)
        published, sha = current(base, repo, token, opener)
        if published is not None:
            try:
                pub_seq = verify(published, pubkey, work)
            except Stop as e:
                raise Stop(f"the published file does not verify ({e}); ordinary publication stops")
            if cand_seq <= pub_seq:
                raise Stop(f"candidate sequence {cand_seq} is not higher than the published {pub_seq}")
        if dry_run:
            return "dry-run: would publish sequence %d" % cand_seq
        body = {"message": f"Advisory list sequence {cand_seq}", "branch": "main",
                "content": base64.b64encode(cand).decode()}
        if sha:
            body["sha"] = sha
        status, raw = api("PUT", f"{base}/repos/{repo}/contents/{PATH}", token, body, opener)
        if status == 409 or status == 422:
            raise Stop(f"concurrent change (HTTP {status}); not retried — the next run starts over")
        if status not in (200, 201):
            raise Stop(f"publication failed: HTTP {status}")
        return f"published sequence {cand_seq}"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--candidate", required=True)
    p.add_argument("--pubkey", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--api", default="https://api.github.com")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    token = os.environ.get("BRIGLIA_ADVISORY_PUBLISH_TOKEN", "")
    if not token:
        print("✖ no publish token in the environment")
        return 1
    try:
        print(publish(a.candidate, a.pubkey, a.repo, token, a.api, a.dry_run))
        return 0
    except (Stop, OSError) as e:
        print(f"✖ {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
