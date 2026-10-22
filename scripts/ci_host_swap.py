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
paths in CLEANUP_PATHS are removed; the runner (/home/runner), Docker
(/var/lib/docker), the tool cache mounted into the job as /__t
(/opt/hostedtoolcache) and the system binaries are never touched, and the
script refuses to run if the list ever overlaps them.

The step fails loudly if cleanup or the swap fails, so a run never silently
goes back to the no-headroom configuration. Standard library only.
"""

import http.client
import json
import os
import socket
import struct
import sys
import urllib.parse

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
# Never deleted, and no cleanup path may be inside or above one of these.
PROTECTED_PATHS = (
    "/", "/usr", "/usr/local", "/usr/share", "/usr/local/lib", "/usr/local/share",
    "/opt", "/usr/bin", "/usr/local/bin", "/usr/lib", "/bin", "/sbin", "/lib",
    "/etc", "/var", "/var/lib/docker", "/var/run", "/home", "/home/runner",
    "/opt/hostedtoolcache", "/mnt", "/tmp", "/proc", "/sys", "/dev", "/boot", "/run",
)


def check_cleanup_paths(paths=CLEANUP_PATHS, protected=PROTECTED_PATHS):
    """Refuse a cleanup list that could reach anything the runner or Docker needs."""
    for p in paths:
        if not p.startswith("/") or p != os.path.normpath(p) or "'" in p or " " in p:
            raise ValueError(f"cleanup path {p!r} is not a plain absolute path")
        for q in protected:
            if p == q or q.startswith(p.rstrip("/") + "/"):
                raise ValueError(f"cleanup path {p} would delete protected {q}")
            if q != "/" and p.startswith(q + "/") and q not in ("/usr", "/usr/local", "/usr/share",
                                                                 "/usr/local/lib", "/usr/local/share", "/opt"):
                raise ValueError(f"cleanup path {p} is inside protected {q}")

HOST_SCRIPT = r"""
set -eu
SIZE_GIB=__SIZE__
SPARE_GIB=__SPARE__
NAME=__NAME__
echo "host disk before cleanup:"; df -h / /mnt 2>/dev/null || df -h /
pids=""
for p in __CLEANUP__; do
  if [ -L "$p" ]; then echo "refusing: $p is a symlink" >&2; exit 1; fi
  if [ -e "$p" ]; then echo "removing $p"; rm -rf --one-file-system -- "$p" & pids="$pids $!"; else echo "absent: $p"; fi
done
for pid in $pids; do wait "$pid" || { echo "cleanup failed" >&2; exit 1; }; done
echo "host disk after cleanup:"; df -h / /mnt 2>/dev/null || df -h /
echo "host swap before:"; swapon --show || true; free -h
DIR=""
for d in /mnt /; do
  [ -d "$d" ] || continue
  avail=$(df -Pk "$d" | awk 'NR==2 {print $4}')
  if [ "$avail" -ge $(( (SIZE_GIB + SPARE_GIB) * 1024 * 1024 )) ]; then DIR="$d"; break; fi
  echo "$d: only ${avail} KiB free, need $(( (SIZE_GIB + SPARE_GIB) * 1024 * 1024 )) KiB"
done
[ -n "$DIR" ] || { echo "no filesystem with room for a ${SIZE_GIB} GiB swap file" >&2; exit 1; }
SWAP="${DIR%/}/$NAME"
if swapon --show=NAME --noheadings | grep -qx "$SWAP"; then
  echo "$SWAP already active"
else
  rm -f "$SWAP"
  fallocate -l "${SIZE_GIB}G" "$SWAP" || dd if=/dev/zero of="$SWAP" bs=1M count=$(( SIZE_GIB * 1024 )) status=none
  chmod 600 "$SWAP"
  mkswap "$SWAP" >/dev/null
  swapon "$SWAP"
fi
echo "host swap after:"; swapon --show; free -h
"""


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


def main():
    if not os.path.exists(SOCKET):
        print(f"{SOCKET} is not mounted into the job container", file=sys.stderr)
        return 1
    me = api("GET", f"/containers/{urllib.parse.quote(socket.gethostname())}/json")
    image = me["Config"]["Image"]
    check_cleanup_paths()
    before = swap_total_kib()
    script = (HOST_SCRIPT.replace("__SIZE__", str(SIZE_GIB))
              .replace("__SPARE__", str(SPARE_GIB))
              .replace("__NAME__", SWAP_FILE_NAME)
              .replace("__CLEANUP__", " ".join(f"'{p}'" for p in CLEANUP_PATHS)))
    created = api("POST", "/containers/create", {
        "Image": image,
        "User": "0",
        "Entrypoint": ["nsenter"],
        "Cmd": ["--target", "1", "--mount", "--", "/bin/sh", "-c", script],
        "HostConfig": {"Privileged": True, "PidMode": "host", "NetworkMode": "none"},
    })
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
