"""Jr mobile protocol v1. Only this module knows Hermes wire differences.

The existing operation names are frozen under jr.v1.*; future Hermes changes
must be translated here rather than propagated to mobile clients. No mutation
is retried or dispatched through an alternate route after an uncertain result.
"""
from __future__ import annotations
import hashlib
import json
import time

PREFIX = 'jr.v1.'
SCOPED = {'profile', 'session_id'}
PARAMS = {
    'gateway.ping': set(), 'profiles.list': {'include_sessions'},
    'profiles.get_asset': {'name', 'asset'},
    'session.create': {'profile', 'source', 'close_on_disconnect'},
    'session.resume': SCOPED | {'defer_history', 'omit_messages'},
    'session.interrupt': SCOPED, 'session.status': SCOPED,
    'session.title': SCOPED | {'title'},
    'session.compress': SCOPED | {'focus_topic'}, 'session.save': SCOPED,
    'prompt.submit': {'session_id', 'text'},
    'approval.received': {'session_id', 'request_id'},
    'approval.respond': {'session_id', 'request_id', 'choice', 'all'},
    'clarify.respond': {'session_id', 'request_id', 'question_id', 'answer'},
    'image.attach_bytes': {'session_id', 'content_base64', 'filename'},
    'image.detach': {'session_id', 'path'}, 'process.stop': SCOPED,
    'commands.catalog': SCOPED, 'complete.slash': SCOPED | {'text'},
    'model.options': SCOPED,
    'config.get': {'key'},
    'config.set': SCOPED | {'key', 'value', 'confirm_expensive_model'},
    'slash.exec': SCOPED | {'command'},
    'command.dispatch': SCOPED | {'name', 'arg'},
}
FEATURES = {
    'chat': True, 'history': True, 'images': True,
    'command_catalog': True, 'slash_completion': True,
    'approval': True, 'clarification': True,
    'interaction_replay': True,
    'secret_input': 'dashboard',
    'completion_scope': 'gateway_filtered_by_catalog',
}
# Change when adapter behavior or supported features change, independently of
# package version, encrypted transport version, and Hermes's desktop contract.
ADAPTER_REVISION = 1
REVISION = hashlib.sha256(json.dumps({
    'protocol': 1, 'adapter': ADAPTER_REVISION, 'features': FEATURES,
    'params': {k: sorted(v) for k, v in PARAMS.items()},
}, sort_keys=True).encode()).hexdigest()


def negotiate(params):
    if not isinstance(params, dict) or set(params) - {'protocols', 'known_revision'}:
        raise ValueError('Invalid mobile negotiation')
    versions = params.get('protocols')
    if not isinstance(versions, list) or not any(type(v) is int and v == 1 for v in versions):
        raise ValueError('No shared mobile protocol. Update the companion or app.')
    unchanged = params.get('known_revision') == REVISION
    result = {'protocol': 1, 'revision': REVISION, 'unchanged': unchanged}
    if not unchanged:
        result['features'] = dict(FEATURES)
    return result


def event(kind, sid, payload):
    return {'jsonrpc': '2.0', 'method': 'event',
            'params': {'session_id': sid, 'type': kind, 'payload': payload}}


def reply(rid, result):
    return {'jsonrpc': '2.0', 'id': rid, 'result': result}


class MobileAdapter:
    def __init__(self):
        self.interactions = {}
        self.inflight = {}

    def request(self, frame):
        """Return one backend request, or raise before sending anything."""
        method = frame.get('method', '')
        if not isinstance(method, str) or not method.startswith(PREFIX):
            raise ValueError('Mobile v1 operation required')
        method = method[len(PREFIX):]
        params = frame.get('params', {})
        if method not in PARAMS or not isinstance(params, dict) or set(params) - PARAMS[method]:
            raise ValueError('Unsupported mobile v1 operation or parameters')
        rid = frame.get('id')
        if not isinstance(rid, str) or not rid or len(rid) > 200:
            raise ValueError('Mobile request ID required')
        # Bound unanswered RPC bookkeeping even if a backend never responds.
        now = time.monotonic()
        self.inflight = {k: v for k, v in self.inflight.items() if now - v[2] < 660}
        if rid in self.inflight or len(self.inflight) >= 512:
            raise ValueError('Too many pending mobile requests or duplicate ID')
        out = dict(params)
        translated = method
        if method == 'complete.slash':
            # This endpoint was permissive in v6, text-only in v7. Neither
            # guarantees profile scoping; clients filter using commands.catalog.
            out = {'text': params.get('text', '')}
        public_id = params.get('request_id', '')
        interaction = self.interactions.get(public_id)
        if isinstance(public_id, str) and public_id.startswith('jr-request:'):
            if not interaction or params.get('session_id') != interaction['sid']:
                raise ValueError('This interaction is no longer pending in this session')
            kind = interaction['method']
            if method.startswith('approval.') and kind != 'approval' or method == 'clarify.respond' and kind != 'clarify':
                raise ValueError('Interaction kind does not match')
            if method == 'approval.received':
                out['request_id'] = interaction['params']['request_id']
            elif method == 'approval.respond':
                if params.get('all', False) is not False or params.get('choice') not in interaction['params'].get('choices', []):
                    raise ValueError('Unsupported approval choice')
                translated = 'request.answer'
                out = {'id': interaction['id'], 'result': {'choice': params['choice'], 'all': False}}
            elif method == 'clarify.respond':
                if not isinstance(params.get('answer'), str):
                    raise ValueError('An answer is required')
                questions = interaction['params'].get('questions')
                if questions:
                    qid = params.get('question_id')
                    if qid not in {q.get('qid') for q in questions}:
                        raise ValueError('Unknown clarification question')
                    translated = 'clarify.lock'
                    out = {'request_id': interaction['id'], 'question_id': qid, 'answer': params['answer']}
                else:
                    translated = 'request.answer'
                    out = {'id': interaction['id'], 'result': {'answer': params['answer']}}
        self.inflight[rid] = (method, translated, now, public_id)
        return {'jsonrpc': '2.0', 'id': rid, 'method': translated, 'params': out}

    def incoming(self, frame):
        """Translate response/event/server request without executing any action."""
        if not isinstance(frame, dict):
            raise ValueError('Invalid Hermes frame')
        if frame.get('method') in {'approval', 'clarify', 'sudo', 'secret'} and 'id' in frame:
            return self.interaction(frame)
        if 'method' in frame and 'id' in frame:
            # Unknown blocking interactions must be visible; never approve or
            # silently answer them. The backend remains authoritative.
            sid = (frame.get('params') or {}).get('session_id')
            return event('status.update', sid, {'text': 'Hermes needs input in its dashboard. Open the dashboard to respond.'})
        if frame.get('method') == 'event':
            params = frame.get('params', {})
            if params.get('type') == 'request.cancel':
                payload = params.get('payload', {})
                public_id = 'jr-request:' + str(payload.get('id', ''))
                pending = self.interactions.pop(public_id, None)
                if pending:
                    return event(pending['method'] + '.expire', pending['sid'], {'request_id': public_id})
            return frame
        pending = self.inflight.pop(frame.get('id'), None)
        if not pending or 'error' in frame:
            return frame
        method, translated, _, public_id = pending
        result = frame.get('result')
        if not isinstance(result, dict):
            raise ValueError('Hermes returned an unsupported result')
        result = dict(result)
        if method == 'approval.respond' and translated == 'request.answer':
            result = {'resolved': result.get('status') == 'ok'}
            self.interactions.pop(public_id, None)
        elif method == 'clarify.respond' and translated == 'request.answer':
            self.interactions.pop(public_id, None)
        elif method == 'clarify.respond' and translated == 'clarify.lock':
            if result.get('status') == 'expired' or result.get('remaining') == []:
                self.interactions.pop(public_id, None)
        if method in {'session.create', 'session.resume'}:
            # Carry replay in the response so the phone first binds the returned
            # session, then displays its pending interactions (no timing race).
            result['pending_interactions'] = [self.incoming(r) for r in result.pop('open_requests', [])]
            for key, kind in [('pending_approval', 'approval.request'), ('pending_clarify', 'clarify.request')]:
                payload = result.pop(key, None)
                if isinstance(payload, dict) and payload and not any(
                        item.get('params', {}).get('type') == kind for item in result['pending_interactions']):
                    result['pending_interactions'].append(event(kind, result.get('session_id'), payload))
        return {**frame, 'result': result}

    def interaction(self, frame):
        params = frame.get('params', {})
        sid, rid, method = params.get('session_id'), frame.get('id'), frame.get('method')
        if not isinstance(sid, str) or not isinstance(rid, str) or method not in {'approval', 'clarify', 'sudo', 'secret'}:
            raise ValueError('Unsupported Hermes interaction')
        public_id = 'jr-request:' + rid
        if public_id not in self.interactions and len(self.interactions) >= 256:
            raise ValueError('Too many pending Hermes interactions')
        self.interactions[public_id] = {'id': rid, 'sid': sid, 'method': method, 'params': dict(params)}
        payload = {k: v for k, v in params.items() if k != 'session_id'}
        payload['request_id'] = public_id
        return event(method + '.request', sid, payload)
