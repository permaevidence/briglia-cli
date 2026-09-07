#!/usr/bin/env python3
"""Browser behavior with fake UI responses; native workflow/auth are Swift tests."""
import http.server
import json
import threading
from pathlib import Path
from playwright.sync_api import sync_playwright

root = Path(__file__).resolve().parents[1] / 'TelegramConcierge/Resources/QuickSetup'
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs): super().__init__(*args, directory=str(root), **kwargs)
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
state = {'signed': False, 'cancelled': False, 'polls': 0, 'verified': None}
generation = '98d8f20b-5905-446f-b4f0-ab944c95f7fd'
try:
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        page = browser.new_page()
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        def api(route):
            path = route.request.url.split('/api/')[-1]
            req = route.request.post_data_json or {} if route.request.method == 'POST' else {}
            result = {'ok': True}
            if path == 'status': result = {'phase': 'intro', 'kept': [], 'rows': [], 'stored_name': ''}
            elif path == 'subscription':
                action = req['action']
                if action == 'status': result.update(state='signed_in' if state['signed'] else 'signed_out', generation=generation if state['signed'] else '')
                elif action == 'start': result.update(state='pending', pending='opaque-id', code='<b>ABCD</b>', interval=1)
                elif action == 'poll':
                    state['polls'] += 1
                    if state['polls'] == 1:
                        route.fulfill(status=409, content_type='application/json', body=json.dumps({'ok':False,'error':'busy'})); return
                    if state['polls'] == 2:
                        route.fulfill(status=503, content_type='application/json', body=json.dumps({'ok':False,'error':{'message':'temporary'}})); return
                    if state['polls'] == 3:
                        route.fulfill(status=200, content_type='application/json', body=json.dumps({'ok':False,'error':{'message':'retry transport','retryable':True}})); return
                    state['signed'] = True
                    result.update(state='signed_in')
                elif action == 'logout': state['signed'] = False; result.update(state='signed_out')
                elif action == 'cancel': state['cancelled'] = True; result.update(state='cancelled')
            elif path == 'verify':
                state['verified'] = req
                result = {'phase': 'verified', 'rows': []}
            route.fulfill(status=200, content_type='application/json', body=json.dumps(result))
        page.route('**/api/**', api)
        page.goto('http://127.0.0.1:%s/index.html' % server.server_address[1])
        page.select_option('#main-provider', 'chatgpt')
        assert page.locator('#subscription-panel').is_visible()
        assert page.locator('#f-opencode').count() == 0
        page.click('#subscription-start')
        page.wait_for_function("document.getElementById('subscription-code').textContent.includes('ABCD')")
        assert page.locator('#subscription-code b').count() == 0, 'code must render as inert text'
        page.wait_for_function("document.getElementById('subscription-status').textContent.startsWith('Signed in')")
        assert state['polls'] == 4, 'busy and transient polls must resume automatically'
        page.fill('#f-name', 'Fixture')
        for key in ['openai', 'serper', 'jina', 'telegram_token', 'telegram_chat']:
            page.fill('#f-' + key, '123' if key == 'telegram_chat' else 'synthetic')
        assert page.locator('#subscription-model-choice').input_value() == 'gpt-5.6-luna'
        assert page.locator('#subscription-effort').input_value() == 'high'
        for model in ['gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-6-astra']:
            page.select_option('#subscription-model-choice', model)
            assert page.locator('#subscription-model').input_value() == model
            assert page.locator('#subscription-custom-model-row').is_hidden()
            efforts = page.locator('#subscription-effort option').evaluate_all('(options) => options.map(o => o.value)')
            assert 'high' in efforts and 'max' in efforts and 'ultra' not in efforts
            assert ('none' in efforts) == (model != 'gpt-6-astra')
        page.select_option('#subscription-model-choice', 'custom')
        assert page.locator('#subscription-custom-model-row').is_visible()
        page.fill('#subscription-model', 'custom-fixture-model')
        assert page.locator('#subscription-effort option[value="max"]').count() == 0
        page.select_option('#subscription-model-choice', 'gpt-6-astra')
        page.select_option('#subscription-effort', 'max')
        page.click('#btn-verify')
        page.wait_for_timeout(100)
        req = state['verified']
        assert req['chatgpt'] == {'model': 'gpt-6-astra', 'effort': 'max', 'generation': generation}
        assert 'opencode' not in req and req['openai']['value'] == 'synthetic'
        assert not errors, errors
        browser.close()
finally: server.shutdown()
print('Subscription browser: login, polling, inert code, model/effort choices, alternate provider and API-tool separation PASS')
