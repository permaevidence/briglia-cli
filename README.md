# Briglia CLI

**The agent that remembers: one continuous conversation, never a session.**

Other agents work in sessions. Your messages get compacted with everything else. And what you said days ago survives only as a retrieval target. We all know retrievals hit and miss.

Briglia on the other hand doesn't have a session based architecture. Messages and contents follow different paths. So your preferences and decisions stay in front of the agent without a search. The result is a memory that connects the dots without being asked.

It runs on a machine you own — a Mac or a Linux box — and you talk to it from anywhere through Telegram.

> In our [Thread benchmark](https://briglia.dev/benchmark), after about a month of everyday use (~300k tokens of conversation alone, not counting tool work), Briglia recalled **43 of 48** old facts. Hermes + Hindsight recalled 39, Codex 6.

```sh
curl -fsSL https://github.com/permaevidence/briglia-cli/releases/latest/download/install.sh | bash
briglia menu     # setup in your browser
```

Website and guides: **https://briglia.dev**

---

## How it remembers

A day of agent work produces far more material than conversation: tool calls, command output, file contents, reasoning. The messages you and Briglia actually exchanged are a small fraction of it, and they hold everything that matters: what you asked, what you decided, what you prefer, what was left open.

So Briglia keeps them on two separate paths:

| | what it is | what happens to it |
| --- | --- | --- |
| **Work** | tool calls, command output, files, reasoning | pruned once it's done; a full snapshot stays on disk |
| **Conversation** | your messages and Briglia's replies | archived verbatim, then fractal compaction: recent messages word for word, older stretches as summaries, the oldest as summaries of summaries |

**Fractal compaction, for messages only.** When the live conversation passes about 20k tokens, the oldest ~10k become a chunk: the transcript is saved verbatim as a plain-text file and summarised. Chunks consolidate as they age, and consolidated chunks roll into meta-summaries. The result is a timeline that gets coarser the further back it goes, always in chronological order, while every original transcript stays intact on disk.

**What the model sees on every request.** That timeline, from the first day to now, plus a profile of you distilled from it, plus the recent messages verbatim. Up to about 50k tokens of context on every request. Nothing has to be retrieved first: a decision from weeks ago is on the page, in order, next to what came before and after it.

**Grep like a sniper, not a blind search.** Most harnesses query a memory store and hope the right fragment comes back. Briglia already knows what was said and roughly when, so when it needs an exact detail it goes straight to the right transcript on disk. Fewer searches, and the ones it does hit.

That's why it brings up a decision from weeks ago without being asked.

Full details: [How Briglia remembers](https://briglia.dev/guides/memory).

## What it is

Briglia is a personal assistant and coding agent with full access to the computer it runs on, in the same family as Hermes Agent and OpenClaw. It has a real shell, the file system and the network. It writes and runs code, reads and produces documents, researches the web, manages email and calendar, watches things and tells you when they change, and runs long jobs while you're away.

It acts **without approval prompts**. That's why we recommend installing it on a separate machine, or in a virtual machine, rather than on the computer you use every day. Give it only the keys you're comfortable giving, and read the [terms](https://briglia.dev/terms) before you install.

- **Your model:** OpenRouter (recommended: DeepSeek V4.1 Flash on Together), ChatGPT subscription, OpenCode Go, any OpenAI-compatible endpoint, or a local server. Switch with `/provider`.
- **Your data:** everything lives in your home directory as plain files. `/deleteuserdata` removes it all. No telemetry, no accounts with us.
- **Your line in:** only your paired Telegram chat, your terminal or the phone app can talk to it.

## Install

Prebuilt binaries for macOS arm64 (Apple Silicon), Linux x64 and Linux arm64. The installer verifies the release's Ed25519 signature before anything runs ([how releases are signed](https://briglia.dev/security)).

```sh
curl -fsSL https://github.com/permaevidence/briglia-cli/releases/latest/download/install.sh | bash
briglia menu       # setup and settings in your browser (English / Italian)
briglia            # chat in the terminal; /quit to leave
briglia daemon     # headless, Telegram only
```

Update with `briglia upgrade`, or send `/upgrade` from Telegram.

More: [Install](https://briglia.dev/install) · [First setup](https://briglia.dev/guides/setup) · [Telegram](https://briglia.dev/guides/telegram) · [Always-on / Linux service](https://briglia.dev/guides/always-on) · [Providers](https://briglia.dev/reference/providers) · [All commands](https://briglia.dev/reference/commands) · [Ubuntu Touch app](https://briglia.dev/ubuntu-touch)

### From source

```sh
git clone https://github.com/permaevidence/briglia-cli.git
cd briglia-cli
./scripts/install.sh        # builds a release and installs the `briglia` command
```

Requires Swift 6+ ([swift.org/install](https://www.swift.org/install/)). On Linux, prebuilt binaries need only `libcurl4` and `libxml2`; the media pipeline uses poppler-utils and ImageMagick (`briglia media-selftest` checks it).

## Storage

| path | contents |
| --- | --- |
| `~/.config/briglia/` | config: `secrets.json` (0600), `mcp.json`, `agents/`, `skills/` |
| `~/.local/share/briglia/` | state: conversation, archive chunks, snapshots, sessions, logs |
| `~/Documents/Briglia/` | files Briglia receives, downloads or generates for you |

See [Storage & privacy](https://briglia.dev/guides/storage).

## Development

Read `AGENTS.md` before contributing changes: it records the build and test commands and the invariants every change must preserve. Security reports: see `SECURITY.md`. CI builds and smoke-tests every push on macOS and Ubuntu.

## License

Briglia CLI is **source-available** (not open source) under the Business Source License 1.1 — see `LICENSE`. Production use is free for individual people, including commercial use as a freelancer or sole proprietor; companies and other entities need a commercial license (contact address in `LICENSE`). Non-production use — evaluation, development, testing — is free for everyone. Each released version converts to Apache-2.0 four years after its release. Third-party components are listed in `THIRD_PARTY_NOTICES.md`.

External contributions are not being accepted yet while the contribution policy (CLA) is finalized — bug reports and security reports are very welcome.
