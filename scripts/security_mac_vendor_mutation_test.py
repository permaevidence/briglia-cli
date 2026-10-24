#!/usr/bin/env python3
"""Deliberate breaks for the security plan v17-v20 additions (§9.5.9 macOS
weekly message, §9.5.10 official Node.js and LibreOffice): each mutation
edits ONE source location in this checkout, rebuilds incrementally, requires
`briglia __local-tools-selftest` to FAIL, and restores the file — also on
error or Ctrl-C. Local review tool (it rebuilds the debug binary per break),
not a CI step. Publisher breaks live in scripts/advisory_node_test.py and
scripts/advisory_libreoffice_test.py.

Usage: security_mac_vendor_mutation_test.py [--only N]
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("phase3_mut", os.path.join(HERE, "security_phase3_mutation_test.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

S = "TelegramConcierge/Services/"
MU, MUI, MUS, MUT = S + "MacUpdates.swift", S + "MacUpdatesInventory.swift", S + "MacUpdatesService.swift", S + "MacUpdatesText.swift"
INV, DEB, MATCH, TEXT, VER, PARSE = (S + "LocalToolsInventory.swift", S + "LocalToolsInventoryDeb.swift", S + "LocalToolsMatcher.swift",
                                     S + "LocalToolsText.swift", S + "LocalToolsVersion.swift", S + "LocalAdvisoryParse.swift")

base.MUTATIONS = [
    ("M1 a version bump of a waiting item counts as new", MU,
     "        return e.waiting.filter { !recorded.contains($0.key) }",
     "        return e.waiting.filter { !recorded.contains($0.key) || $0.available != nil }"),
    ("M2 the 7-day gate is ignored", MU,
     "        return now.timeIntervalSince(last) >= messageInterval", "        return true"),
    ("M3 unknown evidence resolves recorded keys", MU,
     "        s.notified.removeAll { resolved.contains($0.key) ||",
     "        s.notified.removeAll { !e.complete || resolved.contains($0.key) ||"),
    ("M4 quiet overflow does not suppress news", MU,
     "        guard s.quietOverflow == nil else { return [] }", ""),
    ("M5 overflow reset on 'fits' alone", MU,
     "            if e.waiting.allSatisfy({ recorded.contains($0.key) }) { s.quietOverflow = nil }",
     "            s.quietOverflow = nil"),
    ("M6 an ambiguous outcome keeps the attempt", MU,
     "        case .ambiguous: a.state = .ambiguous", "        case .ambiguous: a.state = .refused; a.retryAfter = now"),
    ("M7 the clock clamp is skipped", MU,
     "        if let last = s.lastMessageAt, last > now.addingTimeInterval(24 * 3600) { s.lastMessageAt = now }", ""),
    ("M8 a stale catalogue still gives evidence", MUI,
     "            return now.timeIntervalSince(at) <= freshness && at.timeIntervalSince(now) <= futureSkew",
     "            return true"),
    ("M9 pinned formulae are not excluded", MUI,
     "                    if pinned(formula) == true {", "                    if false {"),
    ("M10 auto_updates casks are not excluded", MUI,
     "                    if entry.autoUpdates {", "                    if false {"),
    ("M11 LibreOffice: newer-than-both counts as waiting", MUI,
     "        return (false, nil)                          // newer than both, or between: no reference",
     "        return (true, s)"),
    ("M12 Software Update staleness ignored", MUI,
     "              now.timeIntervalSince(asOf) <= freshness, asOf.timeIntervalSince(now) <= futureSkew,",
     "              true,"),
    ("M13 unsafe Software Update names shown", MUI,
     "        guard let s, !s.isEmpty, s.count <= 80, !s.contains(\"`\"), !s.contains(\"\\n\"), !s.contains(\"\\r\"),",
     "        guard let s, !s.isEmpty,"),
    ("M14 the weekly message sends while a turn runs", MUS,
     [("    func deliver() async {\n        guard deps.isIdle() else { return }", "    func deliver() async {"),
      ("        let fresh = await deps.evaluate()\n        guard deps.isIdle() else { return }\n        let now = deps.now()",
       "        let fresh = await deps.evaluate()\n        let now = deps.now()")], None),
    ("M15 formula names are not validated in the command", MUT,
     "        let formulae = items.filter { $0.kind == .formula }.compactMap(\\.command).filter(LocalTools.validBrewName)",
     "        let formulae = items.filter { $0.kind == .formula }.compactMap(\\.command)"),
    ("M16 an nvm version mismatch is accepted", INV,
     "            return pathVersion == version ? present(\"nvm\") : mismatch", "            return present(\"nvm\")"),
    ("M17 a missing installer receipt falls through", INV,
     "                return unknown(\"\\(path) has no nodejs.org installer receipt\", \"\\(path) non ha la ricevuta dell'installer di nodejs.org\")",
     "                return present(\"pkg\")"),
    ("M18 conda roots accepted", INV,
     "        if p.listDirectory(rootPath + \"/conda-meta\") != nil { return notRecognised }", ""),
    ("M19 a failed dpkg probe counts as 'not owned'", DEB,
     "                if !(st == 1 && out.contains(\"no path found matching pattern\")) { positivelyUnowned = false }", ""),
    ("M20 pacman ownership ignored", DEB,
     "            if st == 0 { return T.Text(\"\\(path) is packaged by your distribution (pacman)\", \"\\(path) è un pacchetto della tua distribuzione (pacman)\") }", ""),
    ("M21 release records counted as known vulnerabilities", MATCH,
     "            if a.kind == .release { r.releases.append(result) } else { r.affected.append(result) }",
     "            r.affected.append(result)"),
    ("M22 maintained lines ignored", MATCH,
     "        } else if let unmaintained {", "        } else if let unmaintained, false {"),
    ("M23 unknownOutside ignored", MATCH,
     "                if a.unknownOutside && !inListedSeries(i.compareVersion, a) { r.unknownAdvisories += 1 }", ""),
    ("M24 unknownOutside applied inside a listed series", MATCH,
     "                if a.unknownOutside && !inListedSeries(i.compareVersion, a) { r.unknownAdvisories += 1 }",
     "                if a.unknownOutside { r.unknownAdvisories += 1 }"),
    ("M25 N.N remediation lines not matched", VER,
     "            if parts.count >= 2, let hit = r.fixed.first(where: { $0.line == \"\\(parts[0]).\\(parts[1])\" }) { return hit.version }", ""),
    ("M26 an unknown advisory kind treated as a vulnerability", PARSE,
     "            kind = s == \"release\" ? .release : .unsupported", "            kind = s == \"release\" ? .release : .vulnerability"),
    ("M27 release-only wording says 'known security problem'", TEXT,
     "            if !r.hasInstallableFix, kevUnfixed(r).isEmpty, r.releaseUpdateInstallable {",
     "            if false {"),
    ("M28 an invalid tarball directory name reaches the text", TEXT,
     "                guard let root, root.range(of: \"^node-v[0-9.]{5,14}-(darwin|linux)-(x64|arm64|armv7l|ppc64le|s390x)$\", options: .regularExpression) != nil else { return nil }",
     "                guard let root else { return nil }"),
]

if __name__ == "__main__":
    sys.exit(base.main())
