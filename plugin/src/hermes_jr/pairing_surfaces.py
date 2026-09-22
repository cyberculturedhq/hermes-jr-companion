"""Small compatibility boundary for Hermes' existing native question renderers.

Hermes exposes execution middleware publicly, but not a cancellable plugin UI
handle. Keep the renderer-specific access here, check the owning session, and
fail closed on unsupported versions. Never import/start a second gateway.
"""
from __future__ import annotations

import queue
import sys
import threading
import uuid


class ClassicPanel:
    def __init__(self, cli):
        self.cli = cli
        self.responses = queue.Queue()
        self.panel = None
        self.closed = False
        if not all(callable(getattr(cli, name, None)) for name in ("_paint_now", "_clarify_teardown", "_ring_bell")):
            raise ValueError("Unsupported CLI")
        if not getattr(getattr(cli, "_app", None), "loop", None):
            raise ValueError("No interactive CLI")
        if any(getattr(cli, name, None) for name in ("_clarify_state", "_approval_state", "_sudo_state", "_secret_state")):
            raise ValueError("Another question is already open")

    def on_ui(self, action):
        finished = threading.Event()
        errors = []
        def apply():
            try:
                action()
            except Exception as exc:
                errors.append(exc)
            finally:
                finished.set()
        self.cli._app.loop.call_soon_threadsafe(apply)
        if not finished.wait(3) or errors:
            self.closed = True
            raise ValueError("The CLI question panel is unavailable")

    def show(self, text):
        def update():
            if self.closed:
                return
            cli = self.cli
            if self.panel is None:
                if any(getattr(cli, name, None) for name in ("_clarify_state", "_approval_state", "_sudo_state", "_secret_state")):
                    raise ValueError("Another question is already open")
                self.panel = {"question": text, "choices": ["Cancel pairing"], "selected": 0,
                              "multi_select": False, "selected_indices": None, "response_queue": self.responses}
                cli._clarify_state = self.panel
                cli._clarify_deadline = None
                cli._clarify_freetext = False
                cli._clarify_multi_base = None
                cli._ring_bell(prompt=True, context="clarify")
            elif cli._clarify_state is not self.panel:
                self.closed = True
                return
            self.panel["question"] = text
            cli._paint_now()
        self.on_ui(update)

    def cancelled(self):
        return self.closed or not self.responses.empty() or (self.panel is not None and self.cli._clarify_state is not self.panel)

    def close(self):
        self.closed = True
        if self.panel is not None:
            def clear():
                if self.cli._clarify_state is self.panel:
                    self.cli._clarify_teardown()
            self.on_ui(clear)


class GatewayPanel:
    def __init__(self, requests, sid):
        self.requests, self.sid = requests, sid
        self.responses = queue.Queue()
        self.settle = None
        if callable(getattr(requests, "open_requests", None)) and requests.open_requests(sid):
            raise ValueError("Another question is already open")

    def show(self, text):
        self.close()
        if callable(getattr(self.requests, "open_requests", None)) and self.requests.open_requests(self.sid):
            raise ValueError("Another question is already open")
        self.settle = self.requests.send_async("clarify", self.sid,
            {"question": text, "choices": ["Cancel pairing"]}, self.responses.put)

    def cancelled(self):
        return not self.responses.empty()

    def close(self):
        if self.settle:
            self.settle("resolved")
            self.settle = None


class LegacyGatewayPanel:
    """Pre-JSON-RPC question transport, with the same request ownership rules."""
    def __init__(self, server, sid):
        self.server, self.sid = server, sid
        self.rid = None
        self.event = None
        self.answered = False
        if not callable(getattr(server, "_emit", None)) or not all(
                hasattr(server, name) for name in ("_prompt_lock", "_pending", "_answers", "_pending_prompt_payloads")):
            raise ValueError("Unsupported gateway")
        with server._prompt_lock:
            self.check_available()

    def check_available(self):
        if any(owner == self.sid for owner, _ in self.server._pending.values()):
            raise ValueError("Another question is already open")

    def show(self, text):
        self.close()
        if self.cancelled():
            return
        server = self.server
        payload = {"question": text, "choices": ["Cancel pairing"], "request_id": uuid.uuid4().hex}
        with server._prompt_lock:
            self.check_available()
            self.rid, self.event = payload["request_id"], threading.Event()
            server._pending[self.rid] = (self.sid, self.event)
            server._pending_prompt_payloads[self.rid] = ("clarify.request", payload)
        server._emit("clarify.request", self.sid, dict(payload))

    def cancelled(self):
        return self.answered or (self.event is not None and self.event.is_set())

    def close(self):
        if self.rid is None:
            return
        server, rid = self.server, self.rid
        with server._prompt_lock:
            self.answered = self.answered or self.event.is_set()
            server._pending.pop(rid, None)
            server._pending_prompt_payloads.pop(rid, None)
            server._answers.pop(rid, None)
        self.rid = None
        server._emit("clarify.expire", self.sid, {"request_id": rid})


def resolve(ctx, session_id):
    if not session_id:
        raise ValueError("No owning conversation")
    cli = getattr(getattr(ctx, "_manager", None), "_cli_ref", None)
    if cli is not None:
        if getattr(getattr(cli, "agent", None), "session_id", None) != session_id:
            raise ValueError("Another CLI conversation owns this tool call")
        return ClassicPanel(cli)
    server = sys.modules.get("tui_gateway.server")
    requests = sys.modules.get("tui_gateway.server_requests")
    if server is None:
        raise ValueError("No native question renderer")
    with server._sessions_lock:
        matches = [sid for sid, session in server._sessions.items()
                   if session_id in (sid, session.get("session_key"), getattr(session.get("agent"), "session_id", None))]
    if len(matches) != 1:
        raise ValueError("No unique owning conversation")
    if requests is not None and callable(getattr(requests, "send_async", None)):
        return GatewayPanel(requests, matches[0])
    return LegacyGatewayPanel(server, matches[0])
