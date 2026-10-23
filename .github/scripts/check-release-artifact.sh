#!/bin/bash
# Release-artifact checks, run on the EXACT binary that ships (right after
# each platform build in release-signed.yml):
#   1. the development-only engine runner `__migrate-run` refuses in every
#      mode (forward, --rollback, --detect, --doctor, --dump-prefs-domain)
#      with exit 2 and the fixed refusal text — release builds are stamped
#      to a bare SemVer, which is what closes it; the managed-Playwright
#      crash-injection driver (`__playwright-selftest --child-run`) refuses
#      the same way;
#   2. the migration path itself still answers: `migrate --status`,
#      `migrate --dump-spec`, `__migrate-probe`, `__migrate-gate` — the
#      commands the installer and the production migration use — so the
#      gate demonstrably closed only the runner.
# Everything runs in a scratch HOME/XDG tree; nothing on the runner is read
# or written outside it.
set -euo pipefail
BIN="${1:?usage: check-release-artifact.sh <path-to-briglia>}"
[[ -x "$BIN" ]] || { echo "✖ $BIN is not an executable file"; exit 1; }
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH/home"
export XDG_CONFIG_HOME="$SCRATCH/config"
export XDG_DATA_HOME="$SCRATCH/data"
export XDG_STATE_HOME="$SCRATCH/state"
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$TMPDIR"
unset BRIGLIA_MIGRATE_SYSTEMCTL BRIGLIA_MIGRATE_PREFS_DOMAINS BRIGLIA_MIGRATE_SYSTEM_UNIT_DIR \
      BRIGLIA_MIGRATE_CRASH_POINT BRIGLIA_MIGRATE_FAULT BRIGLIA_TOOLCHAIN_BIN || true

REFUSAL="__migrate-run is a development-build command"
fail=0

expect_refusal() {
    local label="$1"; shift
    local out rc
    set +e; out="$("$BIN" "$@" 2>&1)"; rc=$?; set -e
    if [[ $rc -eq 2 && "$out" == *"$REFUSAL"* ]]; then
        echo "✔ $label: refused (exit 2)"
    else
        echo "✖ $label: expected exit 2 + refusal text, got exit $rc:"; echo "$out" | tail -5; fail=1
    fi
}

expect_ok() {
    local label="$1" needle="$2"; shift 2
    local out rc
    set +e; out="$("$BIN" "$@" 2>&1)"; rc=$?; set -e
    if [[ $rc -eq 0 && "$out" == *"$needle"* ]]; then
        echo "✔ $label: exit 0, answers"
    else
        echo "✖ $label: expected exit 0 containing '$needle', got exit $rc:"; echo "$out" | tail -8; fail=1
    fi
}

echo "— release-artifact checks on $BIN ($("$BIN" --version 2>/dev/null | head -1)) —"
VERSION_LINE="$("$BIN" --version 2>/dev/null | head -1)"
if [[ "$VERSION_LINE" == *-dev* ]]; then
    echo "✖ the binary reports a -dev version ($VERSION_LINE) — the release stamp did not apply"; fail=1
fi

# 1. Every mode of the development-only runner refuses.
expect_refusal "__migrate-run --spec"              __migrate-run --spec /dev/null
expect_refusal "__migrate-run --spec --rollback"   __migrate-run --spec /dev/null --rollback
expect_refusal "__migrate-run --rollback (no spec)" __migrate-run --rollback
expect_refusal "__migrate-run --detect"            __migrate-run --spec /dev/null --detect
expect_refusal "__migrate-run --doctor"            __migrate-run --spec /dev/null --doctor
expect_refusal "__migrate-run --dump-prefs-domain" __migrate-run --dump-prefs-domain briglia-release-artifact-check

# 1b. The managed-Playwright crash-injection driver (Release C) refuses too.
set +e; out="$("$BIN" __playwright-selftest --child-run /dev/null 2>&1)"; rc=$?; set -e
if [[ $rc -eq 2 && "$out" == *"__playwright-selftest --child-run is a development-build command"* ]]; then
    echo "✔ __playwright-selftest --child-run: refused (exit 2)"
else
    echo "✖ __playwright-selftest --child-run: expected exit 2 + refusal text, got exit $rc:"; echo "$out" | tail -5; fail=1
fi

# 1c. The update-notice development drivers (security plan v8 Phase 2) refuse:
#     they would otherwise run a check/send against an arbitrary channel.
for cmd in "__update-check-once" "__update-notice-send-once" "__release-security-parse /dev/null"; do
    # shellcheck disable=SC2086
    set +e; out="$("$BIN" $cmd 2>&1)"; rc=$?; set -e
    name="${cmd%% *}"
    if [[ $rc -eq 2 && "$out" == *"$name is a development-build command"* ]]; then
        echo "✔ $name: refused (exit 2)"
    else
        echo "✖ $name: expected exit 2 + refusal text, got exit $rc:"; echo "$out" | tail -5; fail=1
    fi
done

# 2. The migration path stays open on a clean scratch HOME.
expect_ok "migrate --status"    "not needed"  migrate --status
expect_ok "migrate --dump-spec" "healthProbe" migrate --dump-spec
mkdir -p "$XDG_CONFIG_HOME/briglia" "$XDG_DATA_HOME/briglia"
expect_ok "__migrate-probe"     "PROBE-OK"    __migrate-probe
expect_ok "__migrate-gate"      "GATE-OK"     __migrate-gate

if [[ $fail -ne 0 ]]; then
    echo "✖ release-artifact checks FAILED"; exit 1
fi
echo "✔ release-artifact checks passed"
