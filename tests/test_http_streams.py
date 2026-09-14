"""Exercise real chunked HTTP responses, including cleanup when the byte cap is exceeded."""
import asyncio
import contextlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer

from hermes_jr.gateway import Gateway, MAX_MESSAGE
from hermes_jr.service import Service, client_session, read_bounded
from hermes_jr.state import State


class ChunkedHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(Path(self.temp.name))
        self.payloads = {
            '/': [b'<script>window.__HERMES_AUTH_REQUIRED__=false;',
                  b'window.__HERMES_SESSION_TOKEN__="fixture-local-token";</script>']
        }
        self.env = patch.dict(os.environ, {'HERMES_JR_DASHBOARD_TOKEN':'', 'HERMES_JR_DASHBOARD_SESSION_TOKEN':''})
        self.env.start()
        app = web.Application()
        app.router.add_route('*', '/{path:.*}', self.stream)
        self.server = TestServer(app)
        await self.server.start_server()
        self.state.settings({'dashboard_url':str(self.server.make_url('/')).rstrip('/'),
                             'service_url':str(self.server.make_url('/')).rstrip('/')})
        self.client = client_session()

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()
        self.env.stop()
        self.temp.cleanup()

    async def stream(self, request):
        response = web.StreamResponse(status=200, headers={'Content-Type':'application/json'})
        await response.prepare(request)
        with contextlib.suppress(ConnectionResetError, aiohttp.ClientConnectionError):
            for chunk in self.payloads[request.path]:
                await response.write(chunk)
                await asyncio.sleep(0.005)  # Force separately arriving chunks, not one buffered write.
            await response.write_eof()
        return response

    async def test_chunked_bootstrap_and_valid_history_read_through_eof(self):
        expected = {'messages':[{'role':'assistant','content':'x' * 100_000}]}
        data = json.dumps(expected).encode()
        self.payloads['/api/sessions/fixture/messages'] = [data[:17], data[17:60000], data[60000:]]
        gateway = Gateway(self.state, self.client)
        status, result = await gateway.http('device', {'type':'http','method':'GET','path':'/api/sessions/fixture/messages'})
        self.assertEqual(status, 200)
        self.assertEqual(result, expected)
        self.assertEqual(gateway.local_token, 'fixture-local-token')

    async def test_chunked_service_json_read_through_eof(self):
        self.payloads['/v1/capabilities'] = [b'{"protocol_version":', b'1,"push":false}']
        result = await Service(self.state, self.client).request('GET', '/v1/capabilities')
        self.assertEqual(result, {'protocol_version':1,'push':False})

    async def test_history_larger_than_four_megabytes_is_rejected(self):
        self.payloads['/api/sessions'] = [b'x' * 65536] * (MAX_MESSAGE // 65536 + 1)
        with self.assertRaisesRegex(ValueError, 'permitted size'):
            await Gateway(self.state, self.client).http('device', {'method':'GET','path':'/api/sessions'})

    async def test_oversized_bootstrap_is_rejected(self):
        self.payloads['/'] = [b'x' * 65536] * (2_000_000 // 65536 + 1)
        with self.assertRaisesRegex(ValueError, 'permitted size'):
            await Gateway(self.state, self.client).authenticate()

    async def test_bounded_reader_closes_oversized_stream_immediately(self):
        self.payloads['/bounded'] = [b'abc', b'def', b'never-drain-this-body']
        async with self.client.get(self.server.make_url('/bounded')) as response:
            with self.assertRaisesRegex(ValueError, 'permitted size'):
                await read_bounded(response, 5)
            self.assertTrue(response.closed)


if __name__ == '__main__':
    unittest.main()
