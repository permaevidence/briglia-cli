#!/usr/bin/env python3
"""Deliberate breaks for keyless web (KEYLESS_WEB_AND_LIVE_MENU_PLAN A.10).

Same method as multi_assistant_break_test.py: copy the tree to a scratch
directory, build once (positive control: `__web-backend-selftest` passes),
then apply one mutation at a time, rebuild incrementally and require the
NAMED check of the selftest to be reported as failed (✖), not just a
non-zero exit. The repository is never modified.

Usage: python3 scripts/keyless_web_break_test.py [--keep-build DIR] [--only K1,K2]
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

# (label, check id that must fail, file, old, new)
BREAKS = [
    ("K1 the search ID is rotated on a rate limit", "S.11", S + "WebOrchestrator.swift",
     "            let sessionID = try ParallelSessionStore.idForSearch()\n",
     "            let sessionID = UUID().uuidString.lowercased()\n"),
    ("K2 a damaged session file is silently re-minted", "S.6", S + "ParallelSessionStore.swift",
     "        case .damaged(let reason): throw Damaged(reason: reason)\n        case .absent: return try mintLocked()",
     "        case .damaged: return try mintLocked()\n        case .absent: return try mintLocked()"),
    ("K3 the image-alt header is sent without a key", "J.2", S + "WebOrchestrator.swift",
     "        if includeImageCaptions && !keyless {", "        if includeImageCaptions {"),
    ("K4 a failing Serper falls back to Parallel", "R.5", S + "WebOrchestrator.swift",
     "                            return (q, try await self.serperSearch(q, apiKey: config.serperKey), nil)",
     "                            do { return (q, try await self.serperSearch(q, apiKey: config.serperKey), nil) } catch { return (q, try await self.parallelSearch(q), nil) }"),
    ("K5 BRIGLIA_KEYLESS_SEARCH=0 is ignored", "R.1", S + "WebServiceConfig.swift",
     "        return env[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) == \"0\"",
     "        _ = env; return false"),
    ("K6 a typed keyless domain block counts in health", "J.3", S + "WebOrchestrator.swift",
     "                    throw blocked\n",
     "                    await ToolServiceHealth.shared.recordFailure(.webFetchFree, error: blocked.localizedDescription, transientOnly: true)\n                    throw blocked\n"),
    ("K7 the keyed web_query description changes (gate alters keyed lists)", "R.9", S + "WebServiceConfig.swift",
     "        service == .parallelKeyless ? webQueryKeyless : webQuery", "        service == .none ? webQuery : webQueryKeyless"),
    ("K8 a child executor copies the configuration instead of sharing it", "X.4", S + "ToolExecutor.swift",
     "        let child = ToolExecutor(outputMode: .subagent, depth: depth + 1, webConfig: webConfig)",
     "        let child = ToolExecutor(outputMode: .subagent, depth: depth + 1, webConfig: WebServiceConfigBox(webConfig.current))"),
    ("K9 a generic 400 is taken as session expiry", "P2.3", S + "ParallelSearchClient.swift",
     "        if status == 404 && carriedSession { return .expired }", "        if (status == 404 || status == 400) && carriedSession { return .expired }"),
    ("K10 a retry ignores a Retry-After past the deadline", "P2.7", S + "ParallelSearchClient.swift",
     "                    let wait = retryAfter ?? limits.defaultBackoff",
     "                    let wait = min(retryAfter ?? limits.defaultBackoff, 0.05)"),
    ("K11 the breaker never opens", "P3.1", S + "ParallelSearchClient.swift",
     "        if probe || consecutiveFailures >= limits.breakerThreshold {", "        if probe || consecutiveFailures >= 1_000 {"),
    ("K12 no concurrency cap", "P3.6", S + "ParallelSearchClient.swift",
     "        if inFlight < limits.maxConcurrent {", "        if inFlight < 1_000 {"),
    ("K13 keyless retries are not charged to the pacer", "J.8", S + "WebOrchestrator.swift",
     "                    try await pacer.acquire()\n", "                    _ = pacer\n"),
    ("K14 a keyless 401 alerts immediately", "J.6", S + "WebOrchestrator.swift",
     "                await ToolServiceHealth.shared.recordFailure(.webFetchFree, error: error.localizedDescription, transientOnly: true)",
     "                await ToolServiceHealth.shared.recordFailure(.webFetchFree, error: error.localizedDescription)"),
    ("K15 the expiry recovery does not consume the second attempt", "P2.2", S + "ParallelSearchClient.swift",
     "                    budget.recoveries += 1\n", "                    budget.recoveries += 1\n                    budget.searchAttempts -= 1\n"),
    ("K16 '.none' still sends Serper an empty key", "R.3", S + "WebOrchestrator.swift",
     "                            return (q, nil, Self.noSearchServiceMessage)",
     "                            return (q, try await self.serperSearch(q, apiKey: \"\"), nil)"),
    # Codex round 1 (KEYLESS_WEB_IMPL_CODEX_REVIEW_2026-10-30).
    ("K17 a cancelled caller keeps waiting for the shared initialize", "P4.1", S + "ParallelSearchClient.swift",
     "            Task { await self.failInitWaiter(id, with: CancellationError()) }", "            _ = id"),
    ("K18 server requests are answered only after the stream completes", "P1.16", S + "ParallelSearchClient.swift",
     "        for request in requests { onServerRequest(request, streamSession) }", "        _ = requests; _ = streamSession"),
    ("K19 an HTTP-date Retry-After is ignored", "P2.13", S + "ParallelSearchClient.swift",
     "        if let seconds = TimeInterval(value) { return seconds.isFinite && seconds >= 0 ? seconds : nil }",
     "        if let seconds = TimeInterval(value) { return seconds.isFinite && seconds >= 0 ? seconds : nil }; if !value.isEmpty { return nil }"),
    ("K20 a failed post-link barrier is swallowed", "S.12", S + "ParallelSessionStore.swift",
     "        return try confirmedLocked(id)\n", "        confirmedID = id; return id\n"),
    ("K21 a discard is reported without a directory barrier", "S.15", S + "ParallelSessionStore.swift",
     "        if FileManager.default.fileExists(atPath: dir.path) { try barrier(dir) }", "        _ = dir"),
    ("K22 an old-session 404 drops a newer session", "P2.12", S + "ParallelSearchClient.swift",
     "        guard session?.generation == gen || (session == nil && generation == gen) else { return }", "        _ = gen"),
    # Codex round 2.
    ("K23 a reply during initialize omits the session the stream assigned", "P1.17", S + "ParallelSearchClient.swift",
     "            let replySession = session ?? streamSession", "            let replySession = session; _ = streamSession"),
    # 0.2.66 CI: S.16 fails the temp write through a seam (root ignores a read-only directory).
    ("K24 a failed temp write falls back to writing the session file directly", "S.16", S + "ParallelSessionStore.swift",
     "        if let hook = writeTempForTesting { try hook(Data(body.utf8), tmp) }\n",
     "        if let hook = writeTempForTesting { do { try hook(Data(body.utf8), tmp) } catch { try Data(body.utf8).write(to: fileURL); return id } }\n"),
    ("K25 the mint ignores the temp-write seam (S.16 would test nothing)", "S.16", S + "ParallelSessionStore.swift",
     "        if let hook = writeTempForTesting { try hook(Data(body.utf8), tmp) }\n",
     "        if let hook = writeTempForTesting, Bool(\"false\") == true { try hook(Data(body.utf8), tmp) }\n"),
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
    # The selftest makes its own scratch roots; never the live install.
    env["XDG_CONFIG_HOME"] = str(Path(workdir) / "outer-config")
    env["XDG_DATA_HOME"] = str(Path(workdir) / "outer-data")
    return run([str(binary), "__web-backend-selftest"], workdir, timeout=900, env=env)


def mutate(tree, rel, old, new):
    path = tree / rel
    text = path.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"break anchor moved: {rel}: {old!r} (found {text.count(old)})")
    path.write_text(text.replace(old, new))
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-build")
    ap.add_argument("--only")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="briglia-kwbreak-"))
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
        for label, check_id, rel, old, new in BREAKS:
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            original = mutate(tree, rel, old, new)
            try:
                binary = build(tree, scratch)
                r = selftest(binary, work)
                failed = [l for l in r.stdout.splitlines() if l.startswith("✖")]
                caught = r.returncode != 0 and any(l.startswith(f"✖ {check_id} ") for l in failed)
                print(("✔" if caught else "✖") + f" {label}: {check_id} fails"
                      + (f" ({len(failed)} failing check(s))" if failed else ""), flush=True)
                failures += 0 if caught else 1
                executed += 1
                if not caught and args.verbose:
                    print((r.stdout + r.stderr)[-6000:])
            finally:
                (tree / rel).write_text(original)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
