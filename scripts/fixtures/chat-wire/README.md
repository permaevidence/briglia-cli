# Legacy request compatibility gate

P0 review-2 safeguards are under verification. Do not start P1 until independent
review accepts both the wire and lifecycle gates and their frozen references.

The original `darwin-arm64.json` and `linux-aarch64.json` are unchanged historical
v1 evidence from `d4767d9`: 36 **no-tools** requests, bodies and targets only.
They are not the P1 gate. Never overwrite them.

The v2 gate builds release source `4dd86133de03b484bed62fb81ce59935b89a7de8`
and the candidate on the **same current compiler/platform**, in disposable Git
worktrees, with the same test instrumentation. It compares two fresh processes
per build, then compares reference to candidate. No platform is skipped.

```sh
python3 scripts/chat_wire_baseline_test.py
python3 scripts/chat_wire_baseline.py
# Enforce the committed reference for local Apple Swift 6.3:
python3 scripts/chat_wire_baseline.py --baseline scripts/fixtures/chat-wire/local-darwin-arm64-r2.json
# Recording ALWAYS builds the pinned source, even after production changes:
python3 scripts/chat_wire_baseline.py --record /tmp/new-reviewed-reference.json
```

`--record` refuses overwrite. `--save-reference PATH` saves the pinned reference
while also comparing the candidate. CI runs the differential gate as a mandatory
step in both existing platform jobs, and retains the exact pinned reference as
an artifact. Branch protection configuration is separate from workflow execution.
`--scratch-root PATH` optionally retains Swift compilation caches.

## Precisely bounded instrumentation

The reference worktree receives only the capture parser, capture/affinity test
file and wire driver, plus hidden command registration. Their hashes are recorded. Historical frozen hashes describe the drivers that
created that evidence; newer drivers must match its bodies, headers and inventory
without regenerating it. Driver/comparator changes still require independent review.
The candidate retains all its production changes (including Utilities, Resources,
Package.swift and non-test CLI files); no production directories are replaced.

One explicitly checked OpenRouter endpoint literal is replaced **only in both
disposable builds**, using the loopback URL supplied by the driver. This exercises
`LLMProvider.openRouter`, provider preferences, Anthropic cache control, reasoning,
and headers without paid traffic. A missing or changed literal fails the gate.
A test-only flag is enabled only in those disposable copies; an environment
variable cannot enable OpenRouter in an ordinary selftest build. The ordinary
production source and installed binary are untouched. These are instrumented
release-source captures, **not unchanged shipped-binary captures**.

Inputs explicitly select the synthetic Google Workspace provider (no installed-CLI
inference or Google requests). Inputs fix the clock, synthetic names/key/context, UUIDs, salt, nonce and isolated
storage path. The driver exclusively creates `/tmp/briglia-chat-wire-fixture-v2`
and removes only its own directory. Concurrent/stale-directory collisions fail;
do not run this driver concurrently on the same host. It uses in-memory preference
overrides and isolated XDG secrets, never real credentials.

Comparison never parses/re-encodes request JSON. Base64 preserves the body bytes
without putting the reserved harness prefix in tracked files. Two substitutions
are narrowly defined and recorded:

* The captured `Host` value must equal this server's exact loopback authority;
  replace only its ephemeral port with `<capture-port>`.
* Replace at most one exact JSON-escaped `LandingZone.scratchReposRoot` absolute
  path with `/__fixture_home__/Documents/Briglia/scratch/repos`. It must equal an independent Foundation home-directory calculation plus the fixed suffix
  (Python and Foundation can resolve home differently in CI);
  the exact expected replacement count is checked and compared. All other paths are fixed.

Every other body byte, target and lowercased header key/value is compared, including
added/removed headers. Content-Length is validated against the original raw body
before substitution, then omitted as redundant. POST and credential routing also
have independent Swift assertions. No affinity value is masked.

## Matrix

The six original model IDs remain: `glm-5.3`, `kimi-k3`, `kimi-k2.7-code`,
`qwen3.8-max`, `custom-model`, `local-model`. Instrumented builds add actual
OpenRouter routing for `anthropic/claude-sonnet-4`: 7 models × 13 cases = 91.
Ordinary selftest builds run 78 cases with no OpenRouter traffic.

| Suffix | Scenario |
| --- | --- |
| 0 | Plain input; bare endpoint |
| 1 | Stored two-tool history/reasoning; forced-final instruction; `/v1/` |
| 2 | Historical annotation/next-turn replay; hostile text; summary tail |
| 3 | Reasoning from mismatching model/gateway |
| 4 | Current-round tool image and legacy synthetic user-role media |
| 5 | Rasterized PDF page (PNG), not raw PDF |
| 6 | Real default AvailableTools schemas, user skill, structured persona, calendar/email, chunk summary, current user ID, system tail |
| 7 | Populated main with subagents disabled |
| 8 | Populated main with deferred MCP summary and proxy tools |
| 9 | Populated main with a current-round, two-message typed batch and attachment path; canonical users last in history |
| 10 | Populated main with positively matching model AND gateway provenance for historical tool and final reasoning |
| 11 | Chat profile URL entered as `/v1/responses`; legacy result is `/v1/responses/v1/chat/completions` (OpenRouter's fixed endpoint is unaffected) |
| 12 | Text-only model + image tool output; missing OCR credentials produce the existing explicit inspect-media placeholder without inline image bytes |

Serialization fixtures do not claim to drive the ConversationManager delivery
acknowledgement, pruning decisions, usage watermarks or persistence/rehydration.
Archive/probe/subagent execution and shipped-client/Mind tests remain required.

## Independent affinity derivation

```python
import hashlib, hmac, struct
fingerprint = hashlib.sha256(b"synthetic-wire-key").digest()
lane = b"main:33333333-3333-4333-8333-333333333333"
message = b"briglia-affinity-v1" + b"".join(struct.pack(">I", len(p)) + p for p in (fingerprint, lane))
print(hmac.new(bytes(range(32)), message, hashlib.sha256).hexdigest()[:32])
# 772be81ca4a295114141686608dd0b89
```

Every P1 review must inspect diffs from `d4767d9` to the driver, comparator and
fixture directory. Later changes must be justified, reviewed and additive where
possible, with pinned-source provenance. Never change SOURCE or regenerate from
a changed candidate merely to make a gate pass. This gate cannot protect against
a reviewer accepting weakened fixtures or comparison logic.

Review-2 adds suffixes 11–12. The original 77 cases must still match their
previous frozen references; additions do not authorize changing those bytes.
CI references are compiler-specific; an image/compiler upgrade fails explicitly
and requires a reviewed pinned-SOURCE re-record. CI must pass `--baseline` in
addition to its current reference-versus-candidate comparison. Never re-record
from the candidate or silently update a file after a comparison failure.
