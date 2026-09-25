#!/bin/bash
# Public Briglia CLI installer — prebuilt binaries, no GitHub account, no Swift.
#
#   curl -fsSL https://github.com/permaevidence/briglia-cli/releases/latest/download/install.sh | bash
#   wget -qO-  … | bash   (no curl)
#
# Downloads the prebuilt tarball for this OS/arch from the signed GitHub
# release channel and installs `briglia` + its resource bundle.
#
# AUTHENTICATION (docs/RELEASE_SIGNING_PLAN.md §8.2): when this machine has
# python3 and an Ed25519-capable openssl (proven against a LOCAL RFC 8032
# known vector, never against live content), the installer verifies the
# signed release envelope with the embedded public key, then downloads the
# exact version-pinned asset it authenticates, enforcing size and SHA-256.
# Without that capability it falls back to a plainly disclosed TLS bootstrap
# (checksum from the same origin). Either way, the FIRST install trusts the
# origin that served this script; the installed binary's pinned key protects
# every later update.
#
#   BRIGLIA_INSTALL_DIR=/some/bin   install location. Default: ~/.local/bin
#                               (user-writable, so remote /upgrade from
#                               Telegram never needs a sudo password);
#                               /usr/local/bin when running as root.
#   BRIGLIA_RELEASE_BASE=…          alternate releases base (staging/testing)
#
# scripts/get-briglia.sh in the repo is the source of truth; the release
# workflow publishes it as the `install.sh` asset of every release.
set -euo pipefail

RELEASE_BASE="${BRIGLIA_RELEASE_BASE:-https://github.com/permaevidence/briglia-cli/releases}"
# Stamped at the key ceremony (64 hex chars of the raw Ed25519 public key).
# Empty = pre-ceremony build: TLS bootstrap only.
BRIGLIA_RELEASE_PUBKEY_HEX="621031636aa2bb2edb64a58f2f72de7bc3559b08d717c79b4251f8b1e35b8a95" # STAMP-INSTALLER-KEY

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS-$ARCH" in
    Darwin-arm64)           PLATFORM="macos-arm64";  BUNDLE_NAME="briglia-cli_briglia.bundle" ;;
    Darwin-x86_64)
        echo "✖ Intel Macs are not supported yet — Briglia CLI ships for Apple Silicon (M1+)."
        exit 1 ;;
    Linux-x86_64)           PLATFORM="linux-x64";    BUNDLE_NAME="briglia-cli_briglia.resources" ;;
    Linux-aarch64|Linux-arm64) PLATFORM="linux-arm64"; BUNDLE_NAME="briglia-cli_briglia.resources" ;;
    *)
        echo "✖ Unsupported platform: $OS $ARCH"
        exit 1 ;;
esac

# curl when available, wget otherwise (Ubuntu Touch and other minimal
# systems ship wget but no curl — and their tiny read-only root fs makes
# "just apt install curl" a trap, so the installer must not require it).
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fSL --retry 3 -o "$1" "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q -O "$1" "$2"; }
else
    echo "✖ Neither curl nor wget is available — one of them is required."
    exit 1
fi
command -v tar  >/dev/null 2>&1 || { echo "✖ tar is required.";  exit 1; }

# The prebuilt Linux binary statically links the Swift runtime but still
# needs the system's libcurl and libxml2 (Foundation's networking/XML).
if [ "$OS" = "Linux" ]; then
    missing=""
    if command -v ldconfig >/dev/null 2>&1; then
        # grep must read ldconfig to EOF: `grep -q` exits at the first match,
        # ldconfig then dies of SIGPIPE, and under `pipefail` the pipeline
        # reports failure although the library IS installed (false "missing
        # libxml2" seen on a Debian box, 2026-08-22 and 2026-09-01).
        ldconfig -p 2>/dev/null | grep 'libcurl\.so\.4' >/dev/null || missing="$missing libcurl4"
        ldconfig -p 2>/dev/null | grep 'libxml2\.so\.2' >/dev/null || missing="$missing libxml2"
    fi
    if [ -n "$missing" ]; then
        echo "✖ Missing system libraries:$missing"
        if command -v apt-get >/dev/null 2>&1; then
            # On systems with a tiny root filesystem (e.g. Ubuntu Touch's
            # ~3 GB read-only image) `apt update` alone can fill the disk.
            ROOT_FREE_KB="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
            if [ -n "${ROOT_FREE_KB:-}" ] && [ "$ROOT_FREE_KB" -lt 512000 ] 2>/dev/null; then
                echo "  ⚠ Your root filesystem has <500 MB free — 'apt update' may fill it."
                echo "    Clean up afterwards with: sudo rm -rf /var/lib/apt/lists/* && sudo apt-get clean"
            fi
            echo "  Install them with: sudo apt-get install -y$missing"
        elif command -v dnf >/dev/null 2>&1; then
            echo "  Install them with: sudo dnf install -y libcurl libxml2"
        elif command -v pacman >/dev/null 2>&1; then
            echo "  Install them with: sudo pacman -S curl libxml2"
        fi
        echo "  Then re-run this installer."
        exit 1
    fi
fi

TARBALL="briglia-$PLATFORM.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Ed25519-capable openssl: must ACCEPT the RFC 8032 TEST 2 vector and
# REJECT a tampered copy of it. A capability probe over a local known
# vector — a live signature failure is never misread as "unsupported".
probe_openssl() {
    local ossl="$1" d="$TMP/probe"
    rm -rf "$d"; mkdir -p "$d"
    python3 - "$d" <<'PYEOF' || return 1
import sys
d = sys.argv[1]
pub = bytes.fromhex("302a300506032b6570032100"
                    "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
open(d + "/pub.der", "wb").write(pub)
open(d + "/msg", "wb").write(bytes.fromhex("72"))
sig = bytes.fromhex("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                    "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
open(d + "/sig", "wb").write(sig)
bad = bytearray(sig); bad[0] ^= 1
open(d + "/badsig", "wb").write(bytes(bad))
PYEOF
    "$ossl" pkey -pubin -inform DER -in "$d/pub.der" -out "$d/pub.pem" 2>/dev/null || return 1
    "$ossl" pkeyutl -verify -rawin -pubin -inkey "$d/pub.pem" \
        -in "$d/msg" -sigfile "$d/sig" >/dev/null 2>&1 || return 1
    if "$ossl" pkeyutl -verify -rawin -pubin -inkey "$d/pub.pem" \
        -in "$d/msg" -sigfile "$d/badsig" >/dev/null 2>&1; then return 1; fi
    return 0
}

OPENSSL=""
if [ -n "$BRIGLIA_RELEASE_PUBKEY_HEX" ] && command -v python3 >/dev/null 2>&1; then
    for candidate in "${OPENSSL_BIN:-}" openssl \
        /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        [ -n "$candidate" ] || continue
        command -v "$candidate" >/dev/null 2>&1 || continue
        if probe_openssl "$candidate"; then OPENSSL="$candidate"; break; fi
    done
fi

if [ -n "$OPENSSL" ]; then
    echo "Fetching signed release metadata…"
    fetch "$TMP/manifest.sig.json" "$RELEASE_BASE/latest/download/manifest.sig.json"
    ENV_SIZE="$(wc -c < "$TMP/manifest.sig.json" | tr -d ' ')"
    [ "$ENV_SIZE" -le 131072 ] || { echo "✖ envelope is $ENV_SIZE bytes (limit 131072) — refusing."; exit 1; }

    # Strict parse + payload validation in stdlib python; Ed25519 verify in
    # openssl. Everything the download below uses comes from the
    # AUTHENTICATED payload: version-pinned URL, exact size, SHA-256.
    python3 - "$TMP" "$BRIGLIA_RELEASE_PUBKEY_HEX" "$PLATFORM" <<'PYEOF'
import base64, datetime, hashlib, json, sys
tmp, pub_hex, platform = sys.argv[1:4]
raw = open(f"{tmp}/manifest.sig.json", "rb").read()
try:
    env = json.loads(raw.decode("utf-8"))
except Exception:
    sys.exit("ENVELOPE-FAIL: not valid JSON")
if not isinstance(env, dict):
    sys.exit("ENVELOPE-FAIL: not a JSON object")
for field in ("format", "channel", "keyId", "payload", "signature"):
    if not isinstance(env.get(field), str):
        sys.exit(f"ENVELOPE-FAIL: field '{field}' missing")
if env["format"] != "ada-release-envelope-v1":
    sys.exit("ENVELOPE-FAIL: unsupported format")
if env["channel"] != "briglia-cli":
    sys.exit("ENVELOPE-FAIL: wrong channel")
fp = hashlib.sha256(bytes.fromhex(pub_hex)).hexdigest()[:16]
if not (env["keyId"].startswith("briglia-cli-release-v") and env["keyId"].endswith("-" + fp)):
    sys.exit("ENVELOPE-FAIL: keyId does not match the embedded key")
def strict_b64(value, name):
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception:
        sys.exit(f"ENVELOPE-FAIL: '{name}' not valid base64")
    if base64.b64encode(decoded).decode() != value:
        sys.exit(f"ENVELOPE-FAIL: '{name}' not canonical base64")
    return decoded
payload = strict_b64(env["payload"], "payload")
signature = strict_b64(env["signature"], "signature")
if len(payload) > 65536:
    sys.exit("ENVELOPE-FAIL: payload too large")
if len(signature) != 64:
    sys.exit("ENVELOPE-FAIL: signature is not 64 bytes")
open(f"{tmp}/payload", "wb").write(payload)
open(f"{tmp}/sig.bin", "wb").write(signature)
domain = (b"ada-release-envelope-v1\0" + env["channel"].encode() + b"\0"
          + env["keyId"].encode() + b"\0")
open(f"{tmp}/input", "wb").write(domain + payload)
open(f"{tmp}/relpub.der", "wb").write(
    bytes.fromhex("302a300506032b6570032100") + bytes.fromhex(pub_hex))
PYEOF

    "$OPENSSL" pkey -pubin -inform DER -in "$TMP/relpub.der" -out "$TMP/relpub.pem" 2>/dev/null
    if ! "$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$TMP/relpub.pem" \
        -in "$TMP/input" -sigfile "$TMP/sig.bin" >/dev/null 2>&1; then
        echo "✖ RELEASE SIGNATURE VERIFICATION FAILED — the release channel does not"
        echo "  match Briglia's pinned key. NOT installing. If this persists, check"
        echo "  https://github.com/permaevidence/briglia-cli/releases directly."
        exit 1
    fi

    # Written to a file first: heredocs INSIDE $(…) trip bash 3.2's naive
    # substitution scanner (apostrophes/parens in the body are miscounted).
    cat > "$TMP/manifest_check.py" <<'PYEOF'
import datetime, json, sys
tmp, platform, release_base = sys.argv[1:4]
manifest = json.loads(open(f"{tmp}/payload", "rb").read())
if manifest.get("schema") != 1 or manifest.get("channel") != "briglia-cli":
    sys.exit("MANIFEST-FAIL: wrong schema/channel")
version = manifest.get("version", "")
import re
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    sys.exit("MANIFEST-FAIL: bad version")
def parse(ts):
    return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
if parse(manifest["expires"]) <= now:
    sys.exit("MANIFEST-FAIL: metadata expired — stale or frozen channel")
if parse(manifest["published"]) > now + datetime.timedelta(hours=24):
    sys.exit("MANIFEST-FAIL: published in the future — check this machine's clock")
entry = manifest.get("platforms", {}).get(platform)
if not entry:
    sys.exit(f"MANIFEST-FAIL: no build for {platform}")
# Default: the canonical repo's version-pinned asset path. An overridden
# RELEASE_BASE (staging/testing) moves the prefix with it — safety still
# rests on the authenticated size + SHA-256 below, the prefix is
# defense-in-depth for the default install.
prefix = f"{release_base}/download/v{version}/"
url = entry.get("url", "")
if not url.startswith(prefix) or "/" in url[len(prefix):] or ".." in url:
    sys.exit("MANIFEST-FAIL: asset URL outside the pinned release location")
sha = entry.get("sha256", "")
if not re.fullmatch(r"[0-9a-f]{64}", sha):
    sys.exit("MANIFEST-FAIL: bad sha256")
size = entry.get("size", 0)
# 2 GiB ceiling (written as a literal: "<<" inside $() would be parsed
# as a shell heredoc operator by bash)
if not (isinstance(size, int) and 0 < size <= 2147483648):
    sys.exit("MANIFEST-FAIL: bad size")
print(version); print(url); print(sha); print(size)
PYEOF
    ASSET_INFO="$(python3 "$TMP/manifest_check.py" "$TMP" "$PLATFORM" "$RELEASE_BASE")"
    VERSION="$(printf '%s\n' "$ASSET_INFO" | sed -n 1p)"
    ASSET_URL="$(printf '%s\n' "$ASSET_INFO" | sed -n 2p)"
    EXPECTED="$(printf '%s\n' "$ASSET_INFO" | sed -n 3p)"
    ASSET_SIZE="$(printf '%s\n' "$ASSET_INFO" | sed -n 4p)"

    echo "✔ signed release metadata verified: Briglia CLI $VERSION"
    echo "Downloading Briglia CLI $VERSION ($PLATFORM)…"
    fetch "$TMP/$TARBALL" "$ASSET_URL"
    GOT_SIZE="$(wc -c < "$TMP/$TARBALL" | tr -d ' ')"
    [ "$GOT_SIZE" = "$ASSET_SIZE" ] || {
        echo "✖ downloaded $GOT_SIZE bytes, manifest authenticates $ASSET_SIZE — aborting."; exit 1; }
    ACTUAL="$(sha256_of "$TMP/$TARBALL")"
    [ "$EXPECTED" = "$ACTUAL" ] || {
        echo "✖ checksum mismatch against the SIGNED manifest — aborting."; exit 1; }
else
    if [ -n "$BRIGLIA_RELEASE_PUBKEY_HEX" ]; then
        echo "⚠ This system lacks python3 or an Ed25519-capable openssl, so the release"
        echo "  signature CANNOT be verified here. Proceeding over HTTPS/TLS only —"
        echo "  first-install authenticity rests on the TLS connection to github.com."
    else
        echo "⚠ Pre-release installer build without an embedded release key —"
        echo "  installing over HTTPS/TLS only."
    fi
    echo "Downloading Briglia CLI ($PLATFORM)…"
    fetch "$TMP/$TARBALL"        "$RELEASE_BASE/latest/download/$TARBALL"
    fetch "$TMP/$TARBALL.sha256" "$RELEASE_BASE/latest/download/$TARBALL.sha256"
    echo "Verifying checksum…"
    EXPECTED="$(awk '{print $1}' "$TMP/$TARBALL.sha256")"
    ACTUAL="$(sha256_of "$TMP/$TARBALL")"
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "✖ Checksum mismatch — download corrupted or tampered with. Aborting."
        exit 1
    fi
fi

tar -xzf "$TMP/$TARBALL" -C "$TMP"
[ -f "$TMP/briglia" ] && [ -d "$TMP/$BUNDLE_NAME" ] || {
    echo "✖ Unexpected tarball layout — expected briglia + $BUNDLE_NAME."
    exit 1
}

# Default to a user-writable location: Briglia self-updates (remote /upgrade
# from Telegram), and a root-owned install would make every upgrade need a
# sudo password typed at a real keyboard. Root installs keep /usr/local/bin.
if [ -n "${BRIGLIA_INSTALL_DIR:-}" ]; then
    DEST_DIR="$BRIGLIA_INSTALL_DIR"
elif [ "$(id -u)" = "0" ]; then
    DEST_DIR="/usr/local/bin"
else
    DEST_DIR="$HOME/.local/bin"
fi

# A leftover root-owned install would shadow the new one in most PATHs.
if [ "$DEST_DIR" != "/usr/local/bin" ] && [ -e "/usr/local/bin/briglia" ]; then
    echo "⚠ An older Briglia install exists at /usr/local/bin/briglia and may shadow this one."
    echo "  Remove it with:  sudo rm -rf /usr/local/bin/briglia /usr/local/bin/$BUNDLE_NAME"
fi

mkdir -p "$DEST_DIR" 2>/dev/null || true
if [ -w "$DEST_DIR" ]; then
    SUDO=""
else
    echo "Installing to $DEST_DIR (may ask for your password)…"
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        sudo mkdir -p "$DEST_DIR"
    else
        echo "✖ $DEST_DIR is not writable and sudo is unavailable."
        echo "  Re-run with: BRIGLIA_INSTALL_DIR=\$HOME/.local/bin"
        exit 1
    fi
fi
$SUDO install -m 755 "$TMP/briglia" "$DEST_DIR/briglia"
$SUDO rm -rf "${DEST_DIR:?}/$BUNDLE_NAME"
$SUDO cp -R "$TMP/$BUNDLE_NAME" "$DEST_DIR/$BUNDLE_NAME"

echo "Installed: $DEST_DIR/briglia"
"$DEST_DIR/briglia" --version
# Smoke-test the installed copy from a neutral cwd (catches a missing bundle).
(cd / && "$DEST_DIR/briglia" bundle-check)

# Explicit post-install identity migration (RENAME_PLAN §4.2). This is the
# ONLY step that moves an existing Ada CLI install's roots to Briglia —
# --version and bundle-check above never do. `briglia migrate` journals
# every step and restores the old install if it cannot complete; it is
# safe to rerun.
# The binary is the single source of truth for the state (exit 0 = nothing
# to do, 3 = migration pending, 4 = old AND new roots coexist — a conflict
# the user resolves by hand; this script never guesses from directories).
MIGRATED=0
MIGRATE_STATE=0
"$DEST_DIR/briglia" migrate --status >/dev/null 2>&1 || MIGRATE_STATE=$?
case "$MIGRATE_STATE" in
    0) ;;
    3)
        echo
        echo "An Ada CLI installation was found — migrating it to Briglia"
        echo "(configuration, memory, watchers, service; nothing is deleted)…"
        if "$DEST_DIR/briglia" migrate; then
            MIGRATED=1
        else
            echo "⚠ The migration did not complete. Your Ada CLI install is untouched;"
            echo "  run:  $DEST_DIR/briglia migrate   to retry (or --rollback)."
        fi
        ;;
    4)
        echo
        echo "⚠ CONFLICT: an Ada CLI installation AND Briglia directories both exist."
        echo "  Nothing was migrated, and Briglia will not run on the Ada data until you resolve it:"
        "$DEST_DIR/briglia" migrate --status || true
        echo "  Move the Briglia directories aside (or remove the old Ada ones), then run:"
        echo "      $DEST_DIR/briglia migrate"
        ;;
    *)
        echo "⚠ Could not determine the migration state (briglia migrate --status exited $MIGRATE_STATE);"
        echo "  run:  $DEST_DIR/briglia migrate --status"
        ;;
esac

ON_PATH=1
PATH_WIRED=""
case ":$PATH:" in
    *":$DEST_DIR:"*) ;;
    *)
        ON_PATH=0
        # For the default user dir, wire up PATH automatically so `briglia` just
        # works in the next terminal. Custom dirs stay the user's business.
        if [ "$DEST_DIR" = "$HOME/.local/bin" ]; then
            PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
            case "${SHELL:-}" in
                */zsh)  RC_FILES="$HOME/.zshrc" ;;
                # bash: interactive terminals read .bashrc, but LOGIN shells
                # (Ubuntu Touch's Terminal app, ssh) read .profile instead —
                # wire both so a new terminal works on every setup.
                *)      RC_FILES="$HOME/.bashrc $HOME/.profile" ;;
            esac
            WROTE=""
            for RC_FILE in $RC_FILES; do
                if [ -f "$RC_FILE" ] && grep -qF '.local/bin' "$RC_FILE"; then
                    WROTE="$WROTE $RC_FILE"
                elif printf '\n%s\n' "$PATH_LINE" >> "$RC_FILE" 2>/dev/null; then
                    WROTE="$WROTE $RC_FILE"
                fi
            done
            if [ -n "$WROTE" ]; then
                echo "PATH configured in:$WROTE — new terminals will find \`briglia\`."
                PATH_WIRED="$WROTE"
            else
                echo "⚠ $DEST_DIR is not in your PATH — add this line to your shell profile:"
                echo "    $PATH_LINE"
            fi
        else
            echo "⚠ $DEST_DIR is not in your PATH — add it to your shell profile."
        fi
        ;;
esac
echo
# >>> next-step (scripts/installer_next_step_test.py runs this block alone)
# Always end with a command that works VERBATIM in this very terminal:
# a piped installer cannot export PATH into the parent shell, so `briglia`
# alone would fail right now even when future terminals are fine.
# Desktops open the browser menu; phones use the Briglia app, headless
# machines the terminal wizard.
NEXT="setup"
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ "$(uname -s)" = "Darwin" ]; then
    # Ubuntu Touch (a Lomiri session) sets up through the Briglia app.
    [ -z "${SSH_CONNECTION:-}" ] && [ ! -e /etc/system-image ] && [ ! -e /usr/bin/lomiri-session ] && NEXT="menu"
fi
[ "$MIGRATED" = "1" ] && NEXT=""
if [ "$MIGRATE_STATE" = "4" ]; then
    # A conflict was reported above: `briglia setup` would only refuse.
    echo "✔ Briglia CLI is installed, but it will not run until the conflict above is resolved."
    echo "  Move the Briglia directories aside (or remove the old Ada ones), then run:"
    echo
    echo "    $DEST_DIR/briglia migrate"
    echo
elif [ "$ON_PATH" = "1" ]; then
    echo "✔ Briglia CLI is installed. Next step:  briglia${NEXT:+ $NEXT}"
elif [ "$NEXT" = "menu" ] && [ -n "$PATH_WIRED" ]; then
    # Desktop, PATH just wired into the shell profile: the plain command
    # only works in a NEW window, which is what non-technical users need
    # to hear; the full path still works right here.
    if [ "$(uname -s)" = "Darwin" ]; then NEW_WINDOW_KEYS="⌘N"; else NEW_WINDOW_KEYS="Ctrl+Alt+T"; fi
    echo "✔ Briglia CLI is installed. Next step:"
    echo "  close this Terminal window, open a new one ($NEW_WINDOW_KEYS) and type:"
    echo
    echo "    briglia menu"
    echo
    echo "  (or run it right here with the full path:  $DEST_DIR/briglia menu)"
else
    echo "✔ Briglia CLI is installed. Next step (copy-paste exactly):"
    echo
    echo "    $DEST_DIR/briglia${NEXT:+ $NEXT}"
    echo
    echo "  (plain \`briglia\` works in new terminals from now on)"
fi
# <<< next-step
