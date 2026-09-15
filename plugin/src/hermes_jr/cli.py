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
from .state import State


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
    backend = commands.add_parser("backend", help="Manage a dedicated loopback Hermes backend when no existing supervisor provides one")
    backend.add_argument("backend_action", choices=["install", "status", "uninstall"])
    commands.add_parser("doctor", help="Check service and dashboard connectivity without exposing secrets")
    update = commands.add_parser("update", help="Check stable releases and show the explicit update procedure")
    update.add_argument("--install", action="store_true", help="Explicitly install the latest compatible stable release with rollback; use when Hermes work is idle")
    commands.add_parser("rollback", help="Restore the code saved by the last managed update; preserve pairings")
    update.add_argument("--checks", choices=["on", "off"], help="Enable or disable automatic daily release checks")
    pair = commands.add_parser("pair", help="Connect using the phone’s setup ticket and numeric comparison")
    pair.add_argument("--name", default="iPhone")
    pair.add_argument("--status", action="store_true", help="Read the service-owned pairing result for --ticket; never waits for approval")
    output = pair.add_mutually_exclusive_group(required=True)
    output.add_argument("--watch", metavar="JOB_ID", help="Wait for pairing completion after showing the comparison code to the user")
    output.add_argument("--ticket", help="Pair with the iPhone that created this public HJ1 setup ticket; compare the displayed codes")
    revoke = commands.add_parser("revoke", help="Immediately revoke this device locally and at the service")
    revoke.add_argument("device_id")
    commands.add_parser("devices", help="List device IDs and public key fingerprints")
    commands.add_parser("status", help="Inspect configuration without revealing credentials")
    commands.add_parser("run", help="Run the supervised foreground bridge until SIGINT/SIGTERM")


def fingerprint(device):
    value = device.get("public_key")
    return hashlib.sha256(base64.urlsafe_b64decode(value + "=")).hexdigest() if value else None


async def execute(args):
    state = State()
    if args.jr_command == "backend":
        from .backend import BackendSupervisor
        manager = BackendSupervisor(state)
        if args.backend_action != "status":
            await asyncio.to_thread(getattr(manager, args.backend_action))
        print(json.dumps(manager.status(), indent=2))
        return
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
            print("Companion configured. Follow INSTALL.md to verify backend startup and run hermes jr service install.")
        elif args.jr_command == "pair":
            if args.watch:
                if args.status:
                    raise ValueError("--watch cannot be combined with --status")
                from .setup_jobs import wait_for_completion
                result = await wait_for_completion(state, args.watch)
                print(json.dumps(result, ensure_ascii=False), flush=True)
                if result["status"] != "connected":
                    raise SystemExit(1)
                return
            if getattr(args, "ticket", None):
                from .setup_jobs import command
                result = await command(state, service, args.ticket, args.name, status_only=args.status)
                print(json.dumps(result, ensure_ascii=False))
                if result["status"] in {"expired", "failed", "not_found"}:
                    raise SystemExit(1)
                return
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
