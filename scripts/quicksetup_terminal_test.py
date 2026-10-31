#!/usr/bin/env python3
"""End-to-end `briglia quicksetup` (terminal, OpenRouter only, 0.2.67) with
the real binary against a loopback mock of OpenRouter and Telegram
(BRIGLIA_DEV_PROBE_BASE), dev stubs for the system steps, and throwaway
HOME/XDG roots. Scenarios:

  1. interactive over a pipe: answers each prompt as it appears (a wrong
     OpenRouter key first), pairs through a mock /start, skips email, ends
     with Bree's greeting; secrets.json holds the name, OpenRouter on the
     1017 default pinned to Together, the Telegram chat, setup complete;
  2. `--yes` with keys only in the environment, --telegram-chat-id and
     --no-tools: no prompt, no getUpdates scan, nothing on stdin;
  3. `--yes` missing keys → exit 2 naming the variables, nothing written;
  4. a rerun after setup → "already set up", nothing changed;
  5. `--yes` with a refused key → exit 1, no provider saved.

No key ever appears in the output. Dev builds only (the seams are ignored by
release builds).

Usage: quicksetup_terminal_test.py /path/to/briglia
"""
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ADA = os.path.abspath(sys.argv[1])
FAILS = 0
OR_KEY = "sk-or-termtest-0123456789abcdef"
BAD_OR_KEY = "sk-or-wrongkey-0123456789abcdef"
TG = "123456789:AAtermtesttoken0123456789abcdef"
CHAT_ID = "5551234567"
DEFAULT_MODEL = "deepseek/deepseek-v4.1-flash-1017"
SEEN = {"paths": [], "sent": []}


def check(label, ok, detail=""):
    global FAILS
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + detail))
    if not ok:
        FAILS += 1


class Mock(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _or_ok(self):
        return OR_KEY in (self.headers.get("Authorization", "") or "")

    def do_GET(self):
        SEEN["paths"].append(self.path)
        if self.path.endswith("/endpoints"):
            return self._send(200, {"data": {"endpoints": [{"provider_name": "Novita", "tag": "novita/fp8"},
                                                           {"provider_name": "Together", "tag": "together"}]}})
        if self.path.startswith("/openrouter/"):
            return self._send(200 if self._or_ok() else 401, {"data": {"is_free_tier": False, "limit_remaining": 20}})
        m = re.match(r"/telegram/bot([^/]+)/(getMe|getChat|getUpdates)", self.path)
        if m:
            token, method = m.group(1), m.group(2)
            if token != TG:
                return self._send(401, {"ok": False, "description": "Unauthorized"})
            if method == "getMe":
                return self._send(200, {"ok": True, "result": {"username": "sofia_test_bot"}})
            if method == "getUpdates":
                return self._send(200, {"ok": True, "result": [{"update_id": 7, "message": {
                    "message_id": 1, "date": int(time.time()), "text": "/start",
                    "chat": {"id": int(CHAT_ID), "type": "private"},
                    "from": {"id": int(CHAT_ID), "is_bot": False, "first_name": "Sofia", "username": "sofia"}}}]})
            if CHAT_ID in self.path:
                return self._send(200, {"ok": True, "result": {"type": "private", "first_name": "Sofia", "username": "sofia"}})
            return self._send(400, {"ok": False, "description": "Bad Request: chat not found"})
        return self._send(404, {})

    def do_POST(self):
        SEEN["paths"].append(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path.startswith("/openrouter/"):
            return self._send(200 if self._or_ok() else 401, {"choices": [{"message": {"content": "OK"}}]})
        m = re.match(r"/telegram/bot([^/]+)/sendMessage", self.path)
        if m and m.group(1) == TG:
            SEEN["sent"].append(json.loads(body or b"{}"))
            return self._send(200, {"ok": True, "result": {"message_id": 2}})
        return self._send(404, {})

    def log_message(self, *a):
        pass


def make_env(base, home, extra=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIGLIA_", "ADA_", "SM_"))}
    env.update({"HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
                "XDG_CACHE_HOME": home + "/.cache", "TMPDIR": home + "/tmp/",
                "BRIGLIA_IGNORE_LEGACY_SETUP_FLAG": "1", "BRIGLIA_DEV_QUICKSETUP_STUBS": "1",
                "BRIGLIA_DEV_QUICKSETUP_NO_START": "1", "BRIGLIA_QUICKSETUP_NO_BROWSER": "1",
                "BRIGLIA_DEV_PROBE_BASE": base, "BRIGLIA_OPENROUTER_API_BASE": base})
    env.pop("SSH_CONNECTION", None)
    env.pop("SSH_TTY", None)
    os.makedirs(home + "/tmp", exist_ok=True)
    env.update(extra or {})
    return env


class Session:
    """The binary on a pipe; answers prompts as they appear."""

    def __init__(self, env, args):
        self.proc = subprocess.Popen([ADA, "quicksetup"] + args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.buf = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            ch = self.proc.stdout.read(1)
            if not ch:
                break
            self.buf.append(ch)

    def text(self):
        return "".join(self.buf)

    def wait_for(self, pattern, start=0, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            m = re.compile(pattern).search(self.text(), start)
            if m:
                return m
            if self.proc.poll() is not None:
                time.sleep(0.3)
                return re.compile(pattern).search(self.text(), start)
            time.sleep(0.05)
        return None

    def send(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def finish(self, timeout=120):
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        time.sleep(0.2)
        return self.proc.returncode


def store_of(home):
    p = home + "/.config/briglia/secrets.json"
    return json.load(open(p)) if os.path.exists(p) else None


def no_keys(label, out):
    check(label + ": no key in the output", all(k not in out for k in (OR_KEY, BAD_OR_KEY, TG)))


def scenario_interactive(base):
    home = tempfile.mkdtemp(prefix="briglia-qst-")
    try:
        SEEN["sent"].clear()
        s = Session(make_env(base, home), [])
        ok = True
        m = s.wait_for(r"What should Bree call you\?\n> ")
        ok &= bool(m); s.send("Sofia")
        m = s.wait_for(r"Paste your OpenRouter API key \(hidden\): ", m.end() if m else 0)
        ok &= bool(m); s.send(BAD_OR_KEY)
        m = s.wait_for(r"OpenRouter refused this key\. Paste it again, or Ctrl-C to stop\.\nPaste your OpenRouter API key \(hidden\): ", m.end() if m else 0)
        check("interactive: a wrong key gets the spec's refusal and is asked again", bool(m), s.text()[-800:])
        s.send(OR_KEY)
        m = s.wait_for(r"then paste the token here \(hidden\): ", m.end() if m else 0)
        ok &= bool(m); s.send(TG)
        m = s.wait_for(r"or press Enter to skip\. You can add it later in briglia menu\.\n> ", m.end() if m else 0, timeout=90)
        ok &= bool(m); s.send("")
        pos = m.end() if m else 0
        # macOS: the Full Disk Access prompt appears only when the terminal lacks it.
        fda = s.wait_for(r"(then press Enter here\. \(Enter without enabling it = skip|Full Disk Access granted|Media tools|media tools)", pos, timeout=60)
        if fda and fda.group(0).startswith("then press Enter"):
            s.send("")
        rc = s.finish()
        out = s.text()
        check("interactive: every prompt appeared in order", ok, out[-1500:])
        check("interactive: exit 0", rc == 0, f"rc={rc} " + out[-1500:])
        for line in ["── Briglia quick setup ──", "✔ Hi, Sofia. (Your name is also the confirm word for /deleteuserdata.)",
                     "Checking… ✔ The key works.", "hosted on Together. Change it anytime with /model or briglia menu.",
                     "✔ Web search: free with Parallel, no account.", "✔ Reading web pages: free with Jina, no key.",
                     "✔ Bot: @sofia_test_bot", "Now send /start to @sofia_test_bot in Telegram. Waiting…",
                     "✔ Paired with Sofia (@sofia). Only this account can talk to Bree.", "– Email skipped",
                     "✔ Keep awake:", "Starting Briglia…", "✓ Done! Bree has just written to you on Telegram.", "Summary:",
                     "To change anything: briglia menu (browser) or briglia setup (terminal)."]:
            check("interactive: shows " + repr(line[:60]), line in out)
        check("interactive: the removed OpenAI sentence is absent", "No OpenAI key needed" not in out)
        check("interactive: media tools installed (dev stub job)",
              ("✔ ffmpeg ✔ ImageMagick ✔ poppler ✔ LibreOffice ✔ Python" in out or "✔ media tools ✔ python3-venv" in out)
              and "stub: installing toolchain" in out, out[-1200:])
        check("interactive: Bree's first Telegram message went to the paired chat",
              len(SEEN["sent"]) == 1 and str(SEEN["sent"][0].get("chat_id")) == CHAT_ID
              and re.fullmatch(r"Hi Sofia, I'm Bree, your assistant on .+\. Ask me anything, by text or voice message\.", SEEN["sent"][0].get("text", "")) is not None,
              json.dumps(SEEN["sent"]))
        no_keys("interactive", out)
        store = store_of(home) or {}
        try:
            entry = json.loads(store.get("openrouter_providers_by_model") or "{}").get("models", {}).get(DEFAULT_MODEL)
        except ValueError:
            entry = "corrupt"
        check("interactive: saved name, OpenRouter on the 1017 default pinned to Together, chat, setup complete",
              store.get("user_name") == "Sofia" and store.get("active_provider_profile") == "openrouter"
              and store.get("openrouter_model") == DEFAULT_MODEL and (entry or {}).get("hosts") == ["together"]
              and store.get("telegram_chat_id") == CHAT_ID and store.get("cli_setup_complete") == "true"
              and not store.get("openai_transcription_api_key") and not store.get("serper_api_key"),
              json.dumps({k: store.get(k) for k in ("user_name", "active_provider_profile", "openrouter_model", "telegram_chat_id", "cli_setup_complete")}) + " " + str(entry))
        # 4. rerun on a set-up install.
        before = open(home + "/.config/briglia/secrets.json", "rb").read() if store else b""
        r = subprocess.run([ADA, "quicksetup"], env=make_env(base, home), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        check("rerun: already set up → points to briglia menu, exit 0, nothing changed",
              r.returncode == 0 and "Briglia is already set up." in r.stdout
              and open(home + "/.config/briglia/secrets.json", "rb").read() == before, r.stdout + r.stderr)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_yes(base):
    home = tempfile.mkdtemp(prefix="briglia-qsy-")
    try:
        SEEN["sent"].clear()
        before = len([p for p in SEEN["paths"] if "getUpdates" in p])
        env = make_env(base, home, {"BRIGLIA_OPENROUTER_KEY": OR_KEY, "BRIGLIA_TELEGRAM_TOKEN": TG})
        r = subprocess.run([ADA, "quicksetup", "--name", "Dev", "--yes", "--telegram-chat-id", CHAT_ID, "--no-tools"],
                           env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180)
        out = r.stdout + r.stderr
        check("--yes: exit 0 with nothing on stdin", r.returncode == 0, out[-1500:])
        check("--yes: no prompt shown", "(hidden):" not in out and "\n> " not in out and "press Enter" not in out, out[-800:])
        check("--yes: --telegram-chat-id → no getUpdates scan",
              len([p for p in SEEN["paths"] if "getUpdates" in p]) == before)
        check("--yes: tools skipped, email skipped, greeting sent",
              "– Media tools skipped (--no-tools)" in out and "– Email skipped" in out and len(SEEN["sent"]) == 1)
        no_keys("--yes", out)
        store = store_of(home) or {}
        check("--yes: setup complete without tools", store.get("cli_setup_complete") == "true" and store.get("user_name") == "Dev")
    finally:
        shutil.rmtree(home, ignore_errors=True)


def scenario_refusals(base):
    home = tempfile.mkdtemp(prefix="briglia-qsr-")
    try:
        r = subprocess.run([ADA, "quicksetup", "--yes"], env=make_env(base, home), stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=60)
        out = r.stdout + r.stderr
        check("--yes without name/keys → exit 2 naming them, nothing written",
              r.returncode == 2 and "--name" in out and "BRIGLIA_OPENROUTER_KEY" in out and "BRIGLIA_TELEGRAM_TOKEN" in out
              and store_of(home) is None, out)
        env = make_env(base, home, {"BRIGLIA_OPENROUTER_KEY": BAD_OR_KEY, "BRIGLIA_TELEGRAM_TOKEN": TG})
        r = subprocess.run([ADA, "quicksetup", "--name", "Dev", "--yes", "--telegram-chat-id", CHAT_ID],
                           env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        out = r.stdout + r.stderr
        store = store_of(home) or {}
        check("--yes with a refused key → exit 1, no provider or Telegram saved",
              r.returncode == 1 and "✖ OpenRouter refused this key." in out and not store.get("openrouter_api_key")
              and not store.get("telegram_bot_token") and store.get("cli_setup_complete") != "true", out[-800:])
        no_keys("refused key", out)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % server.server_address[1]
    try:
        scenario_interactive(base)
        scenario_yes(base)
        scenario_refusals(base)
    finally:
        server.shutdown()
    print("\nquicksetup terminal test: " + ("all passed" if FAILS == 0 else f"{FAILS} FAILED"))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
