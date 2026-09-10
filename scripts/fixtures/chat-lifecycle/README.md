# Chat Completions lifecycle baseline (P0)

Run from the private code checkout:

```sh
python3 scripts/chat_lifecycle_baseline_test.py
python3 scripts/chat_lifecycle_baseline.py --baseline scripts/fixtures/chat-lifecycle/local-darwin-arm64-r2.json
# Record only from SOURCE, to a new path (never the candidate):
python3 scripts/chat_lifecycle_baseline.py --save-reference /new/path/reference.json
```

The runner creates **instrumented builds**, not unmodified shipped binaries. The
reference always uses v0.2.9 source at `4dd86133de03b484bed62fb81ce59935b89a7de8`.
It appends the same private-access seams and registers the same driver in two
throwaway worktrees. No production method body is extracted or reimplemented.
Candidate tracked changes and untracked production source remain in the candidate
build. Every standard UserDefaults access is redirected to a test suite; XDG
storage roots are set before services initialize. No installed binary is changed.

The only behavior substitutions are **inputs**: isolated preferences, specific
request-visible clocks, one subagent session's generated ID, and one context
structuring operation's UUID. Review-2 additionally fixes default Message IDs
and dates plus persisted usage/session dates, now that their raw bytes are
observed. These are entropy inputs; no encoder, retry policy or branch is
replaced. Progress and timeout clocks stay real. The seams
call the real manager budget/planning/pruning functions, actual main tool loop,
subagent runner and registry, archive summary builder, media rehydrator, setup
status and Mind exporter/importer. Scripted responses travel through real HTTP
and production response decoding; read_file executes on a synthetic file.

Port 49179 and the synthetic root `/tmp/briglia-chat-lifecycle-v1` are reserved
exclusively while a driver runs. Collisions fail; the harness never deletes a
pre-existing root. A killed/crashed driver can leave its root as evidence; inspect
that failed run before explicitly removing its own synthetic root and retrying.
The fixed port makes gateway provenance and affinity deterministic. There is no
port, model, reasoning, annotation, role, ordering or usage masking. Only the one
exact Foundation-derived scratch-repositories home path is replaced in known
populated-prompt fixtures, with an asserted substitution count. Original request
bytes are retained in `captures.json` before that substitution.

The gate runs each build in two fresh processes, asserts the complete inventory,
compares raw bodies and all headers (Content-Length is checked then omitted as
redundant), and compares observable pruning/state/accounting values. It imports
the candidate's no-Responses Mind export with the pinned-source importer and
executes the vendored, hash-checked UT 0.8.4 Python bridge on actual status. The
bridge also receives hypothetical additive profile fields; that is **not** proof
of P2 status compatibility. The actual P2 payload must pass this test later.

Frozen macOS fixtures are **per runner image**: the rendered PDF pages in the
media captures are JPEGs carrying the Apple ICC profile of the runner's OS image,
which changes when GitHub rolls the image. CI picks the fixture by `$ImageVersion`
and fails closed on an image without a reviewed fixture. Refresh procedure: record
from the pinned SOURCE on the new image (a macOS-only run with the upload-on-failure
artifact), run `scripts/chat_lifecycle_fixture_diff.py OLD NEW` and require that the
only differences are inside the ICC profile, then add the fixture and its provenance
in a separate reviewed commit. Never regenerate because a candidate differs.

`--candidate-only` is a development diagnostic and cannot create a frozen
reference. `--baseline` additionally compares a previously retained reference;
never update it simply because a new implementation differs. `--keep-trees`
retains instrumented worktrees for debugging. Normal runs remove their worktrees
but preserve logs and capture artifacts. Driver, comparator and instrumentation
diffs themselves need independent review, just like the original wire gate.

Coverage includes:

- High-watermark equality, estimated and measured usage, current-round deltas,
  successful/insufficient pruning, protected recent tools, manual/automatic
  pruning, reasoning-only and media units, synthetic messages and large history.
- The actual Chat Completions mid-turn nonce guard, abort restoration, redelivery
  with a new nonce, canonical ID deduplication and successful acknowledgement.
- Real main-agent text/tool loops, accounting attribution, exhaustion and spend
  force-final, plus rejected tools during summary retry/fallback.
- New/resumed subagents, disk registry reload, eager and mid-run compaction,
  summary retry and forced-final retry; every request has an independently
  checked HMAC session lane, including the first request.
- Archive summary requests, standalone user-context structuring and a probe.
- Saved image/PDF references, source-PDF page bounds, missing snapshots, raw
  inbound PDF hints, manager save/reload and old-importer Mind compatibility.

The original 77 wire cases plus 14 review-2 additions remain a separate gate. It covers the
broader model/provider/cache-control matrix; this lifecycle driver uses a
synthetic OpenCode-shaped GLM endpoint. Existing full smoke and mid-turn suites
remain required. These gates record legacy behavior, including imperfect legacy
behavior; they do not grant permission to silently correct it during P1.

The companion app Python sources are copied without edits from public UT commit
`3b6b8ef8db980599a9b526a95607c3b000c462a7` (0.8.4). Their provenance and hashes are
in `ut-0.8.4/provenance.json`. Their subprocess function is replaced only in the
Python test process; no phone, installer, subprocess or network operation runs.

## Review-2 contracts

The complete inventory is **31 observations / 48 HTTP requests**. Three added
scenarios invoke real `startActiveProcessing` and await its task chain: queued
carry over a tool round, four HTTP 503 attempts after the tool round, and an
initial final answer followed by the real queued-user follow-up turn. No drain,
acknowledgement, restoration or teardown helper is called by these new seams.
The no-tools scenario enables the follow-up condition without starting a poller;
no account or reply channel is configured. Assertions inspect canonical ordering,
queue uniqueness, disk state, guard state, final answers, typed delivery in the
actual second request, and hostile-prefix neutralization. All retry bodies are
captured and compared byte-for-byte.

Legacy behavior differs from the review's suggested failure expectation: transport
failure retains the human and annotated partial work in history, then requeues
once by ID during teardown. Render-invariant failure strips annotations; the
separate existing direct guard test covers that contract. P0 records both
behaviors rather than silently changing production to fit the proposed assertions.

Raw bytes of conversation, usage, pending queue (including its absence), media
history and the subagent session are base64 observations. Required files must
exist. The actual ZIP entry inventory, including directories, is sorted only to
remove filesystem-dependent listing order; new/removed entries fail. Message
save/reload assertions compare complete encoded values, including tool interactions
and attachment references, never the incomplete manual `Message ==` operator.

`chat_persistence_contract.py` separately pins model source, including optional
fields that do not appear in a fixture because they are nil. It conservatively
hashes Message, ToolModels and HarnessAnnotations files plus the complete usage,
subagent-session and ToolInteraction declarations. Any change needs independent
review, including a harmless comment or extraction. This is not a general Swift
schema parser and does not replace review of new persistence writers/types.

CI passes committed `--baseline` files to both runners. Lifecycle platform
matching uses OS + architecture plus the full compiler string, not the changing
kernel/image build. A compiler or SOURCE bump needs a separate reviewed record
from SOURCE. Per-file UserDefaults isolation evidence remains fail-closed: a P1
extraction may move counts, but must explain and review it explicitly. Keep old
seam entry points as thin wrappers; the same test source must compile in both
release and candidate trees. Review driver/comparator/fixture changes against
the accepted P0 head and their original `d4767d9` lineage.

The LM Studio addition observes the real local-model estimator/planner. UT
coverage remains shipped Python-bridge coverage; P2 requires the updated UT app
to ship and pass a device check before new profile kinds are enabled there.
