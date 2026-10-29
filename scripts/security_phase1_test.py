#!/usr/bin/env python3
"""Security plan v24 Phase 1 (AgentMail, Node, Python venv private runtimes)
and owner requirement P (pins never go stale silently), hermetic:

  1. `briglia __private-runtime-selftest`: AgentMail receipt / current link /
     journal / hold / repair with crash recovery at every write, per-use exec
     validation and probe mode, legacy inspect-only, the Node selection and
     private copy, the Python venv, the PATH contract;
  2. scripts/pin_gate_test.py (release gate: C1, C2, overrides, the tag
     record, deliberate breaks);
  3. scripts/python_lock.py --check (the universal hashed lock is bound to
     its committed input and generator settings);
  4. inventory: every client-delivered pin is exact, converges and is covered
     by the watch kinds the gate checks;
  5. static: no --break-system-packages and no shared `pip install` advice
     anywhere Briglia ships; the signed workflow runs the gate (C1 + C2, with
     its read-only issues token) before decoding the signing key, and the
     authorize job requires the promoter's annotated tag record; the
     development-only runtime seams are guarded by the -dev check.

Usage: security_phase1_test.py <briglia>
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
passed = failed = 0


def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"✔ {label}")
    else:
        failed += 1
        print(f"✖ {label}" + (f" — {str(detail)[-800:]}" if detail else ""))


def isolated_env(tmp):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "AGENTMAIL_"))}
    env.update(HOME=tmp, XDG_CONFIG_HOME=f"{tmp}/c", XDG_DATA_HOME=f"{tmp}/d", XDG_STATE_HOME=f"{tmp}/s")
    return env


def python_lock_cap_checks():
    """Owner decision 2026-10-25: pymupdf is capped below 2 (2.x pulls in onnxruntime and
    friends the skills never use). The committed lock honours the cap, and --check refuses
    a lock that violates it or a requirements.in line that is not a bare name / name<cap."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("python_lock", ROOT / "scripts" / "python_lock.py")
    pl = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pl)
    in_text = Path(pl.IN).read_text(encoding="utf-8")
    lock_text = Path(pl.LOCK).read_text(encoding="utf-8")
    rows = pl.entries(lock_text)
    names = {r[0] for r in rows}
    check("requirements.in caps pymupdf below 2", ("pymupdf", "2") in pl.caps(in_text), pl.caps(in_text))
    mu = [r[1] for r in rows if r[0] == "pymupdf"]
    check("lock: pymupdf is a 1.x release", len(mu) == 1 and mu[0].startswith("1."), mu)
    gone = {"onnxruntime", "pymupdf-layout", "pymupdf4llm"} & names
    check("lock: no onnxruntime / pymupdf-layout / pymupdf4llm", not gone, sorted(gone))

    def run_check(in_body, lock_body):
        with tempfile.TemporaryDirectory() as tmp:
            i, l = Path(tmp) / "requirements.in", Path(tmp) / "requirements.lock"
            i.write_text(in_body, encoding="utf-8")
            l.write_text(lock_body, encoding="utf-8")
            saved = pl.IN, pl.LOCK
            pl.IN, pl.LOCK = str(i), str(l)
            try:
                import contextlib, io
                err = io.StringIO()
                with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                    rc = pl.check()
                return rc, err.getvalue()
            finally:
                pl.IN, pl.LOCK = saved

    rc, err = run_check(in_text, lock_text)
    check("cap control: the committed pair passes the in-process check", rc == 0, err)
    bumped = re.sub(r"(?m)^pymupdf==\S+", "pymupdf==2.0", lock_text, count=1)
    rc, err = run_check(in_text, bumped)
    check("cap break: a lock with pymupdf 2.0 is refused", rc != 0 and "violates the requirements.in cap <2" in err, err)
    rc, err = run_check(in_text, re.sub(r"(?m)^pymupdf==\S+", "pymupdf==2.0rc1", lock_text, count=1))
    check("cap break: a 2.0 pre-release is refused too", rc != 0 and "violates the requirements.in cap <2" in err, err)
    for bad in ("0!2.0", "1!1.0", "1garbage", "1.28.2+local"):
        rc, err = run_check(in_text, re.sub(r"(?m)^pymupdf==\S+", "pymupdf==" + bad, lock_text, count=1))
        check(f"cap break: pymupdf=={bad} is refused", rc != 0 and ("violates the requirements.in cap <2" in err or "unparseable version" in err), err)
    for good in ("0!1.28.2", "1.999.0.post1"):
        rc, err = run_check(in_text, re.sub(r"(?m)^pymupdf==\S+", "pymupdf==" + good, lock_text, count=1))
        check(f"cap control: pymupdf=={good} is below the cap", rc == 0, err)
    rc, err = run_check(in_text.replace("pymupdf<2", "pymupdf>=1"), lock_text)
    check("cap break: a non-cap specifier in requirements.in is refused", rc != 0 and "only bare names or name<version caps" in err, err)

    # The supported-Python ceiling (2026-10-29): PythonRuntime.maximumMinor is tied to the lock.
    swift_text = Path(pl.SWIFT).read_text(encoding="utf-8")
    check("max minor: PythonRuntime.maximumMinor equals python_lock.MAX_PYTHON_MINOR (3.14)",
          pl.MAX_PYTHON_MINOR == 14 and re.search(r"(?m)^\s*static let maximumMinor = 14\s*$", swift_text) is not None)
    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp) / "PythonRuntime.swift"
        fake.write_text(re.sub(r"(?m)^(\s*static let maximumMinor = )\d+", r"\g<1>15", swift_text), encoding="utf-8")
        saved = pl.SWIFT
        pl.SWIFT = str(fake)
        try:
            rc, err = run_check(in_text, lock_text)
        finally:
            pl.SWIFT = saved
    check("max minor break: raising maximumMinor without the lock constant is refused", rc != 0 and "maximumMinor is 3.15" in err, err)


def main(argv):
    if len(argv) != 1:
        print(__doc__)
        return 64
    binary = argv[0]
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run([binary, "__private-runtime-selftest"], capture_output=True, text=True, env=isolated_env(tmp), timeout=1800)
        tail = r.stdout.strip().splitlines()[-1:] if r.stdout.strip() else []
        check(f"private-runtime selftest ({tail[0] if tail else 'no output'})", r.returncode == 0, r.stdout[-3000:] + r.stderr[-1000:])

    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "pin_gate_test.py")], capture_output=True, text=True, timeout=3600)
    check("pin gate: cases + deliberate breaks (" + " / ".join(l for l in r.stdout.splitlines() if "passed" in l or "caught" in l)[-160:] + ")",
          r.returncode == 0, r.stdout[-3000:])

    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "python_lock.py"), "--check"], capture_output=True, text=True, timeout=120)
    check("python lock bound to requirements.in and the generator settings", r.returncode == 0, r.stdout + r.stderr)
    python_lock_cap_checks()

    inv = json.loads((ROOT / "security" / "dependencies.json").read_text())
    client = [c for c in inv["components"] if c["owner"] == "briglia-private" and c["pin_kind"] == "exact"
              and c.get("converges") in ("startup", "bundle")]
    ids = {c["id"] for c in client}
    check("inventory: AgentMail, Node and every Python lock entry are client-delivered pins",
          "github-release:agentmail-cli" in ids and "runtime:node" in ids and any(i.startswith("pypi:venv:") for i in ids), sorted(ids)[:10])
    check("inventory: every client pin is watched by a kind the gate checks",
          all(c["watch"] in ("osv", "github-repo-advisories", "node-releases") and c.get("version") for c in client))
    check("inventory: no shared pip entries remain (Briglia never installs into the shared python3)",
          not any(c["id"].startswith("pypi:") and not c["id"].startswith("pypi:venv:") for c in inv["components"]))

    shipped = [p for p in (ROOT / "TelegramConcierge").rglob("*") if p.is_file() and p.suffix in (".swift", ".py", ".md")
               and "Selftest" not in p.name]
    bsp = [str(p.relative_to(ROOT)) for p in shipped if '"--break-system-packages"' in p.read_text(errors="replace")
           or "add `--break-system-packages`" in p.read_text(errors="replace")]
    check("no shipped code passes or recommends --break-system-packages", not bsp, bsp)
    skills = ROOT / "TelegramConcierge" / "Resources" / "BundledSkills"
    pip = [str(p.relative_to(ROOT)) for p in skills.rglob("*") if p.is_file() and re.search(r"pip install", p.read_text(errors="replace"))
           and not ("Never `pip install`" in p.read_text(errors="replace") and len(re.findall(r"pip install", p.read_text(errors="replace"))) == 1)]
    check("bundled skills give no shared `pip install` advice", not pip, pip)
    skill_md = [p for p in skills.glob("*/SKILL.md") if not p.parent.name == "video-edit"]
    check("document skills run their helpers with briglia-python",
          all("briglia-python ${CLAUDE_SKILL_DIR}/" in p.read_text() and not re.search(r"python3 \$\{CLAUDE_SKILL_DIR\}/(?!skills_doctor)", p.read_text())
              for p in skill_md))

    wf = (ROOT / ".github" / "workflows" / "release-signed.yml").read_text()
    sign = wf[wf.index("  sign:\n"):wf.index("  verify-candidate:\n")]
    gate_at, key_at = sign.find("scripts/pin_gate.py --mode signed"), sign.find("SIGNING_KEY_B64: ${{ secrets.BRIGLIA_CLI_SIGNING_KEY }}")
    check("signed workflow: the sign job runs the gate (signed mode) before the signing key is decoded",
          0 < gate_at < key_at and "environment: release-sign" in sign, (gate_at, key_at))
    check("signed workflow: the gate reads the private issues with the environment's read-only token, never C1-only",
          "BRIGLIA_PIN_GATE_ISSUES_TOKEN: ${{ secrets.BRIGLIA_PIN_GATE_ISSUES_TOKEN }}" in sign
          and "--issues-repo permaevidence/briglia-cli-private" in sign and "is not configured" in sign)
    auth = wf[wf.index("  authorize:\n"):wf.index("  build-macos-arm64:\n")]
    check("signed workflow: the authorize job requires the promoter's annotated tag and runs the credential-free precheck",
          './.github/scripts/read-pin-gate-record.sh "$REF_NAME" "$GITHUB_SHA" dist/pin-gate-record.txt' in auth
          and "--mode precheck" in auth and "pin-gate-record" in auth)
    reader = (ROOT / ".github" / "scripts" / "read-pin-gate-record.sh").read_text()
    check("signed workflow: the tag reader re-fetches the real tag and refuses lightweight/foreign tags",
          '"+refs/tags/$TAG:$PRIV"' in reader and '[ "$(git cat-file -t "$PRIV")" = "tag" ]' in reader
          and '"$PRIV^{commit}")" = "$SHA"' in reader)

    seams = (ROOT / "TelegramConcierge" / "Services" / "PrivateRuntime.swift").read_text()
    check("runtime test seams are development-build only", 'static var isDev: Bool { adaCLIVersion.hasSuffix("-dev") }' in seams
          and "guard isDev" in seams and "guard isDev, let spec" in seams)

    print(f"\nSecurity Phase 1: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
