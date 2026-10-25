#!/usr/bin/env python3
"""Deliberate breaks for Phase 1 (security plan v24 §7.8.1, §7.9): each
mutation edits ONE source location in this checkout, rebuilds incrementally,
requires `briglia __private-runtime-selftest` (the named section) to FAIL, and
restores the file — also on error or Ctrl-C. Local review tool (it rebuilds
the debug binary per break), not a CI step.

Usage: private_runtime_mutation_test.py [--only N]
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build" / "debug" / "briglia"
S = "TelegramConcierge/Services/"
KC, ST = "TelegramConcierge/Utilities/KeychainHelper.swift", S + "RuntimeStatus.swift"
ENG, RT, AM, REP, NODE, PY, BASH, MCP = (S + "PrivateRuntimeEngine.swift", S + "PrivateRuntime.swift", S + "AgentMailInstaller.swift",
                                         S + "AgentMailRepair.swift", S + "NodeRuntime.swift", S + "PythonRuntime.swift",
                                         S + "BashTools.swift", S + "MCPRegistry.swift")

# (label, section filter, file, old, new)
MUTATIONS = [
    ("R1 an ordinary committing journal at the new target is finished without re-probing", "crash recovery (ordinary)", ENG,
     '                if j.state == "committing" {\n                    // Switched; no probe passed durably: probe now (ordinary journals only).',
     '                if false {\n                    // Switched; no probe passed durably: probe now (ordinary journals only).'),
    ("R2 the hold row is skipped (a held install is used again)", "hold and repair", ENG,
     "        if spec.usesHold, let hold = st.hold {\n            st.mirror = nil\n            return .held(hold)\n        }", ""),
    ("R3 unknown rows do not hold AgentMail", "hold and repair", ENG,
     '        guard spec.usesHold else { return .unknown(why) }', '        guard false else { return .unknown(why) }'),
    ("R4 the probe rollback is dropped", "install, update", ENG,
     "                if let o = old { try RuntimeFS.switchLink(RuntimePaths.current(c), to: o) }\n                else { try RuntimeFS.remove(RuntimePaths.current(c)) }\n                RuntimeSeams.crash(c, \"after-rollback-switch\")",
     "                RuntimeSeams.crash(c, \"after-rollback-switch\")"),
    ("R5 the 1 h throttle is ignored", "install, update", ENG,
     "Date().timeIntervalSince(last.startedAt) < throttle {", "Date().timeIntervalSince(last.startedAt) < 0 {"),
    ("R6 the generation is not revalidated at commit", "install, update", ENG,
     "            if sel.generation != generation || receipt.verified != snapshotVerified", "            if receipt.verified != snapshotVerified"),
    ("R7 a repair committing journal is re-probed instead of held off", "crash recovery (repair)", ENG,
     '            do {\n                if RuntimeFS.kind(RuntimePaths.current(c).path) != .absent { try RuntimeFS.remove(RuntimePaths.current(c)) }\n            } catch { return .unknown("\\(error)") }', ""),
    ("R8 a corrupt selection file does not hold AgentMail", "legacy inspect-only", RT,
     "            if let pin = AgentMailService.runtimePin, agentMailHasPrivateTrace() {",
     "            if false, let pin = AgentMailService.runtimePin, agentMailHasPrivateTrace() {"),
    ("E1 the per-use check ignores the hold", "exec validation", AM,
     "        if let hold { return .refuse(offMessage(holdText(hold))) }\n        guard let v = receipt?.verifiedRecord else {",
     "        guard let v = receipt?.verifiedRecord else {"),
    ("E2 the per-use check skips the binary hash", "exec validation", AM,
     "\n                && RuntimeFS.sha256(file: URL(fileURLWithPath: binary(rec))) == rec.binarySHA256", ""),
    ("E3 probe mode keeps the caller's key", "exec validation", AM,
     "return .run(binary: binary(j.newRecord), forcedKey: probePlaceholderKey)", "return .run(binary: binary(j.newRecord), forcedKey: nil)"),
    ("E4 probe mode allows any arguments", "exec validation", AM,
     '            guard args == ["--version"] else { return .refuse("probe mode allows only --version") }', ""),
    ("E5 the wrapper is written into ~/.local/bin", "install, update", AM,
     "    static var wrapperURL: URL { RuntimePaths.binDir.appendingPathComponent(wrapperName) }",
     "    static var wrapperURL: URL { legacyDirectory.appendingPathComponent(wrapperName) }"),
    ("E6 the wipe leaves the private copy", "legacy inspect-only", AM,
     "        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name != \".agentmail.lock\" {\n            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))\n        }", ""),
    ("P1 repair writes no hold at R1", "crash recovery (repair)", REP,
     '            st.hold = RuntimeHold(pin: spec.pin, reason: "repair-in-progress", since: Date(), attemptId: attempt.attemptId)\n', ""),
    ("P2 a failed repair probe falls back to the prior copy", "hold and repair", REP,
     "                // (r1) no link; (r2) result + hold reason; (r3) journal gone.\n                try RuntimeFS.remove(RuntimePaths.current(c))",
     "                // (r1) no link; (r2) result + hold reason; (r3) journal gone.\n                if let p = priorCurrent { try RuntimeFS.switchLink(RuntimePaths.current(c), to: p) } else { try RuntimeFS.remove(RuntimePaths.current(c)) }"),
    ("P3 the automatic repair runs for the held pin too", "hold and repair", REP,
     '            if automatic, let hold = st.hold, hold.pin == spec.pin {\n                return .throttled("the hold is for this pin: only an explicit repair acts")\n            }', ""),
    ("N1 an older shared Node is accepted", "node", NODE,
     "            guard atLeast(v, pin.version) == true else", "            guard true else"),
    ("N2 npm is not required next to a shared Node", "node", NODE,
     [('            guard FileManager.default.isExecutableFile(atPath: dir + "/npm") else { reasons.append("\\(node): no npm next to it"); continue }\n', ""),
      ('            guard n.status == 0 else { reasons.append("\\(dir)/npm does not run"); continue }\n', "")], None),
    ("N3 Briglia's own directories are not excluded from shared discovery", "node", NODE,
     '            if real == root || real.hasPrefix(root + "/") { continue }\n', ""),
    ("N4 the shims stay when a shared Node is selected", "node", NODE,
     "        if let shared {\n            removeShims()", "        if let shared {"),
    ("N5 the managed entry falls back to PATH", "node", MCP,
     'let node = NodeRuntime.selectedNodeBinary() ?? "/nonexistent/briglia-node-not-selected"', 'let node = NodeRuntime.selectedNodeBinary() ?? "node"'),
    ("B1 the fallback shims are not last", "path contract", BASH,
     "        return ([brigliaBin, localBin] + missing + parts + [fallback]).joined(separator: \":\")",
     "        return ([fallback, brigliaBin, localBin] + missing + parts).joined(separator: \":\")"),
    ("B2 Briglia's bin after ~/.local/bin", "path contract", BASH,
     "        return ([brigliaBin, localBin] + missing + parts + [fallback]).joined(separator: \":\")",
     "        return ([localBin, brigliaBin] + missing + parts + [fallback]).joined(separator: \":\")"),
    ("C1 containment not enforced", "containment", RT,
     "        let root = RuntimePaths.dataRoot.standardizedFileURL.path\n        let path = url.standardizedFileURL.path\n",
     "        if url.path.count >= 0 { return }\n        let root = RuntimePaths.dataRoot.standardizedFileURL.path\n        let path = url.standardizedFileURL.path\n"),
    ("L1 live leases not kept by GC", "python", PY, "                keep.insert(l.directory)\n", "                _ = l\n"),
    ("L2 GC right after the switch", "python", PY, "            if trigger == .auto {\n                var keep", "            if true {\n                var keep"),
    ("I1 base identity left out of the pin", "python", PY, "-py\\(base.version)-\\(base.identity)", "-py3.\\(base.minor)"),
    ("I2 base retarget ignored at use", "python", PY,
     '        if URL(fileURLWithPath: base).resolvingSymlinksInPath().path != resolved { return "its base interpreter \\(base) now points elsewhere" }\n', ""),
    ("T1 tree hash never compared", "python", PY, "        return have == want ? nil : \"the environment's files differ from what was built\"", "        return nil"),
    ("A1 abandonment re-enters its own selection lock", "install, update", ENG,
     '                try? RuntimeFS.removeTree(scratch)\n                var st = sel[c]; finishAttempt(&st, attempt.attemptId, result: "abandoned", onlyIfUnset: true); sel[c] = st\n                try RuntimeSelectionStore.save(sel)\n                return .abandoned("the installation changed meanwhile (wipe, import, provider change or another install)")',
     '                return abandon(spec, attempt, scratch, "the installation changed meanwhile (wipe, import, provider change or another install)")'),
    ("G1 provider change does not bump the generation", "install, update", KC,
     "        providerChanged = before[emailCalendarProviderKey] != store[emailCalendarProviderKey]", "        providerChanged = false"),
    ("S2 Node status from the cached version only", "node", ST,
     "                  PrivateRuntimeEngine.validate(NodeRuntime.spec(pin: pin), vr) == nil else {", "                  true else {"),
    ("Q1 wrapper path not shell-quoted", "path contract", RT,
     """    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\\\''") + "'" }""",
     """    static func shellQuote(_ s: String) -> String { "'" + s + "'" }"""),
    ("Y1 briglia-python falls back to the shared python3", "python", PY,
     '            return .refuse("Briglia\'s Python environment is not set up yet — run `briglia python-env install` (or the toolchain button in `briglia menu`)")',
     '            return .run("/usr/bin/python3")'),
    ("Y2 pip check skipped", "python", PY,
     '        guard chk.status == 0 else { return "pip check: \\(chk.stdout.prefix(200))" }', ""),
    ("Y3 the installed-set comparison skipped", "python", PY,
     '        guard cmp.status == 0 else { return "installed set differs from the lock: \\(cmp.stdout.prefix(300))\\(cmp.stderr.prefix(200))" }', ""),
    ("Y4 startup builds a venv on machines that never set Python up", "python", PY,
     "            if !hadVenv, !(await legacySharedSetup(base: base)) { return .notSetUp }", ""),
    ("S1 staged payloads keep tool-created group/other bits", "python", ENG,
     "            try RuntimeFS.restrictTree(payload)\n", ""),
    ("Y5 the per-exec venv check skips pyvenv.cfg", "python", PY,
     '              RuntimeFS.sha256(file: dir.appendingPathComponent("env/pyvenv.cfg")) == v.binarySHA256,', "              true,"),
]


def build():
    r = subprocess.run(["swift", "build", "--build-system", "native"], cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, r.stdout[-2000:] + r.stderr[-2000:]


def selftest(only):
    with tempfile.TemporaryDirectory() as tmp:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_"))}
        env.update(HOME=tmp, XDG_CONFIG_HOME=f"{tmp}/c", XDG_DATA_HOME=f"{tmp}/d")
        r = subprocess.run([str(BIN), "__private-runtime-selftest", "--only", only], capture_output=True, text=True, env=env, timeout=1800)
        return r.returncode, r.stdout


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--only", type=int)
    a = p.parse_args()
    caught = total = 0
    for n, (label, only, rel, old, new) in enumerate(MUTATIONS, 1):
        if a.only and a.only != n:
            continue
        total += 1
        path = ROOT / rel
        original = path.read_text()
        pairs = old if isinstance(old, list) else [(old, new)]
        mutated, bad = original, False
        for o, nw in pairs:
            if mutated.count(o) != 1:
                print(f"✖ {label}: anchor found {mutated.count(o)}×")
                bad = True
                break
            mutated = mutated.replace(o, nw, 1)
        if bad:
            continue
        try:
            path.write_text(mutated)
            ok, out = build()
            if not ok:
                print(f"✖ {label}: mutated tree does not compile (break not meaningful)\n{out}")
                continue
            rc, out = selftest(only)
            if rc != 0:
                caught += 1
                first = next((l for l in out.splitlines() if l.strip().startswith("✖")), "?")
                print(f"✔ {label} — caught: {first.strip()[:140]}", flush=True)
            else:
                print(f"✖ {label} — NOT caught", flush=True)
        finally:
            path.write_text(original)
    ok, _ = build()
    print(f"\n{caught}/{total} deliberate breaks caught; restored tree {'builds' if ok else 'DOES NOT BUILD'}")
    return 0 if caught == total and ok else 1


if __name__ == "__main__":
    sys.exit(main())
