#!/bin/bash
# Assemble the release manifest (the bytes that get SIGNED) from the built
# tarballs in dist/. Deterministic given identical inputs and PUBLISHED_AT.
#
# Usage: build-manifest.sh <version> <sequence> <out-manifest.json>
# Env:   RELEASE_REPO   owner/repo the asset URLs point at (default
#                       permaevidence/briglia-cli; staging overrides)
#        PUBLISHED_AT   ISO8601 override for reproducibility tests
#        EXPIRES_DAYS   metadata validity window (default 180, plan §5.2)
#        SECURITY_FRAGMENT  optional JSON from `release_security.py emit`:
#                       its `security` / `componentAdvisories` keys are added
#                       to the signed manifest (security plan v8 §4)
set -euo pipefail

VERSION="${1#v}"; VERSION="${VERSION:?usage: build-manifest.sh <version> <sequence> <out>}"
SEQUENCE="${2:?missing sequence}"
OUT="${3:?missing output path}"
REPO="${RELEASE_REPO:-permaevidence/briglia-cli}"
DAYS="${EXPIRES_DAYS:-180}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✖ '$VERSION' is not exact SemVer"; exit 1; }
[[ "$SEQUENCE" =~ ^[1-9][0-9]*$ ]] || { echo "✖ '$SEQUENCE' is not a positive integer"; exit 1; }

shopt -s nullglob
TARBALLS=(dist/briglia-*.tar.gz)
[ "${#TARBALLS[@]}" -gt 0 ] || { echo "✖ no tarballs found in dist/"; exit 1; }

python3 - "$VERSION" "$SEQUENCE" "$REPO" "$DAYS" "$OUT" "${TARBALLS[@]}" <<'PYEOF'
import datetime, hashlib, json, os, sys
version, sequence, repo, days, out = sys.argv[1:6]
tarballs = sys.argv[6:]
published = os.environ.get("PUBLISHED_AT")
if published:
    published_dt = datetime.datetime.fromisoformat(published.replace("Z", "+00:00"))
else:
    published_dt = datetime.datetime.now(datetime.timezone.utc)
expires_dt = published_dt + datetime.timedelta(days=int(days))
def iso(dt):
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
platforms = {}
for path in sorted(tarballs):
    name = os.path.basename(path)
    platform = name[len("briglia-"):-len(".tar.gz")]
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    platforms[platform] = {
        "url": f"https://github.com/{repo}/releases/download/v{version}/{name}",
        "sha256": digest.hexdigest(),
        "size": os.path.getsize(path),
    }
manifest = {
    "schema": 1,
    "channel": "briglia-cli",
    "sequence": int(sequence),
    "version": version,
    "published": iso(published_dt),
    "expires": iso(expires_dt),
    "platforms": platforms,
}
fragment = os.environ.get("SECURITY_FRAGMENT")
if fragment:
    with open(fragment) as f:
        extra = json.load(f)
    unknown = set(extra) - {"security", "componentAdvisories"}
    if unknown:
        sys.exit(f"✖ security fragment has unexpected keys {sorted(unknown)}")
    manifest.update(extra)
with open(out, "w") as f:
    json.dump(manifest, f, separators=(",", ":"), sort_keys=True)
print(f"manifest: v{version} seq {sequence} platforms {sorted(platforms)}")
PYEOF
