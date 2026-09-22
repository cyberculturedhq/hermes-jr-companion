"""Real Hermes renderers/middleware + real companion CLI, without a model or credentials.

Run with Hermes' Python, passing a clean Hermes checkout. All state is disposable.
"""
import argparse
import asyncio
import json
import inspect
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
from types import SimpleNamespace

parser = argparse.ArgumentParser()
parser.add_argument('upstream', type=Path)
parser.add_argument('--dependencies', type=Path)
parser.add_argument('--companion', type=Path, default=Path(__file__).resolve().parents[1] / 'Companion')
args = parser.parse_args()
assert not (args.upstream / '.env').exists(), 'Use a clean checkout without credentials'
# A local Hermes Python can have an editable-import fallback to the user's
# checkout. Remove that finder so missing modules really test the chosen revision.
sys.meta_path[:] = [finder for finder in sys.meta_path
                   if not getattr(finder, '__module__', '').startswith('__editable___hermes_agent')]
sys.path[:] = [path for path in sys.path if not path.startswith('__editable__.hermes_agent')]
plugin = args.companion.resolve()
args.upstream = args.upstream.resolve()
home = tempfile.TemporaryDirectory(prefix='jr-panel-runtime-')
os.environ['HERMES_HOME'] = home.name
os.environ['HERMES_TEST_ISOLATION'] = '1'
os.environ['HERMES_JR_STATE_DIR'] = str(Path(home.name) / 'jr-state')
os.environ['PYTHONPATH'] = str(plugin / 'src') + os.pathsep + str(args.upstream)
sys.path[:0] = [str(plugin / 'src'), str(args.upstream)]
if args.dependencies:
    sys.path.append(str(args.dependencies))
    os.environ['PYTHONPATH'] += os.pathsep + str(args.dependencies)
def deny_network(*args, **kwargs):
    raise AssertionError('Native panel tests must not contact external services')
socket.socket.connect = deny_network
socket.create_connection = deny_network

def report(message):
    os.write(1, (message + '\n').encode())

from hermes_jr.state import State
from hermes_jr import pairing_panel, setup_jobs
from hermes_cli.plugins import PluginManifest, PluginContext, get_plugin_manager
from hermes_cli.middleware import run_tool_execution_middleware

state = State()
setup_jobs.initialize(state)
manager = get_plugin_manager()
manager.discover_and_load()
context = PluginContext(PluginManifest(name='hermes-jr', version='0.15.0', source='user', path=str(plugin)), manager)
pairing_panel.register(context)

def job(number):
    job_id = f'{number:064x}'
    with state.connect() as db:
        db.execute("INSERT INTO setup_jobs VALUES (?, 'fixture-public-ticket', 'iPhone', 'ready', '1234 5678 9012', strftime('%s','now')+60, strftime('%s','now'))", (job_id,))
    return job_id

def command(job_id, session_id):
    def execute(arguments):
        process = subprocess.run(arguments['command'], shell=True, capture_output=True, text=True, timeout=15)
        assert '1234 5678 9012' not in process.stdout, 'The code leaked into the model-facing CLI output'
        return json.dumps({'output': process.stdout + process.stderr, 'exit_code': process.returncode})
    return run_tool_execution_middleware('terminal',
        {'command': shlex.join([sys.executable, '-m', 'hermes_jr.cli', 'pair', '--watch', job_id])},
        execute, session_id=session_id, task_id=session_id)


async def classic():
    from cli import HermesCLI
    from prompt_toolkit.application import Application
    from prompt_toolkit.input import create_pipe_input
    from prompt_toolkit.output import DummyOutput
    from prompt_toolkit.data_structures import Size

    cli = HermesCLI(model='fixture', provider='custom', api_key='not-a-key',
                    base_url='http://127.0.0.1:1/v1', toolsets=['terminal'])
    cli._tui_init_run_state()
    cli.agent = SimpleNamespace(session_id=cli.session_id)
    kb = cli._tui_build_key_bindings()
    layout, style = cli._tui_build_layout(kb)
    class Output(DummyOutput):
        def get_size(self): return Size(rows=40, columns=100)
    with create_pipe_input() as keys:
        app = Application(layout=layout, key_bindings=kb, style=style, input=keys, output=Output(), full_screen=True)
        cli._app = app
        runner = asyncio.create_task(app.run_async())
        await asyncio.sleep(.05)
        for number, cancel in [(1, False), (2, True)]:
            identity = job(number)
            pending = asyncio.create_task(asyncio.to_thread(command, identity, cli.session_id))
            for _ in range(100):
                if pending.done():
                    raise AssertionError('Tool returned before rendering: ' + pending.result())
                if cli._clarify_state and '1234 5678 9012' in cli._clarify_state['question']:
                    break
                await asyncio.sleep(.05)
            else:
                raise AssertionError('CLI did not open its native panel')
            await asyncio.sleep(.1)
            screen = app.renderer.last_rendered_screen
            rendered = '\n'.join(''.join(cell.char for _, cell in sorted(row.items())) for _, row in sorted(screen.data_buffer.items()))
            assert '1234 5678 9012' in rendered, rendered
            assert 'It’s correct' in rendered, rendered
            if cancel:
                keys.send_text('\r')  # Real Hermes Enter binding chooses Cancel pairing.
            else:
                setup_jobs.publish(state, identity, 'connected')
            result = json.loads(await asyncio.wait_for(pending, 5))
            value = json.loads(result['output'])
            assert value.get('reason') == 'cancelled' if cancel else value['status'] == 'connected', result
            assert cli._clarify_state is None
        app.exit()
        await runner
    manager._cli_ref = None
    report('PASS real CLI renderer + subprocess + middleware: visible code, phone-only completion, keyboard cancellation')


async def desktop():
    from tui_gateway import server
    try:
        from tui_gateway import server_requests
    except ImportError:
        await legacy_desktop(server)
        return
    frames, events = [], []
    sid, durable = 'desktop-panel-fixture', 'desktop-durable-fixture'
    with server._sessions_lock:
        server._sessions[sid] = {'session_key': durable}
    if len(inspect.signature(server_requests.bind_sinks).parameters) == 3:
        server_requests.bind_sinks(frames.append, lambda *event: events.append(event), lambda _: True)
    else:
        server_requests.bind_sinks(frames.append, lambda *event: events.append(event))
    identity = job(3)
    pending = asyncio.create_task(asyncio.to_thread(command, identity, durable))
    for _ in range(100):
        if pending.done(): raise AssertionError(pending.result())
        if frames: break
        await asyncio.sleep(.05)
    assert frames[-1]['method'] == 'clarify'
    assert frames[-1]['params']['session_id'] == sid
    assert '1234 5678 9012' in frames[-1]['params']['question']
    setup_jobs.publish(state, identity, 'connected')
    result = json.loads(await asyncio.wait_for(pending, 5))
    assert json.loads(result['output'])['status'] == 'connected'
    assert events[-1] == ('request.cancel', sid, {'id': frames[-1]['id'], 'method': 'clarify', 'reason': 'resolved'})
    assert not server_requests.resolve_response({'id': frames[-1]['id'], 'result': {'answer': 'Cancel pairing'}})
    assert setup_jobs.result(state, identity)['status'] == 'connected'
    report('PASS real desktop gateway: owning conversation, native question, automatic dismissal, late-answer rejection')


async def legacy_desktop(server):
    from unittest.mock import patch
    sid, durable = 'legacy-panel-fixture', 'legacy-durable-fixture'
    with server._sessions_lock:
        server._sessions[sid] = {'session_key': durable}
    for number, cancel in [(3, False), (4, True)]:
        frames = []
        identity = job(number)
        with patch.object(server, '_emit', side_effect=lambda *event: frames.append(event)):
            pending = asyncio.create_task(asyncio.to_thread(command, identity, durable))
            for _ in range(100):
                if pending.done(): raise AssertionError(pending.result())
                if frames: break
                await asyncio.sleep(.05)
            method, owner, payload = frames[-1]
            assert method == 'clarify.request' and owner == sid
            assert '1234 5678 9012' in payload['question']
            request_id = payload['request_id']
            if cancel:
                answer = server._methods['clarify.respond']('fixture-answer',
                    {'session_id': sid, 'request_id': request_id, 'answer': 'Cancel pairing'})
                assert 'error' not in answer, answer
            else:
                setup_jobs.publish(state, identity, 'connected')
            result = json.loads(await asyncio.wait_for(pending, 5))
            value = json.loads(result['output'])
            assert value.get('reason') == 'cancelled' if cancel else value['status'] == 'connected', result
            assert frames[-1] == ('clarify.expire', sid, {'request_id': request_id})
            assert request_id not in server._pending and request_id not in server._answers
    report('PASS real legacy desktop gateway: visible code, phone-only completion, cancellation, matching dismissal')


async def main():
    await classic()
    await desktop()
    with state.connect() as db:
        assert not db.execute("SELECT key FROM settings WHERE key LIKE 'pairing-panel%'").fetchall()
    for name, module in list(sys.modules.items()):
        if name in ('cli', 'run_agent') or name.startswith(('hermes_cli.', 'tui_gateway.', 'tools.')):
            filename = getattr(module, '__file__', None)
            if filename:
                assert Path(filename).is_relative_to(args.upstream), (name, filename)
    report('PASS all temporary panel leases removed; only the chosen Hermes revision loaded; no model calls or live connections used')

asyncio.run(main())
home.cleanup()
