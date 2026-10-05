"""Invalid file requests must return an error without closing the device connection."""
import asyncio
import base64
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch
import uuid

from fastapi import HTTPException
from starlette.requests import Request

from hermes_jr import api
from hermes_jr.bridge import Peer
from hermes_jr.gateway import Gateway
from hermes_jr.state import State
from hermes_jr.uploads import upload


def request(body, headers=()):
    async def receive():
        return {'type': 'http.request', 'body': json.dumps(body).encode(), 'more_body': False}
    return Request({'type': 'http', 'method': 'PUT', 'headers': list(headers), 'query_string': b''}, receive)


class TransportErrorTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = State(Path(self.temp.name))
        self.device = str(uuid.uuid4())
        token = self.state.add_device(self.device, 'Phone', 'fixture-service-token', paired=True)
        self.headers = [(b'x-hermes-jr-device', self.device.encode()), (b'x-hermes-jr-token', token.encode())]
        self.body = dict(upload_id=str(uuid.uuid4()), filename='report.pdf', offset=0,
                         total=6, content_base64=base64.b64encode(b'abc').decode())

    def rejected_uploads(self):
        upload(self.state, self.device, self.body)
        return [dict(self.body, content_base64=base64.b64encode(b'xyz').decode()), dict(self.body, upload_id=str(uuid.uuid4()), offset=3),
                dict(self.body, upload_id=[]), dict(self.body, upload_id=None)]

    async def test_direct_upload_errors_return_bad_request(self):
        with patch.object(api, 'State', return_value=self.state), \
                patch.object(api, 'client_session', return_value=AsyncMock()):
            for body in self.rejected_uploads():
                with self.subTest(body=body):
                    with self.assertRaises(HTTPException) as error:
                        await api.endpoint('uploads', request(body, self.headers))
                    self.assertEqual(error.exception.status_code, 400)

    async def test_relay_upload_errors_leave_connection_ready(self):
        bridge = SimpleNamespace(state=self.state, gateway=Gateway(self.state, None))
        peer = Peer(bridge, self.device)
        peer.phase, peer.channel, peer.emit = 'ready', Mock(), AsyncMock()
        for body in self.rejected_uploads():
            envelope = {'type': 'http', 'id': 'upload', 'method': 'PUT',
                        'path': api.PREFIX + '/v1/uploads', 'body': body}
            peer.channel.receive.return_value = json.dumps(envelope).encode()
            await peer.receive(b'fixture record')
            self.assertEqual(peer.emit.call_args.args[0]['status'], 400)
            self.assertEqual(peer.phase, 'ready')
        peer.channel.receive.return_value = json.dumps({
            'type': 'http', 'id': 'follow-up', 'path': api.PREFIX + '/v1/follows'}).encode()
        await peer.receive(b'fixture record')
        self.assertEqual(peer.emit.call_args.args[0], {
            'type': 'http', 'id': 'follow-up', 'status': 200, 'body': {'follows': []}})

    async def test_enrollment_rejects_non_object_json_before_creating_a_device(self):
        with patch.object(api, 'State') as state:
            for body in (None, [], 'phone', 1):
                with self.subTest(body=body):
                    with self.assertRaises(HTTPException) as error:
                        await api.enroll(request(body))
                    self.assertEqual(error.exception.status_code, 400)
            state.assert_not_called()

    async def test_backend_timeouts_return_errors_without_closing_the_relay(self):
        bridge = SimpleNamespace(state=self.state, gateway=Gateway(self.state, None))
        peer = Peer(bridge, self.device)
        peer.phase, peer.channel, peer.emit = 'ready', Mock(), AsyncMock()
        peer.local.send = AsyncMock(side_effect=asyncio.TimeoutError)
        bridge.gateway.http = AsyncMock(side_effect=asyncio.TimeoutError)
        for envelope in ({'type': 'rpc', 'body': {'jsonrpc': '2.0', 'id': 'ping',
                          'method': 'jr.v1.gateway.ping'}},
                         {'type': 'http', 'id': 'history', 'path': '/api/sessions'}):
            peer.channel.receive.return_value = json.dumps(envelope).encode()
            await peer.receive(b'fixture record')
            error = peer.emit.call_args.args[0]
            if envelope['type'] == 'rpc':
                self.assertEqual(error['body']['error']['code'], -32000)
            else:
                self.assertEqual(error['status'], 500)
            self.assertEqual(peer.phase, 'ready')


if __name__ == '__main__':
    unittest.main()
