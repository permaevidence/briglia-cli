#!/bin/bash
# Sign a VALIDATED advisory-list payload (scripts/advisory_publish.py) into
# the advisory envelope (security plan v16 §9.5.3). Separate key, separate
# format and domain-separation string from the release envelopes, so this
# key can never sign a release and a release key can never sign a list.
#
# Usage: sign-advisory.sh <private-key.pem> <payload.json> <out.sig.json>
# Env:   EXPECTED_PUBKEY_PEM  committed expected public key (default:
#                             security/advisory-signing-pubkey.pem); signing
#                             REFUSES when it is missing (key not provisioned)
#                             or when the private key derives another key.
#
# Signature input: "briglia-advisory-envelope-v1\0" + domain + "\0" + keyId
# + "\0" + the EXACT payload bytes. No JSON canonicalization anywhere.
set -euo pipefail

PRIV="${1:?usage: sign-advisory.sh <priv.pem> <payload.json> <out.sig.json>}"
PAYLOAD="${2:?missing payload}"
OUT="${3:?missing output path}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPECTED="${EXPECTED_PUBKEY_PEM:-$ROOT/security/advisory-signing-pubkey.pem}"
FORMAT="briglia-advisory-envelope-v1"
DOMAIN="briglia-local-tool-advisories-v1"

[ -f "$EXPECTED" ] || { echo "✖ $EXPECTED missing: the advisory signing key is not provisioned — refusing"; exit 3; }
[ -f "$PAYLOAD" ] || { echo "✖ payload not found: $PAYLOAD"; exit 1; }
SIZE="$(wc -c < "$PAYLOAD")"
[ "$SIZE" -le 262144 ] || { echo "✖ payload is $SIZE bytes (limit 262144)"; exit 1; }
# The payload must pass the publisher's own validation again here: the
# signer never trusts that an earlier step ran.
python3 "$ROOT/scripts/advisory_publish.py" check "$PAYLOAD" >/dev/null

# shellcheck source=openssl-resolve.sh
. "$(dirname "${BASH_SOURCE[0]}")/openssl-resolve.sh"
resolve_openssl

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$OPENSSL" pkey -in "$PRIV" -pubout -outform DER > "$WORK/derived.der"
"$OPENSSL" pkey -pubin -in "$EXPECTED" -pubout -outform DER > "$WORK/expected.der"
cmp -s "$WORK/derived.der" "$WORK/expected.der" || {
    echo "✖ private key derives a DIFFERENT public key than the committed advisory key — refusing"; exit 1; }
tail -c 32 "$WORK/derived.der" > "$WORK/pub.raw"
FP="$("$OPENSSL" dgst -sha256 -hex < "$WORK/pub.raw" | awk '{print $NF}')"
KEYID="briglia-advisories-v1-${FP:0:16}"

printf '%s\0%s\0%s\0' "$FORMAT" "$DOMAIN" "$KEYID" > "$WORK/input"
cat "$PAYLOAD" >> "$WORK/input"
"$OPENSSL" pkeyutl -sign -rawin -inkey "$PRIV" -in "$WORK/input" -out "$WORK/sig.bin"
"$OPENSSL" pkey -pubin -in "$EXPECTED" -out "$WORK/pub.pem"
"$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$WORK/pub.pem" -in "$WORK/input" -sigfile "$WORK/sig.bin" >/dev/null || {
    echo "✖ self-verification of the fresh signature FAILED — refusing"; exit 1; }

python3 - "$PAYLOAD" "$WORK/sig.bin" "$FORMAT" "$DOMAIN" "$KEYID" "$OUT" <<'PYEOF'
import base64, json, sys
payload_path, sig_path, fmt, domain, key_id, out = sys.argv[1:7]
payload = open(payload_path, "rb").read()
sig = open(sig_path, "rb").read()
assert len(sig) == 64
env = {"format": fmt, "domain": domain, "keyId": key_id,
       "payload": base64.b64encode(payload).decode(), "signature": base64.b64encode(sig).decode()}
with open(out, "w") as f:
    json.dump(env, f, separators=(",", ":"), sort_keys=True)
PYEOF
echo "✔ signed advisory list: $OUT (keyId $KEYID)"
