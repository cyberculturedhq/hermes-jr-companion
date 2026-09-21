"""Exercise the actual companion socket path, not only the adapter in isolation."""
import asyncio
import json
import unittest
from unittest.mock import Mock
import aiohttp
from hermes_jr.gateway import LocalPeer


class Socket:
    def __init__(self):
        self.closed = False
        self.frames = asyncio.Queue()
        self.sent = []

    async def send_json(self, frame):
        self.sent.append(frame)

    def __aiter__(self): return self

    async def __anext__(self):
        frame = await self.frames.get()
        if frame is None: raise StopAsyncIteration
        return Mock(type=aiohttp.WSMsgType.TEXT, data=json.dumps(frame))

    async def close(self):
        self.closed = True
        await self.frames.put(None)


class ApprovalTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_modern_approval_reaches_phone_and_answer_returns_to_original_request(self):
        socket = Socket()
        class Gateway:
            async def socket(self): return socket
        delivered = asyncio.Queue()
        peer = LocalPeer(Gateway(), delivered.put)
        try:
            await peer.send({'jsonrpc': '2.0', 'id': 'resume', 'method': 'jr.v1.session.resume',
                             'params': {'session_id': 'saved', 'profile': 'default'}})
            request = {'jsonrpc': '2.0', 'id': 'server-request-1', 'method': 'approval',
                       'params': {'session_id': 'live', 'request_id': 'queue-1',
                                  'command': 'harmless test fixture', 'choices': ['once', 'deny']}}
            await socket.frames.put(request)
            frame = (await asyncio.wait_for(delivered.get(), 1))['body']
            self.assertEqual(frame['method'], 'event')
            self.assertEqual(frame['params']['type'], 'approval.request')
            rid = frame['params']['payload']['request_id']
            await peer.send({'jsonrpc': '2.0', 'id': 'answer', 'method': 'jr.v1.approval.respond',
                             'params': {'session_id': 'live', 'request_id': rid, 'choice': 'deny', 'all': False}})
            self.assertEqual(socket.sent[-1]['method'], 'request.answer')
            self.assertEqual(socket.sent[-1]['params'], {'id': 'server-request-1', 'result': {'choice': 'deny', 'all': False}})
            await socket.frames.put({'jsonrpc': '2.0', 'id': 'answer', 'result': {'status': 'ok'}})
            response = (await asyncio.wait_for(delivered.get(), 1))['body']
            self.assertEqual(response['result'], {'resolved': True})
        finally:
            await peer.close()


if __name__ == '__main__': unittest.main()
