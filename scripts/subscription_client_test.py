#!/usr/bin/env python3
"""Configured ChatGPT status through the unmodified shipped UT 0.8.4 bridge."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid
import chat_lifecycle_client_test

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='briglia-subscription-client-') as scratch:
    root = Path(scratch)
    env = dict(os.environ)
    for key, child in [('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'), ('XDG_CACHE_HOME', 'cache')]:
        env[key] = str(root / child)
    config = root / 'config/briglia'
    config.mkdir(parents=True, mode=0o700)
    auth = config / 'subscription-auth.json'
    # Synthetic test-only tokens; Foundation dates count from 2001-01-01.
    expires = (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds() + 3600
    auth.write_text(json.dumps(dict(version=1, generation=str(uuid.uuid4()), credential=dict(access='synthetic-access', refresh='synthetic-refresh', expires=expires, account='fixture-account'))))
    auth.chmod(0o600)
    subprocess.run([binary, 'subscription', 'select', '--model', 'gpt-5.6-sol', '--effort', 'medium'], env=env, check=True, capture_output=True)
    status = json.loads(subprocess.check_output([binary, 'setup-api', 'status'], env=env))
    profile = status['providers']['profiles']['chatgpt']
    assert profile['configured'] and profile['capabilities']['auth'] == 'oauth'
    assert status['providers']['active'] == 'chatgpt'
    assert status['subscription_setup']['supported']
    target = root / 'status.json'; target.write_text(json.dumps(status))
    chat_lifecycle_client_test.check_status(target)
    def api(request):
        return json.loads(subprocess.check_output([binary, 'setup-api', 'subscription'], input=json.dumps(request).encode(), env=env))
    assert api({'action': 'status'})['model'] == 'gpt-5.6-sol'
    assert api({'action': 'select', 'activate': True})['effort'] == 'medium', 'default settings must be retained'
    assert api({'action': 'logout'})['ok']
    assert api({'action': 'status'})['state'] == 'signed_out'
    assert not api({'action': 'select'})['ok']
    # cancel/logout must not reject irrelevant effort flags.
    subprocess.run([binary, 'subscription', 'logout', '--effort', 'not-an-effort'], env=env, check=True, capture_output=True)
print('Configured subscription client compatibility PASS')
