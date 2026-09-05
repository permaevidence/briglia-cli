# Chat Completions lifecycle baseline (P0)

Run from the private code checkout:

```sh
python3 scripts/chat_lifecycle_baseline_test.py
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
structuring operation's UUID. Progress and timeout clocks stay real. The seams
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

The existing 77-case wire gate remains separate and unchanged. It covers the
broader model/provider/cache-control matrix; this lifecycle driver uses a
synthetic OpenCode-shaped GLM endpoint. Existing full smoke and mid-turn suites
remain required. These gates record legacy behavior, including imperfect legacy
behavior; they do not grant permission to silently correct it during P1.

The companion app Python sources are copied without edits from public UT commit
`3b6b8ef8db980599a9b526a95607c3b000c462a7` (0.8.4). Their provenance and hashes are
in `ut-0.8.4/provenance.json`. Their subprocess function is replaced only in the
Python test process; no phone, installer, subprocess or network operation runs.
