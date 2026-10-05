"""Interactive, isolated test of a real iPhone's sandbox push registration and delivery.

This does not install or operate the app. Credentials and pairing URLs are written
only to a private work directory. The normal app sends its APNs token through the
encrypted companion API; this harness never reads or prints that token.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import signal
import struct
import tempfile
import time
import uuid
import zlib

import aiohttp
from aiohttp import web

from companion_fixture import (
    Bridge, State, client_session, delete_fixture_installation, encoded,
    fixture_module, free_port, generate_private_key, public_key, read_bounded,
    token, validate_service_url,
)
from hermes_jr.service import Service

PROFILE, SESSION = "research", "saved-0"
APPLE_REASONS = frozenset({
    "BadCollapseId", "BadDeviceToken", "BadExpirationDate", "BadMessageId", "BadPriority", "BadTopic",
    "DeviceTokenNotForTopic", "DuplicateHeaders", "IdleTimeout", "InvalidPushType", "MissingDeviceToken",
    "MissingTopic", "PayloadEmpty", "TopicDisallowed", "BadCertificate", "BadCertificateEnvironment",
    "ExpiredProviderToken", "Forbidden", "InvalidProviderToken", "MissingProviderToken", "BadPath",
    "MethodNotAllowed", "Unregistered", "PayloadTooLarge", "TooManyProviderTokenUpdates", "TooManyRequests",
    "InternalServerError", "ServiceUnavailable", "Shutdown",
})


def private_write(path: Path, value: str | bytes):
    """Publish a complete private file without a permissive creation interval."""
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(value.encode() if isinstance(value, str) else value)
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def fingerprint(encoded_key):
    return hashlib.sha256(base64.urlsafe_b64decode(encoded_key + "=")).hexdigest()


def safe_receipt(value):
    """Copy only enumerated diagnostics; never reflect arbitrary provider text."""
    value = value if isinstance(value, dict) else {}
    status = value.get("status")
    stage = value.get("stage")
    code = value.get("apns_status")
    expiry = value.get("expires_at")
    return {
        "status": status if isinstance(status, str) and status in {"pending", "accepted", "unregistered", "unavailable", "failed"} else None,
        "stage": stage if isinstance(stage, str) and stage in {"signing", "transport", "apns"} else None,
        "apns_status": code if type(code) is int and 100 <= code <= 599 else None,
        "reason": value.get("reason") if isinstance(value.get("reason"), str) and value.get("reason") in APPLE_REASONS else None,
        "expires_at": expiry if type(expiry) in (int, float) and 0 < expiry < 10**15 else None,
    }


def confirmed_rejection(receipt):
    receipt = safe_receipt(receipt)
    return (receipt["status"] in {"failed", "unregistered"} and receipt["stage"] == "apns"
            and receipt["apns_status"] is not None and receipt["apns_status"] != 200)


def safe_request_error(error):
    match = re.fullmatch(r"Service rejected request \(HTTP ([1-5][0-9]{2})\)", str(error))
    if match:
        return {"kind": "service_http_error", "http_status": int(match[1])}
    if isinstance(error, (TimeoutError, asyncio.TimeoutError)):
        return {"kind": "timeout"}
    if isinstance(error, aiohttp.ClientError):
        return {"kind": "transport_error"}
    return {"kind": "request_error"}


class DiagnosticService(Service):
    async def receipt(self, event):
        response = await self.request("GET", self.device_path(event["device_id"]) + "/push/receipts/" + event["reference"],
                                      credential=self.state.get("host_token"))
        return safe_receipt(response)

    async def is_registered(self, device_id):
        response = await self.request("GET", f"/v1/installations/{self.state.get('installation_id')}/devices",
                                      credential=self.state.get("host_token"))
        return any(row.get("device_id") == device_id and row.get("push_registered") is True
                   for row in response.get("devices", []) if isinstance(row, dict))


async def read_receipt(service, event):
    try:
        receipt = await service.receipt(event)
        return {"receipt": safe_receipt(receipt), "confirmed_apns_rejection": confirmed_rejection(receipt)}
    except Exception as error:
        return {"receipt": None, "confirmed_apns_rejection": False, "receipt_error": safe_request_error(error)}


class ManualPushState(State):
    """Keep bridge approval/registration intact; dispatch requires fixture control."""
    opened_at = None

    def outbox(self):
        return []  # Never let Bridge.maintenance send or retry a notification.

    def notification(self, device_id, reference):
        result = super().notification(device_id, reference)
        if result:
            self.opened_at = time.time()
        return result


class Controller:
    def __init__(self, state, service, device_id):
        self.state, self.service, self.device_id = state, service, device_id
        self.pending_notification_until = None
        self.attempted = False
        self.push_status = "not_requested"
        self.push_attempted_at = None
        self.reference = None
        self.last_control = None
        self.diagnostic = None
        self.request_error = None

    def followed(self):
        with self.state.connect() as db:
            row = db.execute("SELECT present_until FROM follows WHERE device_id=? AND profile=? AND session_id=?",
                             (self.device_id, PROFILE, SESSION)).fetchone()
        return dict(row) if row else None

    def snapshot(self):
        device = self.state.device(self.device_id)
        follow = self.followed()
        with self.state.connect() as db:
            row = db.execute("SELECT delivered,attempts FROM notifications WHERE reference=?", (self.reference,)).fetchone()
        return {
            "phone_claimed": bool(device and device["public_key"]),
            "phone_fingerprint": fingerprint(device["public_key"]) if device and device["public_key"] else None,
            "approved": bool(device and device["approved"]),
            "push_registered": bool(device and device["push_enabled"]),
            "followed_fixture_session": bool(follow),
            "presence_remaining_seconds": max(0, round(follow["present_until"] - time.time(), 1)) if follow else None,
            "push_attempted": self.attempted,
            "push_attempted_at": self.push_attempted_at,
            "push_status": self.push_status,
            "outbox_delivered": bool(row and row["delivered"]),
            "outbox_attempts": row["attempts"] if row else 0,
            "notification_reference_resolved_at": self.state.opened_at,
            "last_control": self.last_control,
            "diagnostic": self.diagnostic,
            "request_error": self.request_error,
        }

    def command(self, value):
        action = value.get("action")
        result = {"id": value.get("id"), "action": action, "status": "rejected", "at": time.time()}
        device = self.state.device(self.device_id)
        if action == "notify":
            if self.attempted or self.pending_notification_until is not None:
                result["reason"] = "This fixture permits one push attempt"
            elif not device or not device["approved"] or not device["push_enabled"] or not self.followed():
                result["reason"] = "Pair the phone, enable Notify me, and open Research / Session 0 first"
            else:
                if value.get("clear_presence") is True:
                    self.state.clear_presence(self.device_id)
                self.pending_notification_until = time.time() + 60
                self.push_status = "waiting_for_presence_to_clear"
                result["status"] = "queued"
        elif action == "stop":
            self.pending_notification_until = None
            result["status"] = "stopping"
        else:
            result["reason"] = "Unknown action"
        self.last_control = result
        return action == "stop"

    async def tick(self):
        if self.pending_notification_until is None:
            return
        if time.time() > self.pending_notification_until:
            self.pending_notification_until = None
            self.push_status = "not_sent_presence_did_not_clear"
            return
        follow = self.followed()
        if not follow or follow["present_until"] >= time.time():
            return
        self.pending_notification_until = None
        event_key = "manual-apns-fixture:" + str(uuid.uuid4())
        self.state.enqueue(PROFILE, SESSION, "complete", event_key)
        events = [event for event in State.outbox(self.state) if event["event_key"] == event_key]
        if len(events) != 1:
            self.push_status = "not_sent_registration_or_follow_changed"
            return
        event = events[0]
        self.reference = event["reference"]
        # Set before awaiting HTTP: a lost response must never cause another send.
        self.attempted, self.push_attempted_at = True, time.time()
        self.push_status = "request_in_flight"
        accepted = False
        try:
            response = await self.service.send_push(event)
            provider_status = response.get("status")
            accepted = provider_status == "accepted"
            self.push_status = "accepted_by_apns" if accepted else "not_confirmed_by_apns"
        except Exception as error:
            # Exceptions can contain URLs. Do not print request data or credentials.
            self.request_error = safe_request_error(error)
            self.push_status = "request_failed_or_outcome_unknown"
        finally:
            self.state.sent(self.reference, accepted)
        if hasattr(self.service, "receipt"):
            self.diagnostic = await read_receipt(self.service, event)


def attach_fixture(directory):
    """Attach to a live registry without restarting it or initializing a new DB."""
    status_path = directory / "status.json"
    status = json.loads(status_path.read_text())
    if status.get("phase") in {"failed", "stopped"} or status.get("deadline", 0) <= time.time():
        raise RuntimeError("Fixture is stopped or expired")
    if status_path.stat().st_mtime < time.time() - 30:
        raise RuntimeError("Live fixture status is stale")
    state = State.__new__(State)
    state.directory = directory / "host-state"
    state.path = state.directory / "companion.sqlite3"
    if not state.path.is_file():
        raise RuntimeError("Fixture registry is missing")
    validate_service_url(state.get("service_url"))
    return state, status


def fixture_events(state):
    with state.connect() as db:
        return [dict(row) for row in db.execute("SELECT * FROM notifications ORDER BY created")]


async def retry_confirmed_rejection(directory, state, service, original_event, receipt, *, deadline=None):
    """One explicit extra attempt. A separate process never rearms the live loop."""
    if not confirmed_rejection(receipt):
        raise RuntimeError("Retry refused: no confirmed APNs rejection; transport, legacy, pending, and unknown outcomes cannot be retried")
    if deadline is not None and deadline < time.time() + 60:
        raise RuntimeError("Retry refused: fixture cleanup deadline is too close")
    if not await service.is_registered(original_event["device_id"]):
        raise RuntimeError("Retry refused: staging no longer has an APNs registration for this phone")
    controller = Controller(state, service, original_event["device_id"])
    device, follow = state.device(original_event["device_id"]), controller.followed()
    if not device or not device["approved"] or not device["push_enabled"] or not follow:
        raise RuntimeError("Retry refused: approved registration and fixture conversation follow are required")
    if follow["present_until"] >= time.time():
        raise RuntimeError("Retry refused: background the app and wait for presence to clear")
    result_path = directory / "retry-status.json"
    result = {"phase": "reserved", "created_at": time.time(), "prior_receipt": safe_receipt(receipt), "push_attempted": False}
    # Never replace this latch. Concurrent commands or an uncertain response cannot
    # dispatch another push, and a crash is conservative rather than auto-resumable.
    try:
        fd = os.open(result_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        raise RuntimeError("Retry refused: this fixture already reserved its one explicit retry") from None
    with os.fdopen(fd, "w") as output:
        json.dump(result, output, indent=2)
    reference, event_key = token(), "manual-apns-retry:" + str(uuid.uuid4())
    with state.connect() as db:
        db.execute("INSERT INTO notifications(reference,device_id,profile,session_id,kind,event_key,created) VALUES(?,?,?,?,?,?,?)",
                   (reference, original_event["device_id"], PROFILE, SESSION, "complete", event_key, time.time()))
    event = {"device_id": original_event["device_id"], "reference": reference}
    result.update(phase="request_in_flight", push_attempted=True, push_attempted_at=time.time())
    private_write(result_path, json.dumps(result, indent=2))
    accepted = False
    try:
        response = await service.send_push(event)
        accepted = response.get("status") == "accepted"
        result["push_status"] = "accepted_by_apns" if accepted else "not_confirmed_by_apns"
    except Exception as error:
        result.update(push_status="request_failed_or_outcome_unknown", request_error=safe_request_error(error))
    finally:
        state.sent(reference, accepted)
    result.update(phase="finished", diagnostic=await read_receipt(service, event), finished_at=time.time())
    private_write(result_path, json.dumps(result, indent=2))
    return result


async def inspect_or_retry(args):
    directory = Path(args.workdir).resolve()
    state, status = attach_fixture(directory)
    events = fixture_events(state)
    if not events:
        raise RuntimeError("Fixture has no attempted notification receipt")
    # Receipt inspection follows the newest attempt; retry always evaluates the
    # original attempt and the durable one-retry latch still excludes repetition.
    event = events[-1] if args.command == "receipt" else events[0]
    async with client_session() as http:
        service = DiagnosticService(state, http)
        result = await read_receipt(service, event)
        if args.command == "receipt":
            private_write(directory / "receipt-status.json", json.dumps({"checked_at": time.time(), **result}, indent=2))
            print(json.dumps(result, indent=2))
        else:
            await retry_confirmed_rejection(directory, state, service, event, result["receipt"], deadline=status["deadline"])
            print(f"Explicit retry completed; safe status: {directory / 'retry-status.json'}")


async def run(args):
    origin = validate_service_url(args.relay_url)
    directory = Path(args.workdir).resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    directory.chmod(0o700)
    (directory / "commands").mkdir(mode=0o700)
    installation, runner, bridge_task = None, None, None
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    status = {"phase": "starting", "relay_url": origin, "profile": PROFILE, "session_id": SESSION,
              "started_at": time.time(), "deadline": time.time() + args.timeout_minutes * 60,
              "delivery_caveat": "APNs acceptance does not prove a visible banner. Reference resolution shows the app handled a tap, not final screen rendering."}
    status_path = directory / "status.json"
    try:
        async with client_session() as http:
            async with http.get(origin + "/v1/capabilities", timeout=aiohttp.ClientTimeout(total=15)) as response:
                capabilities = json.loads(await read_bounded(response, 65536))
                if response.status != 200 or capabilities.get("protocol_version") != 1 or capabilities.get("push") is not True:
                    raise RuntimeError("Staging relay must report push capability before starting a real phone test")
            async with http.post(origin + "/v1/installations", json={}, timeout=aiohttp.ClientTimeout(total=15)) as response:
                if response.status != 201:
                    raise RuntimeError("Fixture installation creation failed")
                installation = json.loads(await read_bounded(response, 65536))
                installation["installation_id"] = str(uuid.UUID(installation["installation_id"]))
            # Recovery credentials stay in the private test directory for crash cleanup.
            private_write(directory / "cleanup.json", json.dumps({"relay_url": origin, **installation}))
            dashboard_port = free_port()
            host_private = generate_private_key()
            state = ManualPushState(directory / "host-state")
            state.settings({"service_url": origin, "dashboard_url": f"http://127.0.0.1:{dashboard_port}", **installation,
                            "host_private_key": encoded(host_private), "relay_enabled": True, "push_enabled": True})
            service = DiagnosticService(state, http)
            fixture = fixture_module()
            app = web.Application(middlewares=[fixture.auth])
            for route in fixture.app.router.routes():
                app.router.add_route(route.method, route.resource.canonical.removeprefix("/hermes"), route.handler)
            runner = web.AppRunner(app, access_log=None)
            await runner.setup()
            await web.TCPSite(runner, "127.0.0.1", dashboard_port).start()
            os.environ["HERMES_JR_DASHBOARD_TOKEN"] = "fixture-dashboard-token"
            bridge = Bridge(state, http)
            bridge_task = asyncio.create_task(bridge.run())
            from hermes_jr.setup_pairing import run as pair_phone
            def report(phase, **fields):
                if phase == "ready":
                    print("Compare all three groups with Jr., then confirm on the phone: " + fields["code"], flush=True)
            await pair_phone(state, service, Path(args.ticket_file).read_text().strip(), "Push test iPhone", report=report)
            device_id = state.devices()[0]["id"]
            controller = Controller(state, service, device_id)
            status.update(phase="approved", installation_id=installation["installation_id"], device_id=device_id)
            print(f"Safe status: {status_path}", flush=True)
            while not stop.is_set() and time.time() < status["deadline"]:
                if bridge_task.done():
                    raise RuntimeError("Fixture bridge stopped unexpectedly")
                for command_path in sorted((directory / "commands").glob("*.json")):
                    value = json.loads(command_path.read_text())
                    command_path.unlink()
                    try:
                        if controller.command(value):
                            stop.set()
                    except (ValueError, PermissionError):
                        controller.last_control = {"id": value.get("id"), "status": "rejected", "reason": "Invitation expired or approval is unavailable"}
                if stop.is_set():
                    break
                await controller.tick()
                status.update(controller.snapshot(), relay_connected=bridge.socket is not None)
                status["phase"] = "approved" if status["approved"] else "awaiting_approval" if status["phone_claimed"] else "awaiting_phone"
                private_write(status_path, json.dumps(status, indent=2))
                try:
                    await asyncio.wait_for(stop.wait(), timeout=0.25)
                except asyncio.TimeoutError:
                    pass
    except Exception as error:
        status.update(phase="failed", failure_type=type(error).__name__)
        private_write(status_path, json.dumps(status, indent=2))
        # Only known fixture errors have static, non-sensitive text.
        print(str(error) if isinstance(error, RuntimeError) else "Fixture failed; consult safe status metadata", flush=True)
        raise SystemExit(1)
    finally:
        if bridge_task:
            bridge_task.cancel()
            await asyncio.gather(bridge_task, return_exceptions=True)
        if runner:
            await runner.cleanup()
        try:
            if installation:
                await delete_fixture_installation(origin, installation)
                (directory / "cleanup.json").unlink(missing_ok=True)
                status["installation_deleted"] = True
        finally:
            if status["phase"] != "failed":
                status["phase"] = "stopped"
            status["stopped_at"] = time.time()
            private_write(status_path, json.dumps(status, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start")
    start.add_argument("--ticket-file", required=True, help="Private file containing the fresh ticket copied from Jr.")
    start.add_argument("--relay-url", required=True)
    start.add_argument("--workdir", required=True, help="A new private directory under /tmp")
    start.add_argument("--timeout-minutes", type=int, default=30)
    control = commands.add_parser("control")
    control.add_argument("--workdir", required=True)
    control.add_argument("action", choices=["notify", "stop"])
    control.add_argument("--clear-presence", action="store_true", help="Explicitly clear only this fixture phone's presence before its one push")
    for command in ("receipt", "retry-confirmed-rejection"):
        attach = commands.add_parser(command, help="Read safe receipt diagnostics" if command == "receipt" else "Send one explicit retry only after a confirmed APNs rejection")
        attach.add_argument("--workdir", required=True)
    args = parser.parse_args()
    logging.basicConfig(level=logging.WARNING)
    if args.command == "start":
        if not 1 <= args.timeout_minutes <= 120:
            parser.error("Timeout must be 1–120 minutes")
        asyncio.run(run(args))
    elif args.command in ("receipt", "retry-confirmed-rejection"):
        try:
            asyncio.run(inspect_or_retry(args))
        except RuntimeError as error:
            print(str(error))
            raise SystemExit(1)
        except Exception:
            print("Fixture inspection failed without changing its running process")
            raise SystemExit(1)
    else:
        directory = Path(args.workdir).resolve()
        if not (directory / "commands").is_dir():
            parser.error("Fixture control directory does not exist")
        command_id = str(uuid.uuid4())
        private_write(directory / "commands" / (command_id + ".json"), json.dumps({
            "id": command_id, "action": args.action, "clear_presence": args.clear_presence,
        }))
        print(f"Control queued: {args.action}; inspect {directory / 'status.json'}")


if __name__ == "__main__":
    main()
