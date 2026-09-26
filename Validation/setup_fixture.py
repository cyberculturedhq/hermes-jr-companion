"""Run real Swift numeric comparison -> local Worker -> Python companion -> fake Hermes.

Only temporary generated keys, loopback listeners and isolated fixture state are used.
No deployment, real Hermes data, or Apple push calls. Run with Companion/.venv/bin/python.
"""
import asyncio
import contextlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import threading
import tempfile
import sys
from unittest.mock import patch
from aiohttp import web
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption
from companion_fixture import ROOT, free_port, fixture_module
from hermes_jr.bridge import Bridge
from hermes_jr.service import Service, client_session
from hermes_jr.state import State
from hermes_jr.secure_channel import generate_private_key
from hermes_jr.setup_crypto import encode
from hermes_jr.setup_jobs import result as job_result, identity as job_identity
from hermes_jr.pairing_panel import LEASE_ENV, wait as wait_for_panel


async def run(temp):
    port, dashboard_port = free_port(), free_port()
    origin = f"http://127.0.0.1:{port}"
    config = json.loads(re.sub(r"^\s*//.*$", "", (ROOT / "RelayService/wrangler.jsonc").read_text(), flags=re.M))
    config.update(main=str(ROOT / "RelayService/src/index.ts"), name="hermes-numeric-fixture", workers_dev=True)
    config.pop("$schema", None)
    config["vars"].update({key: "" for key in config["secrets"]["required"]})
    config["vars"]["SETUP_TICKET_PRIVATE_KEY"] = encode(Ed25519PrivateKey.generate().private_bytes(Encoding.DER, PrivateFormat.PKCS8, NoEncryption()))
    config.pop("secrets")
    config_path = temp / "wrangler.json"
    config_path.write_text(json.dumps(config)); config_path.chmod(0o600)
    log = (temp / "worker.log").open("w+")
    worker = await asyncio.create_subprocess_exec(str(ROOT / "RelayService/node_modules/.bin/wrangler"), "dev", "--local",
        "--config", str(config_path), "--ip", "127.0.0.1", "--port", str(port), "--inspector-port", str(free_port()),
        "--persist-to", str(temp / "worker"), "--show-interactive-dev-session=false", cwd=temp,
        env={**os.environ, "WRANGLER_SEND_METRICS": "false", "WRANGLER_LOG_PATH": str(temp / "wrangler.log")}, stdout=log, stderr=asyncio.subprocess.STDOUT)
    runner = None; bridge = None; swift = None; pairing = None
    panel_interrupt = threading.Event()
    try:
        async with client_session() as http:
            for _ in range(150):
                try:
                    async with http.get(origin + "/health") as response:
                        if response.status == 200: break
                except OSError: pass
                await asyncio.sleep(.1)
            else: raise RuntimeError("Worker failed to start")
            state = State(temp / "host")
            service = Service(state, http, origin=origin)
            installation = await service.request("POST", "/v1/installations", {})
            state.settings({"service_url": origin, "dashboard_url": f"http://127.0.0.1:{dashboard_port}", **installation,
                            "host_private_key": encode(generate_private_key()), "relay_enabled": True, "push_enabled": False})
            fixture = fixture_module()
            app = web.Application(middlewares=[fixture.auth])
            for route in fixture.app.router.routes(): app.router.add_route(route.method, route.resource.canonical.removeprefix("/hermes"), route.handler)
            runner = web.AppRunner(app, access_log=None); await runner.setup()
            await web.TCPSite(runner, "127.0.0.1", dashboard_port).start()
            os.environ["HERMES_JR_DASHBOARD_TOKEN"] = "fixture-dashboard-token"
            bridge = asyncio.create_task(Bridge(state, http).run())
            executable = temp / "setup-smoke"
            compiler = await asyncio.create_subprocess_exec("xcrun", "swiftc", "-parse-as-library", "-target",
                f"{'arm64' if platform.machine() == 'arm64' else 'x86_64'}-apple-macosx14.0",
                "Hermes/Models/Models.swift", "Hermes/Models/CompanionModels.swift", "Hermes/Models/SetupModels.swift",
                "Hermes/Services/CompanionCrypto.swift", "Hermes/Services/SetupCrypto.swift", "Hermes/Services/CompanionTransport.swift",
                "Hermes/Services/HermesClient.swift", "Validation/SetupSmoke.swift", "-module-cache-path", str(temp / "cache"), "-o", str(executable), cwd=ROOT)
            if await compiler.wait(): raise RuntimeError("Swift compilation failed")
            code_path = temp / "code.txt"
            swift = await asyncio.create_subprocess_exec(str(executable), origin, str(code_path), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
            first = (await asyncio.wait_for(swift.stdout.readline(), 30)).decode().strip()
            if not first.startswith("TICKET "): raise RuntimeError("Swift did not create its setup intent")
            ticket = first.removeprefix("TICKET ")
            lease = secrets.token_hex(32)
            state.set('pairing-panel/' + lease, {'version': 1, 'pid': os.getpid(), 'expires': __import__('time').time()+1200})
            async def cli(status=False):
                process = await asyncio.create_subprocess_exec(sys.executable, "-m", "hermes_jr.cli", "pair", "--ticket", ticket,
                    *(["--status"] if status else []), env={**os.environ, "HERMES_JR_STATE_DIR": str(state.directory),
                    "PYTHONPATH": str(ROOT / "Companion/src"), LEASE_ENV: lease}, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                # Capture output only after exit, exactly like a non-streaming agent tool.
                out, err = await asyncio.wait_for(process.communicate(), 20)
                if process.returncode: raise RuntimeError("Pairing CLI failed: " + err.decode())
                return json.loads(out)
            value = await cli()
            for _ in range(20):
                if value["status"] == "ready": break
                assert value["status"] == "pending"
                await asyncio.sleep(.5)
                value = await cli(True)
            assert value["status"] == "ready", value
            assert 'code' not in value, 'The model-facing subprocess must not contain the code'
            code = job_result(state, job_identity(ticket))['code']
            assert not state.devices(), "No device may be enrolled before phone confirmation"
            print("PASS: foreground CLI hands off to the panel without returning its code to the model", flush=True)
            # The command has already exited. Restart the long-lived owner and
            # prove the same code/session completes afterward.
            bridge.cancel(); await asyncio.gather(bridge, return_exceptions=True)
            bridge = asyncio.create_task(Bridge(state, http).run())
            await asyncio.sleep(1.2)
            assert (await cli(True))['status'] == 'ready'
            assert job_result(state, job_identity(ticket))['code'] == code
            class Panel:
                closed = False
                def show(self, text):
                    assert code in text
                def cancelled(self): return False
                def close(self): self.closed = True
            panel = Panel()
            pairing = asyncio.create_task(asyncio.to_thread(wait_for_panel, state, job_identity(ticket), panel,
                                                           interrupted=panel_interrupt.is_set))
            await asyncio.sleep(.3)
            assert not pairing.done(), "The panel must remain open before phone confirmation"
            code_path.write_text(code)
            out, _ = await asyncio.wait_for(swift.communicate(), 90)
            print(out.decode(), end="", flush=True)
            if swift.returncode: raise RuntimeError("Swift numeric pairing failed")
            for _ in range(20):
                final = await cli(True)
                if final["status"] == "connected": break
                await asyncio.sleep(1)
            assert final["status"] == "connected", final
            assert (await asyncio.wait_for(pairing, 10))['status'] == 'connected' and panel.closed
            print("PASS: pairing panel dismisses automatically after authenticated profile discovery", flush=True)
            print("PASS: service restart preserves the exchange; short status command reports authenticated completion", flush=True)
            assert len(state.devices()) == 1 and state.devices()[0]["approved"]
            assert state.devices()[0]["pair_digest"] is None
            with state.connect() as db:
                assert all("private" not in json.loads(row[0]) for row in db.execute("SELECT value FROM settings WHERE key LIKE 'setup/%'"))
    except Exception:
        log.flush()
        print((temp / "worker.log").read_text()[-3000:])
        raise
    finally:
        panel_interrupt.set()
        if pairing:
            with contextlib.suppress(Exception, asyncio.CancelledError):
                await asyncio.wait_for(asyncio.shield(pairing), 3)
        for task in [pairing, bridge]:
            if task:
                task.cancel(); await asyncio.gather(task, return_exceptions=True)
        if runner: await runner.cleanup()
        for process in [swift, worker]:
            if process and process.returncode is None:
                process.terminate()
                try: await asyncio.wait_for(process.wait(), 5)
                except asyncio.TimeoutError: process.kill(); await process.wait()
        log.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="hermes-numeric-") as directory:
        asyncio.run(run(Path(directory)))
