#!/usr/bin/env python3
"""Lock wheel coverage (metadata only): every supported target can install
Briglia's private Python lock (TelegramConcierge/Resources/PythonEnv/requirements.lock).

For every supported combination — CPython 3.<min>–3.<max> (PythonRuntime
minimumMinor / python_lock.MAX_PYTHON_MINOR) × macOS arm64, manylinux x86_64
and manylinux aarch64 — each lock entry that is active under its environment
marker must have at least one wheel on PyPI that is compatible with the target
AND whose sha256 is in the lock entry's hashes (pip installs the lock with
--require-hashes --only-binary=:all:). PyPI JSON metadata only: the sha256
digests PyPI publishes; no wheel is downloaded.

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
    from packaging.markers import Marker  # type: ignore
except ImportError:  # every python3 with pip vendors it
    from pip._vendor.packaging.markers import Marker  # type: ignore

PLATFORMS = ("macos-arm64", "manylinux-x86_64", "manylinux-aarch64")
LEGACY_MANYLINUX = {"manylinux1": 5, "manylinux2010": 12, "manylinux2014": 17}


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


def wheel_tags(filename):
    """{(python, abi, platform)} of a wheel filename, compressed tag sets expanded."""
    stem = filename[:-len(".whl")]
    parts = stem.split("-")
    if len(parts) < 5:
        return set()
    py, abi, plat = parts[-3], parts[-2], parts[-1]
    return {(p, a, q) for p in py.split(".") for a in abi.split(".") for q in plat.split(".")}


def py_abi_ok(py, abi, minor):
    cp = f"cp3{minor}"
    if py == cp and abi in (cp, "none"):
        return True
    m = re.fullmatch(r"cp3(\d+)", py)
    if m and abi == "abi3" and 2 <= int(m.group(1)) <= minor:
        return True
    if abi == "none":
        if py == "py3":
            return True
        m = re.fullmatch(r"py3(\d+)", py)
        if m and int(m.group(1)) <= minor:
            return True
    return False


def platform_ok(plat, platform, macos, glibc):
    if plat == "any":
        return True
    if platform == "macos-arm64":
        m = re.fullmatch(r"macosx_(\d+)_(\d+)_(\w+)", plat)
        return bool(m) and m.group(3) in ("arm64", "universal2") and (int(m.group(1)), int(m.group(2))) <= macos
    arch = platform.split("-", 1)[1]
    m = re.fullmatch(r"manylinux_2_(\d+)_(\w+)", plat)
    if m:
        return m.group(2) == arch and int(m.group(1)) <= glibc
    m = re.fullmatch(r"(manylinux1|manylinux2010|manylinux2014)_(\w+)", plat)
    if m:
        return m.group(2) == arch and LEGACY_MANYLINUX[m.group(1)] <= glibc
    return False


def compatible(filename, minor, platform, macos, glibc):
    return any(py_abi_ok(p, a, minor) and platform_ok(q, platform, macos, glibc) for p, a, q in wheel_tags(filename))


def pypi_files(name, version, cache):
    key = (name, version)
    if key not in cache:
        url = f"https://pypi.org/pypi/{name}/{version}/json"
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "briglia-lock-check"}), timeout=30) as r:
                data = json.load(r)
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(f"{name}=={version}: PyPI metadata unreadable ({e})")
        cache[key] = [(f["filename"], f["digests"]["sha256"]) for f in data.get("urls", [])
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
                active = [r for r in rows if r[2] is None or Marker(r[2]).evaluate(env)]
                names = [r[0] for r in active]
                dup = sorted({n for n in names if names.count(n) > 1})
                if dup:
                    gaps.append(f"cp3{minor} {platform}: more than one active pin for {', '.join(dup)}")
                for name, version, marker, hashes in active:
                    checked += 1
                    files = pypi_files(name, version, cache)
                    fits = [(f, h) for f, h in files if compatible(f, minor, platform, macos, glibc)]
                    locked = [f for f, h in fits if h in set(hashes)]
                    if not fits:
                        gaps.append(f"cp3{minor} {platform}: {name}=={version} — no compatible wheel on PyPI "
                                    f"(wheels: {', '.join(sorted(f for f, _ in files)) or 'none'})")
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
