#!/usr/bin/env python3
"""Headless end-to-end run of `briglia menu` (the real binary and server)
against a mock provider server: the link in the terminal, the token →
cookie exchange, the page and its assets, the page state, saving the name,
Telegram token → automatic chat detection (getUpdates) → confirmation,
Serper/Jina keys checked and saved in one call each, Italian switching,
secrets never in any reply, then closing the page (the process exits, the
settings are in secrets.json with owner-only permissions, and a second run
opens straight on the saved state).

ChatGPT sign-in is covered offline by `__menu-selftest` (it needs a real
account); the dev quick-setup stubs stand in for the toolchain.

Usage: menu_headless_test.py /path/to/briglia
"""
import http.client
import http.server
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

BRIGLIA = os.path.abspath(sys.argv[1])
FAILS = 0
GOOD = {
    "serper": "srp-goodkey-0123456789abcdef00",
    "jina": "jina_goodkey_0123456789abcdef00",
    "telegram": "123456789:AAgoodtoken0123456789abcdef",
}
CHAT_ID = 5551234567


def check(label, ok, detail=""):
    global FAILS
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + str(detail)[:600]))
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

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        if self.path.startswith("/jina/"):
            return self._send(200 if GOOD["jina"] in auth else 401, {"ok": True})
        m = re.match(r"/telegram/bot([^/]+)/(getMe|getChat|getUpdates)", self.path)
        if m:
            token, method = m.group(1), m.group(2)
            if token != GOOD["telegram"]:
                return self._send(401, {"ok": False, "description": "Unauthorized"})
            if method == "getMe":
                return self._send(200, {"ok": True, "result": {"username": "sofia_test_bot"}})
            if method == "getUpdates":
                msg = {"update_id": 7, "message": {"date": int(time.time()), "chat": {"id": CHAT_ID, "type": "private"},
                       "from": {"id": CHAT_ID, "is_bot": False, "first_name": "Sofia", "username": "sofia"}}}
                return self._send(200, {"ok": True, "result": [msg]})
            if str(CHAT_ID) in self.path:
                return self._send(200, {"ok": True, "result": {"type": "private", "first_name": "Sofia", "username": "sofia"}})
            return self._send(400, {"ok": False, "description": "Bad Request: chat not found"})
        return self._send(404, {})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        if self.path.startswith("/serper/"):
            return self._send(200 if self.headers.get("X-API-KEY") == GOOD["serper"] else 401, {"organic": []})
        return self._send(404, {})

    def log_message(self, *a):
        pass


class Run:
    def __init__(self, env):
        self.proc = subprocess.Popen([BRIGLIA, "menu"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.chunks = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            ch = self.proc.stdout.read(1)
            if not ch:
                break
            self.chunks.append(ch)

    def out(self):
        return "".join(self.chunks)

    def wait_for(self, pattern, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            m = re.search(pattern, self.out())
            if m:
                return m
            if self.proc.poll() is not None:
                break
            time.sleep(0.1)
        return None


class Client:
    def __init__(self, port):
        self.port = port
        self.cookie = None

    def raw(self, method, path, body=None, headers=None, origin=True):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        h = {"Host": "127.0.0.1:%d" % self.port}
        if self.cookie:
            h["Cookie"] = "bqs=" + self.cookie
        if method == "POST":
            h["Content-Type"] = "application/json"
            h["X-Briglia-Quick-Setup"] = "1"
            if origin:
                h["Origin"] = "http://127.0.0.1:%d" % self.port
        h.update(headers or {})
        c.request(method, path, body=json.dumps(body) if body is not None else None, headers=h)
        r = c.getresponse()
        data = r.read()
        hdrs = dict(r.getheaders())
        c.close()
        return r.status, hdrs, data

    def act(self, action, **kw):
        kw["action"] = action
        s, _, d = self.raw("POST", "/api/menu", kw)
        return s, json.loads(d or b"{}")

    def status(self):
        s, _, d = self.raw("GET", "/api/menu/status")
        return json.loads(d) if s == 200 else {}


def main():
    home = tempfile.mkdtemp(prefix="briglia-menu-")
    env = dict(os.environ)
    env.update({
        "HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
        "TMPDIR": home + "/tmp/", "BRIGLIA_IGNORE_LEGACY_SETUP_FLAG": "1",
        "BRIGLIA_DEV_QUICKSETUP_STUBS": "1", "BRIGLIA_QUICKSETUP_NO_BROWSER": "1", "LANG": "en_US.UTF-8",
    })
    env.pop("LC_ALL", None)
    os.makedirs(home + "/tmp", exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env["BRIGLIA_DEV_PROBE_BASE"] = "http://127.0.0.1:%d" % server.server_address[1]
    run = Run(env)
    try:
        m = run.wait_for(r"http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})")
        check("the terminal shows a single-use link", m is not None, run.out())
        if not m:
            return
        port, token = int(m.group(1)), m.group(2)
        cl = Client(port)
        s, h, _ = cl.raw("GET", "/")
        check("the page needs the link (no cookie → 404)", s == 404)
        s, h, _ = cl.raw("GET", "/start?t=" + token)
        cookie = re.search(r"bqs=([0-9a-f]+)", h.get("Set-Cookie", ""))
        check("the link gives an HttpOnly session cookie", s == 303 and cookie is not None and "HttpOnly" in h.get("Set-Cookie", ""))
        cl.cookie = cookie.group(1)
        s, h, body = cl.raw("GET", "/")
        check("the menu page is served", s == 200 and b"menu.js" in body and "default-src 'none'" in h.get("Content-Security-Policy", ""))
        for asset in ["/menu.js", "/menu.css"]:
            s, _, _ = cl.raw("GET", asset)
            check("asset %s is served" % asset, s == 200)
        st = cl.status()
        check("the page state lists the 9 steps, nothing done", len(st.get("steps", [])) == 9 and not any(x["done"] for x in st["steps"] if x["id"] not in ("computer", "tools")))
        s, _, _ = cl.raw("POST", "/api/menu", {"action": "name", "name": "Evil"}, origin=False)
        check("a POST without the page's origin is refused", s == 403)

        s, j = cl.act("lang", lang="en")
        check("the page starts in a supported language and switches to English", st.get("lang") in ("en", "it") and j.get("status", {}).get("lang") == "en")
        s, j = cl.act("name", name="Sofia")
        check("the name is saved", j.get("ok") and j.get("message") == "Nice to meet you, Sofia!")
        s, j = cl.act("telegram_token", token="123456789:AAwrongtoken")
        check("a wrong bot token is refused", not j.get("ok"))
        s, j = cl.act("telegram_token", token=GOOD["telegram"])
        pending = j.get("status", {}).get("telegram", {}).get("pending") or {}
        check("a good token waits for the user's message", j.get("ok") and pending.get("bot") == "sofia_test_bot")
        found = None
        for _ in range(40):
            p = cl.status().get("telegram", {}).get("pending") or {}
            if p.get("state") == "found":
                found = p
                break
            time.sleep(0.25)
        check("the user's message is detected by polling", found and found.get("chat_id") == str(CHAT_ID) and found.get("name") == "Sofia (@sofia)", found)
        s, j = cl.act("telegram_confirm", chat_id=str(CHAT_ID))
        check("confirming connects Telegram", j.get("ok") and j["status"]["telegram"]["configured"])
        s, j = cl.act("key", kind="serper", key="srp-wrong-000000000000000000")
        check("a wrong Serper key is refused in plain words", not j.get("ok") and "Serper refused this key" in j.get("message", ""))
        s, j = cl.act("key", kind="serper", key=GOOD["serper"])
        check("a good Serper key is checked and saved in one call", j.get("ok") and j.get("message") == "Web search is on.")
        s, j = cl.act("lang", lang="it")
        s, j = cl.act("key", kind="jina", key="jina_wrong_0000000000000000")
        check("messages follow the Italian switch", "Jina ha rifiutato questa chiave" in j.get("message", ""), j.get("message"))
        s, j = cl.act("key", kind="jina", key=GOOD["jina"])
        check("a good Jina key is saved", j.get("ok"))
        check("step titles are Italian after the switch", any(x["title"] == "Ricerca web" for x in j["status"]["steps"]))
        replies = json.dumps(j) + json.dumps(cl.status())
        check("no key or token ever appears in the page state", not any(v in replies for v in GOOD.values()))
        s, j = cl.act("finish", what="start")
        check("Start is refused while ChatGPT is not set up (named in Italian)", not j.get("ok") and "ChatGPT" in j.get("message", "") and j["message"].startswith("Prima completa"))
        s, j = cl.act("finish", what="quit")
        check("Close is accepted", j.get("ok") and j["status"]["closing"] == "quit")
        try:
            rc = run.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            rc = None
        check("the process exits by itself after the page closes", rc == 0, run.out()[-800:])
        check("the goodbye line points back to the menu", "type: briglia menu" in run.out())
        check("no key or token was printed in the terminal", not any(v in run.out() for v in GOOD.values()))

        secrets_path = home + "/.config/briglia/secrets.json"
        flat = open(secrets_path).read()
        check("secrets.json holds the saved values", all(v in flat for v in GOOD.values()) and str(CHAT_ID) in flat and "Sofia" in flat)
        check("secrets.json stays owner-only", (os.stat(secrets_path).st_mode & 0o777) == 0o600, oct(os.stat(secrets_path).st_mode & 0o777))

        # A second run opens on the saved state and refuses a parallel one.
        run2 = Run(env)
        m2 = run2.wait_for(r"http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})")
        check("a second run starts", m2 is not None, run2.out())
        run3 = Run(env)
        check("a parallel menu is refused with instructions", run3.wait_for(r"already running", timeout=20) is not None, run3.out())
        run3.proc.wait(timeout=10)
        if m2:
            cl2 = Client(int(m2.group(1)))
            s, h, _ = cl2.raw("GET", "/start?t=" + m2.group(2))
            cl2.cookie = re.search(r"bqs=([0-9a-f]+)", h.get("Set-Cookie", "")).group(1)
            st = cl2.status()
            done = {x["id"] for x in st["steps"] if x["done"]}
            check("the second run shows what was saved", {"name", "telegram", "serper", "jina"} <= done, done)
            try:
                s, _, _ = cl2.raw("GET", "/api/menu/status", headers={"Cookie": "bqs=" + cl.cookie})
            except OSError:
                s = None
            check("the first run's cookie does not work on the second run", s == 404)
        run2.proc.send_signal(signal.SIGINT)
        try:
            rc2 = run2.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            rc2 = None
        check("Ctrl-C closes the menu", rc2 == 130, run2.out()[-400:])
    finally:
        for name in ("run", "run2", "run3"):
            r = locals().get(name)
            if r is not None and r.proc.poll() is None:
                r.proc.kill()
        server.shutdown()
        shutil.rmtree(home, ignore_errors=True)
    print("\nmenu headless test: " + ("all checks passed" if FAILS == 0 else "%d FAILED" % FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
