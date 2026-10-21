#!/usr/bin/env python3
"""Deliberate breaks for /keepsummaries (KEEP_SUMMARIES_PLAN v5 §10, Codex
round-5 notes): each break is applied to the product source, the binary is
rebuilt, and the named selftest section must FAIL. The original source is
restored after every case and verified byte-identical at the end.

Local, slow (one incremental build per break). Not run in CI.

Usage: keep_summaries_mutation_test.py [--only NAME]
"""
import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, ".build/debug/briglia")
CM = "TelegramConcierge/Services/ConversationManager.swift"
COMPOSE = "TelegramConcierge/Services/PruneSummaryComposition.swift"
RESTORE = "TelegramConcierge/Services/PruneSummaryRestore.swift"

# The v4-style splitter Codex used to show R4-1: split at every header-looking
# line, no whole-file inventory, no end-marker check.
V4_SPLITTER = '''        var blocks: [UUID: Range<Int>] = [:]
        for (k, line) in headers.enumerated() {
            let lineText = text(line)
            guard let idRange = lineText.range(of: "id=") else { continue }
            let rest = lineText[idRange.upperBound...]
            guard let id = UUID(uuidString: String(rest.prefix(36))) else { continue }
            let next = k + 1 < headers.count ? headers[k + 1] : lineCount - 1
            if blocks[id] == nil { blocks[id] = (line + 1)..<next }
        }
        _ = ends
'''

# (name, file, old, new, selftest command, section)
BREAKS = [
    ("composition ignores N", COMPOSE,
     "        case .count(let n): keepFull = Set(anchors.suffix(max(0, n)))",
     "        case .count: keepFull = Set(anchors.suffix(3))",
     "__keep-summaries-selftest", "requests"),
    ("composed messages written back (commit persists the pointer shape)", CM,
     "        var candidateView = source\n        applyPrunePlan(plan, to: &candidateView)\n        _ = pruneCompressibleUserMessages(upToIndex: safeBoundary, in: &candidateView)\n        if plan.toolActionCount > 0 { pruneOldCompactToolLogs(in: &candidateView) }\n        let hadSummary = PruneSummaryRetention.isFullAnchor(candidateView[anchor])\n        var summaryParts",
     "        var candidateView = PruneSummaryRetention.compose(source, limit: .count(1)).messages\n        applyPrunePlan(plan, to: &candidateView)\n        _ = pruneCompressibleUserMessages(upToIndex: safeBoundary, in: &candidateView)\n        if plan.toolActionCount > 0 { pruneOldCompactToolLogs(in: &candidateView) }\n        let hadSummary = PruneSummaryRetention.isFullAnchor(candidateView[anchor])\n        var summaryParts",
     "__prune-retention-selftest", "coverage"),
    ("an estimate made on the canonical history (pre-request fallback)", CM,
     "            totalTokens = mandatoryEstimate.tokens\n            for message in decisionView.messages {\n                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)\n                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)\n            }\n            print(\"[ConversationManager] Using estimated tokens: \\(totalTokens)\")",
     "            totalTokens = mandatoryEstimate.tokens\n            for message in messages {\n                totalTokens += estimatedPromptTokens(for: message, isLMStudio: providerIsLMStudio)\n                totalTokens += toolInteractionTokens(message.toolInteractions, isLMStudio: providerIsLMStudio)\n            }\n            print(\"[ConversationManager] Using estimated tokens: \\(totalTokens)\")",
     "__keep-summaries-selftest", "measure"),
    ("the stub snapshot added to pruneArchiveReferences", CM,
     "                view[index].prunedContextSummaryStub = stub\n",
     "                view[index].prunedContextSummaryStub = stub\n                view[index].pruneArchiveReferences.append(stubRef)\n",
     "__keep-summaries-selftest", "commits"),
    ("cached measurement used across keys", CM,
     "        guard let tokens = lastPromptTokens, lastPromptRenderKey == view.renderKey else { return nil }",
     "        guard let tokens = lastPromptTokens else { return nil }",
     "__keep-summaries-selftest", "measure"),
    ("restore accepting a duplicate-marker block", RESTORE,
     "        guard summaryLines.count == 1, coverageLines.count == 1, coverageLines[0] > summaryLines[0] else {",
     "        guard !summaryLines.isEmpty, coverageLines.count == 1, coverageLines[0] > summaryLines[summaryLines.count - 1] else {",
     "__keep-summaries-selftest", "restore"),
    ("restore without the whole-file boundary inventory (v4 splitter)", RESTORE,
     None, V4_SPLITTER,
     "__keep-summaries-selftest", "restore"),
    ("the idle pass running during a background prune", CM,
     "        if backgroundPruneJob != nil { return \"background prune\" }\n",
     "",
     "__background-prune-selftest", "keepsummaries"),
    ("an Int 3 stored instead of removing the key", COMPOSE,
     "        case .count(KeepSummariesLimit.defaultCount): defaults.removeObject(forKey: defaultsKey)\n",
     "",
     "__keep-summaries-selftest", "command"),
    ("restore published without clearing the measurement first", CM,
     "            do { try clearPromptMeasurementDurably() }",
     "            do { if Bool(\"false\") == true { try clearPromptMeasurementDurably() } }",
     "__keep-summaries-selftest", "invalidate"),
    # Codex implementation review round 1 (R1/R2).
    ("R1: discarded staging output not charged to the pass budget", CM,
     "                    maxBytes: budget, meter: meter)",
     "                    maxBytes: budget, meter: nil)",
     "__keep-summaries-selftest", "idle"),
    ("R1: repairs continue after a failed snapshot write", CM,
     "                report.deferred += 1\n                outstanding = true\n                stopped = true\n",
     "                report.deferred += 1\n                outstanding = true\n",
     "__keep-summaries-selftest", "idle"),
    ("R1: an item cut off by the remainder marked unsupported", CM,
     "                if fresh { summaryStubRepairUnsupported.insert(",
     "                if true { summaryStubRepairUnsupported.insert(",
     "__keep-summaries-selftest", "idle"),
    ("R2: scan forgotten when nothing could be committed", CM,
     "            if scan { summaryRetentionScanPending = outstanding }\n            return report\n",
     "            summaryRetentionScanPending = false\n            return report\n",
     "__keep-summaries-selftest", "idle"),
    ("R2: scan forgotten after a partial commit", CM,
     "        if scan { summaryRetentionScanPending = outstanding }\n        print(",
     "        summaryRetentionScanPending = false\n        print(",
     "__keep-summaries-selftest", "idle"),
    ("R2: scan forgotten after a failed history write", CM,
     "            return report // a pending scan stays pending\n",
     "            summaryRetentionScanPending = false; return report\n",
     "__keep-summaries-selftest", "idle"),
]

INVENTORY_START = "        guard headers.count == header.messages else { return .failure(Refusal(\"boundary count\")) }\n"
INVENTORY_END = "        return .success(IndexedSnapshot("


def build():
    proc = subprocess.run(["swift", "build", "--build-system", "native"], cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout[-3000:] + proc.stderr[-3000:])
    return proc.returncode == 0


def apply(path, old, new):
    full = os.path.join(ROOT, path)
    source = open(full).read()
    if old is None:
        start = source.index(INVENTORY_START)
        end = source.index(INVENTORY_END)
        mutated = source[:start] + new + source[end:]
    else:
        if source.count(old) != 1:
            raise SystemExit(f"anchor not found exactly once in {path}: {old[:80]!r}")
        mutated = source.replace(old, new)
    open(full, "w").write(mutated)
    return source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only")
    args = parser.parse_args()
    originals = {p: open(os.path.join(ROOT, p)).read() for p in (CM, COMPOSE, RESTORE)}
    caught = 0
    cases = [b for b in BREAKS if not args.only or args.only in b[0]]
    try:
        for name, path, old, new, command, section in cases:
            original = apply(path, old, new)
            try:
                if not build():
                    print(f"✖ {name}: mutated source did not build")
                    continue
                proc = subprocess.run([BINARY, command, "--only", section], cwd=ROOT, capture_output=True, text=True, timeout=1800)
                failed = proc.returncode != 0
                rows = [l for l in proc.stdout.splitlines() if l.strip().startswith("✖")]
                print(f"{'✔' if failed else '✖'} {name} → {command} --only {section} {'FAILED as intended' if failed else 'PASSED (break not caught)'}"
                      + (f" ({len(rows)} row(s): {rows[0].strip()[:160]})" if rows else ""), flush=True)
                caught += 1 if failed else 0
            finally:
                open(os.path.join(ROOT, path), "w").write(original)
    finally:
        for p, text in originals.items():
            open(os.path.join(ROOT, p), "w").write(text)
        build()
    restored = all(open(os.path.join(ROOT, p)).read() == text for p, text in originals.items())
    print(f"\n{caught}/{len(cases)} deliberate breaks caught; sources restored byte-identical: {restored}")
    sys.exit(0 if caught == len(cases) and restored else 1)


if __name__ == "__main__":
    main()
