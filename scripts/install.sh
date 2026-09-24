#!/bin/bash
# Build Briglia CLI in release mode and install the `briglia` command.
# Usage: ./scripts/install.sh            → installs to ~/.local/bin (no sudo;
#                                          /usr/local/bin when run as root)
#        BRIGLIA_INSTALL_DIR=/some/bin ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
    echo "✖ Swift toolchain not found."
    case "$(uname -s)" in
        Darwin) echo "  Install Xcode or the Command Line Tools: xcode-select --install" ;;
        Linux)  echo "  Install Swift 6+ via swiftly (recommended): https://www.swift.org/install/linux/"
                echo "  e.g. curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz && tar xzf swiftly-*.tar.gz && ./swiftly init" ;;
    esac
    exit 1
fi

echo "Building Briglia CLI (release)…"
swift build -c release

BIN=".build/release/briglia"
# SwiftPM puts bundled resources (skills, WhatsApp bridge, toolchain scripts)
# in a separate artifact that MUST travel with the binary — without it the
# installed executable traps (exit 133) on first resource access. The
# artifact name is platform-specific: .bundle on macOS, .resources on Linux.
case "$(uname -s)" in
    Darwin) BUNDLE_NAME="briglia-cli_briglia.bundle" ;;
    *)      BUNDLE_NAME="briglia-cli_briglia.resources" ;;
esac
BUNDLE=".build/release/$BUNDLE_NAME"
if [ ! -d "$BUNDLE" ]; then
    echo "✖ build output missing $BUNDLE — SwiftPM layout changed?"
    exit 1
fi
# User-writable default: Briglia self-updates (remote /upgrade from Telegram),
# and a root-owned install would make every upgrade need a sudo password.
if [ -n "${BRIGLIA_INSTALL_DIR:-}" ]; then
    DEST_DIR="$BRIGLIA_INSTALL_DIR"
elif [ "$(id -u)" = "0" ]; then
    DEST_DIR="/usr/local/bin"
else
    DEST_DIR="$HOME/.local/bin"
fi
mkdir -p "$DEST_DIR" 2>/dev/null || true

if [ -w "$DEST_DIR" ]; then
    cp "$BIN" "$DEST_DIR/briglia"
    rm -rf "${DEST_DIR:?}/$BUNDLE_NAME"
    cp -R "$BUNDLE" "$DEST_DIR/$BUNDLE_NAME"
else
    echo "Installing to $DEST_DIR (may ask for your password)…"
    sudo cp "$BIN" "$DEST_DIR/briglia"
    sudo rm -rf "${DEST_DIR:?}/$BUNDLE_NAME"
    sudo cp -R "$BUNDLE" "$DEST_DIR/$BUNDLE_NAME"
fi

echo "Installed: $DEST_DIR/briglia"
"$DEST_DIR/briglia" --version
# Smoke-test the INSTALLED copy from a neutral cwd so it cannot lean on the
# build directory: verifies the resource bundle deployed correctly.
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
case ":$PATH:" in
    *":$DEST_DIR:"*) ;;
    *) echo "⚠ $DEST_DIR is not in your PATH — add it to your shell profile." ;;
esac
if [ "$MIGRATED" != "1" ] && [ "$MIGRATE_STATE" = "0" ]; then
    echo
    echo "Next: briglia menu    (set up Briglia in your browser: ChatGPT, OpenCode, OpenRouter or a local model)"
    echo "  or: briglia setup   (the step-by-step wizard in the terminal)"
fi
