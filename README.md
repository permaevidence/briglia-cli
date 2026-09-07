# Briglia CLI

Briglia — a personal AI agent — as a command-line tool. A sibling of the Briglia
macOS app sharing its core (agent loop, filesystem/bash/LSP tools, web
research orchestrator, subagents, long-term memory) with no GUI, no legal
databases, and no license-key checks. English throughout. Runs on macOS
and Linux.

## Install (prebuilt — no GitHub account, no Swift)

```sh
curl -fsSL https://github.com/permaevidence/briglia-cli/releases/latest/download/install.sh | bash
briglia setup                   # first-run wizard (~5 minutes)
briglia                         # chat; leave with /quit, /exit or Ctrl-C
```

Prebuilt binaries: macOS arm64 (Apple Silicon), Linux x64, Linux arm64.
To update later: `briglia upgrade` in a terminal, or send `/upgrade` from
Telegram (or type it in the chat) — Briglia downloads the release, verifies it,
swaps itself, and restarts in place, confirming when it's back online.
Remote `/upgrade` needs a user-writable install dir (sudo installs must use
the terminal command). The installer and the updater both verify the
release's SHA-256 checksum before installing.

## Install from source (development)

```sh
git clone https://github.com/permaevidence/briglia-cli.git
cd briglia-cli
./scripts/install.sh        # builds release + installs the `briglia` command
```

To update later: `git pull && ./scripts/install.sh`.

### Linux notes

- Prebuilt binaries need no Swift toolchain (the Swift runtime is statically
  linked); only system `libcurl4` + `libxml2` are required — the installer
  checks and tells you the exact package command if they're missing.
- Building from source instead requires Swift 6+
  (https://www.swift.org/install/linux/ — swiftly is the easiest path).
  `./scripts/install.sh` tells you if it's missing.
- The media pipeline uses **poppler-utils** and **ImageMagick** instead of
  PDFKit/ImageIO — the setup wizard offers to install them (or:
  `sudo apt install poppler-utils imagemagick`). Verify any time with
  `briglia media-selftest`.
- Permissions: there is no Full Disk Access on Linux (plain file permissions
  apply). The wizard's permissions step instead checks **automatic suspend** —
  a suspended machine stops Briglia — and can disable it via GNOME `gsettings` or
  by masking the systemd sleep targets on headless boxes.
- The `shortcuts` tool and native text-layout PDF generation are macOS-only;
  document generation on Linux goes through the bundled skills (python).

Commands:

| command | |
| --- | --- |
| `briglia` / `briglia chat` | interactive chat REPL (`/stop`, `/status`, `/prune`, `/attach`, `/quit`) |
| `briglia setup` | setup wizard; rerun any single section later. Step 1 can configure SEVERAL main-agent providers (OpenCode Go, OpenRouter, OpenAI API, ChatGPT subscription, custom endpoint, local server) — hop between them anytime with `/provider <name>` in chat |
| `briglia quicksetup` | browser Quick Setup on a new installation; provider, model, ChatGPT account and tool-key settings on an existing installation |
| session affinity | requests to OpenCode Go carry the required `x-opencode-session` header and requests to OpenRouter the optional `x-session-id` (one opaque HMAC-derived value per conversation, subagent session or background run; state in `~/.local/share/briglia/affinity.json`, never exported, wiped by `/deleteuserdata`, refreshed by the hidden `/rotateaffinity`). The header is sent only to `opencode.ai` / `openrouter.ai` hosts directly — a proxy in front of OpenCode must add its own |
| `briglia daemon` | headless mode — Telegram channel only. One conversation-owning instance at a time: `briglia` and `briglia daemon` share state, so the second refuses to start |
| `briglia service install` | Linux: systemd user service for the daemon (auto-start at boot via linger; keep-awake support on Ubuntu Touch). `status`/`uninstall` included |
| `briglia toolchain` | Linux: install/upgrade/remove the media toolchain (poppler, ImageMagick, ffmpeg, optional LibreOffice/pandoc); userdata prefix on Ubuntu Touch |
| `briglia doctor [--online]` | configuration / permissions / toolchain health checks |
| `briglia migrate` | move an existing Ada CLI installation (`~/.config/ada`, `~/.local/share/ada`, service units, watchers) to Briglia — explicit, journaled, restores the old install if it cannot complete; the installer runs it as its last step when an old install is present |
| `briglia media-selftest` | verify the PDF/image pipeline (poppler/ImageMagick on Linux) |

## Storage

| path | contents |
| --- | --- |
| `~/.config/briglia/` | user-editable config: `secrets.json` (0600), `mcp.json`, `mcp-routing.json`, `agents/`, `skills/` |
| `~/.local/share/briglia/` | state: conversation, archive, sessions, attachments, logs, projects |
| `~/Documents/Briglia/` | landing zone: files Briglia receives, downloads or generates for you |

Both are XDG-style and distinct from Ada.app's paths, so the CLI and the app
coexist on the same Mac — and the same paths work unchanged on Linux.

## Scope — intentional omissions

Reviewers: the following are **deliberate design decisions**, not porting
gaps:

- **No Sparkle** — updating is one command: `briglia upgrade` in a terminal, or
  `/upgrade` from chat (Telegram or terminal), which also self-restarts.
  `/restart` re-execs in place without updating — the remote way to apply
  configuration that loads at startup (mcp.json, skills).
  Both pull the latest prebuilt release from the CDN, verify its SHA-256,
  and swap the binary + resource bundle in place (source installs:
  `git pull && ./scripts/install.sh`).
- **No local Whisper (WhisperKit)** — voice transcription is cloud-only
  (OpenAI). The `/transcribe_local` command surface is inherited from
  Ada.app and non-functional here.
- **No legal databases, no licensing** — this fork predates and excludes the
  Ada.app legal product surface entirely.
- **No computer-use tools, no GUI** — headless by definition.
- **English only** — Ada.app's Italian localization is intentionally dropped;
  remaining Italian strings are cleanup debt, not a localization effort.
- **File-based secrets, not the macOS Keychain** — a from-source binary gets
  a new code identity every rebuild, so Keychain use means blocking consent
  prompts on every update (and headless runs hang). `secrets.json` (0600) is
  the same posture as `~/.aws/credentials`.
- **WhatsApp deferred** (not deleted) — Telegram is the only channel wired
  into the wizard for now.
- **Service installer is systemd-only** — `briglia service install` covers
  Linux (including Ubuntu Touch); a macOS launchd generator is future
  work — run `briglia daemon` in a terminal there.

## ChatGPT subscription

Briglia can connect your own ChatGPT account while keeping its own prompts,
local history, tools, memory and agent loop. This is a separate provider from
OpenAI API billing; it never falls back to a paid API key automatically.

```sh
briglia subscription login             # browser verification with a device code
briglia subscription login --browser   # local callback on port 1455
briglia subscription status
briglia subscription cancel            # also clears an interrupted pending login
briglia subscription select --model gpt-5.6-luna --effort high
briglia subscription logout
```

Choose **ChatGPT subscription** in `briglia setup` or in desktop Quick Setup.
Both use the same native device-code sign-in and check the selected model before
saving. Quick Setup replaces the OpenCode-key requirement with subscription login;
its OpenAI API tool key remains separate. The companion Ubuntu Touch app exposes
the same provider in Settings and Quick Setup when the CLI advertises support.
Older CLIs keep their existing setup menus.

Stop the daemon before terminal activation or replacement of an active ChatGPT
login. Re-login on an already-active terminal profile refreshes its runtime scope
and preserves model/effort unless flags override them. Otherwise login saves the
profile; `/provider chatgpt` selects it when idle. Telegram re-login works when the
active account is signed out or requires authentication.
In the paired private Telegram chat, `/subscription login` starts device login,
`/subscription cancel` cancels it, and `/subscription logout` signs out locally.
Device login may need enabling in ChatGPT security settings. Do not send access
or refresh tokens in chat. Browser login expires after five minutes; device
login after fifteen. Briglia never reads or changes Codex's login cache.

OAuth credentials stay in the owner-only `subscription-auth.json` in Briglia's
config directory. Refresh is serialized between processes; logout invalidates
pending login callbacks and future requests. `/deleteuserdata` cancels pending
login and signs out locally; Mind import cancels pending login while retaining an
established account. An already-dispatched inference
may complete after logout. A failed credential-store write is reported; a
remote refresh followed by a local disk failure can require signing in again.

Token usage is available; subscription quota currently displays as unknown,
which does not mean unlimited. `subscription models` lists compatibility
candidates, not a live account-entitlement catalog. Unsupported models fail
explicitly. Image generation, transcription, web search and independently
configured services retain their own credentials and may incur API costs.
Use `/cachestats` in Briglia's paired chat or `briglia cache-stats` in the terminal
for recorded cache coverage. `briglia cache-stats --json` exposes the individual
attempts, including model, operation, input/cached/cache-write/output/reasoning
counters when reported, HTTP status and retry number. Missing usage stays unknown;
a reported zero is a cache miss. The ledger retains at most 1,000 attempts in the
owner-only `responses_usage.json` (2 MiB ceiling), including main turns, subagents,
maintenance and the web agent's separate Responses calls. Subscription, OpenAI
API and custom Responses traffic are reported separately. Chat Completions and
non-model tool requests and setup/doctor probes are outside this ledger. Prompts, account identifiers,
credentials, ciphertext and routing token values are never recorded. Mind exports
exclude this diagnostic state; `/deleteuserdata` clears it, including preserved
damaged copies. A malformed ledger is preserved beside the original and a fresh
ledger starts on the next recorded request. Read-only diagnostics report the
problem without changing files; unsafe permissions or a future format are never
silently reset. Recording failures
warn once and never prevent a model request; lost records cannot be reconstructed.

Subscription requests echo the first valid `x-codex-turn-state` response header
only within the same turn/operation, including its retries and tool rounds. New
turns and maintenance operations use a fresh owner. This complements the existing
stable `prompt_cache_key` and `session_id`; it does not guarantee cache hits or
establish how cached tokens affect subscription allowances.

Subscription tool media currently uses the labeled synthetic-observation
fallback. Opaque reasoning is replayed only for the same model/login scope;
ordinary token refresh preserves it, while logout/reconnect invalidates it.

This integration uses the public OAuth-client compatibility route also used by
Pi and OpenCode, with Briglia attribution. It is not an official OpenAI client;
availability depends on your account, workspace permissions and the upstream
service. The companion Ubuntu Touch login screens require a compatible app
update; physical Pixel onboarding is not yet verified for this release.

## Development

Read `AGENTS.md` before contributing changes — it records the build/test
commands and the invariants every change must preserve. Security reports:
see `SECURITY.md`.

CI builds and smoke-tests every push on Ubuntu (Swift container) and macOS:
version/doctor checks, the media-selftest, and a full chat turn against a
mock OpenAI-compatible server. Platform seams live in
`TelegramConcierge/Utilities/PlatformCompat.swift` (shell, process signals,
binary lookup) and `PlatformMedia.swift` (AdaPDF + PlatformImage); Linux
swaps CryptoKit → swift-crypto and Combine → OpenCombine via
platform-conditional package dependencies.

## License

Briglia CLI is **source-available** (not open source) under the Business
Source License 1.1 — see `LICENSE`. Production use is free for individual
people, including commercial use as a freelancer or sole proprietor;
companies and other entities need a commercial license (contact address in
`LICENSE`). Non-production use — evaluation, development, testing — is
free for everyone. Each released version automatically converts to
Apache-2.0 four years after its release. Third-party components are listed
in `THIRD_PARTY_NOTICES.md`.

External contributions are not being accepted yet while the contribution
policy (CLA) is finalized — bug reports and security reports are very
welcome.

### Browser settings after installation

Run `briglia quicksetup` whenever you want to update a provider, model, reasoning
effort, or tool API key. Existing installations open a settings page; new ones
still use the guided installation flow. All six provider profiles are available:
OpenCode Go, OpenRouter, OpenAI API, ChatGPT subscription, a custom endpoint, and
a local server. Model IDs can be entered directly; OpenCode choices are also
suggested from the bundled catalog.

Verify and save one section at a time. A blank provider key keeps the saved key;
the browser never receives stored keys. Adding a provider keeps the current
provider active unless you select “Use this as the active provider.” ChatGPT
sign-in is separate from the API key used by web research, voice, and images.

When Briglia is running, the command asks that process to serve the page. Saving
waits for user retry if a turn, background subagent, or maintenance task is busy;
a successful save reloads the affected services before admitting another turn.
Sign-in polling also waits for idle, up to the device code’s expiry. Busy responses
do not consume the connection-retry allowance. Signing out of the active ChatGPT
profile stops new turns until you sign in again or select another provider.
When Briglia is stopped, the settings command holds its instance lease, so a
second agent cannot start during configuration. Closing the command keeps saved
changes. A running older version without browser-settings support must be
updated/restarted or stopped first.

The page listens only on `127.0.0.1`, with a single-use five-minute launch link and
an HttpOnly session cookie. Opening another link revokes the previous session.
After 30 minutes without page activity, the server closes. Opening the page on a
remote machine requires local browser access or an explicitly configured SSH
tunnel; the listener is never exposed on the network. Telegram pairing, email
installation and system changes remain in `briglia setup`.
