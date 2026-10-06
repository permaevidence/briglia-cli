#!/usr/bin/env python3
"""Background archiving: prove inline mode is today's archive, against real v0.2.49.

Builds two disposable trees — the pinned v0.2.49 source and the candidate
(HEAD plus any working-tree diff) — each with the same appended driver
(scripts/fixtures/background-archive), then runs one archive turn and one
following turn against a loopback server with fixed inputs:

  E1  /archiveinline on (candidate) vs v0.2.49: every request body (parsed
      JSON, normalized for random ids and clock times), every channel text,
      the final history and the archive chunks are equal.
  E2  candidate background vs candidate inline, same inputs: every
      archive-lane request (chunk summary, fact extraction) is equal and in
      the same order; the archive turn's main request intentionally still
      carries the batch in background mode and not in inline mode.
  M   (reported, not pass/fail) time to the archive turn's reply with a slow
      summary (5 s), background vs inline, on a concurrent and on a
      single-slot (serial) server.

Only disposable worktrees under a temporary directory are built or run; the
runner's own checkout and the user's real Briglia are never touched. Every
run uses a scratch HOME/XDG root and a reserved binary link name (own
preference domain), which is deleted afterwards.
"""
import argparse
import base64
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = "7dadfc5a7cc368a90a14b190daeafbde76560501"   # v0.2.49
FIXTURE = ROOT / "scripts/fixtures/background-archive"
LINK = "briglia-mw-bginline"
UUID_RE = re.compile(r"\b(?!00000000-0000-4000-8000-)[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")
SHORT_ID_RE = re.compile(r"\| [0-9A-F]{8} \|")
SNAPSHOT_RE = re.compile(r"\d{4}-\d{2}-\d{2}_\d{6}Z_[0-9a-f]{32}\.txt")
ISO_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?")
TIME_RE = re.compile(r"\b\d{1,2}:\d{2}(:\d{2})?\b")
SCRATCH_RE = re.compile(r"/[^\s\"']*briglia-bginline-[^\s\"'/]*")


def run(args, cwd=ROOT, **kwargs):
    return subprocess.run(args, cwd=cwd, check=True, **kwargs)


def prepare(tree, ref, candidate):
    run(["git", "worktree", "add", "--detach", str(tree), ref])
    if candidate:
        diff = subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT)
        if diff:
            run(["git", "apply", "--binary", "-"], cwd=tree, input=diff)
        untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z", "--", "TelegramConcierge", "scripts"], cwd=ROOT)
        for raw in untracked.split(b"\0"):
            if raw:
                name = os.fsdecode(raw)
                (tree / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, tree / name, follow_symlinks=False)
    shutil.copyfile(FIXTURE / "InlineDriver.swift", tree / "TelegramConcierge/CLI/BackgroundArchiveInlineDriver.swift")
    manager = tree / "TelegramConcierge/Services/ConversationManager.swift"
    manager.write_text(manager.read_text() + (FIXTURE / "ManagerSeam.swift").read_text())
    main = tree / "TelegramConcierge/CLI/AdaMain.swift"
    text = main.read_text()
    anchor = "ArchiveFullChunkSelftest.self,"
    if text.count(anchor) != 1:
        raise RuntimeError("registration anchor moved")
    main.write_text(text.replace(anchor, anchor + " BackgroundArchiveInlineDriver.self,"))


def build(tree, scratch):
    run(["swift", "build", "-Xswiftc", "-suppress-warnings", "--scratch-path", str(scratch)], cwd=tree)
    bindir = subprocess.check_output(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"], cwd=tree, text=True).strip()
    return pathlib.Path(bindir) / "briglia"


def drive(binary, parent, mode, delay=0.0, serial=False):
    root = pathlib.Path(tempfile.mkdtemp(prefix="briglia-bginline-", dir=parent))
    home = root / "home"
    for sub in (".config", ".local/share", ".local/state", ".cache"):
        (home / sub).mkdir(parents=True)
    (root / "tmp").mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "SM_"))}
    env.update(HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
               XDG_DATA_HOME=str(home / ".local/share"), XDG_STATE_HOME=str(home / ".local/state"),
               XDG_CACHE_HOME=str(home / ".cache"), TMPDIR=str(root / "tmp") + "/",
               BRIGLIA_TELEGRAM_API_BASE="http://127.0.0.1:9/bot")
    link = root / LINK
    os.link(binary, link)
    out = root / "out.json"
    args = [str(link), "__background-archive-inline-driver", "--out", str(out), "--mode", mode, "--delay", str(delay)]
    if serial:
        args.append("--serial")
    result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
    purge_domain()
    if result.returncode:
        raise RuntimeError(f"{mode} failed:\n" + result.stdout.decode(errors="replace")[-6000:])
    return json.loads(out.read_text())


def purge_domain():
    plist = pathlib.Path.home() / "Library/Preferences" / (LINK + ".plist")
    if plist.exists():
        subprocess.run(["defaults", "delete", LINK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        plist.unlink(missing_ok=True)


def norm_text(text):
    for pattern, token in ((UUID_RE, "<uuid>"), (SHORT_ID_RE, "| <id> |"), (SNAPSHOT_RE, "<snapshot>"),
                           (ISO_RE, "<iso>"), (SCRATCH_RE, "<scratch>"), (TIME_RE, "<time>")):
        text = pattern.sub(token, text)
    return text


def norm_body(b64):
    body = json.loads(base64.b64decode(b64))
    return norm_text(json.dumps(body, sort_keys=True))


def history(data, ignore_accounting=False):
    """The final conversation; messages created during the run (random ids,
    clock timestamps and measured token counts) keep every other field.
    `ignore_accounting` also drops measured token counts everywhere: they
    follow the provider's reported prompt sizes, which differ by design
    between modes (the batch stays in the prompt while archiving runs)."""
    raw = json.loads(base64.b64decode(data["history_base64"]) or b"[]")
    for message in raw:
        if ignore_accounting:
            message.pop("measuredTokens", None)
            message.pop("measuredToolTokens", None)
        if not str(message.get("id", "")).upper().startswith("00000000-0000-4000-8000-"):
            for key in ("timestamp", "measuredTokens", "measuredToolTokens"):
                message.pop(key, None)
    return norm_text(json.dumps(raw, sort_keys=True, indent=1))


def first_difference(a, b):
    for n, (x, y) in enumerate(zip(a.splitlines(), b.splitlines())):
        if x != y:
            return f"line {n}: {x.strip()[:300]!r} != {y.strip()[:300]!r}"
    return f"lengths {len(a.splitlines())} vs {len(b.splitlines())}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--base-binary")
    parser.add_argument("--candidate-binary")
    args = parser.parse_args()
    work = pathlib.Path(tempfile.mkdtemp(prefix="briglia-bginline-run-"))
    trees, failures = [], []

    def check(label, ok, detail=""):
        print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + str(detail)[:1500]))
        if not ok:
            failures.append(label)

    try:
        binaries = {}
        for name, ref, candidate, given in (("base", BASE, False, args.base_binary), ("candidate", "HEAD", True, args.candidate_binary)):
            if given:
                binaries[name] = pathlib.Path(given)
                continue
            tree = work / name
            prepare(tree, ref, candidate)
            trees.append(tree)
            binaries[name] = build(tree, work / f"build-{name}")
        base = drive(binaries["base"], work, "inline")
        inline = drive(binaries["candidate"], work, "inline")
        background = drive(binaries["candidate"], work, "background")

        b_req = [norm_body(r["body_base64"]) for r in base["requests"]]
        i_req = [norm_body(r["body_base64"]) for r in inline["requests"]]
        first = next((n for n, (x, y) in enumerate(zip(b_req, i_req)) if x != y), None)
        check("E1 inline mode: every request body equals v0.2.49's, in order",
              len(b_req) == len(i_req) and first is None, f"{len(b_req)} vs {len(i_req)} requests; first difference #{first}")
        check("E1 inline mode: the same channel texts (incl. the 🧠 notice)",
              [norm_text(t) for t in base["notices"]] == [norm_text(t) for t in inline["notices"]],
              (base["notices"], inline["notices"]))
        check("E1 inline mode: the same final history", history(base) == history(inline), first_difference(history(base), history(inline)))
        check("E1 inline mode: the same archive chunks", base["chunks"] == inline["chunks"], (base["chunks"], inline["chunks"]))

        lane = lambda d: [norm_body(r["body_base64"]) for r in d["requests"] if not r["main"]]
        check("E2 background vs inline: the archive-lane requests (summary, extraction) are equal and in the same order",
              lane(inline) == lane(background) and len(lane(inline)) >= 2, f"{len(lane(inline))} vs {len(lane(background))}")
        mains = lambda d: [json.loads(base64.b64decode(r["body_base64"])) for r in d["requests"] if r["main"]]
        carries = lambda body: "end of old-0." in json.dumps(body)
        check("E2 the archive turn's main request carries the batch only in background mode (by design)",
              carries(mains(background)[0]) and not carries(mains(inline)[0]))
        check("E2 the following turn's main request no longer carries the batch in either mode",
              not carries(mains(background)[-1]) and not carries(mains(inline)[-1]))
        check("E2 background mode sends no 🧠 notice", not any(t.startswith("🧠") for t in background["notices"]), background["notices"])
        check("E2 both modes end with the same chunks and the same history (token accounting aside)",
              inline["chunks"] == background["chunks"] and history(inline, True) == history(background, True),
              (inline["chunks"] == background["chunks"], first_difference(history(inline, True), history(background, True))))

        print("\nM (reported) time to the archive turn's reply with a 5 s summary:")
        for serial in (False, True):
            for mode in ("inline", "background"):
                data = drive(binaries["candidate"], work, mode, delay=5.0, serial=serial)
                reqs = len(data["requests"])
                print(f"  {'single-slot' if serial else 'concurrent '} {mode:10s}: reply after {data['turns'][0]['first_reply_seconds']:.2f}s,"
                      f" turn idle after {data['turns'][0]['idle_seconds']:.2f}s, {reqs} requests in two turns")
    finally:
        if not args.keep:
            for tree in trees:
                subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=ROOT,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(work, ignore_errors=True)
        purge_domain()
    print(f"\nBackground archive inline equivalence: {'PASS' if not failures else 'FAIL ' + str(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
