"""User-requested update receipts and durable, verified completion notifications.

Registration never installs code. Only the signed, explicitly invoked installer
can mark a receipt complete. The bridge recovers the narrow post-commit crash
window from the installer's durable journal, without asking a model.
"""
from __future__ import annotations
import asyncio
import base64
import json
import re
import time
import uuid

from .updates import installed_version, version
from .state import token

SCHEMA = """CREATE TABLE IF NOT EXISTS update_requests (
    id TEXT PRIMARY KEY, device_id TEXT NOT NULL, profile TEXT NOT NULL,
    session_id TEXT NOT NULL, target TEXT NOT NULL, notify INTEGER NOT NULL,
    created REAL NOT NULL, status TEXT NOT NULL, installed TEXT, error TEXT, finished REAL)"""


def initialize(state):
    with state.connect() as db:
        db.execute(SCHEMA)
        db.execute('DELETE FROM update_requests WHERE created<?', (time.time() - 7 * 86400,))


def validate(value):
    if not isinstance(value, dict) or set(value) != {'id', 'device_id', 'profile', 'session_id', 'target', 'notify', 'created'}:
        raise ValueError('Invalid update receipt')
    for key in ('id', 'device_id'):
        if not isinstance(value[key], str) or str(uuid.UUID(value[key])) != value[key]:
            raise ValueError('Invalid update identity')
    if not isinstance(value['profile'], str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', value['profile']) or '..' in value['profile']:
        raise ValueError('Invalid update profile')
    if not isinstance(value['session_id'], str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}', value['session_id']):
        raise ValueError('Invalid update conversation')
    if not isinstance(value['target'], str) or len(value['target']) > 32:
        raise ValueError('Invalid update version')
    version(value['target'])
    if type(value['notify']) is not bool or type(value['created']) not in (int, float) or not time.time() - 86400 <= value['created'] <= time.time() + 300:
        raise ValueError('Invalid or expired update request')
    return value


def decode(receipt):
    if not isinstance(receipt, str) or len(receipt) > 2048 or not re.fullmatch(r'[A-Za-z0-9_-]+', receipt):
        raise ValueError('Invalid update receipt')
    return validate(json.loads(base64.urlsafe_b64decode(receipt + '=' * (-len(receipt) % 4))))


def register(state, value, *, device_id=None):
    value = validate(value)
    if device_id is not None and device_id != value['device_id']:
        raise PermissionError('An update receipt belongs to another phone')
    device = state.device(value['device_id'])
    if not device or not device['approved']:
        raise PermissionError('The requesting phone is no longer paired')
    initialize(state)
    with state.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        old = db.execute('SELECT * FROM update_requests WHERE id=?', (value['id'],)).fetchone()
        if old:
            if any(old[key] != value[key] for key in ('device_id', 'profile', 'session_id', 'target', 'notify', 'created')):
                raise ValueError('An update receipt cannot be changed')
        else:
            active = db.execute("SELECT id FROM update_requests WHERE device_id=? AND status IN ('queued','running') AND created>?",
                                (value['device_id'], time.time() - 86400)).fetchone()
            if active:
                raise ValueError('An update is already requested. Open its conversation to continue.')
            db.execute("INSERT INTO update_requests VALUES (?,?,?,?,?,?,?,'queued',NULL,NULL,NULL)",
                       tuple(value[key] for key in ('id', 'device_id', 'profile', 'session_id', 'target', 'notify', 'created')))
    return status(state, value['device_id'], value['id'])


def status(state, device_id, request_id):
    initialize(state)
    with state.connect() as db:
        row = db.execute('SELECT id,profile,session_id,target,status,installed,error FROM update_requests WHERE id=? AND device_id=?',
                         (request_id, device_id)).fetchone()
    if not row:
        raise LookupError('Update request not found')
    value = dict(row)
    value['restart_required'] = value['status'] == 'completed'
    return value


def complete(state, request_id, installed):
    """Called only after installer health verification; event and receipt commit together."""
    initialize(state)
    with state.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute("SELECT * FROM update_requests WHERE id=? AND status IN ('queued','running')", (request_id,)).fetchone()
        if not row or version(installed) < version(row['target']):
            return False
        db.execute("UPDATE update_requests SET status='completed',installed=?,error=NULL,finished=? WHERE id=?", (installed, time.time(), request_id))
        device = db.execute('SELECT approved,revoked,push_enabled FROM devices WHERE id=?', (row['device_id'],)).fetchone()
        if row['notify'] and device and device['approved'] and not device['revoked'] and device['push_enabled'] and state.get('push_enabled', False):
            reference = token()
            db.execute("INSERT OR IGNORE INTO notifications(reference,device_id,profile,session_id,kind,event_key,created) VALUES(?,?,?,?,'update_completed',?,?)",
                       (reference, row['device_id'], row['profile'], row['session_id'], 'companion-update/' + request_id, time.time()))
            db.execute('INSERT OR IGNORE INTO notification_details VALUES (?,?,?)', (reference, 'Hermes Jr.', ''))
        return True


def run_tracked(state, release, receipt):
    import fcntl
    # A retried model tool call must not mark the original install as failed.
    with (state.directory / 'guided-update.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('A guided update is already running; wait for its result') from None
        return _run_tracked(state, release, receipt)


def _run_tracked(state, release, receipt):
    from .installer import install, verify_connection
    from .release_signature import verify
    verify(release)
    value = decode(receipt)
    if version(release['latest']) < version(value['target']):
        raise ValueError('The requested update is not published yet')
    registered = register(state, value)
    if registered['status'] == 'completed':
        return
    with state.connect() as db:
        db.execute("UPDATE update_requests SET status='running',error=NULL WHERE id=?", (value['id'],))
    try:
        if version(installed_version()) < version(release['latest']):
            install(state, release, receipt_id=value['id'])
        verify_connection(state)
        complete(state, value['id'], installed_version())
    except BaseException:
        with state.connect() as db:
            db.execute("UPDATE update_requests SET status='failed',error='The update did not complete. Open its conversation for details.' WHERE id=? AND status!='completed'", (value['id'],))
        raise


async def recover(state):
    """A stopped bridge can finish notification delivery after a verified commit."""
    from .installer import verify_connection
    from .recovery import Snapshot
    initialize(state)
    try:
        pointer = json.loads((state.directory / 'last-update.json').read_text())
        journal = Snapshot(pointer['backup']).journal
        request_id = journal.get('update_request')
        if journal['phase'] != 'complete' or not request_id or installed_version() != journal['target_version']:
            return
        with state.connect() as db:
            pending = db.execute("SELECT 1 FROM update_requests WHERE id=? AND status IN ('queued','running')", (request_id,)).fetchone()
        if pending:
            await asyncio.to_thread(verify_connection, state)
            complete(state, request_id, installed_version())
    except (OSError, KeyError, ValueError):
        return  # Never turn an unverified, failed, or rolled-back install into success.


async def watch(state):
    while True:
        try:
            await recover(state)
        except Exception:
            # A transient health/database failure must not kill future recovery.
            pass
        await asyncio.sleep(30)
