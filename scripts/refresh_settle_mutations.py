#!/usr/bin/env python3
"""Deliberate-break controls for the refresh-and-settle fix (0.2.54).

Each mutation re-introduces one defect into SubscriptionAuth.swift, rebuilds,
and runs `__refresh-settle-selftest` under isolated XDG roots. A mutation is
"caught" when the selftest fails. The source file is always restored.
Local tool: it rebuilds the working tree, so it is not part of ci.yml.
"""
import os, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "TelegramConcierge/Services/SubscriptionAuth.swift"

MUTATIONS = {
    "M1 settle inherits caller cancellation (0.2.53 shape)": (
        "        let caller = SubscriptionRefreshCaller()\n        let store = self\n",
        "        let caller = SubscriptionRefreshCaller()\n        let store = self\n"
        "        if Bool(\"true\")! { let value = try await settle(generation: generation, rejectedAccess: rejectedAccess, caller: caller, refresh: refresh); try Task.checkCancellation(); return value }\n"),
    "M2 no once-only recovery limit": (
        "                throw SubscriptionError(Self.refreshExhaustedMessage)\n            }\n            let recovering",
        "                _ = 0\n            }\n            let recovering"),
    "M3 no durable op record before the send": (
        "                                                    startedAt: Date(), state: \"sending\")\n            try write(state)\n",
        "                                                    startedAt: Date(), state: \"sending\")\n"),
    "M4 checkpoint never promoted": (
        "                if pending.generation == generation, pending.replaces",
        "                if Bool(\"false\")!, pending.generation == generation, pending.replaces"),
    "M5 checkpoint promoted for any generation": (
        "                if pending.generation == generation, pending.replaces",
        "                if pending.generation == pending.generation, pending.replaces"),
    "M6 stopped caller still sends": (
        "            if caller.cancelled { throw CancellationError() }\n",
        ""),
    "M7 every failure treated as ambiguous": (
        "        if let failure = error as? SubscriptionError {\n            if failure.requiresLogin",
        "        if Bool(\"false\")!, let failure = error as? SubscriptionError {\n            if failure.requiresLogin"),
    "M8 no checkpoint before validation/commit": (
        "            state.pendingRotation = SubscriptionPendingRotation(generation: generation, replaces: fingerprint, credential: updated)\n            try? write(state)\n",
        ""),
    "M9 recovery not reserved before its send": (
        "            if recovering { state.refreshRecovery = SubscriptionRefreshRecovery(",
        "            if Bool(\"false\")!, recovering { state.refreshRecovery = SubscriptionRefreshRecovery("),
    "M10 account change leaves the login usable": (
        "                state.refreshOp = nil\n                state.requiresLogin = true\n",
        "                state.refreshOp = nil\n"),
    "M11 gateway 504 treated as answered": (
        "![0, 502, 504].contains(status)",
        "![0].contains(status)"),
}

def run_selftest(binary):
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, HOME=tmp, XDG_CONFIG_HOME=tmp + "/c", XDG_DATA_HOME=tmp + "/d", XDG_CACHE_HOME=tmp + "/k")
        try:
            r = subprocess.run([binary, "__refresh-settle-selftest"], env=env, capture_output=True, text=True, timeout=300)
        except subprocess.TimeoutExpired:
            return False, ["(timeout)"]
        return r.returncode == 0, [l for l in r.stdout.splitlines() if l.startswith("✖")]

def main():
    original = SRC.read_text()
    caught = 0
    try:
        for name, (old, new) in MUTATIONS.items():
            if original.count(old) != 1:
                print(f"SETUP ERROR {name}: anchor found {original.count(old)} times"); sys.exit(2)
            SRC.write_text(original.replace(old, new))
            b = subprocess.run(["swift", "build"], cwd=ROOT, capture_output=True, text=True)
            if b.returncode != 0:
                print(f"BUILD ERROR {name}\n{b.stdout[-2000:]}"); sys.exit(2)
            ok, failures = run_selftest(str(ROOT / ".build/debug/briglia"))
            caught += not ok
            print(f"{'caught' if not ok else 'MISSED'}: {name} ({len(failures)} failing checks)")
            for f in failures[:4]: print("    " + f)
    finally:
        SRC.write_text(original)
        subprocess.run(["swift", "build"], cwd=ROOT, capture_output=True)
    print(f"Deliberate breaks caught: {caught}/{len(MUTATIONS)}")
    sys.exit(0 if caught == len(MUTATIONS) else 1)

if __name__ == "__main__":
    main()
