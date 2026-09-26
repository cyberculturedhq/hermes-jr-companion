"""Readiness must exercise the WebSocket, including rejected upgrades and missing RPC replies."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer
from hermes_jr.gateway import Gateway
from hermes_jr.service import client_session
from hermes_jr.state import State


class DashboardProbeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(Path(self.temp.name))
        self.mode = 'ok'
        self.closed = False
        app = web.Application()
        app.router.add_get('/', self.bootstrap)
        app.router.add_get('/api/ws', self.websocket)
        self.server = TestServer(app)
        await self.server.start_server()
        self.state.set('dashboard_url', str(self.server.make_url('/')).rstrip('/'))
        self.env = patch.dict('os.environ', {'HERMES_JR_DASHBOARD_TOKEN': '', 'HERMES_JR_DASHBOARD_SESSION_TOKEN': ''})
        self.env.start()
        self.client = client_session()

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()
        self.env.stop()
        self.temp.cleanup()

    async def bootstrap(self, request):
        return web.Response(text='window.__HERMES_AUTH_REQUIRED__=false;window.__HERMES_SESSION_TOKEN__="fixture";')

    async def websocket(self, request):
        if self.mode == 'rejected':
            raise web.HTTPForbidden()
        self.assertEqual(request.query.get('token'), 'fixture')
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        async for message in ws:
            frame = message.json()
            self.assertEqual(frame['method'], 'gateway.ping')
            if self.mode == 'closed':
                await ws.close()
                break
            await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'result': {'ok': True}})
        self.closed = True
        return ws

    async def test_checks_real_rpc_and_closes_probe_socket(self):
        await Gateway(self.state, self.client).probe()
        self.assertTrue(self.closed)

    async def test_readable_dashboard_does_not_hide_rejected_socket(self):
        self.mode = 'rejected'
        gateway = Gateway(self.state, self.client)
        await gateway.authenticate()
        with self.assertRaises(aiohttp.WSServerHandshakeError) as error:
            await gateway.probe()
        self.assertEqual(error.exception.status, 403)

    async def test_socket_closing_without_rpc_reply_is_not_healthy(self):
        self.mode = 'closed'
        with self.assertRaises(ConnectionError):
            await Gateway(self.state, self.client).probe()
