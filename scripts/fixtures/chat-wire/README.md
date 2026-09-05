# Legacy request-byte fixtures

These are raw HTTP body bytes from the production Chat Completions builder at
release source `4dd86133de03b484bed62fb81ce59935b89a7de8`, driven by development
test instrumentation. They are **not captures from the shipped release binary**.
Each platform file records the source, compiler and captured binary SHA-256.
Base64 keeps the exact bytes while respecting the repository's reserved-prefix
source invariant. There is no JSON normalization or volatility substitution.

Run from the repository root after `swift build`:

```sh
python3 scripts/chat_wire_baseline.py .build/debug/briglia
```

The driver captures twice in separate processes with independent storage roots,
ports and caches, checks both runs against one another, then compares every byte
and destination against the frozen file. It separately asserts methods, relevant
headers and a fixed independently computed affinity value. The test binary talks
only to its loopback server using synthetic credentials.

The initial matrix contains six exact model IDs (`glm-5.3`, `kimi-k3`,
`kimi-k2.7-code`, `qwen3.8-max`, `custom-model`, `local-model`) and six scenarios:

| Suffix | Scenario |
| --- | --- |
| 0 | Plain input, bare endpoint URL |
| 1 | Two stored tool results, reasoning, forced-final instruction, `/v1/` URL |
| 2 | Typed annotation paired with its canonical user message, hostile ordinary text, summary tail, full endpoint URL |
| 3 | Tool reasoning from a different model/gateway |
| 4 | Current-round image result and the existing synthetic user-role media message |
| 5 | Rasterized PDF-page result using the same media path |

The page fixture is a PNG returned by a tool, not a raw PDF or a PDF-reader test.
Tool schemas are not supplied by this initial matrix. A no-tools request with a
summary tail does not claim to drive the manager's pruning lifecycle. Reasoning
with absent legacy provenance is distinct from positively matched provenance.

`__chat-wire-selftest` additionally tests fragmented and truncated HTTP bodies,
ambiguous framing, byte limits, and a real large Unicode request. Smoke runs this
battery on both platforms. The frozen-byte comparator is an additional manual
gate until the compiler/platform baseline set covers the CI runner configurations.
An unrecognized platform/compiler fails comparison rather than skipping it.

`--record` creates a new baseline only when production Services/Models still
match the pinned source and there are no untracked production files. It never
overwrites a baseline. A compiler change, matrix expansion or explained legacy
difference needs a separately reviewed fixture revision; never regenerate
expectations from a changed production builder to make a comparison pass.

These fixtures are an initial subset, not full compatibility acceptance. Still
required: real OpenRouter/cache-control routing; supplied tool schemas; positively
matched reasoning provenance; archive/probe/subagent execution paths; pruning and
accounting decisions; persistence/rehydration; and shipped-client/Mind compatibility.
