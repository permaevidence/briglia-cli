#!/usr/bin/env python3
"""Headless end-to-end run of `briglia quicksetup` against a mock provider
server (plan §8, smoke). Drives the JSON API exactly like the page does:
token exchange → status → verify (one wrong key, then corrected) → save →
system rows (dev stubs) → finish → done. Also proves: Enter rotates the
authorization (old cookie 404), the launch token appears exactly once in the
terminal output, no key appears anywhere in stdout/stderr, and secrets.json
holds the verified values with setup marked complete.

Usage: quicksetup_headless_test.py /path/to/briglia
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

ADA = os.path.abspath(sys.argv[1])
FAILS = 0


def check(label, ok, detail=""):
    global FAILS
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + detail))
    if not ok:
        FAILS += 1


GOOD = {
    "opencode": "sk-oc-goodkey-0123456789abcdef",
    "openai": "sk-oa-goodkey-0123456789abcdef",
    "serper": "srp-goodkey-0123456789abcdef00",
    "jina": "jina_goodkey_0123456789abcdef00",
    "telegram": "123456789:AAgoodtoken0123456789abcdef",
    "agentmail": "am_goodkey_0123456789abcdef0000",
}
CHAT_ID = "5551234567"
SEEN = {"paths": []}


class Mock(http.server.BaseHTTPRequestHandler):
    def _auth_ok(self, service):
        auth = self.headers.get("Authorization", "") or self.headers.get("X-API-KEY", "")
        return GOOD[service] in auth

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        SEEN["paths"].append(self.path)
        if self.path.startswith("/openai/"):
            return self._send(200 if self._auth_ok("openai") else 401, {"data": []})
        if self.path.startswith("/jina/"):
            return self._send(200 if self._auth_ok("jina") else 401, {"ok": True})
        if self.path.startswith("/agentmail/"):
            return self._send(200 if self._auth_ok("agentmail") else 401, {"inboxes": [{"inbox_id": "bree@agentmail.to"}]})
        m = re.match(r"/telegram/bot([^/]+)/(getMe|getChat)", self.path)
        if m:
            token, method = m.group(1), m.group(2)
            if token != GOOD["telegram"]:
                return self._send(401, {"ok": False, "description": "Unauthorized"})
            if method == "getMe":
                return self._send(200, {"ok": True, "result": {"username": "sofia_test_bot"}})
            if CHAT_ID in self.path:
                return self._send(200, {"ok": True, "result": {"type": "private", "first_name": "Sofia", "username": "sofia"}})
            return self._send(400, {"ok": False, "description": "Bad Request: chat not found"})
        return self._send(404, {})

    def do_POST(self):
        SEEN["paths"].append(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        if self.path.startswith("/opencode/"):
            return self._send(200 if self._auth_ok("opencode") else 401, {"choices": [{"message": {"content": "OK"}}]})
        if self.path.startswith("/openrouter/"):
            return self._send(401, {"error": "no"})
        if self.path.startswith("/serper/"):
            return self._send(200 if self._auth_ok("serper") else 401, {"organic": []})
        return self._send(404, {})

    def log_message(self, *a):
        pass


def main():
    home = tempfile.mkdtemp(prefix="briglia-qs-")
    env = dict(os.environ)
    env.update({
        "HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
        "TMPDIR": home + "/tmp/", "BRIGLIA_IGNORE_LEGACY_SETUP_FLAG": "1",
        "BRIGLIA_DEV_QUICKSETUP_STUBS": "1", "BRIGLIA_QUICKSETUP_NO_BROWSER": "1",
    })
    os.makedirs(home + "/tmp", exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env["BRIGLIA_DEV_PROBE_BASE"] = "http://127.0.0.1:%d" % server.server_address[1]

    proc = subprocess.Popen([ADA, "quicksetup"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1)
    out_lines = []

    def reader():
        # Byte-wise: prompts end without a newline ("Start Briglia now? [Y/n] ").
        while True:
            ch = proc.stdout.read(1)
            if not ch:
                break
            out_lines.append(ch)
    threading.Thread(target=reader, daemon=True).start()

    def output():
        return "".join(out_lines)

    def wait_for(pattern, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            m = re.search(pattern, output())
            if m:
                return m
            if proc.poll() is not None:
                break
            time.sleep(0.1)
        return None

    try:
        m = wait_for(r"http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})")
        check("quicksetup printed a launch link", m is not None, output()[-800:])
        if not m:
            return
        port, token = m.group(1), m.group(2)
        base = "http://127.0.0.1:%s" % port

        def raw(method, path, body=None, cookie=None, headers=None, origin=True):
            conn = http.client.HTTPConnection("127.0.0.1", int(port), timeout=60)
            hdrs = {"Host": "127.0.0.1:%s" % port}
            data = None
            if method == "POST":
                if origin:
                    hdrs["Origin"] = "http://127.0.0.1:%s" % port
                hdrs["Content-Type"] = "application/json"
                hdrs["X-Briglia-Quick-Setup"] = "1"
                data = json.dumps(body or {}).encode()
            if cookie:
                hdrs["Cookie"] = "bqs=" + cookie
            for k, v in (headers or {}).items():
                hdrs[k] = v
            conn.request(method, path, body=data, headers=hdrs)
            resp = conn.getresponse()
            payload = resp.read()
            conn.close()
            return resp, payload

        def call(method, path, body=None, cookie=None, headers=None):
            resp, payload = raw(method, path, body, cookie, headers)
            try:
                js = json.loads(payload) if payload else {}
            except Exception:
                js = {}
            return resp.status, js

        def exchange(tok):
            resp, _ = raw("GET", "/start?t=" + tok)
            sc = resp.getheader("Set-Cookie") or ""
            m = re.search(r"bqs=([0-9a-f]{32})", sc)
            return resp.status, (m.group(1) if m else None), sc

        # 1. Exchange.
        status, cookie, sc = exchange(token)
        check("token exchange → 303 + HttpOnly SameSite=Strict cookie",
              status == 303 and cookie is not None and "HttpOnly" in sc and "SameSite=Strict" in sc, "%s %s" % (status, sc))
        second, _, _ = exchange(token)
        check("second exchange → 404 (single use)", second == 404)
        st, js = call("GET", "/api/status")
        check("status without cookie → 404", st == 404)
        st, js = call("GET", "/api/status", cookie=cookie)
        check("status with cookie → 200, phase intro", st == 200 and js.get("phase") == "intro", str(js)[:200])
        st, _ = call("GET", "/api/status", cookie=cookie, headers={"Host": "localhost:%s" % port})
        check("wrong Host → 400", st == 400)
        st, _ = call("POST", "/api/verify", {}, cookie=cookie, headers={"Origin": "http://evil.example"})
        check("foreign Origin → 403", st == 403)
        resp, _ = raw("OPTIONS", "/api/verify", cookie=cookie)
        check("OPTIONS → 403 without CORS headers", resp.status == 403 and resp.getheader("Access-Control-Allow-Origin") is None)
        resp, _ = raw("GET", "/api/status", cookie=cookie)
        check("responses carry CSP / nosniff / no-store / DENY",
              (resp.getheader("Content-Security-Policy") or "").startswith("default-src 'none'")
              and resp.getheader("X-Content-Type-Options") == "nosniff" and resp.getheader("Cache-Control") == "no-store"
              and resp.getheader("X-Frame-Options") == "DENY")
        resp, _ = raw("GET", "/", cookie=cookie)
        check("page served", resp.status == 200 and "text/html" in (resp.getheader("Content-Type") or ""))

        # 2. Verify with one wrong key.
        def request(opencode=GOOD["opencode"], chat=CHAT_ID):
            return {"name": "Sofia Bruni",
                    "opencode": {"value": opencode}, "openai": {"value": GOOD["openai"]},
                    "serper": {"value": GOOD["serper"]}, "jina": {"value": GOOD["jina"]},
                    "telegram": {"token": GOOD["telegram"], "chat_id": chat},
                    "agentmail": {"value": GOOD["agentmail"]}}
        st, js = call("POST", "/api/save", request(), cookie=cookie)
        check("save before verify → 409", st == 409, str(js))
        st, js = call("POST", "/api/verify", request(opencode="sk-oc-WRONG"), cookie=cookie)
        rows = {r["id"]: r for r in js.get("rows", [])}
        check("verify: wrong OpenCode key fails only its row",
              st == 200 and rows.get("opencode", {}).get("state") == "failed"
              and all(rows[k]["state"] == "ok" for k in ["openai", "serper", "jina", "telegram", "agentmail"]), str(js)[:300])
        check("telegram row resolved bot → name", "sofia_test_bot" in rows.get("telegram", {}).get("resolved", ""), str(rows.get("telegram")))
        st, js = call("POST", "/api/verify", request(chat="999"), cookie=cookie)
        rows = {r["id"]: r for r in js.get("rows", [])}
        check("verify: chat not found carries the /start hint",
              rows.get("telegram", {}).get("state") == "failed" and "/start" in rows["telegram"].get("reason", ""), str(rows.get("telegram")))
        st, js = call("POST", "/api/verify", request(), cookie=cookie)
        check("verify: all ok → phase verified", st == 200 and js.get("phase") == "verified", str(js)[:300])
        st, js = call("POST", "/api/verify", {"name": "x", "bogus": 1}, cookie=cookie)
        check("unknown JSON field → 400", st == 400)
        # Tampered save.
        st, js = call("POST", "/api/save", request(opencode=GOOD["opencode"] + "x"), cookie=cookie)
        check("save with a value that differs from the verified one → 409 naming the field",
              st == 409 and "opencode" in js.get("fields", []), str(js))
        st, js = call("POST", "/api/verify", request(), cookie=cookie)
        check("re-verify after tamper → verified again", js.get("phase") == "verified")

        # 3. Enter → rotation; old cookie dead.
        proc.stdin.write("\n")
        proc.stdin.flush()
        m2 = wait_for(r"start\?t=(?!%s)([0-9a-f]{32})" % token, 15)
        check("Enter printed a new link", m2 is not None)
        st, _ = call("GET", "/api/status", cookie=cookie)
        check("old cookie → 404 after rotation", st == 404)
        token2 = m2.group(1)
        _, cookie, _ = exchange(token2)
        check("new token exchanges", cookie is not None)
        st, js = call("GET", "/api/status", cookie=cookie)
        check("phase still verified across rotation", js.get("phase") == "verified", str(js.get("phase")))

        # 4. Save.
        st, js = call("POST", "/api/save", request(), cookie=cookie)
        check("save → 200, phase system", st == 200 and js.get("phase") == "system", str(js)[:300])
        secrets = json.load(open(home + "/.config/briglia/secrets.json"))
        check("secrets.json holds the verified keys", secrets.get("opencode_api_key") == GOOD["opencode"]
              and secrets.get("serper_api_key") == GOOD["serper"] and secrets.get("telegram_chat_id") == CHAT_ID
              and secrets.get("email_calendar_provider") == "agentmail" and secrets.get("user_name") == "Sofia Bruni")
        check("progress marker quick:system", secrets.get("cli_setup_step_in_progress") == "quick:system")
        check("setup not complete yet", secrets.get("cli_setup_complete") != "true")

        # 5. System rows: run each in order.
        def system_rows():
            st, js = call("GET", "/api/status", cookie=cookie)
            return js
        for _ in range(60):
            js = system_rows()
            rows = js.get("system_rows", [])
            nxt = next((r for r in rows if r["state"] != "ok"), None)
            if not nxt:
                break
            if nxt["state"] == "pending":
                st, r = call("POST", "/api/system/run", {"row": nxt["id"]}, cookie=cookie)
                if st == 409 and r.get("error") == "not_next":
                    pass
            elif nxt["state"] == "failed":
                check("system row failed: " + nxt["id"], False, nxt.get("reason", ""))
                break
            time.sleep(0.5)
        js = system_rows()
        check("all system rows ok → phase systemComplete",
              js.get("phase") in ("systemComplete", "system-complete"), str(js.get("system_rows"))[:400])
        st, r = call("POST", "/api/system/run", {"row": "toolchain"}, cookie=cookie)
        check("system/run after completion → 409", st == 409)
        st, jl = call("POST", "/api/job", {"offset": 0}, cookie=cookie)
        check("job ring carries the stub install output", any("stub: done" in l for l in jl.get("lines", [])), str(jl)[:200])

        # 6. Finish.
        st, js = call("POST", "/api/finish", {}, cookie=cookie)
        check("finish accepted (202)", st == 202, str(js)[:200])
        done = False
        for _ in range(60):
            try:
                st, js = call("GET", "/api/status", cookie=cookie)
            except ConnectionRefusedError:
                # Linux: the server stops right after "done" and the process
                # exits; the secrets check below is the evidence.
                done = True
                break
            if st == 404 or js.get("phase") == "done":
                done = js.get("phase") == "done" if st == 200 else done
                break
            failed = [s for s in js.get("finish_steps", []) if s["state"] == "failed"]
            if failed:
                check("finish step failed: " + failed[0]["id"], False, failed[0].get("reason", ""))
                break
            time.sleep(0.5)
        check("finish reached done", done)
        # macOS: the process asks "Start Briglia now?"; answer n once it asks
        # (writing earlier would feed the Enter listener instead).
        if sys.platform == "darwin":
            asked = wait_for(r"Start Briglia now\?", 20)
            check("macOS asks to start the chat", asked is not None, "rc=%s tail=%r" % (proc.poll(), output()[-500:]))
            try:
                proc.stdin.write("n\n")
                proc.stdin.flush()
            except Exception:
                pass
        for _ in range(100):
            if proc.poll() is not None:
                break
            time.sleep(0.1)
        secrets = json.load(open(home + "/.config/briglia/secrets.json"))
        check("setup complete + progress cleared", secrets.get("cli_setup_complete") == "true"
              and "cli_setup_step_in_progress" not in secrets)
        check("process exited 0", proc.returncode == 0, "rc=%s tail=%s" % (proc.returncode, output()[-400:]))

        # 7. Secrets never leak.
        text = output()
        for name, value in GOOD.items():
            check("no %s key in terminal output" % name, value not in text)
        check("launch token appears exactly once in the output", text.count(token) == 1, str(text.count(token)))
        check("second token appears exactly once", text.count(token2) == 1, str(text.count(token2)))
        lock = home + "/.local/share/briglia/quicksetup.lock"
        check("quicksetup.lock removed at the end", not os.path.exists(lock))
        check("no job journal left", not os.path.exists(home + "/.local/share/briglia/quicksetup.job.json"))

        # 8. The completed installation now opens independent browser
        # settings. It must preserve setup/pairing and never run installers.
        before_rerun = dict(secrets)
        r2 = subprocess.Popen([ADA, "quicksetup"], env=env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, bufsize=1)
        rerun_lines = []
        def read_rerun():
            for line in r2.stdout:
                rerun_lines.append(line)
        rerun_reader = threading.Thread(target=read_rerun, daemon=True)
        rerun_reader.start()
        try:
            deadline = time.time() + 30
            match = None
            while time.time() < deadline:
                match = re.search(r"Briglia settings: http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})", "".join(rerun_lines))
                if match or r2.poll() is not None:
                    break
                time.sleep(0.05)
            check("rerun opens browser settings", match is not None, "".join(rerun_lines)[-300:])
            if match:
                rerun_port, rerun_token = match.groups()
                conn = http.client.HTTPConnection("127.0.0.1", int(rerun_port), timeout=10)
                conn.request("GET", "/start?t=" + rerun_token)
                response = conn.getresponse()
                cookie_header = response.getheader("Set-Cookie", "").split(";", 1)[0]
                response.read()
                conn.request("GET", "/api/status", headers={"Cookie": cookie_header})
                response = conn.getresponse()
                settings_status = json.loads(response.read())
                conn.close()
                check("rerun serves settings rather than installation steps", response.status == 200 and settings_status.get("mode") == "settings")
        finally:
            if r2.poll() is None:
                r2.send_signal(signal.SIGINT)
                try:
                    r2.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    r2.kill(); r2.wait()
            rerun_reader.join(timeout=2)
        check("settings rerun exits cleanly", r2.returncode == 0)
        after_rerun = json.load(open(home + "/.config/briglia/secrets.json"))
        check("settings rerun preserves keys, pairing and completion", after_rerun == before_rerun)
        check("settings rerun does not install anything", "stub: installing" not in "".join(rerun_lines))
    except Exception as e:
        check("driver raised %r" % (e,), False, "rc=%s tail=%r" % (proc.poll(), output()[-1500:]))
    finally:
        if proc.poll() is None:
            proc.kill()
        server.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
    print("\nquicksetup headless: %s" % ("all checks passed" if FAILS == 0 else "%d FAILED" % FAILS))
    sys.exit(1 if FAILS else 0)
