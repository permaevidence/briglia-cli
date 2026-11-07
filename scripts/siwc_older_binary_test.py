#!/usr/bin/env python3
"""Older-binary guard for Sign in with ChatGPT (SIWC plan §8, round-1 R1,
round-2 R1, D25), with a tag-built v0.2.67 binary.

The NEW binary (this tree's .build/debug/briglia) writes, inside scratch
roots, a usable legacy login plus an SIWC selection (legacy selection keys
removed, runtime slot deleted, runtime endpoint = SIWC base). The OLD
binary then runs against the same roots:

- never-multi: `setup-api status` does not list ChatGPT as configured
  although the legacy login is usable; the D25 boundary: an explicit
  `setup-api subscription select` in the old binary binds legacy, after
  which the new binary reads the selection as ambiguous and not configured;
- provisioning: the old `profiles add --copy-keys` from an SIWC default
  creates an extra with no runtime slot and the SIWC endpoint, which the
  new binary reads as legacy and not configured.

Every run uses temporary HOME/XDG roots, BRIGLIA_* stripped, binaries copied
under throwaway `briglia-mw-older*` names (own preference domains, purged at
the end). No network. Usage:

  python3 scripts/siwc_older_binary_test.py [--old-binary PATH]
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAG = "v0.2.67"
SIWC_BASE = "https://api.openai.com/v1"
NAMES = ("briglia-mw-older-old", "briglia-mw-older-new")

results = []


def check(label, ok, detail=""):
    results.append(ok)
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else f" — {detail}"), flush=True)


def build_old(work):
    tree = work / "tree"
    subprocess.run(["git", "worktree", "add", "--detach", str(tree), TAG], cwd=ROOT, check=True, capture_output=True)
    try:
        r = subprocess.run(["swift", "build", "--build-system", "native", "--scratch-path", str(work / "build")],
                           cwd=tree, capture_output=True, text=True, timeout=5400)
        if r.returncode != 0:
            raise RuntimeError("v0.2.67 build failed:\n" + (r.stdout + r.stderr)[-3000:])
        out = subprocess.run(["swift", "build", "--build-system", "native", "--scratch-path", str(work / "build"), "--show-bin-path"],
                             cwd=tree, capture_output=True, text=True).stdout.strip()
        binary = work / "briglia-old"
        shutil.copy2(Path(out) / "briglia", binary)
        return binary
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=ROOT, capture_output=True)


def env_for(roots, extra=None):
    env = {k: v for k, v in os.environ.items() if not (k.startswith("BRIGLIA_") or k.startswith("ADA_"))}
    env.update({"HOME": str(roots / "home"), "XDG_CONFIG_HOME": str(roots / "config"), "XDG_DATA_HOME": str(roots / "data"),
                "XDG_CACHE_HOME": str(roots / "cache"), "TMPDIR": str(roots / "tmp") + "/", "CFFIXED_USER_HOME": str(roots / "home")})
    for d in ("home", "config", "data", "cache", "tmp"):
        (roots / d).mkdir(parents=True, exist_ok=True)
    env.update(extra or {})
    return env


def run(binary, args, env, stdin=None):
    r = subprocess.run([str(binary)] + args, env=env, input=stdin, capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout, r.stderr


def last_json(text):
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return {}


def secrets(roots, profile=None):
    path = roots / "config" / ("briglia" if profile is None else f"briglia-profiles/{profile}") / "secrets.json"
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def digest(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def never_multi(old, new, base):
    roots = Path(tempfile.mkdtemp(prefix="briglia-siwc-older-nm-", dir=base))
    env = env_for(roots)
    code, out, err = run(new, ["__siwc-selftest", "--older-fixture"], env)
    route = last_json(out)
    check("fixture: the new binary selected the SIWC route", code == 0 and route.get("route") == "siwc", out + err)
    s = secrets(roots)
    check("selection: legacy subscription_model removed, runtime slot deleted, SIWC endpoint",
          "subscription_model" not in s and "openai_compatible_api_key" not in s and s.get("openai_compatible_base_url") == SIWC_BASE,
          str(sorted(s)))
    auth = roots / "config" / "briglia" / "subscription-auth.json"
    before = digest(auth)
    code, out, err = run(old, ["setup-api", "status"], env)
    status = last_json(out)
    chatgpt = status.get("providers", {}).get("profiles", {}).get("chatgpt")
    check("v0.2.67: ChatGPT is not configured (passive use fails closed) with a usable legacy login",
          code == 0 and (chatgpt is None or chatgpt.get("configured") is False), out[-800:] + err[-400:])
    code, out, err = run(old, ["setup-api", "subscription"], env, stdin='{"action":"status"}')
    check("v0.2.67: its legacy login itself is usable (the guard is the selection, not a dead login)",
          last_json(out).get("state") == "signed_in", out[-600:] + err[-300:])
    check("v0.2.67: the legacy auth file is untouched by passive use", digest(auth) == before)
    # D25 boundary: an explicit ChatGPT save in the old binary binds legacy.
    code, out, err = run(old, ["setup-api", "subscription"], env, stdin='{"action":"select","model":"gpt-6.1-sol","effort":"high"}')
    check("v0.2.67 (D25): an explicit ChatGPT save binds the legacy login", code == 0 and last_json(out).get("ok") is True,
          out[-600:] + err[-300:])
    code, out, err = run(new, ["__siwc-selftest", "--resolve"], env)
    after = last_json(out)
    check("new binary after the D25 save: ambiguous, not configured (asks to choose ChatGPT again)",
          after.get("route") == "ambiguous" and after.get("configured") is False, out + err)
    shutil.rmtree(roots, ignore_errors=True)


def provisioning(old, new, base):
    roots = Path(tempfile.mkdtemp(prefix="briglia-siwc-older-cp-", dir=base))
    env = env_for(roots, {"BRIGLIA_EXPERIMENTAL_PROFILES": "1"})
    code, out, err = run(new, ["__siwc-selftest", "--older-fixture"], env)
    check("fixture (multi): the new binary selected the SIWC route", code == 0 and last_json(out).get("route") == "siwc", out + err)
    code, out, err = run(old, ["profiles", "add", "sx", "--name", "Sx", "--home", str(roots / "home-sx"), "--copy-keys"], env)
    check("v0.2.67: profiles add --copy-keys runs", code == 0, (out + err)[-800:])
    extra = secrets(roots, "sx")
    check("v0.2.67 provisioning: the new extra has no runtime slot and the SIWC endpoint",
          "openai_compatible_api_key" not in extra and extra.get("openai_compatible_base_url") == SIWC_BASE and "subscription_model" not in extra,
          str(sorted(extra)))
    code, out, err = run(new, ["--profile", "sx", "__siwc-selftest", "--resolve"], env)
    view = last_json(out)
    check("new binary: that extra reads as legacy and not configured (never used silently)",
          view.get("route") == "legacy" and view.get("configured") is False, out + err)
    code, out, err = run(old, ["--profile", "sx", "setup-api", "status"], env)
    chatgpt = last_json(out).get("providers", {}).get("profiles", {}).get("chatgpt")
    check("v0.2.67: the provisioned extra does not list ChatGPT as configured", chatgpt is None or chatgpt.get("configured") is False,
          out[-600:] + err[-300:])
    shutil.rmtree(roots, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old-binary")
    ap.add_argument("--save-old", help="copy the built v0.2.67 binary here for later runs")
    args = ap.parse_args()
    new_src = ROOT / ".build" / "debug" / "briglia"
    if not new_src.exists():
        print("build the tree first (swift build --build-system native)")
        return 2
    base = Path(tempfile.mkdtemp(prefix="briglia-siwc-older-"))
    try:
        old_src = Path(args.old_binary) if args.old_binary else build_old(base / "build-old")
        if args.save_old and not args.old_binary:
            shutil.copy2(old_src, args.save_old)
        old, new = base / NAMES[0], base / NAMES[1]
        shutil.copy2(old_src, old)
        shutil.copy2(new_src, new)
        never_multi(old, new, base)
        provisioning(old, new, base)
    finally:
        shutil.rmtree(base, ignore_errors=True)
        for name in NAMES:
            subprocess.run(["defaults", "delete", name], capture_output=True)
    print(f"\n{sum(results)}/{len(results)} older-binary checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
