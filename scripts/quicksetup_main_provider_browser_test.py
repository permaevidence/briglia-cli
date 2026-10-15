#!/usr/bin/env python3
"""Browser check that the Quick Setup page shows the main provider the save
activates (Codex round 3 R2). Playwright Chromium drives the real page served
by the real binary against loopback mock providers and the dev stubs, with
throwaway HOME/XDG roots; every page request outside 127.0.0.1 is aborted.

Scenarios (each from the intro to the system phase, then the stored file):
  1. Fresh install, OpenRouter key only: OpenRouter is preselected and shown
     as running Briglia; saved active provider = OpenRouter.
  2. Fresh install, both keys, OpenRouter left selected: the OpenCode key sits
     among the saved-not-active providers; saved active = OpenRouter.
  3. Fresh install, both keys, OpenCode selected: the OpenAI key is required
     (Save stays off until it is given); saved active = OpenCode.
  4. Existing OpenRouter install (no OpenAI key) given a new OpenCode key:
     OpenRouter stays selected and running (Codex round 3 R1, via the page).
In every scenario the page must not promise that OpenRouter stays an
alternative, and the selected value must equal the saved provider.

Usage: quicksetup_main_provider_browser_test.py /path/to/briglia
"""
import http.server
import json
import os
import shutil
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quicksetup_openrouter_flow_test as flow  # noqa: E402
from quicksetup_headless_test import GOOD, CHAT_ID  # noqa: E402

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print("playwright is not installed: pip install playwright && python -m playwright install chromium")
    sys.exit(2)

FAILS = 0


def check(label, ok, detail=""):
    global FAILS
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + detail))
    if not ok:
        FAILS += 1


def wait_until(fn, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:
            pass
        time.sleep(0.1)
    return False


def scenario(pw, label, fill, select=None, seed=None, expect_main="openrouter", needs_openai_first=False):
    flow.LISTING["ok"] = True
    home = tempfile.mkdtemp(prefix="briglia-qs-main-")
    os.makedirs(home + "/tmp", exist_ok=True)
    secrets_path = home + "/.config/briglia/secrets.json"
    if seed:
        os.makedirs(os.path.dirname(secrets_path), mode=0o700)
        with open(secrets_path, "w") as f:
            json.dump(seed, f)
        os.chmod(secrets_path, 0o600)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), flow.ProviderMock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = flow.make_env(home, "http://127.0.0.1:%d" % server.server_address[1])
    s = flow.Session(env)
    browser = None
    try:
        m = s.wait_for(r"http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})")
        check(label + ": launch link", m is not None, s.text()[-400:])
        if not m:
            return
        browser = pw.chromium.launch()
        ctx = browser.new_context()
        ctx.route("**/*", lambda route: route.continue_() if route.request.url.startswith("http://127.0.0.1:") else route.abort())
        page = ctx.new_page()
        page.goto(m.group(0))
        page.wait_for_selector("#phase-intro:not([hidden])")
        check(label + ": the selector settles on " + ("the running provider" if seed else "OpenRouter (new setup)"),
              wait_until(lambda: page.input_value("#main-provider") == ("openrouter" if not seed else seed["active_provider_profile"])),
              page.input_value("#main-provider"))
        body = page.text_content("body") or ""
        check(label + ": no promise that OpenRouter stays an alternative", "saved as an alternative provider" not in body)
        if select:
            page.select_option("#main-provider", select)
        page.fill("#f-name", "Offline browser test")
        for field, value in fill.items():
            page.fill("#f-" + field, value)
            page.press("#f-" + field, "Tab")
        chosen = page.input_value("#main-provider")
        note = page.text_content("#main-note") or ""
        names = {"openrouter": "OpenRouter", "opencode": "OpenCode Go"}
        check(label + ": the note names the chosen main provider (" + chosen + ")", ("run on " + names[chosen]) in note, note)
        # The main key is the first required field; the other one is an extra.
        # (A kept key shows "configured, keeping current" instead of an input.)
        labels = {"openrouter": "OpenRouter key", "opencode": "OpenCode Go key"}
        first = page.query_selector("#required-fields .label")
        first_text = (first.text_content() or "") if first else ""
        check(label + ": the chosen provider's key is the first required field", first_text.endswith(labels[chosen]), first_text)
        if needs_openai_first:
            time.sleep(2.5)
            check(label + ": Save stays off without the OpenAI key (OpenCode runs)", not page.is_enabled("#btn-save"))
            check(label + ": the hint asks for the OpenAI key", "OpenAI key" in (page.text_content("#save-hint") or ""), page.text_content("#save-hint") or "")
            page.fill("#f-openai", GOOD["openai"])
            page.press("#f-openai", "Tab")
        check(label + ": Save enabled after automatic verification", wait_until(lambda: page.is_enabled("#btn-save"), 40),
              page.text_content("#save-hint") or "")
        with page.expect_response(lambda r: r.url.endswith("/api/save") and r.request.method == "POST") as resp_info:
            page.click("#btn-save")
        resp = resp_info.value
        check(label + ": save accepted", resp.status == 200, "%s %s" % (resp.status, resp.text()[:300]))
        check(label + ": the page reaches the system phase", wait_until(lambda: page.is_visible("#phase-system"), 30))
        store = json.load(open(secrets_path))
        check(label + ": saved main provider = displayed choice = " + expect_main,
              store.get("active_provider_profile") == expect_main == chosen,
              "saved=%s displayed=%s" % (store.get("active_provider_profile"), chosen))
        if "opencode" in fill and expect_main == "openrouter":
            check(label + ": the OpenCode key is stored, not active", bool(store.get("opencode_api_key")))
        if expect_main == "openrouter" and "openai" not in fill:
            check(label + ": no OpenAI key needed or stored", not store.get("openai_transcription_api_key"))
    except Exception as e:
        check(label + ": driver raised %r" % (e,), False, s.text()[-800:])
    finally:
        if browser:
            browser.close()
        s.stop()
        server.shutdown()
        server.server_close()
        shutil.rmtree(home, ignore_errors=True)


def current_provider_scenario(pw):
    """An install running a provider the selector doesn't list (a custom
    endpoint) preselects "Keep current" and says it keeps running."""
    label = "existing custom-endpoint install"
    home = tempfile.mkdtemp(prefix="briglia-qs-main-")
    os.makedirs(home + "/tmp", exist_ok=True)
    path = home + "/.config/briglia/secrets.json"
    os.makedirs(os.path.dirname(path), mode=0o700)
    with open(path, "w") as f:
        json.dump({"active_provider_profile": "custom", "custom_endpoint_api_key": "k", "custom_endpoint_base_url": "http://127.0.0.1:9/v1",
                   "custom_endpoint_model": "m"}, f)
    os.chmod(path, 0o600)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), flow.ProviderMock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    s = flow.Session(flow.make_env(home, "http://127.0.0.1:%d" % server.server_address[1]))
    browser = None
    try:
        m = s.wait_for(r"http://127\.0\.0\.1:(\d+)/start\?t=([0-9a-f]{32})")
        check(label + ": launch link", m is not None, s.text()[-400:])
        if not m:
            return
        browser = pw.chromium.launch()
        page = browser.new_page()
        page.goto(m.group(0))
        page.wait_for_selector("#phase-intro:not([hidden])")
        check(label + ": preselects Keep current", wait_until(lambda: page.input_value("#main-provider") == "current"), page.input_value("#main-provider"))
        note = page.text_content("#main-note") or ""
        check(label + ": the note says the custom endpoint keeps running and OpenAI is required",
              "run on Custom endpoint" in note and "OpenAI key is required" in note, note)
    except Exception as e:
        check(label + ": driver raised %r" % (e,), False, s.text()[-800:])
    finally:
        if browser:
            browser.close()
        s.stop()
        server.shutdown()
        server.server_close()
        shutil.rmtree(home, ignore_errors=True)


def main():
    base = {"serper": GOOD["serper"], "jina": GOOD["jina"], "telegram_token": GOOD["telegram"], "telegram_chat": CHAT_ID}
    with sync_playwright() as pw:
        scenario(pw, "fresh, OpenRouter only", dict(base, openrouter=flow.OR_KEY))
        scenario(pw, "fresh, both keys, OpenRouter selected", dict(base, openrouter=flow.OR_KEY, opencode=GOOD["opencode"]))
        scenario(pw, "fresh, both keys, OpenCode selected", dict(base, openrouter=flow.OR_KEY, opencode=GOOD["opencode"]),
                 select="opencode", expect_main="opencode", needs_openai_first=True)
        scenario(pw, "existing OpenRouter + new OpenCode key", dict(base, opencode=GOOD["opencode"]),
                 seed={"active_provider_profile": "openrouter", "openrouter_api_key": flow.OR_KEY,
                       "openrouter_model": flow.DEFAULT_MODEL, "openrouter_text_only": "false"})
        current_provider_scenario(pw)
    print("\nquicksetup main-provider browser: %s" % ("all checks passed" if FAILS == 0 else "%d FAILED" % FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
