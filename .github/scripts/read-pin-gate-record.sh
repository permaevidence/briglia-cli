#!/bin/bash
# Pin-gate record reader for the credential-free authorize job
# (security plan v24 §3.5.2). Writes the body of the promoter's ANNOTATED
# release tag (the `briglia-pin-gate v1` record) to OUT.
#
# Why the re-fetch: actions/checkout (v5) fetches all tags, then fetches
# `+<sha>:refs/tags/<tag>` a second time, which replaces the annotated tag
# in the runner clone with a LIGHTWEIGHT ref to the commit ("t [tag update]").
# Reading refs/tags/<tag> straight after checkout therefore always sees a
# commit, never the tag object (v0.2.63, run 40426023973). So this script
# fetches the remote tag ref itself, by its exact name, into a private ref
# that checkout never writes, and reads that.
#
# Fail-closed: a lightweight tag, a missing tag, a tag that does not peel to
# the tagged commit, or a tag object without a body all refuse (exit 1).
#
# Usage: read-pin-gate-record.sh <tag name> <tagged commit sha> <out file>
# Env (optional): REMOTE (default origin)
set -euo pipefail

TAG="${1:?tag name is required}"
SHA="${2:?tagged commit sha is required}"
OUT="${3:?output file is required}"
REMOTE="${REMOTE:-origin}"

# The caller has already checked the name; re-check here because it is
# placed inside a refspec.
printf '%s' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "✖ tag '$TAG' is not exact SemVer"; exit 1; }
printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$' || {
    echo "✖ '$SHA' is not a full commit SHA"; exit 1; }

PRIV="refs/briglia-pin-gate/$TAG"
git update-ref -d "$PRIV" 2>/dev/null || true
git fetch --no-tags --no-recurse-submodules "$REMOTE" "+refs/tags/$TAG:$PRIV" >/dev/null 2>&1 || {
    echo "✖ $TAG: could not fetch the release tag from $REMOTE"; exit 1; }

[ "$(git cat-file -t "$PRIV")" = "tag" ] || {
    echo "✖ $TAG is not an annotated tag from promote-release.sh (no pin-gate record)"; exit 1; }
[ "$(git rev-parse --verify --quiet "$PRIV^{commit}")" = "$SHA" ] || {
    echo "✖ $TAG does not point at the tagged commit $SHA"; exit 1; }

mkdir -p "$(dirname "$OUT")"
git cat-file tag "$PRIV" | sed '1,/^$/d' > "$OUT"
[ -s "$OUT" ] || { echo "✖ $TAG carries no pin-gate record"; exit 1; }
echo "pin-gate record read from annotated tag $TAG ($(git rev-parse "$PRIV"))"
