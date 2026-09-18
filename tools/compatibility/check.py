"""Exercise the mobile adapter against a real, isolated Hermes checkout.

Run from the Hermes checkout with its dependencies installed. No model calls:
agent construction is disabled and outbound socket connections are denied.
"""
import itertools
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
from unittest.mock import patch

root = Path.cwd()
assert (root / 'tui_gateway/server.py').is_file(), 'Run from a Hermes checkout'
assert not (root / '.env').exists(), 'Use a fresh checkout without credentials'
home = tempfile.TemporaryDirectory(prefix='jr-compat-home-')
os.environ['HERMES_HOME'] = home.name
os.environ['HERMES_TEST_ISOLATION'] = '1'
# CI has no model credentials; prevent accidental network calls even if that changes.
def denied(*args, **kwargs):
    raise AssertionError('Compatibility tests must not call external services')
socket.socket.connect = denied
socket.create_connection = denied
sys.path.insert(0, str(root))
from hermes_jr.mobile import MobileAdapter, PREFIX
from tui_gateway import server

adapter = MobileAdapter()
ids = itertools.count()
def rpc(method, params):
    frame = adapter.request({'jsonrpc': '2.0', 'id': 'phone-' + str(next(ids)),
                             'method': PREFIX + method, 'params': params})
    response = server.handle_request(frame)
    assert response and 'error' not in response, (method, response)
    result = adapter.incoming(response)['result']
    print('PASS runtime:', method, flush=True)
    return result

profiles = rpc('profiles.list', {'include_sessions': False})
assert isinstance(profiles.get('profiles'), list)
completion = rpc('complete.slash', {'text': '/', 'profile': 'default', 'session_id': 'unused'})
assert isinstance(completion.get('items'), list), completion
# Real session state/response, with the model-construction boundary disabled.
with patch.object(server, '_schedule_agent_build'), patch.object(server, '_schedule_session_cap_enforcement', create=True):
    created = rpc('session.create', {'profile': 'default', 'source': 'desktop', 'close_on_disconnect': False})
sid = created['session_id']
assert isinstance(created['stored_session_id'], str)
catalog = rpc('commands.catalog', {'profile': 'default', 'session_id': sid})
assert isinstance(catalog.get('pairs'), list), 'Missing command catalog pairs'
status = rpc('session.status', {'profile': 'default', 'session_id': sid})
assert isinstance(status.get('output'), str), 'Missing status output'

# Validate representative app writes without executing a prompt, shell command,
# config mutation, or paid model. Old Hermes has no registry; runtime tests above
# are still mandatory there, and legacy interaction behavior has unit coverage.
examples = {
    'session.resume': {'profile': 'default', 'session_id': 'saved', 'defer_history': True, 'omit_messages': True},
    'session.interrupt': {'profile': 'default', 'session_id': sid},
    'session.title': {'profile': 'default', 'session_id': sid, 'title': 'Example'},
    'session.compress': {'profile': 'default', 'session_id': sid, 'focus_topic': ''},
    'session.save': {'profile': 'default', 'session_id': sid},
    'prompt.submit': {'session_id': sid, 'text': 'hello'},
    'approval.received': {'session_id': sid, 'request_id': 'approval-id'},
    'image.attach_bytes': {'session_id': sid, 'content_base64': 'eA==', 'filename': 'fixture.png'},
    'image.detach': {'session_id': sid, 'path': '/fixture.png'},
    'process.stop': {'profile': 'default', 'session_id': sid},
    'model.options': {'profile': 'default', 'session_id': sid},
    'config.get': {'key': 'model'},
    'config.set': {'profile': 'default', 'session_id': sid, 'key': 'reasoning', 'value': 'low'},
    'slash.exec': {'profile': 'default', 'session_id': sid, 'command': '/help'},
    'command.dispatch': {'profile': 'default', 'session_id': sid, 'name': 'help', 'arg': ''},
}
try:
    from tui_gateway.contracts import registry
except ImportError:
    print('INFO: legacy Hermes has no typed registry; runtime and adapter checks apply')
else:
    for method, params in examples.items():
        frame = adapter.request({'jsonrpc': '2.0', 'id': 'schema-' + method, 'method': PREFIX + method, 'params': params})
        registry.METHODS[frame['method']].params.model_validate(frame['params'])
        print('PASS parameters:', method)
    # Ask a synthetic question through Hermes's real server-request registry;
    # route the phone answer back through the real RPC handler. No tool executes.
    from tui_gateway import server_requests
    for kind, params, answer in [
        ('approval', {'request_id': 'approval-id', 'command': 'fixture only', 'choices': ['once', 'deny']}, {'choice': 'deny', 'all': False}),
        ('clarify', {'question': 'Which?', 'choices': ['A', 'B']}, {'answer': 'A'}),
    ]:
        frames, results = [], []
        with patch.object(server_requests, '_write', frames.append):
            settle = server_requests.send_async(kind, sid, params, results.append)
            card = adapter.incoming(frames[-1])
            public_id = card['params']['payload']['request_id']
            rpc(kind + '.respond', {'session_id': sid, 'request_id': public_id, **answer})
            assert results == [answer], results
            settle('fixture complete')
print('PASS: real Hermes mobile compatibility checks complete')
