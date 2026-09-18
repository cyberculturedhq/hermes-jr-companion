import unittest
from hermes_jr.mobile import MobileAdapter, PREFIX, REVISION, negotiate, reply
from hermes_jr.gateway import validate_rpc


def request(method, params=None, rid='phone-1'):
    return {'jsonrpc': '2.0', 'id': rid, 'method': PREFIX + method, 'params': params or {}}


def interaction(kind='approval', sid='session-a', rid='srq-a', **params):
    if kind == 'approval':
        params = {'request_id': 'native-approval', 'command': 'fixture command', 'choices': ['once', 'deny'], **params}
    return {'jsonrpc': '2.0', 'id': rid, 'method': kind, 'params': {'session_id': sid, **params}}


class MobileProtocolTests(unittest.TestCase):
    def test_negotiation_only_returns_changed_descriptor(self):
        full = negotiate({'protocols': [2, 1]})
        self.assertEqual(full['protocol'], 1)
        self.assertTrue(full['features']['approval'])
        same = negotiate({'protocols': [1], 'known_revision': full['revision']})
        self.assertTrue(same['unchanged'])
        self.assertNotIn('features', same)
        self.assertIn('features', negotiate({'protocols': [1], 'known_revision': 'old'}))
        for versions in ([], [2], [True], '1'):
            with self.assertRaises(ValueError):
                negotiate({'protocols': versions})

    def test_completion_has_one_upstream_shape_for_old_and_new_hermes(self):
        adapter = MobileAdapter()
        out = adapter.request(request('complete.slash', {'text': '/', 'profile': 'research', 'session_id': 's'}))
        self.assertEqual(out['method'], 'complete.slash')
        self.assertEqual(out['params'], {'text': '/'})
        # Scope is retained everywhere it affects an operation's meaning.
        scoped = {'profile': 'research', 'session_id': 's', 'title': 'Example'}
        self.assertEqual(adapter.request(request('session.title', scoped, 'phone-2'))['params'], scoped)

    def test_mobile_namespace_does_not_expand_remote_permissions(self):
        for method, params in [('shell.exec', {}), ('config.get', {'key': 'full'}),
                               ('config.set', {'key': 'api_key', 'value': 'x'})]:
            with self.assertRaises(ValueError):
                validate_rpc(request(method, params))
        with self.assertRaises(ValueError):
            MobileAdapter().request(request('session.title', {'session_id': 's', 'unexpected': True}))

    def test_modern_approval_round_trip_preserves_identity_and_scope(self):
        adapter = MobileAdapter()
        card = adapter.incoming(interaction())
        pid = card['params']['payload']['request_id']
        self.assertEqual(card['params']['type'], 'approval.request')
        ack = adapter.request(request('approval.received', {'session_id': 'session-a', 'request_id': pid}))
        self.assertEqual(ack['params']['request_id'], 'native-approval')
        for sid, choice in [('session-b', 'once'), ('session-a', 'always')]:
            with self.assertRaises(ValueError):
                adapter.request(request('approval.respond', {'session_id': sid, 'request_id': pid, 'choice': choice}, 'bad'))
        out = adapter.request(request('approval.respond', {'session_id': 'session-a', 'request_id': pid, 'choice': 'deny', 'all': False}, 'phone-2'))
        self.assertEqual(out['method'], 'request.answer')
        self.assertEqual(out['params'], {'id': 'srq-a', 'result': {'choice': 'deny', 'all': False}})
        self.assertEqual(adapter.incoming(reply('phone-2', {'status': 'ok'}))['result'], {'resolved': True})
        with self.assertRaises(ValueError):
            adapter.request(request('approval.respond', {'session_id': 'session-a', 'request_id': pid, 'choice': 'deny'}, 'phone-3'))

    def test_legacy_interactions_and_replies_are_preserved(self):
        adapter = MobileAdapter()
        old = {'method': 'event', 'params': {'session_id': 's', 'type': 'approval.request',
                                          'payload': {'request_id': 'old-approval', 'choices': ['deny']}}}
        self.assertEqual(adapter.incoming(old), old)
        out = adapter.request(request('approval.respond', {'session_id': 's', 'request_id': 'old-approval', 'choice': 'deny'}))
        self.assertEqual(out['method'], 'approval.respond')
        self.assertEqual(adapter.incoming(reply('phone-1', {'resolved': True}))['result'], {'resolved': True})

    def test_single_and_batch_clarification_use_correct_routes(self):
        adapter = MobileAdapter()
        card = adapter.incoming(interaction('clarify', question='Which?', choices=['A', 'B']))
        pid = card['params']['payload']['request_id']
        out = adapter.request(request('clarify.respond', {'session_id': 'session-a', 'request_id': pid, 'answer': 'A'}))
        self.assertEqual(out['params'], {'id': 'srq-a', 'result': {'answer': 'A'}})
        self.assertEqual(adapter.incoming(reply('phone-1', {'status': 'expired'}))['result']['status'], 'expired')
        adapter.incoming(interaction('clarify', questions=[{'qid': 'q1', 'question': 'One'}, {'qid': 'q2', 'question': 'Two'}], answers={'q1': 'saved'}))
        out = adapter.request(request('clarify.respond', {'session_id': 'session-a', 'request_id': pid, 'question_id': 'q2', 'answer': 'B'}, 'phone-2'))
        self.assertEqual(out['method'], 'clarify.lock')
        self.assertEqual(out['params'], {'request_id': 'srq-a', 'question_id': 'q2', 'answer': 'B'})
        adapter.incoming(reply('phone-2', {'status': 'ok', 'remaining': 0}))
        self.assertNotIn(pid, adapter.interactions)

    def test_cancel_invalidates_pending_card_and_prevents_stale_answer(self):
        adapter = MobileAdapter()
        adapter.incoming(interaction('clarify', question='One'))
        canceled = adapter.incoming({'method': 'event', 'params': {'type': 'request.cancel', 'payload': {'id': 'srq-a'}}})
        self.assertEqual(canceled['params']['type'], 'clarify.expire')
        with self.assertRaises(ValueError):
            adapter.request(request('clarify.respond', {'session_id': 'session-a', 'request_id': 'jr-request:srq-a', 'answer': 'late'}))

    def test_resume_replay_is_returned_after_session_identity_not_emitted_early(self):
        adapter = MobileAdapter()
        adapter.request(request('session.resume', {'session_id': 'saved', 'profile': 'research'}))
        result = adapter.incoming(reply('phone-1', {'session_id': 'session-a', 'open_requests': [interaction()]}))['result']
        self.assertNotIn('open_requests', result)
        self.assertEqual(result['pending_interactions'][0]['params']['session_id'], result['session_id'])

    def test_legacy_resume_and_modern_resume_do_not_duplicate_approval(self):
        for modern in (False, True):
            adapter = MobileAdapter()
            adapter.request(request('session.resume', {'session_id': 'saved'}))
            body = {'session_id': 'session-a', 'pending_approval': {'request_id': 'native-approval', 'choices': ['deny']}}
            if modern:
                body['open_requests'] = [interaction()]
            cards = adapter.incoming(reply('phone-1', body))['result']['pending_interactions']
            self.assertEqual(len(cards), 1)
            self.assertEqual(cards[0]['params']['payload']['request_id'], 'jr-request:srq-a' if modern else 'native-approval')

    def test_interaction_ids_are_isolated_between_devices(self):
        first, second = MobileAdapter(), MobileAdapter()
        first.incoming(interaction())
        with self.assertRaises(ValueError):
            second.request(request('approval.respond', {'session_id': 'session-a', 'request_id': 'jr-request:srq-a', 'choice': 'deny'}))

    def test_unknown_interaction_is_visible_but_never_answered(self):
        adapter = MobileAdapter()
        result = adapter.incoming(interaction('new-sensitive-prompt'))
        self.assertEqual(result['params']['type'], 'status.update')
        self.assertFalse(adapter.inflight)

    def test_error_does_not_dispatch_alternative_or_claim_success(self):
        adapter = MobileAdapter()
        adapter.request(request('prompt.submit', {'session_id': 's', 'text': 'hello'}))
        error = {'jsonrpc': '2.0', 'id': 'phone-1', 'error': {'code': 5000, 'message': 'failed after write'}}
        self.assertEqual(adapter.incoming(error), error)
        self.assertFalse(adapter.inflight)


if __name__ == '__main__':
    unittest.main()
