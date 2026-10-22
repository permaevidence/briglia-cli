#!/usr/bin/env python3
"""Give the Linux CI runner host extra swap before the Swift builds.

The Linux CI jobs run inside a `swift:*-jammy` job container, which cannot
call swapon(2) itself. The runner mounts the host Docker socket into that
container, so this script asks the host Docker daemon for one short-lived
privileged helper container (same image as the job container, already
pulled) that enters the host's mount namespace and adds a swap file there.
Swap is a host kernel setting, so the job container gains the headroom too
(job containers run without a memory limit).

Why: 0.2.58 private CI lost Linux jobs to out-of-memory kills (exit 137 /
"runner lost communication") while compiling the briglia module, even at
`-j 2`; a single compiler frontend gets close to the runner's RAM.

The ubuntu-24.04 runners have ~7.8 GiB RAM, a 3 GiB swap file and only
~10 GB free disk (0.2.58 private CI run 39725039314), too little for 8 GiB of
swap plus headroom. So the helper first deletes preinstalled HOST toolchains
that no Linux job uses: every job runs inside the swift:*-jammy container with
its own Swift, apt packages, Node (/opt/node inside the container) and
Playwright; the host only provides Docker and the runner itself. Only the fixed
paths in CLEANUP_PATHS are removed, and every one of them must be in the
reviewed allow-list APPROVED_CLEANUP_PATHS (exact strings, plain lowercase
canonical absolute paths). Adding a path means editing that list, which
scripts/ci_inventory_test.py pins, so every addition is reviewed on its own.
The list is validated before the first Docker call. On the host, every path
is checked before anything is deleted: a symlinked path or ancestor, or a path
that is itself a mount point, aborts the step with nothing removed. Removal
uses `rm --one-file-system`, so a different filesystem mounted further inside
fails the step instead of being crossed. This protects against the listed
mistakes for these fixed paths on a GitHub-hosted runner; it is not a general
filesystem sandbox (a concurrent process could still change the host between
the check and the removal).

The swap step is idempotent: an already-active briglia-ci.swap on either
candidate filesystem is reused before any free-space check.

The step fails loudly if cleanup or the swap fails, so a run never silently
goes back to the no-headroom configuration. A failure after deletions started
can leave some toolchains removed (the runner VM is disposable). The helper
container carries a per-run label; it is force-removed by ID, or found by that
label when the create response was lost. A killed script can still leave a
helper behind until the VM is discarded. Standard library only.
"""

import http.client
import json
import os
import posixpath
import re
import socket
import struct
import sys
import urllib.parse
import uuid

SOCKET = "/var/run/docker.sock"
SWAP_FILE_NAME = "briglia-ci.swap"
SIZE_GIB = 8
SPARE_GIB = 6  # disk that must stay free on the chosen filesystem after the swap file

# Preinstalled host toolchains no Linux job uses (all builds/tests run in the
# swift:*-jammy job container). Deleted on the host before the swap file.
CLEANUP_PATHS = (
    "/usr/local/lib/android",     # Android SDK/NDK
    "/usr/share/dotnet",          # .NET SDKs
    "/opt/ghc",                   # Haskell
    "/usr/local/.ghcup",          # Haskell (ghcup)
    "/usr/local/share/boost",     # Boost
    "/usr/local/share/powershell",
    "/usr/share/swift",           # host Swift; the jobs use the container's
)
# The reviewed allow-list. A cleanup path must be one of these exact strings;
# scripts/ci_inventory_test.py pins this set, so a new entry needs its own review.
APPROVED_CLEANUP_PATHS = frozenset({
    "/usr/local/lib/android",
    "/usr/share/dotnet",
    "/opt/ghc",
    "/usr/local/.ghcup",
    "/usr/local/share/boost",
    "/usr/local/share/powershell",
    "/usr/share/swift",
})
# Lowercase ASCII components, no empty/"."/".." component, no leading "//".
_PLAIN_PATH = re.compile(r"(?:/(?!\.{1,2}(?:/|\Z))[a-z0-9._-]+)+\Z")


def check_cleanup_paths(paths=CLEANUP_PATHS, approved=APPROVED_CLEANUP_PATHS):
    """Refuse any cleanup list that is not a subset of the reviewed allow-list."""
    if not isinstance(paths, (tuple, list)) or not paths:
        raise ValueError("cleanup list must be a non-empty tuple of paths")
    if len(set(paths)) != len(paths):
        raise ValueError("cleanup list has a duplicate path")
    for p in paths:
        if not isinstance(p, str) or not _PLAIN_PATH.match(p) or posixpath.normpath(p) != p:
            raise ValueError(f"cleanup path {p!r} is not a plain canonical absolute path")
        if p not in approved:
            raise ValueError(f"cleanup path {p} is not in the reviewed allow-list")


# __ROOT__ is empty on the runner; scripts/ci_inventory_test.py renders it with
# a scratch directory (and stub host commands) to exercise this logic.
HOST_SCRIPT = r"""
set -eu
ROOT=__ROOT__
SIZE_GIB=__SIZE__
SPARE_GIB=__SPARE__
NAME=__NAME__
command -v mountpoint >/dev/null 2>&1 || { echo "mountpoint(1) missing; refusing to delete anything" >&2; exit 1; }
echo "host disk before cleanup:"; df -h "$ROOT/" "$ROOT/mnt" 2>/dev/null || df -h "$ROOT/"
# Check every path (and each ancestor) before deleting anything.
present=""
for p in __CLEANUP__; do
  t="$ROOT$p"
  a="$ROOT"
  rest="${p#/}"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    a="$a/$part"
    if [ -L "$a" ]; then echo "refusing: $a is a symlink" >&2; exit 1; fi
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
  done
  if [ -e "$t" ]; then
    if mountpoint -q "$t"; then echo "refusing: $t is a mount point" >&2; exit 1; fi
    present="$present $t"
  else
    echo "absent: $t"
  fi
done
pids=""
for t in $present; do echo "removing $t"; rm -rf --one-file-system -- "$t" & pids="$pids $!"; done
for pid in $pids; do wait "$pid" || { echo "cleanup failed" >&2; exit 1; }; done
echo "host disk after cleanup:"; df -h "$ROOT/" "$ROOT/mnt" 2>/dev/null || df -h "$ROOT/"
echo "host swap before:"; swapon --show || true; free -h
SWAP=""
for d in "$ROOT/mnt" "$ROOT/"; do
  c="${d%/}/$NAME"
  if swapon --show=NAME --noheadings | grep -qx "$c"; then SWAP="$c"; echo "$SWAP already active"; break; fi
done
if [ -z "$SWAP" ]; then
  DIR=""
  for d in "$ROOT/mnt" "$ROOT/"; do
    [ -d "$d" ] || continue
    avail=$(df -Pk "$d" | awk 'NR==2 {print $4}')
    if [ "$avail" -ge $(( (SIZE_GIB + SPARE_GIB) * 1024 * 1024 )) ]; then DIR="$d"; break; fi
    echo "$d: only ${avail} KiB free, need $(( (SIZE_GIB + SPARE_GIB) * 1024 * 1024 )) KiB"
  done
  [ -n "$DIR" ] || { echo "no filesystem with room for a ${SIZE_GIB} GiB swap file" >&2; exit 1; }
  SWAP="${DIR%/}/$NAME"
  rm -f "$SWAP"
  fallocate -l "${SIZE_GIB}G" "$SWAP" || dd if=/dev/zero of="$SWAP" bs=1M count=$(( SIZE_GIB * 1024 )) status=none
  chmod 600 "$SWAP"
  mkswap "$SWAP" >/dev/null
  swapon "$SWAP"
fi
echo "host swap after:"; swapon --show; free -h
"""


def render_host_script(root="", paths=CLEANUP_PATHS):
    """The host shell script; `root` is "" on the runner (tests use a scratch dir)."""
    check_cleanup_paths(paths)
    if root and (not root.startswith("/") or any(ch in root for ch in "'\"\\$` \t\n")):
        raise ValueError("test root must be a plain absolute path (no quotes, spaces or shell characters)")
    return (HOST_SCRIPT.replace("__ROOT__", f"'{root}'")
            .replace("__SIZE__", str(SIZE_GIB))
            .replace("__SPARE__", str(SPARE_GIB))
            .replace("__NAME__", SWAP_FILE_NAME)
            .replace("__CLEANUP__", " ".join(f"'{p}'" for p in paths)))


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._path)
        self.sock = s


def api(method, path, body=None, timeout=60, raw=False):
    conn = UnixHTTPConnection(SOCKET, timeout)
    headers = {"Host": "docker"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    conn.request(method, path, body=data, headers=headers)
    resp = conn.getresponse()
    payload = resp.read()
    conn.close()
    if resp.status >= 300:
        raise RuntimeError(f"docker {method} {path}: HTTP {resp.status}: {payload[:500]!r}")
    if raw:
        return payload
    return json.loads(payload) if payload else None


def demux(stream):
    """Docker log stream without a TTY: 8-byte header (stream, 0, 0, 0, size) + payload."""
    out, i = [], 0
    while i + 8 <= len(stream):
        size = struct.unpack(">I", stream[i + 4:i + 8])[0]
        out.append(stream[i + 8:i + 8 + size])
        i += 8 + size
    return b"".join(out).decode(errors="replace")


def swap_total_kib():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("SwapTotal:"):
                return int(line.split()[1])
    raise RuntimeError("SwapTotal missing from /proc/meminfo")


HELPER_LABEL = "briglia-ci-swap-helper"


def remove_labelled_helpers(token):
    """Force-remove helpers of this run found by label (lost create response)."""
    filters = urllib.parse.quote(json.dumps({"label": [f"{HELPER_LABEL}={token}"]}))
    for c in api("GET", f"/containers/json?all=1&filters={filters}") or []:
        api("DELETE", f"/containers/{c['Id']}?force=1")


def main():
    # Validate before any Docker call or host change.
    check_cleanup_paths(CLEANUP_PATHS)
    script = render_host_script("", CLEANUP_PATHS)
    if not os.path.exists(SOCKET):
        print(f"{SOCKET} is not mounted into the job container", file=sys.stderr)
        return 1
    me = api("GET", f"/containers/{urllib.parse.quote(socket.gethostname())}/json")
    image = me["Config"]["Image"]
    before = swap_total_kib()
    token = uuid.uuid4().hex
    try:
        created = api("POST", "/containers/create", {
            "Image": image,
            "User": "0",
            "Labels": {HELPER_LABEL: token},
            "Entrypoint": ["nsenter"],
            "Cmd": ["--target", "1", "--mount", "--", "/bin/sh", "-c", script],
            "HostConfig": {"Privileged": True, "PidMode": "host", "NetworkMode": "none"},
        })
    except Exception:
        # The daemon may have created it even though the response was lost.
        try:
            remove_labelled_helpers(token)
        except Exception as e:  # cleanup only; the create error is what fails the step
            print(f"warning: helper lookup by label failed: {e}", file=sys.stderr)
        raise
    cid = created["Id"]
    try:
        api("POST", f"/containers/{cid}/start")
        status = api("POST", f"/containers/{cid}/wait", timeout=1200)["StatusCode"]
        logs = api("GET", f"/containers/{cid}/logs?stdout=1&stderr=1", raw=True)
        print(demux(logs), end="", flush=True)
    finally:
        try:
            api("DELETE", f"/containers/{cid}?force=1")
        except Exception as e:  # cleanup only; the verdict below decides
            print(f"warning: helper container cleanup failed: {e}", file=sys.stderr)
    after = swap_total_kib()
    print(f"job container SwapTotal: {before} KiB -> {after} KiB", flush=True)
    if status != 0:
        print(f"host swap helper exited {status}", file=sys.stderr)
        return 1
    # mkswap keeps one header page, so allow 1 MiB below the nominal size
    if after < SIZE_GIB * 1024 * 1024 - 1024:
        print(f"SwapTotal {after} KiB is below the {SIZE_GIB} GiB swap file", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
