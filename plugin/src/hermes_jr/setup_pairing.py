"""Resumable phone-bound pairing; no credentials or private keys go to agent output."""
from __future__ import annotations
import asyncio
import fcntl
import hashlib
import hmac
import json
import os
import socket
import time
import uuid
import aiohttp
from . import setup_crypto as crypto
from .secure_channel import generate_private_key, public_key
from .service import read_bounded, ServiceError
from .state import token


class SetupBroker:
    def __init__(self, service, ticket, intent):
        self.service, self.ticket = service, ticket
        self.path = "/v1/pairing/" + intent

    async def request(self, method, suffix="", body=None, credential=None):
        headers = {"X-Hermes-Setup": self.ticket, "Authorization": "Bearer " + credential}
        async with self.service.client.request(method, self.service.url(self.path + suffix), json=body,
                headers=headers, allow_redirects=False) as response:
            raw = await read_bounded(response, 16_384)
            if response.status >= 300:
                raise ServiceError(response.status)
            return json.loads(raw)


class SetupExpired(ValueError):
    pass


async def run(state, service, ticket, name, report=None):
    if not state.get("relay_enabled") or not state.get("host_private_key"):
        raise ValueError("Configure and start the companion before pairing")
    if not 1 <= len(name) <= 80:
        raise ValueError("Invalid phone name")
    # Verification key comes from the configured HTTPS service, never a URL in the ticket.
    issuer = await service.request("GET", "/v1/pairing/key")
    intent = crypto.verify_ticket(ticket, issuer["public_key"], state.get("service_url"))
    broker = SetupBroker(service, ticket, intent["intent_id"])
    record_key = "setup/" + intent["intent_id"]
    lock_path = state.directory / "setup.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    owns_lock = False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            owns_lock = True
        except BlockingIOError:
            raise ValueError("A setup command is already waiting for the phone. Keep that command running.") from None
        saved = state.get(record_key)
        if saved and saved.get("terminal"):
            if saved.get("status") == "connected":
                if report: report("connected")
                return
            raise ValueError("This setup attempt has ended. Create a new prompt in Hermes Jr.")
        host_private = crypto.decode(state.get("host_private_key"), 32)
        if not saved:
            host_name = "".join(c for c in socket.gethostname() if 32 <= ord(c) < 127)[:80] or "Hermes"
            claim = {"claim_id": str(uuid.uuid4()), "installation_id": state.get("installation_id"),
                     "host_public_key": crypto.encode(public_key(host_private)), "host_name": host_name}
            ephemeral = generate_private_key()
            claim["commitment"] = crypto.commitment(crypto.context(ticket, claim), public_key(ephemeral))
            saved = {"claim": claim, "private": crypto.encode(ephemeral), "ticket_hash": hashlib.sha256(ticket.encode()).hexdigest(), "expires_at": intent["expires_at"]}
            state.set(record_key, saved)  # Commit private state BEFORE publishing anything; reuse on retry.
        claim = saved["claim"]
        if saved["ticket_hash"] != hashlib.sha256(ticket.encode()).hexdigest() or claim["host_public_key"] != crypto.encode(public_key(host_private)):
            raise ValueError("Setup identity changed. Create a new prompt in Hermes Jr.")
        if "credential" not in saved:
            # Client-chosen credential permits an identical retry after an uncertain response.
            saved["credential"] = token()
            state.set(record_key, saved)
        await broker.request("POST", "/claims", {**claim, "claim_token": saved["credential"]}, state.get("host_token"))
        suffix, credential = "/claims/" + claim["claim_id"], saved["credential"]
        if not report:
            print("Hermes is ready. Open Hermes Jr. on your iPhone to compare the codes. Keep this command running.", flush=True)
        displayed = False
        deadline = min(intent["expires_at"], saved.get("deadline", intent["expires_at"]))
        while time.time() < deadline:
            try:
                remote = await broker.request("GET", suffix, credential=credential)
                if remote["status"] in {"cancelled", "complete"}:
                    if saved.get("device_id") and (state.device(saved["device_id"]) or {}).get("approved") and state.get("setup-ready/" + saved["device_id"]):
                        state.set(record_key, {"terminal": True, "status": "connected", "expires_at": intent["expires_at"]})
                        if report: report("connected")
                        else: print("You’re connected. Your conversations are ready in Hermes Jr.", flush=True)
                        return
                    raise ValueError("Setup was cancelled or another installation was selected. Create a new prompt.")
                remote_key = remote.get("phone_ephemeral")
                if remote_key:
                    if saved.get("phone_ephemeral") not in (None, remote_key):
                        raise ValueError("The phone's setup key changed. Create a new prompt.")
                    if not saved.get("phone_ephemeral"):
                        saved.update(phone_ephemeral=remote_key, deadline=min(intent["expires_at"], int(time.time()) + 300))
                        state.set(record_key, saved)
                    deadline = saved["deadline"]
                    private = crypto.decode(saved["private"], 32)
                    phone = crypto.decode(remote_key, 32)
                    transcript = crypto.transcript(crypto.context(ticket, claim), public_key(private), phone)
                    code = crypto.comparison_code(private, phone, transcript)
                    await broker.request("PUT", suffix + "/reveal", {"host_ephemeral": crypto.encode(public_key(private))}, credential)
                    if not displayed:
                        if report: report("ready", code=code, expires_at=deadline)
                        else: print(f"Pairing code: {code}\nCheck all three groups match on your iPhone, then tap ‘It’s correct’. If they differ, cancel.", flush=True)
                        displayed = True
                    if remote.get("confirmation"):
                        if not hmac.compare_digest(remote["confirmation"], crypto.confirmation(private, phone, transcript)):
                            raise ValueError("The pairing confirmation could not be authenticated")
                        if "envelope" not in saved:
                            if "device_id" not in saved:
                                saved.update(device_id=str(uuid.uuid4()), device_token=token(), pairing_secret=token())
                                state.set(record_key, saved)
                            # Idempotent resource creation handles lost replies without orphan devices.
                            await service.request("PUT", service.device_path(saved["device_id"]),
                                                  {"device_token": saved["device_token"]}, state.get("host_token"))
                            if not state.device(saved["device_id"]):
                                state.add_device(saved["device_id"], name, saved["device_token"], secret=saved["pairing_secret"],
                                    expires=deadline, automatic=True, expected_key=crypto.decode(intent["phone_public_key"], 32))
                            payload = dict(v=1, relay_url=state.get("service_url"), installation_id=claim["installation_id"],
                                device_id=saved["device_id"], device_token=saved["device_token"], pairing_secret=saved["pairing_secret"],
                                host_public_key=claim["host_public_key"], expires_at=deadline)
                            saved["envelope"] = crypto.encrypt_enrollment(host_private, crypto.decode(intent["phone_public_key"], 32), transcript, payload)
                            state.set(record_key, saved)
                        await broker.request("PUT", suffix + "/enrollment", {"envelope": saved["envelope"]}, credential)
                        if (state.device(saved["device_id"]) or {}).get("approved") and state.get("setup-ready/" + saved["device_id"]):
                            state.set(record_key, {"terminal": True, "status": "connected", "expires_at": intent["expires_at"]})
                            if report: report("connected")
                            else: print("You’re connected. Your conversations are ready in Hermes Jr.", flush=True)
                            return
            except ServiceError as exc:
                if exc.status not in {429, 500, 502, 503, 504}:
                    raise
                await asyncio.sleep(10 if exc.status != 429 else 60)
            except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
                pass  # Resume the same exchange when transport recovers, under the original deadline.
            await asyncio.sleep(3)
        raise SetupExpired("Setup expired. Create a new setup prompt in Hermes Jr.")
    except (ValueError, ServiceError) as exc:
        if not owns_lock or (isinstance(exc, ServiceError) and exc.status in {429, 500, 502, 503, 504}):
            raise  # Another process or a temporary service failure must not destroy resumable state.
        saved = state.get(record_key) or {}
        if saved.get("device_id") and not (state.device(saved["device_id"]) or {}).get("approved"):
            state.revoke(saved["device_id"])
        state.set(record_key, {"terminal": True, "expires_at": intent["expires_at"]})
        raise
    finally:
        os.close(fd)
