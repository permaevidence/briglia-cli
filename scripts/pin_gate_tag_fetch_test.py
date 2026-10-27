#!/usr/bin/env python3
"""The authorize job reads the REAL annotated release tag (v0.2.63 regression).

In signed run 40426023973 actions/checkout v5 fetched every tag, then fetched
`+<sha>:refs/tags/v0.2.63` again, replacing the promoter's annotated tag in
the runner clone with a lightweight ref ("t [tag update]"). The pin-gate
precheck then read `git cat-file -t refs/tags/v0.2.63` = commit and refused
a correct release. .github/scripts/read-pin-gate-record.sh now re-fetches the
remote tag by name into a private ref and reads that.

This test needs no network: a local bare "origin" holds a commit and several
tags, and each case builds a fresh runner clone with the SAME two fetch
commands checkout ran (copied from the run log), then runs the real script.

  * positive control: after the checkout fetches, refs/tags/<tag> in the
    clone is a commit (the clobbering is reproduced) and the old inline check
    refuses it;
  * the script passes on the promoter's annotated tag and writes exactly the
    tag body (the pin-gate record);
  * it refuses: a lightweight tag, a missing tag, an annotated tag on another
    commit, an annotated tag with an empty body, a non-SemVer name, a short
    SHA; and it never leaves a stale record file behind as success;
  * the workflow calls the script (with $REF_NAME, $GITHUB_SHA and
    dist/pin-gate-record.txt) before the precheck, and no longer reads
    refs/tags/$REF_NAME directly;
  * deliberate breaks: copies of the script with the fetch removed (reads the
    clobbered ref), the type check pointed at the clobbered ref, the type
    check removed, the peel check removed, the empty-body check removed, the
    fetch failure ignored, or the SemVer re-check removed must each be
    rejected by these cases. (The SHA-format check is defence in depth: the
    peel comparison already rejects any SHA that is not the exact commit.)
Exit 0 = all checks passed.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, ".github", "scripts", "read-pin-gate-record.sh")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release-signed.yml")
TAG = "v0.2.63"
RECORD = "briglia-pin-gate v1\ncommit: {sha}\nchecked-at: 2026-10-26T20:00:00Z\n"

PASSED = 0
FAILED = 0


def check(label, ok, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print(f"  ✓ {label}")
    else:
        FAILED += 1
        print(f"  ✖ {label}")
        if detail:
            print("    " + str(detail).replace("\n", "\n    ")[:1500])


def env():
    e = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    e.update({"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
              "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
              "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
              "GIT_TERMINAL_PROMPT": "0"})
    return e


def git(cwd, *args, check_rc=True):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=env())
    if check_rc and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def make_origin(tmp, kind):
    """kind: annotated | lightweight | missing | other-commit | empty-body"""
    work = os.path.join(tmp, f"src-{kind}")
    os.makedirs(work)
    git(work, "init", "-q", "-b", "main")
    with open(os.path.join(work, "f"), "w") as f:
        f.write("one\n")
    git(work, "add", "f")
    git(work, "commit", "-q", "-m", "one")
    first = git(work, "rev-parse", "HEAD")
    with open(os.path.join(work, "f"), "w") as f:
        f.write("two\n")
    git(work, "commit", "-q", "-am", "two")
    sha = git(work, "rev-parse", "HEAD")
    if kind == "annotated":
        git(work, "tag", "-a", TAG, "-m", RECORD.format(sha=sha), sha)
    elif kind == "lightweight":
        git(work, "tag", TAG, sha)
    elif kind == "other-commit":
        git(work, "tag", "-a", TAG, "-m", RECORD.format(sha=first), first)
    elif kind == "empty-body":
        git(work, "tag", "-a", "--cleanup=verbatim", TAG, "-m", "", sha)
    bare = os.path.join(tmp, f"origin-{kind}.git")
    git(tmp, "clone", "-q", "--bare", work, bare)
    return bare, sha


def checkout_clone(tmp, bare, sha, name):
    """The exact fetch sequence actions/checkout v5 ran in run 40426023973."""
    clone = os.path.join(tmp, name)
    os.makedirs(clone)
    git(clone, "init", "-q")
    git(clone, "remote", "add", "origin", "file://" + bare)
    git(clone, "-c", "protocol.version=2", "fetch", "--prune", "--no-recurse-submodules", "origin",
        "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/tags/*")
    git(clone, "-c", "protocol.version=2", "fetch", "--no-tags", "--prune", "--no-recurse-submodules",
        "origin", f"+{sha}:refs/tags/{TAG}")
    git(clone, "checkout", "-q", "--force", sha)
    return clone


def run_reader(script, clone, tag, sha, out):
    return subprocess.run(["bash", "-e", script, tag, sha, out], cwd=clone,
                          capture_output=True, text=True, env=env(), timeout=60)


def battery(script, tmp, quiet=False):
    """Returns the list of failed case labels for `script`."""
    fails = []

    def case(label, ok):
        if not quiet:
            check(label, ok)
        if not ok:
            fails.append(label)

    origins = {k: make_origin(tmp, k) for k in ("annotated", "lightweight", "missing", "other-commit", "empty-body")}

    bare, sha = origins["annotated"]
    clone = checkout_clone(tmp, bare, sha, "clone-annotated")
    out = os.path.join(clone, "dist", "pin-gate-record.txt")
    if not quiet:
        clobbered = git(clone, "cat-file", "-t", f"refs/tags/{TAG}")
        check("positive control: checkout's second fetch leaves refs/tags/<tag> as a commit", clobbered == "commit", clobbered)
        old = subprocess.run(["bash", "-c", f'[ "$(git cat-file -t "refs/tags/{TAG}")" = "tag" ]'],
                             cwd=clone, env=env())
        check("positive control: the old inline check refuses the clobbered clone", old.returncode != 0)
    r = run_reader(script, clone, TAG, sha, out)
    body = open(out).read() if os.path.exists(out) else None
    case("annotated tag: passes", r.returncode == 0)
    case("annotated tag: writes exactly the pin-gate record",
         body is not None and body.strip() == RECORD.format(sha=sha).strip())
    r2 = run_reader(script, clone, TAG, sha, out)
    case("annotated tag: a second read in the same clone also passes", r2.returncode == 0)

    for kind, msg in (("lightweight", "not an annotated tag"), ("missing", "could not fetch"),
                      ("other-commit", "does not point at the tagged commit"), ("empty-body", "no pin-gate record")):
        bare, sha_k = origins[kind]
        clone_k = os.path.join(tmp, f"clone-{kind}")
        if kind == "missing":
            # checkout of a tag that does not exist would not get here; model
            # a clone whose remote has no such tag but the commit exists.
            os.makedirs(clone_k)
            git(clone_k, "init", "-q")
            git(clone_k, "remote", "add", "origin", "file://" + bare)
            git(clone_k, "fetch", "-q", "origin", "+refs/heads/*:refs/remotes/origin/*")
            git(clone_k, "tag", TAG, sha_k)  # a local lightweight ref only
        else:
            clone_k = checkout_clone(tmp, bare, sha_k, f"clone-{kind}")
        out_k = os.path.join(clone_k, "dist", "pin-gate-record.txt")
        rk = run_reader(script, clone_k, TAG, sha_k, out_k)
        case(f"{kind}: refused", rk.returncode != 0)
        case(f"{kind}: says why", msg in (rk.stdout + rk.stderr))

    # an annotated tag with a valid record but a non-release name: only the
    # script's own SemVer re-check refuses it
    bare, sha = origins["annotated"]
    src = os.path.join(tmp, "src-annotated")
    git(src, "tag", "-a", "release-x", "-m", RECORD.format(sha=sha), sha)
    git(src, "push", "-q", bare, "refs/tags/release-x")
    rr = run_reader(script, clone, "release-x", sha, os.path.join(tmp, "y.txt"))
    case("annotated non-SemVer tag with a valid record: refused", rr.returncode != 0)
    for label, tag, s in (("non-SemVer tag name", "v0.2.63;rm", sha), ("short SHA", TAG, sha[:12]),
                          ("SHA of another commit", TAG, "0" * 40)):
        rr = run_reader(script, clone, tag, s, os.path.join(tmp, "x.txt"))
        case(f"{label}: refused", rr.returncode != 0)
    return fails


def static_checks():
    wf = open(WORKFLOW).read()
    auth = wf[wf.index("  authorize:\n"):wf.index("  build-macos-arm64:\n")]
    call = './.github/scripts/read-pin-gate-record.sh "$REF_NAME" "$GITHUB_SHA" dist/pin-gate-record.txt'
    check("workflow: authorize calls the reader with the tag, the tagged commit and the record path", call in auth)
    check("workflow: the reader runs before the credential-free precheck",
          0 <= auth.find(call) < auth.find("--mode precheck"))
    check("workflow: authorize no longer reads refs/tags/$REF_NAME directly (checkout clobbers it)",
          not re.search(r'refs/tags/\$REF_NAME', auth))
    check("workflow: the record artifact is still uploaded for the sign job", "path: dist/pin-gate-record.txt" in auth)
    check("reader script is executable", os.access(SCRIPT, os.X_OK))
    src = open(SCRIPT).read()
    check("reader script runs under set -euo pipefail", "set -euo pipefail" in src)


BREAKS = [
    ("fetch removed: reads the clobbered refs/tags ref",
     lambda s: s.replace('PRIV="refs/briglia-pin-gate/$TAG"', 'PRIV="refs/tags/$TAG"')
                .replace('git fetch --no-tags --no-recurse-submodules "$REMOTE" "+refs/tags/$TAG:$PRIV" >/dev/null 2>&1 || {',
                         'true || {')),
    ("type check reads the clobbered refs/tags ref instead of the fetched tag",
     lambda s: s.replace('[ "$(git cat-file -t "$PRIV")" = "tag" ]', '[ "$(git cat-file -t "refs/tags/$TAG")" = "tag" ]')),
    ("type check removed", lambda s: s.replace('[ "$(git cat-file -t "$PRIV")" = "tag" ] ||', 'true ||')),
    ("peel check removed", lambda s: s.replace('[ "$(git rev-parse --verify --quiet "$PRIV^{commit}")" = "$SHA" ] ||', 'true ||')),
    ("empty-body check removed", lambda s: s.replace('[ -s "$OUT" ] ||', 'true ||')),
    ("fetch failure ignored", lambda s: s.replace('>/dev/null 2>&1 || {\n    echo "✖ $TAG: could not fetch',
                                                  '>/dev/null 2>&1 || true; false && {\n    echo "✖ $TAG: could not fetch')),
    ("SemVer re-check removed", lambda s: s.replace("grep -Eq '^v[0-9]+\\.[0-9]+\\.[0-9]+$' || {", "true || {")),
]


def main():
    print("— pin-gate tag fetch (checkout clobbering regression) —")
    static_checks()
    with tempfile.TemporaryDirectory(prefix="pgtf-") as tmp:
        real = os.path.join(tmp, "real")
        os.makedirs(real)
        battery(SCRIPT, real)
        print("— deliberate breaks (each must be rejected) —")
        src = open(SCRIPT).read()
        caught = 0
        for i, (label, mutate) in enumerate(BREAKS):
            mutated = mutate(src)
            if mutated == src:
                check(f"break '{label}' applied", False, "mutation did not change the script")
                continue
            d = os.path.join(tmp, f"break{i}")
            os.makedirs(d)
            p = os.path.join(d, "reader.sh")
            with open(p, "w") as f:
                f.write(mutated)
            found = battery(p, d, quiet=True)
            caught += bool(found)
            check(f"break rejected: {label}", bool(found))
        print(f"  {caught}/{len(BREAKS)} deliberate breaks caught")
    print(f"\npin-gate tag fetch: {PASSED} passed, {FAILED} failed")
    return 0 if FAILED == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
