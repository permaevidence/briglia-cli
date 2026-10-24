#!/usr/bin/env python3
"""Security auto-update plan, Phase 0 — every check in one CI step.

  1. security/dependencies.json matches a fresh generation from the sources,
     and drift is caught (deliberate breaks on a scratch copy of the sources);
  2. the security-watch job against a mocked OSV/GitHub/KEV (scenarios plus
     its own deliberate breaks);
  3. release builds force Package.resolved (static checks + breaks);
  4. .github/workflows/security-watch.yml stays issues-only and private-only
     (structure checks + breaks);
  5. with a binary: the read-only Security status selftest, and `briglia
     doctor` in throwaway XDG roots prints the Security section (this runs the
     REAL host probe: apt-get -s on Linux CI, Software Update/brew on macOS).

Usage: security_phase0_test.py [path/to/briglia]
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WATCH_WF = os.path.join(ROOT, ".github", "workflows", "security-watch.yml")
FAILED = []


def check(label, ok, detail=""):
    print(f"{'✔' if ok else '✖'} {label}" + ("" if ok or not detail else f" — {str(detail)[-600:]}"))
    if not ok:
        FAILED.append(label)


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=kw.pop("timeout", 900), **kw)
    return p.returncode, p.stdout + p.stderr


# 1 ---------------------------------------------------------------------------

def inventory():
    rc, out = run([sys.executable, os.path.join(HERE, "security_inventory.py"), "--check"])
    check("inventory: committed security/dependencies.json is current", rc == 0, out)
    inv = json.load(open(os.path.join(ROOT, "security", "dependencies.json")))
    comps = inv["components"]
    ids = {c["id"] for c in comps}
    want = {"swift:swift-crypto", "npm:playwright-tree:@playwright/mcp", "github-release:agentmail-cli", "runtime:node",
            "runtime:gws", "npm:whatsapp:baileys", "pypi:pillow", "deb:userdata:ffmpeg", "brew:ffmpeg", "pypi:weasyprint",
            "host:pdf-renderer-browser", "host:os-tools"}
    check("inventory: covers every component class the plan names", want <= ids, sorted(want - ids))
    check("inventory: every OSV-watched entry has an exact version",
          all(c["version"] for c in comps if c["watch"] in ("osv", "osv-package")))
    check("inventory: unpinned/range/os entries are never marked OSV-watched",
          all(c["watch"] not in ("osv", "osv-package") for c in comps if c["pin_kind"] in ("unpinned", "range", "os-repo")))
    check("inventory: GitHub Actions use the package-level OSV mode (OSV does not version-match them)",
          all(c["watch"] == "osv-package" for c in comps if c["ecosystem"] == "GitHub Actions" and c["version"]))

    # drift breaks on a scratch copy holding exactly the files the inventory reads
    files = {c["source"].split(":")[0] for c in comps} | {"Package.resolved", "scripts/security_inventory.py",
                                                         "security/dependencies.json"}
    def scratch():
        d = tempfile.mkdtemp(prefix="secinv-")
        for f in files:
            os.makedirs(os.path.dirname(os.path.join(d, f)) or d, exist_ok=True)
            shutil.copy2(os.path.join(ROOT, f), os.path.join(d, f))
        shutil.copytree(os.path.join(ROOT, ".github", "workflows"), os.path.join(d, ".github", "workflows"), dirs_exist_ok=True)
        return d

    def edit(d, rel, old, new):
        p = os.path.join(d, rel)
        s = open(p).read()
        if old not in s:
            raise RuntimeError(f"break anchor {old!r} missing in {rel}")
        open(p, "w").write(s.replace(old, new, 1))

    breaks = [
        ("a Swift pin bumped without regenerating", "Package.resolved", '"version" : "3.15.1"', '"version" : "3.15.2"'),
        ("the managed-Node download code changed (evidence anchor gone)", "TelegramConcierge/Services/MCPRegistry.swift",
         "https://nodejs.org/dist/index.json", "https://example.invalid/index.json"),
        ("a new pinned action added to a workflow", ".github/workflows/security-watch.yml",
         "    steps:\n", "    steps:\n      - uses: actions/cache@0400d5f644dc74513175e3cd8d07132dd4860809 # v4.2.4\n"),
        ("the AgentMail pin changed", "TelegramConcierge/Services/AgentMailInstaller.swift",
         'static let pinnedVersion = "1.3.0"', 'static let pinnedVersion = "1.3.1"'),
    ]
    caught = 0
    for label, rel, old, new in breaks:
        d = scratch()
        try:
            edit(d, rel, old, new)
            rc, out = run([sys.executable, os.path.join(d, "scripts", "security_inventory.py"), "--check"])
            caught += rc != 0
            check(f"inventory break caught: {label}", rc != 0, out)
        finally:
            shutil.rmtree(d, ignore_errors=True)
    d = scratch()
    try:
        rc, out = run([sys.executable, os.path.join(d, "scripts", "security_inventory.py"), "--check"])
        check("inventory: the unmodified scratch copy passes (control)", rc == 0, out)
    finally:
        shutil.rmtree(d, ignore_errors=True)


# 2, 3 --------------------------------------------------------------------------

def watch_and_resolved():
    rc, out = run([sys.executable, os.path.join(HERE, "security_watch_test.py")])
    tail = "\n".join(l for l in out.splitlines() if l.startswith(("all ", "12/", "\d")) or "deliberate breaks caught" in l or "scenario checks" in l)
    check("security watch: mocked-feed scenarios and deliberate breaks", rc == 0, out)
    print("    " + tail.replace("\n", "\n    "))
    rc, out = run([sys.executable, os.path.join(HERE, "resolved_versions_test.py")])
    check("release builds force Package.resolved (static checks + breaks)", rc == 0, out)


# 4 ---------------------------------------------------------------------------

def watch_workflow_errors(text):
    errs = []
    if not re.search(r"^on:\n  schedule:\n    - cron: \"[0-9 *]+\"\n  workflow_dispatch:\n\n", text, re.M):
        errs.append("triggers must be exactly a daily schedule + workflow_dispatch")
    if re.search(r"pull_request|push:|workflow_run|repository_dispatch", text):
        errs.append("no push/PR/workflow_run triggers")
    if not re.search(r"^permissions:\n  contents: read\n  issues: write\n\n", text, re.M) or text.count("permissions:") != 1:
        errs.append("permissions must be exactly contents: read + issues: write, once, at the top")
    if "if: github.repository == 'permaevidence/briglia-cli-private'" not in text:
        errs.append("the job must be guarded to the private repository")
    if "secrets." in text:
        errs.append("no secrets beyond github.token")
    uses = re.findall(r"uses: (\S+)", text)
    if not uses or not all(re.match(r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$", u) for u in uses):
        errs.append("every action pinned to a full commit SHA")
    if "persist-credentials: false" not in text:
        errs.append("checkout must not persist the token")
    if not re.search(r"timeout-minutes: \d+", text):
        errs.append("a job timeout is required")
    runs = re.findall(r"run: (.+)", text)
    # Phase 3 (plan v16 §9.5.3): the watch also fetches the PUBLIC data of
    # the local-tools advisory list and uploads it as an artifact; it still
    # holds no secret and never signs or publishes.
    if runs != ["python3 scripts/security_inventory.py --check", "python3 scripts/security_watch.py",
                'python3 scripts/advisory_fetch.py --out "$RUNNER_TEMP/advisory-input"']:
        errs.append(f"run steps must be exactly the inventory check, the watch script and the advisory fetch, got {runs}")
    names = [u.split("@")[0] for u in uses]
    if names != ["actions/checkout", "actions/upload-artifact"]:
        errs.append(f"actions must be exactly checkout and upload-artifact, got {names}")
    return errs


def watch_workflow():
    text = open(WATCH_WF).read()
    errs = watch_workflow_errors(text)
    check("security-watch.yml: issues-only, private-only, pinned, bounded", not errs, errs)
    breaks = [
        ("contents: write", text.replace("contents: read", "contents: write")),
        ("pull-requests permission added", text.replace("  issues: write\n", "  issues: write\n  pull-requests: write\n")),
        ("repository guard removed", text.replace("    if: github.repository == 'permaevidence/briglia-cli-private'\n", "")),
        ("push trigger added", text.replace("  workflow_dispatch:\n", "  workflow_dispatch:\n  push:\n")),
        ("a secret used", text.replace("${{ github.token }}", "${{ secrets.RELEASE_TOKEN }}")),
        ("action by tag", text.replace("actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8", "actions/checkout@v5")),
        ("credentials persisted", text.replace("persist-credentials: false", "persist-credentials: true")),
        ("an extra build step", text.replace("        run: python3 scripts/security_watch.py\n", "        run: python3 scripts/security_watch.py\n      - name: x\n        run: swift build\n")),
        ("the advisory fetch given a signing secret", text.replace('run: python3 scripts/advisory_fetch.py --out "$RUNNER_TEMP/advisory-input"',
            'run: python3 scripts/advisory_fetch.py --out "$RUNNER_TEMP/advisory-input"\n        env:\n          K: ${{ secrets.BRIGLIA_ADVISORY_SIGNING_KEY }}')),
        ("a signing step added to the watch", text.replace('run: python3 scripts/advisory_fetch.py --out "$RUNNER_TEMP/advisory-input"',
            'run: python3 scripts/advisory_fetch.py --out "$RUNNER_TEMP/advisory-input"\n      - name: s\n        run: .github/scripts/sign-advisory.sh k p o')),
    ]
    for label, mutated in breaks:
        check(f"security-watch.yml break caught: {label}", mutated != text and bool(watch_workflow_errors(mutated)))


# 5 ---------------------------------------------------------------------------

def binary(bin_path):
    rc, out = run([bin_path, "__security-status-selftest"], timeout=300)
    check("binary: __security-status-selftest", rc == 0 and "SECURITY STATUS CHECKS PASSED" in out, out)
    scratch = tempfile.mkdtemp(prefix="secdoctor-")
    try:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "SM_"))}
        env.update(XDG_CONFIG_HOME=os.path.join(scratch, "config"), XDG_DATA_HOME=os.path.join(scratch, "data"))
        before = sorted(os.listdir(scratch))
        rc, out = run([bin_path, "doctor"], env=env, timeout=300)
        section = out.split("\nSecurity\n", 1)[1].split("\n\n", 1)[0] if "\nSecurity\n" in out else ""
        check("binary: `briglia doctor` prints a Security section with the summary line and the read-only footer",
              "🛡️ Security" in section and "read-only: nothing was installed or changed" in section, out[-1500:])
        print("    " + section.replace("\n", "\n    "))
        check("binary: the Security section never claims 'up to date'", "up to date" not in section.lower())
        created = [os.path.relpath(os.path.join(d, f), scratch) for d, _, fs in os.walk(scratch) for f in fs]
        check("binary: doctor wrote no file in the scratch roots (no trust lock, no cache, nothing)",
              set(os.listdir(scratch)) - set(before) <= {"config", "data"} and not created, created)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv):
    inventory()
    watch_and_resolved()
    watch_workflow()
    if argv:
        binary(os.path.abspath(argv[0]))
    else:
        print("· no binary given: skipping the Security status selftest and the doctor check")
    if FAILED:
        print(f"\n{len(FAILED)} Phase 0 check(s) FAILED")
        return 1
    print("\nALL SECURITY PHASE 0 CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
