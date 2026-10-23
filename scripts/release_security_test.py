#!/usr/bin/env python3
"""Release tooling for signed security metadata (security plan v8 §4.4,
§15 items 3c and 7): the authorize-job checks with Codex's exact traces,
predecessor selection from the PUBLISHED history (never `latest`), the
alias lint, componentAdvisories forward-only rules, and the fragment that
build-manifest.sh signs. Standard library + openssl (for the signed fake
channel). No network: OSV and GitHub are local fakes.
"""
import http.server
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("release_security", ROOT / ".github/scripts/release_security.py")
rs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rs)

passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"✔ {label}")
    else:
        failed += 1
        print(f"✖ {label}" + (f" — {detail}" if detail else ""))


def entry(id_, aliases=(), level="recommended", frm=101, fixed=135):
    return {"id": id_, "aliases": list(aliases), "level": level, "affectsFromSequence": frm, "fixedInSequence": fixed}


def payload(seq, cumulative=None, floor_r=0, floor_c=0, components=None, security=True):
    p = {"schema": 1, "channel": "briglia-cli", "sequence": seq, "version": f"0.3.{seq}"}
    if security:
        p["security"] = {"cumulative": cumulative or [], "securityFloor": {"recommended": floor_r, "critical": floor_c}}
    if components is not None:
        p["componentAdvisories"] = components
    return p


def spec(seq, cumulative=None, floor_r=0, floor_c=0, components=None, **extra):
    s = {"schema": 1, "forSequence": seq, "cumulative": cumulative or [],
         "securityFloor": {"recommended": floor_r, "critical": floor_c}}
    if components is not None:
        s["componentAdvisories"] = components
    s.update(extra)
    return s


def no_aliases(ids, base):
    return set()


def run(s, seq, history, lookup=no_aliases):
    return rs.authorize(s, seq, history, alias_lookup=lookup)


def refused_with(reasons, needle):
    return any(needle in r for r in reasons)


CVE = "CVE-2026-12345"
GHSA = "GHSA-abcd-efgh-ijkl"
H135 = payload(135, [entry(CVE, [GHSA], fixed=135)])
H136 = payload(136, [], floor_r=135)


def reintroduction():
    hist = [H135, H136]
    variants = {
        "(i) only as its GHSA": spec(137, [entry(GHSA, fixed=135)], floor_r=135),
        "(ii) with all historical IDs": spec(137, [entry(CVE, [GHSA], fixed=135)], floor_r=135),
        "(iv) after a merge beyond 16 members": spec(137, [entry(CVE, [f"GHSA-{i:04d}-aaaa-bbbb" for i in range(8)], fixed=135),
                                                         entry(GHSA, [f"GHSA-{i:04d}-cccc-dddd" for i in range(8)], fixed=135)], floor_r=135),
    }
    for label, s in variants.items():
        reasons = run(s, 137, hist)
        check(f"3c reintroduction {label} → rejected: 'fix already covered by a published floor'",
              refused_with(reasons, "already covered by a published floor"), "; ".join(reasons))
    # (iii) recommended fix whose fixedIn is ≤ the CRITICAL floor P published.
    hist3 = [payload(135, [entry(CVE, fixed=130)]), payload(136, [], floor_r=0, floor_c=130)]
    reasons = run(spec(137, [entry("GHSA-zzzz-zzzz-zzzz", fixed=130)], floor_c=130), 137, hist3)
    check("3c (iii) recommended re-entry with fixedIn ≤ securityFloor.critical → rejected",
          refused_with(reasons, "already covered by a published floor"), "; ".join(reasons))
    # Accepted: range correction above the floor, critical re-entry above the critical floor.
    ok = run(spec(137, [entry(CVE, [GHSA], fixed=137)], floor_r=135), 137, hist)
    check("3c range correction (fixedIn above the floor) → allowed", ok == [], "; ".join(ok))
    crit = run(spec(137, [entry(CVE, [GHSA], level="critical", fixed=136)], floor_r=135), 137, hist)
    check("3c critical re-entry above securityFloor.critical → allowed", crit == [], "; ".join(crit))
    check("3c missing or unverifiable predecessor → refused", run(spec(137), 137, []) != [])


def alias_lint():
    hist = [H135, H136]
    reentry = spec(137, [entry(GHSA, fixed=137)], floor_r=135)
    reasons = run(reentry, 137, hist)
    check("alias lint: above-floor entering entry omitting historical IDs → refused (identity completeness)",
          refused_with(reasons, "omits historical IDs"), "; ".join(reasons))
    other = spec(137, [entry("GHSA-qqqq-qqqq-qqqq", fixed=137)], floor_r=135)
    osv = run(other, 137, hist, lookup=lambda ids, base: {CVE})
    check("alias lint: OSV alias is an omitted published ID → refused", refused_with(osv, "OSV aliases"), "; ".join(osv))

    def broken(ids, base):
        raise OSError("OSV unreachable")
    down = run(other, 137, hist, lookup=broken)
    check("alias lint: lookup unavailable → refused", refused_with(down, "alias lookup unavailable"), "; ".join(down))
    skipped = dict(other, aliasLookup="skipped: OSV outage, reviewed by hand")
    check("alias lint: recorded aliasLookup 'skipped: …' → allowed", run(skipped, 137, hist, lookup=broken) == [])
    under = dict(spec(137, [entry("GHSA-qqqq-qqqq-qqqq", fixed=135)], floor_r=135), aliasLookup="skipped: x")
    check("alias lint: the skip never bypasses the floor rule",
          refused_with(run(under, 137, hist, lookup=broken), "already covered by a published floor"))


def item7():
    hist = [payload(120, [entry(CVE, fixed=120, frm=100)])]
    drop = run(spec(121), 121, hist)
    check("7 dropping a still-open entry (not covered by a floor) → refused", refused_with(drop, "dropped without a covering"))
    covered = run(spec(121, floor_r=120), 121, hist)
    check("7 dropping an entry covered by the floor of its level → allowed", covered == [], "; ".join(covered))
    crit = run(spec(121, [entry(CVE, fixed=120, frm=100), entry("BRIGLIA-INTERNAL-1", level="critical", fixed=121)]), 121, hist)
    check("7 critical entry without a named advisory → refused", refused_with(crit, "no named advisory"))
    rng = run(spec(121, [entry(CVE, fixed=120, frm=120)]), 121, hist)
    check("7 affectsFromSequence ≥ fixedInSequence → refused", refused_with(rng, "violates"))
    above = run(spec(121, [entry(CVE, fixed=122, frm=100)]), 121, hist)
    check("7 fixedInSequence above the release's own sequence → refused", refused_with(above, "violates"))
    shrink = run(spec(121, [entry(GHSA, fixed=120, frm=100)]), 121, [payload(120, [entry(CVE, [GHSA], fixed=120, frm=100)])])
    check("3a identity set lost a published ID (CVE dropped from the entry) → refused", refused_with(shrink, "only grow"))
    floor = run(spec(121, floor_r=100), 121, [payload(120, floor_r=110)])
    check("decreasing floor → refused", refused_with(floor, "decreasing security floor"))
    wrong = run(spec(999), 121, [payload(120)])
    check("RELEASE_SECURITY.json for another sequence → refused (review per release)", refused_with(wrong, "is for sequence"))
    none_after = run(None, 121, [payload(120, [entry(CVE, fixed=120, frm=100)])])
    check("no security block after a release with open entries → refused", none_after != [])
    check("no security block after releases without one → allowed", run(None, 121, [payload(120, security=False)]) == [])
    ten_a = [f"GHSA-a{i}-xxxx-xxxx" for i in range(9)]
    ten_b = [f"GHSA-b{i}-xxxx-xxxx" for i in range(9)]
    union = run(spec(121, [entry("CVE-2026-77777", ten_a, fixed=121), entry("CVE-2026-77777", ten_b, fixed=121)]),
                121, [payload(120)])
    check("two 10-ID entries overlapping in one ID (19-ID union) → refused, never truncated", refused_with(union, "after the transitive merge"))
    chain = run(spec(121, [entry("CVE-2026-1", ["GHSA-ab-xxxx-xxxx"], fixed=121), entry("GHSA-ab-xxxx-xxxx", ["GHSA-bc-xxxx-xxxx"], fixed=121),
                            entry("GHSA-bc-xxxx-xxxx", fixed=121)]), 121, [payload(120)])
    check("chain A∩B, B∩C merged transitively (≤ 16) → allowed", chain == [], "; ".join(chain))
    intro = run(dict(spec(121), introduces=[{"id": "CVE-2026-2", "level": "recommended"}]), 121, [payload(120)])
    check("introduces entry not in cumulative → refused", refused_with(intro, "not in cumulative"))
    ctrl = run(dict(spec(121), summary="bad\u0007summary"), 121, [payload(120)])
    check("summary with control characters → refused", refused_with(ctrl, "control characters"))


def deb(eco="deb", **ident):
    base = {"distro": "ubuntu", "release": "noble", "arch": "arm64", "sourcePackage": "ffmpeg"} if eco == "deb" else ident
    return base


def comp(minimum, advisories=("USN-1234-1",), **kw):
    c = {"ecosystem": "deb", "identity": deb(), "minimumSafe": minimum, "advisories": list(advisories), "level": "recommended"}
    c.update(kw)
    return c


def components():
    base = [payload(120, components=[comp("7:6.1.1-3ubuntu5.2")])]
    check("components: superseded forward (higher minimumSafe, superset advisories) → allowed",
          run(spec(121, components=[comp("7:6.1.1-3ubuntu5.10", ("USN-1234-1", "CVE-2026-9"))]), 121, base) == [])
    cases = {
        "entry dropped": spec(121, components=[]),
        "minimumSafe lowered": spec(121, components=[comp("7:6.1.1-3ubuntu5.1")]),
        "minimumSafe unknown (unparseable)": spec(121, components=[comp("not a version!")]),
        "advisory set shrunk": spec(121, components=[comp("7:6.1.1-3ubuntu5.2", ("CVE-2026-9",))]),
        "more than 16 IDs": spec(121, components=[comp("7:6.1.1-3ubuntu5.2", [f"CVE-2026-{1000 + i}" for i in range(17)])]),
    }
    for label, s in cases.items():
        r = run(s, 121, base)
        check(f"components: {label} → refused", r != [], "allowed")
    many = [comp("1.0", identity={"distro": "ubuntu", "release": "noble", "arch": "arm64", "sourcePackage": f"p{i}"}) for i in range(65)]
    check("components: 65th identity → refused (owner decides)", refused_with(run(spec(121, components=many), 121, [payload(120)]), "more than 64"))
    gone = [payload(119, components=[comp("7:6.1.1-3ubuntu5.2")]), payload(120, components=[])]
    check("components: an identity reappearing after an absence → refused",
          refused_with(run(spec(121, components=[comp("7:6.1.1-3ubuntu5.2")]), 121, gone), "reappears"))
    v = rs.compare_versions
    check("deb version order: ~ sorts first, revisions numeric, epochs win",
          v("deb", "1.0~rc1", "1.0") == -1 and v("deb", "1.0-3ubuntu5.10", "1.0-3ubuntu5.2") == 1 and v("deb", "1:0.1", "9.9") == 1)


def predecessor():
    # 137 and 138 published; candidate 139 must compare against 138 even if
    # GitHub's `latest` still pointed at 137.
    hist = [payload(137, [entry(CVE, fixed=137)]), payload(138, [], floor_r=137)]
    reasons = run(spec(139, [entry(CVE, fixed=137)], floor_r=137), 139, hist)
    check("predecessor: candidate 139 compared against published 138 (re-adding 138's retired fix is refused)",
          refused_with(reasons, "already covered"), "; ".join(reasons))


# ------------------------------------------------- fetch-history (signed fake)

def openssl():
    out = subprocess.run(["bash", "-c", f". {ROOT}/.github/scripts/openssl-resolve.sh && resolve_openssl && echo $OPENSSL"],
                         capture_output=True, text=True)
    return out.stdout.strip().splitlines()[-1] if out.returncode == 0 and out.stdout.strip() else None


def fetch_history_test():
    ossl = openssl()
    if not ossl:
        check("fetch-history: openssl with Ed25519 available", False, "no usable openssl")
        return
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        key, pem = tmp / "k.pem", tmp / "pub.pem"
        subprocess.run([ossl, "genpkey", "-algorithm", "ed25519", "-out", key], check=True, capture_output=True)
        subprocess.run([ossl, "pkey", "-in", key, "-pubout", "-out", pem], check=True, capture_output=True)
        der = subprocess.run([ossl, "pkey", "-pubin", "-in", pem, "-outform", "DER"], check=True, capture_output=True).stdout
        import hashlib, base64
        fp = hashlib.sha256(der[-32:]).hexdigest()[:16]
        key_id = f"briglia-cli-release-v1-{fp}"

        def envelope(p, tamper=False):
            body = json.dumps(p, sort_keys=True).encode()
            inp = tmp / "in"
            inp.write_bytes(b"ada-release-envelope-v1\0briglia-cli\0" + key_id.encode() + b"\0" + body)
            sig = subprocess.run([ossl, "pkeyutl", "-sign", "-rawin", "-inkey", key, "-in", inp], check=True, capture_output=True).stdout
            if tamper:
                body = body.replace(b'"sequence":', b'"sequence": ')
            return json.dumps({"format": "ada-release-envelope-v1", "channel": "briglia-cli", "keyId": key_id,
                               "payload": base64.b64encode(body).decode(), "signature": base64.b64encode(sig).decode()}).encode()

        files = {"/e/137": envelope(payload(137)), "/e/138": envelope(payload(138)),
                 "/e/139": envelope(payload(139)), "/e/140": envelope(payload(140))}
        hits = []

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                hits.append(self.path)
                base = f"http://127.0.0.1:{self.server.server_port}"
                if self.path.startswith("/repos/o/r/releases"):
                    from urllib.parse import parse_qs, urlparse
                    page = int(parse_qs(urlparse(self.path).query)["page"][0])
                    rels = [
                        {"tag_name": "v0.3.137", "draft": False, "prerelease": False, "assets": [{"name": "manifest.sig.json", "browser_download_url": base + "/e/137"}]},
                        {"tag_name": "v0.3.138", "draft": False, "prerelease": False, "assets": [{"name": "manifest.sig.json", "browser_download_url": base + "/e/138"}]},
                        {"tag_name": "v0.3.139", "draft": True, "prerelease": False, "assets": [{"name": "manifest.sig.json", "browser_download_url": base + "/e/139"}]},
                        {"tag_name": "v0.3.140", "draft": False, "prerelease": True, "assets": [{"name": "manifest.sig.json", "browser_download_url": base + "/e/140"}]},
                        {"tag_name": "v0.1.50", "draft": False, "prerelease": False, "assets": []},
                    ] if page == 1 else []
                    data = json.dumps(rels).encode()
                elif self.path in files:
                    data = files[self.path]
                else:
                    self.send_response(404); self.end_headers(); return
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            out = tmp / "hist"
            out.mkdir()
            got = rs.fetch_history("o/r", str(pem), "briglia-cli", str(out), f"http://127.0.0.1:{srv.server_port}",
                                   str(ROOT / ".github/scripts/verify-envelope.sh"))
            seqs = sorted(p["sequence"] for p in got)
            check("fetch-history: only published releases (drafts, prereleases, pre-signing skipped), all verified",
                  seqs == [137, 138], f"{seqs}")
            check("fetch-history: never asks for the `latest` pointer", not any("latest" in h for h in hits), f"{hits}")
            files["/e/138"] = envelope(payload(138), tamper=True)
            try:
                rs.fetch_history("o/r", str(pem), "briglia-cli", str(out), f"http://127.0.0.1:{srv.server_port}",
                                 str(ROOT / ".github/scripts/verify-envelope.sh"))
                check("fetch-history: a published release that does not verify → refused", False)
            except rs.Refused:
                check("fetch-history: a published release that does not verify → refused", True)
        finally:
            srv.shutdown()


def emit_fragment():
    with tempfile.TemporaryDirectory() as tmp:
        f = Path(tmp) / "RELEASE_SECURITY.json"
        f.write_text(json.dumps(spec(121, [entry(CVE, fixed=121)], floor_r=110, summary="TLS fix", aliasLookup="skipped: x")))
        out = Path(tmp) / "frag.json"
        rc = rs.main(["emit", "--file", str(f), "--sequence", "121", "--out", str(out)])
        frag = json.loads(out.read_text())
        check("emit: fragment carries security (not forSequence/aliasLookup)",
              rc == 0 and set(frag) == {"security"} and "aliasLookup" not in frag["security"] and frag["security"]["summary"] == "TLS fix")
        rc2 = rs.main(["emit", "--file", str(f), "--sequence", "122", "--out", str(out)])
        check("emit: file for another sequence → refused", rc2 == 1)
        absent = rs.main(["emit", "--file", str(Path(tmp) / "none.json"), "--sequence", "121", "--out", str(out)])
        check("emit: no RELEASE_SECURITY.json → empty fragment (no security block)", absent == 0 and json.loads(out.read_text()) == {})
        # build-manifest.sh merges the fragment.
        out.write_text(json.dumps({"security": spec(121)["cumulative"] and {} or {"cumulative": [], "securityFloor": {"recommended": 0, "critical": 0}}}))
        dist = Path(tmp) / "dist"
        dist.mkdir()
        (dist / "briglia-linux-x64.tar.gz").write_bytes(b"x")
        env = dict(os.environ, SECURITY_FRAGMENT=str(out), PUBLISHED_AT="2026-10-23T00:00:00Z")
        res = subprocess.run(["bash", str(ROOT / ".github/scripts/build-manifest.sh"), "0.3.121", "121", str(Path(tmp) / "m.json")],
                             cwd=tmp, env=env, capture_output=True, text=True)
        m = json.loads((Path(tmp) / "m.json").read_text()) if res.returncode == 0 else {}
        check("build-manifest.sh adds the fragment's security block to the signed manifest",
              res.returncode == 0 and "security" in m and m["sequence"] == 121, res.stdout + res.stderr)
        out.write_text(json.dumps({"autoTarget": 1}))
        bad = subprocess.run(["bash", str(ROOT / ".github/scripts/build-manifest.sh"), "0.3.121", "121", str(Path(tmp) / "m2.json")],
                             cwd=tmp, env=env, capture_output=True, text=True)
        check("build-manifest.sh refuses a fragment with other keys (no autoTarget/rollback emitted)", bad.returncode != 0)


def main():
    reintroduction()
    alias_lint()
    item7()
    components()
    predecessor()
    emit_fragment()
    fetch_history_test()
    print(f"\n{'ALL' if failed == 0 else 'FAILED:'} {passed if failed == 0 else failed} RELEASE SECURITY CHECKS {'PASSED' if failed == 0 else f'of {passed + failed}'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
