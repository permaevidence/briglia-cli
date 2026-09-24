#!/usr/bin/env python3
"""Browser automation for `briglia quicksetup` (plan §8.10): Playwright
Chromium drives the real page served by the real binary, against the same
mock provider server and dev stubs as the headless test.

Covers: the full happy path with no Verify click (keys are checked
automatically after a pause or when a field is left, never mid-typing); a
wrong key marks only its row; editing after verification returns the row to
unverified and disables Save until the automatic re-check passes; rapid edits
settle on the newest value; a refused save re-verifies by itself; reload mid-job re-attaches to the job log; the server-restart
sentence appears when the server is killed; token rotation from the terminal
invalidates the open tab; a direct fetch from the page with a tampered value
gets 409; a page on another origin cannot reach the API.

Usage: quicksetup_browser_test.py /path/to/briglia   (needs `pip install playwright`
and `python -m playwright install chromium`)
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quicksetup_headless_test import Mock, GOOD, CHAT_ID  # noqa: E402

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print("playwright is not installed: pip install playwright && python -m playwright install chromium")
    sys.exit(2)

ADA = os.path.abspath(sys.argv[1])
FAILS = 0
CLOSE_AT_FINISH = "--close-at-finish" in sys.argv[2:]


def check(label, ok, detail=""):
    global FAILS
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + detail))
    if not ok:
        FAILS += 1


class Foreign(http.server.BaseHTTPRequestHandler):
    """A page on another origin that tries to reach the quick-setup API."""
    def do_GET(self):
        body = b"<!doctype html><html><body><script>window.result='pending';fetch(window.location.hash.slice(1)+'/api/status',{credentials:'include'}).then(r=>{window.result='status:'+r.status}).catch(e=>{window.result='blocked'});</script></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def wait_text(page, selector, needle, timeout=30):
    """Poll from Python: the page's CSP (script-src 'self') forbids the eval
    that Playwright's string predicates need — which is itself the point."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            el = page.query_selector(selector)
            if el is not None and needle in (el.text_content() or ""):
                return True
        except Exception:
            pass
        time.sleep(0.25)
    return False


def main():
    home = tempfile.mkdtemp(prefix="briglia-qsb-")
    env = dict(os.environ)
    env.update({
        "HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
        "TMPDIR": home + "/tmp/", "BRIGLIA_IGNORE_LEGACY_SETUP_FLAG": "1",
        "BRIGLIA_DEV_QUICKSETUP_STUBS": "1", "BRIGLIA_QUICKSETUP_NO_BROWSER": "1",
        "BRIGLIA_DEV_STUB_SLOW_TOOLCHAIN": "4",
        "BRIGLIA_DEV_DONE_STATUS_DELAY_MS": "1500",
    })
    os.makedirs(home + "/tmp", exist_ok=True)
    mock = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    env["BRIGLIA_DEV_PROBE_BASE"] = "http://127.0.0.1:%d" % mock.server_address[1]
    foreign = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Foreign)
    threading.Thread(target=foreign.serve_forever, daemon=True).start()

    proc = subprocess.Popen([ADA, "quicksetup"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=0)
    out = []

    def reader():
        while True:
            ch = proc.stdout.read(1)
            if not ch:
                break
            out.append(ch)
    threading.Thread(target=reader, daemon=True).start()

    def output():
        return "".join(out)

    def wait_for(pattern, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            m = re.search(pattern, output())
            if m:
                return m
            time.sleep(0.1)
        return None

    last_status = {}

    def remember_status(response):
        if response.url.endswith("/api/status") and response.status == 200:
            try:
                last_status.clear()
                last_status.update(response.json())
            except Exception:
                pass

    def sanitized(text):
        for value in GOOD.values():
            text = text.replace(value, "<test-key>")
        return re.sub(r"(?<=t=)[0-9a-f]{32}", "<launch-token>", text)

    try:
        m = wait_for(r"http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})")
        check("launch link printed", m is not None)
        if not m:
            return
        port, token = m.group(1), m.group(2)
        base = "http://127.0.0.1:%s" % port
        with sync_playwright() as pw:
            browser = pw.chromium.launch()
            page = browser.new_page()
            page.on("response", remember_status)
            page.goto(base + "/start?t=" + token)
            page.wait_for_selector("#phase-intro:not([hidden])")
            check("exchange landed on the page", page.url.rstrip("/") == base)
            verify_bodies = []

            def remember_verify(request):
                if request.url.endswith("/api/verify") and request.method == "POST":
                    try:
                        verify_bodies.append(request.post_data_json or {})
                    except Exception:
                        verify_bodies.append({})
            page.on("request", remember_verify)

            def vstate(row):
                el = page.query_selector("#vs-" + row)
                return el.get_attribute("data-state") if el else None

            def wait_state(row, want, timeout=30):
                end = time.time() + timeout
                while time.time() < end:
                    if vstate(row) == want:
                        return True
                    time.sleep(0.1)
                return False

            def save_enabled():
                return page.is_enabled("#btn-save")

            def wait_save(enabled, timeout=30):
                end = time.time() + timeout
                while time.time() < end:
                    if save_enabled() == enabled:
                        return True
                    time.sleep(0.1)
                return False

            check("no manual Verify button on the page", page.query_selector("#btn-verify") is None)
            check("Save starts disabled", not save_enabled())
            page.fill("#f-name", "Sofia Bruni")
            # A key typed character by character is not probed mid-typing.
            page.type("#f-opencode", "sk-oc-WRONG", delay=60)
            check("typing a key fires no check before a pause", len(verify_bodies) == 0, str(len(verify_bodies)))
            check("the typed row waits for the pause", vstate("opencode") == "pending", str(vstate("opencode")))
            check("the pause checks it automatically (no Verify click)", wait_state("opencode", "failed"), str(vstate("opencode")))
            check("the automatic check is a partial verify of the filled fields only",
                  len(verify_bodies) == 1 and verify_bodies[0].get("partial") is True
                  and set(verify_bodies[0]) == {"partial", "name", "opencode"}, str([sorted(b) for b in verify_bodies]))
            page.fill("#f-openai", GOOD["openai"])
            page.fill("#f-serper", GOOD["serper"])
            page.fill("#f-jina", GOOD["jina"])
            page.fill("#f-telegram_token", GOOD["telegram"])
            page.fill("#f-telegram_chat", CHAT_ID)
            check("counter reads 6 of 6 filled", page.text_content("#req-count").strip() == "6 of 6 filled")
            ok_rows = all(wait_state(r, "ok") for r in ["openai", "serper", "jina", "telegram"])
            check("wrong key marks only its row (others verified inline)", ok_rows and vstate("opencode") == "failed",
                  str({r: vstate(r) for r in ["opencode", "openai", "serper", "jina", "telegram"]}))
            check("failed row shows the reason inline", "401" in (page.text_content("#vs-opencode") or "") or len((page.text_content("#vs-opencode") or "").strip()) > 3,
                  page.text_content("#vs-opencode") or "")
            check("telegram row shows the resolved bot", "sofia_test_bot" in (page.text_content("#vs-telegram") or ""), page.text_content("#vs-telegram") or "")
            check("Save stays disabled while a row failed", not save_enabled())
            page.fill("#f-opencode", GOOD["opencode"])
            page.press("#f-opencode", "Tab")
            check("correcting the key re-checks it automatically → Save enabled", wait_save(True) and vstate("opencode") == "ok", str(vstate("opencode")))
            # Editing a verified field invalidates it at once.
            page.fill("#f-jina", "jina_wrong")
            check("editing a verified field disables Save immediately", not save_enabled() and vstate("jina") in ("pending", "running"), str(vstate("jina")))
            check("…and the edited value is checked automatically", wait_state("jina", "failed"), str(vstate("jina")))
            # Rapid edits: the newest value wins over an older in-flight check.
            page.fill("#f-jina", "jina_wrong_again")
            page.press("#f-jina", "Tab")
            page.fill("#f-jina", GOOD["jina"])
            page.press("#f-jina", "Tab")
            check("rapid edits settle on the newest value (older checks superseded)", wait_save(True) and vstate("jina") == "ok", str(vstate("jina")))
            # A slow check still in flight is superseded by a newer value: its
            # (failing) answer must never land on the page.
            n0 = len(verify_bodies)
            page.fill("#f-jina", "jina_slow_wrong")
            page.press("#f-jina", "Tab")
            check("slow check in flight shows 'checking'", wait_state("jina", "running", 5), str(vstate("jina")))
            page.fill("#f-jina", GOOD["jina"])
            page.press("#f-jina", "Tab")
            check("newer value verified while the older check was still running", wait_save(True, 10) and vstate("jina") == "ok", str(vstate("jina")))
            time.sleep(3.5)
            check("the superseded slow answer never lands (row stays verified, Save enabled)",
                  vstate("jina") == "ok" and save_enabled() and len(verify_bodies) >= n0 + 2, "%s %d" % (vstate("jina"), len(verify_bodies) - n0))
            time.sleep(1.5)
            check("no stray banner after superseded checks", page.is_hidden("#banner"), page.text_content("#banner") or "")
            check("all verified → Save enabled", save_enabled())
            # Direct fetch with a tampered value → 409.
            status = page.evaluate("""async () => {
                const body = {name: 'Sofia Bruni', opencode: {value: '%s'}, openai: {value: '%s'}, serper: {value: '%s'}, jina: {value: '%s'}, telegram: {token: '%s', chat_id: '%s'}};
                const r = await fetch('/api/save', {method: 'POST', credentials: 'same-origin', headers: {'Content-Type': 'application/json', 'X-Briglia-Quick-Setup': '1'}, body: JSON.stringify(body)});
                return r.status;
            }""" % (GOOD["opencode"] + "x", GOOD["openai"], GOOD["serper"], GOOD["jina"], GOOD["telegram"], CHAT_ID))
            check("direct fetch with a tampered value → 409", status == 409, str(status))
            partial_save = page.evaluate("""async () => (await fetch('/api/save', {method: 'POST', credentials: 'same-origin',
                headers: {'Content-Type': 'application/json', 'X-Briglia-Quick-Setup': '1'},
                body: JSON.stringify({partial: true, name: 'Sofia Bruni', openai: {value: 'x'}})})).status""")
            check("save never accepts the partial flag (400)", partial_save == 400, str(partial_save))
            # The tamper attempt dropped the server phase to intro: the page must
            # re-verify (by itself) before a save goes through.
            before = len(verify_bodies)
            end = time.time() + 45
            while time.time() < end and page.is_hidden("#phase-system"):
                if page.is_visible("#btn-save") and save_enabled():
                    page.click("#btn-save")
                time.sleep(0.3)
            check("after a refused save the page re-verifies automatically, then saves", page.is_visible("#phase-system") and len(verify_bodies) > before,
                  "verifies after tamper: %d" % (len(verify_bodies) - before))
            check("save → system phase shown", page.is_visible("#phase-system"))
            # Foreign origin cannot reach the API.
            other = browser.new_page()
            other.goto("http://127.0.0.1:%d/#%s" % (foreign.server_address[1], base))
            other.wait_for_function("window.result !== 'pending'", timeout=10000)
            result = other.evaluate("window.result")
            check("a page on another origin cannot read the API (CORS/preflight blocked)", result == "blocked" or result.startswith("status:4"), str(result))
            other.close()
            # A job runs (slow stub toolchain): reload mid-job re-attaches to the log.
            page.wait_for_selector("#job-log:not([hidden])", timeout=30000)
            page.reload()
            page.wait_for_selector("#phase-system:not([hidden])", timeout=15000)
            check("reload mid-job re-attaches to the job log", wait_text(page, "#job-log", "stub", 30))
            page.wait_for_selector("#btn-finish:not([hidden])", timeout=60000)
            check("all system rows ok → Finish shown", True)
            # Token rotation from the terminal invalidates the open tab.
            proc.stdin.write("\n")
            proc.stdin.flush()
            wait_for(r"start\?t=(?!%s)([0-9a-f]{32})" % token, 15)
            check("rotation from the terminal invalidates the open tab", wait_text(page, "#banner", "replaced", 15))
            m2 = re.findall(r"start\?t=([0-9a-f]{32})", output())
            token2 = m2[-1]
            page.goto(base + "/start?t=" + token2)
            page.wait_for_selector("#btn-finish:not([hidden])", timeout=15000)
            finish_started = time.monotonic()
            if CLOSE_AT_FINISH:
                # Stop all status polls, accept finish without the page's
                # refresh handler, and close the tab before it can see DONE.
                page.route("**/api/status", lambda route: route.abort())
                accepted = page.evaluate("""async () => (await fetch('/api/finish', {
                    method: 'POST', headers: {'Content-Type': 'application/json',
                    'X-Briglia-Quick-Setup': '1'}, body: '{}'})).status""")
                check("finish accepted before tab closes", accepted == 202)
                page.close()
            else:
                page.click("#btn-finish")
                page.wait_for_selector("#phase-done:not([hidden])", timeout=60000)
                check("delayed finish → Done", time.monotonic() - finish_started >= 1.5)
            if sys.platform == "darwin":
                wait_for(r"Start Briglia now\?", 20)
                proc.stdin.write("n\n")
                proc.stdin.flush()
            for _ in range(150):
                if proc.poll() is not None:
                    break
                time.sleep(0.1)
            check("process exited 0", proc.returncode == 0, str(proc.returncode))
            if CLOSE_AT_FINISH:
                check("closed tab cannot keep CLI alive", time.monotonic() - finish_started < 15)
            # A finished page stops polling by design; the "terminal was
            # restarted" sentence is for a server lost MID-RUN: second session
            # on a fresh home, killed while the page is open.
            home2 = tempfile.mkdtemp(prefix="briglia-qsb2-")
            env2 = dict(env)
            env2.update({"HOME": home2, "XDG_CONFIG_HOME": home2 + "/.config", "XDG_DATA_HOME": home2 + "/.local/share", "TMPDIR": home2 + "/tmp/"})
            os.makedirs(home2 + "/tmp", exist_ok=True)
            proc2 = subprocess.Popen([ADA, "quicksetup"], env=env2, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=0)
            out2 = ""
            end = time.time() + 30
            while time.time() < end and not re.search(r"start\?t=([0-9a-f]{32})", out2):
                out2 += proc2.stdout.read(1) or ""
            m3 = re.search(r"http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})", out2)
            check("second session printed a link", m3 is not None)
            if m3:
                page2 = browser.new_page()
                page2.goto("http://127.0.0.1:%s/start?t=%s" % (m3.group(1), m3.group(2)))
                page2.wait_for_selector("#phase-intro:not([hidden])")
                proc2.kill()
                proc2.wait()
                check("server killed mid-run → 'terminal was restarted' sentence", wait_text(page2, "#banner", "terminal was restarted", 25))
                page2.close()
            shutil.rmtree(home2, ignore_errors=True)
            browser.close()
        secrets = json.load(open(home + "/.config/briglia/secrets.json"))
        check("setup complete", secrets.get("cli_setup_complete") == "true")
        text = output()
        for name, value in GOOD.items():
            check("no %s key in terminal output" % name, value not in text)
    except Exception:
        print("LAST STATUS: " + sanitized(json.dumps(last_status, sort_keys=True)))
        print("CLI OUTPUT:\n" + sanitized(output()))
        raise
    finally:
        if proc.poll() is None:
            proc.kill()
        mock.shutdown()
        foreign.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    main()
    print("\nquicksetup browser: %s" % ("all checks passed" if FAILS == 0 else "%d FAILED" % FAILS))
    sys.exit(1 if FAILS else 0)
