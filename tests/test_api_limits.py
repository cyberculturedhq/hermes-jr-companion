import contextlib
import json
import unittest
from unittest.mock import AsyncMock, Mock, patch

from fastapi import FastAPI
from hermes_jr import api


@contextlib.asynccontextmanager
async def client():
    yield None


class ApiLimitTests(unittest.IsolatedAsyncioTestCase):
    async def call(self, path, method, chunks, length=None, authorized=True):
        app = FastAPI()
        app.include_router(api.router, prefix=api.PREFIX)
        headers = [(b'x-hermes-jr-device', b'fixture'), (b'x-hermes-jr-token', b'fixture')]
        if length is not None:
            headers.append((b'content-length', str(length).encode()))
        scope = dict(type='http', asgi={'version': '3.0'}, http_version='1.1',
                     method=method, scheme='https', path=api.PREFIX + path,
                     raw_path=(api.PREFIX + path).encode(), query_string=b'', headers=headers,
                     server=('test', 443), client=('test', 1), root_path='')
        self.reads = 0
        self.messages = []
        chunks = list(chunks)
        async def receive():
            self.reads += 1
            chunk = chunks.pop(0) if chunks else b''
            return {'type': 'http.request', 'body': chunk, 'more_body': bool(chunks)}
        async def send(message):
            self.messages.append(message)
        state = Mock()
        if not authorized:
            state.authenticate.side_effect = PermissionError()
        with patch.object(api, 'State', return_value=state), \
             patch.object(api, 'client_session', client), \
             patch.object(api, 'handle', new=AsyncMock(return_value={'ok': True})):
            await app(scope, receive, send)
        return next(m['status'] for m in self.messages if m['type'] == 'http.response.start')

    async def test_chunked_actual_limit_and_false_length(self):
        for length in [None, 1]:
            self.assertEqual(await self.call('/v1/presence', 'PUT', [b' ' * 4096, b'x', b'x' * 10000], length), 413)
            self.assertEqual(self.reads, 2)

    async def test_exact_limit_preserves_supported_payloads(self):
        for path, limit in [('/v1/presence', 4096), ('/v1/uploads', 720000),
                            ('/v1/bot-replies/' + 'a' * 36, 2000000)]:
            body = json.dumps({'x': 'a' * (limit - 9)}).encode()
            self.assertEqual(len(body), limit)
            self.assertEqual(await self.call(path, 'PUT', [body]), 200)
            self.assertEqual(await self.call(path, 'PUT', [body, b' ']), 413)

    async def test_declared_large_body_auth_and_unknown_routes_read_nothing(self):
        self.assertEqual(await self.call('/v1/presence', 'PUT', [b'{}'], 10**12), 413)
        self.assertEqual(self.reads, 0)
        self.assertEqual(await self.call('/v1/uploads', 'PUT', [b'x' * 10000], authorized=False), 401)
        self.assertEqual(self.reads, 0)
        for method in ['GET', 'PUT', 'DELETE']:
            self.assertEqual(await self.call('/v1/unknown', method, [b'x' * 10000]), 404)
            self.assertEqual(self.reads, 0)
        self.assertEqual(await self.call('/v1/uploads', 'GET', [b'x' * 10000]), 404)
        self.assertEqual(self.reads, 0)

    async def test_bodyless_operations_and_invalid_json(self):
        self.assertEqual(await self.call('/v1/follows', 'GET', [b'x' * 10000]), 200)
        self.assertEqual(self.reads, 0)
        for body in [b'[1]', b'{', b'\xff']:
            self.assertEqual(await self.call('/v1/presence', 'PUT', [body]), 400)

    async def test_enrollment_uses_the_same_stream_limit(self):
        self.assertEqual(await self.call('/v1/enroll', 'POST', [b' ' * 4096, b'x', b'x' * 10000]), 413)
        self.assertEqual(self.reads, 2)
