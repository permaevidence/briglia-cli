#!/usr/bin/env python3
"""Execute the shipped UT 0.8.4 bridge against captured CLI status.

Future-field samples are compatibility fixtures, not actual P2 status evidence.
Re-run with candidate status after P2 exists. No subprocess, install or network.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

FIXTURE = Path(__file__).resolve().parent / "fixtures/chat-lifecycle/ut-0.8.4"


def check_status(path):
    provenance = json.loads((FIXTURE / 'provenance.json').read_text())
    assert provenance['commit'] == '3b6b8ef8db980599a9b526a95607c3b000c462a7'
    for name, expected in provenance['files'].items():
        assert hashlib.sha256((FIXTURE / name).read_bytes()).hexdigest() == expected, name
    sys.path.insert(0, str(FIXTURE))
    spec = importlib.util.spec_from_file_location('pinned_ut_bridge', FIXTURE / 'briglia_bridge.py')
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    original = json.loads(Path(path).read_text())
    assert original['ok'] and original['schema'] == 2
    assert original['providers']['profiles'], 'No actual provider status captured'
    samples = [('actual-p0', original)]
    additive = copy.deepcopy(original)
    additive['providers']['profiles']['responses_fixture'] = {
        'configured': True, 'model': 'synthetic-model', 'protocol': 'responses',
        'auth': 'apiKey', 'text_only': False}
    additive['providers']['profiles']['subscription_fixture'] = {
        'configured': False, 'model': 'synthetic-model', 'protocol': 'responses',
        'auth': 'chatGPTSubscription', 'login_state': 'signed_out'}
    additive['providers']['active'] = 'responses_fixture'
    samples.append(('anticipated-additive-fields', additive))
    for label, payload in samples:
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            if argv[-1] == '--version': return 0, '0.2.9-dev', ''
            if argv[-1] == 'bundle-check': return 0, 'OK', ''
            assert argv[-2:] == ['setup-api', 'status']
            return 0, json.dumps(payload), ''
        bridge._run = run
        assert bridge.setup_api('status') == payload, label
        version, error = bridge._validate_staged('/fixture/briglia')
        assert version == '0.2.9-dev' and error is None, (label, error)
        assert len(calls) == 4, calls
    bridge._run = lambda *a, **k: (0, json.dumps(dict(original, schema=3)), '')
    assert bridge.setup_api('status')['error']['code'] == 'schema_mismatch'
    bridge._run = lambda *a, **k: (0, '{broken', '')
    assert bridge.setup_api('status')['error']['code'] == 'no_response'
    print('Pinned UT 0.8.4 bridge: actual + anticipated additive status and rejection checks PASS')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('status', type=Path)
    check_status(parser.parse_args().status)
