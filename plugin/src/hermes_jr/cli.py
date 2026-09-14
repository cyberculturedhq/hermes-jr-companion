"""Local owner commands. Configuration writes occur only through explicit commands."""
from __future__ import annotations
import argparse
import asyncio
import base64
import contextlib
import hashlib
import json
import logging
import os
import signal
import sys
import time
import uuid
import aiohttp
from .gateway import dashboard_url
from .service import Service, client_session, validate_service_url
from .state import State, token


def encoded(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def configure_parser(parser):
    commands = parser.add_subparsers(dest="jr_command", required=True)
    setup = commands.add_parser("setup", help="Configure service and independent remote/push switches")
    setup.add_argument("--service", required=True)
    setup.add_argument("--dashboard", default="http://127.0.0.1:9119")
    setup.add_argument("--relay", action=argparse.BooleanOptionalAction, default=None)
    setup.add_argument("--push", action=argparse.BooleanOptionalAction, default=None)
    setup.add_argument("--allow-local-service", action="store_true", help="Allow loopback HTTP for development")
    managed = commands.add_parser("service", help="Manage automatic startup and crash recovery")
    managed.add_argument("service_action", choices=["install", "start", "stop", "restart", "status", "uninstall"])
    commands.add_parser("doctor", help="Check service and dashboard connectivity without exposing secrets")
    update = commands.add_parser("update", help="Check stable releases and show the explicit update procedure")
    update.add_argument("--install", action="store_true", help="Explicitly install the latest compatible stable release with rollback; use when Hermes work is idle")
    commands.add_parser("rollback", help="Restore the code saved by the last managed update; preserve pairings")
    update.add_argument("--checks", choices=["on", "off"], help="Enable or disable automatic daily release checks")
    pair = commands.add_parser("pair", help="Create a ten-minute pairing invitation")
    pair.add_argument("--name", default="iPhone")
    pair.add_argument("--no-wait", action="store_true", help="Return after opening the page instead of waiting for the phone")
    output = pair.add_mutually_exclusive_group()
    output.add_argument("--browser", action="store_true", help="Open a private branded QR page (default)")
    output.add_argument("--json", action="store_true", help="Output invitation JSON for automation")
    output.add_argument("--url", action="store_true", help="Output a hermes-jr:// pairing URL without opening a browser")
    output.add_argument("--qr", action="store_true", help="Open the browser QR page (alias for --browser; no terminal QR output)")
    approve = commands.add_parser("approve", help="Approve a phone after checking its fingerprint")
    approve.add_argument("device_id")
    approve.add_argument("--fingerprint", required=True, help="SHA256 key fingerprint shown on the phone")
    revoke = commands.add_parser("revoke", help="Immediately revoke this device locally and at the service")
    revoke.add_argument("device_id")
    commands.add_parser("devices", help="List device IDs and public key fingerprints")
    commands.add_parser("status", help="Inspect configuration without revealing credentials")
    commands.add_parser("run", help="Run the supervised foreground bridge until SIGINT/SIGTERM")


def fingerprint(device):
    value = device.get("public_key")
    return hashlib.sha256(base64.urlsafe_b64decode(value + "=")).hexdigest() if value else None


def print_pairing(payload, *, as_url=False, out=None, err=None):
    """Render an already-created invitation; this function never creates state or credentials."""
    out, err = out or sys.stdout, err or sys.stderr
    compact = json.dumps(payload, separators=(",", ":"))
    url = "hermes-jr://pair#" + encoded(compact.encode())
    print(url if as_url else compact, file=out)
    host_key = base64.urlsafe_b64decode(payload["host_public_key"] + "=")
    print("Host fingerprint (SHA256): " + hashlib.sha256(host_key).hexdigest(), file=err)
    print("Compare this host fingerprint with Hermes Jr. before connecting.", file=err)
    print("Keep this invitation private. Hermes must inspect the pending device and approve it after checking the fingerprint supplied by the user; do not ask the user to run commands.", file=err)


async def execute(args):
    state = State()
    if args.jr_command == "rollback":
        from .installer import rollback
        await asyncio.to_thread(rollback, state)
        return
    if args.jr_command == "service":
        from .supervisor import Supervisor
        manager = Supervisor(state)
        if args.service_action == "restart":
            manager.stop()
            manager.start()
        elif args.service_action != "status":
            getattr(manager, args.service_action)()
        print(json.dumps(manager.status(), indent=2))
        return
    async with client_session(timeout=aiohttp.ClientTimeout(total=30)) as client:
        service = Service(state, client)
        if args.jr_command == "doctor":
            from .diagnostics import check
            print(json.dumps(await check(state, client), indent=2))
        elif args.jr_command == "update":
            from .updates import check
            if args.checks:
                state.settings({"update_checks_enabled": args.checks == "on"})
            result = await check(state, client, force=True) if args.checks != "off" else state.get("update_status", {})
            print(json.dumps({"automatic_checks": state.get("update_checks_enabled", True), **result}, indent=2))
            if getattr(args, "install", False):
                if args.checks == "off":
                    raise ValueError("Cannot install while disabling release checks")
                from .installer import install
                await asyncio.to_thread(install, state, result)
            elif result.get("state") == "available":
                print("Install explicitly when Hermes work is idle. Follow https://github.com/cyberculturedhq/hermes-jr-companion/blob/main/UPDATES.md")
                print("Target immutable commit: " + result["commit"])
        elif args.jr_command == "setup":
            origin = validate_service_url(args.service, allow_local=args.allow_local_service)
            local = dashboard_url(args.dashboard)
            prior = state.get("service_url")
            if prior and prior != origin and state.devices():
                raise ValueError("Revoke existing devices before moving to another service")
            service = Service(state, client, origin=origin)
            capabilities = await service.request("GET", "/v1/capabilities")
            if capabilities.get("protocol_version") != 1:
                raise ValueError("Unsupported service protocol")
            push_enabled = state.get("push_enabled", False) if args.push is None else args.push
            relay_enabled = state.get("relay_enabled", False) if args.relay is None else args.relay
            if push_enabled and capabilities.get("push") is not True:
                raise ValueError("This service has not configured Apple push delivery")
            values = {"service_url": origin, "dashboard_url": local, "relay_enabled": relay_enabled, "push_enabled": push_enabled}
            if not state.get("installation_id") or prior != origin:
                installation = await service.request("POST", "/v1/installations", {})
                values.update(installation_id=str(uuid.UUID(installation["installation_id"])), host_token=installation["host_token"])
            if not state.get("host_private_key"):
                from .secure_channel import generate_private_key
                values["host_private_key"] = encoded(generate_private_key())
            state.settings(values)
            print("Companion configured. Enable the Hermes plugin and restart Hermes, then run: hermes jr service install")
        elif args.jr_command == "pair":
            from .secure_channel import public_key
            if not state.get("relay_enabled", False):
                raise ValueError("Remote access is disabled; enable it with hermes jr setup --relay")
            if not 1 <= len(args.name) <= 80:
                raise ValueError("Device name must contain 1–80 characters")
            from .cleanup import sweep
            await sweep(state, service)
            device = await service.add_device()
            device_id = str(uuid.UUID(device["device_id"]))
            secret, expires = token(), int(time.time()) + 600
            state.add_device(device_id, args.name, device["device_token"], secret=secret, expires=expires, automatic=True)
            payload = {"v": 1, "relay_url": state.get("service_url"), "installation_id": state.get("installation_id"),
                       "device_id": device_id, "device_token": device["device_token"],
                       "host_public_key": encoded(public_key(base64.urlsafe_b64decode(state.get("host_private_key") + "="))),
                       "pairing_secret": secret, "expires_at": expires}
            if args.url or args.json:
                print_pairing(payload, as_url=args.url)
            else:
                from .pairing_page import open_page
                page = await asyncio.to_thread(open_page, payload, state.directory)
                if not args.no_wait:
                    from .pairing_page import wait_for_phone
                    await wait_for_phone(state, device_id, expires, page)
        elif args.jr_command == "approve":
            device_id = str(uuid.UUID(args.device_id))
            device = state.device(device_id)
            wanted = args.fingerprint.lower().replace(":", "").replace(" ", "")
            if not device or fingerprint(device) != wanted:
                raise ValueError("Fingerprint does not match the phone that claimed this invitation")
            state.approve(device_id)
            print("Phone approved. Its pending encrypted connection can now open Hermes.")
        elif args.jr_command == "revoke":
            device_id = str(uuid.UUID(args.device_id))
            state.revoke(device_id)  # Local authority revokes first even during an Internet outage.
            try:
                await service.delete_device(device_id)
                state.deleted_remotely(device_id)
            except (ValueError, aiohttp.ClientError):
                raise ValueError("Device revoked locally. Service unavailable; the running companion will retry removal automatically") from None
            print("Device revoked and its local follows and notification references removed.")
        elif args.jr_command == "devices":
            print(json.dumps([{"device_id": d["id"], "name": d["name"], "approved": bool(d["approved"]),
                               "fingerprint": fingerprint(d), "push_enabled": bool(d["push_enabled"])} for d in state.devices()], indent=2))
        elif args.jr_command == "status":
            print(json.dumps({k: state.get(k) for k in ("installation_id", "service_url", "dashboard_url", "relay_enabled", "push_enabled", "health", "update_status")}, indent=2))
        elif args.jr_command == "run":
            if not state.get("host_token"):
                raise ValueError("Run hermes jr setup first")
            from .bridge import Bridge
            # Advisory OS lock prevents two supervisors sharing one host socket or outbox.
            import fcntl
            with (state.directory / "bridge.lock").open("a+") as lock:
                try:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise ValueError("The companion bridge is already running") from None
                os.chmod(lock.name, 0o600)
                logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
                task = asyncio.create_task(Bridge(state, client).run())
                loop = asyncio.get_running_loop()
                for sig in (signal.SIGINT, signal.SIGTERM):
                    loop.add_signal_handler(sig, task.cancel)
                try:
                    with contextlib.suppress(asyncio.CancelledError):
                        await task
                finally:
                    for sig in (signal.SIGINT, signal.SIGTERM):
                        loop.remove_signal_handler(sig)


def dispatch(args):
    try:
        asyncio.run(execute(args))
    except (ValueError, PermissionError) as exc:
        raise SystemExit(str(exc)) from None
    except (KeyError, aiohttp.ClientError):
        # Full network exceptions may include the local WebSocket authorization query.
        raise SystemExit("Companion service request failed. Check the service configuration; run hermes jr status for non-secret settings.") from None


def main():
    parser = argparse.ArgumentParser(prog="hermes-jr")
    configure_parser(parser)
    dispatch(parser.parse_args())


if __name__ == "__main__":
    main()
