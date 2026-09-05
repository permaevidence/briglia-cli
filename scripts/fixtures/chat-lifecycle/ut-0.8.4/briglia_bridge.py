"""Python backend for the Briglia Ubuntu Touch app (PyOtherSide bridge).

All device-side work lives here: detecting/installing the Briglia CLI binary
and talking to its machine-readable setup surface (`briglia setup-api`,
briglia-cli docs/UT_APP_PLAN.md §1, schema 2). The QML layer renders state
and calls these functions asynchronously; long operations report progress
through pyotherside.send() events.

Contract notes:
- setup-api requests go as one JSON object on the child's stdin, NEVER on
  argv (argv is world-readable via /proc).
- The install flow mirrors scripts/get-briglia.sh in briglia-cli: signed
  release envelope (verified with the baked CLI key, anti-rollback —
  release_verify) → authenticated platform tarball (size-bounded, hashed
  while streaming) → briglia + resources next to each other in ~/.local/bin
  → --version + bundle-check smoke, then PATH wiring for login shells (UT's
  Terminal app reads ~/.profile).
- A phone that still runs the CLI under its previous identity ("ada") is
  detected READ-ONLY here (legacy_status) and migrated ONLY through the
  CLI's own explicit engine — `briglia setup-api migrate`, the verb twin of
  `briglia migrate` (rename plan §4.2/§5). Nothing in this module moves,
  deletes or rewrites the old install itself.
"""

import errno
import getpass
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import release_verify

try:
    import pyotherside
except ImportError:  # unit-testing off-device
    class _NullSide:
        @staticmethod
        def send(*args):
            pass
    pyotherside = _NullSide()

# Where the CLI comes from: release_verify.CLI_POLICY (signed GitHub
# Releases channel, pinned key, pinned artifact location). Nothing here is
# read from the environment on purpose — see release_verify's docstring.
INSTALL_DIR = os.path.expanduser("~/.local/bin")
BRIGLIA = os.path.join(INSTALL_DIR, "briglia")
BUNDLE_NAME = "briglia-cli_briglia.resources"  # SwiftPM resource artifact on Linux
# EXACT match required (rename plan §4.1): schema 1 is the previous identity's
# interface, anything newer is a CLI this app build does not understand.
SETUP_API_SCHEMA = 2

# The project website. One constant, referenced by every user-facing hint;
# the final hostname is confirmed at cutover (rename plan §6/§8) and changes
# here only.
WEBSITE_BASE = "https://briglia.vercel.app"
WEBSITE_APP_PAGE = WEBSITE_BASE + "/ubuntu-touch"
WEBSITE_QR_PAGE = WEBSITE_BASE + "/qr"

# ---- the previous identity ("ada"), for detection only. Every literal that
# names the retired product lives in this block on purpose. The paths are
# module attributes (not baked into closures) so the selftest can point them
# at a fixture home; the app never overrides them.
LEGACY_BINARY = os.path.join(INSTALL_DIR, "ada")
LEGACY_CONFIG_ROOT = os.path.expanduser("~/.config/ada")
LEGACY_DATA_ROOT = os.path.expanduser("~/.local/share/ada")
LEGACY_USER_UNIT = os.path.expanduser("~/.config/systemd/user/ada.service")
LEGACY_WAKELOCK_UNIT_NAME = "ada-keepawake.service"
LEGACY_WAKELOCK_UNIT_PATH = "/etc/systemd/system/ada-keepawake.service"


# ---------------------------------------------------------------- helpers

def _run(argv, stdin_text=None, timeout=120):
    """Run a child process; returns (returncode, stdout, stderr).

    Children never inherit the app's stdin: with no stdin_text they get
    /dev/null, so a child that reads stdin (e.g. `cat`) sees EOF instead
    of blocking forever on a descriptor nobody will write to."""
    try:
        if stdin_text is None:
            result = subprocess.run(
                argv, stdin=subprocess.DEVNULL, capture_output=True,
                text=True, timeout=timeout)
        else:
            result = subprocess.run(
                argv, input=stdin_text, capture_output=True, text=True,
                timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except FileNotFoundError:
        return 127, "", "%s: not found" % argv[0]
    except subprocess.TimeoutExpired:
        return 124, "", "%s: timed out after %ss" % (argv[0], timeout)
    except OSError as exc:
        return 126, "", str(exc)


def _fetch(url, timeout=60):
    request = urllib.request.Request(url, headers={"User-Agent": "briglia-ut-app"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _telegram_api(token, method, params):
    """One Bot API call. Returns the decoded JSON object; Telegram answers
    4xx with a JSON body carrying `description`, which is returned rather
    than raised so the caller can show it. The token appears only in the
    URL of this in-process request — never in the returned payload."""
    url = "https://api.telegram.org/bot%s/%s?%s" % (
        token, method, urllib.parse.urlencode(params))
    request = urllib.request.Request(url, headers={"User-Agent": "briglia-ut-app"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read()
    return json.loads(body.decode("utf-8", "replace"))


def telegram_get_chat(token, chat_id):
    """Quick setup (Codex, 2026-09-03): the chat ID decides who may operate
    Briglia remotely, so it is verified against Telegram (getChat), not
    just for numeric syntax. Mirrors the CLI's pairing rule: private
    chats only. Returns {ok, label} or {ok: False, error}."""
    token = (token or "").strip()
    chat_id = (chat_id or "").strip()
    if not token or not chat_id:
        return {"ok": False, "error": "token and chat ID are both required"}
    try:
        payload = _telegram_api(token, "getChat", {"chat_id": chat_id})
    except Exception as exc:  # network, timeout, malformed body
        return {"ok": False, "error": "could not reach Telegram: %s" % exc}
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        desc = payload.get("description") if isinstance(payload, dict) else None
        result = {"ok": False, "error": "Telegram rejected the chat ID: %s"
                  % (desc or "unknown error")}
        if desc and "chat not found" in desc.lower():
            result["code"] = "chat_not_found"   # fresh bot: user must /start it
        return result
    chat = payload.get("result") or {}
    kind = chat.get("type")
    if kind != "private":
        return {"ok": False, "error": "chat %s is a %s, not a private chat — Briglia "
                "pairs only with your own private chat (get the number from "
                "@userinfobot)" % (chat_id, kind or "unknown type")}
    name = " ".join(x for x in (chat.get("first_name"), chat.get("last_name")) if x)
    label = name or chat_id
    if chat.get("username"):
        label += " (@%s)" % chat["username"]
    return {"ok": True, "label": label, "chat_id": str(chat.get("id", chat_id))}


def _progress(stage, percent, message):
    pyotherside.send("install", stage, int(percent), message)


# ---------------------------------------------------------------- detect

def legacy_status():
    """Read-only look at a previous-identity ("ada") installation on this
    device. Nothing here is authoritative for the migration decision once
    Briglia is installed — `setup-api status`.migration is (the CLI owns
    that gate) — but the app needs this BEFORE Briglia exists (to offer
    "install Briglia, it migrates your data") and AFTER the migration (the
    keep-awake system unit is root-owned; an unprivileged `migrate` records
    it and leaves the swap to this app's sudo dialog, plan §5).

    `binary` is true only for a REAL file: after a migration the same path
    is the compatibility symlink to briglia (plan §4.6), reported as
    `compat_symlink` instead."""
    is_link = os.path.islink(LEGACY_BINARY)
    binary = os.path.isfile(LEGACY_BINARY) and not is_link
    config_root = os.path.isdir(LEGACY_CONFIG_ROOT)
    data_root = os.path.isdir(LEGACY_DATA_ROOT)
    roots = [path for present, path in ((config_root, LEGACY_CONFIG_ROOT),
                                        (data_root, LEGACY_DATA_ROOT)) if present]
    return {
        "binary": binary,
        "compat_symlink": is_link,
        "config_root": config_root,
        "data_root": data_root,
        "roots": roots,
        "user_unit": os.path.isfile(LEGACY_USER_UNIT),
        "wakelock_unit": os.path.isfile(LEGACY_WAKELOCK_UNIT_PATH),
        "wakelock_unit_name": LEGACY_WAKELOCK_UNIT_NAME,
        # "An old install is here": data roots or the old binary. The units
        # alone (leftover files) are not an install.
        "present": binary or config_root or data_root,
    }


def detect():
    """What's on this device right now. Cheap enough to run on every page."""
    info = {
        "binary_path": BRIGLIA,
        "installed": False,
        "version": None,
        "status": None,
        "error": None,
        "legacy": legacy_status(),
    }
    if not os.access(BRIGLIA, os.X_OK):
        return info
    code, out, err = _run([BRIGLIA, "--version"], timeout=30)
    if code != 0:
        info["error"] = "briglia --version failed: %s" % (err or out).strip()[:300]
        return info
    info["installed"] = True
    info["version"] = out.strip()
    # Chat capability signal: the daemon's app-chat socket (every Briglia
    # release serves it; the check stays because a -dev build's version
    # string is not comparable, and the live socket wins over the version
    # string). Same resolution rule as chat_client.socket_path() (env seam
    # included) so the two can't drift.
    info["release_verifier"] = release_verify.provider_status()
    info["chat_socket"] = os.path.exists(os.environ.get(
        "BRIGLIA_CHAT_SOCKET",
        os.path.expanduser("~/.local/share/briglia/app-chat.sock")))
    status = setup_api("status")
    if status.get("ok"):
        info["status"] = status
    else:
        info["error"] = _describe_api_error(status)
    return info


# ---------------------------------------------------------------- identity migration
#
# Rename plan §4.2/§5: the ONLY thing that moves an old ("ada") installation
# to Briglia is the CLI's own journaled engine. This app reaches it through
# setup-api's `migrate` verb — same spec, same crash-safety, same refusals
# as `briglia migrate` in a terminal — strictly behind the consent page
# (MigratePage.qml). Diagnostics (`detect`, `setup-api status`) never
# migrate; the CLI's status block (`migration.needed / conflict /
# journal_state`) is the authority the page renders.

def migrate(rollback=False):
    """Run (or recover, or — before its commit point — roll back) the
    identity migration. Returns setup-api's response verbatim: on success
    {"ok": true, "outcome": "migrated"|"rolled_back"|"nothing_to_do",
    "notes": [...], "log": [...], "migration": {...}}; on failure the
    engine's typed error ("migration_refused" | "migration_journal_corrupt"
    | "migration_failed") with its "log". The engine holds an exclusive
    lock, so a second concurrent call refuses instead of racing."""
    request = {"rollback": True} if rollback else {}
    return setup_api("migrate", request)


# The one property of a served root script that must hold before it may run
# under sudo: with `set -e`, a failing middle step would otherwise exit with
# the system partition left writable. Content check, not a version compare.
ROOT_SCRIPT_TRAP_MARKER = "trap 'mount -o remount,ro /"


def legacy_wakelock_uninstall_script():
    """The removal script the PREVIOUS identity served for its keep-awake
    unit (`… setup-api service keepawake_script:true` → wakelock_uninstall_
    script), reproduced byte-for-byte in shape. After a migration the old
    binary is retired (parked), so it cannot be asked — and the unit it
    installed is root-owned, so an unprivileged `migrate` only records it
    (plan §4.3.5) and leaves the swap to this app's sudo dialog."""
    return (
        "#!/bin/sh\n"
        "# Legacy (ada) keep-awake unit removal (Ubuntu Touch). Run as root: sudo sh <this-file>\n"
        "set -e\n"
        "mount -o remount,rw /\n"
        "trap 'mount -o remount,ro / || echo \"note: / stays read-write until reboot (busy)\"' EXIT INT TERM HUP\n"
        "systemctl disable --now %s || true\n"
        "rm -f %s\n"
        "systemctl daemon-reload\n"
        % (LEGACY_WAKELOCK_UNIT_NAME, LEGACY_WAKELOCK_UNIT_PATH))


def legacy_wakelock_swap_script():
    """Compose the ONE root script that swaps the keep-awake unit after a
    migration: Briglia's unit is installed FIRST (the script the CLI itself
    serves, trap-gated), the legacy unit is removed AFTER — the two overlap
    on purpose so the phone cannot suspend in between (plan §4.3/§5). A
    failure in the install half stops the script (`set -e`) with the legacy
    unit still holding the wakelock; the swap is idempotent, so a retry is
    safe. Returns {"ok", "script", "error"}; nothing runs here."""
    if not os.path.isfile(LEGACY_WAKELOCK_UNIT_PATH):
        return {"ok": False, "script": None,
                "error": "no legacy keep-awake unit is installed — nothing to swap"}
    served = setup_api("service", {"keepawake_script": True})
    if not served.get("ok"):
        return {"ok": False, "script": None, "error": _describe_api_error(served)}
    install = served.get("wakelock_install_script") or ""
    if not install.strip():
        return {"ok": False, "script": None,
                "error": "the CLI did not serve a keep-awake install script"}
    if ROOT_SCRIPT_TRAP_MARKER not in install:
        return {"ok": False, "script": None,
                "error": "the served keep-awake script lacks the read-only restore "
                         "trap — refusing to run it as root"}
    if LEGACY_WAKELOCK_UNIT_NAME in install:
        return {"ok": False, "script": None,
                "error": "the served keep-awake script still names the legacy unit — "
                         "refusing (is the installed CLI really Briglia?)"}
    uninstall = legacy_wakelock_uninstall_script()
    if ROOT_SCRIPT_TRAP_MARKER not in uninstall:  # defensive: same gate, same rule
        return {"ok": False, "script": None, "error": "internal: legacy removal script lacks the trap"}
    script = (install.rstrip("\n") + "\n\n"
              "# --- Briglia's unit is up; now retire the legacy unit (deliberate overlap)\n"
              + uninstall)
    return {"ok": True, "script": script, "error": None}


def swap_legacy_wakelock(passcode):
    """Run the composed swap as root (passcode contract of run_privileged_
    script: stdin only, never stored). The verdict is TRUTHFUL about what
    landed: a script that exited 0 but left the legacy unit file behind is
    reported as a failure, never as done."""
    composed = legacy_wakelock_swap_script()
    if not composed["ok"]:
        passcode = None
        return {"ok": False, "output": "", "error": composed["error"],
                "legacy_unit_remaining": os.path.isfile(LEGACY_WAKELOCK_UNIT_PATH)}
    result = run_privileged_script(composed["script"], passcode)
    passcode = None
    remaining = os.path.isfile(LEGACY_WAKELOCK_UNIT_PATH)
    result["legacy_unit_remaining"] = remaining
    if result.get("ok") and remaining:
        result["ok"] = False
        result["error"] = ("the swap script finished but the legacy unit file %s is still "
                           "present — retry, or remove it by hand" % LEGACY_WAKELOCK_UNIT_PATH)
    return result


# ---------------------------------------------------------------- files

def list_dir(path):
    """Directory listing for the chat attachment picker. Hidden entries are
    skipped; directories sort first. Errors (permission, gone) come back as
    data, never exceptions."""
    resolved = os.path.expanduser(path or "~")
    try:
        names = os.listdir(resolved)
    except OSError as exc:
        return {"ok": False, "error": str(exc), "path": resolved}
    entries = []
    for name in names:
        if name.startswith("."):
            continue
        full = os.path.join(resolved, name)
        try:
            is_dir = os.path.isdir(full)
            # Only regular files are selectable attachments: a FIFO or
            # device node here would pass a naive exists+size check and
            # could hang or exhaust the Briglia daemon (it refuses them too —
            # this keeps the picker from offering guaranteed-nack rows).
            if not is_dir and not os.path.isfile(full):
                continue
            size = 0 if is_dir else os.path.getsize(full)
        except OSError:
            continue
        entries.append({"name": name, "path": full, "dir": is_dir, "size": size})
    entries.sort(key=lambda e: (not e["dir"], e["name"].lower()))
    parent = os.path.dirname(resolved.rstrip("/")) or "/"
    return {"ok": True, "path": resolved, "parent": parent,
            "entries": entries}


# ---------------------------------------------------------------- setup-api

def setup_api(verb, request=None):
    """One setup-api round trip. Returns the decoded response object, or a
    synthesized {"ok": False, "error": {...}} when the call itself failed."""
    argv = [BRIGLIA, "setup-api", verb]
    stdin_text = None
    if verb != "status":
        stdin_text = json.dumps(request or {})
    # Toolchain installs run apt over phone networks — minutes, not seconds.
    # LibreOffice's closure is a few hundred MB, so give it real headroom.
    # The identity migration stops/starts services, moves the data roots
    # and runs a 60 s health probe before retiring anything: minutes too.
    if verb == "apply" and isinstance(request, dict) and "toolchain" in request:
        timeout = 5400
    elif verb == "migrate":
        timeout = 900
    else:
        timeout = 180
    code, out, err = _run(argv, stdin_text=stdin_text, timeout=timeout)
    try:
        payload = json.loads(out) if out.strip() else None
    except ValueError:
        payload = None
    if payload is None:
        return {"ok": False, "error": {
            "code": "no_response",
            "message": ("setup-api produced no JSON (exit %s): %s"
                        % (code, (err or out).strip()[:300]))}}
    if payload.get("schema") != SETUP_API_SCHEMA:
        return {"ok": False, "error": {
            "code": "schema_mismatch",
            "message": _schema_mismatch_message(payload.get("schema"))}}
    return payload


def _schema_mismatch_message(seen):
    """Exact-schema gate wording: an OLDER schema means the installed CLI
    predates this app (schema 1 = the previous identity's interface), a
    NEWER one means the app is behind."""
    if isinstance(seen, int) and seen < SETUP_API_SCHEMA:
        return ("this CLI speaks setup-api schema %s; the app needs schema %s "
                "(Briglia CLI 0.2.0 or newer) — update the CLI" % (seen, SETUP_API_SCHEMA))
    return ("setup-api schema %s (app speaks %s) — update the app"
            % (seen, SETUP_API_SCHEMA))


def _describe_api_error(payload):
    error = payload.get("error") or {}
    return error.get("message") or error.get("code") or "unknown setup-api error"


# ---------------------------------------------------------------- install

def _platform_key():
    machine = platform.machine()
    if machine == "aarch64":
        return "linux-arm64"
    if machine == "x86_64":
        return "linux-x64"
    return None


# Extraction guards: the archive is checksum-verified against our own CDN,
# but defend anyway (Codex, 2026-08-27): tarfile's data filter (Python 3.12+,
# UT 24.04 ships 3.12) rejects absolute paths, traversal, escaping links and
# special files; the count/size caps bound a corrupted-but-valid-checksum
# archive.
MAX_ARCHIVE_MEMBERS = 4000
MAX_EXTRACTED_BYTES = 600 * 2**20

# os.replace seam — the transactional-swap selftest injects faults here.
_rename = os.replace


def _journal_path():
    return os.path.join(INSTALL_DIR, ".briglia-install-journal.json")


def _fsync_dir(path):
    """Directory-entry durability: fsync on a FILE does not guarantee its
    directory entry reached storage — the containing directory must be
    synced as well (fsync(2), Codex round 4).

    Returns None on success — or on a benign "this filesystem doesn't
    support directory fsync" refusal (EINVAL/ENOTSUP), where power-loss
    ordering falls back to kernel flush behavior. A REAL I/O error is
    returned as a message: transaction-critical callers must treat it as
    failure instead of silently losing the durability guarantee (Codex
    round 5); ordering-aid callers may ignore the return."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError as exc:
        return "open %s: %s" % (path, exc)
    try:
        os.fsync(fd)
    except OSError as exc:
        if exc.errno in (errno.EINVAL, errno.ENOTSUP):
            return None
        return "fsync %s: %s" % (path, exc)
    finally:
        os.close(fd)
    return None


def _remove_live(path, is_dir):
    if is_dir:
        if os.path.isdir(path):
            shutil.rmtree(path)
    elif os.path.isfile(path):
        os.unlink(path)


def _recover_interrupted_swap(bundle_dest):
    """Crash recovery, run BEFORE any network access (Codex, 2026-08-27
    rounds 2-3). A transaction journal written before the first rename and
    deleted right after post-swap validation makes every crash state
    decidable — including the FIRST-ever install, which has no .old
    backups to fall back on:

    - Journal present ⇒ the transaction never completed. Roll back to the
      journal's pre-install state: restore every parked .old component
      over whatever is live; delete a live component the journal says did
      not exist before (the fresh-install half-swap — round 3's finding).
      Worst case is rolling back an install that validated but crashed
      before its journal delete: fresh → back to "not installed", upgrade
      → the older working version; the starting install replaces it.
    - Journal absent ⇒ the last transaction completed (or never started),
      so any stray .old is post-success garbage: DELETE it — restoring
      only one of two .old files here is what produced mixed-version
      installs. .new staging leftovers are never load-bearing.

    Returns a failure message (nothing downloaded) or None."""
    journal_path = _journal_path()
    journal = None
    if os.path.isfile(journal_path):
        try:
            with open(journal_path) as f:
                journal = json.load(f)
        except (OSError, ValueError):
            # Unreadable journal: treat the transaction as incomplete with
            # unknown priors — restore what is parked, touch nothing else.
            journal = {}

    components = (
        (BRIGLIA, BRIGLIA + ".old", False, "had_binary"),
        (bundle_dest, bundle_dest + ".old", True, "had_bundle"),
    )

    def cleanup_staging():
        if os.path.isfile(BRIGLIA + ".new"):
            try:
                os.unlink(BRIGLIA + ".new")
            except OSError:
                pass
        shutil.rmtree(bundle_dest + ".new", ignore_errors=True)

    if journal is not None:
        # Two-barrier recovery (Codex round 5 — a power cut between the
        # journal unlink and the directory sync could persist the DELETION
        # while the repairs were lost, making a later boot treat the
        # half-swap as complete):
        #   1. every repair + staging cleanup, journal RETAINED throughout;
        #   2. barrier — the repairs must be durable, or we stop with the
        #      journal in place so the next run retries;
        #   3. journal unlink = the repair's commit point;
        #   4. ordering aid — if this last sync fails, a reboot re-runs the
        #      (idempotent) recovery against an already-repaired tree.
        for live, parked, is_dir, had_key in components:
            try:
                if os.path.exists(parked):
                    _remove_live(live, is_dir)
                    os.rename(parked, live)
                elif journal.get(had_key) is False and os.path.exists(live):
                    _remove_live(live, is_dir)
            except OSError as exc:
                return ("an interrupted previous install could not be repaired "
                        "(%s) — nothing was downloaded; fix the problem and try again" % exc)
        cleanup_staging()
        if sync_failure := _fsync_dir(INSTALL_DIR):
            return ("the interrupted-install repair could not be made durable "
                    "(%s) — nothing was downloaded; try again" % sync_failure)
        try:
            os.unlink(journal_path)
        except OSError as exc:
            return ("could not clear the install journal (%s) — nothing was "
                    "downloaded; fix the problem and try again" % exc)
        _fsync_dir(INSTALL_DIR)
    else:
        # Post-success garbage only — non-transactional, best-effort.
        for _live, parked, is_dir, _had_key in components:
            if is_dir:
                shutil.rmtree(parked, ignore_errors=True)
            elif os.path.isfile(parked):
                try:
                    os.unlink(parked)
                except OSError:
                    pass
        cleanup_staging()
        _fsync_dir(INSTALL_DIR)
    return None


def _extract_release(tarball, dest):
    """Safe extraction. Returns None or a failure message."""
    try:
        with tarfile.open(tarball) as archive:
            members = archive.getmembers()
            if len(members) > MAX_ARCHIVE_MEMBERS:
                return "archive has %d members (limit %d)" % (
                    len(members), MAX_ARCHIVE_MEMBERS)
            total = sum(m.size for m in members)
            if total > MAX_EXTRACTED_BYTES:
                return "archive expands to %d MB (limit %d MB)" % (
                    total // 2**20, MAX_EXTRACTED_BYTES // 2**20)
            for member in members:
                if not (member.isreg() or member.isdir() or member.issym()):
                    return "unsupported member type in archive: %s" % member.name
            try:
                archive.extractall(dest, filter="data")
            except TypeError:
                # Python < 3.12 has no extraction filter and is not a
                # supported target — refuse rather than extract unsafely.
                return "Python >= 3.12 is required to install safely"
    except tarfile.FilterError as exc:
        return "unsafe path in archive: %s" % exc
    except Exception as exc:
        return "could not unpack the download: %s" % exc
    return None


def _validate_staged(staged_binary):
    """Run the STAGED binary before anything is touched: version, bundle,
    and — the compatibility gate — setup-api with our schema. Returns
    (version, None) or (None, failure message)."""
    code, out, err = _run([staged_binary, "--version"], timeout=30)
    if code != 0:
        return None, "downloaded binary failed --version: %s" % (err or out).strip()[:300]
    version = out.strip()
    code, out, err = _run([staged_binary, "bundle-check"], timeout=30)
    if code != 0:
        return None, "downloaded bundle check failed: %s" % (err or out).strip()[:300]
    code, out, err = _run([staged_binary, "setup-api", "status"], timeout=60)
    try:
        payload = json.loads(out) if out.strip() else None
    except ValueError:
        payload = None
    if payload is None:
        return None, ("this Briglia CLI release (%s) predates the app's setup interface — "
                      "it was NOT installed. Try again after the next CLI release."
                      % version)
    if payload.get("schema") != SETUP_API_SCHEMA:
        return None, ("this Briglia CLI release (%s): %s — it was NOT installed."
                      % (version, _schema_mismatch_message(payload.get("schema"))))
    return version, None


def install():
    """Download + verify + STAGE + validate + transactionally swap the Briglia
    CLI (mirrors briglia-cli's own UpgradeService: nothing existing is touched
    until the new release fully validated, the swap is same-volume renames,
    and any failure rolls both components back). Emits
    pyotherside.send('install', stage, percent, message); returns
    {"ok": bool, "version": str|None, "error": str|None}."""
    def fail(message):
        _progress("error", 0, message)
        return {"ok": False, "version": None, "error": message}

    key = _platform_key()
    if key is None:
        return fail("unsupported architecture: %s" % platform.machine())

    bundle_dest = os.path.join(INSTALL_DIR, BUNDLE_NAME)
    # First, repair any interrupted previous transaction — strictly before
    # the network is touched, so a flaky download can never cost the
    # restored installation.
    recovery_failure = _recover_interrupted_swap(bundle_dest)
    if recovery_failure:
        return fail(recovery_failure)

    _progress("manifest", 2, "Fetching the signed release metadata…")
    try:
        manifest = release_verify.resolve_release(release_verify.CLI_POLICY)
    except release_verify.ReleaseVerifyError as exc:
        return fail("release metadata refused (%s): %s" % (exc.kind, exc))
    entry = manifest["platforms"].get(key)
    if entry is None:
        return fail("no build for %s in the signed release" % key)
    version = manifest["version"]

    _progress("download", 5, "Downloading Briglia CLI %s…" % version)
    tmp_dir = tempfile.mkdtemp(prefix="briglia-ut-install-")
    try:
        tarball = os.path.join(tmp_dir, "briglia.tar.gz")

        def on_progress(done, total):
            _progress("download", 5 + 70 * done // total,
                      "Downloading… %d / %d MB" % (done // 2**20, total // 2**20))
        # The bound and the hash are the AUTHENTICATED ones from the
        # envelope; a server lying about Content-Length changes nothing.
        download_failure = release_verify.download_to_file(
            entry["url"], tarball, entry["size"], entry["sha256"],
            progress=on_progress)
        if download_failure:
            return fail(download_failure)
        _progress("verify", 78, "Checksum verified")

        _progress("extract", 82, "Unpacking…")
        extract_failure = _extract_release(tarball, tmp_dir)
        if extract_failure:
            return fail(extract_failure)
        staged_binary = os.path.join(tmp_dir, "briglia")
        staged_bundle = os.path.join(tmp_dir, BUNDLE_NAME)
        if not os.path.isfile(staged_binary) or not os.path.isdir(staged_bundle):
            return fail("unexpected tarball layout — expected briglia + %s" % BUNDLE_NAME)

        _progress("check", 86, "Checking the downloaded release…")
        os.chmod(staged_binary, 0o755)
        staged_version, staged_failure = _validate_staged(staged_binary)
        if staged_failure:
            return fail(staged_failure)

        # Stage .new siblings inside INSTALL_DIR (same volume, so the swap
        # below is pure renames); copies can fail here with nothing touched.
        _progress("installing", 92, "Installing to ~/.local/bin…")
        try:
            os.makedirs(INSTALL_DIR, exist_ok=True)
            shutil.copy2(staged_binary, BRIGLIA + ".new")
            os.chmod(BRIGLIA + ".new", 0o755)
            shutil.copytree(staged_bundle, bundle_dest + ".new")
        except OSError as exc:
            for leftover in (BRIGLIA + ".new",):
                if os.path.isfile(leftover):
                    os.unlink(leftover)
            shutil.rmtree(bundle_dest + ".new", ignore_errors=True)
            return fail("could not stage the install: %s" % exc)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    # Transactional swap: park the old components, move the new ones in,
    # roll EVERYTHING back on any failure. Renames on one volume. The
    # journal (fsynced before the first rename, deleted right after
    # validation) is what makes a CRASH at any point decidable — see
    # _recover_interrupted_swap.
    had_binary = os.path.isfile(BRIGLIA)
    had_bundle = os.path.isdir(bundle_dest)
    # Power-loss protocol (Codex round 4): staged contents durable first,
    # then the journal written ATOMICALLY (tmp + fsync + rename) with its
    # directory entry synced — only then may renames begin. Every later
    # phase syncs INSTALL_DIR so the on-storage order matches the logical
    # order recovery reasons about.
    journal_tmp = _journal_path() + ".tmp"
    try:
        os.sync()  # staged .new contents + entries down before the journal exists
        with open(journal_tmp, "w") as journal_file:
            json.dump({"had_binary": had_binary, "had_bundle": had_bundle,
                       "version": staged_version}, journal_file)
            journal_file.flush()
            os.fsync(journal_file.fileno())
        os.replace(journal_tmp, _journal_path())
        if sync_failure := _fsync_dir(INSTALL_DIR):
            raise OSError("journal directory sync failed: %s" % sync_failure)
    except OSError as exc:
        for leftover in (BRIGLIA + ".new", journal_tmp):
            if os.path.isfile(leftover):
                os.unlink(leftover)
        shutil.rmtree(bundle_dest + ".new", ignore_errors=True)
        return fail("could not record the install journal: %s" % exc)
    undo = []  # (src, dst) renames that restore the previous state
    try:
        if had_binary:
            _rename(BRIGLIA, BRIGLIA + ".old")
            undo.append((BRIGLIA + ".old", BRIGLIA))
        _rename(BRIGLIA + ".new", BRIGLIA)
        undo.append((BRIGLIA, BRIGLIA + ".new"))
        if had_bundle:
            _rename(bundle_dest, bundle_dest + ".old")
            undo.append((bundle_dest + ".old", bundle_dest))
        _rename(bundle_dest + ".new", bundle_dest)
        undo.append((bundle_dest, bundle_dest + ".new"))
        # Post-swap sanity on the LIVE paths (bundle-next-to-binary).
        code, out, err = _run([BRIGLIA, "bundle-check"], timeout=30)
        if code != 0:
            raise OSError("installed bundle check failed: %s" % (err or out).strip()[:300])
        # Barrier: the swap renames must be durable BEFORE the commit
        # point — a real sync failure means we cannot commit, so roll back.
        if sync_failure := _fsync_dir(INSTALL_DIR):
            raise OSError("pre-commit directory sync failed: %s" % sync_failure)
    except OSError as exc:
        for src, dst in reversed(undo):
            try:
                _rename(src, dst)
            except OSError:
                pass  # partial rollback: detected below
        # Rollback is complete when every pre-existing component is back on
        # its live path, nothing new remained live, and nothing is parked.
        incomplete = (
            (had_binary and not os.path.isfile(BRIGLIA))
            or (not had_binary and os.path.isfile(BRIGLIA))
            or (had_bundle and not os.path.isdir(bundle_dest))
            or (not had_bundle and os.path.isdir(bundle_dest))
            or os.path.isfile(BRIGLIA + ".old")
            or os.path.isdir(bundle_dest + ".old"))
        if os.path.isfile(BRIGLIA + ".new"):
            os.unlink(BRIGLIA + ".new")
        shutil.rmtree(bundle_dest + ".new", ignore_errors=True)
        # Same two-barrier shape as recovery: the journal survives unless
        # the rollback is BOTH structurally complete and durable, so the
        # next run retries the repair otherwise.
        rollback_sync = _fsync_dir(INSTALL_DIR)
        if incomplete or rollback_sync:
            note = " (rollback incomplete — the next install repairs it first)"
        else:
            note = ""
            try:
                os.unlink(_journal_path())
            except OSError:
                pass  # recovery re-runs the (now no-op) rollback next time
            _fsync_dir(INSTALL_DIR)  # ordering aid; failure = idempotent re-run
        return fail("install swap failed: %s%s" % (exc, note))

    # Success. The pre-commit barrier already ran inside the try block
    # (renames durable). Clearing the journal is the COMMIT POINT, and the
    # .old backups may be deleted ONLY once that deletion is known durable
    # (Codex round 6): with the journal's fate uncertain, dropping backups
    # opens a mixed-version reboot — journal resurfaces with only one .old
    # left, recovery restores that one component and keeps the other new
    # one. Both failure paths below therefore keep BOTH backups and report
    # honestly; the state is safe either way a reboot lands (journal
    # present → full rollback to the old version; journal absent → both
    # backups discarded as garbage, the validated new install stays).
    def commit_failure(reason):
        _progress("error", 0, reason)
        return {"ok": False, "version": None, "error": reason}
    try:
        os.unlink(_journal_path())
    except OSError as exc:
        return commit_failure(
            "installed, but the commit could not be recorded (%s) — a reboot "
            "may revert to the previous version; run install again to finish" % exc)
    if sync_failure := _fsync_dir(INSTALL_DIR):
        return commit_failure(
            "installed, but the commit could not be made durable (%s) — a reboot "
            "may revert to the previous version; run install again to finish" % sync_failure)
    # Commit durable: the backups are garbage now. A power cut during this
    # cleanup is safe — journal-absent recovery discards any survivor.
    if os.path.isfile(BRIGLIA + ".old"):
        os.unlink(BRIGLIA + ".old")
    shutil.rmtree(bundle_dest + ".old", ignore_errors=True)
    _fsync_dir(INSTALL_DIR)  # ordering aid only

    _wire_login_shell_path()
    # Anti-rollback floor: recorded ONLY now that the release is live and
    # committed. A failure to persist it is reported, not fatal — the
    # embedded minimum still applies and the next successful install
    # records again.
    trust_note = None
    try:
        release_verify.record_accepted(release_verify.CLI_POLICY, manifest)
    except OSError as exc:
        trust_note = "could not record the anti-rollback floor: %s" % exc
    _progress("done", 100, "Briglia CLI %s installed" % staged_version)
    return {"ok": True, "version": staged_version, "error": None,
            "sequence": manifest["sequence"], "trust_note": trust_note}


# ---------------------------------------------------------------- service & privileged helpers (M4)
#
# Passcode handling contract (UT_APP_PLAN.md §2.5): the passcode reaches this
# module only as a function argument, travels ONLY on sudo's stdin (`sudo -S`,
# empty -p prompt), is never placed on argv, never logged, never stored; the
# local reference is dropped before returning. Scripts run under sudo are
# written to a 0600 file in a private temp dir and deleted afterwards.

def _sudo_result(code, out, err):
    if code == 0:
        return {"ok": True, "output": (out or "").strip()[-2000:], "error": None}
    detail = (err or out or "").strip()[-2000:]
    if code == 1 and ("try again" in detail.lower() or "incorrect password"
                      in detail.lower() or detail == ""):
        detail = "wrong passcode (or sudo refused)" + (" — " + detail if detail else "")
    return {"ok": False, "output": (out or "").strip()[-2000:], "error": detail}


def run_sudo_command(command_text, passcode):
    """Run one server-supplied command line as root. The API hands the app
    literal commands like "sudo loginctl enable-linger phablet"; the leading
    `sudo ` is stripped and the remainder runs via `sudo -S sh -c`."""
    command = command_text.strip()
    if command.startswith("sudo "):
        command = command[len("sudo "):]
    if not command:
        return {"ok": False, "output": "", "error": "empty privileged command"}
    code, out, err = _run(["sudo", "-S", "-p", "", "sh", "-c", command],
                          stdin_text=(passcode or "") + "\n", timeout=120)
    passcode = None
    return _sudo_result(code, out, err)


def run_privileged_script(script_text, passcode):
    """Run a multi-line root script (the wakelock install/uninstall scripts
    served by `setup-api service keepawake_script:true`). The script body is
    briglia-cli's own — this function only transports it to root."""
    if not (script_text or "").strip():
        return {"ok": False, "output": "", "error": "empty privileged script"}
    script_dir = tempfile.mkdtemp(prefix="briglia-ut-priv-")
    script_path = os.path.join(script_dir, "script.sh")
    try:
        fd = os.open(script_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(script_text)
        code, out, err = _run(["sudo", "-S", "-p", "", "sh", script_path],
                              stdin_text=(passcode or "") + "\n", timeout=180)
        passcode = None
        return _sudo_result(code, out, err)
    except OSError as exc:
        return {"ok": False, "output": "", "error": str(exc)}
    finally:
        shutil.rmtree(script_dir, ignore_errors=True)


def default_linger_command():
    """Fallback "enable start at boot" command for CLI releases that don't
    yet serve service.linger_command in status (v0.1.43 serves it only in
    the install response). Same text setup-api emits; the server-provided
    value wins whenever present so the two can't drift in practice."""
    try:
        user = getpass.getuser()
    except (KeyError, OSError):
        user = os.environ.get("USER", "")
    if not user:
        return ""
    return "sudo loginctl enable-linger " + user


_SERVICE_ACTIONS = ("start", "stop")


def systemctl_user(action):
    """Start/stop the installed briglia.service. Restart and install/uninstall go
    through `setup-api service` (which also returns the fresh status block);
    this covers the two verbs that API deliberately doesn't own."""
    if action not in _SERVICE_ACTIONS:
        return {"ok": False, "output": "",
                "error": "unsupported action %r (start|stop only)" % (action,)}
    code, out, err = _run(["systemctl", "--user", action, "briglia.service"],
                          timeout=60)
    if code == 0:
        return {"ok": True, "output": (out or "").strip(), "error": None}
    return {"ok": False, "output": (out or "").strip(),
            "error": (err or out or "systemctl exit %s" % code).strip()[:2000]}


def tail_journal(lines=40):
    """Last N journal lines of briglia.service, for the dashboard log card."""
    try:
        count = max(1, min(int(lines), 500))
    except (TypeError, ValueError):
        count = 40
    code, out, err = _run(["journalctl", "--user", "-u", "briglia.service",
                           "-n", str(count), "--no-pager", "-o", "short-iso"],
                          timeout=30)
    if code == 0:
        return {"ok": True, "text": out.rstrip(), "error": None}
    return {"ok": False, "text": "",
            "error": (err or out or "journalctl exit %s" % code).strip()[:2000]}


def _wire_login_shell_path():
    """Same PATH wiring as get-briglia.sh: UT's Terminal app runs bash as a LOGIN
    shell, so ~/.profile matters alongside ~/.bashrc. Best-effort."""
    line = 'export PATH="$HOME/.local/bin:$PATH"'
    for rc in ("~/.bashrc", "~/.profile"):
        path = os.path.expanduser(rc)
        try:
            if os.path.isfile(path):
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    if ".local/bin" in f.read():
                        continue
            with open(path, "a", encoding="utf-8") as f:
                f.write("\n%s\n" % line)
        except OSError:
            pass  # PATH is a convenience; the app always uses absolute paths

# ---------------------------------------------------------- app self-update
# The click itself, not the CLI: scripts/publish_click.sh publishes each
# release as an immutable GitHub Release of permaevidence/briglia-ut (click +
# signed envelope, release_verify.APP_POLICY), and this unconfined app may
# install its own new package. The running instance keeps executing OLD
# code after a successful install — callers must tell the user to close and
# reopen the app.

# A click is ~250 KB; bound what even an AUTHENTICATED manifest can make us
# download (a signed-but-absurd size is still refused).
MAX_CLICK_BYTES = 20 * 2**20


def _app_settings_path():
    return os.environ.get(
        "BRIGLIA_UT_APP_SETTINGS_PATH",
        os.path.expanduser("~/.cache/briglia.permaevidence/app-settings.json"))


def app_settings():
    """App-local preferences (NOT Briglia's config). Missing/corrupt file ==
    defaults; auto_update defaults OFF — updating is opt-in."""
    try:
        with open(_app_settings_path()) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    return {"auto_update": data.get("auto_update") is True}


def set_app_setting(key, value):
    if key != "auto_update":
        return {"ok": False, "error": "unknown app setting: %s" % key}
    settings = app_settings()
    settings[key] = bool(value)
    path = _app_settings_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(settings, f)
        os.replace(tmp, path)
    except OSError as exc:
        return {"ok": False, "error": "could not save setting: %s" % exc}
    return {"ok": True, "settings": settings}


def app_own_version():
    """The running app's version, from the manifest.json the click ships in
    its data area (build_click.py packages it next to py/ and qml/)."""
    manifest_path = os.environ.get(
        "BRIGLIA_UT_APP_MANIFEST",
        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "manifest.json"))
    try:
        with open(manifest_path) as f:
            version = json.load(f).get("version")
        return version if isinstance(version, str) and version else None
    except (OSError, ValueError):
        return None


def _version_ints(value):
    try:
        return [int(x) for x in
                str(value).strip().lstrip("v").split("-")[0].split(".")]
    except ValueError:
        return None


def _version_newer(remote, local):
    """True only when remote is STRICTLY newer. Unparseable versions are
    False: never install something we cannot compare (no downgrades, no
    sideways moves — a bad manifest must not replace a working app)."""
    r, l = _version_ints(remote), _version_ints(local)
    if r is None or l is None:
        return False
    n = max(len(r), len(l))
    r += [0] * (n - len(r))
    l += [0] * (n - len(l))
    return r > l


def app_update_check():
    installed = app_own_version()
    if installed is None:
        return {"ok": False, "error": "cannot read the app's own version"}
    try:
        manifest = release_verify.resolve_release(release_verify.APP_POLICY)
    except release_verify.ReleaseVerifyError as exc:
        return {"ok": False, "kind": exc.kind,
                "error": "update metadata refused (%s): %s" % (exc.kind, exc)}
    entry = manifest["platforms"].get("click")
    if entry is None:
        return {"ok": False, "kind": "bad-platform",
                "error": "the signed release lists no click package"}
    filename = entry["filename"]  # already a plain asset name (validated)
    if not filename.endswith(".click"):
        return {"ok": False, "kind": "bad-platform",
                "error": "the signed release's package is not a .click"}
    return {"ok": True, "installed": installed, "available": manifest["version"],
            "filename": filename, "sha256": entry["sha256"],
            "size": entry["size"], "url": entry["url"],
            "sequence": manifest["sequence"], "floor": manifest["floor"],
            "trust_note": manifest["trust_note"],
            "update_available": _version_newer(manifest["version"], installed)}


# Lomiri launches apps with a slimmer PATH than the Terminal's login shell
# (field bug, Pixel 2026-08-28: bare "pkcon" → exit 127 while the same
# command works in Terminal), so resolve pkcon by absolute path too.
PKCON_CANDIDATES = ("/usr/bin/pkcon", "/usr/local/bin/pkcon", "/bin/pkcon",
                    "/usr/sbin/pkcon")


def _pkcon_path():
    found = shutil.which("pkcon")
    if found:
        return found
    for candidate in PKCON_CANDIDATES:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


# Modern Ubuntu Touch images (24.04, field bug 2026-08-28) do not ship the
# pkcon CLI AT ALL — the sanctioned installer is the com.lomiri.click
# system D-Bus service, which is exactly what OpenStore itself calls
# (Install(path); an error reply means failure, a normal reply means the
# install completed). Call it through busctl/gdbus — absolute candidates
# again, Lomiri's slim PATH — and keep pkcon only as the older-image
# fallback. When neither exists, the advice must be one that works
# everywhere: OpenStore via Morph, NOT a pkcon Terminal command.
CLICK_DBUS_SERVICE = ("com.lomiri.click", "/com/lomiri/click",
                      "com.lomiri.click")
DBUS_TOOL_CANDIDATES = (("busctl", ("/usr/bin/busctl", "/bin/busctl")),
                        ("gdbus", ("/usr/bin/gdbus", "/bin/gdbus")))


def _dbus_tool():
    override = os.environ.get("BRIGLIA_UT_CLICK_DBUS_TOOL")
    if override == "none":
        return None
    if override:
        return override
    for name, candidates in DBUS_TOOL_CANDIDATES:
        found = shutil.which(name)
        if found:
            return found
        for candidate in candidates:
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
    return None


def _dbus_install(tool, click_path):
    service, objpath, iface = CLICK_DBUS_SERVICE
    if "busctl" in os.path.basename(tool):
        cmd = [tool, "call", "--system", "--timeout=300",
               service, objpath, iface, "Install", "s", click_path]
    else:
        cmd = [tool, "call", "--system", "--timeout", "300",
               "--dest", service, "--object-path", objpath,
               "--method", iface + ".Install", click_path]
    return _run(cmd, timeout=320)


def _install_click(click_path):
    """Install a staged click. Returns (ok, error_text). Tries the
    com.lomiri.click D-Bus service first, pkcon second; the final error
    lists every attempt so a field report shows the whole picture."""
    attempts = []
    tool = _dbus_tool()
    if tool is not None:
        code, out, err = _dbus_install(tool, click_path)
        if code == 0:
            return True, ""
        attempts.append("%s → com.lomiri.click Install failed (exit %d): %s"
                        % (os.path.basename(tool), code,
                           (err or out).strip()[:200]))
    else:
        attempts.append("no busctl/gdbus found for the com.lomiri.click "
                        "installer service")
    pkcon = _pkcon_path()
    if pkcon is not None:
        code, out, err = _run(
            [pkcon, "install-local", "--allow-untrusted", click_path],
            timeout=300)
        if code == 0:
            return True, ""
        attempts.append("pkcon failed (exit %d): %s"
                        % (code, (err or out).strip()[:200]))
    else:
        attempts.append("pkcon is not installed on this image")
    return False, (
        "could not install the update automatically — "
        + "; ".join(attempts)
        + ". Manual path that works on every device: open "
          + WEBSITE_APP_PAGE + " in Morph, download the new version, "
          "open the file and confirm the OpenStore prompt.")


def _registry_version():
    """Version in the system click registry's `current` manifest — the
    ground truth for what is actually installed. None when unreadable
    (developer machines, tests)."""
    base = os.environ.get("BRIGLIA_UT_CLICK_REGISTRY") \
        or "/opt/click.ubuntu.com/briglia.permaevidence"
    try:
        with open(os.path.join(base, "current", "manifest.json")) as f:
            return json.load(f).get("version")
    except (OSError, ValueError):
        return None


def _verify_registry(target):
    """Post-install truth check: an installer that RETURNED success must
    also have moved the registry to the target version. Unreadable
    registry → accept the installer's word (non-UT environments)."""
    wait = float(os.environ.get("BRIGLIA_UT_CLICK_REGISTRY_WAIT", "15"))
    deadline = time.time() + wait
    while True:
        seen = _registry_version()
        if seen is None or seen == target:
            return True, seen
        if time.time() >= deadline:
            return False, seen
        time.sleep(0.5)


def app_update_install():
    """Full chain: re-check → download → verify size+sha256 → install
    (com.lomiri.click D-Bus first, pkcon fallback) → click-registry truth
    check. Returns updated=False when already current (not an error)."""
    checked = app_update_check()
    if not checked.get("ok"):
        return checked
    if not checked["update_available"]:
        return {"ok": True, "updated": False,
                "installed": checked["installed"],
                "available": checked["available"]}
    if checked["size"] > MAX_CLICK_BYTES:
        return {"ok": False,
                "error": "update is implausibly large (%d bytes)"
                         % checked["size"]}
    staging_dir = os.path.dirname(_app_settings_path())
    click_path = os.path.join(staging_dir, checked["filename"])
    try:
        os.makedirs(staging_dir, exist_ok=True)
    except OSError as exc:
        return {"ok": False, "error": "could not stage the download: %s" % exc}
    try:
        # Authenticated url + exact size bound + streaming hash.
        download_failure = release_verify.download_to_file(
            checked["url"], click_path, checked["size"], checked["sha256"])
        if download_failure:
            return {"ok": False, "error": download_failure}
        ok, error = _install_click(click_path)
        if not ok:
            return {"ok": False, "error": error[:600]}
        verified, seen = _verify_registry(checked["available"])
        if not verified:
            return {"ok": False,
                    "error": "the installer reported success but the click "
                             "registry still shows v%s — the update did not "
                             "actually land; try installing from Morph + "
                             "OpenStore instead" % seen}
        # The new app is verified installed: raise this device's floor for
        # the app channel so nothing older is ever accepted again.
        trust_note = None
        try:
            release_verify.trust_record(release_verify.APP_POLICY.trust_domain,
                                        checked["sequence"])
        except OSError as exc:
            trust_note = "could not record the anti-rollback floor: %s" % exc
    finally:
        try:
            os.unlink(click_path)
        except OSError:
            pass
    return {"ok": True, "updated": True, "needs_relaunch": True,
            "installed": checked["installed"],
            "available": checked["available"],
            "sequence": checked["sequence"], "trust_note": trust_note}


def app_auto_update():
    """Launch hook. Does NOTHING — including no network — unless the user
    turned the auto-update setting on."""
    if not app_settings()["auto_update"]:
        return {"ran": False}
    result = app_update_install()
    result["ran"] = True
    return result
