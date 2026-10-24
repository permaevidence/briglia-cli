#!/usr/bin/env python3
"""Deliberate breaks for the security plan v16 Phase 3 core (§9.5, §15
items 15-16: every rule has a counterpart that must fail). Each mutation
edits ONE source location in this checkout, rebuilds incrementally,
requires `briglia __local-tools-selftest` to FAIL, and restores the file —
also on error or Ctrl-C. Local review tool (it rebuilds the debug binary
per break), not a CI step. Publisher breaks live in
scripts/advisory_publish_test.py.

Usage: security_phase3_mutation_test.py [--only N]
"""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug/briglia"
S = "TelegramConcierge/Services/"
LIST, MATCH, ENGINE, STORE, SVC = S + "LocalAdvisoryList.swift", S + "LocalToolsMatcher.swift", S + "LocalVulnEngine.swift", \
    S + "LocalAdvisoryStore.swift", S + "LocalToolsService.swift"
INV, NSTORE = S + "LocalToolsInventory.swift", S + "UpdateNoticeStore.swift"

MUTATIONS = [
    ("B1 the verifier accepts a validity above 72 h", LIST,
     "guard doc.expires.timeIntervalSince(doc.published) <= maxValidity else {",
     "guard doc.expires.timeIntervalSince(doc.published) <= maxValidity || true else {"),
    ("B2 the verifier accepts a list published in the future", LIST,
     "guard doc.published <= now.addingTimeInterval(futureSkew) else",
     "guard doc.published <= now.addingTimeInterval(futureSkew) || true else"),
    ("B3 ranges compare the binary version, not the source version", MATCH,
     "LocalToolsVersion.isAffected(i.compareVersion, a.affected, scheme: scheme)",
     "LocalToolsVersion.isAffected(i.installedVersion, a.affected, scheme: scheme)"),
    ("B4 'installed < fixed' matching instead of the affected ranges", MATCH,
     "guard let applies = LocalToolsVersion.isAffected(i.compareVersion, a.affected, scheme: scheme) else {",
     "guard let applies = a.remediation?.fixed.first.flatMap({ LocalToolsVersion.compare(i.compareVersion, $0.version, scheme: scheme) }).map({ $0 < 0 }) ?? LocalToolsVersion.isAffected(i.compareVersion, a.affected, scheme: scheme) else {"),
    ("B5 duplicate coverage rows are tolerated", MATCH,
     "            guard bySource[row.source] == nil else {",
     "            guard bySource[row.source] == nil || true else {"),
    ("B6 a failed source is treated as clean", MATCH,
     "            case .ok?: break",
     "            case .ok?, .failed?: break"),
    ("B7 F3 broken: a trimmed identity shows 'no known issue'", MATCH,
     "        } else if r.trimmed {", "        } else if false {"),
    ("B8 the old rule: partial makes the whole identity unknown", MATCH,
     "            case .partial?: trimmed = true",
     "            case .partial?: return .unknown(Text(\"partial\", \"partial\"))"),
    ("B9 coverage freshness ignored", MATCH,
     "guard age <= LocalAdvisory.coverageFreshness, age >= -LocalAdvisory.futureSkew else {",
     "guard true else {"),
    ("B10 the origin check ignored", MATCH,
     "        if let why = i.originProblem { r.reason = why; return r }", ""),
    ("B11 an ambiguous outcome is retried", ENGINE,
     "        case .ambiguous: a.state = .ambiguous", "        case .ambiguous: a.state = .refused; a.retryAfter = now"),
    ("B12 the KEV fix follow-up can repeat", ENGINE,
     "r.affected.contains(where: { $0.kev && $0.fix == .installable }), !row.fixFollowUpSent {",
     "r.affected.contains(where: { $0.kev && $0.fix == .installable }) {"),
    ("B13 escalation is not limited to one", ENGINE,
     "if exceeds, !row.escalationUsed {", "if exceeds {"),
    ("B14 a failed inventory probe removes rows", ENGINE,
     "            case .unknown: return false", "            case .unknown: return true"),
    ("B15 messages sent from an unknown state", ENGINE,
     "for r in reports where r.messageable {", "for r in reports where r.messageable || r.state == .unknown {"),
    ("B16 the 256-row overflow is not quiet", ENGINE,
     "if s.rows.count + newKeys >= maxRows { overflow += 1; continue }", "if false { overflow += 1; continue }"),
    ("B17 a lower sequence regresses the observation", STORE,
     "            if d.lowerSince == nil { d.lowerSince = now }",
     "            d = fresh\n            if d.lowerSince == nil { d.lowerSince = now }"),
    ("B18 a conflict does not block messages", SVC,
     "return d.contentId == contentId && d.expires > now && d.conflictSince == nil",
     "return d.contentId == contentId && d.expires > now"),
    ("B19 no recheck before the send", SVC,
     "guard fresh.map({ \"\\($0.key)|\\($0.kind.rawValue)\" }) == first.map({ \"\\($0.key)|\\($0.kind.rawValue)\" }) else {",
     "guard true else {"),
    ("B20 /deleteuserdata keeps localvuln.json and the observation", NSTORE,
     "            try LocalAdvisoryStore.unlinkDerived(.under(paths))", ""),
    ("B21 a locally invalid package name may reach a command", INV,
     'static let debNamePattern = "^[a-z0-9][a-z0-9+.-]{0,127}(:[a-z0-9-]{1,32})?$"',
     'static let debNamePattern = ".*"'),
    ("B22 OFF still fetches the list (both guards removed)", SVC,
     [("        guard setting.enabled else { return false }\n        let (obs, _) = LocalAdvisoryStore.snapshot(deps.paths)",
       "        let (obs, _) = LocalAdvisoryStore.snapshot(deps.paths)"),
      ("                guard setting.enabled else { return nil }\n                obs.lastAttempt = start",
       "                obs.lastAttempt = start")], None),
    ("B23 the fetch happens outside the update-check window", SVC,
     "if afterCheck, fetchDue() { fetched = await runFetch() }", "if fetchDue() { fetched = await runFetch() }"),
    ("B25 (R3) a candidate of another source counts as a fix", MATCH,
     "            guard srcName == i.identity.source else {", "            guard true else {"),
    ("B26 (R4) a retry checks only generic eligibility", ENGINE,
     "            return condition(r, kind: line.kind) == line.condition", "            return true"),
    ("B27 (R5) another advisory's fix triggers the KEV follow-up", ENGINE,
     "r.affected.contains(where: { $0.kev && $0.fix == .installable }), !row.fixFollowUpSent {",
     "r.hasInstallableFix, !row.fixFollowUpSent {"),
    ("B28 (R6) one member's absence removes a shared row", ENGINE,
     "            if evidence.isEmpty || evidence.contains(false) { kept.append(row) }",
     "            if evidence.isEmpty || evidence.allSatisfy({ !$0 }) { kept.append(row) }"),
    ("B29 (R7) the browser checked in another order than the renderer's", INV,
     'static let rendererBrowserNames = ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]',
     'static let rendererBrowserNames = ["google-chrome", "chromium", "chromium-browser", "google-chrome-stable"]'),
    ("B30 (N2) index age truncated to whole days", S + "LocalToolsInventoryDeb.swift",
     "        guard youngest <= 7 * 86_400 else {", "        guard Int(youngest / 86_400) <= 7 else {"),
    ("B31 (R1) explicitly listed versions ignored by the client", S + "LocalToolsVersion.swift",
     "        for v in affected.versions {", "        for v in [String]() {"),
    ("B32 (R5/N16-3) an escalation with a fix drops the KEV mitigation", S + "LocalToolsText.swift",
     "            if let m = kevMitigationSentence(r, lang: lang, also: !fixable(r).isEmpty) { s += \" \" + m }", ""),
    ("B24 consume after the send (not before)", SVC,
     "                LocalVuln.consume(&v, fresh, text: text, listContentId: contentId, noticeGeneration: setting.generation,\n                                  destination: destination, now: now)\n",
     ""),
]


def build():
    r = subprocess.run(["swift", "build", "--build-system", "native"], cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, r.stdout[-2000:] + r.stderr[-2000:]


def selftest():
    with tempfile.TemporaryDirectory() as tmp:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_"))}
        env.update(HOME=tmp, XDG_CONFIG_HOME=f"{tmp}/c", XDG_DATA_HOME=f"{tmp}/d", XDG_STATE_HOME=f"{tmp}/s")
        r = subprocess.run([str(BIN), "__local-tools-selftest"], capture_output=True, text=True, env=env, timeout=600)
        return r.returncode, r.stdout


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--only", type=int)
    a = p.parse_args()
    caught = total = 0
    for n, (label, rel, old, new) in enumerate(MUTATIONS, 1):
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
            rc, out = selftest()
            if rc != 0:
                caught += 1
                first = next((l for l in out.splitlines() if l.startswith("✖")), "?")
                print(f"✔ {label} — caught: {first[:140]}")
            else:
                print(f"✖ {label} — NOT caught")
        finally:
            path.write_text(original)
    ok, out = build()
    print(f"\n{caught}/{total} deliberate breaks caught; restored tree {'builds' if ok else 'DOES NOT BUILD'}")
    return 0 if caught == total and ok else 1


if __name__ == "__main__":
    sys.exit(main())
