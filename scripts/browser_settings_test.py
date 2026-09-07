#!/usr/bin/env python3
"""Real browser + HTTP + persistence test of repeatable Quick Setup.
All credentials are fixtures; the sole provider is a local HTTP mock.
"""
import http.server
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from playwright.sync_api import sync_playwright

BINARY = str(Path(sys.argv[1]).resolve())

class Provider(http.server.BaseHTTPRequestHandler):
    models = []
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.models.append(body.get('model'))
        ok = self.headers.get('Authorization') == 'Bearer fixture-key'
        data = json.dumps({'choices': [{'message': {'content': 'OK'}}]} if ok else {'error': {'message': 'Invalid fixture key'}}).encode()
        self.send_response(200 if ok else 401)
        self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *args): pass

def run():
    with tempfile.TemporaryDirectory(prefix='briglia-bs-', dir='/tmp') as tmp:
        root = Path(tmp)
        config = root / 'config' / 'briglia'
        config.mkdir(parents=True)
        secrets = config / 'secrets.json'
        original = {'cli_setup_complete': 'true', 'telegram_bot_token': 'preserved-bot',
                    'active_provider_profile': 'opencode', 'opencode_api_key': 'preserved-key',
                    'opencode_model': 'old-model', 'opencode_reasoning_effort': 'high'}
        secrets.write_text(json.dumps(original)); secrets.chmod(0o600)
        env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
                   XDG_CACHE_HOME=str(root / 'cache'), BRIGLIA_IGNORE_LEGACY_SETUP_FLAG='1', BRIGLIA_QUICKSETUP_NO_BROWSER='1')
        mock = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        threading.Thread(target=mock.serve_forever, daemon=True).start()
        process = subprocess.Popen([BINARY, 'quicksetup'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        output = []
        def read():
            for line in process.stdout: output.append(line)
        threading.Thread(target=read, daemon=True).start()
        def launch_link(previous=None):
            until = time.time() + 30
            while time.time() < until:
                links = re.findall(r'http://127\.0\.0\.1:\d+/start\?t=[0-9a-f]{32}', ''.join(output))
                if links and links[-1] != previous: return links[-1]
                if process.poll() is not None: break
                time.sleep(.05)
            raise AssertionError('No launch link: ' + ''.join(output)[-1200:])
        try:
            link = launch_link()
            with sync_playwright() as pw:
                browser = pw.chromium.launch(headless=True)
                context = browser.new_context()
                page = context.new_page()
                errors = []
                page.on('pageerror', lambda e: errors.append(str(e)))
                if '--negative-control' in sys.argv:
                    old_js = subprocess.check_output(['git', 'show', 'a28e22b:TelegramConcierge/Resources/QuickSetup/settings.js'], text=True)
                    page.route('**/settings.js', lambda route: route.fulfill(content_type='application/javascript', body=old_js))
                page.goto(link)
                page.locator('#provider option').last.wait_for(state='attached')
                assert page.title() == 'Briglia · Settings'
                assert page.locator('#provider option').count() == 6
                assert 'stopped' in page.locator('#runtime').inner_text()
                assert page.locator('#key').input_value() == ''
                assert 'preserved-key' not in page.content()
                # Reconfiguration cannot invoke installer/finish routes, even
                # with a valid settings cookie.
                forbidden = context.request.post(page.url + 'api/finish', data='{}', headers={'Content-Type': 'application/json', 'X-Briglia-Quick-Setup': '1', 'Origin': page.url.rstrip('/')})
                assert forbidden.status == 404
                foreign = context.request.post(page.url + 'api/save', data='{}', headers={'Content-Type': 'application/json', 'X-Briglia-Quick-Setup': '1', 'Origin': 'https://example.invalid'})
                assert foreign.status == 403
                print('PASS existing installation opens settings without installation preflight')
                page.select_option('#provider', 'custom')
                page.fill('#endpoint', f'http://127.0.0.1:{mock.server_port}/v1')
                page.fill('#model', 'chosen-model')
                page.fill('#key', 'wrong-key')
                page.click('#verify-provider')
                page.locator('#banner.error').wait_for()
                assert page.locator('#save-provider').is_disabled()
                assert json.loads(secrets.read_text()) == original
                print('PASS invalid credentials do not change storage')
                page.fill('#key', 'fixture-key')
                page.click('#verify-provider')
                page.locator('#save-provider:enabled').wait_for()
                page.fill('#model', 'edited-model')
                assert page.locator('#save-provider').is_disabled()
                # The server rejects a direct API bypass as well as the UI.
                bypass = page.evaluate("""async () => { const r=await fetch('/api/save',{method:'POST',headers:{'Content-Type':'application/json','X-Briglia-Quick-Setup':'1'},body:JSON.stringify({section:'provider',values:{profile:'custom',api_key:'fixture-key',base_url:document.querySelector('#endpoint').value,model:'edited-model',effort:'high',text_only:true,activate:false,protocol:'chatCompletions',native_tool_media:true}})}); return r.status; }""")
                assert bypass == 409
                page.click('#verify-provider'); page.locator('#save-provider:enabled').wait_for(); page.click('#save-provider')
                page.locator('#banner').filter(has_text='Saved.').wait_for()
                disk = json.loads(secrets.read_text())
                assert disk['custom_endpoint_model'] == 'edited-model'
                assert disk['custom_endpoint_api_key'] == 'fixture-key'
                assert disk['active_provider_profile'] == 'opencode'
                assert disk['telegram_bot_token'] == 'preserved-bot'
                assert disk['cli_setup_complete'] == 'true'
                print('PASS independent provider add, exact model probe, unchanged active provider and pairing')
                page.reload(); page.locator('#provider option').last.wait_for(state='attached'); page.select_option('#provider', 'custom')
                assert page.locator('#key').input_value() == ''
                page.check('#activate'); page.fill('#model', 'next-model')
                page.click('#verify-provider'); page.locator('#save-provider:enabled').wait_for(); page.click('#save-provider')
                page.locator('#banner').filter(has_text='Saved.').wait_for()
                disk = json.loads(secrets.read_text())
                assert disk['active_provider_profile'] == 'custom'
                assert disk['custom_endpoint_api_key'] == 'fixture-key'
                assert disk['openai_compatible_model'] == 'next-model'
                assert 'next-model' in Provider.models
                print('PASS model-only edit retains key and activates profile')
                # Mock only account HTTP results to exercise the actual browser
                # device-poll UI under busy and retryable failures.
                polls = []
                mode = ['busy']
                def account(route):
                    body = route.request.post_data_json
                    action = body['action']
                    data = {'ok': True, 'state': 'signed_out', 'generation': ''}
                    status = 200
                    if action == 'start': data = {'ok': True, 'state': 'pending', 'pending': 'opaque-fixture', 'code': 'ABCD-EFGH', 'url': 'https://auth.openai.com/codex/device', 'interval': 1, 'expires_in': 3 if mode[0] == 'expiry' else 900}
                    elif action == 'poll':
                        polls.append(body['pending'])
                        if mode[0] == 'transport': status, data = 400, {'ok': False, 'error': {'message': 'Temporary connection error', 'retryable': True}}
                        elif mode[0] == 'fatal': status, data = 400, {'ok': False, 'error': {'message': 'Login denied', 'retryable': False}}
                        elif mode[0] == 'expiry' or len(polls) <= 15:
                            status, data = 409, {'ok': False, 'error': 'agent_busy' if len(polls) % 2 else 'busy'}
                        elif len(polls) == 16: status, data = 400, {'ok': False, 'error': {'message': 'Temporary connection error', 'retryable': True}}
                        else: data = {'ok': True, 'state': 'signed_in'}
                    elif action == 'status' and mode[0] == 'busy' and len(polls) >= 17: data = {'ok': True, 'state': 'signed_in', 'generation': 'fixture-generation'}
                    route.fulfill(status=status, content_type='application/json', body=json.dumps(data))
                # The owner is running for this scenario; only account transport
                # is stubbed. The real workflow/barrier is covered by selftests.
                def running_status(route):
                    response = route.fetch()
                    data = response.json(); data['running'] = True; data['active'] = 'chatgpt'
                    route.fulfill(response=response, json=data)
                page.route('**/api/status', running_status)
                page.route('**/api/subscription', account)
                page.reload(); page.locator('#provider option').last.wait_for(state='attached')
                page.select_option('#provider', 'chatgpt')
                assert 'running' in page.locator('#runtime').inner_text()
                if '--negative-control' not in sys.argv:
                    assert page.locator('#logout-warning').is_visible()
                assert page.locator('#effort option[value="ultra"]').count() == 0
                page.clock.install()
                def start_login():
                    page.click('#login'); page.locator('#login-code').wait_for(state='visible')
                def tick_until(predicate, limit=100):
                    for _ in range(limit):
                        page.clock.run_for(1000)
                        page.wait_for_timeout(25)
                        if predicate(): return
                    raise AssertionError('Polling did not reach expected state: ' + page.locator('#account-status').inner_text())
                start_login()
                tick_until(lambda: len(polls) >= 15 or 'Automatic retries stopped' in page.locator('#account-status').inner_text())
                assert len(polls) >= 15, 'Busy responses exhausted the retry allowance'
                assert 'Briglia is busy' in page.locator('#account-status').inner_text()
                tick_until(lambda: 'Signed in.' in page.locator('#account-status').inner_text())
                assert polls == ['opaque-fixture'] * 17
                print('PASS running owner busy beyond 12 polls, then transport retry and successful same-handle login')
                mode[0] = 'transport'; polls.clear(); start_login()
                tick_until(lambda: 'Automatic retries stopped' in page.locator('#account-status').inner_text())
                assert polls == ['opaque-fixture'] * 13
                page.clock.run_for(30000); page.wait_for_timeout(50)
                assert len(polls) == 13
                page.click('#cancel'); page.locator('#login:enabled').wait_for()
                print('PASS persistent connection failures retain the bounded 12-retry allowance')
                mode[0] = 'expiry'; polls.clear(); start_login()
                tick_until(lambda: 'Sign-in code expired' in page.locator('#account-status').inner_text())
                assert len(polls) <= 2
                assert page.locator('#login').is_enabled()
                count = len(polls); page.clock.run_for(10000); page.wait_for_timeout(50)
                assert len(polls) == count
                print('PASS busy polling stops at code expiry and offers a new login')
                mode[0] = 'fatal'; polls.clear(); start_login()
                tick_until(lambda: 'Sign-in failed' in page.locator('#account-status').inner_text())
                assert len(polls) == 1 and page.locator('#login').is_enabled()
                page.clock.run_for(10000); page.wait_for_timeout(50)
                assert len(polls) == 1
                print('PASS terminal account failure does not retry')
                page.unroute('**/api/status', running_status)
                # Re-open command rotates authorization, but never undoes saves.
                process.stdin.write('\n'); process.stdin.flush()
                new_link = launch_link(link)
                page.reload()
                assert page.locator('body').inner_text().strip() == '' or '404' in page.content()
                page.goto(new_link); page.locator('#provider option').last.wait_for(state='attached')
                assert page.locator('#provider').input_value() == 'custom'
                assert not errors, errors
                assert secrets.stat().st_mode & 0o777 == 0o600
                print('PASS reload, link revocation, retained settings, private file permissions and no JS errors')
                page.screenshot(path='/tmp/briglia-settings-preview.png', full_page=True)
                browser.close()
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try: process.wait(timeout=50)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            mock.shutdown()
        assert process.returncode == 0, ''.join(output)[-1000:]
        print('PASS clean settings shutdown')

if __name__ == '__main__': run()
