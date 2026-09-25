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
TITLES = [("name", "Your name", True), ("ai", "ChatGPT", True), ("telegram", "Telegram", True), ("serper", "Web search", True),
          ("jina", "Reading web pages", True), ("openai", "Voice & images", False), ("email", "Email", False),
          ("computer", "This computer", True), ("tools", "Document & media tools", True)]
GOOD = {"serper": "srp-good-0123456789abcdef", "jina": "jina_good_0123456789abcdef", "openai": "sk-good-0123456789abcdef",
        "agentmail": "am_good_0123456789abcdef", "telegram": "123456789:AAgoodtoken0123456789",
        "opencode": "oc-good-0123456789abcdef", "openrouter": "sk-or-good-0123456789abcdef"}
OC_MODELS = [{"id": "glm-5.3-flash", "label": "GLM 5.3 Flash", "recommended": True}, {"id": "kimi-k3", "label": "Kimi K3"},
             {"id": "qwen3.8-max", "label": "Qwen 3.8 Max"}]
LANE_TITLES = {"chatgpt": "ChatGPT", "opencode": "OpenCode Go", "openrouter": "OpenRouter", "local": "Server (local or online)"}


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
        self.planned = None
        self.providers = {k: {"configured": False, "active": False, "model": "", "model_label": "", "effort": "high", "text_only": False,
                              "efforts": ["low", "medium", "high"]} for k in ("opencode", "openrouter")}
        self.servers = []          # named servers: {id, name, endpoint, model, keyed, key, text_only, effort}
        self.active_server = None
        self.local = None
        self.lang = "en"
        self.calls = []
        self.poll_count = 0

    def active(self):
        if self.chatgpt["state"] == "signed_in" and self.chatgpt["active"]:
            return "chatgpt"
        for k, p in self.providers.items():
            if p["active"] and p["configured"]:
                return k
        if self.active_server:
            return "local"
        return None

    def lane(self):
        return self.planned or self.active() or "chatgpt"

    def openai_required(self):
        # OpenCode Go and local/other need the OpenAI key; ChatGPT and
        # OpenRouter don't (owner, 2026-09-25).
        a = self.active()
        return (a in ("opencode", "local")) if a else (self.planned in ("opencode", "local"))

    def media_via(self):
        if self.keys["openai"]:
            return "openai"
        return "openrouter" if self.active() == "openrouter" else None

    def use(self, k, server=None):
        self.chatgpt["active"] = k == "chatgpt"
        for kk, p in self.providers.items():
            p["active"] = kk == k
        self.active_server = server if k == "local" else None
        self.planned = None

    def done(self, sid):
        return {"name": bool(self.name), "ai": self.active() is not None,
                "telegram": self.telegram["configured"], "serper": bool(self.keys["serper"]), "jina": bool(self.keys["jina"]),
                "openai": bool(self.keys["openai"]) or self.media_via() == "openrouter", "email": self.email["on"],
                "computer": self.computer["fda"] and self.computer["keep_awake_ok"], "tools": self.tools["complete"]}[sid]

    def status(self):
        req = self.openai_required()
        def title(i, t):
            if i == "ai":
                if self.active() == "local":
                    return [x for x in self.servers if x["id"] == self.active_server][0]["name"]
                return LANE_TITLES[self.active() or self.lane()]
            if i == "openai" and req:
                return "OpenAI key"
            return TITLES_IT.get(i, t) if self.lang == "it" else t
        steps = [{"id": i, "title": title(i, t), "required": req if i == "openai" else r, "done": self.done(i), "summary": ""} for i, t, r in TITLES]
        provs = {k: dict(v, active=(self.active() == k)) for k, v in self.providers.items()}
        provs["chatgpt"] = {"configured": self.chatgpt["state"] == "signed_in", "active": self.active() == "chatgpt", "model": self.chatgpt["model"],
                            "model_label": [m["label"] for m in MODELS if m["id"] == self.chatgpt["model"]][0], "effort": self.chatgpt["effort"],
                            "efforts": ["low", "medium", "high", "xhigh"]}
        ai = {"lane": self.lane(), "active": self.active(), "planned": self.planned, "ready": self.active() is not None, "openai_required": req, "media_via": self.media_via(),
              "providers": provs, "opencode_models": OC_MODELS, "openrouter_default": "deepseek/deepseek-v4.1-flash",
              "servers": [dict(x, model_label=x["model"], active=(x["id"] == self.active_server),
                               efforts=(["low", "medium", "high"] if x["keyed"] and x["id"] == self.active_server else [])) for x in self.servers],
              "active_server": self.active_server, "max_servers": 20, "servers_damaged": False}
        if self.local:
            ai["local"] = {k: v for k, v in self.local.items() if k != "key"}
        c = dict(self.chatgpt)
        c["models"] = MODELS
        c["model_label"] = [m["label"] for m in MODELS if m["id"] == c["model"]][0]
        return {"platform": self.platform, "lang": self.lang, "complete": all(s["done"] for s in steps if s["required"]), "steps": steps, "name": self.name,
                "chatgpt": c, "ai": ai, "telegram": self.telegram, "keys": self.keys, "email": self.email, "computer": self.computer,
                "tools": self.tools, "busy": None, "service_was_running": getattr(self, "service_was_running", False), "running": getattr(self, "running", False), "run_mode": getattr(self, "run_mode", None), "browser_likely": True, "closing": self.closing,
                "startup": getattr(self, "startup", None)}

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
        elif a == "lane":
            self.planned = body["lane"] or None
            if self.planned == self.active():
                self.planned = None
        elif a == "provider_key":
            k = body["profile"]
            if body["key"] != GOOD[k]:
                ok, msg = False, LANE_TITLES[k] + " refused this key. Make sure you copied the whole key, then paste it again."
            else:
                p = self.providers[k]
                p.update({"configured": True, "key": body["key"][:5] + "…" + body["key"][-4:]})
                if not p["model"]:
                    p["model"] = "glm-5.3-flash" if k == "opencode" else "deepseek/deepseek-v4.1-flash"
                p["model_label"] = {"glm-5.3-flash": "GLM 5.3 Flash"}.get(p["model"], p["model"])
                self.use(k)
                msg = "Briglia now thinks with %s on %s." % (p["model_label"], LANE_TITLES[k])
        elif a == "provider_model":
            k = body["profile"]
            p = self.providers[k]
            p.update({"model": body["model"], "model_label": {m["id"]: m["label"] for m in OC_MODELS}.get(body["model"], body["model"]),
                      "text_only": bool(body.get("text_only"))})
            self.use(k)
            msg = "Briglia now thinks with %s on %s." % (p["model_label"], LANE_TITLES[k])
        elif a == "provider_use":
            self.use(body["profile"]); msg = "Briglia now thinks with %s." % LANE_TITLES[body["profile"]]
        elif a == "server_save":
            sid = body.get("id") or ""
            if not body.get("name", "").strip():
                ok, msg = False, "Give the server a name."
            elif any(x["name"].lower() == body["name"].lower() and x["id"] != sid for x in self.servers):
                ok, msg = False, "You already have a server called “%s”." % body["name"]
            else:
                lk = (self.local or {}).get("key")
                if sid:
                    x = [x for x in self.servers if x["id"] == sid][0]
                else:
                    x = {"id": "srv-%04d" % (len(self.servers) + 1), "keyed": False, "effort": ""}
                    self.servers.append(x)
                if self.local and self.local.get("base") == body["base_url"]:
                    x["keyed"] = bool(lk); x["key"] = (lk[:5] + "…" + lk[-4:]) if lk else None
                x.update({"name": body["name"], "endpoint": body["base_url"], "model": body["model"], "text_only": bool(body.get("text_only"))})
                if x["keyed"] and not x["effort"]:
                    x["effort"] = "high"
                self.local = None
                if not sid:
                    self.use("local", x["id"]); msg = "Added %s. Briglia now thinks with %s on it." % (x["name"], x["model"])
                else:
                    msg = "Saved."
        elif a == "server_use":
            x = [x for x in self.servers if x["id"] == body["id"]][0]
            self.use("local", x["id"]); msg = "Briglia now thinks with %s on %s." % (x["model"], x["name"])
        elif a == "lane_remove":
            lane = body["lane"]
            if lane == "server":
                if body["id"] == self.active_server:
                    ok, msg = False, "Briglia is using this one right now. Switch to another first, then remove it."
                else:
                    name = [x for x in self.servers if x["id"] == body["id"]][0]["name"]
                    self.servers = [x for x in self.servers if x["id"] != body["id"]]; msg = "%s removed." % name
            elif self.active() == lane:
                ok, msg = False, "Briglia is using this one right now. Switch to another first, then remove it."
            else:
                self.providers[lane].update({"configured": False, "model": "", "model_label": ""}); msg = "%s removed." % LANE_TITLES[lane]
        elif a == "effort":
            a2 = self.active()
            if a2 == "chatgpt":
                self.chatgpt["effort"] = body["effort"]
            elif a2 == "local":
                [x for x in self.servers if x["id"] == self.active_server][0]["effort"] = body["effort"]
            else:
                self.providers[a2]["effort"] = body["effort"]
            msg = "Saved. It applies from the next message."
        elif a == "local_models":
            self.local = {"base": body["base_url"], "state": "ok", "models": ["qwen3.8-27b", "gemma-4-12b"], "server_id": body.get("server_id") or None,
                          "keyed": bool(body.get("api_key")), "key": body.get("api_key") or None}
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
            if body["what"] == "start" and self.platform == "linux":
                # Linux: the real server starts and health-checks the service
                # first; this fake fails the first try and succeeds on Retry.
                self.start_tries = getattr(self, "start_tries", 0) + 1
                if self.start_tries == 1:
                    self.startup = {"state": "failed", "step": "", "message": "Briglia didn't start: the service restarted within the stability window."}
                else:
                    self.startup = None
                    self.closing = "start"
            else:
                self.startup = None
                self.closing = body["what"]
        return {"ok": ok, "message": msg, "status": self.status()}

    def tick(self):
        # Things that happen outside the page while it polls.
        self.poll_count += 1
        login = self.chatgpt.get("login")
        if login and login["state"] == "waiting" and getattr(self, "auto_signin", False):
            self.chatgpt.update({"state": "signed_in", "login": None})
            self.use("chatgpt")
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
        page.wait_for_selector("text=How should Briglia think?")
        check("then it asks how Briglia should think, ChatGPT pre-selected as the easiest",
              page.locator(".lanecard").count() == 4 and "sel" in page.get_attribute(".lanecard[data-lane=chatgpt]", "class")
              and page.is_visible(".lanecard[data-lane=chatgpt] >> text=Easiest"))
        shot(page, "00b-lanes")
        page.click("#lane-continue")
        page.wait_for_selector("text=Let’s set up Briglia")
        check("first run shows the welcome screen", page.is_visible("text=Let’s start") and f.planned == "chatgpt" or f.planned is None)
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
        check("the corner Start/Stop isn't shown on the first run's finish screen", not page.is_visible("#power .pbtn"))
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
        check("a finished setup opens on the lanes home: the AI lanes first, other settings below",
              page.is_visible("text=Your AI lanes") and page.is_visible(".lanerow[data-lane-card=chatgpt] >> text=In use")
              and page.is_visible("#add-lane") and page.is_visible("text=Other settings") and page.is_visible(".grid") and not page.is_visible(".tile:has-text('ChatGPT')"))
        check("the lane in use offers Edit but neither Use nor Remove",
              page.is_visible("[data-edit=chatgpt]") and not page.is_visible("[data-use=chatgpt]") and not page.is_visible("[data-remove=chatgpt]"))
        check("the corner shows Briglia stopped, with Start and no Stop",
              page.is_visible("#power >> text=Stopped") and page.is_visible("#power-start") and not page.is_visible("#power-stop"))
        shot(page, "20-dashboard")
        page.click("[data-edit=chatgpt]")
        page.wait_for_selector(".choices")
        page.click(".choice:has-text('GPT-6 Luna')")
        page.wait_for_selector("text=Briglia now thinks with GPT-6 Luna.")
        check("a model can be changed with one click", g.chatgpt["model"] == "gpt-6-luna")
        shot(page, "21-dashboard-chatgpt")
        check("each thinking level shows its real name in small text, Deep (high) selected by default",
              page.inner_text(".seg button[data-effort=medium] .ename") == "Balanced" and page.inner_text(".seg button[data-effort=medium] .etech") == "medium"
              and page.inner_text(".seg button[data-effort=xhigh] .etech") == "xhigh" and page.is_visible(".seg button.on[data-effort=high]"))
        check("the corner Start/Stop stays visible on a settings screen", page.is_visible("#power-start"))
        page.click(".seg button[data-effort=xhigh]")
        page.wait_for_selector(".seg button.on[data-effort=xhigh]")
        check("the thinking level is one click", g.chatgpt["effort"] == "xhigh")
        page.click("text=← Your AI lanes")
        page.wait_for_selector(".grid")
        check("the dashboard says Briglia is stopped and has one Start (in the corner), no bottom Start/Stop",
              page.is_visible("text=Briglia is stopped") and page.locator("button:has-text('Start')").count() == 1 and page.locator("button:has-text('Stop')").count() == 0)
        shot(page, "22-dashboard-startstop")
        page.click("#power-start")
        page.wait_for_selector("text=Briglia is starting")
        check("corner Start starts Briglia", g.closing == "start")
        check("no page errors on the dashboard", not errors, errors)
        ctx.close()

        # ---- paused service (Linux): the corner offers Start and Stop ----
        ps = Fake(platform="linux")
        ps.service_was_running = True
        ps.name = "Sofia"; ps.chatgpt.update({"state": "signed_in", "active": True}); ps.telegram.update({"configured": True, "chat_id": "5551234567", "bot": "sofia_test_bot"})
        ps.keys.update({"serper": "srp-g…cdef", "jina": "jina_…cdef"}); ps.computer["fda"] = True; ps.tools.update({"complete": True, "missing": []})
        ctx, page, errors = session(ps)
        page.wait_for_selector(".grid")
        check("paused: the corner says Paused with Stop and Start", page.is_visible("#power >> text=Paused") and page.is_visible("#power-stop") and page.is_visible("#power-start"))
        page.click("#power-stop")
        check("paused: Stop asks once before acting", page.is_visible("#power >> text=Stop Briglia?") and ps.closing is None)
        page.click("#power >> text=Cancel")
        check("paused: Cancel keeps Briglia as it was", page.is_visible("#power-stop") and ps.closing is None)
        page.click("#power-stop"); page.click("#power-yes")
        page.wait_for_selector("h1:has-text('Briglia is stopped')")
        check("paused: confirmed Stop keeps it off and says so", ps.closing == "stop" and not errors, errors)
        ctx.close()

        # ---- Italian ----
        it = Fake()
        ctx, page, errors = session(it)
        page.wait_for_selector("text=Choose your language")
        page.click(".langcard:has-text('Italiano')")
        page.wait_for_selector("text=Come deve ragionare Briglia?")
        check("the AI choice is in Italian too", page.is_visible("text=Il più semplice"))
        page.click("#lane-continue")
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
        page.wait_for_selector("text=How should Briglia think?")
        overflow = page.evaluate("document.documentElement.scrollWidth > window.innerWidth + 1")
        check("no horizontal scrolling on the AI choice at phone width", not overflow)
        shot(page, "29b-phone-lanes")
        page.click("#lane-continue")
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
        page.wait_for_selector("text=How should Briglia think?")
        shot(page, "39-dark-lanes")
        page.click("#lane-continue")
        page.wait_for_selector("text=Let’s set up Briglia")
        page.click("text=See all settings")
        page.wait_for_selector(".grid")
        shot(page, "40-dark-dashboard")
        check("no page errors in dark mode", not errors, errors)
        ctx.close()

        # ---- live hub: the page served by a running Briglia ----
        lv = Fake(platform="linux")
        lv.running, lv.run_mode = True, "service"
        lv.name = "Sofia"; lv.chatgpt.update({"state": "signed_in", "active": True}); lv.telegram.update({"configured": True, "chat_id": "5551234567", "bot": "sofia_test_bot"})
        lv.keys.update({"serper": "srp-g…cdef", "jina": "jina_…cdef"}); lv.computer["fda"] = True; lv.tools.update({"complete": True, "missing": []})
        ctx, page, errors = session(lv)
        page.wait_for_selector("text=Briglia is running")
        check("live: the corner says Running, with Stop and no Start; the page offers Close",
              page.is_visible("#power >> text=Running") and page.is_visible("#power-stop") and not page.is_visible("#power-start") and page.is_visible("button:has-text('Close this page')"))
        shot(page, "70-live-dashboard")
        page.click("#steps button:has-text('Telegram')")
        page.wait_for_selector("text=Briglia is using this bot now")
        check("live: a different bot isn't offered while Briglia uses this one", not page.is_visible("text=Connect a different bot"))
        check("live: the corner Stop is there on a step screen too", page.is_visible("#power-stop"))
        page.click("text=← Back")
        page.click("#power-stop"); page.click("#power-yes")
        page.wait_for_selector("text=Stopping Briglia")
        check("live: Stop says Briglia is shutting down", lv.closing == "stop" and not errors, errors)
        ctx.close()

        # ---- OpenRouter lane: no OpenAI key needed (owner, 2026-09-25) ----
        orf = Fake()
        ctx, page, errors = session(orf)
        page.wait_for_selector("text=Choose your language")
        page.click(".langcard:has-text('English')")
        page.wait_for_selector("text=How should Briglia think?")
        page.click(".lanecard[data-lane=openrouter]")
        check("or: picking OpenRouter says no OpenAI key is needed",
              page.is_visible("text=no OpenAI key needed") and not page.is_visible("text=also need an OpenAI API key"))
        page.click("#lane-continue")
        page.wait_for_selector("text=Let’s set up Briglia")
        check("or: the welcome list asks for no OpenAI key",
              orf.planned == "openrouter" and page.is_visible("text=an OpenRouter account") and not page.is_visible("text=Briglia reads web pages with it"))
        check("or: the voice & images step is optional, not an 'OpenAI key' step",
              not page.is_visible("#steps li >> text=OpenAI key") and page.is_visible("#steps li >> text=Voice & images"))
        page.click("text=Let’s start")
        page.wait_for_selector("#f-name"); page.fill("#f-name", "Sofia"); page.click("button:has-text('Save')")
        page.wait_for_selector("text=Connect OpenRouter")
        page.fill("#f-ai", GOOD["openrouter"])
        page.wait_for_selector("text=Connect Telegram", timeout=6000)
        page.click("#steps button:has-text('Voice & images')")
        page.wait_for_selector("text=Working through OpenRouter")
        check("or: voice & images show as working through OpenRouter, no key asked",
              orf.active() == "openrouter" and page.is_visible("#openai-add") and not page.is_visible("#f-openai"))
        shot(page, "66-openrouter-media")
        page.click("#openai-add")
        page.wait_for_selector("#f-openai")
        check("or: an OpenAI key can still be added, and the choice can be cancelled", page.is_visible("button:has-text('Cancel')"))
        page.click("button:has-text('Cancel')")
        page.wait_for_selector("text=Working through OpenRouter")
        check("or: no page errors", not errors, errors)
        ctx.close()

        # ---- OpenCode lane, then switching and adding providers ----
        o = Fake()
        ctx, page, errors = session(o)
        page.wait_for_selector("text=Choose your language")
        page.click(".langcard:has-text('English')")
        page.wait_for_selector("text=How should Briglia think?")
        page.click(".lanecard[data-lane=opencode]")
        check("picking another lane says the OpenAI key is needed too", page.is_visible("text=also need an OpenAI API key"))
        page.click("#lane-continue")
        page.wait_for_selector("text=Let’s set up Briglia")
        check("the welcome lists what OpenCode needs, OpenAI key included",
              o.planned == "opencode" and page.is_visible("text=an OpenCode Go subscription") and page.is_visible("text=Briglia reads web pages with it"))
        check("the OpenAI key is a required step on this lane", page.is_visible("#steps li.todo >> text=OpenAI key"))
        shot(page, "60-opencode-welcome")
        page.click("text=Let’s start")
        page.wait_for_selector("#f-name"); page.fill("#f-name", "Sofia"); page.click("button:has-text('Save')")
        page.wait_for_selector("text=Connect OpenCode Go")
        shot(page, "61-opencode-key")
        page.fill("#f-ai", "oc-wrong-00000000000000")
        page.wait_for_selector("text=OpenCode Go refused this key", timeout=6000)
        page.fill("#f-ai", GOOD["opencode"])
        page.wait_for_selector("text=Connect Telegram", timeout=6000)
        check("a good OpenCode key is saved automatically and the setup moves on", o.active() == "opencode")
        page.click("#steps button:has-text('OpenCode Go')")
        page.wait_for_selector(".choice[data-model='kimi-k3']")
        page.click(".choice[data-model='kimi-k3']")
        page.wait_for_selector("text=Briglia now thinks with Kimi K3 on OpenCode Go.")
        page.click(".seg button[data-effort=medium]")
        page.wait_for_selector(".seg button.on[data-effort=medium]")
        check("model and thinking level change with one click each", o.providers["opencode"]["model"] == "kimi-k3" and o.providers["opencode"]["effort"] == "medium")
        shot(page, "62-opencode-settings")
        page.click("text=← Your AI lanes")
        page.wait_for_selector("#add-lane")
        check("the lanes home lists OpenCode Go in use, with its model",
              page.is_visible(".lanerow[data-lane-card=opencode] >> text=In use") and page.is_visible(".lanerow[data-lane-card=opencode] >> text=Kimi K3"))
        page.click("#add-lane")
        page.wait_for_selector("h1:has-text('Add a lane')")
        check("Add a lane offers the four kinds; a built-in already added can't be added twice",
              page.locator(".lanecard").count() == 4 and page.is_disabled(".lanecard[data-lane=opencode]") and page.is_visible(".lanecard[data-lane=opencode] >> text=Added")
              and page.is_enabled(".lanecard[data-lane=local]"))
        shot(page, "63-add-lane")
        page.click(".lanecard[data-lane=openrouter]")
        page.wait_for_selector("h1:has-text('Connect OpenRouter')")
        check("adding OpenRouter keeps OpenCode running until it's set up", page.is_visible("text=Briglia keeps using OpenCode Go"))
        page.fill("#f-ai", GOOD["openrouter"])
        page.wait_for_selector("text=Briglia now thinks with deepseek/deepseek-v4.1-flash on OpenRouter.", timeout=6000)
        check("an OpenRouter key switches Briglia to OpenRouter", o.active() == "openrouter")
        page.fill("#f-or-model", "moonshotai/kimi-k3")
        page.click("button:has-text('Use this model')")
        page.wait_for_selector("text=Briglia now thinks with moonshotai/kimi-k3 on OpenRouter.")
        shot(page, "64-openrouter")
        # A server on this computer, named.
        page.click("text=← Your AI lanes")
        page.click("#add-lane")
        page.click(".lanecard[data-lane=local]")
        page.wait_for_selector("h1:has-text('Add a server')")
        check("the new server's address starts at LM Studio's default", page.input_value("#f-srv-url") == "http://localhost:1234/v1")
        check("the optional API key field hides what's typed", page.get_attribute("#f-local-key", "type") == "password" and page.input_value("#f-local-key") == "")
        check("Add is disabled until a model is picked and the server is named", page.is_disabled("#srv-save"))
        page.click("button:has-text('Find models')")
        page.wait_for_selector(".choice[data-model='gemma-4-12b']")
        lm = [c for c in o.calls if c.get("action") == "local_models"]
        check("without a key, Find models sends an empty key and no server id (new server)", lm and lm[-1].get("api_key") == "" and lm[-1].get("server_id") == "")
        page.click(".choice[data-model='gemma-4-12b']")
        page.fill("#f-srv-name", "Home GPU")
        shot(page, "65-server-new")
        page.click("#srv-save")
        page.wait_for_selector("text=Added Home GPU.")
        sv = [c for c in o.calls if c.get("action") == "server_save"][-1]
        check("the server is saved with its name, address and model, and runs",
              sv.get("name") == "Home GPU" and sv.get("base_url") == "http://localhost:1234/v1" and sv.get("model") == "gemma-4-12b" and sv.get("id") == ""
              and o.active() == "local" and page.is_visible(".lanerow[data-lane-card^='srv:'] >> text=Home GPU"))
        # A second server, online, with a key.
        page.click("#add-lane")
        page.click(".lanecard[data-lane=local]")
        page.wait_for_selector("h1:has-text('Add a server')")
        page.fill("#f-srv-url", "https://api.example.com/v1")
        page.fill("#f-local-key", "sk-fake-server-key-123")
        page.click("button:has-text('Find models')")
        page.wait_for_selector(".choice[data-model='qwen3.8-27b']")
        lm = [c for c in o.calls if c.get("action") == "local_models"]
        check("a typed key goes with Find models", lm[-1].get("api_key") == "sk-fake-server-key-123")
        page.click(".choice[data-model='qwen3.8-27b']")
        page.fill("#f-srv-name", "Acme cloud")
        page.click("#srv-save")
        page.wait_for_selector("text=Added Acme cloud.")
        check("the page never shows the typed key back", "sk-fake-server-key-123" not in page.content())
        check("each server is its own card; the one in use is marked",
              page.locator(".lanerow[data-lane-card^='srv:']").count() == 2 and page.is_visible(".lanerow.active >> text=Acme cloud"))
        shot(page, "66-lanes-home")
        # Edit a server that isn't in use: rename it.
        home = [x for x in o.servers if x["name"] == "Home GPU"][0]
        page.click("[data-edit='srv:%s']" % home["id"])
        page.wait_for_selector("h1:has-text('Home GPU')")
        check("editing a server shows its saved model selected and its name", page.is_visible(".choice.sel[data-model='gemma-4-12b']") and page.input_value("#f-srv-name") == "Home GPU")
        page.fill("#f-srv-name", "Home box")
        shot(page, "67-server-edit")
        page.click("#srv-save")
        page.wait_for_selector(".notice.ok >> text=Saved.")
        sv = [c for c in o.calls if c.get("action") == "server_save"][-1]
        check("a rename is saved on that server, keeping its address and model",
              sv.get("id") == home["id"] and sv.get("name") == "Home box" and sv.get("model") == "gemma-4-12b" and home["name"] == "Home box")
        page.click("text=← Your AI lanes")
        # Remove: refused for the one in use (no button), asks once for another.
        acme = [x for x in o.servers if x["name"] == "Acme cloud"][0]
        check("the server in use has no Remove button", not page.is_visible("[data-remove='srv:%s']" % acme["id"]))
        page.click("[data-remove='srv:%s']" % home["id"])
        check("Remove asks once before acting", page.is_visible("text=Remove Home box?") and len(o.servers) == 2)
        page.click("[data-confirm-remove='srv:%s']" % home["id"])
        page.wait_for_selector("text=Home box removed.")
        check("a confirmed Remove deletes the server", [x["name"] for x in o.servers] == ["Acme cloud"])
        # Use: back to a saved built-in lane in one click.
        page.click("[data-use=opencode]")
        page.wait_for_selector(".lanerow[data-lane-card=opencode] >> text=In use")
        check("Use switches back to a saved lane in one click", o.active() == "opencode")
        overflow = page.evaluate("document.documentElement.scrollWidth > window.innerWidth + 1")
        check("no page errors or overflow while managing lanes", not errors and not overflow, errors)
        ctx.close()

        # ---- lanes home at phone width, in both languages ----
        for lang, name in (("en", "81-phone-lanes-en"), ("it", "82-phone-lanes-it")):
            pf = Fake()
            pf.lang = lang
            pf.name = "Sofia"; pf.chatgpt.update({"state": "signed_in", "active": False}); pf.telegram.update({"configured": True, "chat_id": "5551234567", "bot": "sofia_test_bot"})
            pf.keys.update({"serper": "srp-g…cdef", "jina": "jina_…cdef", "openai": "sk-go…cdef"}); pf.computer["fda"] = True; pf.tools.update({"complete": True, "missing": []})
            pf.providers["openrouter"].update({"configured": True, "model": "deepseek/deepseek-v4.1-flash", "model_label": "deepseek/deepseek-v4.1-flash", "key": "sk-or…cdef"})
            pf.servers = [{"id": "srv-0001", "name": "Home GPU", "endpoint": "http://localhost:1234/v1", "model": "qwen3.8-27b", "keyed": False, "key": None, "text_only": False, "effort": ""},
                          {"id": "srv-0002", "name": "Acme cloud", "endpoint": "https://api.example.com/v1", "model": "acme-large", "keyed": True, "key": "sk-ac…9xyz", "text_only": False, "effort": "high"}]
            pf.use("local", "srv-0002")
            ctx, page, errors = session(pf, width=390, height=844)
            page.wait_for_selector("#add-lane")
            overflow = page.evaluate("document.documentElement.scrollWidth > window.innerWidth + 1")
            check("phone (%s): the lanes home fits without sideways scrolling" % lang, not overflow and page.locator(".lanerow").count() == 4)
            if lang == "it":
                check("phone (it): the lanes home is in Italian", page.is_visible("text=I tuoi fornitori AI") and page.is_visible("text=Aggiungi un fornitore") and page.is_visible(".lanerow.active >> text=In uso"))
            shot(page, name)
            if lang == "en":
                page.click("#add-lane")
                page.wait_for_selector("h1:has-text('Add a lane')")
                shot(page, "83-phone-add-lane")
                page.click("text=← Your AI lanes")
                page.click("[data-edit='srv:srv-0002']")
                page.wait_for_selector("h1:has-text('Acme cloud')")
                check("phone: the server edit form fits", not page.evaluate("document.documentElement.scrollWidth > window.innerWidth + 1"))
                shot(page, "84-phone-server-edit")
            check("phone (%s): no page errors" % lang, not errors, errors)
            ctx.close()

        # ---- Linux start failure (Codex R3): shown on the page with Retry,
        # never "running in the background" before the service is healthy.
        lf = Fake(platform="linux")
        lf.name = "Sofia"
        lf.chatgpt.update({"state": "signed_in", "active": True})
        lf.telegram.update({"configured": True, "chat_id": "5551234567", "bot": "sofia_test_bot"})
        lf.keys.update({"serper": "srp-…cdef", "jina": "jina_…cdef"})
        lf.computer.update({"fda": True})
        lf.tools.update({"complete": True, "missing": []})
        ctx, page, errors = session(lf)
        page.wait_for_selector("#power-start")
        page.click("#power-start")
        page.wait_for_selector("text=Briglia didn’t start")
        check("Linux: a failed start stays on the page with the reason",
              page.is_visible("text=stability window") and page.is_visible("button:has-text('Try again')") and not page.is_visible("text=runs in the background now"))
        shot(page, "50-linux-start-failed")
        page.click("button:has-text('Try again')")
        page.wait_for_selector("text=Briglia is starting")
        check("Linux: Retry that succeeds shows the running page", page.is_visible("text=It runs in the background now") and not errors, errors)
        ctx.close()

        # ---- auto-check races (Codex R2): a value edited while its check
        # runs is never lost; old replies show nothing; other fields still
        # submit. Key POSTs are held until the test releases them; like the
        # real server, a newer key for the same service supersedes an older
        # pending one.
        def race_session():
            rf = Fake()
            rf.name = "Sofia"
            rf.chatgpt.update({"state": "signed_in", "active": True})
            rf.telegram.update({"configured": True, "chat_id": "5551234567", "bot": "sofia_test_bot"})
            rf.keys["jina"] = "jina_…cdef"
            rf.computer["fda"] = True
            rf.tools.update({"complete": True, "missing": []})
            held, rev = [], {}
            ctx = browser.new_context(viewport={"width": 1280, "height": 860})
            page = ctx.new_page()
            errors = []
            page.on("pageerror", lambda e: errors.append(str(e)))

            def api(route):
                if route.request.url.endswith("/api/menu/status"):
                    route.fulfill(status=200, content_type="application/json", body=json.dumps(rf.status()))
                    return
                body = route.request.post_data_json or {}
                rf.calls.append(body)
                if body.get("action") != "key":
                    route.fulfill(status=200, content_type="application/json", body=json.dumps(rf.act(body)))
                    return
                rev[body["kind"]] = rev.get(body["kind"], 0) + 1
                held.append((route, body, rev[body["kind"]]))

            def release(key):
                for i, (route, body, mine) in enumerate(held):
                    if body["key"] != key:
                        continue
                    held.pop(i)
                    kind = body["key"] and body["kind"]
                    if rev[kind] != mine:
                        out = {"ok": False, "superseded": True, "status": rf.status()}
                    elif "BAD" in key:
                        out = {"ok": False, "message": "Serper refused this key. Make sure you copied the whole key, then paste it again.", "status": rf.status()}
                    else:
                        rf.keys[kind] = key[:4] + "…" + key[-4:]
                        out = {"ok": True, "message": "Web search is on.", "status": rf.status()}
                    route.fulfill(status=200, content_type="application/json", body=json.dumps(out))
                    return

            def wait_held(n):
                for _ in range(300):
                    if len(held) >= n:
                        return True
                    page.wait_for_timeout(10)
                return False

            page.route("**/api/**", api)
            page.goto(base)
            page.click("#steps button:has-text('Web search')")
            page.wait_for_selector("#f-serper")
            return rf, ctx, page, errors, release, wait_held

        def sent(rf, kind="serper"):
            return [c["key"] for c in rf.calls if c.get("action") == "key" and c.get("kind") == kind]

        first, second, bad = "srp-FIRST-0123456789", "srp-SECOND-9876543210", "srp-BAD-0123456789"
        # Codex's exact case: edit during the check, old reply arrives last.
        rf, ctx, page, errors, release, wait_held = race_session()
        page.fill("#f-serper", first); page.press("#f-serper", "Enter")
        wait_held(1)
        page.fill("#f-serper", second)
        check("race: a value edited during a check is sent too", wait_held(2) and sent(rf) == [first, second], sent(rf))
        release(second); page.wait_for_timeout(200)
        release(first); page.wait_for_timeout(600)
        check("race: the newer key is the one saved and shown", rf.keys["serper"] == "srp-…3210" and page.is_visible("text=Key saved") and not page.is_visible("#f-serper"), rf.keys)
        check("race: the old reply shows no message", not page.is_visible(".notice.bad"))
        ctx.close()
        # Old reply arrives first, before the new value's check is sent.
        rf, ctx, page, errors, release, wait_held = race_session()
        page.fill("#f-serper", first); page.press("#f-serper", "Enter")
        wait_held(1)
        page.fill("#f-serper", second)
        page.wait_for_timeout(150)
        release(first)
        page.wait_for_timeout(150)
        check("race: an old success doesn't clear the newer value", page.is_visible("#f-serper") and page.input_value("#f-serper") == second)
        check("race: the newer value is then checked by itself", wait_held(1) and sent(rf) == [first, second], sent(rf))
        release(second); page.wait_for_timeout(600)
        check("race: …and saved", rf.keys["serper"] == "srp-…3210" and page.is_visible("text=Key saved"), rf.keys)
        ctx.close()
        # The old value is refused while a newer one is typed.
        rf, ctx, page, errors, release, wait_held = race_session()
        page.fill("#f-serper", bad); page.press("#f-serper", "Enter")
        wait_held(1)
        page.fill("#f-serper", second)
        page.wait_for_timeout(150)
        release(bad); page.wait_for_timeout(150)
        check("race: an old refusal isn't shown over a newer value", not page.is_visible(".notice.bad") and page.input_value("#f-serper") == second)
        wait_held(1); release(second); page.wait_for_timeout(600)
        check("race: the newer value is saved after an old refusal", rf.keys["serper"] == "srp-…3210", rf.keys)
        ctx.close()
        # Another field typed while a check runs still submits by itself.
        rf, ctx, page, errors, release, wait_held = race_session()
        page.fill("#f-serper", second); page.press("#f-serper", "Enter")
        wait_held(1)
        page.click("#steps button:has-text('Voice & images')")
        page.fill("#f-openai", GOOD["openai"])
        check("race: another field auto-submits while a check runs", wait_held(2) and sent(rf, "openai") == [GOOD["openai"]], rf.calls)
        release(second); release(GOOD["openai"]); page.wait_for_timeout(300)
        check("race: no page errors", not errors, errors)
        ctx.close()
        browser.close()
    server.shutdown()
    print("\nmenu browser test: " + ("all checks passed" if not FAILS else "%d FAILED" % len(FAILS)))
    raise SystemExit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
