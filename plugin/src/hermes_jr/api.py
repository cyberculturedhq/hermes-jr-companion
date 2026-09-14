"""Direct/Tailscale API and shared channel-authenticated endpoint dispatch."""
from __future__ import annotations
import re
import uuid
import aiohttp
from fastapi import APIRouter, HTTPException, Request
from .service import Service, client_session
from .state import State
from .updates import public_status

PREFIX = "/api/plugins/hermes-jr"
router = APIRouter()


def coordinate(body):
    profile, session_id = body.get("profile"), body.get("session_id")
    if not isinstance(profile, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", profile) or ".." in profile:
        raise ValueError("Invalid profile")
    if not isinstance(session_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}", session_id):
        raise ValueError("Invalid session ID")
    return profile, session_id


async def handle(state, device_id, method, path, body, query, client):
    """Only authenticated callers enter here. Relay identity replaces local-token headers."""
    device = state.device(device_id)
    if not device or not device["approved"]:
        raise PermissionError("Device is not authorized")
    if method == "GET" and path == "/v1/capabilities":
        return {"notification_encryption": 1, "protocol_version": 1, "relay_enabled": state.get("relay_enabled", False), "push_enabled": state.get("push_enabled", False), "installation_id": state.get("installation_id"), "update": public_status(state)}
    if path == "/v1/follows" and method == "GET":
        with state.connect() as db:
            rows = db.execute("SELECT profile,session_id FROM follows WHERE device_id=? ORDER BY profile,session_id", (device_id,)).fetchall()
        return {"follows": [dict(row) for row in rows]}
    if path == "/v1/follows" and method in {"PUT", "DELETE"}:
        profile, sid = coordinate(query if method == "DELETE" else body)
        state.follow(device_id, profile, sid, method == "PUT")
        return {"ok": True}
    if path == "/v1/presence" and method == "PUT":
        if not isinstance(body.get("active"), bool):
            raise ValueError("active must be boolean")
        if not body["active"]:
            state.clear_presence(device_id)
            return {"ok": True}
        profile, sid = coordinate(body)
        state.presence(device_id, profile, sid, body["active"])
        return {"ok": True}
    if path == "/v1/devices/self/push" and method in {"PUT", "DELETE"}:
        if not state.get("push_enabled", False) and method == "PUT":
            raise ValueError("Notifications are disabled on this Hermes host")
        if method == "PUT":
            apns = body.get("apns_token", "")
            environment = body.get("environment")
            if not isinstance(apns, str) or not re.fullmatch(r"[a-fA-F0-9]{32,512}", apns) or environment not in {"sandbox", "production"}:
                raise ValueError("Invalid APNs token or environment")
            from .notification_crypto import validate_key
            preview_key = validate_key(body.get("notification_key")) if "notification_key" in body else None
            body = {"apns_token": apns.lower(), "environment": environment}
        else:
            state.set_notification_key(device_id, None)
            state.set_push(device_id, False)  # Disable locally even if APNs unregister is temporarily down.
        await Service(state, client).push_registration(device, body if method == "PUT" else None)
        if method == "PUT":
            state.set_notification_key(device_id, preview_key)
        state.set_push(device_id, method == "PUT")
        return {"ok": True}
    if method == "GET" and re.fullmatch(r"/v1/notifications/[A-Za-z0-9_-]{32,64}", path):
        item = state.notification(device_id, path.rsplit("/", 1)[1])
        if item is None:
            raise LookupError("Notification has expired")
        return item
    raise LookupError("Unknown companion operation")


@router.get("/v1/capabilities")
async def capabilities():
    state = State()
    return {"notification_encryption": 1, "protocol_version": 1, "relay_enabled": state.get("relay_enabled", False), "push_enabled": state.get("push_enabled", False), "installation_id": state.get("installation_id"), "update": public_status(state)}


@router.post("/v1/enroll")
async def enroll(request: Request):
    # The Hermes auth middleware has authenticated this request before our router executes.
    raw = await request.body()
    if len(raw) > 4096:
        raise HTTPException(413, "Request too large")
    try:
        body = await request.json()
        name = body.get("device_name", "iPhone")
        if not isinstance(name, str) or not 1 <= len(name) <= 80:
            raise ValueError("Invalid device name")
        state = State()
        if not state.get("host_token"):
            raise ValueError("Run hermes jr setup on the host first")
        async with client_session() as client:
            entry = await Service(state, client).add_device()
        device_id = str(uuid.UUID(entry["device_id"]))
        local = state.add_device(device_id, name, entry["device_token"], paired=True)
        return {"device_id": device_id, "device_token": local, "installation_id": state.get("installation_id")}
    except (ValueError, KeyError, TypeError):
        raise HTTPException(400, "Could not enroll this device; check companion setup") from None


@router.api_route("/v1/{rest:path}", methods=["GET", "PUT", "DELETE"])
async def endpoint(rest: str, request: Request):
    try:
        state = State()
        device_id = request.headers.get("x-hermes-jr-device", "")
        state.authenticate(device_id, request.headers.get("x-hermes-jr-token", ""))
        raw = await request.body()
        if len(raw) > 4096:
            raise HTTPException(413, "Request too large")
        body = await request.json() if raw else {}
        if not isinstance(body, dict):
            raise ValueError("Expected a JSON object")
        async with client_session() as client:
            return await handle(state, device_id, request.method, "/v1/" + rest, body, dict(request.query_params), client)
    except PermissionError:
        raise HTTPException(401, "Device is not authorized") from None
    except LookupError:
        raise HTTPException(404, "Companion operation or notification not found") from None
    except (ValueError, TypeError):
        raise HTTPException(400, "Invalid companion request or service unavailable") from None
