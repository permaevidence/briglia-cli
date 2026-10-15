#!/usr/bin/env python3
"""End-to-end `briglia quicksetup` on a FRESH install with an OpenRouter key
and no OpenCode or OpenAI key (owner 2026-10-15; Codex round 2 found the
final check still demanded an OpenCode key). Drives the real binary's JSON
API like the page: verify → save → (restart: resume at the system phase) →
system rows (dev stubs) → finish → done, then checks the completion marker,
the stored provider, model and Together host pin, the save notices, and that
a rerun opens settings without changing anything. A second run makes the
host list unreadable: setup still completes, with no pin and a notice.
Later scenarios cover existing installs: switching between OpenRouter and
OpenCode (Codex round 3), and "Keep current" on a custom endpoint, local
server, named server or the OpenAI API profile (Codex round 4), each
through to done, plus the refusals for an incomplete current provider and
a missing OpenAI key.

Loopback only (mock provider server), throwaway HOME/XDG roots.

Usage: quicksetup_openrouter_flow_test.py /path/to/briglia
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
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quicksetup_headless_test import Mock, GOOD, CHAT_ID  # noqa: E402

FAILS = 0
OR_KEY = "sk-or-flowtest-0123456789abcdef"
DEFAULT_MODEL = "deepseek/deepseek-v4.1-flash"
LISTING = {"ok": True}


def check(label, ok, detail=""):
    global FAILS
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + detail))
    if not ok:
        FAILS += 1


class ProviderMock(Mock):
    def do_GET(self):
        if self.path.endswith("/endpoints"):
            if not LISTING["ok"]:
                return self._send(503, {"error": "unavailable"})
            return self._send(200, {"data": {"endpoints": [{"provider_name": "Novita", "tag": "novita/fp8"},
                                                           {"provider_name": "Together", "tag": "together"}]}})
        if self.path.startswith("/openrouter/"):
            ok = OR_KEY in (self.headers.get("Authorization", "") or "")
            return self._send(200 if ok else 401, {"data": {"is_free_tier": False, "limit_remaining": 20}})
        return super().do_GET()

    def do_POST(self):
        if self.path.startswith("/openrouter/"):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            ok = OR_KEY in (self.headers.get("Authorization", "") or "")
            return self._send(200 if ok else 401, {"choices": [{"message": {"content": "OK"}}]})
        return super().do_POST()


class Session:
    def __init__(self, env):
        self.proc = subprocess.Popen([ADA, "quicksetup"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.out = []
        threading.Thread(target=self._read, daemon=True).start()
        self.port = self.cookie = None

    def _read(self):
        while True:
            ch = self.proc.stdout.read(1)
            if not ch:
                break
            self.out.append(ch)

    def text(self):
        return "".join(self.out)

    def wait_for(self, pattern, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            m = re.search(pattern, self.text())
            if m:
                return m
            if self.proc.poll() is not None:
                break
            time.sleep(0.05)
        return None

    def connect(self):
        m = self.wait_for(r"http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})")
        if not m:
            return False
        self.port = int(m.group(1))
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        conn.request("GET", "/start?t=" + m.group(2), headers={"Host": "127.0.0.1:%d" % self.port})
        resp = conn.getresponse()
        resp.read()
        conn.close()
        c = re.search(r"bqs=([0-9a-f]{32})", resp.getheader("Set-Cookie") or "")
        self.cookie = c.group(1) if c else None
        return self.cookie is not None

    def call(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
        hdrs = {"Host": "127.0.0.1:%d" % self.port, "Cookie": "bqs=" + self.cookie}
        data = None
        if method == "POST":
            hdrs.update({"Origin": "http://127.0.0.1:%d" % self.port, "Content-Type": "application/json", "X-Briglia-Quick-Setup": "1"})
            data = json.dumps(body or {}).encode()
        conn.request(method, path, body=data, headers=hdrs)
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        try:
            return resp.status, (json.loads(payload) if payload else {})
        except Exception:
            return resp.status, {}

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def run_system_rows(s, label):
    js = {}
    for _ in range(80):
        _, js = s.call("GET", "/api/status")
        nxt = next((r for r in js.get("system_rows", []) if r["state"] != "ok"), None)
        if not nxt:
            break
        if nxt["state"] == "pending":
            s.call("POST", "/api/system/run", {"row": nxt["id"]})
        elif nxt["state"] == "failed":
            check(label + ": system row failed: " + nxt["id"], False, nxt.get("reason", ""))
            return False
        time.sleep(0.2)
    _, js = s.call("GET", "/api/status")
    ok = js.get("phase") in ("systemComplete", "system-complete")
    check(label + ": all system rows ok → systemComplete", ok, str(js.get("system_rows"))[:300])
    return ok


def finish(s, label):
    st, js = s.call("POST", "/api/finish", {})
    check(label + ": finish accepted", st == 202, str(js)[:200])
    done, failed = False, []
    for _ in range(100):
        try:
            st, js = s.call("GET", "/api/status")
        except ConnectionRefusedError:
            done = True
            break
        if st == 404 or js.get("phase") == "done":
            done = js.get("phase") == "done" if st == 200 else done
            break
        failed = [x for x in js.get("finish_steps", []) if x["state"] == "failed"]
        if failed:
            break
        time.sleep(0.2)
    check(label + ": finish reached done (no failed step)", done and not failed,
          json.dumps(failed)[:300] if failed else "")
    if sys.platform == "darwin":
        if s.wait_for(r"Start Briglia now\?", 20):
            try:
                s.proc.stdin.write("n\n")
                s.proc.stdin.flush()
            except Exception:
                pass
    for _ in range(100):
        if s.proc.poll() is not None:
            break
        time.sleep(0.1)


def scenario(label, listing_ok, restart, with_openai=False):
    LISTING["ok"] = listing_ok
    home = tempfile.mkdtemp(prefix="briglia-qs-or-")
    os.makedirs(home + "/tmp", exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ProviderMock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % server.server_address[1]
    env = dict(os.environ)
    for k in list(env):
        if k.startswith(("BRIGLIA_", "ADA_", "SM_")):
            del env[k]
    env.update({"HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
                "XDG_CACHE_HOME": home + "/.cache", "TMPDIR": home + "/tmp/",
                "BRIGLIA_IGNORE_LEGACY_SETUP_FLAG": "1", "BRIGLIA_DEV_QUICKSETUP_STUBS": "1",
                "BRIGLIA_QUICKSETUP_NO_BROWSER": "1", "BRIGLIA_DEV_PROBE_BASE": base,
                "BRIGLIA_OPENROUTER_API_BASE": base})
    secrets_path = home + "/.config/briglia/secrets.json"
    s = Session(env)
    try:
        check(label + ": link and cookie", s.connect(), s.text()[-500:])
        req = {"name": "Offline test", "openrouter": {"value": OR_KEY}, "serper": {"value": GOOD["serper"]},
               "jina": {"value": GOOD["jina"]}, "telegram": {"token": GOOD["telegram"], "chat_id": CHAT_ID}}
        if with_openai:
            req["openai"] = {"value": GOOD["openai"]}
        st, js = s.call("POST", "/api/verify", req)
        rows = {r["id"]: r["state"] for r in js.get("rows", [])}
        check(label + ": OpenRouter form without OpenCode verifies", st == 200 and js.get("phase") == "verified"
              and rows.get("openrouter") == "ok" and "opencode" not in rows and (rows.get("openai") == "ok" if with_openai else "openai" not in rows), str(js)[:300])
        st, js = s.call("POST", "/api/save", req)
        notices = " ".join(js.get("notices", []))
        check(label + ": save → system phase", st == 200 and js.get("phase") == "system", str(js)[:300])
        if with_openai:
            check(label + ": no 'No OpenAI key' notice when the key is given", "No OpenAI key" not in notices, notices)
        else:
            check(label + ": save says voice/images/pages go through OpenRouter (no OpenAI key)", "No OpenAI key" in notices, notices)
        if listing_ok:
            check(label + ": save says it runs on Together", "runs on Together" in notices, notices)
        else:
            check(label + ": save says Together couldn't be selected and OpenRouter chooses the host",
                  "Together couldn't be selected" in notices and "OpenRouter chooses the host" in notices, notices)
        store = json.load(open(secrets_path))
        check(label + ": OpenRouter is active on DeepSeek V4.1 Flash, no OpenCode key stored" + ("" if with_openai else ", no OpenAI key"),
              store.get("active_provider_profile") == "openrouter" and store.get("openrouter_model") == DEFAULT_MODEL
              and not store.get("opencode_api_key") and bool(store.get("openai_transcription_api_key")) == with_openai, json.dumps({k: store.get(k) for k in ("active_provider_profile", "openrouter_model")}))
        check(label + ": host pin " + ("together" if listing_ok else "absent"),
              store.get("openrouter_providers") == ("together" if listing_ok else None), str(store.get("openrouter_providers")))
        if restart:
            s.stop()
            s = Session(env)
            check(label + ": restart → new link", s.connect(), s.text()[-500:])
            _, js = s.call("GET", "/api/status")
            check(label + ": restart resumes at the system phase", js.get("phase") in ("system", "systemComplete", "system-complete"), str(js.get("phase")))
        if run_system_rows(s, label):
            finish(s, label)
        store = json.load(open(secrets_path))
        check(label + ": setup complete and progress cleared", store.get("cli_setup_complete") == "true"
              and "cli_setup_step_in_progress" not in store, json.dumps({k: store.get(k) for k in ("cli_setup_complete", "cli_setup_step_in_progress")}))
        check(label + ": process exited 0", s.proc.returncode == 0, "rc=%s tail=%r" % (s.proc.returncode, s.text()[-400:]))
        check(label + ": no key in terminal output", not any(v in s.text() for v in (OR_KEY, GOOD["openai"], GOOD["serper"], GOOD["jina"], GOOD["telegram"])))
        # A rerun of a completed installation opens settings and changes nothing.
        before = dict(store)
        r2 = subprocess.Popen([ADA, "quicksetup"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, bufsize=1)
        lines = []
        threading.Thread(target=lambda: [lines.append(l) for l in r2.stdout], daemon=True).start()
        end = time.time() + 30
        while time.time() < end and not re.search(r"Briglia settings: http://127\.0\.0\.1:\d+/start", "".join(lines)) and r2.poll() is None:
            time.sleep(0.05)
        check(label + ": rerun opens browser settings", "Briglia settings:" in "".join(lines), "".join(lines)[-300:])
        if r2.poll() is None:
            r2.send_signal(signal.SIGINT)
            try:
                r2.wait(timeout=20)
            except subprocess.TimeoutExpired:
                r2.kill(); r2.wait()
        check(label + ": rerun preserves the stored setup", json.load(open(secrets_path)) == before)
    except Exception as e:
        check(label + ": driver raised %r" % (e,), False, s.text()[-1500:])
    finally:
        s.stop()
        server.shutdown()
        server.server_close()
        shutil.rmtree(home, ignore_errors=True)


def make_env(home, base):
    env = dict(os.environ)
    for k in list(env):
        if k.startswith(("BRIGLIA_", "ADA_", "SM_")):
            del env[k]
    env.update({"HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
                "XDG_CACHE_HOME": home + "/.cache", "TMPDIR": home + "/tmp/",
                "BRIGLIA_IGNORE_LEGACY_SETUP_FLAG": "1", "BRIGLIA_DEV_QUICKSETUP_STUBS": "1",
                "BRIGLIA_QUICKSETUP_NO_BROWSER": "1", "BRIGLIA_DEV_PROBE_BASE": base,
                "BRIGLIA_OPENROUTER_API_BASE": base})
    return env


def transition_scenario(label, main):
    """Codex round 3 R1: an incomplete setup that already runs OpenRouter
    (no OpenAI key, valid under the new policy) is given a new OpenCode key.
    main=None is the API shape without a choice (the older inference then
    activates OpenCode); main="openrouter" is what the page sends when
    OpenRouter stays selected. The save must validate the OpenAI key against
    the provider it leaves running, refuse before any write, and complete
    once consistent."""
    LISTING["ok"] = True
    home = tempfile.mkdtemp(prefix="briglia-qs-or-switch-")
    os.makedirs(home + "/tmp", exist_ok=True)
    cfg = home + "/.config/briglia"
    os.makedirs(cfg, mode=0o700)
    secrets_path = cfg + "/secrets.json"
    with open(secrets_path, "w") as f:
        json.dump({"active_provider_profile": "openrouter", "openrouter_api_key": OR_KEY,
                   "openrouter_model": DEFAULT_MODEL, "openrouter_text_only": "false"}, f)
    os.chmod(secrets_path, 0o600)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ProviderMock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = make_env(home, "http://127.0.0.1:%d" % server.server_address[1])
    s = Session(env)
    try:
        check(label + ": link and cookie", s.connect(), s.text()[-500:])
        _, st0 = s.call("GET", "/api/status")
        check(label + ": status reports the running provider", st0.get("active_provider") == "openrouter", str(st0.get("active_provider")))
        req = {"name": "Offline test", "openrouter": {"kept": True}, "opencode": {"value": GOOD["opencode"]},
               "serper": {"value": GOOD["serper"]}, "jina": {"value": GOOD["jina"]},
               "telegram": {"token": GOOD["telegram"], "chat_id": CHAT_ID}}
        if main:
            req["main"] = main
        st, js = s.call("POST", "/api/verify", req)
        check(label + ": verifies", st == 200 and js.get("phase") == "verified", str(js)[:300])
        before = open(secrets_path, "rb").read()
        st, js = s.call("POST", "/api/save", req)
        if main is None:
            check(label + ": save refused openai_required (OpenCode would run without an OpenAI key)",
                  st == 409 and js.get("error") == "openai_required", "%s %s" % (st, str(js)[:300]))
            check(label + ": refusal wrote nothing", open(secrets_path, "rb").read() == before)
            req["openai"] = {"value": GOOD["openai"]}
            st, js = s.call("POST", "/api/verify", req)
            check(label + ": with the OpenAI key added it verifies", st == 200 and js.get("phase") == "verified", str(js)[:300])
            st, js = s.call("POST", "/api/save", req)
        check(label + ": save → system phase", st == 200 and js.get("phase") == "system", "%s %s" % (st, str(js)[:300]))
        store = json.load(open(secrets_path))
        expected = "opencode" if main is None else "openrouter"
        check(label + ": the running provider is " + expected + ", OpenCode key stored",
              store.get("active_provider_profile") == expected and bool(store.get("opencode_api_key")),
              str(store.get("active_provider_profile")))
        check(label + ": OpenAI key " + ("stored" if main is None else "absent (OpenRouter runs)"),
              bool(store.get("openai_transcription_api_key")) == (main is None))
        notices = " ".join(js.get("notices", []))
        check(label + ": the 'No OpenAI key' notice only when OpenRouter runs", ("No OpenAI key" in notices) == (main is not None), notices)
        if run_system_rows(s, label):
            finish(s, label)
        store = json.load(open(secrets_path))
        check(label + ": setup complete and progress cleared", store.get("cli_setup_complete") == "true"
              and "cli_setup_step_in_progress" not in store, json.dumps({k: store.get(k) for k in ("cli_setup_complete", "cli_setup_step_in_progress")}))
        check(label + ": process exited 0", s.proc.returncode == 0, "rc=%s tail=%r" % (s.proc.returncode, s.text()[-400:]))
    except Exception as e:
        check(label + ": driver raised %r" % (e,), False, s.text()[-1500:])
    finally:
        s.stop()
        server.shutdown()
        server.server_close()
        shutil.rmtree(home, ignore_errors=True)


def keep_current_scenario(label, seed_for, expect_refusal=None, with_openai=True):
    """Codex round 4 R1: an incomplete install that already runs a provider
    outside the selector (custom endpoint, local server, named server, the
    OpenAI API profile) keeps it with main="current". The save must leave
    that provider running and the final check must require only what it
    needs, never an OpenCode key. An incomplete current provider is refused
    at save, before anything is written (expect_refusal)."""
    LISTING["ok"] = True
    home = tempfile.mkdtemp(prefix="briglia-qs-keep-")
    os.makedirs(home + "/tmp", exist_ok=True)
    cfg = home + "/.config/briglia"
    os.makedirs(cfg, mode=0o700)
    secrets_path = cfg + "/secrets.json"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ProviderMock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % server.server_address[1]
    seed = seed_for(base)
    with open(secrets_path, "w") as f:
        json.dump(seed, f)
    os.chmod(secrets_path, 0o600)
    env = make_env(home, base)
    s = Session(env)
    try:
        check(label + ": link and cookie", s.connect(), s.text()[-500:])
        _, st0 = s.call("GET", "/api/status")
        check(label + ": status reports the running provider", st0.get("active_provider") == seed["active_provider_profile"],
              str(st0.get("active_provider")))
        req = {"name": "Offline test", "main": "current", "serper": {"value": GOOD["serper"]}, "jina": {"value": GOOD["jina"]},
               "telegram": {"token": GOOD["telegram"], "chat_id": CHAT_ID}}
        if with_openai:
            req["openai"] = {"value": GOOD["openai"]}
        st, js = s.call("POST", "/api/verify", req)
        check(label + ": verifies", st == 200 and js.get("phase") == "verified", "%s %s" % (st, str(js)[:300]))
        before = open(secrets_path, "rb").read()
        st, js = s.call("POST", "/api/save", req)
        if expect_refusal:
            check(label + ": save refused " + expect_refusal, st == 409 and js.get("error") == expect_refusal, "%s %s" % (st, str(js)[:300]))
            check(label + ": refusal wrote nothing", open(secrets_path, "rb").read() == before)
            store = json.load(open(secrets_path))
            check(label + ": setup not marked complete", store.get("cli_setup_complete") != "true")
            return
        check(label + ": save → system phase", st == 200 and js.get("phase") == "system", "%s %s" % (st, str(js)[:300]))
        store = json.load(open(secrets_path))
        provider_keys = [k for k in seed if k != "active_provider_profile"]
        check(label + ": the running provider is unchanged, no OpenCode key stored",
              store.get("active_provider_profile") == seed["active_provider_profile"] and not store.get("opencode_api_key"),
              str(store.get("active_provider_profile")))
        check(label + ": the provider's own settings are unchanged",
              all(store.get(k) == seed[k] for k in provider_keys if k != "provider_servers"),
              json.dumps({k: (store.get(k), seed[k]) for k in provider_keys if store.get(k) != seed[k]})[:300])
        if run_system_rows(s, label):
            finish(s, label)
        store = json.load(open(secrets_path))
        check(label + ": setup complete and progress cleared", store.get("cli_setup_complete") == "true"
              and "cli_setup_step_in_progress" not in store, json.dumps({k: store.get(k) for k in ("cli_setup_complete", "cli_setup_step_in_progress")}))
        check(label + ": still running " + seed["active_provider_profile"] + " after done, no OpenCode key",
              store.get("active_provider_profile") == seed["active_provider_profile"] and not store.get("opencode_api_key"))
        check(label + ": process exited 0", s.proc.returncode == 0, "rc=%s tail=%r" % (s.proc.returncode, s.text()[-400:]))
        check(label + ": no key in terminal output", not any(v in s.text() for v in (GOOD["openai"], GOOD["serper"], GOOD["jina"], GOOD["telegram"])))
    except Exception as e:
        check(label + ": driver raised %r" % (e,), False, s.text()[-1500:])
    finally:
        s.stop()
        server.shutdown()
        server.server_close()
        shutil.rmtree(home, ignore_errors=True)


def seed_custom(base):
    return {"active_provider_profile": "custom", "custom_endpoint_api_key": "fake-flow-custom-key",
            "custom_endpoint_base_url": base + "/custom", "custom_endpoint_model": "fake-custom-model"}


def seed_custom_no_model(base):
    seed = seed_custom(base)
    del seed["custom_endpoint_model"]
    return seed


def seed_local(base):
    return {"active_provider_profile": "local", "lmstudio_base_url": base + "/local", "lmstudio_model": "fake-local-model"}


def seed_named_server(base):
    server = {"id": "srv-flowtest01", "name": "Home GPU", "base_url": base + "/home", "api_key": "fake-flow-named-key",
              "model": "fake-named-model", "effort": "high", "text_only": False}
    return {"active_provider_profile": "custom", "provider_servers": json.dumps([server]),
            "custom_endpoint_server_id": "srv-flowtest01", "custom_endpoint_base_url": base + "/home",
            "custom_endpoint_api_key": "fake-flow-named-key", "custom_endpoint_model": "fake-named-model",
            "custom_endpoint_reasoning_effort": "high", "custom_endpoint_text_only": "false"}


def seed_openai_platform(base):
    return {"active_provider_profile": "openai", "openai_platform_api_key": "sk-fake-flow-platform-key",
            "openai_platform_model": "gpt-6-luna"}

if __name__ == "__main__":
    # Codex round-2 reproduction: OpenRouter + OpenAI, no OpenCode key.
    scenario("or+openai", listing_ok=True, restart=False, with_openai=True)
    scenario("or-only", listing_ok=True, restart=True)
    scenario("or-only, host list unreadable", listing_ok=False, restart=False)
    # Codex round-3 R1 reproduction, then the page's explicit choice.
    transition_scenario("existing OR + new OpenCode, no main", None)
    transition_scenario("existing OR + new OpenCode, main=openrouter", "openrouter")
    # Codex round-4 R1 reproduction: "Keep current" on providers outside the
    # selector, through to done; an incomplete one is refused at save.
    keep_current_scenario("keep current: custom endpoint", seed_custom)
    keep_current_scenario("keep current: local server", seed_local)
    keep_current_scenario("keep current: named keyed server", seed_named_server)
    keep_current_scenario("keep current: OpenAI API profile", seed_openai_platform)
    keep_current_scenario("keep current: incomplete custom endpoint", seed_custom_no_model, expect_refusal="main_incomplete")
    keep_current_scenario("keep current: custom endpoint without OpenAI key", seed_custom, expect_refusal="openai_required", with_openai=False)
    print("\nquicksetup openrouter flow: %s" % ("all checks passed" if FAILS == 0 else "%d FAILED" % FAILS))
    sys.exit(1 if FAILS else 0)
