"""Explicitly supervised outbound bridge. Nothing starts until `hermes jr run`."""
from __future__ import annotations
import asyncio
import base64
import contextlib
import json
import logging
import time
import uuid
import aiohttp
from .gateway import Gateway, LocalPeer, validate_rpc
from .secure_channel import HostHandshake
from .service import Service

log = logging.getLogger("hermes_jr")


class Peer:
    def __init__(self, bridge, device_id):
        self.bridge, self.device_id = bridge, device_id
        self.handshake = None
        self.channel = None
        self.phase = "offline"
        self.pending_since = 0
        self.lock = asyncio.Lock()
        self.local = LocalPeer(bridge.gateway, self.emit)

    def reset(self, connected=False):
        if self.channel:
            self.channel.invalidate()
        if self.handshake:
            self.handshake.invalidate()
        self.channel = None
        self.handshake = None
        self.phase = "hello" if connected else "offline"

    async def raw(self, record):
        socket = self.bridge.socket
        if not socket or socket.closed:
            raise ConnectionError("Relay is offline")
        await socket.send_bytes(uuid.UUID(self.device_id).bytes + record)

    async def emit(self, value):
        async with self.lock:
            if self.channel is None or not self.bridge.state.device(self.device_id):
                return  # Durable history is the reconnect source; never keep an unbounded RAM backlog.
            try:
                channel, socket = self.channel, self.bridge.socket
                for record in channel.seal(json.dumps(value, separators=(",", ":")).encode()):
                    if channel is not self.channel or socket is not self.bridge.socket:
                        return
                    await self.raw(record)
            except Exception:
                self.reset()

    async def authorize(self):
        device = self.bridge.state.device(self.device_id)
        if self.phase != "pending" or not device or not device["approved"]:
            return
        async with self.lock:
            record, self.channel = self.handshake.finish()
            self.phase = "ready"
            await self.raw(record)

    async def receive(self, record):
        device = self.bridge.state.device(self.device_id)
        if not device:
            self.reset()
            return
        if self.phase == "hello":
            private_key = base64.urlsafe_b64decode(self.bridge.state.get("host_private_key") + "=")
            self.handshake = HostHandshake(private_key)
            await self.raw(self.handshake.receive_hello(record))
            self.phase = "auth"
            return
        if self.phase == "auth":
            auth = json.loads(self.handshake.receive_auth(record))
            if not isinstance(auth, dict) or not isinstance(auth.get("pairing_secret", ""), str) or not isinstance(auth.get("device_name", "iPhone"), str):
                raise ValueError("Invalid device authentication")
            self.bridge.state.accept_pair(self.device_id, self.handshake.device_public_key,
                                           auth.get("pairing_secret", ""), auth.get("device_name", "iPhone"))
            self.phase = "pending"
            self.pending_since = time.time()
            await self.authorize()
            return
        if self.phase != "ready" or not device["approved"]:
            raise PermissionError("Device authorization is pending")
        plaintext = self.channel.receive(record)
        if plaintext is None:
            return
        envelope = json.loads(plaintext)
        if not isinstance(envelope, dict):
            raise ValueError("Expected an application envelope")
        if envelope.get("type") == "rpc":
            frame = envelope.get("body")
            try:
                validate_rpc(frame)
            except ValueError:
                await self.emit({"type": "rpc", "body": {"jsonrpc": "2.0", "id": frame.get("id") if isinstance(frame, dict) else None,
                                                        "error": {"code": -32601, "message": "Operation is not allowed by the companion"}}})
                return
            try:
                await self.local.send(frame)
            except (ValueError, PermissionError, aiohttp.ClientError, ConnectionError, TimeoutError):
                await self.emit({"type": "rpc", "body": {"jsonrpc": "2.0", "id": frame.get("id") if isinstance(frame, dict) else None,
                                                        "error": {"code": -32000, "message": "Your iPhone reached the companion, but it couldn’t connect to the local Hermes backend. Restore the Hermes backend, then reconnect."}}})
        elif envelope.get("type") == "http":
            status, body = 500, {"detail": "The local Hermes service is unavailable"}
            try:
                status, body = await self.bridge.gateway.http(self.device_id, envelope)
            except PermissionError:
                status, body = 403, {"detail": "Operation is not allowed"}
            except LookupError:
                status, body = 404, {"detail": "Operation or notification not found"}
            except (ValueError, TypeError):
                status, body = 400, {"detail": "Invalid request or companion service configuration"}
            except (aiohttp.ClientError, TimeoutError):
                pass
            await self.emit({"type": "http", "id": envelope.get("id"), "status": status, "body": body})
            if envelope.get("path") in {"/api/profiles", "/api/plugins/hermes-jr/v1/mobile/api/profiles"} and status == 200 and isinstance(body, dict) and isinstance(body.get("profiles"), list):
                self.bridge.state.set("setup-ready/" + self.device_id, True)
        else:
            raise ValueError("Unknown application envelope")


class Bridge:
    def __init__(self, state, client):
        self.state, self.client = state, client
        self.service = Service(state, client)
        self.gateway = Gateway(state, client)
        self.peers = {}
        self.socket = None

    async def relay(self):
        delay = 1
        while True:
            if not self.state.get("relay_enabled", False):
                await asyncio.sleep(1)
                continue
            try:
                url = self.service.url(f"/v1/installations/{self.state.get('installation_id')}/host")
                async with self.client.ws_connect(url, headers={"Authorization": "Bearer " + self.state.get("host_token")},
                                                 heartbeat=20, max_msg_size=65552) as socket:
                    self.socket = socket
                    delay = 1
                    log.info("Encrypted remote access connected")
                    async for message in socket:
                        if not self.state.get("relay_enabled", False):
                            await socket.close()
                            break
                        if message.type == aiohttp.WSMsgType.TEXT:
                            control = json.loads(message.data)
                            device_id = str(uuid.UUID(control.get("device_id", "")))
                            if not self.state.device(device_id):
                                continue
                            if control.get("type") == "peer_connected":
                                peer = self.peers.setdefault(device_id, Peer(self, device_id))
                                peer.reset(connected=True)
                            elif control.get("type") == "peer_disconnected" and device_id in self.peers:
                                self.peers[device_id].reset()
                        elif message.type == aiohttp.WSMsgType.BINARY:
                            if len(message.data) < 17:
                                continue
                            device_id = str(uuid.UUID(bytes=message.data[:16]))
                            peer = self.peers.get(device_id)
                            if peer:
                                try:
                                    await peer.receive(message.data[16:])
                                except Exception:
                                    peer.reset()
                                    log.warning("Rejected an invalid device connection")
            except (aiohttp.ClientError, ValueError, TypeError, ConnectionError, TimeoutError):
                log.warning("Relay unavailable; reconnecting")
            finally:
                self.socket = None
                for peer in self.peers.values():
                    peer.reset()
            await asyncio.sleep(delay)
            delay = min(delay * 2, 30)

    async def maintenance(self):
        tick = 0
        while True:
            if not self.state.get("relay_enabled", False) and self.socket:
                await self.socket.close()
            for device_id, peer in list(self.peers.items()):
                if not self.state.device(device_id):
                    peer.reset()
                    await peer.local.close()
                    del self.peers[device_id]
                elif peer.phase == "pending":
                    if time.time() - peer.pending_since > 600:
                        peer.reset()
                    else:
                        with contextlib.suppress(Exception):
                            await peer.authorize()
            if tick % 5 == 0 and self.state.get("push_enabled", False):
                for event in self.state.outbox():
                    ok = False
                    try:
                        await self.service.send_push(event)
                        ok = True
                    except (aiohttp.ClientError, ValueError, TimeoutError):
                        log.warning("Notification service unavailable; delivery will retry")
                    self.state.sent(event["reference"], ok)
            tick += 1
            await asyncio.sleep(1)

    async def run(self):
        from .setup_jobs import watch as watch_setup
        from .cleanup import watch as watch_cleanup
        from .updates import watch as watch_updates
        from .diagnostics import watch as watch_health
        tasks = [asyncio.create_task(self.relay()), asyncio.create_task(self.maintenance()),
                 asyncio.create_task(watch_updates(self.state, self.client)),
                 asyncio.create_task(watch_health(self.state, self.client)),
                 asyncio.create_task(watch_cleanup(self.state, self.service)),
                 asyncio.create_task(watch_setup(self.state, self.service))]
        try:
            await asyncio.gather(*tasks)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            for peer in self.peers.values():
                peer.reset()
                await peer.local.close()
