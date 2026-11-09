#!/usr/bin/env python3
"""Deliberate breaks for the GPT editing profile, stage S2
(GPT_APPLY_PATCH_PLAN §14.11 and amendment A1).

Same method as codex_patch_break_test.py: copy the tree to a scratch
directory, build once (positive control: `__gpt-profile-selftest` passes),
then apply one mutation at a time, rebuild incrementally and require the
NAMED check (a label prefix) to be reported as failed (✖). The repository is
never modified.

Usage: python3 scripts/gpt_profile_break_test.py [--keep-build DIR] [--only S1,S2] [--verbose] [--dry-anchors]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINUX_JOBS = ["-j", "2"] if sys.platform.startswith("linux") else []
S = "TelegramConcierge/Services/"
C = S + "CodexPatch/"
FIXTURES = ROOT / "scripts/fixtures/codex-apply-patch"

# (id label, failing check prefix, [(file, old, new), ...])
BREAKS = [
    ("P13 .standard list includes the GPT apply_patch", "U .standard list is byte-identical", [("TelegramConcierge/Models/ToolModels+GPT.swift",
        "        guard editing.isGPT else { return tools }", "        guard editing.isGPT else { return tools + [applyPatchGPT] }")]),
    ("P14 one byte of a .standard description changed", "U standard file-tool definitions match the frozen hash", [("TelegramConcierge/Models/ToolModels.swift",
        "description: \"Reads a file from the local filesystem. You can access any file directly by using this tool.",
        "description: \"Reads a file from the local filesystem. You can access any file directly by using this tool!")]),
    ("P15 unknown model resolved GPT", "R unknown model → standard", [(C + "GPTEditing.swift",
        "        guard switchOn, GPTModelMatcher.isGPT(model) else { return .standard }", "        guard switchOn else { return .standard }")]),
    ("A1a matcher accepts major 4", "M matcher refuses gpt-4.1", [(C + "GPTEditing.swift",
        "    static let minimumMajor = 5", "    static let minimumMajor = 4")]),
    ("A1b loose substring match", "M matcher refuses my-gpt-6-finetune", [(C + "GPTEditing.swift",
        "        guard name.hasPrefix(\"gpt-\") else { return false }\n        let rest = name.dropFirst(4)",
        "        guard let at = name.range(of: \"gpt-\") else { return false }\n        let rest = name[at.upperBound...]")]),
    ("A1c provider prefix not stripped", "M matcher accepts openai/gpt-5.6-luna", [(C + "GPTEditing.swift",
        "        guard let slash = trimmed.lastIndex(of: \"/\") else { return trimmed }", "        guard let slash = trimmed.lastIndex(of: \"/\"), false else { return trimmed }")]),
    ("A1d freeform on an unverified route", "R OpenAI key (api.openai.com Responses) → JSON", [(C + "GPTEditing.swift",
        "    static let freeformHosts: Set<String> = [\"openrouter.ai\"]", "    static let freeformHosts: Set<String> = [\"openrouter.ai\", \"api.openai.com\"]")]),
    ("P17 SIWC route not excluded from freeform", "R Sign in with ChatGPT route → JSON", [(C + "GPTEditing.swift",
        "        guard context.wireProtocol == .responses, context.siwc == nil, context.siwcFailure == nil,",
        "        guard context.wireProtocol == .responses,")]),
    ("P29 switch ignored", "R stored off read by the switch", [(C + "GPTEditing.swift",
        "    static var isOn: Bool { storedOn && !environmentForcesOff }", "    static var isOn: Bool { !environmentForcesOff }")]),
    ("P30 environment variable ignored", "R BRIGLIA_GPT_PATCH=0 forces off", [(C + "GPTEditing.swift",
        "    static var isOn: Bool { storedOn && !environmentForcesOff }", "    static var isOn: Bool { storedOn }")]),
    ("P31 form file kept after /deleteuserdata", "R deleteAll removes the file", [(C + "GPTEditing.swift",
        "            try FileManager.default.removeItem(at: Self.fileURL)\n", "")]),
    ("S1 form record not version-bound", "R a record from another Briglia version retries freeform once", [(C + "GPTEditing.swift",
        "        return load()[key] == adaCLIVersion", "        return load()[key] != nil")]),
    ("P32 grammar altered", "U grammar = vendored apply_patch.lark", [(C + "GPTFreeform.swift",
        "start: begin_patch hunk+ end_patch", "start: begin_patch hunk* end_patch")]),
    ("S2 whitelist grant missing", "U GPT child whitelist naming apply_patch grants it", [(S + "SubagentRunner.swift",
        "                allowed.formUnion(AvailableTools.gptPatchGrantingNames)\n", "")]),
    ("P43 cross-profile mid-run change applied partially", "L GPT run: a mid-run switch to a non-GPT model", [(C + "GPTEditing.swift",
        "            return ctx\n        }\n        return runContext\n", "            return ctx\n        }\n        var partial = fresh\n        partial.editing = current\n        return partial\n")]),
    ("S3 transition not monotonic", "L transition is monotonic", [(C + "GPTEditing.swift",
        "        guard !transitioned, current.form == .freeform else { return false }", "        guard current.form == .freeform || transitioned else { return false }")]),
    ("P40 engine chosen by argument shape", "D a standard-stamped apply_patch goes to the legacy executor", [(S + "ToolExecutor.swift",
        "            if editing.isGPT { return await executeGPTApplyPatch(call) }", "            if editing.isGPT || call.function.arguments.contains(\"\\\"input\\\"\") { return await executeGPTApplyPatch(call) }")]),
    ("S4 unstamped apply_patch not refused", "D an unstamped apply_patch fails closed", [(S + "ToolExecutor.swift",
        "            guard let editing = call.editing else {\n                return ToolResultMessage(toolCallId: call.id, content: Self.unstampedPatchRefusal)\n            }",
        "            let editing = call.editing ?? .gptJSON")]),
    ("P33 success inferred from text (verification)", "D failure with a \"success\":true-like filename emits no verification", [(S + "ProjectInstructions.swift",
        "        if let outcome {\n            // GPT_APPLY_PATCH_PLAN §9.1", "        if let outcome, false {\n            // GPT_APPLY_PATCH_PLAN §9.1")]),
    ("P34 verification not injected for a GPT success", "D success with an \"error\"-like filename still verifies", [(S + "ProjectInstructions.swift",
        "            guard outcome.status == .applied || (outcome.status == .partial && !outcome.changed.isEmpty) else { return nil }",
        "            guard false else { return nil }")]),
    ("P42 committed patch relabelled after cancellation", "D /stop during a commit", [(S + "ToolExecutor+GPTPatch.swift",
        "            return await worker.value\n", "            let value = await worker.value\n            if Task.isCancelled { return GPTPatchApplied(text: \"cancelled\", outcome: .refused(.cancelled), evidence: .init()) }\n            return value\n")]),
    ("P24b caller cancellation never reaches preflight", "D cancelled before the first mutation", [(S + "ToolExecutor+GPTPatch.swift",
        "        } onCancel: {\n            flag.set()\n        }", "        } onCancel: {\n            _ = flag\n        }")]),
    ("P23 Move destination not claim-checked", "D claims cover every path of a GPT patch", [(C + "CodexPatchEngine.swift",
        "            if let move = hunk.movePath { raw.append(move) }\n", "")]),
    ("P49 status/telemetry classified from text", "D stage/telemetry/status classification follows the typed outcome", [(S + "ToolExecutor+GPTPatch.swift",
        "        editOutcome.map { $0.status != .applied } ?? textCheck(content)", "        textCheck(content)")]),
    ("P22 heredoc with trailing command intercepted", "I does not intercept: trailing command (P22)", [(S + "ToolExecutor+GPTPatch.swift",
        "        guard after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }\n", "")]),
    ("S5 unquoted heredoc with expansions intercepted", "I does not intercept: unquoted body with $", [(S + "ToolExecutor+GPTPatch.swift",
        "        if !quoted, bodyText.contains(\"$\")", "        if false, bodyText.contains(\"$\")")]),
    ("S6 standard bash intercepted", "I a standard-stamped bash call is never intercepted", [(S + "ToolExecutor+GPTPatch.swift",
        "        guard call.function.name == \"bash\", call.editing?.isGPT == true,", "        guard call.function.name == \"bash\",")]),
    ("S7 evidence published before delivery", "K no GPT record until the result is committed", [(S + "ToolExecutor+Filesystem.swift",
        "            message.gptEvidence = GPTEvidenceSettlement(receipts: [receipt])\n",
        "            message.gptEvidence = GPTEvidenceSettlement(receipts: [receipt])\n            await message.gptEvidence?.publish()\n")]),
    ("P50 zero-line read credited", "K zero-line read earns no receipt", [(S + "ToolExecutor+GPTPatch.swift",
        "              let returned = object[\"returned_lines\"] as? Int, returned >= 1 else { return nil }",
        "              let returned = object[\"returned_lines\"] as? Int, returned >= 0 else { return nil }")]),
    ("P51 GPT record from a post-read stat", "K an in-place write between open and read earns nothing", [(S + "ToolExecutor+GPTPatch.swift",
        "        guard let observed = observation.observed, observed.before.sameState(as: observed.after) else { return nil }",
        "        guard let observed = observation.observed else { return nil }"),
        (S + "ToolExecutor+GPTPatch.swift",
        "        return GPTEvidence.Receipt(key: observation.keyBefore, identity: observed.before, source: .gptReadFile)",
        "        return GPTEvidence.Receipt(key: observation.keyBefore, identity: current, source: .gptReadFile)"),
        (S + "ToolExecutor+GPTPatch.swift",
        "              current.sameState(as: observed.before) else { return nil }",
        "              true else { return nil }")]),
    ("R1 bytes not bound to the requested path (away and back)", "K alias retargeted away and back", [(S + "ToolExecutor+GPTPatch.swift",
        "              current.sameState(as: observed.before) else { return nil }", "              true else { return nil }")]),
    ("R1b receipt without a descriptor observation", "K an observation that never read earns nothing", [(S + "ToolExecutor+GPTPatch.swift",
        "        guard let observed = observation.observed, observed.before.sameState(as: observed.after) else { return nil }",
        "        guard let observed = observation.observed ?? ((try? FileIdentity.lstatPath(observation.keyBefore)) ?? nil).map({ GPTReadObservation.Observed(before: $0, after: $0) }), observed.before.sameState(as: observed.after) else { return nil }")]),
    ("R3 explicit context not checked", "L an explicit cross-profile context is replaced by the run's own", [(C + "GPTEditing.swift",
        "        guard candidate == current else { return runContext }\n", "")]),
    ("R4a registry not scoped", "L the same call id in another scope never collides", [(S + "ToolExecutor+GPTPatch.swift",
        "        lock.lock(); defer { lock.unlock() }; return running[scope]?.contains(callID) == true",
        "        lock.lock(); defer { lock.unlock() }; return running.values.contains { $0.contains(callID) }")]),
    ("R4b stale outcome kept on reuse", "L a reused call id: the new call is running and the old outcome is gone", [(S + "ToolExecutor+GPTPatch.swift",
        "        settled[scope]?.removeValue(forKey: callID)\n        touch(scope)\n        lock.unlock()\n    }\n\n    func finish",
        "        touch(scope)\n        lock.unlock()\n    }\n\n    func finish")]),
    ("R2b publication not admitted inside the tracker", "K cancelled during publication (single receipt)", [(S + "FileTimeTracker.swift",
        "        guard !Task.isCancelled else { return false }\n        publishGPT(receipt)", "        publishGPT(receipt)")]),
    ("R2c forget not admitted inside the tracker", "K cancelled during publication (forget + receipt)", [(S + "FileTimeTracker.swift",
        "        guard !Task.isCancelled else { return false }\n        forgetGPT(key: key)", "        forgetGPT(key: key)")]),
    ("R4c owed scope evicted", "L an unconsumed (pinned) scope survives", [(S + "ToolExecutor+GPTPatch.swift",
        "              let index = scopeOrder.firstIndex(where: { running[$0] == nil && (pins[$0] ?? 0) == 0 }) {",
        "              let index = scopeOrder.firstIndex(where: { running[$0] == nil }) {")]),
    ("R4d last release does not retire", "L the last release retires the scope", [(S + "ToolExecutor+GPTPatch.swift",
        "        if left == 0, running[scope] == nil {\n            settled.removeValue(forKey: scope)", "        if left == 0, running[scope] == nil, false {\n            settled.removeValue(forKey: scope)")]),
    ("R5 description error classified", "X does not classify the entry's description", [(C + "GPTFreeform.swift",
        "                let typeOrFormat = param == base + \".type\" || param == base + \".format\"",
        "                let typeOrFormat = param.hasPrefix(base + \".\") || param == base + \".format\"")]),
    ("S8 stale receipt published", "K a receipt for a version that changed before delivery is not published", [(S + "ToolExecutor+GPTPatch.swift",
        "            guard let now = try? FileIdentity.lstatPath(receipt.key), now.sameState(as: receipt.identity) else { continue }\n            guard await FileTimeTracker.shared.publishGPTIfAdmitted(receipt) else { return }",
        "            guard await FileTimeTracker.shared.publishGPTIfAdmitted(receipt) else { return }")]),
    ("P20 GPT record unlocks edit_file", "K a GPT patch record never unlocks edit_file", [(S + "FileTimeTracker.swift",
        "        gptSnapshots[receipt.key] = GPTEvidence.Record(identity: receipt.identity, recordedAt: Date(), source: receipt.source)",
        "        gptSnapshots[receipt.key] = GPTEvidence.Record(identity: receipt.identity, recordedAt: Date(), source: receipt.source)\n        if let (m, s) = Self.currentStat(path: receipt.key) { snapshots[receipt.key] = Snapshot(mtime: m, size: s, readAt: Date()) }")]),
    ("P21 shell read recorded on exit != 0", "H not credited: exit ≠ 0", [(S + "ToolExecutor+GPTPatch.swift",
        "              object[\"exit_code\"] as? Int == 0, object[\"status\"] as? String == \"exited\" else { return nil }",
        "              object[\"status\"] as? String == \"exited\" else { return nil }")]),
    ("P47 multi-operand shell read credited", "H not recognised: cat D/a.txt D/b.txt", [(S + "ToolExecutor+GPTPatch.swift",
        "        return operands.count == 1 ? operands[0] : nil", "        return operands.first")]),
    ("P48 empty-output read credited", "H not credited: empty output from a non-empty file", [(S + "ToolExecutor+GPTPatch.swift",
        "        guard !stdout.isEmpty || (before.size == 0 && isPlainCat(command)) else { return nil }\n", "")]),
    ("P16 custom call accepted for an unexposed tool", "W decoder refuses a custom call when freeform is not exposed", [(S + "ResponsesModels.swift",
        "allowedTools.contains(name), freeformTools.contains(name),", "allowedTools.contains(name),")]),
    ("P18 semantic replay emits custom when not exposed", "W JSON-form request: a native custom round replays semantically", [(S + "OpenRouterService+Responses.swift",
        "                    if freeformPatch, let patch = GPTFreeform.patchInput(call) {", "                    if let patch = GPTFreeform.patchInput(call) {")]),
    ("P37 function output for a custom item", "W its output is a string custom_tool_call_output", [(S + "OpenRouterService+Responses.swift",
        "                if customCallIDs.contains(mapped[result.toolCallId]!) {", "                if false, customCallIDs.contains(mapped[result.toolCallId]!) {")]),
    ("S9 freeform not emitted", "W freeform request: Codex grammar tool in apply_patch's slot", [(S + "ResponsesAdapter.swift",
        "                if context.editing.form == .freeform, tool.function.name == \"apply_patch\" { return GPTFreeform.customToolEntry() }\n", "")]),
    ("S10 repair widens the allowlist", "W repair never widens the executable allowlist", [(S + "ResponsesAdapter.swift",
        "        return foreign.subtracting(exposed)", "        return foreign")]),
    ("S11 stamp not copied", "W the call carries the producing request's stamp", [(S + "ToolArgumentHint.swift",
        "            copy.editing = editing\n", "")]),
    ("P41 classifier accepts a generic tools 400", "X does not classify a generic `tools` error", [(C + "GPTFreeform.swift",
        "                if typeOrFormat || (param == base && typeCodes.contains(code)) {", "                if param.hasPrefix(\"tools\") {")]),
    ("S12 unknown code classified", "X does not classify an unknown code", [(C + "GPTFreeform.swift",
        "            guard let param = error[\"param\"] as? String, let code = error[\"code\"] as? String, refusalCodes.contains(code) else { continue }",
        "            guard let param = error[\"param\"] as? String, let code = error[\"code\"] as? String else { continue }")]),
    ("L1 live custom-type refusal not recognised", "X live fixture or-gpt41mini-openai.json: classified = true", [(C + "GPTFreeform.swift",
        "            if let code = error[\"code\"] as? String, refusalCodes.contains(code), message.contains(\"'custom'\") {",
        "            if let code = error[\"code\"] as? String, refusalCodes.contains(code), message.contains(\"'custom'\"), false {")]),
    ("L2 live grammar refusal not recognised", "X live fixture or-badgrammar-openai.json: classified = true", [(C + "GPTFreeform.swift",
        "            if message.hasPrefix(larkRefusalPrefix) {", "            if message.hasPrefix(larkRefusalPrefix), false {")]),
    ("L3 OpenRouter validation refusal not recognised", "X live fixture or-badsyntax.json: classified = true", [(C + "GPTFreeform.swift",
        "            guard path.count == 2, path[0] as? String == \"tools\", let k = path[1] as? Int, indices.contains(k) else { continue }",
        "            guard path.count == 2, path[0] as? String == \"tools\", let k = path[1] as? Int, indices.contains(k), false else { continue }")]),
    ("L4 any `tools` refusal classified", "X live `tools` refusal naming another type is not classified", [(C + "GPTFreeform.swift",
        "refusalCodes.contains(code), message.contains(\"'custom'\") {", "refusalCodes.contains(code) {")]),
    ("L5 validation index not checked", "X live validation refusal at another tool's index is not classified", [(C + "GPTFreeform.swift",
        "let k = path[1] as? Int, indices.contains(k) else { continue }", "let k = path[1] as? Int else { continue }")]),
    ("L6 refusal code not required on the `tools` rule", "X live `tools` refusal with a non-refusal code is not classified", [(C + "GPTFreeform.swift",
        "            if let code = error[\"code\"] as? String, refusalCodes.contains(code), message.contains(\"'custom'\") {",
        "            if let code = error[\"code\"] as? String, message.contains(\"'custom'\") {")]),
    ("P19 transition without notice", "X exactly one notice", [(S + "OpenRouterService.swift",
        "                if first { await editingRun.notify(GPTPatchRoute.transitionNotice) }\n", "")]),
    ("P36 prompt not rebuilt after a transition", "X the resend's prompt is rebuilt for JSON", [(S + "OpenRouterService.swift",
        "                persona: persona, editing: context.editing\n            )\n            rebuilt.imageLog = imageLog",
        "                persona: persona, editing: .gptFreeform\n            )\n            rebuilt.imageLog = imageLog")]),
    ("S13 rejection not recorded", "X the route is recorded; the next run starts in JSON", [(S + "OpenRouterService.swift",
        "            let first = GPTPatchFormStore.shared.recordRejection(GPTPatchRoute.key(context))", "            let first = true")]),
    ("S14 prompt bullet not switched", "P GPT system prompt: no `edit_file` anywhere", [(S + "OpenRouterService+Preparation.swift",
        "        guard editing.isGPT else { return standardEditingBullet() }", "        guard editing.isGPT, false else { return standardEditingBullet() }")]),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    r = run(["swift", "build", "--build-system", "native", *LINUX_JOBS, "--scratch-path", str(scratch)], tree, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


def selftest(binary, workdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith("BRIGLIA_")}
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    return run([str(binary), "__gpt-profile-selftest", "--fixtures", str(FIXTURES)], workdir, timeout=900, env=env)


def check_anchors():
    bad = 0
    for label, _, edits in BREAKS:
        for rel, old, _ in edits:
            n = (ROOT / rel).read_text().count(old)
            if n != 1:
                bad += 1
                print(f"✖ anchor {label}: {rel}: found {n}: {old[:70]!r}")
    print(f"{len(BREAKS)} breaks, {bad} bad anchor(s)")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-build")
    ap.add_argument("--only")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--dry-anchors", action="store_true")
    args = ap.parse_args()
    if args.dry_anchors:
        return check_anchors()
    work = Path(tempfile.mkdtemp(prefix="briglia-gpbreak-"))
    tree = work / "tree"
    tree.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / name, tree / name)
    shutil.copytree(ROOT / "TelegramConcierge", tree / "TelegramConcierge")
    scratch = Path(args.keep_build) if args.keep_build else work / "build"
    failures = executed = 0
    try:
        binary = build(tree, scratch)
        r = selftest(binary, work)
        ok = r.returncode == 0
        print(("✔" if ok else "✖") + " positive control: the unmodified copy passes", flush=True)
        if not ok:
            print((r.stdout + r.stderr)[-3000:])
            return 1
        for label, prefix, edits in BREAKS:
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            originals = {}
            try:
                for rel, old, new in edits:
                    path = tree / rel
                    text = originals.get(rel) or path.read_text()
                    current = path.read_text()
                    if current.count(old) != 1:
                        raise RuntimeError(f"break anchor moved: {label}: {rel}: {old[:80]!r} (found {current.count(old)})")
                    originals.setdefault(rel, text)
                    path.write_text(current.replace(old, new))
                binary = build(tree, scratch)
                r = selftest(binary, work)
                failed = [l for l in r.stdout.splitlines() if l.startswith("✖")]
                caught = r.returncode != 0 and any(l.startswith(f"✖ {prefix}") for l in failed)
                print(("✔" if caught else "✖") + f" {label}: '{prefix}' fails"
                      + (f" ({len(failed)} failing check(s))" if failed else ""), flush=True)
                failures += 0 if caught else 1
                executed += 1
                if not caught and args.verbose:
                    print((r.stdout + r.stderr)[-6000:])
            finally:
                for rel, text in originals.items():
                    (tree / rel).write_text(text)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
