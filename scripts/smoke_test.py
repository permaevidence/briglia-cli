#!/usr/bin/env python3
"""Briglia CLI smoke test — runs on macOS and Linux (CI runs both).

Usage: python3 scripts/smoke_test.py [path/to/briglia]

Checks, in order:
  1. `briglia --version` prints the version string
  2. `briglia doctor` on a pristine home: exits 1, prints all report sections
  3. `briglia media-selftest`: the cross-platform PDF/image pipeline is healthy
     (poppler/ImageMagick on Linux, PDFKit/ImageIO on macOS)
  4. `briglia bundle-check`: passes next to the build bundle; a binary copied
     WITHOUT the resource bundle fails with a readable error (not SIGTRAP)
  5. A real chat session against a local mock OpenAI-compatible server:
     chat turn, single-instance lock, /hide privacy mode, quoted /attach
  6. Setup wizard interruption: an interrupted first run (the Full Disk
     Access terminal-relaunch shape) saves its progress, offers to resume
     at the interrupted step, and never forces re-entering saved values
  7. /upgrade from chat against a mock release CDN: download, checksum
     verify, in-place swap, exec self-restart (instance lock released
     across exec), post-restart confirmation, downgrade refusal,
     corrupt-build rejection, and a mid-swap fault injection proving
     rollback restores both components
  8. Telegram poller against a mock Bot API: same-batch and cross-batch
     duplicate updates dropped, offset persisted across restart (no
     re-delivery, polling resumes at the right offset), and the
     documented week-of-silence id reset adopted instead of dropped
  9. `briglia __setsid-exec` trampoline (every bash tool child runs through
     it): a child given a real controlling pty ends up with NO
     controlling terminal — so sudo-style /dev/tty password prompts fail
     fast instead of writing `Password:` into Briglia's own terminal and
     blocking the turn — and exit codes pass through unchanged
 10. TerminalHandoff (the trampoline's inverse, for wizard/upgrade
     children that MUST prompt on the terminal — sudo, apt): a
     Foundation-spawned child lands in a background process group, so
     its tty read would SIGTTIN-freeze without the foreground handoff
"""

import json
import os
import pty
import re
import select
import shutil
import stat
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADA = sys.argv[1] if len(sys.argv) > 1 else ".build/debug/briglia"
# Repo root for selftests that scan the source tree (midturn invariant scan).
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The binary's embedded release sequence (its anti-rollback floor). Mock
# release channels must use sequences RELATIVE to it: release-prep commits
# bump the constant, and the staging pipeline stamps it, so hardcoded
# fixture sequences go red exactly when a release is being cut.
def _source_release_sequence():
    try:
        src = open(os.path.join(REPO_ROOT, "TelegramConcierge", "CLI", "ReleaseSigning.swift")).read()
        return int(re.search(r"^let adaCLIReleaseSequence = (\d+)$", src, re.M).group(1))
    except Exception:
        return 58
BASE_SEQ = _source_release_sequence()
MOCK_REPLY = "Hello from the mock model! Smoke test says hi."

passed = 0
failed = 0


def check(label, ok, detail=""):
    global passed, failed
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f" — {detail}" if detail and not ok else ""))
    if ok:
        passed += 1
    else:
        failed += 1


def run_selftest(*args, **kwargs):
    """Retain the complete failed suite in CI logs, including timeout output."""
    def emit(stdout, stderr):
        for name, value in (("stdout", stdout), ("stderr", stderr)):
            if isinstance(value, bytes):
                value = value.decode("utf-8", errors="replace")
            if value:
                print("\nFAILED SELFTEST " + name + ":\n" + value, flush=True)
    try:
        result = subprocess.run(*args, **kwargs)
    except subprocess.TimeoutExpired as exc:
        emit(exc.stdout, exc.stderr)
        raise
    if result.returncode != 0:
        emit(result.stdout, result.stderr)
    return result


def isolated_env(home):
    env = dict(os.environ)
    env["HOME"] = home
    env["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
    env["XDG_DATA_HOME"] = os.path.join(home, ".local", "share")
    return env


class MockOpenAIHandler(BaseHTTPRequestHandler):
    # HTTP/1.1 + Content-Length: FoundationNetworking on Linux mishandles
    # HTTP/1.0 close-per-request at high request rates (hangs + duplicate
    # sends); proper keep-alive removes the ambiguity.
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        _ = self.rfile.read(length)
        body = json.dumps({
            "id": "gen-smoke-1",
            "object": "chat.completion",
            "model": "mock-model",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": MOCK_REPLY},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 12, "total_tokens": 22},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


TEST_PREFS_PREFIXES = ("ada-mig-probe-", "ada-mig-st-", "ada-setup-api-selftest-", "briglia-s4-")


def _test_prefs_domains_since(t0):
    """macOS only: throwaway UserDefaults domains the selftests create must
    not accumulate in ~/Library/Preferences (each leaked one is a 42-byte
    empty plist cfprefsd leaves behind unless the test purges it). Returns
    the matching files written at or after `t0` — a stale shell from an
    earlier run (cleaned by the selftests' own stale sweep) is not this
    run's leak, and an older leak must not mask a new one."""
    if sys.platform != "darwin":
        return None
    prefs = os.path.expanduser("~/Library/Preferences")
    try:
        names = os.listdir(prefs)
    except OSError:
        return None
    out = []
    for n in names:
        if not n.startswith(TEST_PREFS_PREFIXES):
            continue
        try:
            if os.stat(os.path.join(prefs, n)).st_mtime >= t0 - 1:
                out.append(n)
        except OSError:
            pass
    return out


def main():
    print(f"Briglia binary: {ADA}")
    smoke_started_at = time.time()

    # 1. --version
    result = subprocess.run([ADA, "--version"], capture_output=True, text=True, timeout=60)
    check("--version", result.returncode == 0 and result.stdout.strip() != "",
          f"rc={result.returncode} out={result.stdout!r}")

    # 2. doctor on a pristine home
    with tempfile.TemporaryDirectory() as home:
        env = isolated_env(home)
        result = subprocess.run([ADA, "doctor"], capture_output=True, text=True,
                                timeout=180, env=env)
        sections_ok = all(s in result.stdout for s in ["Configuration", "Permissions", "Toolchain"])
        check("doctor: prints all sections", sections_ok, result.stdout[-500:])
        check("doctor: unconfigured exits 1", result.returncode == 1,
              f"rc={result.returncode}")
        # A data root that is a symlink to a directory elsewhere: doctor
        # must report the wide entries behind the link, not "healthy".
        moved = os.path.join(home, "moved-data", "briglia")
        os.makedirs(moved, exist_ok=True)
        os.chmod(moved, 0o755)
        with open(os.path.join(moved, "conversation.json"), "w") as f:
            f.write("[]")
        os.chmod(os.path.join(moved, "conversation.json"), 0o644)
        link_root = os.path.join(home, ".local", "share", "briglia")
        os.makedirs(os.path.dirname(link_root), exist_ok=True)
        os.symlink(moved, link_root)
        result = subprocess.run([ADA, "doctor"], capture_output=True, text=True,
                                timeout=180, env=env)
        check("doctor: reports wide entries behind a symlinked data root",
              "with group/other bits" in result.stdout and "conversation.json" in result.stdout,
              result.stdout[-800:])
        # A data root that exists as a regular file: an error, not "healthy".
        os.remove(link_root)
        with open(link_root, "w") as f:
            f.write("not a directory")
        result = subprocess.run([ADA, "doctor"], capture_output=True, text=True,
                                timeout=180, env=env)
        check("doctor: a data root that is a regular file is reported as an error",
              "not a directory" in result.stdout and "✖ entries under the roots" in result.stdout,
              result.stdout[-800:])
        # Every mutating entry point goes through the shared gate: with the
        # data root as a regular file, then as a FIFO, `trigger` must refuse
        # on the storage root (exit 2) before looking at its arguments, and
        # `__migrate-gate` must refuse too.
        for kind in ("file", "fifo"):
            if kind == "fifo":
                os.remove(link_root)
                os.mkfifo(link_root)
            result = subprocess.run([ADA, "trigger", "not-a-uuid", "x"], capture_output=True,
                                    text=True, timeout=60, env=env)
            check(f"gate: `trigger` refuses a data root that is a {kind} (exit 2, names the storage root)",
                  result.returncode == 2 and "Storage root cannot be used" in (result.stdout + result.stderr)
                  and "not-a-uuid" not in (result.stdout + result.stderr),
                  f"rc={result.returncode} out={(result.stdout + result.stderr)[-500:]!r}")
            result = subprocess.run([ADA, "__migrate-gate"], capture_output=True,
                                    text=True, timeout=60, env=env)
            check(f"gate: `__migrate-gate` refuses a data root that is a {kind}",
                  result.returncode != 0 and "Storage root cannot be used" in (result.stdout + result.stderr),
                  f"rc={result.returncode} out={(result.stdout + result.stderr)[-500:]!r}")
        os.remove(link_root)

    # 3. media pipeline
    result = run_selftest([ADA, "media-selftest"], capture_output=True, text=True, timeout=300)
    check("media-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-800:])

    # 3b. streaming bash output pipeline: pipe back-pressure, orphan writers,
    # split UTF-8/secrets, spill integrity, timeouts. The 300s ceiling is
    # generous — the suite itself proves the deadlock fix by finishing in
    # seconds where the old implementation burned a 120s timeout per big test.
    try:
        result = run_selftest([ADA, "__bash-pipeline-selftest"], capture_output=True, text=True, timeout=300)
        check("bash-pipeline-selftest", result.returncode == 0,
              (result.stdout + result.stderr)[-1500:])
    except subprocess.TimeoutExpired as e:
        # The selftest line-buffers and has its own 240s watchdog, so the
        # partial output pinpoints the hang. Never let this kill the suite.
        partial = ((e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")) + \
                  ((e.stderr or b"").decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or ""))
        check("bash-pipeline-selftest", False,
              "TIMEOUT after 300s; partial output:\n" + partial[-1500:])

    # 3b2. bash payload goldens (BASH_V2_PLAN Phase 0): the exact JSON
    # contract of every bash/bash_manage response — key sets, sorted order,
    # static values — frozen before the managed-jobs lifecycle refactor.
    # Any drift here is a compatibility break.
    try:
        result = run_selftest([ADA, "__bash-golden-selftest"], capture_output=True, text=True, timeout=240)
        check("bash-golden-selftest", result.returncode == 0,
              (result.stdout + result.stderr)[-1500:])
    except subprocess.TimeoutExpired as e:
        partial = ((e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")) + \
                  ((e.stderr or b"").decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or ""))
        check("bash-golden-selftest", False,
              "TIMEOUT after 240s; partial output:\n" + partial[-1500:])

    # 3b3. managed bash jobs v2 machinery: completion-acknowledgement
    # receipts (settle → receipt → durable-save-gated withdrawal, stale-UUID
    # safety, idempotence) and receipt exclusion from persisted/encoded JSON.
    result = run_selftest([ADA, "__bash-jobs-selftest"], capture_output=True, text=True, timeout=240)
    check("bash-jobs-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c. external-trigger watcher pipeline: spool intake, leading-edge fire,
    # cooldown queueing, trailing batch, orphan/delete cleanup, batch capping.
    # Self-isolates into a temp XDG_DATA_HOME and shortens the cooldown to 2s.
    result = run_selftest([ADA, "__trigger-selftest"], capture_output=True, text=True, timeout=120)
    check("trigger-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c1a. secret store cross-process durability (field incident
    # 2026-08-29): a warm-cached writer must not revert another process's
    # keys, keys saved externally must be visible without restart, and the
    # sidecar flock must genuinely serialize writers. Isolated XDG roots.
    result = run_selftest([ADA, "__secretstore-selftest"], capture_output=True, text=True, timeout=120)
    check("secretstore-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c1a2. signed release channel (RELEASE_SIGNING_PLAN §11): RFC 8032
    # vectors, envelope/domain/manifest strictness, anti-rollback decisions,
    # trust store, bounded streaming downloads, OpenSSL↔Swift interop
    # through the real keygen + signing scripts (needs the repo-root cwd).
    result = run_selftest([ADA, "__release-signing-selftest"], capture_output=True,
                            text=True, timeout=300, cwd=REPO_ROOT)
    check("release-signing-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c1a3. publisher fault-injection battery (RELEASE_SIGNING_PLAN §11.3):
    # the real check-supersession / publish-release / verify-public-release
    # scripts against a fake Releases API + download host
    # — fail-closed supersession, envelope-last uploads, ambiguous publish, the
    # authenticate-FIRST public verification (forged-binary regression),
    # Blob isolation, and workflow-structure invariants.
    result = subprocess.run([sys.executable, os.path.join(REPO_ROOT, "scripts", "publisher_selftest.py")],
                            capture_output=True, text=True, timeout=600, cwd=REPO_ROOT)
    check("publisher-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c1b. userdata toolchain installer: fake-apt/dpkg-backed prefix
    # install, alternatives-aware wrappers, probe enforcement, cleanup.
    result = run_selftest([ADA, "__toolchain-selftest"], capture_output=True, text=True, timeout=600)
    check("toolchain-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c1c. identity-migration engine (RENAME_PLAN Stage 3): journaled
    # capture/move/fixups/commit transaction with typed preimages and
    # parking, real crash injection after every destructive sub-step,
    # byte-identical rollback, park-restoring rollback, corruption refusal,
    # service-state matrix, preferences-domain copy, diagnostics
    # no-mutation battery. Self-isolates into a temp root + fake systemctl.
    result = run_selftest([ADA, "__migration-selftest"], capture_output=True, text=True, timeout=600)
    combined = result.stdout + result.stderr
    failed_lines = "\n".join(l for l in combined.splitlines() if l.startswith("\u2716"))
    check("migration-selftest", result.returncode == 0,
          (failed_lines[:6000] + "\n---\n" if failed_lines else "") + combined[-1500:])

    # 3c2. watcher triage machinery (WATCHER_TRIAGE_PLAN phase 0-4
    # deterministic layers): durable fire-outbox produce/verdict/ack and
    # crash-window dedup against the spool, per-batch verdict parsing,
    # funnel-counter telemetry + runaway backstop thresholds, triage
    # instruction hash verification, session pinning vs LRU, per-session
    # FIFO run lock. Self-isolates into a temp XDG_DATA_HOME.
    result = run_selftest([ADA, "__watcher-selftest"], capture_output=True, text=True, timeout=180)
    check("watcher-triage-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c3. cheap subagent model lanes (/subagentmodels): per-provider
    # storage, hint resolution, dynamic Agent-tool enum, the loud unset-lane
    # gate, watcher triage_model round-trips, FireRecord lane snapshots and
    # the legacy cheapFast frontmatter mapping. Self-isolates into temp XDG
    # roots.
    result = run_selftest([ADA, "__lane-selftest"], capture_output=True, text=True, timeout=120)
    check("lane-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c4. main-agent provider profiles (/provider): legacy-install
    # migration into per-provider profiles, activation slot copies,
    # per-profile vision restore, /model + /effort mirrors, the loud
    # unconfigured-hop guard and masked-key listings. Self-isolates into
    # temp XDG roots.
    result = run_selftest([ADA, "__provider-selftest"], capture_output=True, text=True, timeout=120)
    check("provider-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c5. Filesystem tool JSON fidelity: tool results show file content with
    # plain slashes (no Foundation \/ escaping the model would copy into
    # old_string), the escape-mismatch hint covers \/, and the read-before-edit
    # error explains the cross-restart ledger reset. Temp-dir isolated.
    result = run_selftest([ADA, "__fstools-selftest"], capture_output=True, text=True, timeout=120)
    check("fstools-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c5-bis. Typed mid-turn annotation hardening (MIDTURN_NONCE_PLAN v2):
    # nonce/validator/neutralizer/renderer goldens, provider wire text,
    # persistence round-trips, adversarial fixtures, fail-closed paths, and
    # the repository no-contiguous-prefix invariant (runs from the repo cwd).
    result = run_selftest([os.path.abspath(ADA), "__midturn-selftest"], capture_output=True,
                            text=True, timeout=120, cwd=REPO_ROOT)
    check("midturn-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    result = run_selftest([ADA, "__prune-archive-selftest"], capture_output=True, text=True, timeout=120)
    check("prune archive selftest", result.returncode == 0, (result.stdout + result.stderr)[-1500:])

    # 3c5-ter. MCP tool surface: server handles, canonical aliases (length,
    # charset, determinism, per-server prefix isolation), escaped
    # descriptions, refused hostile semantic strings, registry-only dispatch
    # for direct calls / tool_search / mcp_call, legacy-name grace via the
    # validated reverse map, and mcp-routing.json / mcp_tools migration.
    # Spawns fake stdio MCP servers (python3) under an isolated XDG root.
    result = run_selftest([ADA, "__storage-selftest"], capture_output=True, text=True, timeout=120)
    check("storage selftest (private-by-default modes, symlink policy, sweep)",
          result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # Repository invariant: every write under the storage roots goes through
    # PrivateStorage, or is listed with a reason in the reviewable allowlist.
    scan = subprocess.run([sys.executable, os.path.join(REPO_ROOT, "scripts", "private_storage_scan.py")],
                          capture_output=True, text=True, timeout=60)
    check("private-storage repository scan (writes under the roots are routed or allowlisted)",
          scan.returncode == 0, (scan.stdout + scan.stderr)[-1500:])

    # Session affinity (x-opencode-session / x-session-id): host rule, HMAC
    # derivation, the decorator on the real builders against a local capture
    # server, stability, separation, key change, two-process creation,
    # quarantine, durability seams, wipe, Mind ID replacement, /rotateaffinity.
    result = run_selftest([os.path.abspath(ADA), "__affinity-selftest"], capture_output=True,
                            text=True, timeout=300)
    check("affinity-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    result = run_selftest([os.path.abspath(ADA), "__chat-wire-selftest"], capture_output=True,
                            text=True, timeout=120)
    check("chat-wire-selftest (complete captures, legacy body repeatability)", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    result = run_selftest([os.path.abspath(ADA), "__chat-adapter-selftest"], capture_output=True,
                            text=True, timeout=120)
    check("chat-adapter-selftest (origins, snapshot and retry isolation)", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # HTTP 413 in the shared chat request loop: retried with identical bytes on
    # OpenCode hosts only (six attempts, ~45 s schedule), fatal at once on
    # OpenRouter and custom hosts, generic four-attempt cap unchanged, the
    # mid-turn nonce on every attempt, cancellation during the wait.
    result = run_selftest([os.path.abspath(ADA), "__chat-retry-selftest"], capture_output=True,
                            text=True, timeout=120)
    check("chat-retry-selftest (OpenCode-only 413 retry, other hosts fatal)", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    result = run_selftest([os.path.abspath(ADA), "__responses-selftest"], capture_output=True,
                            text=True, timeout=120)
    check("responses-selftest (codec, stream, replay and native/fallback media)", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    result = run_selftest([os.path.abspath(ADA), "__responses-cache-selftest"], capture_output=True,
                         text=True, timeout=120)
    check("responses-cache-selftest (routing scope and durable bounded usage)", result.returncode == 0,
          result.stdout + result.stderr)

    result = run_selftest([os.path.abspath(ADA), "__subscription-selftest"], capture_output=True,
                            text=True, timeout=120)
    check("subscription-selftest (OAuth, refresh concurrency and endpoint isolation)", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # Repository invariant: every URLRequest to a model endpoint is decorated
    # by SessionAffinity in the same function, or allowlisted with a reason.
    scan = subprocess.run([sys.executable, os.path.join(REPO_ROOT, "scripts", "model_request_scan.py")],
                          capture_output=True, text=True, timeout=60)
    check("model-request repository scan (every model request site is decorated or allowlisted)",
          scan.returncode == 0, (scan.stdout + scan.stderr)[-1500:])

    result = run_selftest([os.path.abspath(ADA), "__mcp-surface-selftest"], capture_output=True,
                            text=True, timeout=300)
    check("mcp-surface-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c6. /deleteuserdata confirmation barrier: bare command teaches, only
    # the stored name (or CONFIRM when none) wipes, everything else refuses.
    # Isolated config root — never touches a real secrets.json.
    # Managed Playwright (Release C): fake node/npm/server battery — install
    # transaction, reuse, quarantine, failures, timeout + process group,
    # lock, orphans, external edits, profile bundle, registry reload, crash
    # injection at five boundaries (development builds).
    result = run_selftest([os.path.abspath(ADA), "__playwright-selftest"], capture_output=True,
                            text=True, timeout=600)
    check("playwright-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-2500:])
    # Live: the real bootstrap (bundled lockfile, real npm ci, real handshake)
    # wherever a usable Node is on PATH (CI installs one; skipped otherwise).
    if shutil.which("node") and shutil.which("npm"):
        result = run_selftest([os.path.abspath(ADA), "__playwright-selftest", "--live"], capture_output=True,
                                text=True, timeout=900)
        check("playwright-selftest --live (real npm ci against the committed lockfile)", result.returncode == 0,
              (result.stdout + result.stderr)[-2500:])
    else:
        print("· playwright-selftest --live skipped (no node/npm on PATH)")

    result = run_selftest([ADA, "__deleteuserdata-selftest"], capture_output=True, text=True, timeout=120)
    check("deleteuserdata-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c6-bis. /exportmind–/importmind arc: pre-import disclosure text,
    # staged read-only validation (junk rejects with all current work
    # intact), quiescence barrier over all three producer classes, the
    # wipe's triage abort, pre-import output discard, and a full
    # export → mutate → apply round trip. XDG-isolated.
    result = run_selftest([ADA, "__mind-selftest"], capture_output=True, text=True, timeout=180)
    check("mind-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c7. Chat command catalog: the Telegram menu stays trimmed to the five
    # everyday commands, /commands lists every public command and none of the
    # power/owner commands, terminal /help derives from the same registry.
    # Telegram inline-keyboard menus: payload codec + bounds, the owner's
    # button policy (OpenCode catalog + ChatGPT four, text-only elsewhere),
    # plain sendMessage body unchanged, callback_query decode, pairing gate,
    # browser-page model pickers in step with the Swift list.
    result = run_selftest([ADA, "__image-tool-selftest"], capture_output=True, text=True, timeout=120)
    check("Image tool models, options, request bodies and spend", result.returncode == 0, result.stdout + result.stderr)

    result = run_selftest([ADA, "__telegram-menu-selftest"], capture_output=True, text=True, timeout=60)
    check("telegram-menu-selftest (inline-keyboard menus for /provider, /model, /effort)", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    result = run_selftest([ADA, "__command-menu-selftest"], capture_output=True, text=True, timeout=60)
    check("command-menu-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c8. /switchbot flow: decision matrix (only confirm-after-discovery
    # cuts over), token-shape gate, one-time code format, tolerant
    # getUpdates parsing, private-human-only code discovery, and the
    # behind-/commands visibility contract. Pure, no storage or network.
    result = run_selftest([ADA, "__botswitch-selftest"], capture_output=True, text=True, timeout=60)
    check("botswitch-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c8b. Telegram transport errors never carry the bot token: every Bot API
    # URLSession failure is rethrown as TelegramError.transport (code +
    # localized description only) — NSURLError's userInfo embeds the full
    # request URL, and the poll-tick diagnostic printed it verbatim during a
    # DNS outage. Unresolvable `.invalid` host, XDG-isolated, no real endpoint.
    result = run_selftest([ADA, "__telegram-transport-selftest"], capture_output=True, text=True, timeout=120)
    check("telegram-transport-selftest (bot token never in rendered transport errors)", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c8c. Parked-reply queue reentrancy: the poll loop's success path and
    # any successful send can both flush while a redelivery is suspended.
    # Pre-fix both took the same item and the second removeFirst() on an
    # empty array trapped the process (mac2 crash, 2026-09-10) after a double
    # delivery. Overlap, mid-flush park, failure stop, capacity trim. Pure.
    result = run_selftest([ADA, "__parked-outbound-selftest"], capture_output=True, text=True, timeout=120)
    check("parked-outbound-selftest (overlapping flushes deliver once, never trap)", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c9. Email/calendar providers: resolution (explicit choice wins, unset
    # falls back to legacy gws-if-installed inference), the manage_calendar
    # tool gate (agentmail only), provider-aware prompt strings (guidance
    # bullet + new-mail envelope hint never name an absent CLI), AgentMail
    # wire parsing/formatting, and the local calendar store roundtrip with
    # short-id resolution. XDG-isolated; provider reads use test seams.
    result = run_selftest([ADA, "__emailcal-selftest"], capture_output=True, text=True, timeout=120)
    check("emailcal-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3c-bis. Web agent plumbing: tool-calling request/response encoding for
    # all three backends, backend resolution (stored choice > OpenAI-key
    # inference > legacy OpenRouter > opencode, plus the live-test process
    # override), Responses API replay fidelity, cap enforcement, cross-round
    # dedup, and strict-schema validity. Pure in-memory.
    result = run_selftest([ADA, "__web-agent-selftest"], capture_output=True, text=True, timeout=120)
    check("web-agent-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3d. `briglia trigger` CLI surface: unknown watcher fails at the caller;
    # a valid external watcher gets a spooled event file.
    with tempfile.TemporaryDirectory() as home:
        env = isolated_env(home)
        result = subprocess.run([ADA, "trigger", "11111111-2222-3333-4444-555555555555", "x"],
                                capture_output=True, text=True, timeout=60, env=env)
        unknown_ok = result.returncode == 1 and "no watcher" in result.stdout
        data_dir = os.path.join(env["XDG_DATA_HOME"], "briglia")
        os.makedirs(data_dir, exist_ok=True)
        wid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        with open(os.path.join(data_dir, "reminders.json"), "w") as f:
            f.write('[{"id":"%s","triggerDate":"4001-01-01T00:00:00Z","prompt":"t",'
                    '"createdAt":"2026-01-01T00:00:00Z","triggered":false,"externalTrigger":true}]' % wid)
        result = subprocess.run([ADA, "trigger", wid, "front", "door"],
                                capture_output=True, text=True, timeout=60, env=env)
        spool = os.path.join(data_dir, "trigger-events")
        event_files = [n for n in os.listdir(spool)] if os.path.isdir(spool) else []
        event_files = [n for n in event_files if n.endswith(".json")]  # ignore .spool.lock
        spooled = result.returncode == 0 and len(event_files) == 1
        payload_ok = False
        if spooled:
            with open(os.path.join(spool, event_files[0])) as f:
                payload_ok = '"front door"' in f.read()
        check("trigger CLI: unknown watcher refused, valid event spooled",
              unknown_ok and spooled and payload_ok,
              f"unknown_ok={unknown_ok} spooled={spooled} payload_ok={payload_ok} out={result.stdout!r}")

    # 3e. Service unit generation + Ubuntu Touch detection (pure checks,
    # both platforms), and the `briglia service` platform gate: real systemd
    # management on Linux, a readable refusal on macOS. On Linux the status
    # subcommand must stay exit-0 with no unit installed AND with no
    # reachable systemd user bus (the CI container case).
    result = run_selftest([ADA, "__service-selftest"], capture_output=True, text=True, timeout=120)
    check("service-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])
    with tempfile.TemporaryDirectory() as home:
        env = isolated_env(home)
        result = subprocess.run([ADA, "service", "status"],
                                capture_output=True, text=True, timeout=60, env=env)
        if sys.platform == "darwin":
            check("service status: macOS refuses readably",
                  result.returncode == 1 and "Linux only" in result.stdout,
                  f"rc={result.returncode} out={result.stdout!r}")
        else:
            check("service status: not-installed is informational (exit 0)",
                  result.returncode == 0 and "not installed" in result.stdout,
                  f"rc={result.returncode} out={result.stdout!r}")
            # install must refuse without Telegram configured (daemon needs it)
            result = subprocess.run([ADA, "service", "install"],
                                    capture_output=True, text=True, timeout=60, env=env)
            check("service install: refuses without Telegram",
                  result.returncode == 1 and "Telegram" in result.stdout,
                  f"rc={result.returncode} out={result.stdout!r}")

    # 3f. setup-api: the machine-readable setup surface for GUI frontends.
    # Selftest covers the contract; the end-to-end
    # checks here prove the real binary keeps stdout pure JSON, applies an
    # offline provider config, reads it back, and fails transport errors
    # with exit 64.
    result = run_selftest([ADA, "__setup-api-selftest"], capture_output=True, text=True, timeout=180)
    check("setup-api-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])

    # 3f2. desktop quick setup: the offline battery (parser, generations,
    # workflow enforcement, job runner + start gate, AgentMail transaction,
    # lease, census, package maps), then the headless end-to-end run of the
    # real binary against a mock provider server with dev stubs.
    result = run_selftest([os.path.abspath(ADA), "__quicksetup-selftest"],
                            capture_output=True, text=True, timeout=600)
    qs_out = result.stdout + result.stderr
    qs_failed = "\n".join(l for l in qs_out.splitlines() if l.startswith("✖") or "FAILED" in l or "threw" in l)
    check("quicksetup-selftest", result.returncode == 0, (qs_failed or qs_out)[-4000:])
    result = subprocess.run([sys.executable, os.path.join(REPO_ROOT, "scripts", "quicksetup_headless_test.py"), os.path.abspath(ADA)],
                            capture_output=True, text=True, timeout=600)
    check("quicksetup headless end-to-end (mock providers, dev stubs)", result.returncode == 0,
          (result.stdout + result.stderr)[-2500:])

    # 3g. companion-app chat socket: the selftest
    # covers rendering rules, the live protocol, privacy withhold/replay,
    # and socket hygiene; poller phase 10 later proves the same wire on a
    # fully configured daemon end-to-end.
    result = run_selftest([ADA, "__chat-socket-selftest"],
                            capture_output=True, text=True, timeout=300)
    check("chat-socket-selftest", result.returncode == 0,
          (result.stdout + result.stderr)[-1500:])
    with tempfile.TemporaryDirectory() as home:
        env = isolated_env(home)
        env["BRIGLIA_IGNORE_LEGACY_SETUP_FLAG"] = "1"
        result = subprocess.run([ADA, "setup-api", "status"], capture_output=True,
                                text=True, timeout=60, env=env)
        try:
            payload = json.loads(result.stdout)
        except ValueError:
            payload = None
        check("setup-api status: pure JSON on stdout, virgin install",
              result.returncode == 0 and payload is not None
              and payload.get("schema") == 2 and payload.get("ok") is True
              and payload.get("setup", {}).get("complete") is False,
              f"rc={result.returncode} out={result.stdout[:300]!r}")
        req = json.dumps({"provider": {"profile": "local", "base_url": "http://localhost:9/v1",
                                       "model": "smoke-model", "text_only": True}})
        result = subprocess.run([ADA, "setup-api", "apply"], input=req, capture_output=True,
                                text=True, timeout=60, env=env)
        try:
            payload = json.loads(result.stdout)
        except ValueError:
            payload = {}
        check("setup-api apply: offline local-provider config accepted",
              result.returncode == 0 and payload.get("ok") is True
              and payload.get("applied") == ["provider"],
              f"rc={result.returncode} out={result.stdout[:300]!r}")
        result = subprocess.run([ADA, "setup-api", "status"], capture_output=True,
                                text=True, timeout=60, env=env)
        try:
            payload = json.loads(result.stdout)
        except ValueError:
            payload = {}
        local = payload.get("providers", {}).get("profiles", {}).get("local", {})
        check("setup-api status: reflects the applied provider",
              payload.get("providers", {}).get("active") == "local"
              and local.get("configured") is True and local.get("model") == "smoke-model",
              f"out={result.stdout[:300]!r}")
        result = subprocess.run([ADA, "setup-api", "apply"], input="not json",
                                capture_output=True, text=True, timeout=60, env=env)
        check("setup-api: malformed stdin exits 64 with a JSON error",
              result.returncode == 64 and '"transport"' in result.stdout,
              f"rc={result.returncode} out={result.stdout[:200]!r}")
        result = subprocess.run([ADA, "setup-api", "status", "sk-oops-on-argv"],
                                capture_output=True, text=True, timeout=60, env=env)
        check("setup-api: argv payload refused (secrets must use stdin)",
              result.returncode == 64 and "stdin" in result.stdout,
              f"rc={result.returncode} out={result.stdout[:200]!r}")

    # 4. bundle-check: healthy next to the build bundle, readable failure without it
    result = subprocess.run([ADA, "bundle-check"], capture_output=True, text=True, timeout=60)
    check("bundle-check: passes next to build bundle", result.returncode == 0,
          result.stdout + result.stderr)
    with tempfile.TemporaryDirectory() as bindir:
        shutil.copy2(ADA, os.path.join(bindir, "briglia"))
        result = subprocess.run([os.path.join(bindir, "briglia"), "bundle-check"],
                                capture_output=True, text=True, timeout=60, cwd="/")
        check("bundle-check: missing bundle fails readably",
              result.returncode == 1 and "resource bundle missing" in result.stdout,
              f"rc={result.returncode} out={result.stdout!r}")

    # 5. mock chat session
    server = ThreadingHTTPServer(("127.0.0.1", 0), MockOpenAIHandler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    home = tempfile.mkdtemp(prefix="ada-smoke-")
    try:
        env = isolated_env(home)
        config_dir = os.path.join(home, ".config", "briglia")
        os.makedirs(config_dir, exist_ok=True)
        secrets = {
            "llm_provider": "openai_compatible",
            "openai_compatible_base_url": f"http://127.0.0.1:{port}/v1",
            "openai_compatible_model": "mock-model",
            "openai_compatible_api_key": "smoke-test-key",
            "openai_compatible_reasoning_effort": "high",
            "assistant_name": "Bree",
            "user_name": "Smoke",
        }
        with open(os.path.join(config_dir, "secrets.json"), "w") as f:
            json.dump(secrets, f)
        os.chmod(os.path.join(config_dir, "secrets.json"), 0o600)

        # Raw-byte reader: the REPL prompt ("› ") is printed WITHOUT a
        # trailing newline, so a line-based reader never sees it and the
        # driver can only sequence on fixed timeouts — which flakes on slow
        # or loaded machines. Reading raw chunks lets every step wait for
        # the prompt to reappear (true idle) before sending the next command.
        proc = subprocess.Popen(
            [ADA], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env=env,
        )
        buf = bytearray()
        lock = threading.Lock()

        def reader():
            while True:
                chunk = proc.stdout.read1(4096)
                if not chunk:
                    break
                with lock:
                    buf.extend(chunk)

        t = threading.Thread(target=reader, daemon=True)
        t.start()

        def output_text():
            with lock:
                return buf.decode("utf-8", errors="replace")

        def output_count(needle):
            return output_text().count(needle)

        def output_reaches(needle, count, timeout_s):
            deadline = time.time() + timeout_s
            while time.time() < deadline:
                if output_count(needle) >= count:
                    return True
                if proc.poll() is not None:
                    break
                time.sleep(0.2)
            return output_count(needle) >= count

        def output_contains(needle, timeout_s):
            return output_reaches(needle, 1, timeout_s)

        PROMPT = "› "

        def send(cmd, idle_timeout_s=120):
            """Write one command and wait for the REPL to return to the
            prompt (idle) — the sequencing hardening from Codex's review."""
            before = output_count(PROMPT)
            proc.stdin.write((cmd + "\n").encode())
            proc.stdin.flush()
            output_reaches(PROMPT, before + 1, idle_timeout_s)

        try:
            output_contains(PROMPT, 60)  # wait for the welcome prompt
            send("Say hello")
            got_reply = output_contains(MOCK_REPLY, 120)
            check("chat: mock reply rendered", got_reply,
                  output_text()[-1200:])

            # Single-instance lock: a second process on the same state dir
            # must refuse to start while the first is alive.
            second = subprocess.run([ADA], capture_output=True, text=True,
                                    timeout=60, env=env, stdin=subprocess.DEVNULL)
            check("lock: second instance refused",
                  second.returncode == 1 and "another Briglia instance" in second.stdout,
                  f"rc={second.returncode} out={second.stdout!r}")

            # /hide: replies must not render while privacy mode is on…
            send("/hide", idle_timeout_s=30)
            output_contains("Privacy mode", 30)
            send("Say hello again")
            hid = output_contains("message hidden (privacy mode", 120)
            leaked = output_count(MOCK_REPLY) > 1
            check("hide: reply suppressed while private", hid and not leaked,
                  output_text()[-1200:])
            # …and /show replays what was hidden.
            send("/show", idle_timeout_s=30)
            revealed = output_contains("revealing ", 60) \
                and output_reaches(MOCK_REPLY, 2, 60)
            check("show: hidden reply revealed", revealed,
                  output_text()[-1200:])

            # /attach with a quoted path containing spaces must find the file.
            spaced = os.path.join(home, "attach me.txt")
            with open(spaced, "w") as f:
                f.write("attachment content\n")
            send(f'/attach "{spaced}" describe this')
            attached_ok = output_reaches(MOCK_REPLY, 3, 120) \
                and output_count("no such file") == 0
            check("attach: quoted spaced path accepted", attached_ok,
                  output_text()[-1200:])
            send("/attach /definitely/not/here.txt", idle_timeout_s=30)
            check("attach: missing path rejected",
                  output_contains("no such file", 30), output_text()[-600:])

            # /websearch: listing renders through the shared dispatcher, and
            # switching to a backend with no configured key is refused loudly
            # (this env has no OpenAI key in its isolated secrets store).
            send("/websearch", idle_timeout_s=30)
            check("websearch: backend listing rendered",
                  output_contains("Web research backend", 30), output_text()[-800:])
            send("/websearch openai", idle_timeout_s=30)
            check("websearch: keyless switch refused",
                  output_contains("No key configured for OpenAI", 30), output_text()[-600:])

            proc.stdin.write(b"/quit\n")
            proc.stdin.flush()
            try:
                rc = proc.wait(timeout=60)
                check("chat: /quit exits cleanly", rc == 0, f"rc={rc}")
            except subprocess.TimeoutExpired:
                proc.kill()
                check("chat: /quit exits cleanly", False, "timeout waiting for exit")
        except BrokenPipeError:
            check("chat: mock reply rendered", False, "stdin pipe broke — process died early:\n" + output_text()[-1200:])
            check("chat: /quit exits cleanly", False, "")
        finally:
            if proc.poll() is None:
                proc.kill()
    finally:
        server.shutdown()
        shutil.rmtree(home, ignore_errors=True)

    # 6. setup wizard: interrupted first run resumes at the saved step
    with tempfile.TemporaryDirectory() as home:
        env = isolated_env(home)
        # macOS UserDefaults ignores the HOME override — without this, a real
        # completed install on the host machine routes setup to the rerun menu.
        env["BRIGLIA_IGNORE_LEGACY_SETUP_FLAG"] = "1"
        server = ThreadingHTTPServer(("127.0.0.1", 0), MockOpenAIHandler)
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            # The wizard has one extra Linux-only step (always-on service),
            # so the step totals in its headers differ per platform.
            total_steps = 8 if sys.platform == "darwin" else 9
            # Complete step 1 (custom-endpoint profile, menu option 3,
            # against the mock server; Responses=n, vision=y; Enter declines "configure
            # another provider"), then close stdin at step 2 — the
            # FDA-relaunch shape of interruption.
            step1 = f"3\nhttp://127.0.0.1:{port}/v1\nmock-model\nn\nsk-mock-main\ny\n\n"
            result = subprocess.run([ADA, "setup"], input=step1, capture_output=True,
                                    text=True, timeout=120, env=env)
            interrupted_ok = (result.returncode == 1
                              and f"[2/{total_steps}]" in result.stdout
                              and "Input closed" in result.stdout)
            check("setup: EOF mid-run exits cleanly with progress saved", interrupted_ok,
                  f"rc={result.returncode} out={result.stdout[-800:]!r}")

            # Rerun: offers to resume at step 2; Enter accepts, and the OpenAI
            # step (not the main-agent step) is what runs next.
            result = subprocess.run([ADA, "setup"], input="\n", capture_output=True,
                                    text=True, timeout=120, env=env)
            resumed_ok = ("stopped at step 2" in result.stdout
                          and "Resume from step 2" in result.stdout
                          and f"[2/{total_steps}]" in result.stdout
                          and f"[1/{total_steps}]" not in result.stdout)
            check("setup: rerun offers resume at interrupted step", resumed_ok,
                  result.stdout[-800:])

            # Declining resume starts over, but step 1 offers to keep the
            # already-configured main agent instead of forcing re-entry.
            result = subprocess.run([ADA, "setup"], input="n\n\n", capture_output=True,
                                    text=True, timeout=120, env=env)
            keep_ok = ("Main agent already configured" in result.stdout
                       and "keeping the current main agent" in result.stdout
                       and f"[2/{total_steps}]" in result.stdout)
            check("setup: restart offers to keep configured main agent", keep_ok,
                  result.stdout[-800:])
        finally:
            server.shutdown()

    # 7. /upgrade from chat: mock CDN → swap → exec restart → confirmation
    import hashlib
    import platform as platform_mod

    if sys.platform == "darwin":
        cdn_platform = "macos-arm64"
        bundle_name = "briglia-cli_briglia.bundle"
    else:
        cdn_platform = "linux-arm64" if platform_mod.machine() in ("arm64", "aarch64") else "linux-x64"
        bundle_name = "briglia-cli_briglia.resources"

    build_dir = os.path.dirname(os.path.abspath(ADA))
    bundle_src = os.path.join(build_dir, bundle_name)
    if not os.path.isdir(bundle_src):
        check("upgrade: build bundle present for packaging", False, f"missing {bundle_src}")
    else:
        home = tempfile.mkdtemp(prefix="ada-smoke-upgrade-")
        try:
            # A user-writable "install": the exact layout install.sh produces.
            install_dir = os.path.join(home, "bin")
            os.makedirs(install_dir)
            shutil.copy2(ADA, os.path.join(install_dir, "briglia"))
            shutil.copytree(bundle_src, os.path.join(install_dir, bundle_name))

            # Release tarball with the same binary, served by a mock CDN as 9.9.9.
            tar_path = os.path.join(home, "briglia.tar.gz")
            subprocess.run(["tar", "-czf", tar_path, "-C", build_dir,
                            "briglia", bundle_name], check=True)
            with open(tar_path, "rb") as f:
                tar_bytes = f.read()
            tar_sha = hashlib.sha256(tar_bytes).hexdigest()

            # SIGNED mock channel (the client is signed-only): the harness
            # signs each mock manifest with a deterministic test key through
            # the binary's own -dev-gated `__test-sign-envelope`, and hands
            # the client the matching pinned key via BRIGLIA_RELEASE_TEST_KEY.
            # Mutable so later checks can re-point the channel at a
            # downgrade version or a corrupted build.
            cdn_state = {"envelope": b"", "tar": tar_bytes}

            class MockCDNHandler(BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def do_GET(self):
                    if self.path == "/manifest.sig.json":
                        body = cdn_state["envelope"]
                        ctype = "application/json"
                    elif self.path.endswith("/briglia.tar.gz"):
                        body = cdn_state["tar"]
                        ctype = "application/gzip"
                    else:
                        self.send_response(404)
                        self.end_headers()
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *args):
                    pass

            cdn = ThreadingHTTPServer(("127.0.0.1", 0), MockCDNHandler)
            cdn_port = cdn.server_address[1]
            threading.Thread(target=cdn.serve_forever, daemon=True).start()

            import datetime as dt
            TEST_SEED = "5eed" * 16

            def sign_mock(version, sequence, tar, sha):
                now = dt.datetime.now(dt.timezone.utc)
                manifest = {
                    "schema": 1, "channel": "briglia-cli", "sequence": sequence,
                    "version": version,
                    "published": (now - dt.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "expires": (now + dt.timedelta(days=180)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "platforms": {cdn_platform: {
                        "url": f"http://127.0.0.1:{cdn_port}/dl/v{version}/briglia.tar.gz",
                        "sha256": sha, "size": len(tar),
                    }},
                }
                mpath = os.path.join(home, "mock-manifest.json")
                epath = os.path.join(home, "mock-manifest.sig.json")
                with open(mpath, "w") as f:
                    json.dump(manifest, f, separators=(",", ":"))
                result = subprocess.run(
                    [ADA, "__test-sign-envelope", mpath, epath, "--seed-hex", TEST_SEED],
                    capture_output=True, text=True, check=True)
                key_id = pub_hex = None
                for line in result.stdout.splitlines():
                    if line.startswith("keyId="):
                        key_id = line[len("keyId="):]
                    elif line.startswith("publicKeyHex="):
                        pub_hex = line[len("publicKeyHex="):]
                with open(epath, "rb") as f:
                    cdn_state["envelope"] = f.read()
                cdn_state["tar"] = tar
                return key_id, pub_hex

            test_key_id, test_pub_hex = sign_mock("9.9.9", BASE_SEQ + 1, tar_bytes, tar_sha)
            llm = ThreadingHTTPServer(("127.0.0.1", 0), MockOpenAIHandler)
            llm_port = llm.server_address[1]
            threading.Thread(target=llm.serve_forever, daemon=True).start()

            env = isolated_env(home)
            env["BRIGLIA_ENVELOPE_URL"] = f"http://127.0.0.1:{cdn_port}/manifest.sig.json"
            env["BRIGLIA_RELEASE_URL_PREFIX"] = f"http://127.0.0.1:{cdn_port}/dl/v{{version}}/"
            env["BRIGLIA_RELEASE_TEST_KEY"] = f"{test_key_id}:{test_pub_hex}"
            config_dir = os.path.join(home, ".config", "briglia")
            os.makedirs(config_dir, exist_ok=True)
            with open(os.path.join(config_dir, "secrets.json"), "w") as f:
                json.dump({
                    "llm_provider": "openai_compatible",
                    "openai_compatible_base_url": f"http://127.0.0.1:{llm_port}/v1",
                    "openai_compatible_model": "mock-model",
                    "openai_compatible_api_key": "smoke-test-key",
                    "assistant_name": "Bree",
                }, f)
            os.chmod(os.path.join(config_dir, "secrets.json"), 0o600)

            proc = subprocess.Popen(
                [os.path.join(install_dir, "briglia")],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, env=env,
            )
            buf = bytearray()
            lock = threading.Lock()

            def reader():
                while True:
                    chunk = proc.stdout.read1(4096)
                    if not chunk:
                        break
                    with lock:
                        buf.extend(chunk)

            threading.Thread(target=reader, daemon=True).start()

            def out():
                with lock:
                    return buf.decode("utf-8", errors="replace")

            def wait_for(needle, timeout_s, count=1):
                deadline = time.time() + timeout_s
                while time.time() < deadline:
                    if out().count(needle) >= count:
                        return True
                    if proc.poll() is not None:
                        break
                    time.sleep(0.2)
                return out().count(needle) >= count

            try:
                wait_for("› ", 60)
                proc.stdin.write(b"/upgrade\n")
                proc.stdin.flush()
                swapped = wait_for("installed — restarting now", 180)
                check("upgrade: mock release downloaded and swapped", swapped, out()[-1200:])

                # The process must survive its own exec: banner again, marker
                # announcement, and a live REPL — all in the SAME pid.
                restarted = wait_for("Update 9.9.9 installed — Briglia restarted.", 120)
                check("upgrade: exec restart announced", restarted, out()[-1200:])
                wait_for("Briglia CLI", 60, count=2)
                wait_for("› ", 60, count=2)
                proc.stdin.write(b"/status\n")
                proc.stdin.flush()
                alive = wait_for("status:", 60)
                check("upgrade: REPL functional after exec (lock reacquired)", alive,
                      out()[-1200:])

                # Downgrade refusal: the CDN briefly serving an OLDER version
                # (concurrent-release race) must never be installed.
                sign_mock("0.0.1", BASE_SEQ + 2, tar_bytes, tar_sha)
                proc.stdin.write(b"/upgrade\n")
                proc.stdin.flush()
                refused = wait_for("Not downgrading", 60)
                check("upgrade: older manifest refused (downgrade guard)", refused,
                      out()[-1200:])

                # Corrupt release: a build that fails validation must be
                # rejected BEFORE the installed files are touched.
                corrupt_dir = os.path.join(home, "corrupt")
                os.makedirs(os.path.join(corrupt_dir, bundle_name))
                with open(os.path.join(corrupt_dir, bundle_name, "stub"), "w") as f:
                    f.write("not a real bundle\n")
                with open(os.path.join(corrupt_dir, "briglia"), "w") as f:
                    f.write("#!/bin/sh\nexit 1\n")
                os.chmod(os.path.join(corrupt_dir, "briglia"), 0o755)
                corrupt_tar = os.path.join(home, "corrupt.tar.gz")
                subprocess.run(["tar", "-czf", corrupt_tar, "-C", corrupt_dir,
                                "briglia", bundle_name], check=True)
                with open(corrupt_tar, "rb") as f:
                    corrupt_bytes = f.read()
                sign_mock("8.8.8", BASE_SEQ + 3, corrupt_bytes,
                          hashlib.sha256(corrupt_bytes).hexdigest())
                proc.stdin.write(b"/upgrade\n")
                proc.stdin.flush()
                rejected = wait_for("failed verification", 120)
                with open(os.path.join(install_dir, "briglia"), "rb") as f:
                    intact = f.read(64) != b"#!/bin/sh\nexit 1\n"[:64]
                check("upgrade: corrupt build rejected, install untouched",
                      rejected and intact, out()[-1200:])

                proc.stdin.write(b"/quit\n")
                proc.stdin.flush()
                try:
                    rc = proc.wait(timeout=60)
                    check("upgrade: clean exit after restart", rc == 0, f"rc={rc}")
                except subprocess.TimeoutExpired:
                    proc.kill()
                    check("upgrade: clean exit after restart", False, "timeout waiting for exit")

                # Fault injection: fail the swap AFTER the new binary is
                # placed (the exact hole Codex found — a mixed install of new
                # binary + old bundle). Rollback must restore BOTH originals.
                def sha256_of(path):
                    with open(path, "rb") as f:
                        return hashlib.sha256(f.read()).hexdigest()
                pre_hash = sha256_of(os.path.join(install_dir, "briglia"))
                sign_mock("7.7.7", BASE_SEQ + 4, tar_bytes, tar_sha)
                env2 = dict(env)
                env2["BRIGLIA_UPGRADE_FAULT"] = "bundle-move"
                proc2 = subprocess.Popen(
                    [os.path.join(install_dir, "briglia")],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, env=env2,
                )
                buf2 = bytearray()
                lock2 = threading.Lock()

                def reader2():
                    while True:
                        chunk = proc2.stdout.read1(4096)
                        if not chunk:
                            break
                        with lock2:
                            buf2.extend(chunk)

                threading.Thread(target=reader2, daemon=True).start()

                def out2():
                    with lock2:
                        return buf2.decode("utf-8", errors="replace")

                def wait2(needle, timeout_s):
                    deadline = time.time() + timeout_s
                    while time.time() < deadline:
                        if needle in out2():
                            return True
                        if proc2.poll() is not None:
                            break
                        time.sleep(0.2)
                    return needle in out2()

                try:
                    wait2("› ", 60)
                    proc2.stdin.write(b"/upgrade\n")
                    proc2.stdin.flush()
                    rolled_back = wait2("previous version restored", 120)
                    post_hash = sha256_of(os.path.join(install_dir, "briglia"))
                    bundle_ok = os.path.isdir(os.path.join(install_dir, bundle_name))
                    leftovers = [n for n in os.listdir(install_dir)
                                 if n.startswith(".briglia-upgrade-")]
                    check("upgrade: mid-swap fault rolls back both components",
                          rolled_back and post_hash == pre_hash and bundle_ok
                          and not leftovers,
                          f"rolled_back={rolled_back} hash_same={post_hash == pre_hash} "
                          f"bundle_ok={bundle_ok} leftovers={leftovers}\n" + out2()[-800:])
                    proc2.stdin.write(b"/status\n")
                    proc2.stdin.flush()
                    alive2 = wait2("status:", 60)
                    proc2.stdin.write(b"/quit\n")
                    proc2.stdin.flush()
                    try:
                        rc2 = proc2.wait(timeout=60)
                    except subprocess.TimeoutExpired:
                        proc2.kill()
                        rc2 = -1
                    check("upgrade: process healthy after rollback",
                          alive2 and rc2 == 0, f"alive={alive2} rc={rc2}\n" + out2()[-600:])
                finally:
                    if proc2.poll() is None:
                        proc2.kill()
            except BrokenPipeError:
                check("upgrade: mock release downloaded and swapped", False,
                      f"stdin pipe broke — process died early (poll={proc.poll()}):\n"
                      + out())
            finally:
                if proc.poll() is None:
                    proc.kill()
                cdn.shutdown()
                llm.shutdown()
        finally:
            shutil.rmtree(home, ignore_errors=True)

    # 8. Telegram poller: dedup, offset persistence, week-reset adoption
    # Short /tmp home, NOT the platform temp dir: macOS's per-user temp root
    # is long enough that <home>/.local/share/briglia/app-chat.sock overflows
    # sockaddr_un's 104-byte path cap and phase 10's chat socket can't bind.
    home = tempfile.mkdtemp(prefix="ada-smoke-poller-", dir="/tmp")
    try:
        tg_state = {"updates": [], "force": [], "offsets": [], "timeline": [],
                    "sent": [], "posts": [], "t0": time.time()}
        tg_lock = threading.Lock()

        def tg_timeline():
            with tg_lock:
                return f"getUpdates timeline (s,offset): {tg_state['timeline'][-40:]}"

        def tg_update(uid, text):
            return {"update_id": uid, "message": {
                "message_id": uid, "date": 0, "text": text,
                "chat": {"id": 12345, "type": "private"},
                "from": {"id": 12345, "is_bot": False, "first_name": "T"},
            }}

        class MockTelegramHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def _reply(self, obj):
                body = json.dumps(obj).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if "/getUpdates" in self.path:
                    from urllib.parse import urlparse, parse_qs
                    q = parse_qs(urlparse(self.path).query)
                    offset = int(q.get("offset", ["0"])[0])
                    with tg_lock:
                        tg_state["offsets"].append(offset)
                        tg_state["timeline"].append(
                            (round(time.time() - tg_state["t0"], 1), offset))
                        # Idempotent by design: identical offsets get identical
                        # answers (Swift's Linux networking duplicates GETs, and
                        # a pop-once queue let the phantom twin eat batches).
                        # "updates" serves normally (id >= offset); "force"
                        # serves regardless of offset — re-delivery and reset
                        # scenarios — and relies on Briglia's dedup to ignore
                        # repeats.
                        batch = [u for u in tg_state["updates"]
                                 if u["update_id"] >= offset]
                        batch += [u for u in tg_state["force"]
                                  if u["update_id"] < offset]
                    self._reply({"ok": True, "result": batch})
                else:
                    self._reply({"ok": True, "result": True})

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length)
                try:
                    parsed = json.loads(body)
                except ValueError:
                    parsed = None
                # Every Bot API method call is recorded (method name + body)
                # so phases can assert on answerCallbackQuery / editMessageText
                # too; "sent" keeps its sendMessage-only meaning.
                with tg_lock:
                    tg_state["posts"].append((self.path.rsplit("/", 1)[-1], parsed))
                    stall = (isinstance(parsed, dict)
                             and parsed.get("callback_query_id") in tg_state.get("stall_answer_ids", ()))
                if stall:
                    # Suspended acknowledgement (phase 13 race): the daemon
                    # awaits this reply while another surface changes state.
                    time.sleep(6)
                if "/sendMessage" in self.path or "/editMessageText" in self.path:
                    if "/sendMessage" in self.path and parsed is not None:
                        with tg_lock:
                            tg_state["sent"].append(parsed)
                    self._reply({"ok": True, "result": {
                        "message_id": 1, "date": 0,
                        "chat": {"id": 12345, "type": "private"}}})
                else:
                    self._reply({"ok": True, "result": True})

            def log_message(self, *args):
                pass

        tg = ThreadingHTTPServer(("127.0.0.1", 0), MockTelegramHandler)
        tg_port = tg.server_address[1]
        threading.Thread(target=tg.serve_forever, daemon=True).start()

        # Slowable + recording LLM mock: a request whose body contains the
        # marker stalls (long enough to pin a turn "active" while the kill
        # scenario runs); every body is recorded so tests can assert which
        # messages actually reached the model.
        llm_state = {"bodies": [], "marker": "sleep-now", "delay": 20,
                     "tool_call_marker": ""}

        class SlowableOpenAIHandler(MockOpenAIHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8", errors="replace")
                with tg_lock:
                    llm_state["bodies"].append(body)
                    tool_marker = llm_state["tool_call_marker"]
                if llm_state["marker"] in body:
                    time.sleep(llm_state["delay"])
                # Scriptable tool round (mid-turn integration test): the first
                # request containing the tool marker gets a real bash tool
                # call; the follow-up request (recognizable by the echoed
                # tool_call id) gets the normal text reply.
                if tool_marker and tool_marker in body and "call_mt1" not in body:
                    message = {"role": "assistant", "content": None,
                               "tool_calls": [{"id": "call_mt1", "type": "function",
                                               "function": {"name": "bash",
                                                            "arguments": json.dumps({"command": "sleep 6"})}}]}
                    finish = "tool_calls"
                else:
                    message = {"role": "assistant", "content": MOCK_REPLY}
                    finish = "stop"
                reply = json.dumps({
                    "id": "gen-smoke-1", "object": "chat.completion",
                    "model": "mock-model",
                    "choices": [{"index": 0, "finish_reason": finish,
                                 "message": message}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 12,
                              "total_tokens": 22},
                }).encode()
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(reply)))
                    self.end_headers()
                    self.wfile.write(reply)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # client killed mid-stall — expected in the kill test

        llm = ThreadingHTTPServer(("127.0.0.1", 0), SlowableOpenAIHandler)
        llm_port = llm.server_address[1]
        threading.Thread(target=llm.serve_forever, daemon=True).start()

        def llm_bodies():
            with tg_lock:
                return list(llm_state["bodies"])

        env = isolated_env(home)
        env["BRIGLIA_TELEGRAM_API_BASE"] = f"http://127.0.0.1:{tg_port}/bot"
        config_dir = os.path.join(home, ".config", "briglia")
        os.makedirs(config_dir, exist_ok=True)
        with open(os.path.join(config_dir, "secrets.json"), "w") as f:
            json.dump({
                "llm_provider": "openai_compatible",
                "openai_compatible_base_url": f"http://127.0.0.1:{llm_port}/v1",
                "openai_compatible_model": "mock-model",
                "openai_compatible_api_key": "smoke-test-key",
                "assistant_name": "Bree",
                "telegram_bot_token": "TESTTOKEN",
                "telegram_chat_id": "12345",
            }, f)
        os.chmod(os.path.join(config_dir, "secrets.json"), 0o600)

        def run_poller_phase(extra_env, actions, timeout_s=90, binary=None,
                             keep_marker=False):
            """Spawn ada, run `actions(wait_fn, push_fn, out_fn, proc)`, /quit,
            return (full output, exit code)."""
            # Force entries are per-phase: leaking them across phases poisons
            # the reset scenario (the reset fires on a stale forced id first,
            # refreshing activity, and the real reset id then reads as a
            # duplicate — exactly what the macOS CI timeline showed).
            with tg_lock:
                tg_state["force"].clear()
            # Phase hermeticity: an active-turn marker carried over from a
            # previous phase makes THIS phase's process resume a stale turn
            # at startup — mid-turn guards then fire instead of the guards
            # the phase actually tests (seen on slow CI runners). Only the
            # marker-resume phase (6b) legitimately inherits one. Loudly
            # report what leaked — the trigger id and startedAt pin down the
            # phase that wrote it — then remove it.
            stale_marker = os.path.join(
                home, ".local", "share", "briglia", "active_turn.json")
            if not keep_marker and os.path.exists(stale_marker):
                try:
                    with open(stale_marker) as f:
                        content = f.read()
                except OSError as e:
                    content = f"<unreadable: {e}>"
                print(f"  [harness] stale active_turn.json leaked from a "
                      f"previous phase, removing: {content}")
                os.remove(stale_marker)
            phase_env = dict(env)
            phase_env.update(extra_env)
            p = subprocess.Popen(
                [binary or ADA], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, env=phase_env,
            )
            pbuf = bytearray()
            plock = threading.Lock()

            def preader():
                while True:
                    chunk = p.stdout.read1(4096)
                    if not chunk:
                        break
                    with plock:
                        pbuf.extend(chunk)

            threading.Thread(target=preader, daemon=True).start()

            def pout():
                with plock:
                    return pbuf.decode("utf-8", errors="replace")

            def pwait(needle, timeout_n=30, count=1):
                deadline = time.time() + timeout_n
                while time.time() < deadline:
                    if pout().count(needle) >= count:
                        return True
                    if p.poll() is not None:
                        break
                    time.sleep(0.2)
                return pout().count(needle) >= count

            def push(batch, force=False):
                with tg_lock:
                    tg_state["force" if force else "updates"].extend(batch)

            rc = -1
            try:
                pwait("› ", 60)
                actions(pwait, push, pout, p)
                if p.poll() is None:  # a kill-scenario action may have ended it
                    # A text turn may still be mid-flight when the phase's
                    # last offset check passes (the offset confirms durable
                    # intake, not the answer). /quit mid-turn legitimately
                    # leaves the power-failure resume marker behind, and the
                    # NEXT phase's process would resume that stale turn and
                    # poison its scenario — on slow CI runners phase 5b
                    # resumed phase 5's tail turn and correctly refused
                    # /restart mid-turn (no exec, no announcement). Wait for
                    # the marker to clear before the graceful quit;
                    # kill-scenario phases never reach this path.
                    marker = os.path.join(
                        home, ".local", "share", "briglia", "active_turn.json")
                    mdeadline = time.time() + 15
                    while time.time() < mdeadline and os.path.exists(marker):
                        time.sleep(0.2)
                    p.stdin.write(b"/quit\n")
                    p.stdin.flush()
                rc = p.wait(timeout=60)
            except (subprocess.TimeoutExpired, BrokenPipeError):
                p.kill()
            finally:
                if p.poll() is None:
                    p.kill()
            return pout(), rc

        def tg_mark(label):
            with tg_lock:
                tg_state["timeline"].append((round(time.time() - tg_state["t0"], 1), label))

        # Phase 1: same-batch and cross-batch duplicates.
        def phase1(pwait, push, pout, proc):
            push([tg_update(100, "hello one"), tg_update(100, "hello one")])
            pwait("hello one", 30)
            pwait("Dropping re-delivered update 100", 15)
            push([tg_update(100, "hello one")], force=True)
            pwait("Dropping re-delivered update 100", 15, count=2)
            push([tg_update(101, "hello two")])
            pwait("hello two", 30)

        # H2 private-by-default storage: plant wide entries under the roots
        # before the first start; the daemon's startup sweep must tighten
        # them (owner bits kept), leave projects/ alone, and the tightened
        # skill helper must still execute.
        data_root = os.path.join(home, ".local", "share", "briglia")
        config_root = os.path.join(home, ".config", "briglia")
        # The data root is a SYMLINK to a directory elsewhere for the whole
        # poller run (data moved to another disk): every phase runs through
        # it, and the first start must tighten the target tree.
        moved_data = os.path.join(home, "moved-data", "briglia")
        os.makedirs(moved_data, exist_ok=True)
        os.makedirs(os.path.dirname(data_root), exist_ok=True)
        if not os.path.lexists(data_root):
            os.symlink(moved_data, data_root)
        planted_file = os.path.join(data_root, "smoke_wide.json")
        planted_dir = os.path.join(data_root, "subagent_sessions")
        planted_helper = os.path.join(config_root, "skills", "smoke", "helper.sh")
        planted_project = os.path.join(data_root, "projects", "p", "readme.md")
        os.makedirs(planted_dir, exist_ok=True)
        os.chmod(planted_dir, 0o755)
        with open(planted_file, "w") as f:
            f.write("{}")
        os.chmod(planted_file, 0o644)
        os.makedirs(os.path.dirname(planted_helper), exist_ok=True)
        with open(planted_helper, "w") as f:
            f.write("#!/bin/sh\necho helper-ok\n")
        os.chmod(planted_helper, 0o755)
        os.makedirs(os.path.dirname(planted_project), exist_ok=True)
        with open(planted_project, "w") as f:
            f.write("x")
        os.chmod(planted_project, 0o644)
        os.chmod(data_root, 0o755)

        def mode_of(path):
            return stat.S_IMODE(os.lstat(path).st_mode)

        def dir_mode(path):
            return stat.S_IMODE(os.stat(path).st_mode)   # follows a root symlink

        tg_mark("phase1-start")
        out1, rc1 = run_poller_phase({}, phase1)
        helper_run = subprocess.run([planted_helper], capture_output=True, text=True)
        check("storage: startup sweep tightened planted entries (0644→0600, 0755→0700, roots 0700), "
              "projects/ untouched, swept helper still runs",
              mode_of(planted_file) == 0o600 and mode_of(planted_dir) == 0o700
              and mode_of(planted_helper) == 0o700 and mode_of(planted_project) == 0o644
              and dir_mode(data_root) == 0o700 and dir_mode(config_root) == 0o700
              and os.path.islink(data_root) and dir_mode(moved_data) == 0o700
              and helper_run.stdout.strip() == "helper-ok"
              and ("tightened to owner-only" in out1),
              f"file={oct(mode_of(planted_file))} dir={oct(mode_of(planted_dir))} "
              f"helper={oct(mode_of(planted_helper))} project={oct(mode_of(planted_project))} "
              f"data={oct(dir_mode(data_root))} config={oct(dir_mode(config_root))} link={os.path.islink(data_root)} "
              f"helper_out={helper_run.stdout!r}\n" + out1[-1500:])
        # Other-uid isolation (Linux CI runs as root in the container): with
        # the scratch home made traversable, another uid must still be unable
        # to list the data root or read the conversation.
        if sys.platform.startswith("linux") and os.geteuid() == 0 and shutil.which("su"):
            for d in (home, os.path.join(home, ".local"), os.path.join(home, ".local", "share"),
                      os.path.join(home, ".config")):
                os.chmod(d, 0o711)
            conv = os.path.join(data_root, "conversation.json")
            probe = subprocess.run(
                ["su", "-s", "/bin/sh", "nobody", "-c",
                 f"ls {data_root} >/dev/null 2>&1 && echo LISTED; "
                 f"cat {conv} >/dev/null 2>&1 && echo READ; echo done"],
                capture_output=True, text=True, timeout=30)
            if "done" in probe.stdout:
                check("storage: another uid can neither list the data root nor read conversation.json",
                      "LISTED" not in probe.stdout and "READ" not in probe.stdout
                      and os.path.exists(conv),
                      f"stdout={probe.stdout!r} stderr={probe.stderr!r} conv_exists={os.path.exists(conv)}")
            else:
                print(f"  [harness] other-uid probe unavailable: {probe.stdout!r} {probe.stderr!r}")
        check("poller: same-batch duplicate dropped",
              out1.count("[Telegram] hello one") == 1
              and "Dropping re-delivered update 100" in out1,
              tg_timeline() + "\n" + out1[-2500:])
        check("poller: cross-batch duplicate dropped",
              out1.count("Dropping re-delivered update 100") >= 2 and rc1 == 0,
              tg_timeline() + f"\nrc={rc1}\n" + out1[-2500:])

        state_path = os.path.join(home, ".local", "share", "briglia",
                                  "telegram_offset.json")
        persisted = {}
        if os.path.exists(state_path):
            with open(state_path) as f:
                persisted = json.load(f)

        # Phase 2 (default reset window): the restarted process must resume
        # at offset 102 and drop a re-delivery of 101.
        with tg_lock:
            tg_state["offsets"].clear()
        def phase2(pwait, push, pout, proc):
            push([tg_update(101, "hello two")], force=True)
            pwait("Dropping re-delivered update 101", 20)

        tg_mark("phase2-start")
        out2, rc2 = run_poller_phase({}, phase2)
        with tg_lock:
            first_offset = tg_state["offsets"][0] if tg_state["offsets"] else None
        check("poller: offset persisted across restart, re-delivery dropped",
              persisted.get("lastUpdateId") == 101 and first_offset == 102
              and "Dropping re-delivered update 101" in out2
              and out2.count("[Telegram] hello two") == 0 and rc2 == 0,
              tg_timeline() + f"\npersisted={persisted} first_offset={first_offset} rc={rc2}\n" + out2[-2500:])

        # Phase 3 (1s reset window): a lower id after "a week" of silence is
        # a legitimate reset — adopted and processed, not dropped.
        def phase3(pwait, push, pout, proc):
            time.sleep(1.5)  # let the last real activity age past the window
            push([tg_update(50, "after reset")], force=True)
            pwait("after reset", 30)
            # Adoption is proven by the NEXT poll asking for offset 51 — give
            # the 1s-interval loop time to issue it before quitting.
            deadline = time.time() + 15
            while time.time() < deadline:
                with tg_lock:
                    if 51 in tg_state["offsets"]:
                        return
                time.sleep(0.3)

        tg_mark("phase3-start")
        out3, rc3 = run_poller_phase({"BRIGLIA_TELEGRAM_RESET_WINDOW_SECONDS": "1"}, phase3)
        with tg_lock:
            saw_51 = 51 in tg_state["offsets"]
        check("poller: week-reset id adopted, polling follows new sequence",
              "sequence reset detected" in out3
              and "[Telegram] after reset" in out3
              and saw_51 and rc3 == 0,
              tg_timeline() + f"\nsaw_51={saw_51} rc={rc3}\n" + out3[-2500:])

        # Phase 4: SIGKILL while a message sits in the mid-turn queue. The
        # queued update is already confirmed to Telegram (never re-served), so
        # only the durable queue file can save it. Kill -9 mid-turn, restart,
        # and require the message to be recovered and actually answered.
        data_dir = os.path.join(home, ".local", "share", "briglia")
        midturn_path = os.path.join(data_dir, "pending_midturn.json")
        with tg_lock:
            tg_state["updates"].clear()  # retire phase 1-3 ids for good

        phase4_state = {"queued_on_disk": False, "confirmed_401": False}

        def phase4(pwait, push, pout, proc):
            push([tg_update(400, "please sleep-now and think hard")])
            # Wait until the slow LLM call is in flight (turn pinned active).
            deadline = time.time() + 30
            while time.time() < deadline:
                if any("sleep-now" in b for b in llm_bodies()):
                    break
                time.sleep(0.2)
            push([tg_update(401, "queued while busy")])
            deadline = time.time() + 30
            while time.time() < deadline:
                if os.path.exists(midturn_path):
                    phase4_state["queued_on_disk"] = True
                    try:
                        with open(state_path) as f:
                            phase4_state["confirmed_401"] = \
                                json.load(f).get("lastUpdateId") == 401
                    except (OSError, ValueError):
                        pass
                    if phase4_state["confirmed_401"]:
                        break
                time.sleep(0.2)
            proc.kill()  # SIGKILL: no cleanup, the crash case

        tg_mark("phase4-start")
        out4, _ = run_poller_phase({}, phase4)
        check("poller: mid-turn queue persisted + offset confirmed per update",
              phase4_state["queued_on_disk"] and phase4_state["confirmed_401"],
              f"{phase4_state}\n" + tg_timeline() + "\n" + out4[-2500:])

        # Phase 4b: the restarted process must recover the queued message
        # from disk (Telegram won't re-serve it) and run a turn for it.
        # The stall marker is retired first — the recovery turn's request
        # carries the full history, which still contains the marker text.
        with tg_lock:
            tg_state["offsets"].clear()
            llm_state["marker"] = "-- no stalls in phase 4b --"
            llm_state["bodies"].clear()

        def phase4b(pwait, push, pout, proc):
            pwait("Recovered 1 queued mid-turn message(s)", 30)
            deadline = time.time() + 30
            while time.time() < deadline:
                if any("queued while busy" in b for b in llm_bodies()):
                    return
                time.sleep(0.2)

        tg_mark("phase4b-start")
        out4b, rc4b = run_poller_phase({}, phase4b)
        with tg_lock:
            resumed_at = tg_state["offsets"][0] if tg_state["offsets"] else None
        reached_llm = any("queued while busy" in b for b in llm_bodies())
        check("poller: killed process's queued message recovered after restart",
              "Recovered 1 queued mid-turn message(s)" in out4b
              and reached_llm and not os.path.exists(midturn_path)
              and resumed_at == 402 and rc4b == 0,
              f"reached_llm={reached_llm} resumed_at={resumed_at} rc={rc4b} "
              f"file_gone={not os.path.exists(midturn_path)}\n" + out4b[-2500:])

        # Phase 5: /upgrade with a second message in the SAME getUpdates
        # batch. /upgrade must confirm only its own update id before the
        # exec-restart; the restarted process must then receive and answer
        # the tail message instead of skipping it forever.
        import hashlib as hashlib5
        import platform as platform5
        if sys.platform == "darwin":
            p5_platform, p5_bundle = "macos-arm64", "briglia-cli_briglia.bundle"
        else:
            p5_platform = ("linux-arm64" if platform5.machine() in ("arm64", "aarch64")
                           else "linux-x64")
            p5_bundle = "briglia-cli_briglia.resources"
        p5_build_dir = os.path.dirname(os.path.abspath(ADA))
        p5_install = os.path.join(home, "bin")
        os.makedirs(p5_install, exist_ok=True)
        shutil.copy2(ADA, os.path.join(p5_install, "briglia"))
        shutil.copytree(os.path.join(p5_build_dir, p5_bundle),
                        os.path.join(p5_install, p5_bundle))
        p5_tar = os.path.join(home, "p5.tar.gz")
        subprocess.run(["tar", "-czf", p5_tar, "-C", p5_build_dir,
                        "briglia", p5_bundle], check=True)
        with open(p5_tar, "rb") as f:
            p5_tar_bytes = f.read()
        p5_sha = hashlib5.sha256(p5_tar_bytes).hexdigest()

        # Signed mock channel, same contract as phase 7's: the client is
        # signed-only, so the mock serves a __test-sign-envelope-signed
        # envelope and the harness pins the test key via env.
        p5_envelope = {"body": b""}

        class P5CDNHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                if self.path == "/manifest.sig.json":
                    body, ctype = p5_envelope["body"], "application/json"
                elif self.path.endswith("/p5.tar.gz"):
                    body, ctype = p5_tar_bytes, "application/gzip"
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        p5_cdn = ThreadingHTTPServer(("127.0.0.1", 0), P5CDNHandler)
        p5_cdn_port = p5_cdn.server_address[1]
        threading.Thread(target=p5_cdn.serve_forever, daemon=True).start()

        import datetime as p5_dt
        p5_now = p5_dt.datetime.now(p5_dt.timezone.utc)
        p5_manifest = {
            "schema": 1, "channel": "briglia-cli", "sequence": BASE_SEQ + 1, "version": "9.9.9",
            "published": (p5_now - p5_dt.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "expires": (p5_now + p5_dt.timedelta(days=180)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "platforms": {p5_platform: {
                "url": f"http://127.0.0.1:{p5_cdn_port}/dl/v9.9.9/p5.tar.gz",
                "sha256": p5_sha, "size": len(p5_tar_bytes)}},
        }
        p5_mpath = os.path.join(home, "p5-manifest.json")
        p5_epath = os.path.join(home, "p5-manifest.sig.json")
        with open(p5_mpath, "w") as f:
            json.dump(p5_manifest, f, separators=(",", ":"))
        p5_sign = subprocess.run(
            [ADA, "__test-sign-envelope", p5_mpath, p5_epath, "--seed-hex", "5eed" * 16],
            capture_output=True, text=True, check=True)
        p5_key_id = p5_pub_hex = None
        for line in p5_sign.stdout.splitlines():
            if line.startswith("keyId="):
                p5_key_id = line[len("keyId="):]
            elif line.startswith("publicKeyHex="):
                p5_pub_hex = line[len("publicKeyHex="):]
        with open(p5_epath, "rb") as f:
            p5_envelope["body"] = f.read()

        with tg_lock:
            tg_state["updates"].clear()
            tg_state["offsets"].clear()

        def phase5(pwait, push, pout, proc):
            # One batch: /upgrade first, a normal message right behind it.
            # Progress replies ("restarting now") go to Telegram, not the
            # terminal — the first terminal evidence of the upgrade is the
            # restarted process's own announcement.
            push([tg_update(500, "/upgrade"),
                  tg_update(501, "tail message survives")])
            pwait("Update 9.9.9 installed — Briglia restarted", 240)
            # The tail message must arrive at the RESTARTED process.
            pwait("[Telegram] tail message survives", 60)
            # ...and be confirmed by a poll at 502.
            deadline = time.time() + 15
            while time.time() < deadline:
                with tg_lock:
                    if 502 in tg_state["offsets"]:
                        return
                time.sleep(0.3)

        tg_mark("phase5-start")
        try:
            out5, rc5 = run_poller_phase(
                {"BRIGLIA_ENVELOPE_URL": f"http://127.0.0.1:{p5_cdn_port}/manifest.sig.json",
                 "BRIGLIA_RELEASE_URL_PREFIX": f"http://127.0.0.1:{p5_cdn_port}/dl/v{{version}}/",
                 "BRIGLIA_RELEASE_TEST_KEY": f"{p5_key_id}:{p5_pub_hex}"}, phase5,
                binary=os.path.join(p5_install, "briglia"))
        finally:
            p5_cdn.shutdown()
        tail_pos = out5.find("[Telegram] tail message survives")
        restart_pos = out5.find("Update 9.9.9 installed — Briglia restarted")
        with tg_lock:
            p5_offsets = list(tg_state["offsets"])
        check("poller: /upgrade confirms only its own update; same-batch tail survives restart",
              restart_pos != -1 and tail_pos > restart_pos
              and 501 in p5_offsets and 502 in p5_offsets and rc5 == 0,
              f"restart_pos={restart_pos} tail_pos={tail_pos} rc={rc5} "
              f"offsets={p5_offsets[-12:]}\n" + tg_timeline() + "\n" + out5[-3000:])

        # Phase 5b: /restart — plain in-place re-exec (no install swap, no
        # CDN). Same per-update-ack contract as /upgrade: a same-batch tail
        # message must survive the exec, and the restarted process announces
        # itself as a restart, NOT an update.
        with tg_lock:
            tg_state["updates"].clear()
            tg_state["offsets"].clear()

        def phase5b(pwait, push, pout, proc):
            push([tg_update(550, "/restart"),
                  tg_update(551, "restart tail survives")])
            pwait("✔ Briglia restarted.", 120)
            pwait("[Telegram] restart tail survives", 60)
            deadline = time.time() + 15
            while time.time() < deadline:
                with tg_lock:
                    if 552 in tg_state["offsets"]:
                        return
                time.sleep(0.3)

        tg_mark("phase5b-start")
        out5b, rc5b = run_poller_phase({}, phase5b)
        restart5b = out5b.find("✔ Briglia restarted.")
        tail5b = out5b.find("[Telegram] restart tail survives")
        with tg_lock:
            p5b_offsets = list(tg_state["offsets"])
        check("poller: /restart re-execs in place; same-batch tail survives, no update announce",
              restart5b != -1 and tail5b > restart5b
              and "installed — Briglia restarted" not in out5b
              and 551 in p5b_offsets and 552 in p5b_offsets and rc5b == 0,
              f"restart_pos={restart5b} tail_pos={tail5b} rc={rc5b} "
              f"offsets={p5b_offsets[-12:]}\n" + tg_timeline() + "\n" + out5b[-3000:])

        # Phase 6: power failure during a SINGLE idle-start turn, no later
        # message. The trigger is in history and its update confirmed, so
        # nothing re-delivers — only the active-turn marker lets the restart
        # notice the unanswered question and resume it unprompted.
        marker_path = os.path.join(data_dir, "active_turn.json")
        with tg_lock:
            tg_state["updates"].clear()
            llm_state["marker"] = "resume-me-stall"
            llm_state["bodies"].clear()

        phase6_state = {"marker_on_disk": False, "confirmed_600": False}

        def phase6(pwait, push, pout, proc):
            push([tg_update(600, "please resume-me-stall and ponder")])
            deadline = time.time() + 30
            while time.time() < deadline:
                in_flight = any("resume-me-stall" in b for b in llm_bodies())
                phase6_state["marker_on_disk"] = os.path.exists(marker_path)
                try:
                    with open(state_path) as f:
                        phase6_state["confirmed_600"] = \
                            json.load(f).get("lastUpdateId") == 600
                except (OSError, ValueError):
                    pass
                if in_flight and phase6_state["marker_on_disk"] \
                        and phase6_state["confirmed_600"]:
                    break
                time.sleep(0.2)
            proc.kill()  # power failure mid-model-call

        tg_mark("phase6-start")
        out6, _ = run_poller_phase({}, phase6)
        check("poller: active-turn marker on disk while turn runs, update confirmed",
              phase6_state["marker_on_disk"] and phase6_state["confirmed_600"],
              f"{phase6_state}\n" + out6[-2000:])

        # Phase 6b: restart with NO new message — the turn must resume by
        # itself, answer, and clear the marker.
        with tg_lock:
            llm_state["marker"] = "-- no stalls in phase 6b --"
            llm_state["bodies"].clear()

        def phase6b(pwait, push, pout, proc):
            pwait("Resuming turn interrupted by shutdown", 30)
            pwait("Briglia ▸", 60)

        tg_mark("phase6b-start")
        out6b, rc6b = run_poller_phase({}, phase6b, keep_marker=True)
        resumed_reached_llm = any("resume-me-stall" in b for b in llm_bodies())
        check("poller: interrupted single-message turn auto-resumes after restart",
              "Resuming turn interrupted by shutdown" in out6b
              and resumed_reached_llm and "Briglia ▸" in out6b
              and not os.path.exists(marker_path) and rc6b == 0,
              f"resumed_reached_llm={resumed_reached_llm} rc={rc6b} "
              f"marker_gone={not os.path.exists(marker_path)}\n" + out6b[-2500:])

        # Phase 7: durable-write failure must PAUSE polling entirely. The
        # offset of any getUpdates request is itself the acknowledgment —
        # if Briglia keeps polling at fetchedThroughId+1 while "not confirming",
        # Telegram deletes the supposedly protected updates anyway.
        fault_flag = os.path.join(home, "durability_fault_flag")
        with open(fault_flag, "w") as f:
            f.write("x")
        with tg_lock:
            tg_state["updates"].clear()
            tg_state["offsets"].clear()
            llm_state["bodies"].clear()

        phase7_state = {"premature_701": None, "confirmed_during_stall": None}

        def phase7(pwait, push, pout, proc):
            push([tg_update(700, "durability stall probe")])
            pwait("NOT confirming update 700", 30)
            pwait("Telegram polling PAUSED", 15)
            # Stall window: several ticks must pass with NO poll at 701 and
            # NO offset persistence of 700.
            time.sleep(4)
            with tg_lock:
                phase7_state["premature_701"] = 701 in tg_state["offsets"]
            try:
                with open(state_path) as f:
                    phase7_state["confirmed_during_stall"] = \
                        json.load(f).get("lastUpdateId", 0) >= 700
            except (OSError, ValueError):
                phase7_state["confirmed_during_stall"] = False
            # Disk "recovers": the retry must confirm and resume polling.
            os.remove(fault_flag)
            pwait("Durable writes recovered — confirmed update 700", 30)
            deadline = time.time() + 15
            while time.time() < deadline:
                with tg_lock:
                    if 701 in tg_state["offsets"]:
                        return
                time.sleep(0.3)

        tg_mark("phase7-start")
        out7, rc7 = run_poller_phase(
            {"BRIGLIA_TEST_DURABILITY_FAULT_FLAG": fault_flag}, phase7)
        with tg_lock:
            resumed_701 = 701 in tg_state["offsets"]
        persisted7 = {}
        try:
            with open(state_path) as f:
                persisted7 = json.load(f)
        except (OSError, ValueError):
            pass
        check("poller: durability failure pauses polling (no confirming offset leaks)",
              phase7_state["premature_701"] is False
              and phase7_state["confirmed_during_stall"] is False
              and "Telegram polling PAUSED" in out7,
              f"{phase7_state}\n" + tg_timeline() + "\n" + out7[-2500:])
        check("poller: write recovery confirms stalled update and resumes polling",
              "Durable writes recovered — confirmed update 700" in out7
              and resumed_701 and persisted7.get("lastUpdateId") == 700
              and rc7 == 0,
              f"resumed_701={resumed_701} persisted={persisted7} rc={rc7}\n"
              + out7[-2500:])

        # Phase 8: /upgrade behind a stalled update in the SAME batch must be
        # refused — its own confirmProcessed(higher id) would implicitly
        # confirm the stalled update, bypassing the whole stall. /status as
        # the stall trigger keeps Briglia idle so the refusal exercises the stall
        # guard, not the turn-running guard.
        with open(fault_flag, "w") as f:
            f.write("x")
        with tg_lock:
            tg_state["updates"].clear()
            tg_state["offsets"].clear()
            tg_state["sent"].clear()

        def phase8(pwait, push, pout, proc):
            push([tg_update(800, "/status"), tg_update(801, "/upgrade")])
            pwait("NOT confirming update 801", 30)
            time.sleep(3)  # stall window: nothing may confirm or restart
            os.remove(fault_flag)
            pwait("Durable writes recovered — confirmed update 801", 30)
            deadline = time.time() + 15
            while time.time() < deadline:
                with tg_lock:
                    if 802 in tg_state["offsets"]:
                        return
                time.sleep(0.3)

        tg_mark("phase8-start")
        out8, rc8 = run_poller_phase(
            {"BRIGLIA_TEST_DURABILITY_FAULT_FLAG": fault_flag}, phase8)
        with tg_lock:
            sent_texts = [m.get("text", "") for m in tg_state["sent"]]
            resumed_802 = 802 in tg_state["offsets"]
        persisted8 = {}
        try:
            with open(state_path) as f:
                persisted8 = json.load(f)
        except (OSError, ValueError):
            pass
        upgrade_refused = any("deferred until storage recovers" in t for t in sent_texts)
        check("poller: /upgrade refused during durability stall (no implicit confirm)",
              upgrade_refused and "Briglia restarted" not in out8
              and "Durable writes recovered — confirmed update 801" in out8
              and resumed_802 and persisted8.get("lastUpdateId") == 801
              and rc8 == 0,
              f"refused={upgrade_refused} resumed_802={resumed_802} "
              f"persisted={persisted8} rc={rc8}\nsent={sent_texts[-6:]}\n"
              + out8[-2500:])

        # Phase 9: marker recreation on stall recovery. The fault makes the
        # active-turn marker write fail at turn start (stall); the slow LLM
        # keeps the turn alive; when the disk "recovers" mid-turn, the retry
        # must recreate the marker BEFORE confirming — otherwise a power
        # failure after the confirm couldn't resume this turn.
        with open(fault_flag, "w") as f:
            f.write("x")
        with tg_lock:
            tg_state["updates"].clear()
            tg_state["offsets"].clear()
            llm_state["marker"] = "sleep-now"
            llm_state["bodies"].clear()

        phase9_state = {"marker_absent_during_stall": None,
                        "marker_present_after_recovery": None}

        def phase9(pwait, push, pout, proc):
            push([tg_update(900, "please sleep-now for the marker test")])
            pwait("Telegram polling PAUSED", 30)
            phase9_state["marker_absent_during_stall"] = \
                not os.path.exists(marker_path)
            os.remove(fault_flag)
            pwait("Durable writes recovered — confirmed update 900", 30)
            phase9_state["marker_present_after_recovery"] = \
                os.path.exists(marker_path)
            with tg_lock:
                llm_state["marker"] = "-- done stalling --"
            pwait("Briglia ▸", 60)  # turn finishes normally afterwards

        tg_mark("phase9-start")
        out9, rc9 = run_poller_phase(
            {"BRIGLIA_TEST_DURABILITY_FAULT_FLAG": fault_flag}, phase9)
        check("poller: stall recovery recreates the active-turn marker before confirming",
              phase9_state["marker_absent_during_stall"] is True
              and phase9_state["marker_present_after_recovery"] is True
              and "Durable writes recovered — confirmed update 900" in out9
              and "Briglia ▸" in out9 and rc9 == 0,
              f"{phase9_state} rc={rc9}\n" + out9[-2500:])

        # Phase 10: companion-app chat socket, end-to-end over the real
        # binary — hello + snapshot, ping, a full text turn answered by the
        # mock LLM arriving back as an assistant message event, attachment
        # intake surfacing on the user event, the shared /command set, and
        # the honest no-transcription-key voice nack.
        with tg_lock:
            tg_state["updates"].clear()
            llm_state["marker"] = "-- no stall in phase 10 --"
            llm_state["bodies"].clear()

        sock_path = os.path.join(home, ".local", "share", "briglia", "app-chat.sock")
        chat_state = {}

        def phase10(pwait, push, pout, proc):
            conn = None
            deadline = time.time() + 20
            while time.time() < deadline and conn is None:
                try:
                    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    c.connect(sock_path)
                    conn = c
                except OSError:
                    time.sleep(0.3)
            if conn is None:
                chat_state["error"] = "could not connect to " + sock_path
                return
            conn.settimeout(0.5)
            buf = bytearray()

            def read_event(want, timeout_s=30, match=None):
                deadline2 = time.time() + timeout_s
                while time.time() < deadline2:
                    nl = buf.find(b"\n")
                    if nl != -1:
                        line = bytes(buf[:nl])
                        del buf[:nl + 1]
                        try:
                            ev = json.loads(line)
                        except ValueError:
                            continue
                        if ev.get("type") == want and (match is None or match(ev)):
                            return ev
                        continue
                    try:
                        chunk = conn.recv(65536)
                    except socket.timeout:
                        continue
                    except OSError:
                        return None
                    if not chunk:
                        return None
                    buf.extend(chunk)
                return None

            def send_req(obj):
                conn.sendall((json.dumps(obj) + "\n").encode())

            chat_state["hello"] = read_event("hello")
            send_req({"type": "ping", "ref": "p1"})
            chat_state["pong"] = read_event("pong")

            send_req({"type": "send", "ref": "s1", "text": "hello from the app"})
            chat_state["ack"] = read_event(
                "ack", match=lambda e: e.get("ref") == "s1")
            chat_state["user_event"] = read_event(
                "message", match=lambda e: e.get("text") == "hello from the app")
            chat_state["reply_event"] = read_event(
                "message", 60, match=lambda e: e.get("role") == "assistant"
                and MOCK_REPLY in e.get("text", ""))

            attach = os.path.join(home, "attach-note.txt")
            with open(attach, "w") as f:
                f.write("attachment content for the chat socket test")
            send_req({"type": "send", "ref": "s2", "text": "see attached",
                      "attachments": [attach]})
            chat_state["attach_event"] = read_event(
                "message", 60,
                match=lambda e: "attach-note.txt" in (e.get("documents") or []))
            # drain s2's reply so /quit isn't racing the turn
            read_event("message", 60,
                       match=lambda e: e.get("role") == "assistant")

            send_req({"type": "command", "ref": "c1", "line": "/commands"})
            chat_state["cmd"] = read_event(
                "command_result", 30, match=lambda e: e.get("ref") == "c1")

            voice = os.path.join(home, "note.ogg")
            with open(voice, "wb") as f:
                f.write(b"OggS")
            send_req({"type": "voice", "ref": "v1", "path": voice})
            chat_state["voice_nack"] = read_event(
                "nack", 30, match=lambda e: e.get("ref") == "v1")
            conn.close()

        tg_mark("phase10-start")
        out10, rc10 = run_poller_phase({}, phase10)
        h10 = chat_state.get("hello") or {}
        check("app-chat: hello handshake with media dirs, ping answered",
              chat_state.get("error") is None and h10.get("protocol") == 1
              and h10.get("images_dir") and h10.get("documents_dir")
              and (chat_state.get("pong") or {}).get("ref") == "p1",
              f"{chat_state.get('error')} hello={h10}\n" + out10[-1500:])
        check("app-chat: text turn — ack, user event, mock-LLM reply event",
              chat_state.get("ack") is not None
              and chat_state.get("user_event") is not None
              and chat_state.get("reply_event") is not None and rc10 == 0,
              f"ack={chat_state.get('ack')} user={chat_state.get('user_event')} "
              f"reply={chat_state.get('reply_event')} rc={rc10}\n" + out10[-1500:])
        check("app-chat: attachment name surfaces on the user message event",
              chat_state.get("attach_event") is not None,
              f"{chat_state.get('attach_event')}\n" + out10[-1500:])
        cmd10 = chat_state.get("cmd") or {}
        nack10 = chat_state.get("voice_nack") or {}
        check("app-chat: /commands routed, voice without key nacked honestly",
              cmd10.get("handled") is True and cmd10.get("lines")
              and "transcription" in nack10.get("error", ""),
              f"cmd={cmd10} nack={nack10}\n" + out10[-1500:])

        # Phase 11: typed mid-turn annotation, end-to-end over the real
        # binary and a recorded mock provider (MIDTURN_NONCE_PLAN §14 /
        # Codex round-1 request). Request 1 answers the trigger with a real
        # bash tool call (sleep 6); a second Telegram message lands during
        # the tool round; request 2 must then carry the harness-rendered
        # annotation — reserved prefix, 32-hex nonce, BEGIN/END delimiters
        # with the SAME nonce, the message text inside the block, placed
        # after the [System Note:] line — and the durable queue must be
        # empty once the turn completes.
        with tg_lock:
            tg_state["updates"].clear()
            tg_state["offsets"].clear()
            llm_state["marker"] = "-- no stall in phase 11 --"
            llm_state["bodies"].clear()
            llm_state["tool_call_marker"] = "use-the-bash-tool"

        phase11_state = {"saw_request1": False, "pushed_midturn": False,
                         "saw_request2": False, "queue_empty_at_end": None}

        def phase11(pwait, push, pout, proc):
            push([tg_update(950, "please use-the-bash-tool now")])
            deadline = time.time() + 45
            while time.time() < deadline:
                if any("use-the-bash-tool" in b for b in llm_bodies()):
                    phase11_state["saw_request1"] = True
                    break
                time.sleep(0.2)
            # The bash tool is sleeping — deliver the mid-turn message now.
            push([tg_update(951, "midturn integration message")])
            phase11_state["pushed_midturn"] = True
            deadline = time.time() + 60
            while time.time() < deadline:
                if any("call_mt1" in b for b in llm_bodies()):
                    phase11_state["saw_request2"] = True
                    break
                time.sleep(0.2)
            pwait("Briglia ▸", 60)  # turn completes with the mock reply
            phase11_state["queue_empty_at_end"] = not os.path.exists(midturn_path)

        tg_mark("phase11-start")
        out11, rc11 = run_poller_phase({}, phase11, timeout_s=150)
        with tg_lock:
            llm_state["tool_call_marker"] = ""

        # The reserved prefix is assembled here so this file honors the
        # repository no-contiguous-prefix invariant.
        needle = "<<<" + "ADA_HARNESS_" + "DIRECT_USER:"
        body2 = next((b for b in llm_bodies()
                      if "call_mt1" in b and "[Direct user message" in b), None)
        annotation_ok = False
        ordering_ok = False
        if body2 is not None:
            m = re.search(re.escape(needle) + r"v1:([0-9a-f]{32}):BEGIN>>>", body2)
            if m:
                nonce = m.group(1)
                end_marker = f"{needle}v1:{nonce}:END>>>"
                end_idx = body2.find(end_marker)
                if end_idx > m.end():
                    block = body2[m.end():end_idx]
                    annotation_ok = ("[Direct user message 1 of 1]" in block
                                     and "midturn integration message" in block)
                note_idx = body2.find("[System Note: Current time is now")
                ordering_ok = 0 <= note_idx < m.start()
        check("midturn integration: tool-round delivery carries the typed annotation",
              phase11_state["saw_request1"] and phase11_state["saw_request2"]
              and body2 is not None and annotation_ok and ordering_ok
              and phase11_state["queue_empty_at_end"] is True and rc11 == 0,
              f"{phase11_state} body2_found={body2 is not None} "
              f"annotation_ok={annotation_ok} ordering_ok={ordering_ok} rc={rc11}\n"
              + tg_timeline() + "\n" + out11[-2500:])
        # Phase 12: Telegram inline-keyboard menus (owner request 2026-09-07),
        # end-to-end over the real binary and the mock Bot API. /effort with
        # no argument answers with buttons; a tap (callback_query) runs the
        # ordinary /effort handler and freezes the menu; a tap from a foreign
        # user is dropped silently (not even answered); a tap while a turn is
        # running is answered with an alert and changes nothing.
        with tg_lock:
            tg_state["updates"].clear()
            tg_state["offsets"].clear()
            tg_state["sent"].clear()
            tg_state["posts"].clear()
            llm_state["marker"] = "sleep-now"
            llm_state["delay"] = 12
            llm_state["bodies"].clear()

        def tg_callback(uid, data, from_id=12345, msg_id=77):
            return {"update_id": uid, "callback_query": {
                "id": f"cq{uid}", "chat_instance": "-1", "data": data,
                "from": {"id": from_id, "is_bot": False, "first_name": "T"},
                "message": {"message_id": msg_id, "date": 0,
                            "text": "Current reasoning effort: menu",
                            "chat": {"id": 12345, "type": "private"}}}}

        def tg_posts():
            with tg_lock:
                return list(tg_state["posts"])

        def tg_sent():
            with tg_lock:
                return list(tg_state["sent"])

        def wait_for(pred, timeout_n=30):
            deadline = time.time() + timeout_n
            while time.time() < deadline:
                if pred():
                    return True
                time.sleep(0.2)
            return pred()

        p12 = {}

        def menu_button(menu, level_or_id):
            """callback_data of the button whose payload ends in :<value>."""
            rows = ((menu or {}).get("reply_markup") or {}).get("inline_keyboard") or []
            for row in rows:
                for b in row:
                    if (b.get("callback_data") or "").endswith(":" + level_or_id):
                        return b["callback_data"]
            return None

        def latest_menu():
            return next((m for m in reversed(tg_sent()) if "reply_markup" in m), None)

        def menus_seen():
            return sum(1 for m in tg_sent() if "reply_markup" in m)

        def phase12(pwait, push, pout, proc):
            push([tg_update(960, "/effort")])
            wait_for(lambda: menus_seen() >= 1, 30)
            p12["menu"] = latest_menu()
            high = menu_button(p12["menu"], "high") or "bm1:e:00000000:high"
            low = menu_button(p12["menu"], "low") or "bm1:e:00000000:low"
            # Foreign tapper: dropped silently — no answer, no edit, no reply.
            push([tg_callback(961, high, from_id=999)])
            time.sleep(3)
            p12["posts_after_foreign"] = tg_posts()
            # The paired user taps "high".
            push([tg_callback(962, high)])
            p12["tap_logged"] = pwait("Menu tap → /effort high", 30)
            wait_for(lambda: any("Reasoning effort set to high" in (m.get("text") or "")
                                 for m in tg_sent()), 30)
            p12["posts_after_tap"] = tg_posts()
            p12["sent_after_tap"] = tg_sent()
            # A turn is running (stalled mock): the tap is answered with an
            # alert, nothing changes, the keyboard stays.
            push([tg_update(963, "please sleep-now")])
            wait_for(lambda: any("sleep-now" in b for b in llm_bodies()), 30)
            push([tg_callback(964, low)])
            p12["busy_answered"] = wait_for(
                lambda: any(name == "answerCallbackQuery" and (body or {}).get("callback_query_id") == "cq964"
                            for name, body in tg_posts()), 20)
            p12["posts_after_busy"] = tg_posts()
            p12["sent_after_busy"] = tg_sent()
            pwait("Briglia ▸", 60)  # the stalled turn completes

        tg_mark("phase12-start")
        out12, rc12 = run_poller_phase({}, phase12, timeout_s=150)
        with tg_lock:
            llm_state["marker"] = "-- no stall after phase 12 --"
            llm_state["delay"] = 20

        menu = p12.get("menu") or {}
        keyboard = ((menu.get("reply_markup") or {}).get("inline_keyboard")) or []
        menu_data = [b.get("callback_data") for row in keyboard for b in row]
        menu_ctx = {(d or "").split(":")[2] for d in menu_data}
        check("telegram menus: /effort answers with an inline keyboard of the provider's levels + off, every button bound to one 8-hex context",
              [(d or "").split(":")[-1] for d in menu_data] == ["minimal", "low", "medium", "high", "xhigh", "off"]
              and all((d or "").startswith("bm1:e:") for d in menu_data)
              and len(menu_ctx) == 1 and re.fullmatch(r"[0-9a-f]{8}", next(iter(menu_ctx), ""))
              and "Current reasoning effort" in (menu.get("text") or ""),
              f"menu={menu}\n" + out12[-1500:])
        foreign = [(n, b) for n, b in p12.get("posts_after_foreign", [])
                   if n in ("answerCallbackQuery", "editMessageText")]
        check("telegram menus: a tap from a foreign sender is dropped silently (no answer, no edit)",
              not foreign and rc12 == 0, f"{foreign} rc={rc12}\n" + out12[-1500:])
        tap_posts = p12.get("posts_after_tap", [])
        answered = [b for n, b in tap_posts if n == "answerCallbackQuery"
                    and (b or {}).get("callback_query_id") == "cq962"]
        frozen = [b for n, b in tap_posts if n == "editMessageText" and (b or {}).get("message_id") == 77]
        applied = any("Reasoning effort set to high" in (m.get("text") or "") for m in p12.get("sent_after_tap", []))
        check("telegram menus: the paired tap is answered, the menu is frozen with the choice, the handler applies it",
              p12.get("tap_logged") and answered and not answered[0].get("show_alert")
              and frozen and "/effort high" in (frozen[0].get("text") or "")
              and "reply_markup" not in frozen[0] and applied,
              f"answered={answered} frozen={frozen} applied={applied}\n" + out12[-2000:])
        busy = [b for n, b in p12.get("posts_after_busy", []) if n == "answerCallbackQuery"
                and (b or {}).get("callback_query_id") == "cq964"]
        busy_frozen = [b for n, b in p12.get("posts_after_busy", []) if n == "editMessageText"
                       and "/effort low" in ((b or {}).get("text") or "")]
        busy_applied = any("set to low" in (m.get("text") or "") for m in p12.get("sent_after_busy", []))
        check("telegram menus: a tap while a turn runs gets an alert, no edit, no change",
              p12.get("busy_answered") and busy and busy[0].get("show_alert") is True
              and "A turn is running" in (busy[0].get("text") or "") and not busy_frozen and not busy_applied,
              f"busy={busy} frozen={busy_frozen} applied={busy_applied}\n" + out12[-2000:])
        try:
            with open(os.path.join(config_dir, "secrets.json")) as f:
                effort_saved = json.load(f).get("openai_compatible_reasoning_effort")
        except (OSError, ValueError):
            effort_saved = None
        check("telegram menus: the tapped effort is persisted (high), the busy tap (low) is not",
              effort_saved == "high", f"saved={effort_saved!r}")

        # Phase 13: stale-context menus (Codex R1, 2026-09-07). A keyboard
        # outlives the state it was built for: after a provider hop an old
        # OpenCode model button must NOT rewrite the custom profile's model;
        # after a model change an old effort button must not apply; a fresh
        # menu (positive control) still works; and a provider change that
        # lands WHILE the tap's acknowledgement is suspended on the network
        # is caught by the re-check right before the command runs.
        secrets_path = os.path.join(config_dir, "secrets.json")
        with open(secrets_path) as f:
            sec = json.load(f)
        sec.update({
            "opencode_api_key": "smoke-oc-key", "opencode_model": "glm-5.3-flash",
            "custom_endpoint_base_url": f"http://127.0.0.1:{llm_port}/v1",
            "custom_endpoint_api_key": "smoke-test-key", "custom_endpoint_model": "mock-model",
        })
        with open(secrets_path, "w") as f:
            json.dump(sec, f)
        os.chmod(secrets_path, 0o600)
        with tg_lock:
            tg_state["updates"].clear()
            tg_state["offsets"].clear()
            tg_state["sent"].clear()
            tg_state["posts"].clear()
            tg_state["stall_answer_ids"] = {"cq981"}
            llm_state["marker"] = "-- no stall in phase 13 --"

        def read_secrets():
            try:
                with open(secrets_path) as f:
                    return json.load(f)
            except (OSError, ValueError):
                return {}

        def sent_contains(needle):
            return any(needle in (m.get("text") or "") for m in tg_sent())

        def answered(cq):
            return [b for n, b in tg_posts() if n == "answerCallbackQuery" and (b or {}).get("callback_query_id") == cq]

        p13 = {}

        def phase13(pwait, push, pout, proc):
            push([tg_update(970, "/provider opencode")])
            p13["hop1"] = wait_for(lambda: sent_contains("Active provider: OpenCode Go"), 30)
            push([tg_update(971, "/model")])
            wait_for(lambda: menus_seen() >= 1, 30)
            oc_menu = latest_menu()
            p13["oc_menu_ok"] = menu_button(oc_menu, "glm-5.3-flash") == "bm1:m:opencode:glm-5.3-flash"
            glm = menu_button(oc_menu, "glm-5.3-flash") or "bm1:m:opencode:glm-5.3-flash"
            push([tg_update(972, "/provider custom")])
            p13["hop2"] = wait_for(lambda: sent_contains("Active provider: Custom endpoint"), 30)
            p13["secrets_before_stale_model"] = read_secrets()
            # (a) stale OpenCode model button on the custom profile.
            push([tg_callback(973, glm, msg_id=81)])
            p13["stale_model_answered"] = wait_for(lambda: bool(answered("cq973")), 20)
            time.sleep(1.5)
            p13["stale_model_answer"] = (answered("cq973") or [None])[0]
            p13["posts_after_stale_model"] = tg_posts()
            p13["sent_after_stale_model"] = tg_sent()
            p13["secrets_after_stale_model"] = read_secrets()
            # (b) stale effort button: menu built for custom+mock-model, then
            # the model changes by typed command, then the old "high" tap.
            push([tg_update(974, "/effort")])
            wait_for(lambda: menus_seen() >= 2, 30)
            high = menu_button(latest_menu(), "high") or "bm1:e:00000000:high"
            push([tg_update(975, "/model other-model")])
            p13["model_typed"] = wait_for(lambda: sent_contains("Model switched to other-model"), 30)
            push([tg_callback(976, high, msg_id=82)])
            p13["stale_effort_answered"] = wait_for(lambda: bool(answered("cq976")), 20)
            time.sleep(1.5)
            p13["stale_effort_answer"] = (answered("cq976") or [None])[0]
            p13["sent_after_stale_effort"] = tg_sent()
            p13["secrets_after_stale_effort"] = read_secrets()
            # (c) positive control: a fresh OpenCode menu still applies.
            push([tg_update(977, "/provider opencode")])
            wait_for(lambda: sum(1 for m in tg_sent() if "Active provider: OpenCode Go" in (m.get("text") or "")) >= 2, 30)
            push([tg_update(978, "/model")])
            wait_for(lambda: menus_seen() >= 3, 30)
            kimi = menu_button(latest_menu(), "kimi-k3") or "bm1:m:opencode:kimi-k3"
            push([tg_callback(979, kimi, msg_id=83)])
            p13["fresh_applied"] = wait_for(lambda: sent_contains("Model switched to kimi-k3"), 30)
            p13["secrets_after_fresh"] = read_secrets()
            # (d) race: tap a fresh OpenCode button whose acknowledgement the
            # mock stalls for 6 s; while it is suspended, the terminal hops
            # to custom. The re-check before applying must refuse the tap.
            push([tg_update(980, "/model")])
            wait_for(lambda: menus_seen() >= 4, 30)
            glm2 = menu_button(latest_menu(), "glm-5.3-flash") or "bm1:m:opencode:glm-5.3-flash"
            push([tg_callback(981, glm2, msg_id=84)])
            p13["race_ack_started"] = wait_for(lambda: bool(answered("cq981")), 20)
            proc.stdin.write(b"/provider custom\n")
            proc.stdin.flush()
            p13["race_hop"] = pwait("Active provider: Custom endpoint", 20)
            p13["race_refused"] = wait_for(lambda: sent_contains("Not applied") and sent_contains("outdated"), 30)
            time.sleep(1.5)
            p13["posts_after_race"] = tg_posts()
            p13["sent_after_race"] = tg_sent()
            p13["secrets_after_race"] = read_secrets()
            # Leave the config as the later checks expect it.
            push([tg_update(982, "/model mock-model")])
            wait_for(lambda: sent_contains("Model switched to mock-model"), 30)

        tg_mark("phase13-start")
        out13, rc13 = run_poller_phase({}, phase13, timeout_s=200)
        with tg_lock:
            tg_state["stall_answer_ids"] = set()

        before = p13.get("secrets_before_stale_model", {})
        after_m = p13.get("secrets_after_stale_model", {})
        sm_answer = p13.get("stale_model_answer") or {}
        sm_edits = [b for n, b in p13.get("posts_after_stale_model", []) if n == "editMessageText" and (b or {}).get("message_id") == 81]
        check("stale menus: an OpenCode model button tapped on the custom profile is refused with an alert, no edit, no reply, custom model untouched",
              p13.get("hop1") and p13.get("oc_menu_ok") and p13.get("hop2") and p13.get("stale_model_answered")
              and sm_answer.get("show_alert") is True and "outdated" in (sm_answer.get("text") or "")
              and "OpenCode Go" in (sm_answer.get("text") or "") and "Custom endpoint" in (sm_answer.get("text") or "")
              and not sm_edits
              and not any("Model switched" in (m.get("text") or "") for m in p13.get("sent_after_stale_model", []))
              and after_m.get("custom_endpoint_model") == "mock-model" and after_m.get("openai_compatible_model") == "mock-model"
              and after_m.get("opencode_model") == "glm-5.3-flash"
              and {k: v for k, v in after_m.items() if k.startswith("custom_endpoint_")}
                  == {k: v for k, v in before.items() if k.startswith("custom_endpoint_")}
              and rc13 == 0,
              f"{ {k: p13.get(k) for k in ('hop1', 'oc_menu_ok', 'hop2', 'stale_model_answered', 'stale_model_answer')} } "
              f"edits={sm_edits} custom_model={after_m.get('custom_endpoint_model')!r} rc={rc13}\n" + out13[-2500:])
        se_answer = p13.get("stale_effort_answer") or {}
        after_e = p13.get("secrets_after_stale_effort", {})
        check("stale menus: an effort button from before a model change is refused, effort unchanged",
              p13.get("model_typed") and p13.get("stale_effort_answered")
              and se_answer.get("show_alert") is True and "outdated" in (se_answer.get("text") or "")
              and not any("Reasoning effort set" in (m.get("text") or "") for m in p13.get("sent_after_stale_effort", []))
              and after_e.get("openai_compatible_reasoning_effort") == after_m.get("openai_compatible_reasoning_effort"),
              f"model_typed={p13.get('model_typed')} answer={se_answer}\n" + out13[-2000:])
        after_f = p13.get("secrets_after_fresh", {})
        check("stale menus: positive control — a fresh OpenCode menu button still applies",
              p13.get("fresh_applied") and after_f.get("opencode_model") == "kimi-k3",
              f"fresh_applied={p13.get('fresh_applied')} opencode_model={after_f.get('opencode_model')!r}\n" + out13[-2000:])
        after_r = p13.get("secrets_after_race", {})
        race_edits = [b for n, b in p13.get("posts_after_race", []) if n == "editMessageText" and (b or {}).get("message_id") == 84]
        check("stale menus: a provider hop landing while the tap's acknowledgement is suspended is caught before applying — refused, custom model untouched",
              p13.get("race_ack_started") and p13.get("race_hop") and p13.get("race_refused")
              and any("not applied" in ((b or {}).get("text") or "") for b in race_edits)
              and after_r.get("custom_endpoint_model") == "other-model"
              and after_r.get("openai_compatible_model") == "other-model"
              and not any("Model switched to glm-5.3-flash" in (m.get("text") or "") for m in p13.get("sent_after_race", [])),
              f"{ {k: p13.get(k) for k in ('race_ack_started', 'race_hop', 'race_refused')} } edits={race_edits} "
              f"custom_model={after_r.get('custom_endpoint_model')!r}\n" + out13[-2500:])

        # H2 (b): after every phase ran, nothing under the roots (projects/
        # and toolchain/ excluded) may carry a group/other bit — this catches
        # a writer that bypasses PrivateStorage and creates a wide file after
        # the last startup sweep.
        wide_entries = []
        for root in (data_root, config_root):
            if not os.path.isdir(root):
                continue
            if dir_mode(root) & 0o077:
                wide_entries.append(f"{root} {oct(dir_mode(root))}")
            for dirpath, dirnames, filenames in os.walk(root):
                if dirpath == root:
                    dirnames[:] = [d for d in dirnames if d not in ("projects", "toolchain")]
                for name in dirnames + filenames:
                    path = os.path.join(dirpath, name)
                    st = os.lstat(path)
                    if stat.S_ISLNK(st.st_mode) or not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
                        continue
                    if stat.S_IMODE(st.st_mode) & 0o077:
                        wide_entries.append(f"{path} {oct(stat.S_IMODE(st.st_mode))}")
        check("storage: no entry under the roots carries group/other bits after the poller phases",
              not wide_entries, "\n".join(wide_entries[:40]))
    finally:
        tg.shutdown()
        llm.shutdown()
        shutil.rmtree(home, ignore_errors=True)

    # 9. __setsid-exec trampoline: no controlling terminal, exit passthrough
    def run_under_pty(argv, timeout=60, send=None):
        """Run argv with a fresh pty as its controlling terminal (pty.fork
        also makes the child a session leader, exercising the trampoline's
        posix_spawn fallback — the hardest detachment case). `send` bytes
        are written to the pty up front — the line discipline buffers them
        until something in the child actually reads the terminal."""
        pid, master = pty.fork()
        if pid == 0:
            os.execv(argv[0], argv)
        if send:
            os.write(master, send)
        out = b""
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                out += b"[TEST TIMEOUT]"
                os.kill(pid, 9)
                break
            r, _, _ = select.select([master], [], [], remaining)
            if not r:
                continue
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        _, status = os.waitpid(pid, 0)
        os.close(master)
        return out.decode(errors="replace"), status

    tty_probe = 'if ( exec < /dev/tty ) 2>/dev/null; then echo HAS_TTY; else echo NO_TTY; fi'
    out, _ = run_under_pty(["/bin/sh", "-c", tty_probe])
    control_ok = "HAS_TTY" in out
    out, _ = run_under_pty([os.path.abspath(ADA), "__setsid-exec", "--", "/bin/sh", "-c", tty_probe])
    check("setsid-exec: child detached from controlling pty (sudo can't prompt)",
          control_ok and "NO_TTY" in out and "HAS_TTY" not in out,
          f"control_has_tty={control_ok} out={out[-300:]!r}")

    out, status = run_under_pty([os.path.abspath(ADA), "__setsid-exec", "--", "/bin/sh", "-c", "exit 7"])
    code = os.waitstatus_to_exitcode(status)
    check("setsid-exec: exit code passes through", code == 7, f"exit={code} out={out[-200:]!r}")

    # TerminalHandoff — the inverse contract of the trampoline: a wizard/
    # upgrade child that MUST talk to the terminal (sudo password, apt
    # conffile prompt) gets the foreground slot. Without the handoff,
    # Foundation's background process group means the child's terminal read
    # is SIGTTIN-stopped forever (the frozen Raspberry Pi apt-get bug) and
    # this test times out instead of echoing the line back.
    out, status = run_under_pty(
        [os.path.abspath(ADA), "__tty-handoff-selftest"], timeout=30, send=b"hello\n")
    code = os.waitstatus_to_exitcode(status)
    check("tty-handoff: prompting child reads the terminal via foreground handoff",
          "HANDOFF_GOT:hello" in out and code == 0, f"exit={code} out={out[-300:]!r}")

    # Quick-setup terminal lend (plan §8.8): a __gate-exec child that reads
    # stdin immediately on exec must own the foreground BEFORE it is released.
    out, status = run_under_pty(
        [os.path.abspath(ADA), "__gate-tty-selftest"], timeout=30, send=b"sudo-line\n")
    code = os.waitstatus_to_exitcode(status)
    check("gate-tty: handoff child reads the terminal (lend before RELEASE), foreground restored",
          "GATE_GOT:sudo-line" in out and code == 0, f"exit={code} out={out[-400:]!r}")
    # With the lend removed the same child is SIGTTIN-stopped: the job never
    # answers and times out (proving the order matters).
    out, status = run_under_pty(
        [os.path.abspath(ADA), "__gate-tty-selftest", "--skip-lend"], timeout=40, send=b"sudo-line\n")
    code = os.waitstatus_to_exitcode(status)
    check("gate-tty: without the lend the child cannot read the terminal (SIGTTIN stop or EIO; no output, job fails)",
          "GATE_GOT" not in out and code != 0, f"exit={code} out={out[-400:]!r}")
    # An injected tcsetpgrp failure closes the release pipe unwritten.
    out, status = run_under_pty(
        [os.path.abspath(ADA), "__gate-tty-selftest", "--fail-lend"], timeout=30, send=b"sudo-line\n")
    code = os.waitstatus_to_exitcode(status)
    check("gate-tty: failed lend → child never executes (exit 125 path), listener resumed, foreground restored",
          "GATE_GOT" not in out and code == 0, f"exit={code} out={out[-400:]!r}")

    # Fallback-shim signal forwarding: SIGTERM to the trampoline must reach
    # the detached child (MCP/LSP registry shutdowns terminate the tracked
    # PID — an unforwarded signal would orphan the server in its own session).
    pid, master = pty.fork()
    if pid == 0:
        os.execv(os.path.abspath(ADA),
                 [os.path.abspath(ADA), "__setsid-exec", "--", "/bin/sleep", "300"])
    time.sleep(1.5)
    kids = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True,
                          text=True).stdout.split()
    os.kill(pid, 15)
    deadline = time.time() + 10
    reaped = False
    while time.time() < deadline:
        rp, status = os.waitpid(pid, os.WNOHANG)
        if rp:
            reaped = True
            break
        time.sleep(0.2)
    child_dead = True
    for k in kids:
        try:
            os.kill(int(k), 0)
            child_dead = False
            os.kill(int(k), 9)
        except ProcessLookupError:
            pass
    if not reaped:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    os.close(master)
    check("setsid-exec: SIGTERM to shim forwarded to detached child",
          reaped and child_dead and len(kids) == 1,
          f"reaped={reaped} child_dead={child_dead} kids={kids}")

    # Selftest hygiene: no throwaway preference domain written during this
    # run survives it. cfprefsd can write the empty shell late under load;
    # the selftests' final sweep waits for it, and their stale sweep removes
    # anything an earlier run left — so give the last shell a moment here.
    leaked = _test_prefs_domains_since(smoke_started_at)
    if leaked:
        time.sleep(15)
        leaked = _test_prefs_domains_since(smoke_started_at)
    if leaked is not None:
        check("selftests leave no throwaway preference domains behind",
              not leaked, f"written during this run: {', '.join(sorted(leaked))} "
              f"(prefixes {', '.join(TEST_PREFS_PREFIXES)})")

    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
