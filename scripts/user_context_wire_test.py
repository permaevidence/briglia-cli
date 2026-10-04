#!/usr/bin/env python3
"""User-profile maintenance: prove what did NOT change, against real v0.2.48.

Builds two disposable trees — the pinned v0.2.48 source and the candidate
(HEAD plus any working-tree diff) — each with the same appended driver
(scripts/fixtures/user-context), then:

  W2/W4  every archive request other than the profile rewrite/maintenance
         (chunk and consolidation summaries, meta-summary, fact extraction
         fresh and from the backlog) is equal between the two builds, in the
         same order, on Chat Completions and on Responses. Bodies are
         compared as parsed JSON (Swift's JSONEncoder does not fix object key
         order, so even v0.2.48's own bodies are not byte-stable).
  W3     default (non-budgeted) paths keep their retry behaviour.
  U14-16 downgrade to the real v0.2.48 binary on the same roots and back:
         the state and retired files survive v0.2.48's archive cleanup paths
         and Mind import/export untouched; the re-upgraded build ignores and
         removes the old flag and appends to the retired file.

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
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = "418472c5c2159a1f1ea4f663263cd3996be017be"
FIXTURE = ROOT / "scripts/fixtures/user-context"
LINK = "briglia-mw-ucwire"


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
    shutil.copyfile(FIXTURE / "WireDriver.swift", tree / "TelegramConcierge/CLI/UserContextWireDriver.swift")
    archive = tree / "TelegramConcierge/Services/ConversationArchiveService.swift"
    archive.write_text(archive.read_text() + (FIXTURE / "ArchiveSeam.swift").read_text())
    main = tree / "TelegramConcierge/CLI/AdaMain.swift"
    text = main.read_text()
    anchor = "ArchiveFullChunkSelftest.self,"
    if text.count(anchor) != 1:
        raise RuntimeError("registration anchor moved")
    main.write_text(text.replace(anchor, anchor + " UserContextWireDriver.self,"))


def build(tree, scratch):
    run(["swift", "build", "-Xswiftc", "-suppress-warnings", "--scratch-path", str(scratch)], cwd=tree)
    bindir = subprocess.check_output(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"], cwd=tree, text=True).strip()
    return pathlib.Path(bindir) / "briglia"


class Home:
    def __init__(self, parent):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="briglia-ucwire-", dir=parent))
        self.home = self.root / "home"
        for sub in (".config", ".local/share", ".local/state", ".cache"):
            (self.home / sub).mkdir(parents=True)
        (self.root / "tmp").mkdir()

    def env(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "SM_"))}
        home = str(self.home)
        env.update(HOME=home, CFFIXED_USER_HOME=home, XDG_CONFIG_HOME=home + "/.config",
                   XDG_DATA_HOME=home + "/.local/share", XDG_STATE_HOME=home + "/.local/state",
                   XDG_CACHE_HOME=home + "/.cache", TMPDIR=str(self.root / "tmp") + "/")
        return env

    def drive(self, binary, mode, protocol="chat", file=None):
        link = self.root / LINK
        if link.exists():
            link.unlink()
        os.link(binary, link)
        out = self.root / f"{mode}-{protocol}.json"
        args = [str(link), "__user-context-wire-driver", "--mode", mode, "--wire-protocol", protocol, "--out", str(out)]
        if file:
            args += ["--file", str(file)]
        result = subprocess.run(args, env=self.env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
        if result.returncode:
            raise RuntimeError(f"{mode} failed:\n" + result.stdout.decode(errors="replace")[-6000:])
        return json.loads(out.read_text())


def purge_domain():
    plist = pathlib.Path.home() / "Library/Preferences" / (LINK + ".plist")
    if plist.exists():
        subprocess.run(["defaults", "delete", LINK], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        plist.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--base-binary")
    parser.add_argument("--candidate-binary")
    args = parser.parse_args()
    work = pathlib.Path(tempfile.mkdtemp(prefix="briglia-ucwire-run-"))
    trees = []
    failures = []

    def check(label, ok, detail=""):
        print(("PASS " if ok else "FAIL ") + label + ("" if ok or not detail else " — " + str(detail)[:1500]), flush=True)
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
            binaries[name] = build(tree, work / ("build-" + name))
            print(f"built {name}: {binaries[name]}", flush=True)

        # W2/W4/W3 on both protocols.
        for protocol in ("chat", "responses"):
            got = {}
            for name in ("base", "candidate"):
                home = Home(work)
                got[name] = home.drive(binaries[name], "capture", protocol)
            def kept(reqs, drop):
                return [(r["path"], r["kind"], r["body"]) for r in reqs if r["kind"] not in drop]
            base_reqs = kept(got["base"]["requests"], {"rewrite"})
            cand_reqs = kept(got["candidate"]["requests"], {"maintenance"})
            kinds = [k for _, k, _ in base_reqs]
            check(f"W2/W4 {protocol}: summary, consolidation, meta and extraction requests equal to v0.2.48, same order "
                  f"({len(base_reqs)} requests: {kinds.count('extraction')} extraction incl. backlog)",
                  base_reqs == cand_reqs and kinds.count("extraction") >= 3 and kinds.count("summary") >= 7,
                  [k for k in kinds] if base_reqs != cand_reqs else "")
            if base_reqs != cand_reqs:
                for i, (a, b) in enumerate(zip(base_reqs, cand_reqs)):
                    if a != b:
                        print("  first difference at", i, a[1], "\n  base:", a[2][:800], "\n  cand:", b[2][:800])
                        break
            check(f"W4 {protocol}: v0.2.48 made a full-profile rewrite request at consolidation; the candidate made none",
                  any(r["kind"] == "rewrite" for r in got["base"]["requests"])
                  and not any(r["kind"] in ("rewrite", "maintenance") for r in got["candidate"]["requests"]))
            check(f"W3 {protocol}: default-path retry behaviour unchanged ({got['base']['retryProbeSends']} sends)",
                  got["base"]["retryProbeSends"] == got["candidate"]["retryProbeSends"] == 3)
            check(f"W4 {protocol}: the resulting profiles are identical", got["base"]["profile"] == got["candidate"]["profile"])

        # U14-U16: same roots, same preference domain, real v0.2.48 in between.
        home = Home(work)
        up = home.drive(binaries["candidate"], "upgrade-step")
        check("U16 setup: the candidate's maintenance created the state and retired files",
              up["state"] is not None and up["retired"] is not None and any(r["kind"] == "maintenance" for r in up["requests"]))
        down = home.drive(binaries["base"], "downgrade-step")
        check("U15 v0.2.48 on the same roots leaves the state and retired files byte-identical (archive cleanup, startup recovery)",
              down["state"] == up["state"] and down["retired"] == up["retired"])
        check("U15 v0.2.48 brings back its own flag and full rewrite (expected, documented)",
              down["flag"] in ("1", "true") or any(r["kind"] == "rewrite" for r in down["requests"]))
        check("U15 v0.2.48 extraction still appends to the maintained profile", (down["profile"] or "").endswith("Learned in downgrade-step"))
        again = home.drive(binaries["candidate"], "reupgrade-step")
        before = base64.b64decode(up["retired"]["base64"])
        after = base64.b64decode(again["retired"]["base64"]) if again["retired"] else b""
        check("U16 re-upgrade: the old flag is ignored and removed; no rewrite request", again["flag"] is None
              and not any(r["kind"] == "rewrite" for r in again["requests"]))
        check("U16 re-upgrade: the retired file is only ever appended (old bytes are its prefix)", after.startswith(before))

        # U14: a new-format Mind into v0.2.48 and back.
        mind = work / "u14.mind"
        exporter = Home(work)
        exporter.drive(binaries["candidate"], "upgrade-step")
        exported = exporter.drive(binaries["candidate"], "mind-export", file=mind)
        old = Home(work)
        imported = old.drive(binaries["base"], "mind-import", file=mind)
        check("U14 v0.2.48 imports a new-format Mind with the state and retired files intact",
              imported["state"] == exported["state"] and imported["retired"] == exported["retired"])
        mind2 = work / "u14-back.mind"
        old.drive(binaries["base"], "mind-export", file=mind2)
        back = Home(work)
        reimported = back.drive(binaries["candidate"], "mind-import", file=mind2)
        check("U14 v0.2.48 re-exports them intact (candidate re-import byte-identical)",
              reimported["state"] == exported["state"] and reimported["retired"] == exported["retired"])
    finally:
        purge_domain()
        if not args.keep:
            for tree in trees:
                subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=ROOT, check=False)
            shutil.rmtree(work, ignore_errors=True)
        else:
            print("kept", work)
    print("User-context wire/downgrade test:", "PASS" if not failures else f"FAIL ({len(failures)})")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
