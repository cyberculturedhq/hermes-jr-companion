"""Exercise the actual companion socket path, not only the adapter in isolation."""
import asyncio
import json
import unittest
from unittest.mock import Mock, patch
import aiohttp
from hermes_jr.gateway import LocalPeer


class Socket:
    def __init__(self, capabilities='modern'):
        self.closed = False
        self.frames = asyncio.Queue()
        self.sent = []
        self.capabilities = capabilities
        self.advertised = False
        self.capability_sent = asyncio.Event()

    async def send_json(self, frame):
        self.sent.append(frame)
        if frame.get('method') == 'client.capabilities':
            self.capability_sent.set()
            if self.capabilities == 'modern':
                self.advertised = frame['params'].get('server_requests') is True
                await self.frames.put({'jsonrpc': '2.0', 'id': frame['id'],
                                       'result': {'server_requests': ['approval', 'clarify']}})
            elif self.capabilities in ('legacy', 'rejected'):
                await self.frames.put({'jsonrpc': '2.0', 'id': frame['id'],
                    'error': {'code': -32601 if self.capabilities == 'legacy' else 4000, 'message': 'fixture rejection'}})
            elif self.capabilities == 'closed':
                await self.close()
            elif self.capabilities == 'invalid':
                await self.frames.put({'jsonrpc': '2.0', 'id': frame['id'], 'result': None})

    def __aiter__(self): return self

    async def __anext__(self):
        frame = await self.frames.get()
        if frame is None: raise StopAsyncIteration
        return Mock(type=aiohttp.WSMsgType.TEXT, data=json.dumps(frame))

    async def close(self):
        self.closed = True
        await self.frames.put(None)


def rpc(method, params=None, rid='phone-1'):
    return {'jsonrpc': '2.0', 'id': rid, 'method': 'jr.v1.' + method, 'params': params or {}}


def approval():
    return {'jsonrpc': '2.0', 'id': 'server-request-1', 'method': 'approval',
            'params': {'session_id': 'live', 'request_id': 'queue-1',
                       'command': 'harmless test fixture', 'choices': ['once', 'deny']}}


class ApprovalTransportTests(unittest.IsolatedAsyncioTestCase):
    def peer(self, *sockets):
        pending = iter(sockets)
        class Gateway:
            async def socket(self): return next(pending)
        delivered = asyncio.Queue()
        peer = LocalPeer(Gateway(), delivered.put)
        self.addAsyncCleanup(peer.close)
        return peer, delivered

    async def test_modern_approval_reaches_phone_and_answer_returns_to_original_request(self):
        socket = Socket()
        peer, delivered = self.peer(socket)
        await peer.send(rpc('session.resume', {'session_id': 'saved', 'profile': 'default'}, 'resume'))
        # The current backend withdraws the approval before sending it unless
        # this connection advertised server requests. The old fixture skipped
        # this gate and missed the real failure.
        self.assertTrue(socket.advertised)
        await socket.frames.put(approval())
        frame = (await asyncio.wait_for(delivered.get(), 1))['body']
        self.assertEqual(frame['params']['type'], 'approval.request')
        rid = frame['params']['payload']['request_id']
        self.assertEqual([f['method'] for f in socket.sent], ['client.capabilities', 'session.resume'])
        await peer.send(rpc('approval.respond', {'session_id': 'live', 'request_id': rid,
                                               'choice': 'deny', 'all': False}, 'answer'))
        self.assertEqual(socket.sent[-1]['method'], 'request.answer')
        self.assertEqual(socket.sent[-1]['params'], {'id': 'server-request-1', 'result': {'choice': 'deny', 'all': False}})
        await socket.frames.put({'jsonrpc': '2.0', 'id': 'answer', 'result': {'status': 'ok'}})
        response = (await asyncio.wait_for(delivered.get(), 1))['body']
        self.assertEqual(response['result'], {'resolved': True})

    async def test_approval_once_requires_explicit_phone_answer(self):
        socket = Socket()
        peer, delivered = self.peer(socket)
        await peer.send(rpc('session.resume', {'session_id': 'saved'}))
        await socket.frames.put(approval())
        card = (await asyncio.wait_for(delivered.get(), 1))['body']['params']['payload']
        self.assertFalse(any(f['method'] == 'request.answer' for f in socket.sent))
        await peer.send(rpc('approval.respond', {'session_id': 'live', 'request_id': card['request_id'],
                                               'choice': 'once', 'all': False}, 'answer'))
        self.assertEqual(socket.sent[-1]['params']['result'], {'choice': 'once', 'all': False})

    async def test_pending_handshake_blocks_session_and_prompt_dispatch(self):
        socket = Socket('held')
        peer, delivered = self.peer(socket)
        resume = asyncio.create_task(peer.send(rpc('session.resume', {'session_id': 'saved'})))
        await asyncio.wait_for(socket.capability_sent.wait(), 1)
        prompt = asyncio.create_task(peer.send(rpc('prompt.submit', {'session_id': 'live', 'text': 'fixture'}, 'prompt')))
        self.assertEqual(len(socket.sent), 1)
        self.assertFalse(resume.done())
        await socket.frames.put({'jsonrpc': '2.0', 'id': socket.sent[0]['id'], 'result': {}})
        await asyncio.wait_for(asyncio.gather(resume, prompt), 1)
        self.assertEqual([f['method'] for f in socket.sent], ['client.capabilities', 'session.resume', 'prompt.submit'])
        self.assertTrue(delivered.empty())  # Internal handshake does not reach the phone.

    async def test_backend_reconnect_advertises_again_with_a_new_id(self):
        first, second = Socket(), Socket()
        peer, _ = self.peer(first, second)
        await peer.send(rpc('gateway.ping'))
        await first.close()
        await asyncio.wait_for(peer.reader, 1)
        await peer.send(rpc('session.resume', {'session_id': 'saved'}, 'resume'))
        self.assertTrue(second.advertised)
        self.assertNotEqual(first.sent[0]['id'], second.sent[0]['id'])
        self.assertEqual([f['method'] for f in second.sent], ['client.capabilities', 'session.resume'])

    async def test_older_backend_method_not_found_preserves_legacy_approvals(self):
        socket = Socket('legacy')
        peer, delivered = self.peer(socket)
        await peer.send(rpc('session.resume', {'session_id': 'saved'}))
        event = {'jsonrpc': '2.0', 'method': 'event', 'params': {'session_id': 'live', 'type': 'approval.request',
                 'payload': {'request_id': 'old-queue', 'command': 'fixture', 'choices': ['deny']}}}
        await socket.frames.put(event)
        self.assertEqual((await asyncio.wait_for(delivered.get(), 1))['body'], event)
        await peer.send(rpc('approval.respond', {'session_id': 'live', 'request_id': 'old-queue', 'choice': 'deny'}, 'answer'))
        self.assertEqual(socket.sent[-1]['method'], 'approval.respond')

    async def test_rejected_closed_or_timed_out_handshake_never_submits_a_turn(self):
        for mode in ('rejected', 'closed', 'held', 'invalid'):
            with self.subTest(mode=mode):
                socket = Socket(mode)
                peer, _ = self.peer(socket)
                with patch('hermes_jr.gateway.CAPABILITY_TIMEOUT', .01):
                    with self.assertRaises((ConnectionError, TimeoutError)):
                        await peer.send(rpc('prompt.submit', {'session_id': 'live', 'text': 'fixture'}))
                self.assertTrue(socket.closed)
                self.assertEqual([f['method'] for f in socket.sent], ['client.capabilities'])

    async def test_cancelled_handshake_never_dispatches_the_pending_request(self):
        socket = Socket('held')
        peer, _ = self.peer(socket)
        pending = asyncio.create_task(peer.send(rpc('prompt.submit', {'session_id': 'live', 'text': 'fixture'})))
        await asyncio.wait_for(socket.capability_sent.wait(), 1)
        pending.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await pending
        self.assertTrue(socket.closed)
        self.assertEqual([f['method'] for f in socket.sent], ['client.capabilities'])

    async def test_raw_legacy_client_does_not_claim_server_request_support(self):
        socket = Socket()
        peer, _ = self.peer(socket)
        await peer.send({'jsonrpc': '2.0', 'id': 'resume', 'method': 'session.resume', 'params': {'session_id': 'saved'}})
        self.assertFalse(socket.advertised)
        self.assertEqual(len(socket.sent), 1)

    async def test_unsupported_live_requests_are_rejected_without_input_leaking(self):
        for kind in ('sudo', 'secret', 'new-sensitive-prompt'):
            with self.subTest(kind=kind):
                socket = Socket()
                peer, delivered = self.peer(socket)
                await peer.send(rpc('gateway.ping'))
                await socket.frames.put({'jsonrpc': '2.0', 'id': 'unknown', 'method': kind,
                                         'params': {'session_id': 'live', 'private_field': 'must-not-reach-phone'}})
                card = (await asyncio.wait_for(delivered.get(), 1))['body']
                self.assertEqual(socket.sent[-1], {'jsonrpc': '2.0', 'id': 'unknown',
                    'error': {'code': -32601, 'message': 'This request is not supported on the phone.'}})
                self.assertEqual(card['params']['type'], 'status.update')
                self.assertNotIn('must-not-reach-phone', json.dumps(card))
                self.assertFalse(peer.adapter.interactions)

    async def test_replayed_unsupported_request_is_also_rejected(self):
        socket = Socket()
        peer, delivered = self.peer(socket)
        await peer.send(rpc('session.resume', {'session_id': 'saved'}, 'resume'))
        await socket.frames.put({'jsonrpc': '2.0', 'id': 'resume', 'result': {'session_id': 'live', 'open_requests': [
            approval(), {'id': 'secret-replay', 'method': 'secret', 'params': {'session_id': 'live', 'prompt': 'private'}}]}})
        result = (await asyncio.wait_for(delivered.get(), 1))['body']['result']
        self.assertEqual(socket.sent[-1]['id'], 'secret-replay')
        self.assertEqual(socket.sent[-1]['error']['code'], -32601)
        self.assertEqual([card['params']['type'] for card in result['pending_interactions']], ['approval.request', 'status.update'])


if __name__ == '__main__': unittest.main()
