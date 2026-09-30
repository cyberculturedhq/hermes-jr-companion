import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from pydantic import BaseModel, ConfigDict

from hermes_jr.state import State
from hermes_jr import pairing_panel as panel, setup_jobs as jobs
from hermes_jr.pairing_surfaces import ClassicPanel, GatewayPanel, LegacyGatewayPanel, resolve


class Surface:
    def __init__(self):
        self.questions = []
        self.is_cancelled = False
        self.closed = False
    def show(self, text): self.questions.append(text)
    def cancelled(self): return self.is_cancelled
    def close(self): self.closed = True


class PairingPanelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = State(Path(self.temp.name))
        jobs.initialize(self.state)
        self.job = 'a' * 64
        with self.state.connect() as db:
            db.execute("INSERT INTO setup_jobs VALUES (?, 'public-ticket', 'Phone', 'pending', NULL, ?, ?)",
                       (self.job, time.time() + 60, time.time()))

    def ready(self):
        jobs.publish(self.state, self.job, 'ready', code='1234 5678 9012')

    def lease(self):
        nonce = 'b' * 64
        self.state.set('pairing-panel/' + nonce, {'version': 1, 'pid': os.getpid(), 'expires': time.time() + 60})
        return nonce

    def test_no_loaded_panel_cannot_claim_a_pairing_command(self):
        with patch.dict(os.environ, {panel.LEASE_ENV: ''}):
            with self.assertRaisesRegex(ValueError, 'not active'):
                panel.claim(self.state, self.job)

    def test_lease_is_bound_to_one_attempt_and_expires(self):
        nonce = self.lease()
        with patch.dict(os.environ, {panel.LEASE_ENV: nonce}):
            panel.claim(self.state, self.job)
            with self.assertRaises(ValueError): panel.claim(self.state, 'c' * 64)
            lease = self.state.get('pairing-panel/' + nonce)
            lease['expires'] = time.time() - 1
            self.state.set('pairing-panel/' + nonce, lease)
            with self.assertRaises(ValueError): panel.claim(self.state, self.job)

    def test_live_panel_owns_attempt_but_dead_process_can_be_recovered(self):
        first = self.lease()
        with patch.dict(os.environ, {panel.LEASE_ENV: first}):
            panel.claim(self.state, self.job)
        second = 'd' * 64
        self.state.set('pairing-panel/' + second, {'version': 1, 'pid': os.getpid(), 'expires': time.time() + 60})
        with patch.dict(os.environ, {panel.LEASE_ENV: second}):
            with self.assertRaisesRegex(ValueError, 'already has'):
                panel.claim(self.state, self.job)
            owner = self.state.get('pairing-panel/' + first)
            owner['pid'] = -1
            self.state.set('pairing-panel/' + first, owner)
            panel.claim(self.state, self.job)
        self.assertEqual(self.state.get('pairing-panel-owner/' + self.job), second)

    def middleware(self, surface):
        callbacks = []
        panel.register(SimpleNamespace(register_middleware=lambda kind, fn: callbacks.append(fn)))
        self.addCleanup(patch.stopall)
        patch('hermes_jr.pairing_panel.State', return_value=self.state).start()
        patch('hermes_jr.pairing_surfaces.resolve', return_value=surface).start()
        return callbacks[0]

    def test_middleware_leaves_unrelated_commands_untouched(self):
        arguments = {'command': 'hermes jr doctor', 'background': True}
        received = []
        call = self.middleware(Surface())
        result = call('terminal', arguments, lambda value: received.append(value) or 'original')
        self.assertEqual(result, 'original')
        self.assertEqual(received, [arguments])
        self.assertIs(received[0], arguments)

    def test_middleware_preserves_preflight_error_and_cleans_lease(self):
        surface = Surface(); calls = []
        call = self.middleware(surface)
        original = json.dumps({'output': 'Backend is not ready', 'exit_code': 1})
        def execute(value):
            calls.append(value)
            nonce = re.search(panel.LEASE_ENV + '=([a-f0-9]+)', value['command'])[1]
            with patch.dict(os.environ, {panel.LEASE_ENV: nonce}):
                panel.claim(self.state, 'e' * 64)
            return original
        result = call('terminal', {'command': 'python -m hermes_jr.cli pair --ticket TICKET', 'background': True,
                                  'timeout': 1800, 'notify': True}, execute,
                      session_id='origin')
        self.assertEqual(result, original)
        self.assertEqual(len(calls), 1)
        self.assertFalse(calls[0]['background'])
        self.assertFalse(calls[0]['pty'])
        self.assertEqual(calls[0]['timeout'], 180)
        self.assertNotIn('notify', calls[0])
        self.assertTrue(surface.closed)
        with self.state.connect() as db:
            self.assertFalse(db.execute("SELECT key FROM settings WHERE key LIKE 'pairing-panel%'").fetchall())

    def test_unavailable_native_ui_does_not_execute_pairing(self):
        call = self.middleware(Surface())
        with patch('hermes_jr.pairing_surfaces.resolve', side_effect=ValueError('wrong session')):
            result = call('terminal', {'command': 'hermes jr pair --ticket TICKET'},
                          lambda _: self.fail('Must not launch pairing without a renderer'), session_id='other')
        self.assertEqual(json.loads(result)['exit_code'], 1)

    def test_yielded_subprocess_cannot_leave_an_attempt_without_a_panel(self):
        call = self.middleware(Surface())
        nonce = None
        def execute(value):
            nonlocal nonce
            nonce = re.search(panel.LEASE_ENV + '=([a-f0-9]+)', value['command'])[1]
            with patch.dict(os.environ, {panel.LEASE_ENV: nonce}):
                panel.claim(self.state, self.job)
            return json.dumps({'status': 'yielded_to_background', 'exit_code': None})
        result = call('terminal', {'command': 'hermes jr pair --ticket TICKET'}, execute, session_id='origin')
        self.assertEqual(json.loads(result)['exit_code'], 1)
        self.assertEqual(jobs.result(self.state, self.job)['reason'], 'cancelled')
        with self.state.connect() as db, patch.dict(os.environ, {panel.LEASE_ENV: nonce}):
            db.execute('BEGIN IMMEDIATE')
            with self.assertRaises(ValueError):
                panel.claim(self.state, self.job, connection=db)

    def test_phone_completion_closes_panel_without_local_answer(self):
        surface = Surface()
        self.ready()
        def phone():
            while not surface.questions: time.sleep(.005)
            self.assertIn('1234 5678 9012', surface.questions[-1])
            jobs.publish(self.state, self.job, 'connected')
        thread = threading.Thread(target=phone)
        thread.start()
        result = panel.wait(self.state, self.job, surface, poll=.005)
        thread.join(2)
        self.assertEqual(result['status'], 'connected')
        self.assertTrue(surface.closed)
        self.assertNotIn('1234', json.dumps(result))

    def test_local_answer_cancels_and_never_confirms(self):
        surface = Surface(); surface.is_cancelled = True
        self.ready()
        result = panel.wait(self.state, self.job, surface)
        self.assertEqual(result['reason'], 'cancelled')
        self.assertFalse(jobs.publish(self.state, self.job, 'connected'))
        self.assertTrue(surface.closed)

    def test_expiry_dismisses_and_hides_code(self):
        self.ready()
        with self.state.connect() as db:
            db.execute('UPDATE setup_jobs SET expires=?', (time.time() - 1,))
        surface = Surface()
        result = panel.wait(self.state, self.job, surface)
        self.assertEqual(result['status'], 'expired')
        self.assertTrue(surface.closed)
        self.assertNotIn('code', result)

    def test_panel_error_cancels_attempt(self):
        surface = Surface()
        surface.show = lambda text: (_ for _ in ()).throw(ValueError('missing renderer'))
        with self.assertRaises(ValueError): panel.wait(self.state, self.job, surface)
        self.assertEqual(jobs.result(self.state, self.job)['reason'], 'cancelled')

    def test_cancel_serializes_with_enrollment_and_preserves_existing_device(self):
        self.state.add_device('existing', 'Old phone', 'existing-route', paired=True)
        self.state.add_device('new', 'New phone', 'new-route', automatic=True,
                              secret='secret', expires=time.time() + 60, setup_job_id=self.job)
        self.assertTrue(jobs.cancel(self.state, self.job))
        self.assertIsNone(self.state.device('new'))
        self.assertIsNotNone(self.state.device('existing'))
        with self.assertRaises(ValueError):
            self.state.add_device('late', 'Late phone', 'late-route', setup_job_id=self.job)
        self.assertFalse(jobs.publish(self.state, self.job, 'ready', code='1234 5678 9012'))

    def test_cancel_after_completed_pairing_does_not_revoke_it(self):
        self.state.add_device('new', 'Phone', 'route', setup_job_id=self.job)
        jobs.publish(self.state, self.job, 'connected')
        self.assertFalse(jobs.cancel(self.state, self.job))
        self.assertIsNotNone(self.state.device('new'))

    def test_pending_and_ready_tool_results_have_no_code_or_watcher(self):
        self.ready()
        result = panel.public_result(jobs.result(self.state, self.job))
        self.assertNotIn('1234', json.dumps(result))
        self.assertNotIn('completion_watch', result)


class NativeSurfaceTests(unittest.TestCase):
    def test_gateway_selects_loaded_clarification_contract_before_sending(self):
        class Question(BaseModel):
            qid: str
            question: str
            choices: list[str]

        class OldParams(BaseModel):
            model_config = ConfigDict(extra='forbid')
            session_id: str
            question: str | None = None
            choices: list[str] | None = None
            questions: list[Question] | None = None

        class NewParams(BaseModel):
            model_config = ConfigDict(extra='forbid')
            session_id: str
            questions: list[Question]

        for schema in (OldParams, NewParams):
            with self.subTest(schema=schema.__name__):
                shown, withdrawn, callbacks, pending = [], [], [], {}
                def send(method, sid, params, callback):
                    schema.model_validate({'session_id': sid, **params})
                    shown.append(params)
                    callbacks.append(callback)
                    return withdrawn.append
                def request(sid, method, params, *, qids):
                    return SimpleNamespace(id=str(len(shown)), sid=sid, params=params,
                        qids=qids, event=threading.Event(), result=None)
                def register(req):
                    schema.model_validate({'session_id': req.sid, **req.params})
                    pending[req.id] = req
                    shown.append(req.params)
                requests = SimpleNamespace(send_async=send, ServerRequest=request, _register=register,
                    _open=pending, _lock=threading.Lock(), _unanswerable=lambda *args: False,
                    _emit_cancel=lambda req, reason: withdrawn.append(reason))
                registry = SimpleNamespace(SERVER_REQUESTS={'clarify': SimpleNamespace(params=schema)})
                with patch.dict(sys.modules, {'tui_gateway.contracts.registry': registry}):
                    surface = GatewayPanel(requests, 'owner')
                    surface.show('Waiting')
                    surface.show('Compare the code')
                question = {'question': 'Compare the code', 'choices': ['Cancel pairing']}
                expected = {'questions': [{'qid': 'q1', **question}]} if schema is NewParams else question
                self.assertEqual(shown[-1], expected)
                self.assertEqual(withdrawn, ['resolved'])
                answer = {'answers': {'q1': 'Cancel pairing'}} if schema is NewParams else {'answer': 'Cancel pairing'}
                if schema is NewParams:
                    req = surface.batch_request
                    self.assertEqual(req.qids, ['q1'])
                    self.assertFalse(surface.cancelled())
                    pending.pop(req.id)
                    req.result = answer
                    req.event.set()  # Native clarify.lock settles without an async callback.
                else:
                    callbacks[-1](answer)
                self.assertTrue(surface.cancelled())
                if schema is NewParams:
                    req.event.clear()  # Settlement can remove the request before event.set().
                with patch.dict(sys.modules, {'tui_gateway.contracts.registry': registry}):
                    surface.show('A refresh after cancellation')
                self.assertTrue(surface.cancelled())
                self.assertEqual(len(shown), 2)
                pending['unrelated'] = object()
                surface.close()
                self.assertEqual(withdrawn, ['resolved'] if schema is NewParams else ['resolved', 'resolved'])
                self.assertEqual(set(pending), {'unrelated'})

    def test_questions_only_gateway_without_native_batch_lifecycle_fails_closed(self):
        registry = SimpleNamespace(SERVER_REQUESTS={'clarify': SimpleNamespace(
            params=SimpleNamespace(model_fields={'questions': None}))})
        requests = SimpleNamespace(send_async=lambda *args: self.fail('Sent an unanswerable batch'))
        with patch.dict(sys.modules, {'tui_gateway.contracts.registry': registry}):
            with self.assertRaisesRegex(ValueError, 'Unsupported gateway'):
                GatewayPanel(requests, 'owner').show('Code')

    def test_gateway_without_loaded_registry_keeps_single_question_transport(self):
        shown = []
        requests = SimpleNamespace(send_async=lambda method, sid, params, callback: shown.append(params))
        with patch.dict(sys.modules, {'tui_gateway.contracts.registry': None}):
            GatewayPanel(requests, 'owner').show('Code')
        self.assertEqual(shown, [{'question': 'Code', 'choices': ['Cancel pairing']}])

    def test_wrong_cli_conversation_is_rejected(self):
        context = SimpleNamespace(_manager=SimpleNamespace(_cli_ref=SimpleNamespace(agent=SimpleNamespace(session_id='owner'))))
        with self.assertRaises(ValueError): resolve(context, 'other')

    def test_gateway_does_not_displace_a_new_unrelated_question(self):
        active = []
        surface = GatewayPanel(SimpleNamespace(open_requests=lambda _: active), 'origin')
        active.append('unrelated')
        with self.assertRaises(ValueError): surface.show('Code')

    def test_legacy_gateway_cleans_only_its_request(self):
        events = []
        server = SimpleNamespace(_prompt_lock=threading.Lock(), _pending={}, _answers={},
            _pending_prompt_payloads={}, _emit=lambda *event: events.append(event))
        surface = LegacyGatewayPanel(server, 'origin')
        surface.show('Code')
        rid = surface.rid
        server._pending['unrelated'] = ('other', threading.Event())
        server._answers[rid] = 'Cancel pairing'
        server._pending[rid][1].set()
        self.assertTrue(surface.cancelled())
        surface.close()
        self.assertEqual(set(server._pending), {'unrelated'})
        self.assertEqual(server._answers, {})
        self.assertEqual(events[-1], ('clarify.expire', 'origin', {'request_id': rid}))
        # A cancel arriving as the waiting panel gains its code must survive
        # that refresh, even though the old request is withdrawn.
        surface.show('Code after response')
        self.assertTrue(surface.cancelled())
        self.assertIsNone(surface.rid)
        self.assertEqual(set(server._pending), {'unrelated'})

    def test_classic_uses_native_question_state_and_clears_only_its_panel(self):
        loop = SimpleNamespace(call_soon_threadsafe=lambda fn: fn())
        cli = SimpleNamespace(_app=SimpleNamespace(loop=loop), _clarify_state=None,
                              _paint_now=lambda: None, _ring_bell=lambda **kwargs: None)
        cli._clarify_teardown = lambda: setattr(cli, '_clarify_state', None)
        surface = ClassicPanel(cli)
        surface.show('Compare the code')
        self.assertEqual(cli._clarify_state['choices'], ['Cancel pairing'])
        self.assertFalse(surface.cancelled())
        cli._clarify_state['response_queue'].put('Cancel pairing')
        self.assertTrue(surface.cancelled())
        surface.close()
        self.assertIsNone(cli._clarify_state)
        other = {'question': 'Unrelated'}
        cli._clarify_state = other
        surface.close()
        self.assertIs(cli._clarify_state, other)

    def test_classic_questions_only_callback_gets_refreshed_batch_state(self):
        activated = []
        cli = SimpleNamespace(_app=SimpleNamespace(loop=SimpleNamespace(call_soon_threadsafe=lambda fn: fn())),
            _clarify_state=None, _paint_now=lambda: None, _ring_bell=lambda **kwargs: None,
            _clarify_callback=lambda questions: None,
            _clarify_batch_set_active=lambda state, index: activated.append((state, index)))
        cli._clarify_teardown = lambda: setattr(cli, '_clarify_state', None)
        surface = ClassicPanel(cli)
        surface.show('Waiting')
        surface.show('Compare the code')
        state = cli._clarify_state
        self.assertEqual(state['questions'], [{'qid': 'q1', 'question': 'Compare the code',
            'choices': ['Cancel pairing'], 'multi_select': False}])
        self.assertEqual(state['answers'], {})
        self.assertEqual(state['answer_meta'], {})
        self.assertEqual(activated, [(state, 0)])
        state['response_queue'].put({'q1': 'Cancel pairing'})
        self.assertTrue(surface.cancelled())
        surface.close()
        self.assertIsNone(cli._clarify_state)

    def test_classic_callback_supporting_both_shapes_keeps_flat_state(self):
        cli = SimpleNamespace(_app=SimpleNamespace(loop=SimpleNamespace(call_soon_threadsafe=lambda fn: fn())),
            _clarify_state=None, _paint_now=lambda: None, _ring_bell=lambda **kwargs: None,
            _clarify_callback=lambda question, choices, multi_select=False, questions=None: None,
            _clarify_teardown=lambda: None)
        ClassicPanel(cli).show('Code')
        self.assertEqual(cli._clarify_state['question'], 'Code')
        self.assertNotIn('questions', cli._clarify_state)

    def test_gateway_replaces_pending_question_and_withdraws_matching_request(self):
        shown, withdrawn, callbacks = [], [], []
        def send(method, sid, params, callback):
            shown.append((method, sid, params)); callbacks.append(callback)
            n = len(shown)
            return lambda reason: withdrawn.append((n, reason))
        surface = GatewayPanel(SimpleNamespace(send_async=send), 'originating-session')
        surface.show('Waiting')
        surface.show('Code')
        self.assertEqual(withdrawn, [(1, 'resolved')])
        self.assertEqual(shown[-1][1], 'originating-session')
        callbacks[-1]({'answer': 'Cancel pairing'})
        self.assertTrue(surface.cancelled())
        surface.close()
        self.assertEqual(withdrawn[-1], (2, 'resolved'))
