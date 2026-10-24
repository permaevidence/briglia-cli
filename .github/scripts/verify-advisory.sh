#!/bin/bash
# Verify a signed advisory list with the COMMITTED public key (stdlib python
# + openssl): used by the publisher to authenticate the previously published
# list (withdrawn-advisory carry, sequence) and to self-check a fresh one.
#
# Usage: verify-advisory.sh <list.sig.json> <expected-pub.pem> [payload-out]
# Prints "VERIFIED keyId=<id>" and writes the payload; any failure exits nonzero.
set -euo pipefail
ENVELOPE="${1:?usage: verify-advisory.sh <list.sig.json> <pub.pem> [payload-out]}"
PUB="${2:?missing expected public key PEM}"
OUTP="${3:-}"
FORMAT="briglia-advisory-envelope-v1"
DOMAIN="briglia-local-tool-advisories-v1"
# shellcheck source=openssl-resolve.sh
. "$(dirname "${BASH_SOURCE[0]}")/openssl-resolve.sh"
resolve_openssl
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SIZE="$(wc -c < "$ENVELOPE")"
[ "$SIZE" -le 368640 ] || { echo "✖ envelope is $SIZE bytes"; exit 1; }
"$OPENSSL" pkey -pubin -in "$PUB" -pubout -outform DER > "$WORK/pub.der"
tail -c 32 "$WORK/pub.der" > "$WORK/pub.raw"
FP="$("$OPENSSL" dgst -sha256 -hex < "$WORK/pub.raw" | awk '{print $NF}')"
EXPECTED_KEYID="briglia-advisories-v1-${FP:0:16}"
python3 - "$ENVELOPE" "$WORK" "$FORMAT" "$DOMAIN" "$EXPECTED_KEYID" <<'PYEOF'
import base64, json, sys
path, work, fmt, domain, keyid = sys.argv[1:6]
try:
    env = json.loads(open(path, "rb").read().decode())
except Exception:
    sys.exit("✖ not JSON")
for f in ("format", "domain", "keyId", "payload", "signature"):
    if not isinstance(env.get(f), str):
        sys.exit(f"✖ field {f} missing")
if env["format"] != fmt or env["domain"] != domain:
    sys.exit("✖ wrong format or domain")
if env["keyId"] != keyid:
    sys.exit("✖ signed by another key")
def b64(s):
    d = base64.b64decode(s, validate=True)
    if base64.b64encode(d).decode() != s:
        sys.exit("✖ non-canonical base64")
    return d
payload, sig = b64(env["payload"]), b64(env["signature"])
if len(sig) != 64 or len(payload) > 262144:
    sys.exit("✖ bad sizes")
open(f"{work}/payload", "wb").write(payload)
open(f"{work}/sig", "wb").write(sig)
open(f"{work}/input", "wb").write(f"{fmt}\0{domain}\0{keyid}\0".encode() + payload)
PYEOF
"$OPENSSL" pkey -pubin -in "$PUB" -out "$WORK/pub.pem"
"$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$WORK/pub.pem" -in "$WORK/input" -sigfile "$WORK/sig" >/dev/null \
    || { echo "✖ bad signature"; exit 1; }
[ -n "$OUTP" ] && cp "$WORK/payload" "$OUTP"
echo "VERIFIED keyId=$EXPECTED_KEYID"
