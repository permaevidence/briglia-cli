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
          'git cat-file -t "refs/tags/$REF_NAME")" = "tag"' in auth and "--mode precheck" in auth and "pin-gate-record" in auth)

    seams = (ROOT / "TelegramConcierge" / "Services" / "PrivateRuntime.swift").read_text()
    check("runtime test seams are development-build only", 'static var isDev: Bool { adaCLIVersion.hasSuffix("-dev") }' in seams
          and "guard isDev" in seams and "guard isDev, let spec" in seams)

    print(f"\nSecurity Phase 1: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
