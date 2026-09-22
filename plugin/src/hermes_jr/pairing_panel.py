"""Pairing UI lifecycle, owned by the plugin rather than the model's response.

The short-lived lease connects a terminal subprocess to the exact Hermes tool
call displaying its panel. It is not pairing authority; only the phone can grant
that. No code is returned to the model, and an unloaded plugin cannot start a job.
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import secrets
import time

from .state import State
from . import setup_jobs as jobs

LEASE_ENV = "HERMES_JR_PAIRING_PANEL"
UNAVAILABLE = ("The Hermes Jr. pairing panel is not active in this conversation. "
               "Restart this Hermes CLI process or quit and reopen Hermes Desktop after installing/updating "
               "the companion, then run the same pairing command. Keep the installation and existing "
               "connections. If the setup ticket expires, copy a fresh prompt from Jr. "
               "Do not start a background watcher or ask the model to display the code.")


def live(lease):
    if lease.get("version") != 1 or lease.get("expires", 0) <= time.time():
        return False
    try:
        pid = lease["pid"]
        if not isinstance(pid, int) or pid <= 0:
            return False
        os.kill(pid, 0)
    except (KeyError, OSError, TypeError):
        return False
    return True


def claim(state, job_id, *, connection=None):
    """Called by the CLI before starting any exchange or reading a code."""
    nonce = os.environ.get(LEASE_ENV, "")
    if not re.fullmatch(r"[0-9a-f]{64}", nonce) or not re.fullmatch(r"[0-9a-f]{64}", job_id):
        raise ValueError(UNAVAILABLE)
    with (state.connect() if connection is None else contextlib.nullcontext(connection)) as db:
        if connection is None:
            db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT value FROM settings WHERE key=?", ("pairing-panel/" + nonce,)).fetchone()
        lease = json.loads(row[0]) if row else {}
        if not live(lease) or lease.get("job_id") not in (None, job_id):
            raise ValueError(UNAVAILABLE)
        owner_key = "pairing-panel-owner/" + job_id
        owner = db.execute("SELECT value FROM settings WHERE key=?", (owner_key,)).fetchone()
        if owner and json.loads(owner[0]) != nonce:
            other = db.execute("SELECT value FROM settings WHERE key=?", ("pairing-panel/" + json.loads(owner[0]),)).fetchone()
            if other and live(json.loads(other[0])):
                raise ValueError("This attempt already has a pairing panel. Use the existing panel and confirm on the iPhone.")
        db.execute("INSERT OR REPLACE INTO settings VALUES (?,?)", (owner_key, json.dumps(nonce)))
        lease["job_id"] = job_id
        db.execute("UPDATE settings SET value=? WHERE key=?", (json.dumps(lease), "pairing-panel/" + nonce))


def public_result(value):
    """Tool results contain status only. The native UI reads the code locally."""
    result = {k: v for k, v in value.items() if k not in {"code", "completion_watch", "instruction", "user_message"}}
    if value["status"] in {"pending", "ready"}:
        result["message"] = "The native pairing panel is handling iPhone confirmation."
    elif value["status"] == "connected":
        result["user_message"] = "Your iPhone is connected."
    return result


def question(value):
    if value["status"] == "ready":
        code = value.get("code", "")
        if not re.fullmatch(r"[1-9][0-9]{3} [1-9][0-9]{3} [1-9][0-9]{3}", code):
            raise ValueError("The pairing code is invalid. Cancel this attempt and try again.")
        return (f"Pair your iPhone\n\n{code}\n\nCompare all three groups with Hermes Jr., "
                "then tap It’s correct on your iPhone.\n\nWaiting for confirmation…")
    return "Pair your iPhone\n\nOpen Hermes Jr. on your iPhone to continue setup.\n\nWaiting for your iPhone…"


def wait(state, job_id, surface, *, interrupted=lambda: False, heartbeat=lambda: None, poll=.2):
    """One bounded wait; any local response cancels, never approves."""
    shown = None
    deadline = time.monotonic() + 1200
    try:
        while True:
            value = jobs.result(state, job_id)
            if value["status"] not in {"pending", "ready"}:
                return public_result(value)
            if surface.cancelled() or interrupted() or time.monotonic() >= deadline:
                jobs.cancel(state, job_id)
                return public_result(jobs.result(state, job_id))
            text = question(value)
            if text != shown:
                surface.show(text)
                shown = text
            heartbeat()
            time.sleep(poll)
    except Exception:
        jobs.cancel(state, job_id)
        raise
    finally:
        surface.close()


def register(ctx):
    """Wrap the existing terminal entry point; do not add a model-dependent tool."""
    if not callable(getattr(ctx, "register_middleware", None)):
        return

    def pairing_call(tool_name, args, next_call, session_id="", task_id="", **kwargs):
        command = args.get("command", "")
        if (tool_name != "terminal" or not isinstance(command, str)
                or not re.search(r"\b(?:hermes_jr\.cli|hermes-jr|hermes\s+jr)['\"]?\s+['\"]?pair\b", command)):
            return next_call(args)
        # Resolve before launching the command. Unsupported contexts must never
        # leave the user waiting for a panel which cannot be shown.
        from .pairing_surfaces import resolve
        try:
            surface = resolve(ctx, session_id or task_id)
        except (ImportError, ValueError, AttributeError):
            return json.dumps({"output": UNAVAILABLE, "exit_code": 1})
        state = State()
        jobs.initialize(state)
        nonce = secrets.token_hex(32)
        key = "pairing-panel/" + nonce
        state.set(key, {"version": 1, "pid": os.getpid(), "expires": time.time() + 1200})
        job_id = None
        try:
            # A subshell bounds the lease to this invocation even on backends
            # that preserve shell environment between terminal calls.
            amended = dict(args, command=f"( export {LEASE_ENV}={nonce}\n{command}\n)",
                           background=False, pty=False, timeout=180)
            for modifier in ("notify", "notify_on_complete", "watch_patterns"):
                amended.pop(modifier, None)
            original = next_call(amended)
            job_id = state.get(key, {}).get("job_id")
            try:
                original_data = json.loads(original) if isinstance(original, str) else dict(original)
            except (ValueError, TypeError):
                original_data = {}
            if original_data.get("status") == "yielded_to_background":
                return json.dumps({"output": "Pairing was interrupted before the native panel opened. "
                    "Retry in this conversation; if the ticket expired, copy a fresh setup prompt from Jr.", "exit_code": 1})
            if not job_id:
                if original_data.get("exit_code") not in (None, 0):
                    return original
                return json.dumps({"output": "The pairing command did not attach to the native panel. "
                    "Check that it uses the updated companion in the same Hermes Python environment. " + UNAVAILABLE, "exit_code": 1})
            if jobs.result(state, job_id)["status"] == "not_found":
                return original  # Preserve the precise preflight error; no exchange started.
            from tools.approval_human_wait import human_wait_window, activity_heartbeat
            from tools.interrupt import is_interrupted
            with human_wait_window():
                value = wait(state, job_id, surface, interrupted=is_interrupted,
                             heartbeat=activity_heartbeat("Hermes Jr. pairing"))
            try:
                result = json.loads(original) if isinstance(original, str) else dict(original)
            except (ValueError, TypeError):
                result = {}
            result.update(output=json.dumps(value, ensure_ascii=False),
                          exit_code=0 if value["status"] == "connected" else 1)
            return json.dumps(result, ensure_ascii=False)
        except Exception:
            job_id = job_id or state.get(key, {}).get("job_id")
            if job_id:
                jobs.cancel(state, job_id)
            return json.dumps({"output": "The pairing panel could not continue. Pairing was not completed. " + UNAVAILABLE,
                               "exit_code": 1})
        finally:
            with contextlib.suppress(Exception):
                surface.close()
            with state.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                # Serialize withdrawal with a child still finishing preflight.
                # It must either have created a job that we cancel, or fail its
                # lease check before inserting one. Never leave a hidden attempt.
                row = db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
                job_id = job_id or (json.loads(row[0]).get("job_id") if row else None)
                if job_id:
                    jobs.cancel(state, job_id, connection=db)
                db.execute("DELETE FROM settings WHERE key=?", (key,))
                if job_id:
                    db.execute("DELETE FROM settings WHERE key=? AND value=?", ("pairing-panel-owner/" + job_id, json.dumps(nonce)))

    ctx.register_middleware("tool_execution", pairing_call)
