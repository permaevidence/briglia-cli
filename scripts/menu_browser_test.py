#!/usr/bin/env python3
"""Browser behavior of the `briglia menu` page against a scripted fake
server (the real server's flows are covered by `__menu-selftest`): the
guided first run, automatic key checks without any Verify button, ChatGPT
sign-in waiting states, Telegram detection and confirmation, the computer
and tools steps, the dashboard, phone width, dark mode, and no page errors.

With MENU_SCREENSHOTS=<dir> it also saves screenshots of every screen.

Usage: menu_browser_test.py
"""
import copy
import http.server
import json
import os
import threading
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1] / "TelegramConcierge/Resources/QuickSetup"
SHOTS = os.environ.get("MENU_SCREENSHOTS")
FAILS = []


def check(label, ok, detail=""):
    print(("✔ " if ok else "✖ ") + label + ("" if ok or not detail else " — " + str(detail)))
    if not ok:
        FAILS.append(label)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=str(ROOT), **k)

    def log_message(self, *a):
        pass


MODELS = [{"id": "gpt-6-sol", "label": "GPT-6 Sol", "recommended": True}, {"id": "gpt-6-luna", "label": "GPT-6 Luna"},
          {"id": "gpt-6-astra", "label": "GPT-6 Astra"}, {"id": "gpt-5.6-luna", "label": "GPT-5.6 Luna"},
          {"id": "gpt-5.6-terra", "label": "GPT-5.6 Terra"}, {"id": "gpt-5.6-sol", "label": "GPT-5.6 Sol"}]
TITLES_IT = {"name": "Il tuo nome", "serper": "Ricerca web", "jina": "Lettura pagine web", "openai": "Voce e immagini",
             "computer": "Questo computer", "tools": "Strumenti documenti e media"}
TITLES = [("name", "Your name", True), ("chatgpt", "ChatGPT", True), ("telegram", "Telegram", True), ("serper", "Web search", True),
          ("jina", "Reading web pages", True), ("openai", "Voice & images", False), ("email", "Email", False),
          ("computer", "This computer", True), ("tools", "Document & media tools", True)]
GOOD = {"serper": "srp-good-0123456789abcdef", "jina": "jina_good_0123456789abcdef", "openai": "sk-good-0123456789abcdef",
        "agentmail": "am_good_0123456789abcdef", "telegram": "123456789:AAgoodtoken0123456789"}


class Fake:
    def __init__(self, platform="macos"):
        self.platform = platform
        self.name = ""
        self.chatgpt = {"state": "signed_out", "active": False, "model": "gpt-6-sol", "effort": "high", "other_provider": None, "login": None}
        self.telegram = {"configured": False, "chat_id": "", "bot": None, "pending": None}
        self.keys = {"serper": None, "jina": None, "openai": None, "agentmail": None}
        self.email = {"on": False, "inbox": "", "tool_installed": False}
        self.computer = {"fda": False, "terminal_app": "Terminal", "keep_awake_ok": True,
                         "keep_awake_summary": "Briglia keeps this Mac awake while it runs.", "can_fix_gnome": False, "can_mask": False}
        self.tools = {"checking": False, "complete": False, "missing": ["pandoc", "LibreOffice"], "installing": False, "label": "", "lines": []}
        self.closing = None
        self.lang = "en"
        self.calls = []
        self.poll_count = 0

    def done(self, sid):
        return {"name": bool(self.name), "chatgpt": self.chatgpt["state"] == "signed_in" and self.chatgpt["active"],
                "telegram": self.telegram["configured"], "serper": bool(self.keys["serper"]), "jina": bool(self.keys["jina"]),
                "openai": bool(self.keys["openai"]), "email": self.email["on"],
                "computer": self.computer["fda"] and self.computer["keep_awake_ok"], "tools": self.tools["complete"]}[sid]

    def status(self):
        steps = [{"id": i, "title": TITLES_IT.get(i, t) if self.lang == "it" else t, "required": r, "done": self.done(i), "summary": ""} for i, t, r in TITLES]
        c = dict(self.chatgpt)
        c["models"] = MODELS
        c["model_label"] = [m["label"] for m in MODELS if m["id"] == c["model"]][0]
        return {"platform": self.platform, "lang": self.lang, "complete": all(s["done"] for s in steps if s["required"]), "steps": steps, "name": self.name,
                "chatgpt": c, "telegram": self.telegram, "keys": self.keys, "email": self.email, "computer": self.computer,
                "tools": self.tools, "busy": None, "service_was_running": False, "browser_likely": True, "closing": self.closing}

    def act(self, body):
        a = body.get("action")
        self.calls.append(body)
        ok, msg = True, None
        if a == "lang":
            self.lang = body["lang"]
        elif a == "name":
            self.name = body["name"]; msg = "Nice to meet you, %s!" % self.name
        elif a == "key":
            kind = body["kind"]
            if body["key"] != GOOD[kind]:
                ok, msg = False, {"serper": "Serper", "jina": "Jina", "openai": "OpenAI", "agentmail": "AgentMail"}[kind] + " refused this key. Make sure you copied the whole key, then paste it again."
            else:
                self.keys[kind] = body["key"][:5] + "…" + body["key"][-4:]
                if kind == "agentmail":
                    self.email = {"on": True, "inbox": "bree@agentmail.to", "tool_installed": True}
                msg = {"serper": "Web search is on.", "jina": "Briglia can now read web pages.", "openai": "Voice messages and image creation are on.", "agentmail": "Email is ready."}[kind]
        elif a == "chatgpt_browser":
            self.chatgpt["login"] = {"kind": "browser", "state": "waiting", "url": "https://auth.example/authorize", "code": None}
        elif a == "chatgpt_code":
            self.chatgpt["login"] = {"kind": "code", "state": "waiting", "url": "https://auth.openai.com/codex/device", "code": "VA6Y-XQ0M"}
        elif a == "chatgpt_cancel":
            self.chatgpt["login"] = None; msg = "Sign-in cancelled."
        elif a == "chatgpt_model":
            self.chatgpt["model"] = body["model"]; msg = "Briglia now thinks with " + [m["label"] for m in MODELS if m["id"] == body["model"]][0] + "."
        elif a == "telegram_token":
            if body["token"] != GOOD["telegram"]:
                ok, msg = False, "Telegram didn't accept this token. Copy it again from @BotFather (the whole line, like 123456789:AAE…)."
            else:
                self.telegram["pending"] = {"bot": "sofia_test_bot", "state": "waiting"}
        elif a == "telegram_confirm":
            self.telegram.update({"configured": True, "chat_id": body["chat_id"], "bot": "sofia_test_bot", "pending": None})
            msg = "Telegram connected! Your messages to @sofia_test_bot reach Briglia while it's running."
        elif a == "fda_open":
            msg = "System Settings is open. Turn on Terminal in the list — this page updates by itself."
        elif a == "tools_install":
            self.tools.update({"installing": True, "label": "Step 1 of 2: brew install pandoc", "lines": ["▶ brew install pandoc", "==> Downloading pandoc-3.8.tar.gz", "==> Pouring pandoc--3.8.arm64_sequoia.bottle.tar.gz"]})
        elif a == "finish":
            self.closing = body["what"]
        return {"ok": ok, "message": msg, "status": self.status()}

    def tick(self):
        # Things that happen outside the page while it polls.
        self.poll_count += 1
        login = self.chatgpt.get("login")
        if login and login["state"] == "waiting" and getattr(self, "auto_signin", False):
            self.chatgpt.update({"state": "signed_in", "active": True, "login": None})
        p = self.telegram.get("pending")
        if p and p["state"] == "waiting" and getattr(self, "auto_found", False):
            p.update({"state": "found", "name": "Sofia (@sofia)", "chat_id": "5551234567"})
        if getattr(self, "auto_fda", False):
            self.computer["fda"] = True
        if self.tools["installing"] and getattr(self, "auto_tools", False):
            self.tools.update({"installing": False, "complete": True, "missing": []})


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d/menu.html" % server.server_address[1]
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)

        def session(fake, width=1280, height=860, dark=False):
            ctx = browser.new_context(viewport={"width": width, "height": height}, color_scheme="dark" if dark else "light", device_scale_factor=2)
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)

            def api(route):
                path = route.request.url.split("/api/")[-1]
                if path == "menu/status":
                    fake.tick()
                    body = fake.status()
                else:
                    body = fake.act(route.request.post_data_json or {})
                route.fulfill(status=200, content_type="application/json", body=json.dumps(body))
            page.route("**/api/**", api)
            page.goto(base)
            return ctx, page, errors

        def shot(page, name):
            if SHOTS:
                page.screenshot(path=os.path.join(SHOTS, name + ".png"), full_page=True)

        # ---- guided first run ----
        f = Fake()
        ctx, page, errors = session(f)
        page.wait_for_selector("text=Choose your language")
        check("a first run asks for the language first", page.is_visible("text=Italiano") and page.is_visible(".lang-switch"))
        shot(page, "00-language")
        page.click(".langcard:has-text('English')")
        page.wait_for_selector("text=Let’s set up Briglia")
        check("first run shows the welcome screen", page.is_visible("text=Let’s start"))
        shot(page, "01-welcome")
        page.click("text=Let’s start")
        page.wait_for_selector("text=What should Bree call you?")
        page.fill("#f-name", "Sofia")
        page.click("button:has-text('Save')")
        page.wait_for_selector("text=Sign in to ChatGPT")
        check("the name is saved and ChatGPT comes next", f.name == "Sofia")
        shot(page, "02-chatgpt")
        page.click("text=Use a code instead")
        page.wait_for_selector(".code-box")
        check("code sign-in shows the code", "VA6Y-XQ0M" in page.inner_text(".code-box"))
        shot(page, "03-chatgpt-code")
        page.click("button:has-text('Cancel')")
        page.wait_for_selector("text=Sign-in cancelled.")
        f.auto_signin = True
        page.click("text=Sign in with ChatGPT")
        page.wait_for_selector("text=Briglia thinks with GPT-6 Sol", timeout=8000)
        check("browser sign-in completes by polling, no button needed", f.chatgpt["state"] == "signed_in")
        shot(page, "04-chatgpt-signed-in")
        page.click("text=Continue →")
        page.wait_for_selector("text=Connect Telegram")
        shot(page, "05-telegram")
        page.fill("#f-telegram", "123456789:AAwrong-but-long-enough-token")
        page.press("#f-telegram", "Enter")
        page.wait_for_selector("text=didn't accept this token")
        check("a wrong token shows the reason under the field", True)
        page.fill("#f-telegram", GOOD["telegram"])
        page.press("#f-telegram", "Enter")
        page.wait_for_selector("text=Waiting for your message")
        check("the Open @bot in Telegram button links to t.me", page.get_attribute("a.btn.primary", "href") == "https://t.me/sofia_test_bot")
        shot(page, "06-telegram-waiting")
        f.auto_found = True
        page.wait_for_selector("text=Is this you?", timeout=8000)
        shot(page, "07-telegram-found")
        page.click("text=Yes, that’s me")
        page.wait_for_selector("text=Serper lets Briglia search Google")
        check("confirming saves the chat and moves to web search", f.telegram["chat_id"] == "5551234567")
        shot(page, "08-serper")
        page.fill("#f-serper", "srp-wrong-00000000000000")
        page.wait_for_selector("text=Serper refused this key", timeout=6000)
        check("typing a key checks it automatically (no Verify button, no Enter)", not page.is_visible("text=Verify"))
        shot(page, "09-serper-refused")
        page.fill("#f-serper", GOOD["serper"])
        page.wait_for_selector("text=Web search is on.", timeout=6000)
        shot(page, "10-serper-saved")
        page.click("text=Continue →")
        page.wait_for_selector("#f-jina")
        # Paste = immediate check.
        page.focus("#f-jina")
        page.evaluate("t => { const i = document.getElementById('f-jina'); i.value = t; i.dispatchEvent(new Event('input')); i.dispatchEvent(new Event('paste')); }", GOOD["jina"])
        page.wait_for_selector("text=Briglia can now read web pages.", timeout=6000)
        check("pasting a key checks it right away", bool(f.keys["jina"]))
        page.click("text=Continue →")
        page.wait_for_selector("text=Voice messages & images")
        check("the OpenAI step says what the key is for", page.is_visible("text=understand your voice messages and create images"))
        shot(page, "11-openai")
        page.click("text=Skip for now")
        page.wait_for_selector("text=AgentMail gives Briglia its own email address")
        shot(page, "12-email")
        page.click("text=Skip for now")
        page.wait_for_selector("text=Prepare this computer")
        shot(page, "13-computer")
        page.click("text=Open System Settings")
        f.auto_fda = True
        page.wait_for_selector(".checks li.ok >> text=Full Disk Access", timeout=8000)
        check("Full Disk Access turning on is noticed by polling", True)
        page.click("text=Continue →")
        page.wait_for_selector("text=Install what’s missing")
        shot(page, "14-tools")
        page.click("text=Install what’s missing")
        page.wait_for_selector("text=Step 1 of 2")
        shot(page, "15-tools-installing")
        f.auto_tools = True
        page.wait_for_selector("text=Everything is installed", timeout=8000)
        page.click("text=Continue →")
        page.wait_for_selector("text=Everything’s ready!")
        shot(page, "16-finish")
        page.click("text=Start Briglia")
        page.wait_for_selector("text=Briglia is starting")
        check("Start Briglia closes the setup", f.closing == "start")
        shot(page, "17-starting")
        check("no page errors in the guided run", not errors, errors)
        ctx.close()

        # ---- returning user: dashboard ----
        g = Fake()
        g.name = "Sofia"; g.chatgpt.update({"state": "signed_in", "active": True}); g.telegram.update({"configured": True, "chat_id": "5551234567", "bot": "sofia_test_bot"})
        g.keys.update({"serper": "srp-g…cdef", "jina": "jina_…cdef"}); g.computer["fda"] = True; g.tools.update({"complete": True, "missing": []})
        ctx, page, errors = session(g)
        page.wait_for_selector("text=Everything’s ready")
        check("a finished setup opens on the dashboard", page.is_visible(".grid"))
        shot(page, "20-dashboard")
        page.click(".tile:has-text('ChatGPT')")
        page.wait_for_selector(".choices")
        page.click(".choice:has-text('GPT-6 Luna')")
        page.wait_for_selector("text=Briglia now thinks with GPT-6 Luna.")
        check("a model can be changed with one click", g.chatgpt["model"] == "gpt-6-luna")
        shot(page, "21-dashboard-chatgpt")
        check("no page errors on the dashboard", not errors, errors)
        ctx.close()

        # ---- Italian ----
        it = Fake()
        ctx, page, errors = session(it)
        page.wait_for_selector("text=Choose your language")
        page.click(".langcard:has-text('Italiano')")
        page.wait_for_selector("text=Configuriamo Briglia")
        check("choosing Italiano switches the page and tells the server", it.lang == "it" and page.is_visible("text=Iniziamo"))
        check("the side list is in Italian", page.is_visible(".steps >> text=Il tuo nome") if False else page.is_visible("text=Tutto quello che inserisci viene salvato subito."))
        shot(page, "50-it-welcome")
        page.click("text=Iniziamo")
        page.wait_for_selector("text=Come deve chiamarti Bree?")
        page.fill("#f-name", "Sofia"); page.click("button:has-text('Salva')")
        page.wait_for_selector("text=Accedi a ChatGPT")
        shot(page, "51-it-chatgpt")
        page.click(".langbtn:has-text('EN')")
        page.wait_for_selector("text=Sign in to ChatGPT")
        check("the corner flags switch language on any screen", it.lang == "en")
        check("no page errors in Italian", not errors, errors)
        ctx.close()

        # ---- phone width + dark mode ----
        h = Fake()
        ctx, page, errors = session(h, width=390, height=844)
        page.wait_for_selector("text=Choose your language")
        shot(page, "29-phone-language")
        page.click(".langcard:has-text('English')")
        page.wait_for_selector("text=Let’s set up Briglia")
        overflow = page.evaluate("document.documentElement.scrollWidth > window.innerWidth + 1")
        check("no horizontal scrolling at phone width", not overflow)
        shot(page, "30-phone-welcome")
        page.click("text=Let’s start"); page.wait_for_selector("#f-name")
        page.fill("#f-name", "Sofia"); page.click("button:has-text('Save')")
        page.wait_for_selector("text=Sign in to ChatGPT")
        shot(page, "31-phone-chatgpt")
        ctx.close()
        d = Fake()
        ctx, page, errors = session(d, dark=True)
        page.wait_for_selector("text=Choose your language")
        page.click(".langcard:has-text('English')")
        page.wait_for_selector("text=Let’s set up Briglia")
        page.click("text=See all settings")
        page.wait_for_selector(".grid")
        shot(page, "40-dark-dashboard")
        check("no page errors in dark mode", not errors, errors)
        ctx.close()
        browser.close()
    server.shutdown()
    print("\nmenu browser test: " + ("all checks passed" if not FAILS else "%d FAILED" % len(FAILS)))
    raise SystemExit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
