"""Host-side client for the public relay/push service API."""
from __future__ import annotations
import json
from urllib.parse import urlsplit
import aiohttp


async def read_bounded(response, limit: int) -> bytes:
    """Read through EOF without mistaking one available chunk for the complete body."""
    data = bytearray()
    try:
        async for chunk in response.content.iter_chunked(min(65536, limit + 1)):
            if len(data) + len(chunk) > limit:
                raise ValueError("HTTP response exceeds the permitted size")
            data.extend(chunk)
        return bytes(data)
    except BaseException:
        # Do not drain an untrusted oversized/infinite response or leave its socket alive.
        response.close()
        raise


def client_session(**kwargs):
    """Also reject WebSocket handshake redirects before any second request is sent."""
    trace = aiohttp.TraceConfig()
    async def reject_redirect(session, context, params):
        raise PermissionError("Companion network redirects are not allowed")
    trace.on_request_redirect.append(reject_redirect)
    return aiohttp.ClientSession(trace_configs=[trace], **kwargs)


def validate_service_url(value: str, *, allow_local=False) -> str:
    parts = urlsplit(value)
    local = parts.hostname in {"localhost", "127.0.0.1", "::1"}
    if parts.username or parts.password or parts.query or parts.fragment or parts.path not in {"", "/"}:
        raise ValueError("Service URL must be an origin without credentials, path, query, or fragment")
    if parts.scheme != "https" and not (allow_local and local and parts.scheme == "http"):
        raise ValueError("Service URL must use HTTPS; local development explicitly allows loopback HTTP")
    if not parts.hostname:
        raise ValueError("Service URL needs a host")
    return value.rstrip("/")


class ServiceError(ValueError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"Service rejected request (HTTP {status})")


class Service:
    def __init__(self, state, client, origin=None):
        self.state, self.client = state, client
        self.origin = origin

    def url(self, suffix):
        origin = self.origin or self.state.get("service_url")
        if not origin:
            raise ValueError("Run hermes jr setup with your service URL first")
        return origin + suffix

    def device_path(self, device_id):
        return f"/v1/installations/{self.state.get('installation_id')}/devices/{device_id}"

    async def request(self, method, path, body=None, credential=None):
        headers = {"Authorization": "Bearer " + credential} if credential else {}
        async with self.client.request(method, self.url(path), json=body, headers=headers,
                                       allow_redirects=False, timeout=aiohttp.ClientTimeout(total=15)) as response:
            raw = await read_bounded(response, 65536)
            if response.status >= 300:
                raise ServiceError(response.status)
            return json.loads(raw) if raw else {}

    async def add_device(self):
        return await self.request("POST", f"/v1/installations/{self.state.get('installation_id')}/devices", {}, self.state.get("host_token"))

    async def push_registration(self, device, body=None):
        return await self.request("DELETE" if body is None else "PUT", self.device_path(device["id"]) + "/push", body, device["service_token"])

    async def send_push(self, event):
        from .notification_crypto import encrypt
        body = {"reference": event["reference"]}
        key = self.state.notification_key(event["device_id"])
        if key:
            body["encrypted"] = encrypt(key, event, self.state.notification_detail(event["reference"]))
        return await self.request("POST", self.device_path(event["device_id"]) + "/push", body, self.state.get("host_token"))

    async def delete_device(self, device_id):
        try:
            await self.request("DELETE", self.device_path(device_id), credential=self.state.get("host_token"))
        except ServiceError as exc:
            if exc.status != 404:
                raise
