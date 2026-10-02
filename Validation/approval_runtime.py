"""Test the companion socket against Hermes' real approval registry.

Run with Hermes' Python and a clean Hermes source checkout. All sockets are
disposable loopback fixtures; no model, command, pairing or live service runs.
"""
import argparse
import asyncio
import importlib.util
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('upstream', type=Path)
root = Path(__file__).resolve().parents[1]
parser.add_argument('--companion', type=Path, default=root / ('Companion' if (root / 'Companion').exists() else 'plugin'))
args = parser.parse_args()
upstream = args.upstream.resolve()
assert not (upstream / '.env').exists(), 'Use a clean checkout without credentials'
sys.meta_path[:] = [finder for finder in sys.meta_path
                   if not getattr(finder, '__module__', '').startswith('__editable___hermes_agent')]
sys.path[:] = [path for path in sys.path if not path.startswith('__editable__.hermes_agent')]
sys.path[:0] = [str(args.companion.resolve() / 'src'), str(upstream)]

from aiohttp import web
from aiohttp.test_utils import TestServer
from hermes_jr.gateway import Gateway, LocalPeer
from hermes_jr.service import client_session
if importlib.util.find_spec('tui_gateway.server_requests') is None:
    print('SKIP old Hermes uses approval notifications; the mobile protocol suite covers that path')
    raise SystemExit(0)
from tui_gateway import server_requests
if not hasattr(server_requests, 'advertise'):
    print('SKIP Hermes predates the approval capability gate; the mobile protocol suite covers that path')
    raise SystemExit(0)
from tui_gateway.contracts import registry as contracts


async def main():
    answers = asyncio.Queue()
    writers = set()
    connections = []

    async def websocket(request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        transport = object()
        connections.append(transport)

        def write(frame):
            pending = asyncio.create_task(ws.send_json(frame))
            writers.add(pending)
            pending.add_done_callback(writers.discard)

        server_requests.bind_sinks(write, lambda *event: None,
                                  lambda _: server_requests.answers_requests(transport))
        try:
            async for message in ws:
                frame = message.json()
                method, params = frame.get('method'), frame.get('params', {})
                if method == 'client.capabilities':
                    _, error = contracts.validate_params(contracts.METHODS[method], params)
                    assert error is None, error
                    server_requests.advertise(transport, params['server_requests'])
                    result = {'server_requests': sorted(contracts.SERVER_REQUESTS), 'declines_not_shown': True}
                elif method == 'session.resume':
                    assert server_requests.answers_requests(transport), 'Resume preceded capability registration'
                    result = {'session_id': 'fixture-live'}
                elif method == 'prompt.submit':
                    server_requests.send_async('approval', 'fixture-live',
                        {'request_id': 'fixture-queue', 'command': 'fixture: no command executes', 'choices': ['once', 'deny']},
                        answers.put_nowait)
                    result = {'accepted': True}
                elif method == 'request.answer':
                    resolved = server_requests.resolve_response({'id': params['id'], 'result': params['result']})
                    result = {'status': 'ok' if resolved else 'expired'}
                elif 'error' in frame:
                    assert server_requests.resolve_response(frame, transport)
                    continue
                else:
                    raise AssertionError(frame)
                await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'result': result})
        finally:
            server_requests.forget(transport)
        return ws

    app = web.Application()
    app.router.add_get('/api/ws', websocket)
    server = TestServer(app)
    await server.start_server()
    client = client_session()
    gateway = Gateway({'dashboard_url': str(server.make_url('/')).rstrip('/')}, client)
    async def authenticate():
        pass  # No credentials or bootstrap are needed for this isolated socket.
    gateway.authenticate = authenticate
    delivered = asyncio.Queue()
    peer = LocalPeer(gateway, delivered.put)

    async def send(method, params, rid):
        await peer.send({'jsonrpc': '2.0', 'id': rid, 'method': 'jr.v1.' + method, 'params': params})

    async def receive(predicate):
        while True:
            frame = (await asyncio.wait_for(delivered.get(), 2))['body']
            if predicate(frame):
                return frame

    try:
        server_requests.bind_sinks(lambda frame: None, lambda *event: None, lambda _: False)
        blocked = []
        server_requests.send_async('approval', 'fixture-blocked',
            {'request_id': 'blocked', 'choices': ['once', 'deny']}, blocked.append)
        assert blocked == [None]
        print('PASS real Hermes rejects approval before client capability registration')

        for number, choice in enumerate(('deny', 'once')):
            await send('session.resume', {'session_id': 'fixture-saved'}, f'resume-{number}')
            await receive(lambda frame: frame.get('id') == f'resume-{number}')
            await send('prompt.submit', {'session_id': 'fixture-live', 'text': 'fixture approval only'}, f'prompt-{number}')
            card = await receive(lambda frame: frame.get('params', {}).get('type') == 'approval.request')
            assert answers.empty(), 'Approval settled without a user response'
            await send('approval.respond', {'session_id': 'fixture-live',
                'request_id': card['params']['payload']['request_id'], 'choice': choice, 'all': False}, f'answer-{number}')
            response = await receive(lambda frame: frame.get('id') == f'answer-{number}')
            assert response['result'] == {'resolved': True}
            assert await asyncio.wait_for(answers.get(), 2) == {'choice': choice, 'all': False}
            assert server_requests.open_requests('fixture-live') == []
            print(f'PASS real approval reaches phone adapter; explicit {choice} settles original request')
            if number == 0:
                await peer.ws.close()
                await asyncio.wait_for(peer.reader, 2)

        assert len(connections) == 2
        unsupported = asyncio.Queue()
        server_requests.send_async('secret', 'fixture-live', {'env_var': 'FIXTURE', 'prompt': 'fixture'}, unsupported.put_nowait)
        notice = await receive(lambda frame: frame.get('params', {}).get('type') == 'status.update')
        assert 'computer' in notice['params']['payload']['text']
        assert await asyncio.wait_for(unsupported.get(), 2) is None
        assert server_requests.open_requests('fixture-live') == []
        print('PASS reconnect registers anew; unsupported request fails promptly without approval')
    finally:
        await peer.close()
        if peer.reader:
            await asyncio.gather(peer.reader, return_exceptions=True)
        if writers:
            await asyncio.gather(*writers, return_exceptions=True)
        server_requests.cancel('fixture-live')
        await client.close()
        await server.close()

    assert Path(server_requests.__file__).is_relative_to(upstream)
    print('PASS selected Hermes source only; no models, commands, pairings or live services touched')


asyncio.run(main())
