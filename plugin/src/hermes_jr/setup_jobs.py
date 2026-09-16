"""Service-owned pairing jobs with bounded, non-streaming command results."""
from __future__ import annotations
import asyncio
import hashlib
import time
import shlex
import sys
import aiohttp
from . import setup_crypto, __version__
from .setup_pairing import run, SetupExpired
from .service import ServiceError
from .gateway import Gateway
from .setup_failures import SetupFailure, details

TERMINAL = {"connected", "expired", "failed"}


def initialize(state):
    with state.connect() as db:
        db.execute("CREATE TABLE IF NOT EXISTS setup_jobs (id TEXT PRIMARY KEY, ticket TEXT, name TEXT NOT NULL, status TEXT NOT NULL, code TEXT, expires REAL NOT NULL, updated REAL NOT NULL)")


def identity(ticket):
    return hashlib.sha256(ticket.encode()).hexdigest()


def result(state, job_id):
    with state.connect() as db:
        row = db.execute("SELECT status,code,expires FROM setup_jobs WHERE id=?", (job_id,)).fetchone()
    if not row:
        return {"status": "not_found", "message": "No pairing attempt exists for this ticket. Start pairing first."}
    status = row["status"]
    if status not in TERMINAL and row["expires"] <= time.time():
        status = "expired"
    messages = {
        "pending": "Waiting for the iPhone. Check status again shortly; do not start another attempt.",
        "ready": "Show this code to the user now. Compare all three groups on the iPhone, then tap It’s correct. Pairing is not complete yet.",
        "connected": "The iPhone has authenticated and connected. Pairing is complete.",
        "expired": "Pairing expired without completing. Create a fresh setup prompt in Jr.; do not report success.",
        "failed": "Pairing could not be completed. Create a fresh setup prompt in Jr.; do not report success.",
    }
    value = {"status": status, "message": messages[status]}
    if status in {'expired', 'failed'}:
        value.update(details('expired' if status == 'expired' else state.get('setup-failure/' + job_id)))
    if status == 'connected':
        value['user_message'] = 'Your iPhone is connected.'
        value['instruction'] = 'Say only the user_message; omit commands, versions, paths and JSON.'
    if status == "ready":
        value.update(code=row["code"], expires_at=row["expires"])
    if status in {"pending", "ready"}:
        value["completion_watch"] = {
            "name": "terminal",
            "arguments": {"command": shlex.join([sys.executable, "-m", "hermes_jr.cli", "pair", "--watch", job_id]), "timeout": 360},
            "instruction": "Show the ready code in a visible assistant message, then call terminal with these exact arguments in the same turn. Wait for the result before reporting completion."}
        value["watch_command"] = "hermes jr pair --watch " + job_id
    return value


async def wait_for_completion(state, job_id):
    """Read-only bounded waiter; the installing agent shows the code before invoking it."""
    if len(job_id) != 64 or any(c not in '0123456789abcdef' for c in job_id):
        raise ValueError("Invalid pairing job ID")
    initialize(state)
    # No ticket, network calls, authorization or second pairing attempt.
    deadline = time.monotonic() + 1200
    while True:
        value = result(state, job_id)
        if value['status'] not in {'pending', 'ready'}:
            return value
        if time.monotonic() >= deadline:
            return {'status': 'expired', 'message': 'Pairing monitoring timed out; check the existing attempt before retrying.'}
        await asyncio.sleep(1)


def publish(state, job_id, status, *, code=None, expires_at=None, reason=None):
    if reason:
        state.set('setup-failure/' + job_id, reason)
    with state.connect() as db:
        db.execute("UPDATE setup_jobs SET status=?,code=?,expires=COALESCE(?,expires),updated=?,ticket=CASE WHEN ? THEN NULL ELSE ticket END WHERE id=?",
                   (status, code, expires_at, time.time(), status in TERMINAL, job_id))


async def command(state, service, ticket, name, *, status_only=False, wait_seconds=8):
    initialize(state)
    job_id = identity(ticket)
    existing = result(state, job_id)
    if status_only or existing["status"] != "not_found":
        return existing
    from .installation_health import require_consistent
    require_consistent()
    if not 1 <= len(name) <= 80:
        raise ValueError("Invalid phone name")
    if not state.get("relay_enabled") or not state.get("host_private_key"):
        raise ValueError("Configure the companion before pairing")
    heartbeat = state.get("setup_worker", {})
    if heartbeat.get("version") != 1 or heartbeat.get("package_version") != __version__ or time.time() - heartbeat.get("at", 0) > 5:
        raise ValueError("Restart the updated companion service with hermes jr service restart before pairing")
    try:
        await Gateway(state, service.client).probe()
    except (aiohttp.ClientError, ValueError, KeyError, OSError, asyncio.TimeoutError) as exc:
        raise ValueError("Hermes backend is not ready. Run hermes jr doctor and follow its recovery action. For a missing listener, run hermes jr backend install; the messaging gateway is a different service. No pairing attempt was created.") from None
    issuer = await asyncio.wait_for(service.request("GET", "/v1/pairing/key"), 10)
    intent = setup_crypto.verify_ticket(ticket, issuer["public_key"], state.get("service_url"))
    with state.connect() as db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM setup_jobs WHERE expires < ?", (time.time() - 86400,))
        active = db.execute("SELECT id FROM setup_jobs WHERE status IN ('pending','ready') AND expires > ?", (time.time(),)).fetchone()
        if active and active["id"] != job_id:
            raise ValueError("Another pairing attempt is active. Cancel it in Jr. before starting a new one")
        db.execute("INSERT OR IGNORE INTO setup_jobs (id,ticket,name,status,code,expires,updated) VALUES (?,?,?,'pending',NULL,?,?)", (job_id, ticket, name, intent["expires_at"], time.time()))
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        value = result(state, job_id)
        if value["status"] != "pending":
            return value
        await asyncio.sleep(.2)
    return result(state, job_id)


async def perform(state, service, job):
    try:
        await run(state, service, job["ticket"], job["name"],
                  report=lambda status, **fields: publish(state, job["id"], status, **fields))
    except SetupFailure as exc:
        publish(state, job['id'], 'expired' if exc.reason == 'expired' else 'failed', reason=exc.reason)
    except (aiohttp.ClientError, OSError, asyncio.TimeoutError):
        await asyncio.sleep(3)  # Same persisted job and cryptographic state retry after transport recovery.
    except ServiceError as exc:
        if exc.status in {429, 500, 502, 503, 504}:
            await asyncio.sleep(10)
        else:
            reason = {410: 'expired', 404: 'unavailable', 401: 'rejected', 403: 'rejected', 409: 'conflict'}.get(exc.status, 'internal')
            publish(state, job['id'], 'expired' if reason == 'expired' else 'failed', reason=reason)
    except Exception:
        # Unexpected failures are terminal and sanitized, never a success or an endless ready state.
        publish(state, job["id"], "failed", reason="internal")


async def watch(state, service):
    initialize(state)
    task = None
    try:
        while True:
            state.set("setup_worker", {"version": 1, "package_version": __version__, "at": time.time()})
            if task and task.done():
                # Observe failures without taking down the relay; never expose credentials in logs.
                try: task.result()
                except Exception: pass
                task = None
            if task is None:
                with state.connect() as db:
                    db.execute("UPDATE setup_jobs SET status='expired',code=NULL,ticket=NULL WHERE status IN ('pending','ready') AND expires<=?", (time.time(),))
                    job = db.execute("SELECT * FROM setup_jobs WHERE status IN ('pending','ready') ORDER BY updated LIMIT 1").fetchone()
                if job:
                    task = asyncio.create_task(perform(state, service, dict(job)))
            await asyncio.sleep(1)
    finally:
        if task:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
