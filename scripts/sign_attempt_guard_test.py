#!/usr/bin/env python3
"""The signing job signs only in run attempt 1 (RELEASE_RUNBOOKS.md §2a).

The release watcher trusts a signing execution only in attempt 1 of a signed
run (the v0.2.52 false alert came from a "Re-run failed jobs" that signed in
attempt 3). The "Sign metadata" job in .github/workflows/release-signed.yml
therefore starts with a guard step that fails unless github.run_attempt is 1,
before checkout and before any secret is referenced.

Static checks on the real workflow (no network, no GitHub calls):
  * the sign job exists, uses the release-sign environment, and has no
    job-level env, if or continue-on-error;
  * its FIRST step is the guard: no `uses:`, no `if:`, no
    `continue-on-error`, no `shell:` override, no secret reference, and its
    only env entry is RUN_ATTEMPT: ${{ github.run_attempt }};
  * no other job references the signing key.
Execution: the guard's own script runs under bash -e (GitHub's default shell
on Linux) with RUN_ATTEMPT=1 (passes, silent) and 2, 3, 10, "", "01", " 1"
(each fails and tells the operator to start a fresh run on the next version
per §2a).
Deliberate breaks: in-memory copies of the workflow with the guard removed,
moved after checkout or after signing, moved to another job, reading the wrong
context, inverted, exiting 0, skippable, continue-on-error, reading a secret,
with a secret in job-level env, or without the environment must each be
rejected.
Exit 0 = all checks passed.
"""
import os
import re
import subprocess
import sys
import tempfile
import textwrap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release-signed.yml")
GUARD_NAME = "One signing execution per run (attempt 1 only)"
SIGNING_SECRET = "secrets.BRIGLIA_CLI_SIGNING_KEY"

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
            print("    " + str(detail).replace("\n", "\n    ")[:2000])


def jobs_of(text):
    """Map job id -> job text (two-space-indented keys under `jobs:`)."""
    body = text.split("\njobs:\n", 1)[1] if "\njobs:\n" in text else ""
    out = {}
    for chunk in re.split(r"\n(?=  [A-Za-z0-9_-]+:\n)", "\n" + body):
        m = re.match(r"\n?  ([A-Za-z0-9_-]+):\n", chunk)
        if m:
            out[m.group(1)] = chunk
    return out


def split_job(job_text):
    """Return (header lines before `steps:`, list of step texts)."""
    if "\n    steps:\n" not in job_text:
        return job_text, []
    head, steps = job_text.split("\n    steps:\n", 1)
    parts = re.split(r"\n(?=      - )", "\n" + steps)
    return head, [p.strip("\n") for p in parts if p.strip()]


def step_env(step):
    m = re.search(r"\n        env:\n((?:          .*\n?)+)", step + "\n")
    if not m:
        return None
    env = {}
    for line in m.group(1).splitlines():
        k, _, v = line.strip().partition(":")
        env[k.strip()] = v.strip()
    return env


def step_script(step):
    m = re.search(r"\n        run: \|\n((?:(?:          .*)?\n?)+)", step + "\n")
    return textwrap.dedent(m.group(1)) if m else None


def guard_errors(text):
    errs = []
    jobs = jobs_of(text)
    sign = jobs.get("sign")
    if not sign:
        return ["no sign job"]
    head, steps = split_job(sign)
    if not re.search(r"^    environment: release-sign$", head, re.M):
        errs.append("sign job must use the release-sign environment")
    for key in ("env", "if", "continue-on-error", "defaults", "container"):
        if re.search(rf"^    {key}:", head, re.M):
            errs.append(f"sign job must have no job-level {key}:")
    if not steps:
        return errs + ["sign job has no steps"]
    first = steps[0]
    if f"- name: {GUARD_NAME}" not in first.splitlines()[0]:
        errs.append("the first sign step must be the attempt-1 guard")
    for key in ("uses", "if", "continue-on-error", "shell", "working-directory"):
        if re.search(rf"^(      - |        ){key}:", first, re.M):
            errs.append(f"the guard step must not carry {key}:")
    if "secrets." in first:
        errs.append("the guard step must not reference any secret")
    if step_env(first) != {"RUN_ATTEMPT": "${{ github.run_attempt }}"}:
        errs.append("the guard's only env must be RUN_ATTEMPT: ${{ github.run_attempt }}")
    if step_script(first) is None:
        errs.append("the guard step has no run script")
    for job_id, job_text in jobs.items():
        if job_id != "sign" and SIGNING_SECRET in job_text:
            errs.append(f"job {job_id} references the signing key")
    if SIGNING_SECRET not in "\n".join(steps[1:]):
        errs.append("the signing key must be referenced only after the guard, inside the sign job")
    return errs


def run_guard(script, attempt):
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write(script)
        path = f.name
    try:
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "RUN_ATTEMPT": attempt}
        r = subprocess.run(["bash", "--noprofile", "--norc", "-e", path],
                           capture_output=True, text=True, env=env, timeout=30)
        return r.returncode, r.stdout + r.stderr
    finally:
        os.unlink(path)


def execution_errors(text):
    """Run the guard's script; return a list of failures (empty = behaves)."""
    jobs = jobs_of(text)
    _, steps = split_job(jobs.get("sign", ""))
    script = step_script(steps[0]) if steps else None
    if not script:
        return ["no guard script to run"]
    errs = []
    rc, out = run_guard(script, "1")
    if rc != 0 or out.strip():
        errs.append(f"attempt 1 must pass silently (rc={rc}, out={out!r})")
    for bad in ("2", "3", "10", "", "01", " 1"):
        rc, out = run_guard(script, bad)
        if rc == 0:
            errs.append(f"attempt {bad!r} must fail")
        elif "§2a" not in out or "next version" not in out:
            errs.append(f"attempt {bad!r}: message must point to §2a and the next version ({out!r})")
    return errs


def main():
    text = open(WORKFLOW, encoding="utf-8").read()
    print("— release-signed.yml: sign job attempt-1 guard —")
    errs = guard_errors(text)
    check("static: guard is the first sign step, before checkout and any secret", not errs, "\n".join(errs))
    xerrs = execution_errors(text)
    check("execution: attempt 1 passes; 2, 3, 10, empty, '01', ' 1' fail with the §2a message",
          not xerrs, "\n".join(xerrs))

    if errs:
        print("  (deliberate breaks skipped: the real workflow has no valid guard)")
        print(f"\n{FAILED} FAILED, {PASSED} passed")
        return 1
    jobs = jobs_of(text)
    sign = jobs["sign"]
    head, steps = split_job(sign)
    guard = steps[0]
    rest = steps[1:]

    def rebuild(new_head, new_steps):
        new_sign = new_head + "\n    steps:\n" + "\n".join(new_steps) + "\n"
        return text.replace(sign, new_sign, 1)

    checkout_idx = next(i for i, s in enumerate(rest) if "actions/checkout@" in s)
    sign_idx = next(i for i, s in enumerate(rest) if SIGNING_SECRET in s)
    vc = jobs["verify-candidate"]
    vc_head, vc_steps = split_job(vc)
    moved_to_vc = rebuild(head, rest).replace(
        vc, vc_head + "\n    steps:\n" + "\n".join([guard] + vc_steps) + "\n", 1)

    breaks = [
        ("guard removed", rebuild(head, rest)),
        ("guard after checkout", rebuild(head, rest[:checkout_idx + 1] + [guard] + rest[checkout_idx + 1:])),
        ("guard after signing", rebuild(head, rest[:sign_idx + 1] + [guard] + rest[sign_idx + 1:])),
        ("guard moved to verify-candidate", moved_to_vc),
        ("reads github.run_number", text.replace("${{ github.run_attempt }}", "${{ github.run_number }}", 1)),
        ("condition inverted", text.replace('[ "$RUN_ATTEMPT" = "1" ] ||', '[ "$RUN_ATTEMPT" != "1" ] ||', 1)),
        ("exits 0 on a re-run", text.replace("(RELEASE_RUNBOOKS.md §2a).\"; exit 1; }",
                                             "(RELEASE_RUNBOOKS.md §2a).\"; exit 0; }", 1)),
        ("message drops the §2a pointer", text.replace("next version (RELEASE_RUNBOOKS.md §2a).\"",
                                                       "next version.\"", 1)),
        ("guard skippable with if:", text.replace(f"- name: {GUARD_NAME}\n",
                                                  f"- name: {GUARD_NAME}\n        if: false\n", 1)),
        ("guard continue-on-error", text.replace(f"- name: {GUARD_NAME}\n",
                                                 f"- name: {GUARD_NAME}\n        continue-on-error: true\n", 1)),
        ("guard reads a secret", text.replace("RUN_ATTEMPT: ${{ github.run_attempt }}",
                                              "RUN_ATTEMPT: ${{ github.run_attempt }}\n"
                                              "          KEY: ${{ secrets.BRIGLIA_CLI_SIGNING_KEY }}", 1)),
        ("signing key in job-level env", text.replace("    environment: release-sign\n",
                                                      "    environment: release-sign\n    env:\n"
                                                      "      K: ${{ secrets.BRIGLIA_CLI_SIGNING_KEY }}\n", 1)),
        ("environment removed", text.replace("    environment: release-sign\n", "", 1)),
    ]
    print("— deliberate breaks (each must be rejected) —")
    caught = 0
    for label, mutated in breaks:
        if mutated == text:
            check(f"break '{label}' applied", False, "mutation did not change the workflow")
            continue
        found = guard_errors(mutated) + (execution_errors(mutated) if not guard_errors(mutated) else [])
        if found:
            caught += 1
        check(f"break rejected: {label}", bool(found))
    print(f"  {caught}/{len(breaks)} deliberate breaks caught")

    print()
    if FAILED:
        print(f"{FAILED} FAILED, {PASSED} passed")
        return 1
    print(f"ALL {PASSED} SIGN-ATTEMPT-GUARD CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
