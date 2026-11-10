#!/usr/bin/env python3
"""Lock wheel coverage (metadata only): every supported target can install
Briglia's private Python lock (TelegramConcierge/Resources/PythonEnv/requirements.lock).

For every supported combination — CPython 3.<min>–3.<max> (PythonRuntime
minimumMinor / python_lock.MAX_PYTHON_MINOR) × macOS arm64, manylinux x86_64
and manylinux aarch64 — each lock entry that is active under its environment
marker must have at least one wheel on PyPI that is compatible with the target
AND whose sha256 is in the lock entry's hashes (pip installs the lock with
--require-hashes --only-binary=:all:). "Compatible" is pip's own rule: the
wheel's tags intersect the target's tag list built with packaging.tags
(cpython_tags + compatible_tags over mac_platforms / the manylinux list
packaging._manylinux would produce for that glibc and architecture), and the
file's Requires-Python accepts the target (Codex implementation review r1).
PyPI JSON metadata only: the sha256 digests and Requires-Python PyPI
publishes; no wheel is downloaded.

A lock-regeneration check (run it after scripts/python_lock.py --regenerate;
it needs the network), deliberately not a CI step. Added 2026-11-10 after
numpy-financial 1.1.0 (no linux aarch64 wheel) broke ARM Linux with
Python >= 3.13.

Usage: python3 scripts/python_lock_wheels.py [--lock PATH] [--macos 14.0] [--glibc 2.36] [--verbose]
Exit: 0 every target covered, 1 a gap, 2 metadata could not be read.
"""
import argparse
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import python_lock  # noqa: E402

try:
    from packaging import tags  # type: ignore
    from packaging.markers import Marker  # type: ignore
    from packaging.specifiers import SpecifierSet  # type: ignore
    from packaging.utils import parse_wheel_filename  # type: ignore
except ImportError:  # every python3 with pip vendors packaging
    from pip._vendor.packaging import tags  # type: ignore
    from pip._vendor.packaging.markers import Marker  # type: ignore
    from pip._vendor.packaging.specifiers import SpecifierSet  # type: ignore
    from pip._vendor.packaging.utils import parse_wheel_filename  # type: ignore

PLATFORMS = ("macos-arm64", "manylinux-x86_64", "manylinux-aarch64")
LEGACY_MANYLINUX = {17: "manylinux2014", 12: "manylinux2010", 5: "manylinux1"}


def swift_minor(name):
    text = open(python_lock.SWIFT, encoding="utf-8").read()
    m = re.search(rf"^\s*static let {name} = (\d+)\s*$", text, re.M)
    if not m:
        raise SystemExit(f"PythonRuntime.swift: static let {name} not found")
    return int(m.group(1))


def marker_env(minor, platform):
    mac = platform.startswith("macos")
    return {
        "implementation_name": "cpython", "implementation_version": f"3.{minor}.0", "os_name": "posix",
        "platform_machine": {"macos-arm64": "arm64", "manylinux-x86_64": "x86_64", "manylinux-aarch64": "aarch64"}[platform],
        "platform_python_implementation": "CPython", "platform_release": "", "platform_system": "Darwin" if mac else "Linux",
        "platform_version": "", "python_full_version": f"3.{minor}.0", "python_version": f"3.{minor}",
        "sys_platform": "darwin" if mac else "linux", "extra": "",
    }


def manylinux_platforms(arch, glibc_minor):
    """The platform list packaging._manylinux.platform_tags yields on a glibc
    2.<glibc_minor> system of this architecture (its runtime ABI checks taken
    as passing): manylinux_2_N down to 2.5 on x86_64/i686 and to 2.17
    elsewhere, the legacy aliases at 2.17/2.12/2.5, then linux_<arch>."""
    floor = 4 if arch in ("x86_64", "i686") else 16
    out = []
    for m in range(glibc_minor, floor, -1):
        out.append(f"manylinux_2_{m}_{arch}")
        if m in LEGACY_MANYLINUX:
            out.append(f"{LEGACY_MANYLINUX[m]}_{arch}")
    out.append(f"linux_{arch}")
    return out


def target_tags(minor, platform, macos, glibc):
    """pip's tag set for CPython 3.<minor> on the target."""
    if platform == "macos-arm64":
        plats = list(tags.mac_platforms(macos, "arm64"))
    else:
        plats = manylinux_platforms(platform.split("-", 1)[1], glibc)
    interp = f"cp3{minor}"
    out = set(tags.cpython_tags((3, minor), abis=[interp], platforms=plats))
    out |= set(tags.compatible_tags((3, minor), interpreter=interp, platforms=plats))
    return out


def installable(filename, requires_python, minor, target):
    """The wheel's tags meet the target's and its Requires-Python accepts 3.<minor>."""
    try:
        wheel = parse_wheel_filename(filename)[3]
    except Exception:  # noqa: BLE001
        return False
    if not (wheel & target):
        return False
    return not requires_python or SpecifierSet(requires_python).contains(f"3.{minor}.0", prereleases=True)


def pypi_files(name, version, cache):
    key = (name, version)
    if key not in cache:
        url = f"https://pypi.org/pypi/{name}/{version}/json"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "briglia-lock-check"}), timeout=30) as r:
                data = json.load(r)
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(f"{name}=={version}: PyPI metadata unreadable ({e})")
        cache[key] = [(f["filename"], f["digests"]["sha256"], f.get("requires_python")) for f in data.get("urls", [])
                      if f.get("packagetype") == "bdist_wheel" and f["filename"].endswith(".whl")]
    return cache[key]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lock", default=python_lock.LOCK)
    ap.add_argument("--macos", default="14.0", help="oldest macOS Briglia supports (Package.swift: .macOS(.v14))")
    ap.add_argument("--glibc", default="2.36", help="oldest supported glibc (Debian 12, the oldest distro shipping Python 3.11)")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    macos = tuple(int(x) for x in a.macos.split(".")[:2])
    glibc = int(a.glibc.split(".")[1])
    lo, hi = swift_minor("minimumMinor"), python_lock.MAX_PYTHON_MINOR
    rows = python_lock.entries(open(a.lock, encoding="utf-8").read())
    cache, gaps, checked = {}, [], 0
    try:
        for minor in range(lo, hi + 1):
            for platform in PLATFORMS:
                env = marker_env(minor, platform)
                target = target_tags(minor, platform, macos, glibc)
                active = [r for r in rows if r[2] is None or Marker(r[2]).evaluate(env)]
                names = [r[0] for r in active]
                dup = sorted({n for n in names if names.count(n) > 1})
                if dup:
                    gaps.append(f"cp3{minor} {platform}: more than one active pin for {', '.join(dup)}")
                for name, version, marker, hashes in active:
                    checked += 1
                    files = pypi_files(name, version, cache)
                    fits = [(f, h) for f, h, rp in files if installable(f, rp, minor, target)]
                    locked = [f for f, h in fits if h in set(hashes)]
                    if not fits:
                        gaps.append(f"cp3{minor} {platform}: {name}=={version} — no compatible wheel on PyPI "
                                    f"(wheels: {', '.join(sorted(f for f, _, _ in files)) or 'none'})")
                    elif not locked:
                        gaps.append(f"cp3{minor} {platform}: {name}=={version} — compatible wheels exist but none of their hashes is in the lock "
                                    f"({', '.join(sorted(f for f, _ in fits))})")
                    elif a.verbose:
                        print(f"  ✔ cp3{minor} {platform}: {name}=={version} via {locked[0]}")
    except RuntimeError as e:
        print(f"✖ {e}")
        return 2
    combos = (hi - lo + 1) * len(PLATFORMS)
    for g in gaps:
        print(f"✖ {g}")
    print(f"\nlock wheel coverage ({os.path.relpath(a.lock, ROOT) if a.lock.startswith(ROOT) else a.lock}): "
          f"{combos} targets (CPython 3.{lo}–3.{hi} × {', '.join(PLATFORMS)}; macOS ≥ {a.macos}, glibc ≥ {a.glibc}), "
          f"{checked} active pins checked, {len(gaps)} gap(s)")
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main())
