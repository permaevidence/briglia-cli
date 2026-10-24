#!/usr/bin/env python3
"""Generate security/deb-floors.json: for every deb identity of the
local-tools watchlist, a release floor: (an estimate of) the lowest source
version ever published under that release's codename (security plan
§9.5.12, lossless pruning). The advisory publisher drops an advisory of that
identity only when every affected range closes strictly below this floor
(scripts/advisory_publish.py `prunable`) and writes the floor into the
entry; the client never reports "no known issue" for an installed version
below the floor or not comparable with it (LocalToolsMatcher). So a floor
that is too HIGH costs a rare "unknown", never a false "no known issue";
a floor that is too low only prunes less. Run by hand, the output is
reviewed and committed like the watchlist; the daily jobs never fetch it.

  * Ubuntu: Launchpad's complete publishing history for the series (every
    pocket and status, the development cycle included), minimum by dpkg
    order. Every page must be well formed and the entry count must equal
    the collection's total_size, otherwise no floor.
  * Debian: snapshot.debian.org `dists/<codename>/main/source/Sources.xz`
    sampled monthly from the day the codename became testing (the previous
    release day) through the day after its own release, plus today's
    `<codename>`, `-updates` and `-security`; each file checked against its
    Release file's SHA256; floor = the minimum over every sample. Versions
    between samples may be lower (removals, old snapshots): the client gate
    above keeps that safe. A source absent from the release-day sample, or
    any version the client could not parse, leaves no floor.

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


def monthly(first, last_month, release_day):
    """first (YYYYMMDD), then the 1st of every month up to last_month
    (YYYYMM), then release_day; as snapshot timestamps."""
    out = [first + "T120000Z"]
    y, m = int(first[:4]), int(first[4:6]) + 1
    while (y, m) <= (int(last_month[:4]), int(last_month[4:])):
        out.append(f"{y:04d}{m:02d}01T000000Z")
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)
    return out + [release_day + "T120000Z"]


# Reviewed sampling plan: from the day the codename became testing (the
# previous release: 2021-08-14, 2023-06-10) to the day after its release
# (2023-06-10, 2025-08-09).
DEBIAN = {
    "12": {"codename": "bookworm", "samples": monthly("20210815", "202306", "20230611")},
    "13": {"codename": "trixie", "samples": monthly("20230611", "202508", "20250810")},
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
    """Floor for one source (minimum over every sample and today's pockets),
    or {"floor": None, "reason": ...}. `series[-1]` is the release-day sample."""
    if not series or not series[-1].get(src):
        return {"floor": None, "reason": "absent from the release-day sample"}
    seen = []
    for idx in list(series) + list(current):
        for v in idx.get(src, []):
            if not client_deb_valid(v) or deb_compare(v, v) is None:
                return {"floor": None, "reason": f"unparsable version {v!r}"}
            seen.append(v)
    return {"floor": min_version(seen), "observations": len(seen)}


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
        versions, pockets, pages, total, count, problem = [], set(), 0, None, 0, None
        while url and problem is None:
            raw, _ = get(url, 16 * 1024 * 1024)
            try:
                d = json.loads(raw)
            except ValueError:
                d = None
            entries = d.get("entries") if type(d) is dict else None
            link = d.get("next_collection_link") if type(d) is dict else None
            if type(entries) is not list or (link is not None and type(link) is not str):
                problem = f"malformed Launchpad page {pages + 1}"
                break
            if pages == 0:
                total = d.get("total_size")
                if type(total) is not int or total < 0:
                    problem = "Launchpad collection without a total_size"
                    break
            for e in entries:
                if type(e) is not dict or type(e.get("source_package_name")) is not str \
                        or type(e.get("source_package_version")) is not str or type(e.get("pocket")) is not str:
                    problem = "malformed Launchpad publication"
                    break
                count += 1
                if e["source_package_name"] != src:
                    continue
                versions.append(e["source_package_version"])
                pockets.add(e["pocket"])
            url = link
            pages += 1
            if pages > 50:
                raise ValueError(f"{src}: too many Launchpad pages")
        if problem is None and count != total:
            problem = f"Launchpad returned {count} publications, total_size says {total}"
        if problem is not None:
            out[src] = {"floor": None, "reason": problem}
        elif "Release" not in pockets:
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
           "_comment": "Release floors: an archive-derived estimate of the lowest source version ever published under each "
                       "release's codename (security plan §9.5.12); the client never reports 'no known issue' below its entry floor. Generated by scripts/advisory_floors.py, reviewed, committed. "
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
