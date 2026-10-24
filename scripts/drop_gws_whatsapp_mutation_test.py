#!/usr/bin/env python3
"""Deliberate breaks for the gws / WhatsApp retirement (DROP_GWS_WHATSAPP_PLAN
v3). Each mutation edits source in this checkout, rebuilds incrementally and
requires `briglia __retired-integrations-selftest` to fail ON THE INTENDED
CHECK (one of the listed check ids must print ✖); the file is restored also on
error or Ctrl-C. A passing unmutated baseline is required first. Local review
tool (it rebuilds the debug binary per break), not a CI step.

Usage: drop_gws_whatsapp_mutation_test.py [--only N]
"""
import argparse
import os
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug/briglia"
S = "TelegramConcierge/Services/"
RI, BR, NO, AR = S + "RetiredIntegrations.swift", S + "RetiredIntegrations+Bridge.swift", \
    S + "RetiredIntegrationsNotice.swift", S + "ConversationArchiveService.swift"
LINUX = platform.system() == "Linux"

# (label, file, [(old, new), ...], expected check ids, platform or None)
MUTATIONS = [
    ("B1 conversion overwrites a concurrent explicit choice", RI,
     [('if raw == "gws" || (raw == nil && gws.legacyUnset) {', 'if true {')], ["G9"], None),
    ("B2 legacy-unset installs are not converted", RI,
     [('if raw == "gws" || (raw == nil && gws.legacyUnset) {', 'if raw == "gws" {')], ["G2.0", "G5"], None),
    ("B3 the legacy probe runs again (no durable negative evaluation)", RI,
     [("        case .ok(let loaded):\n            state = loaded\n", "        case .ok(let loaded):\n            state = loaded.gws == nil ? evaluate(env) : loaded\n")], ["G3b"], None),
    ("B4 stale OAuth copies are not cleaned silently", RI,
     [("            try KeychainHelper.conditionalTransaction { store in\n                store.removeValue(forKey: KeychainHelper.retiredGwsOAuthClientIDKey)\n                store.removeValue(forKey: KeychainHelper.retiredGwsOAuthClientSecretKey)\n                if store",
       "            try KeychainHelper.conditionalTransaction { store in\n                if store")], ["G10"], None),
    ("B5 a provider restored to gws is not re-cleaned", RI,
     [('                if store[KeychainHelper.emailCalendarProviderKey] == "gws" {\n                    store[KeychainHelper.emailCalendarProviderKey] = EmailCalendarProvider.none.rawValue\n                }\n            }\n        } catch {\n            report.cleanupFailed',
       '            }\n        } catch {\n            report.cleanupFailed')], ["G11"], None),
    ("B6 a failed first write does not stop the pass", RI,
     [("                report.stateWriteFailed = true\n                return report   // nothing changes until the record exists",
       "                report.stateWriteFailed = true")], ["G8"], None),
    ("B7 an unreadable state file is rebuilt instead of staying inert", RI,
     [("        case .unreadable(let why):\n            report.inert = why\n            return report",
       "        case .unreadable(let why):\n            report.inert = why\n            state = evaluate(env)")], ["G12"], None),
    ("B8 wasEnabled not captured", RI,
     [("            let wasEnabled = enabled && !phone.isEmpty", "            let wasEnabled = false")], ["W1", "W4"], None),
    ("B9 a WhatsApp last channel is left in place", RI,
     [("               address.kind == .whatsapp {\n                report.lastUserChannelWasWhatsApp = true",
       "               address.kind == .whatsapp && false {\n                report.lastUserChannelWasWhatsApp = true")], ["W1b", "W2"], None),
    ("B10 the folder is removed although a bridge may be running", RI,
     [("            if case .unknown(let why) = stop {", "            if case .unknown(let why) = stop, false {")], ["W6"], None),
    ("B11 text B not used while the folder is pending", RI,
     [("            if wa?.folder == .pending {", "            if false {")], ["W6"], None),
    ("B12 no crash recovery from the recorded topKind", RI,
     [("                    wa.folder = wa.topKind == nil ? .absent : .done", "                    wa.folder = .absent")], ["W7"], None),
    ("B13 a WhatsApp notice for a disabled leftover", RI,
     [("folderDetail: nil, notice: wasEnabled ? .pending : .none)", "folderDetail: nil, notice: .pending)")], ["W3"], None),
    ("B14 notices due while conversion is pending", RI,
     [("if let g = state.gws, g.conversion == .done, g.notice == .pending,", "if let g = state.gws, g.notice == .pending,")], ["N1", "G6"], None),
    ("B15 consume does not require a pending notice", RI,
     [("            guard var g = state.gws, g.conversion == .done, g.notice == .pending else { return nil }",
       "            guard var g = state.gws else { return nil }")], ["N4"], None),
    ("B16 a failed consume write still returns the text", RI,
     [("        do { try save(state, to: env.stateURL) } catch { return nil }\n        return text",
       "        try? save(state, to: env.stateURL)\n        return text")], ["N2"], None),
    ("B17 the remover follows inner symlinks", BR,
     [("            case S_IFDIR:\n                try removeTree(", "            case S_IFDIR, S_IFLNK:\n                try removeTree("),
      ("            case S_IFREG, S_IFLNK:\n                guard unlinkat(", "            case S_IFREG:\n                guard unlinkat("),
      ("        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)",
       "        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)")], ["R1"], None),
    ("B18 a different device is entered", BR,
     [("        guard dev == device else {", "        guard dev == device || true else {")], ["R6"], None),
    ("B19 a same-device mount is entered (macOS file-system identity)", BR,
     [("            guard fs == rootFS else {", "            guard fs == rootFS || true else {")], ["R7"], "Darwin"),
    ("B20 a same-device mount is entered (Linux mount table)", BR,
     [('            if let hit = mounts.first(where: { $0 == top || $0.hasPrefix(top + "/") }) {',
       '            if let hit = mounts.first(where: { _ in false }) {')], ["R7"], "Linux"),
    ("B21 removal not recorded first", BR,
     [("            guard willRemove(.dir) else {", "            guard willRemove(.dir) || true else {")], ["R5"], None),
    ("B22 special files are removed", BR,
     [("            case S_IFREG, S_IFLNK:\n                guard unlinkat(", "            case S_IFREG, S_IFLNK, S_IFIFO:\n                guard unlinkat(")], ["R9"], None),
    ("B23 the entry bound is ignored", BR,
     [("            if budget < 0 {", "            if budget < 0 && false {")], ["R11"], None),
    ("B24 any argv element carrying the path counts as a bridge", BR,
     [("            guard let script = Self.scriptArgument(argv) else { continue }",
       '            guard let script = argv.first(where: { $0.hasSuffix("/whatsapp-bridge/index.js") }) else { continue }')], ["S5"], None),
    ("B25 an unverifiable bridge path counts as not ours", BR,
     [('            case .undetermined: return .unreadable("process \\(p.pid) runs a WhatsApp bridge whose path cannot be verified")',
       "            case .undetermined: continue")], ["S9"], None),
    ("B26 unreadable argv is ignored", BR,
     [('                return .unreadable("the arguments of process \\(p.pid) could not be read")', "                continue")], ["S8"], None),
    ("B27 SIGKILL without a fresh scan", BR,
     [("        if let why = signalEach(initial, SIGKILL, target) { return .unknown(why) }", "        for p in initial { signal(p.pid, SIGKILL) }")], ["S13", "S15"], None),
    ("B35 (impl R1) TERM batch without a per-signal re-read", BR,
     [("        if let why = signalEach(initial, SIGTERM, target) { return .unknown(why) }", "        for p in initial { signal(p.pid, SIGTERM) }")], ["S14"], None),
    ("B36 (impl R1) KILL batch re-read once, not per signal", BR,
     [("        if let why = signalEach(initial, SIGKILL, target) { return .unknown(why) }",
       "        if case .found(let left) = scan(target) { for p in left { signal(p.pid, SIGKILL) } }")], ["S15"], None),
    ("B37 (impl R2) bridges are stopped only while the folder exists", RI,
     [("            let stop = env.bridge.stopBridges(target:", "            let stop: BridgeOutcome = !present ? .clear : env.bridge.stopBridges(target:")], ["W9", "W10"], None),
    ("B38 (impl R4) unfinished cleanup after done is not reopened", RI,
     [("                    wa.folder = .pending; wa.folderDetail = why", "                    if wa.folder == .pending { wa.folderDetail = why }")], ["W10"], None),
    ("B39 (impl R3) polling not re-checked before each consume", NO,
     [("            let idle = isPolling && activeRunId == nil", "            let idle = (isPolling || true) && activeRunId == nil")], ["M10", "M6"], None),
    ("B28 queued retired alerts are kept", AR,
     [("        let kept = store.undelivered.filter { alert in !retiredAlertPrefixes.contains { alert.hasPrefix($0) } }",
       "        let kept = store.undelivered")], ["A1", "A2"], None),
    ("B29 the alert filter matches any mention of gws/WhatsApp", AR,
     [("!retiredAlertPrefixes.contains { alert.hasPrefix($0) }", '!(alert.contains("gws") || alert.contains("WhatsApp"))')], ["A1"], None),
    ("B30 an ambiguous send is retried", NO,
     [("            case .accepted, .ambiguous:\n                RetiredIntegrations.settle(which, .done, env: env)",
       "            case .accepted:\n                RetiredIntegrations.settle(which, .done, env: env)\n            case .ambiguous:\n                RetiredIntegrations.settle(which, .retry(now), env: env)")], ["M8"], None),
    ("B31 a local notice without an attached sink", NO,
     [("        guard RetiredNoticeSinks.terminalAttached || AppChatSocketServer.shared.hasConnectedClients else { return nil }\n", "")], ["M5"], None),
    ("B32 notices sent while polling is stopped", NO,
     [("        let idle = isPolling && activeRunId == nil", "        let idle = activeRunId == nil")], ["M6"], None),
    ("B33 the in-memory WhatsApp fallback is not normalised", NO,
     [("        if lastUserChannelAddress?.kind == .whatsapp {", "        if false {")], ["M1", "M3"], None),
    ("B34 the fallback is normalised only when the durable steps run", RI,
     [("        report.lastUserChannelReplacement = pairedTelegramAddress()\n        var state: State", "        var state: State"),
      ("            let telegram = report.lastUserChannelReplacement\n", "            let telegram = pairedTelegramAddress()\n            report.lastUserChannelReplacement = telegram\n")], ["M3"], None),
]


def build():
    r = subprocess.run(["swift", "build", "--build-system", "native"] if not LINUX else ["swift", "build", "-j", "1"],
                       cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, r.stdout[-2000:] + r.stderr[-2000:]


def selftest():
    with tempfile.TemporaryDirectory() as tmp:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_"))}
        env.update(XDG_CONFIG_HOME=f"{tmp}/c", XDG_DATA_HOME=f"{tmp}/d", XDG_STATE_HOME=f"{tmp}/s")
        r = subprocess.run([str(BIN), "__retired-integrations-selftest"], capture_output=True, text=True, env=env, timeout=600)
        return r.returncode, r.stdout


def failed_ids(out):
    return {m.group(1) for m in re.finditer(r"^✖ (\S+)", out, re.M)}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--only", type=int)
    a = p.parse_args()
    ok, out = build()
    rc, base = selftest() if ok else (1, out)
    if not ok or rc != 0:
        print("✖ the unmutated baseline does not build or pass; refusing to judge breaks\n" + base[-2000:])
        return 1
    print("baseline passes")
    caught = total = 0
    for n, (label, rel, pairs, ids, plat) in enumerate(MUTATIONS, 1):
        if a.only and a.only != n:
            continue
        if plat and plat != platform.system():
            print(f"· {label} — {plat} only, skipped here")
            continue
        total += 1
        path = ROOT / rel
        original = path.read_text()
        mutated, bad = original, False
        for o, nw in pairs:
            if mutated.count(o) != 1:
                print(f"✖ {label}: anchor found {mutated.count(o)}×: {o[:70]!r}")
                bad = True
                break
            mutated = mutated.replace(o, nw, 1)
        if bad:
            continue
        try:
            path.write_text(mutated)
            ok, out = build()
            if not ok:
                print(f"✖ {label}: mutated tree does not compile (break not meaningful)\n{out[-800:]}")
                continue
            rc, out = selftest()
            hit = sorted(i for i in failed_ids(out) if any(i == e or i.startswith(e) for e in ids))
            if rc != 0 and hit:
                caught += 1
                print(f"✔ {label} — caught by {', '.join(hit)}")
            else:
                print(f"✖ {label} — NOT caught by the intended check {ids} (rc {rc}, failed {sorted(failed_ids(out))})")
        finally:
            path.write_text(original)
    ok, _ = build()
    print(f"\n{caught}/{total} deliberate breaks caught; restored tree {'builds' if ok else 'DOES NOT BUILD'}")
    return 0 if caught == total and ok else 1


if __name__ == "__main__":
    sys.exit(main())
