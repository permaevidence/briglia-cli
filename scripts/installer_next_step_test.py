#!/usr/bin/env python3
"""The installer's closing "next step" block (scripts/get-briglia.sh, between
the `>>> next-step` / `<<< next-step` markers), run alone under bash with the
variables the installer sets before it. Checks the desktop wording after the
installer wired PATH (open a new Terminal window, then `briglia menu`, with
the full-path fallback kept), and that the other branches are unchanged."""
import os, platform, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
src = (ROOT / "scripts/get-briglia.sh").read_text()
m = re.search(r"# >>> next-step.*?\n(.*)# <<< next-step", src, re.S)
if not m:
    print("✖ next-step markers not found"); sys.exit(1)
block = m.group(1)
darwin = platform.system() == "Darwin"
keys = "⌘N" if darwin else "Ctrl+Alt+T"
passed = failed = 0

def run(**v):
    env = {k: val for k, val in os.environ.items() if k not in ("SSH_CONNECTION", "DISPLAY", "WAYLAND_DISPLAY")}
    env.update({"DISPLAY": ":0"})
    env.update(v.pop("env", {}))
    pre = "".join(f'{k}="{val}"\n' for k, val in v.items())
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + pre + block], capture_output=True, text=True, env=env).stdout

def check(name, ok, detail=""):
    global passed, failed
    if ok: passed += 1; print(f"✔ {name}")
    else: failed += 1; print(f"✖ {name} — {detail}")

base = dict(DEST_DIR="/home/u/.local/bin", MIGRATED="0", MIGRATE_STATE="0")
out = run(ON_PATH="0", PATH_WIRED=" /home/u/.zshrc", **base)
check("wired PATH on a desktop: close/open a new Terminal window, then briglia menu",
      "close this Terminal window, open a new one" in out and f"({keys})" in out
      and "\n    briglia menu\n" in out, out)
check("wired PATH: the full-path command still works right here",
      "/home/u/.local/bin/briglia menu" in out, out)
check("wired PATH: never points to the terminal wizard", "briglia setup" not in out, out)
out = run(ON_PATH="0", PATH_WIRED="", **base)
check("PATH not wired: copy-paste full path, no new-window promise",
      "/home/u/.local/bin/briglia menu" in out and "open a new one" not in out, out)
out = run(ON_PATH="1", PATH_WIRED="", **base)
check("already on PATH: plain briglia menu, no new window needed",
      "Next step:  briglia menu" in out and "open a new one" not in out, out)
out = run(ON_PATH="0", PATH_WIRED=" /home/u/.bashrc", env={"SSH_CONNECTION": "1 2 3 4", "DISPLAY": ""}, **base)
check("ssh/headless: terminal wizard via full path, no new-window hint",
      "/home/u/.local/bin/briglia setup" in out and "open a new one" not in out, out)
out = run(ON_PATH="0", PATH_WIRED=" /home/u/.zshrc", DEST_DIR="/d", MIGRATED="0", MIGRATE_STATE="4")
check("migration conflict branch unchanged", "/d/briglia migrate" in out and "briglia menu" not in out, out)
print(f"Installer next-step test: {passed}/{passed + failed} passed")
sys.exit(1 if failed else 0)
