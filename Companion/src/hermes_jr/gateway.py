"""Allowlisted loopback REST/WebSocket adapter; dashboard credentials never leave this process."""
from __future__ import annotations
import asyncio
import json
import os
import re
from urllib.parse import urlsplit
import aiohttp
from .api import PREFIX, handle
from .service import read_bounded
from .mobile import MobileAdapter, PREFIX as MOBILE_PREFIX

RPC_METHODS = frozenset({
    "gateway.ping", "profiles.list", "profiles.get_asset", "session.create", "session.resume",
    "session.interrupt", "session.status", "session.title", "session.compress", "session.save",
    "prompt.submit", "approval.received", "approval.respond", "clarify.respond", "image.attach_bytes",
    "image.detach", "process.stop", "commands.catalog", "complete.slash", "model.options",
    "config.get", "config.set", "slash.exec", "command.dispatch",
})
HTTP_PATH = re.compile(r"/api/(?:profiles|sessions|sessions/[A-Za-z0-9_.:-]+(?:/(?:messages|latest-descendant))?)\Z")
QUERY_KEYS = frozenset({"profile", "order", "limit", "offset", "source", "search", "include_sessions"})
MAX_MESSAGE = 4_000_000


def dashboard_url(value):
    parts = urlsplit(value)
    if parts.scheme not in {"http", "https"} or parts.hostname not in {"127.0.0.1", "::1", "localhost"} or parts.username or parts.password or parts.query or parts.fragment or parts.path not in {"", "/"}:
        raise ValueError("Dashboard must be a loopback HTTP(S) origin")
    return value.rstrip("/")


def validate_rpc(frame):
    if not isinstance(frame, dict) or frame.get("jsonrpc") != "2.0":
        raise ValueError("RPC operation is not allowed")
    name = frame.get('method', '')
    if not isinstance(name, str):
        raise ValueError("RPC operation is not allowed")
    name = name.removeprefix(MOBILE_PREFIX)
    if name not in RPC_METHODS:
        raise ValueError("RPC operation is not allowed")
    params = frame.get("params", {})
    if not isinstance(params, dict):
        raise ValueError("RPC parameters must be an object")
    if name == "config.get" and params.get("key") not in {"profile", "model", "reasoning", "provider", "reasoning_effort"}:
        raise ValueError("Configuration key is not allowed")
    if name == "config.set" and params.get("key") not in {"model", "reasoning"}:
        raise ValueError("Configuration key is not allowed")
    if name == "session.create":
        params = {**params, "close_on_disconnect": False}
    return {**frame, "params": params}


class Gateway:
    def __init__(self, state, client):
        self.state, self.client = state, client
        self.origin = dashboard_url(state.get("dashboard_url", "http://127.0.0.1:9119"))
        self.headers = {}
        self.local_token = ""
        self.authenticated = False

    async def authenticate(self):
        bearer = os.environ.get("HERMES_JR_DASHBOARD_TOKEN", "")
        local = os.environ.get("HERMES_JR_DASHBOARD_SESSION_TOKEN", "")
        if bearer:
            self.headers = {"Authorization": "Bearer " + bearer}
            self.authenticated = True
            return
        if not local:
            async with self.client.get(self.origin + "/", allow_redirects=False) as response:
                if response.status != 200:
                    raise ValueError("Cannot read the loopback Hermes dashboard")
                data = await read_bounded(response, 2_000_000)
            html = data.decode("utf-8", errors="replace")
            if "window.__HERMES_AUTH_REQUIRED__=false" not in html:
                raise ValueError("Set HERMES_JR_DASHBOARD_TOKEN for this authenticated dashboard")
            match = re.search(r'window\.__HERMES_SESSION_TOKEN__\s*=\s*("[^"\r\n]+")', html)
            if not match:
                raise ValueError("Dashboard did not provide a local session token")
            local = json.loads(match[1])
        self.local_token = local
        self.headers = {"X-Hermes-Session-Token": local}

    async def socket(self):
        # Refresh local bootstrap on every new connection to tolerate a dashboard restart.
        await self.authenticate()
        if self.authenticated:
            async with self.client.post(self.origin + "/api/auth/ws-ticket", json={}, headers=self.headers, allow_redirects=False) as response:
                if response.status != 200:
                    raise ValueError("Could not authorize the Hermes WebSocket")
                query = {"ticket": json.loads(await read_bounded(response, 65536))["ticket"]}
        else:
            query = {"token": self.local_token}
        return await self.client.ws_connect(self.origin + "/api/ws", params=query, headers=self.headers,
                                            max_msg_size=MAX_MESSAGE, heartbeat=20)

    async def probe(self):
        """Verify the actual RPC transport, not just the dashboard HTML page."""
        await asyncio.wait_for(self._probe(), 10)

    async def _probe(self):
        socket = await self.socket()
        try:
            await socket.send_json({"jsonrpc": "2.0", "id": "jr-health", "method": "gateway.ping", "params": {}})
            async for message in socket:
                if message.type != aiohttp.WSMsgType.TEXT:
                    raise ConnectionError("Hermes closed the diagnostic connection")
                value = json.loads(message.data)
                if isinstance(value, dict) and value.get("id") == "jr-health":
                    if value.get("result") != {"ok": True}:
                        raise ValueError("Hermes did not accept the diagnostic ping")
                    return
            raise ConnectionError("Hermes closed the diagnostic connection")
        finally:
            await socket.close()

    async def http(self, device_id, envelope):
        method, path = envelope.get("method", "GET"), envelope.get("path", "")
        query, body = envelope.get("query", {}), envelope.get("body", {})
        if not isinstance(path, str) or not isinstance(query, dict) or not isinstance(body, dict):
            raise ValueError("Invalid HTTP operation")
        mobile_path = PREFIX + '/v1/mobile/api/'
        if path.startswith(mobile_path):
            device = self.state.device(device_id)
            if not device or not device['approved']:
                raise PermissionError('Device is not authorized')
            path = '/api/' + path[len(mobile_path):]
        if path.startswith(PREFIX + "/"):
            result = await handle(self.state, device_id, method, path[len(PREFIX):], body, query, self.client)
            return 200, result
        if method != "GET" or not HTTP_PATH.fullmatch(path) or ".." in path or set(query) - QUERY_KEYS:
            raise PermissionError("HTTP operation is not allowed")
        if any(not isinstance(v, (str, int, bool)) or len(str(v)) > 256 for v in query.values()):
            raise ValueError("Invalid query value")
        await self.authenticate()
        async with self.client.get(self.origin + path, params={k: str(v) for k, v in query.items()}, headers=self.headers, allow_redirects=False) as response:
            data = await read_bounded(response, MAX_MESSAGE)
            if 300 <= response.status < 400:
                raise PermissionError("Dashboard redirects are not allowed")
            return response.status, json.loads(data)


class LocalPeer:
    """A device's local socket remains alive when its remote connection disappears."""
    def __init__(self, gateway, emit):
        self.gateway, self.emit = gateway, emit
        self.ws = None
        self.reader = None
        self.lock = asyncio.Lock()
        self.adapter = MobileAdapter()
        self.mobile = False

    async def send(self, frame):
        frame = validate_rpc(frame)
        async with self.lock:
            if self.ws is None or self.ws.closed:
                self.adapter = MobileAdapter()
                self.ws = await self.gateway.socket()
                self.reader = asyncio.create_task(self.read(), name="hermes-jr-local-reader")
            if frame['method'].startswith(MOBILE_PREFIX):
                self.mobile = True
                try:
                    frame = self.adapter.request(frame)
                except ValueError as exc:
                    await self.emit({'type': 'rpc', 'body': {'jsonrpc': '2.0', 'id': frame.get('id'),
                                    'error': {'code': -32602, 'message': str(exc)}}})
                    return
            await self.ws.send_json(frame)

    async def read(self):
        socket = self.ws
        try:
            async for message in socket:
                if message.type == aiohttp.WSMsgType.TEXT:
                    frame = json.loads(message.data)
                    if self.mobile:
                        frame = self.adapter.incoming(frame)
                    await self.emit({"type": "rpc", "body": frame})
        except (aiohttp.ClientError, ValueError, ConnectionError):
            pass
        finally:
            if self.mobile and socket is self.ws:
                await self.emit({'type': 'rpc', 'body': {'jsonrpc': '2.0', 'method': 'jr.backend.disconnected'}})
            await socket.close()

    async def close(self):
        if self.ws:
            await self.ws.close()
        if self.reader:
            self.reader.cancel()
