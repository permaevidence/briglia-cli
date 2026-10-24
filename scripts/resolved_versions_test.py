#!/usr/bin/env python3
"""Release builds must use exactly the Swift package versions in Package.resolved.

Static checks (always, no network):
  * every `swift build` in .github/workflows/release-signed.yml passes
    --force-resolved-versions (SwiftPM then fails instead of silently
    resolving a different version when Package.resolved is stale);
  * Package.resolved is version 3, has an originHash, and pins every
    Package.swift dependency (same URL) at an exact version + revision that
    satisfies the manifest's `from:` requirement (same major, not below);
  * no pin without a manifest dependency except known transitive ones that
    a pinned package declares (swift-asn1 via swift-crypto);
    (SwiftPM's staleness test is the originHash over the dependency URLs: a
    raised `from:` alone is NOT detected by the flag, which is why this
    static requirement check exists);
  * deliberate breaks on in-memory copies (a build without the flag, a
    missing pin, a pin below `from:`, a branch pin) must fail.

Live check (--live; needs network to github.com, uses the SwiftPM cache):
in a scratch copy of the manifest, `swift package resolve
--force-resolved-versions` must succeed on the committed Package.resolved and
FAIL on a stale one (a removed pin, an added dependency), while the
same stale copies WITHOUT the flag resolve silently (positive control: the
flag is what makes the difference).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release-signed.yml")
FLAG = "--force-resolved-versions"
# transitive pins a pinned package declares itself (checked against the resolved file only)
TRANSITIVE = {"swift-asn1": "swift-crypto"}


def norm(url):
    return re.sub(r"\.git$", "", url.strip().rstrip("/")).lower()


def semver(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", v or "")
    return tuple(int(x) for x in m.groups()) if m else None


def check_workflow(text):
    errs = []
    builds = re.findall(r"^\s*run:\s*(swift build[^\n]*)$", text, re.M)
    other = [l for l in text.splitlines() if "swift build" in l and not re.match(r"^\s*run:\s*swift build", l)
             and not l.strip().startswith("#")]
    if len(builds) != 3:
        errs.append(f"expected 3 release `swift build` steps, found {len(builds)}")
    for b in builds:
        if FLAG not in b.split("#")[0].split():
            errs.append(f"release build without {FLAG}: {b!r}")
    for l in other:
        errs.append(f"swift build outside a plain run step (not checked): {l.strip()!r}")
    return errs


def check_resolved(manifest, resolved_text):
    errs = []
    try:
        res = json.loads(resolved_text)
    except ValueError as e:
        return [f"Package.resolved is not JSON: {e}"]
    if res.get("version") != 3 or not re.match(r"^[0-9a-f]{64}$", res.get("originHash") or ""):
        errs.append("Package.resolved must be version 3 with an originHash")
    deps = re.findall(r'\.package\(url:\s*"([^"]+)",\s*from:\s*"([^"]+)"\)', manifest)
    if not deps or re.search(r"\.package\((?!url:\s*\"[^\"]+\",\s*from:)", manifest):
        errs.append("Package.swift dependencies must all be `.package(url:, from:)` (others are not checked)")
    pins = {norm(p.get("location", "")): p for p in res.get("pins", [])}
    for url, req in deps:
        pin = pins.get(norm(url))
        if not pin:
            errs.append(f"no Package.resolved pin for {url}")
            continue
        st = pin.get("state") or {}
        have, want = semver(st.get("version")), semver(req)
        if not have or not re.match(r"^[0-9a-f]{40}$", st.get("revision") or "") or "branch" in st:
            errs.append(f"{url}: pin must be an exact version + 40-hex revision (got {st})")
            continue
        if not want or have[0] != want[0] or have < want:
            errs.append(f"{url}: pinned {st.get('version')} does not satisfy from: {req}")
    manifest_ids = {norm(u).rsplit("/", 1)[-1] for u, _ in deps}
    for p in res.get("pins", []):
        ident = p.get("identity")
        if ident in manifest_ids:
            continue
        if TRANSITIVE.get(ident) not in manifest_ids:
            errs.append(f"unexpected pin {ident!r} (not a manifest dependency or a known transitive one)")
    return errs


def static_checks():
    wf = open(WORKFLOW, encoding="utf-8").read()
    manifest = open(os.path.join(ROOT, "Package.swift"), encoding="utf-8").read()
    resolved = open(os.path.join(ROOT, "Package.resolved"), encoding="utf-8").read()
    results = [("release-signed.yml: every release build forces Package.resolved", check_workflow(wf)),
               ("Package.resolved pins every manifest dependency exactly", check_resolved(manifest, resolved))]
    res = json.loads(resolved)

    def drop(ident):
        r = json.loads(resolved)
        r["pins"] = [p for p in r["pins"] if p["identity"] != ident]
        return json.dumps(r)

    def set_state(ident, **state):
        r = json.loads(resolved)
        for p in r["pins"]:
            if p["identity"] == ident:
                p["state"] = state
        return json.dumps(r)

    breaks = [
        ("macOS release build without the flag", lambda: check_workflow(wf.replace("swift build -c release " + FLAG, "swift build -c release", 1))),
        ("Linux release build without the flag", lambda: check_workflow(wf.replace("--static-swift-stdlib " + FLAG, "--static-swift-stdlib", 1))),
        ("flag only in a comment", lambda: check_workflow(wf.replace("swift build -c release " + FLAG, "swift build -c release # " + FLAG, 1))),
        ("a fourth build step without the flag", lambda: check_workflow(wf + "\n      - name: extra\n        run: swift build -c release\n")),
        ("missing pin", lambda: check_resolved(manifest, drop("swift-argument-parser"))),
        ("pin below from:", lambda: check_resolved(manifest.replace('from: "1.5.0"', 'from: "1.9.0"'), resolved)),
        ("next-major pin", lambda: check_resolved(manifest.replace('from: "3.0.0"', 'from: "4.0.0"'), resolved)),
        ("branch pin", lambda: check_resolved(manifest, set_state("opencombine", branch="main", revision="8576f0d579b27020beccbccc3ea6844f3ddfc2c2"))),
        ("unknown extra pin", lambda: check_resolved(manifest, json.dumps(dict(res, pins=res["pins"] + [{"identity": "evil", "location": "https://example.com/evil", "state": {"version": "1.0.0", "revision": "0" * 40}}])))),
        ("no originHash", lambda: check_resolved(manifest, json.dumps({k: v for k, v in res.items() if k != "originHash"}))),
    ]
    return results, breaks


def live_checks():
    swift = shutil.which("swift")
    if not swift:
        return [("live: swift not found", ["swift toolchain missing"])]
    base = tempfile.mkdtemp(prefix="resolved-live-")
    out = []

    def prep(name, manifest_edit=None, resolved_edit=None):
        d = os.path.join(base, name)
        os.makedirs(os.path.join(d, "TelegramConcierge", "Resources"))
        for r in ("BundledSkills", "MCPBundles", "QuickSetup"):
            os.makedirs(os.path.join(d, "TelegramConcierge", "Resources", r))
        with open(os.path.join(d, "TelegramConcierge", "main.swift"), "w") as f:
            f.write("print(1)\n")
        m = open(os.path.join(ROOT, "Package.swift")).read()
        r = open(os.path.join(ROOT, "Package.resolved")).read()
        with open(os.path.join(d, "Package.swift"), "w") as f:
            f.write(manifest_edit(m) if manifest_edit else m)
        with open(os.path.join(d, "Package.resolved"), "w") as f:
            f.write(resolved_edit(r) if resolved_edit else r)
        return d

    def resolve(d, flag):
        p = subprocess.run([swift, "package", "resolve"] + ([FLAG] if flag else []), cwd=d,
                           capture_output=True, text=True, timeout=600)
        return p.returncode, (p.stdout + p.stderr)[-300:]

    def drop_parser(r):
        j = json.loads(r)
        j["pins"] = [p for p in j["pins"] if p["identity"] != "swift-argument-parser"]
        return json.dumps(j, indent=2)

    try:
        rc, txt = resolve(prep("ok"), True)
        out.append(("live: committed Package.resolved resolves with the flag", [] if rc == 0 else [txt]))
        add_dep = '        .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),\n'
        for n, (label, kw) in enumerate((
                ("a removed pin", {"resolved_edit": drop_parser}),
                ("a dependency added without updating Package.resolved",
                 {"manifest_edit": lambda m: m.replace("    dependencies: [\n", "    dependencies: [\n" + add_dep, 1)}))):
            rc, txt = resolve(prep(f"bad-{n}", **kw), True)
            out.append((f"live: {label} FAILS with the flag", [] if rc != 0 else ["resolved anyway: " + txt]))
            rc2, txt2 = resolve(prep(f"ctl-{n}", **kw), False)
            out.append((f"live (control): {label} resolves silently WITHOUT the flag", [] if rc2 == 0 else ["control failed: " + txt2]))
    finally:
        shutil.rmtree(base, ignore_errors=True)
    return out


def main(argv):
    results, breaks = static_checks()
    if "--live" in argv:
        results += live_checks()
    failed = 0
    for label, errs in results:
        print(f"{'✔' if not errs else '✖'} {label}" + ("" if not errs else " — " + "; ".join(map(str, errs))))
        failed += bool(errs)
    caught = 0
    for label, fn in breaks:
        bad = fn()
        print(f"{'✔' if bad else '✖'} break caught: {label}" + ("" if bad else " — NOT caught"))
        caught += bool(bad)
    if failed or caught != len(breaks):
        print(f"\nFAILED: {failed} check(s), {len(breaks) - caught} break(s) not caught")
        return 1
    print(f"\nresolved-versions: {len(results)} checks passed, {caught}/{len(breaks)} breaks caught")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
