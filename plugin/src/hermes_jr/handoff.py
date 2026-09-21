"""Explicitly close a verified standalone CLI before resuming its saved chat.

Never remove a lease, kill a process group, or stop a shared server. Preview
issues a short-lived, device-bound ticket; commit rechecks the exact owner.
"""
from __future__ import annotations
import asyncio
import os
from pathlib import Path
import secrets
import threading
import time

_tickets = {}
_ticket_lock = threading.Lock()


class HandoffUnavailable(Exception):
    pass


def _runtime(profile):
    try:
        import psutil
        import hermes_cli
        from hermes_cli import active_sessions as registry
        from hermes_cli.profiles import resolve_profile_env
        home = Path(resolve_profile_env(profile)).resolve()
        executable = Path(hermes_cli.__file__).resolve().parent.parent / 'hermes'
        return registry, psutil, home, executable
    except (ImportError, ValueError, OSError) as exc:
        raise HandoffUnavailable('This Hermes installation does not support safe CLI handoff.') from exc


def _owner(entries, session_id):
    owners = [e for e in entries if e.get('session_id') == session_id]
    if not owners:
        return None
    if len(owners) != 1 or owners[0].get('surface') != 'cli':
        raise HandoffUnavailable('This chat belongs to a shared Hermes runtime. Close it there before continuing here.')
    owner = owners[0]
    if sum(e.get('pid') == owner.get('pid') for e in entries) != 1:
        raise HandoffUnavailable('The owner also holds other chats; it cannot be closed from this device.')
    return owner


def _process(psutil, owner, executable):
    try:
        pid = owner['pid']
        started = owner['process_start_time']
        if type(pid) is not int or pid <= 1 or pid == os.getpid() or not isinstance(started, (int, float)):
            raise ValueError()
        proc = psutil.Process(pid)
        argv = proc.cmdline()
        # Only the plain interactive CLI. Workers, dashboards, scripts, and
        # noninteractive queries are deliberately excluded from remote closure.
        if (proc.uids().real != os.getuid() or proc.create_time() != started
                or not proc.terminal() or len(argv) < 2
                or Path(argv[1]).resolve() != executable.resolve()):
            raise ValueError()
        args = argv[2:]
        if args and not (len(args) == 2 and args[0] in {'--resume', '-r'}
                         and args[1] == owner['session_id']):
            raise ValueError()
        return proc
    except (KeyError, ValueError, OSError, psutil.Error) as exc:
        raise HandoffUnavailable('The CLI owner could not be verified. Close that chat from its terminal.') from exc


def preview(device_id, profile, session_id):
    registry, psutil, home, executable = _runtime(profile)
    owner = _owner(registry.active_session_registry_snapshot(home, strict=True), session_id)
    if owner is None:
        return {'ready': True}
    _process(psutil, owner, executable)
    with _ticket_lock:
        now = time.monotonic()
        for key in list(_tickets):
            if _tickets[key]['expires'] < now:
                del _tickets[key]
        if len(_tickets) >= 128:
            raise HandoffUnavailable('Too many handoff requests. Try again shortly.')
        token = secrets.token_urlsafe(32)
        _tickets[token] = dict(device=device_id, profile=profile, session=session_id,
                               home=str(home), owner=dict(owner), expires=now + 120)
    return {'ready': False, 'ticket': token,
            'message': 'This will close the Hermes CLI chat on your other device and interrupt any reply or tool still running there. Saved messages will be loaded here. Unsent text in that terminal will not transfer.'}


def commit(device_id, profile, session_id, token):
    with _ticket_lock:
        ticket = _tickets.get(token)
        if not ticket or any(ticket[k] != v for k, v in
                             [('device', device_id), ('profile', profile), ('session', session_id)]):
            raise HandoffUnavailable('This handoff confirmation is invalid. Check the session again.')
        del _tickets[token]  # One attempt, including uncertain shutdown outcomes.
    if ticket['expires'] < time.monotonic():
        raise HandoffUnavailable('This handoff confirmation expired. Check the session again.')
    registry, psutil, home, executable = _runtime(profile)
    if str(home) != ticket['home']:
        raise HandoffUnavailable('The profile changed. Check the session again.')
    # Fence session switches while verifying and signaling. Release immediately:
    # the exiting CLI needs this same lock for its normal cleanup.
    with registry._FileLock(registry._lock_path(home)):
        entries = registry._read_entries(registry._state_path(home), strict=True)
        owner = _owner(entries, session_id)
        if owner != ticket['owner']:
            raise HandoffUnavailable('The session owner changed. Check the session again.')
        proc = _process(psutil, owner, executable)
        proc.terminate()  # SIGTERM invokes Hermes's graceful shutdown handler.
    try:
        proc.wait(timeout=15)
    except psutil.TimeoutExpired as exc:
        raise HandoffUnavailable('The CLI is still shutting down. Wait, then reopen this chat. No second writer was started.') from exc
    if any(e.get('session_id') == session_id for e in registry.active_session_registry_snapshot(home, strict=True)):
        raise HandoffUnavailable('Another window opened this chat during handoff. Check the session again.')
    return {'ready': True}


async def handle(device_id, profile, session_id, body, *, confirm=False):
    try:
        if confirm:
            if body.get('confirm_close_cli') is not True or not isinstance(body.get('ticket'), str):
                raise HandoffUnavailable('Confirm closing the CLI before continuing.')
            return await asyncio.to_thread(commit, device_id, profile, session_id, body['ticket'])
        return await asyncio.to_thread(preview, device_id, profile, session_id)
    except HandoffUnavailable as exc:
        return {'ready': False, 'error': str(exc)}
    except Exception:
        # No internal paths/process details or credentials in remote errors.
        return {'ready': False, 'error': 'Hermes could not verify the handoff. Reopen the chat to check its current state.'}
