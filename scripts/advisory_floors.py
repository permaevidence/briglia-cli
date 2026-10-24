#!/usr/bin/env python3
"""Generate security/deb-floors.json: for every deb identity of the
local-tools watchlist, the LOWEST source version that a client of that
release could ever have installed from an origin it accepts (security plan
§9.5.12, lossless pruning). The advisory publisher drops an advisory of that
identity only when every affected range closes strictly below this floor
(scripts/advisory_publish.py `prunable`). Run by hand, the output is
reviewed and committed like the watchlist; the daily jobs never fetch it.

Why the floor is not just "the version on release day": the client accepts
an installed version only when its own apt index lists it under an
accepted origin (Origin Debian/Ubuntu, codename or codename-*, not
-backports/-proposed; LocalToolsInventoryDeb.originPocket). A machine that
installed a pre-release and never ran `apt update` again still has that
pre-release index, and its /etc/os-release already names the release once
base-files carries VERSION_ID. So the floor covers that window too:

  * Ubuntu: Launchpad's publishing history for the series (every pocket,
    every status, including the whole development cycle), minimum by dpkg
    order. ESM builds sit on top of archive versions and are never lower.
  * Debian: snapshot.debian.org `dists/<codename>/main/source/Sources.xz`
    sampled from before base-files first set VERSION_ID for the release
    (the "release candidate for <codename> as stable" upload) through
    release day, plus today's `<codename>`, `-updates` and `-security`.
    Each Sources file is checked against its Release file's SHA256. The
    sampled versions must be non-decreasing in time (dak and britney only
    ever move a suite to a newer version); any decrease, a missing sample or
    a version the client could not parse leaves that identity WITHOUT a
    floor, and the publisher then prunes nothing for it.

Usage: advisory_floors.py --out security/deb-floors.json [--watchlist PATH]
Exit: 0 written, 2 error. Network: public archives only, no credentials.
"""
import argparse
import datetime
import hashlib
import json
import lzma
import os
import re
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from advisory_fetch import DEFAULT_WATCHLIST, load_watchlist  # noqa: E402
from advisory_publish import client_deb_valid, deb_compare  # noqa: E402

UA = "briglia-security (release floor generator)"
MAX_FILE = 64 * 1024 * 1024
# Reviewed sampling plan. The first Debian sample is before the base-files
# "release candidate ... as stable" upload that added VERSION_ID (12.4 on
# 2023-03-02, 13.8 on 2025-05-12); the last is the day after release.
DEBIAN = {
    "12": {"codename": "bookworm",
           "samples": ["20230301T000000Z", "20230401T000000Z", "20230501T000000Z", "20230601T000000Z", "20230611T000000Z"]},
    "13": {"codename": "trixie",
           "samples": ["20250511T000000Z", "20250601T000000Z", "20250701T000000Z", "20250801T000000Z", "20250810T000000Z"]},
}
UBUNTU = {"24.04": {"codename": "noble"}}
LP = "https://api.launchpad.net/devel/ubuntu"


def get(url, limit=MAX_FILE):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=180) as r:
        data = r.read(limit + 1)
        if len(data) > limit:
            raise ValueError(f"{url}: larger than {limit} bytes")
        return data, r.geturl()


def parse_sources(text):
    """{source name: [versions]} from a Sources file (one stanza each)."""
    out = {}
    for stanza in text.split("\n\n"):
        pkg = ver = None
        for line in stanza.split("\n"):
            if line.startswith("Package: "):
                pkg = line[9:].strip()
            elif line.startswith("Version: "):
                ver = line[9:].strip()
        if pkg and ver:
            out.setdefault(pkg, []).append(ver)
    return out


def release_sha256(release_text, path):
    """The SHA256 a Release file lists for `path`, or None."""
    in_sha = False
    for line in release_text.split("\n"):
        if line.startswith("SHA256:"):
            in_sha = True
            continue
        if in_sha:
            if not line.startswith(" "):
                break
            parts = line.split()
            if len(parts) == 3 and parts[2] == path:
                return parts[0]
    return None


def debian_index(base, suite, codename_check=None):
    """One verified main/source/Sources.xz → (versions map, evidence)."""
    rel, rel_url = get(f"{base}/dists/{suite}/Release", 4 * 1024 * 1024)
    rel_text = rel.decode("utf-8", "replace")
    m = re.search(r"^Codename: (\S+)$", rel_text, re.M)
    if codename_check and (not m or m.group(1) != codename_check):
        raise ValueError(f"{rel_url}: codename is not {codename_check}")
    want = release_sha256(rel_text, "main/source/Sources.xz")
    raw, url = get(f"{base}/dists/{suite}/main/source/Sources.xz")
    got = hashlib.sha256(raw).hexdigest()
    if want != got:
        raise ValueError(f"{url}: SHA256 {got} does not match its Release file ({want})")
    date = re.search(r"^Date: (.+)$", rel_text, re.M)
    return parse_sources(lzma.decompress(raw).decode("utf-8", "replace")), \
        {"url": url, "sha256": got, "releaseDate": date.group(1) if date else None}


def debian_floors(release, sources):
    cfg = DEBIAN[release]
    cn = cfg["codename"]
    series, evidence = [], []
    for ts in cfg["samples"]:
        idx, ev = debian_index(f"https://snapshot.debian.org/archive/debian/{ts}", cn, cn)
        series.append(idx)
        evidence.append(dict(ev, sample=ts))
        print(f"  debian {release} sample {ts}: {len(idx)} sources", file=sys.stderr)
    current = []
    for base, suite in (("https://deb.debian.org/debian", cn), ("https://deb.debian.org/debian", f"{cn}-updates"),
                        ("https://security.debian.org/debian-security", f"{cn}-security")):
        idx, ev = debian_index(base, suite)
        current.append(idx)
        evidence.append(dict(ev, sample="current"))
    out = {}
    for src in sources:
        out[src] = debian_one(src, series, current)
    return out, evidence


def debian_one(src, series, current):
    """Floor for one source, or {"floor": None, "reason": ...}."""
    prev = None
    lows = []
    for i, idx in enumerate(series):
        vs = idx.get(src)
        if not vs:
            return {"floor": None, "reason": f"absent from sample {i + 1}"}
        for v in vs:
            if not client_deb_valid(v) or deb_compare(v, v) is None:
                return {"floor": None, "reason": f"unparsable version {v!r}"}
        low = min_version(vs)
        if prev is not None and deb_compare(low, prev) < 0:
            return {"floor": None, "reason": f"version decreased between samples ({prev} → {low})"}
        prev = low
        lows.append(low)
    for idx in current:
        for v in idx.get(src, []):
            if not client_deb_valid(v) or deb_compare(v, v) is None:
                return {"floor": None, "reason": f"unparsable current version {v!r}"}
            if deb_compare(v, lows[0]) < 0:
                return {"floor": None, "reason": f"a current version {v} is below the first sample"}
    return {"floor": lows[0], "observations": len(lows)}


def min_version(vs):
    best = vs[0]
    for v in vs[1:]:
        if deb_compare(v, best) < 0:
            best = v
    return best


def ubuntu_floors(release, sources):
    cn = UBUNTU[release]["codename"]
    out, evidence = {}, []
    for src in sources:
        url = (f"{LP}/+archive/primary?ws.op=getPublishedSources&exact_match=true&ws.size=300"
               f"&source_name={src}&distro_series={LP}/{cn}")
        versions, pockets, pages = [], set(), 0
        while url:
            raw, _ = get(url, 16 * 1024 * 1024)
            d = json.loads(raw)
            for e in d.get("entries", []):
                if e.get("source_package_name") != src:
                    continue
                versions.append(e["source_package_version"])
                pockets.add(e.get("pocket"))
            url = d.get("next_collection_link")
            pages += 1
            if pages > 50:
                raise ValueError(f"{src}: too many Launchpad pages")
        if "Release" not in pockets:
            out[src] = {"floor": None, "reason": "never published in the release pocket"}
        elif any(not client_deb_valid(v) or deb_compare(v, v) is None for v in versions):
            out[src] = {"floor": None, "reason": "an unparsable version in the publishing history"}
        else:
            out[src] = {"floor": min_version(versions), "observations": len(versions)}
        evidence.append({"source": src, "publications": len(versions), "pockets": sorted(p for p in pockets if p)})
        print(f"  ubuntu {release} {src}: {out[src]}", file=sys.stderr)
    return out, evidence


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--out", required=True)
    p.add_argument("--watchlist", default=DEFAULT_WATCHLIST)
    args = p.parse_args(argv)
    _, ids = load_watchlist(args.watchlist)
    by_rel = {}
    for i in ids:
        if i.get("kind") == "deb":
            by_rel.setdefault((i["distro"], i["release"]), []).append(i["source"])
    floors, evidence = {}, {}
    for (distro, release), srcs in sorted(by_rel.items()):
        if distro == "debian" and release in DEBIAN:
            res, ev = debian_floors(release, srcs)
        elif distro == "ubuntu" and release in UBUNTU:
            res, ev = ubuntu_floors(release, srcs)
        else:
            res, ev = {s: {"floor": None, "reason": "no floor method for this release"} for s in srcs}, []
        evidence[f"{distro}:{release}"] = ev
        for s, r in res.items():
            floors[f"deb:{distro}:{release}:{s}"] = r
    doc = {"schema": 1,
           "_comment": "Lowest source version a client of each release could have installed from an accepted origin "
                       "(security plan §9.5.12). Generated by scripts/advisory_floors.py, reviewed, committed. "
                       "floor null = the publisher prunes nothing for that identity.",
           "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "floors": dict(sorted(floors.items())), "evidence": evidence}
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    missing = [k for k, v in floors.items() if v["floor"] is None]
    print(f"✔ {len(floors)} identities, {len(floors) - len(missing)} with a floor; none for: {missing}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as e:
        print(f"✖ {e}", file=sys.stderr)
        sys.exit(2)
