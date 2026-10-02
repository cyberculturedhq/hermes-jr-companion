"""Local-only notification navigation fixture; no real credentials or model calls.

History and reference resolution can be held until a test explicitly releases
them, so early navigation assertions do not depend on network timing.
"""
import asyncio
import base64
import json
import re
from aiohttp import web

TOKEN = "notification-fixture-token"
state = {}
history_gate = asyncio.Event()
lookup_gate = asyncio.Event()
turn_gate = asyncio.Event()
list_gate = asyncio.Event()
follow_gate = asyncio.Event()


async def control(request):
    body = await request.json()
    if body.get("reset"):
        history_gate.set()
        lookup_gate.set()
        turn_gate.set(); list_gate.set(); follow_gate.set()
        state.clear()
        state.update(lookups=0, histories=0, resumes=0, lists=0, creates=0, prompts=0,
                     updates=body.get("updates", False), tracked=body.get("tracked", True), receipt=None, verified=False,
                     profile=body.get("profile", "research"), failure=body.get("failure", False),
                     require_enrollment=body.get("require_enrollment", False),
                     turn_status=body.get("turn_status", "complete"), receipt_status=None, installed_version=None, last_prompt=None,
                     drop_turn=body.get("drop_turn", False), follows=0)
        if body.get("hold_history", True):
            history_gate.clear()
        if body.get("hold_lookup", False):
            lookup_gate.clear()
        if body.get("hold_turn", False): turn_gate.clear()
        if body.get("hold_lists", False): list_gate.clear()
        if body.get("hold_follow", False): follow_gate.clear()
    if "verified" in body: state["verified"] = body["verified"]
    for key in ("turn_status", "receipt_status", "drop_turn", "installed_version", "tracked"):
        if key in body: state[key] = body[key]
    if body.get("release_turn"): turn_gate.set()
    if body.get("release_lists"): list_gate.set()
    if body.get("release_follow"): follow_gate.set()
    if body.get("release_history"):
        history_gate.set()
    if body.get("release_lookup"):
        lookup_gate.set()
    return web.json_response(state)


@web.middleware
async def auth(request, handler):
    if request.path in ("/control", "/api/health", "/api/ws"):
        return await handler(request)
    if request.headers.get("Authorization") != "Bearer " + TOKEN:
        return web.json_response({"error": "unauthenticated"}, status=401)
    return await handler(request)


async def health(request):
    return web.json_response({"ok": True, "version": "0.21.1-fixture", "auth_required": True})


async def empty(request):
    return web.json_response({})


async def profiles(request):
    return web.json_response({"profiles": [
        {"name": name, "display_name": name.capitalize(), "gateway_running": True}
        for name in ("default", "research")
    ]})


async def ticket(request):
    return web.json_response({"ticket": "fixture-ticket"})


async def lookup(request):
    state["lookups"] += 1
    if state["require_enrollment"] and (
        request.headers.get("X-Hermes-Jr-Device") != "fixture-device"
        or request.headers.get("X-Hermes-Jr-Token") != "fixture-enrollment-token"
    ):
        return web.json_response({"error": "Missing saved notification enrollment"}, status=403)
    profile = state["profile"]
    await lookup_gate.wait()
    return web.json_response({"profile": profile, "session_id": "saved"})


async def sessions(request):
    state["lists"] += 1
    await list_gate.wait()
    if state.get("updates"): return web.json_response({"sessions": []})
    # A notification must work even when the list endpoint is unavailable.
    return web.json_response({"error": "Session lists deliberately unavailable"}, status=503)


async def messages(request):
    state["histories"] += 1
    await history_gate.wait()
    if state["failure"]:
        return web.json_response({"error": "History deliberately unavailable"}, status=503)
    if state.get("updates") and state.get("last_prompt"):
        rows = [{"id": "update-prompt", "role": "user", "content": state["last_prompt"]}]
        return web.json_response({"messages": rows, "pagination": {"returned": len(rows)}})
    return web.json_response({"messages": [{"id": "reply", "role": "assistant",
        "content": "Reply from " + request.query["profile"]}], "pagination": {"returned": 1}})


async def websocket(request):
    if request.query.get("ticket") != "fixture-ticket":
        return web.Response(status=401)
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    async for frame in ws:
        if frame.type != web.WSMsgType.TEXT:
            continue
        message = frame.json()
        method, params = message["method"], message.get("params", {})
        result = {}
        if method == "session.resume":
            state["resumes"] += 1
            assert params["session_id"] in ("saved", "update-conversation")
            result = {"session_id": "runtime-" + params["profile"], "stored_session_id": "saved"}
            if state.get("updates") and state["turn_status"] == "error":
                result["inflight"] = {"status": "error", "error": "Retained internal failure"}
        elif method == "session.create":
            assert params["profile"] == "default"
            state["creates"] += 1
            result = {"session_id": "runtime-default", "stored_session_id": "update-conversation"}
        elif method == "prompt.submit":
            state["prompts"] += 1
            state["last_prompt"] = params["text"]
            match = re.search(r'--receipt ([A-Za-z0-9_-]+)', params["text"])
            if match:
                encoded = match.group(1)
                state["receipt"] = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
            result = {"status": "accepted"}
        elif method == "profiles.list":
            result = {"profiles": []}
        await ws.send_json({"jsonrpc": "2.0", "id": message["id"], "result": result})
        if method == "prompt.submit":
            await turn_gate.wait()
            if state["drop_turn"]:
                await ws.close()
                break
            await ws.send_json({"jsonrpc": "2.0", "method": "event", "params": {
                "session_id": "runtime-default", "type": "message.complete", "payload": {
                    "status": state["turn_status"],
                    "text": "Hermes hit an internal error. Try again.\nDetails: TypeError" if state["turn_status"] == "error" else ""}}})
    return ws


async def capabilities(request):
    if not state.get("updates"): return web.json_response({})
    return web.json_response({"update": {"installed": state["installed_version"] or ("0.16.0" if state["verified"] else "0.14.0"),
        "available": not state["verified"], "version": "0.16.0", "checks_enabled": False,
        "tracking": 1 if state["tracked"] or state["verified"] else 0}})


async def update_status(request):
    receipt = state.get("receipt")
    if not receipt or request.match_info["id"] != receipt["id"]:
        return web.json_response({"error": "Not found"}, status=404)
    if state["receipt_status"] == "missing" or state["turn_status"] == "error" and not state["receipt_status"]:
        return web.json_response({"error": "Installer was never invoked"}, status=404)
    return web.json_response({"status": "completed" if state["verified"] else state["receipt_status"] or "running",
                              "installed": "0.16.0" if state["verified"] else None})


async def follow(request):
    state["follows"] += 1
    await follow_gate.wait()
    return web.json_response({"ok": True})


app = web.Application(middlewares=[auth])
app.router.add_post("/control", control)
app.router.add_post("/api/auth/ws-ticket", ticket)
app.router.add_put("/api/plugins/hermes-jr/v1/follows", follow)
for path, handler in [("health", health), ("auth/me", empty), ("profiles", profiles),
                      ("sessions", sessions), ("sessions/{sid}/messages", messages),
                      ("plugins/hermes-jr/v1/capabilities", capabilities),
                      ("plugins/hermes-jr/v1/update-requests/{id}", update_status),
                      ("plugins/hermes-jr/v1/notifications/{reference}", lookup), ("ws", websocket)]:
    app.router.add_get("/api/" + path, handler)

if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=19129, access_log=None)
