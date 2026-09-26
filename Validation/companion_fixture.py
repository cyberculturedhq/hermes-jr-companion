"""Worker -> Python bridge -> fake Hermes -> actual Swift client smoke test.

Run: Companion/.venv/bin/python Validation/companion_fixture.py
Optional: --relay-url https://your-staging-relay.example
Only ephemeral keys/state are used; no Apple credentials or real Hermes are involved.
"""
from __future__ import annotations
import argparse
import asyncio
import base64
import contextlib
import importlib.util
import json
import logging
import os
from pathlib import Path
import platform
import socket
import sys
import tempfile
import time
import uuid
import aiohttp
from aiohttp import web

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Companion/src"))
from hermes_jr import gateway as gateway_module
from hermes_jr.bridge import Bridge

LEGACY_COMPANION = os.environ.get("JR_FIXTURE_LEGACY_COMPANION") == "1"
if LEGACY_COMPANION:
    original_handle = gateway_module.handle
    async def legacy_handle(state, device_id, method, path, body, query, client):
        if path.startswith('/v1/mobile/'):
            raise LookupError('Legacy companion has no mobile v1 API')
        return await original_handle(state, device_id, method, path, body, query, client)
    gateway_module.handle = legacy_handle

from hermes_jr.secure_channel import generate_private_key, public_key
from hermes_jr.service import client_session, read_bounded, validate_service_url
from hermes_jr.state import State, token


def encoded(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def fixture_module():
    # Reuse the established dashboard behavior without running its top-level listener.
    spec = importlib.util.spec_from_file_location("hermes_dashboard_fixture", ROOT / "Validation/fixture_server.py")
    module = importlib.util.module_from_spec(spec)
    previous = web.run_app
    try:
        web.run_app = lambda *args, **kwargs: None
        spec.loader.exec_module(module)
    finally:
        web.run_app = previous
    return module


async def delete_fixture_installation(origin, installation):
    """Delete only the freshly-created fixture, even if the smoke fails midway."""
    path = f"/v1/installations/{installation['installation_id']}"
    headers = {"Authorization": "Bearer " + installation["host_token"]}
    last_status = "unavailable"
    for attempt in range(3):
        try:
            async with client_session(timeout=aiohttp.ClientTimeout(total=15)) as cleanup:
                async with cleanup.delete(origin + path, headers=headers) as response:
                    last_status = str(response.status)
                    if response.status == 404:
                        print("PASS: fixture installation is absent from the relay", flush=True)
                        return
                    result = json.loads(await read_bounded(response, 65536))
                    if response.status != 200 or result.get("status") != "deleted":
                        raise RuntimeError("Fixture deletion was not confirmed")
                async with cleanup.delete(origin + path, headers=headers) as response:
                    last_status = str(response.status)
                    if response.status != 404:
                        raise RuntimeError("Deleted fixture remains reachable")
                print("PASS: fixture installation deleted; subsequent access returns404", flush=True)
                return
        except Exception:
            if attempt < 2:
                await asyncio.sleep(attempt + 1)
    # Preserve a recovery credential privately if an external outage prevents cleanup.
    recovery = Path(tempfile.gettempdir()) / f"hermes-jr-fixture-cleanup-{installation['installation_id']}.json"
    fd = os.open(recovery, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump({"relay_url": origin, **installation}, file)
    raise RuntimeError(f"Fixture cleanup failed (HTTP {last_status}); private recovery file: {recovery}")


async def run(temp, relay_url=None):
    relay_port, dashboard_port, inspector_port = free_port(), free_port(), free_port()
    origin = validate_service_url(relay_url) if relay_url else f"http://127.0.0.1:{relay_port}"
    dashboard = f"http://127.0.0.1:{dashboard_port}"
    env = {**os.environ, "WRANGLER_SEND_METRICS": "false", "WRANGLER_LOG_PATH": str(temp / "wrangler.log")}
    worker_log = (temp / "worker.log").open("w+")
    worker = None
    if not relay_url:
        worker = await asyncio.create_subprocess_exec(
            str(ROOT / "RelayService/node_modules/.bin/wrangler"), "dev", "--local", "--ip", "127.0.0.1",
            "--port", str(relay_port), "--inspector-port", str(inspector_port), "--persist-to", str(temp / "worker-state"),
            "--show-interactive-dev-session=false", cwd=ROOT / "RelayService", env=env,
            stdout=worker_log, stderr=asyncio.subprocess.STDOUT,
        )
    installation = None
    runner = None
    bridge_task = None
    approval_task = None
    try:
        async with client_session() as http:
            for _ in range(1 if relay_url else 100):
                try:
                    async with http.get(origin + "/v1/capabilities", timeout=aiohttp.ClientTimeout(total=15)) as response:
                        if response.status == 200:
                            capabilities = json.loads(await read_bounded(response, 65536))
                            assert capabilities.get("protocol_version") == 1
                            assert capabilities.get("max_ciphertext_bytes") == 65536
                            print("PASS: relay capabilities verified over " + ("HTTPS" if relay_url else "loopback HTTP"), flush=True)
                            break
                except Exception:
                    if worker and worker.returncode is not None:
                        raise RuntimeError("Local Worker startup failed")
                await asyncio.sleep(.1)
            else:
                raise RuntimeError("Relay capabilities could not be verified")
            async with http.post(origin + "/v1/installations", json={}) as response:
                assert response.status == 201, f"Fixture installation creation returned HTTP {response.status}"
                installation = json.loads(await read_bounded(response, 65536))
                installation["installation_id"] = str(uuid.UUID(installation["installation_id"]))
            headers = {"Authorization": "Bearer " + installation["host_token"]}
            path = f"/v1/installations/{installation['installation_id']}/devices"
            async with http.post(origin + path, json={}, headers=headers) as response:
                assert response.status == 201, f"Fixture device creation returned HTTP {response.status}"
                device = json.loads(await read_bounded(response, 65536))
            host_private, phone_private, secret = generate_private_key(), generate_private_key(), token()
            state = State(temp / "host-state")
            state.settings({"service_url": origin, "dashboard_url": dashboard, **installation,
                            "host_private_key": encoded(host_private), "relay_enabled": True, "push_enabled": False})
            state.add_device(device["device_id"], "Swift fixture", device["device_token"], secret=secret, expires=time.time() + 600)

            fixture = fixture_module()
            app = web.Application(middlewares=[fixture.auth])
            async def delayed_sessions(request):
                if request.query.get("search") == "fixture-delay":
                    await asyncio.sleep(.25)
                return await fixture.sessions(request)
            for route in fixture.app.router.routes():
                route_path = route.resource.canonical.removeprefix("/hermes")
                handler = delayed_sessions if route_path == "/api/sessions" else route.handler
                app.router.add_route(route.method, route_path, handler)
            async def revoke(request):
                state.revoke(device["device_id"])
                async with http.delete(origin + path + "/" + device["device_id"], headers=headers) as response:
                    assert response.status == 200, f"Fixture device revocation returned HTTP {response.status}"
                return web.json_response({"ok": True})
            app.router.add_post("/api/fixture/revoke", revoke)
            runner = web.AppRunner(app, access_log=None)
            await runner.setup()
            await web.TCPSite(runner, "127.0.0.1", dashboard_port).start()
            os.environ["HERMES_JR_DASHBOARD_TOKEN"] = "fixture-dashboard-token"
            bridge = Bridge(state, http)
            bridge_task = asyncio.create_task(bridge.run())
            async def approve_claimed_fixture_phone():
                for _ in range(1000):
                    row = state.device(device["device_id"])
                    if row and row["public_key"]:
                        assert row["public_key"] == encoded(public_key(phone_private))
                        assert row["pair_digest"] is None, "Pairing secret must be consumed before approval"
                        assert not row["approved"], "An unapproved phone gained access automatically"
                        state.approve(device["device_id"])
                        print("PASS: invitation claimed by pinned phone key; host approval releases pending handshake", flush=True)
                        return
                    await asyncio.sleep(.05)
                raise RuntimeError("Phone did not claim its pairing invitation")
            approval_task = asyncio.create_task(approve_claimed_fixture_phone())
            for _ in range(100):
                if bridge.socket is not None:
                    break
                await asyncio.sleep(.1)
            else:
                raise RuntimeError("Host bridge did not connect")
            config = {"connection": {"relayURL": origin, "installationID": installation["installation_id"],
                        "deviceID": device["device_id"], "hostPublicKey": encoded(public_key(host_private))},
                      "credentials": {"deviceToken": device["device_token"], "privateKey": base64.b64encode(phone_private).decode(),
                                      "pairingSecret": secret},
                      "dashboardURL": dashboard, "legacyCompanion": LEGACY_COMPANION}
            config_path = temp / "swift-fixture.json"
            config_path.write_text(json.dumps(config))
            config_path.chmod(0o600)
            executable = temp / "companion-smoke"
            arch = "arm64" if platform.machine() == "arm64" else "x86_64"
            compiler = await asyncio.create_subprocess_exec(
                "xcrun", "swiftc", "-parse-as-library", "-target", f"{arch}-apple-macosx14.0",
                "Hermes/Models/Models.swift", "Hermes/Models/CompanionModels.swift", "Hermes/Services/CompanionCrypto.swift",
                "Hermes/Services/CompanionTransport.swift", "Hermes/Services/HermesClient.swift", "Validation/CompanionSmoke.swift",
                "-module-cache-path", str(temp / "swift-cache"), "-o", str(executable), cwd=ROOT,
            )
            assert await compiler.wait() == 0, "Swift smoke compilation failed"
            swift = await asyncio.create_subprocess_exec(str(executable), str(config_path), cwd=ROOT)
            try:
                code = await asyncio.wait_for(swift.wait(), timeout=90)
            except asyncio.TimeoutError:
                swift.kill()
                await swift.wait()
                raise RuntimeError("Swift smoke timed out")
            assert code == 0, f"Swift smoke exited {code}"
            await approval_task
            print("PASS: complete " + ("staging" if relay_url else "local") + " companion smoke finished", flush=True)
    except Exception:
        worker_log.flush()
        # Local-only logs contain generated test routing identifiers, never production secrets.
        print((temp / "worker.log").read_text()[-8000:], file=sys.stderr)
        raise
    finally:
        if approval_task:
            approval_task.cancel()
            await asyncio.gather(approval_task, return_exceptions=True)
        if bridge_task:
            bridge_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await bridge_task
        if runner:
            await runner.cleanup()
        try:
            if installation:
                await delete_fixture_installation(origin, installation)
        finally:
            if worker and worker.returncode is None:
                worker.terminate()
                try:
                    await asyncio.wait_for(worker.wait(), 5)
                except asyncio.TimeoutError:
                    worker.kill()
                    await worker.wait()
            worker_log.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--relay-url", help="Use an existing HTTPS staging relay instead of starting local Wrangler")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="hermes-jr-full-smoke-") as folder:
        asyncio.run(run(Path(folder), args.relay_url))
