"""Persistent storage bounds. Completed attachments and replay records stay durable."""
import contextlib
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import time

MiB = 1024 * 1024
# One supported attachment batch needs 500 MiB. These limits permit two such batches.
DEFAULTS = dict(upload_device_bytes=1024 * MiB, upload_host_bytes=4096 * MiB,
                upload_device_count=1024, upload_host_count=4096,
                reply_device_bytes=16 * MiB, reply_host_bytes=64 * MiB,
                reply_device_count=1024, reply_host_count=4096,
                free_disk_bytes=256 * MiB)
PARTIAL_LIFETIME = 86400
FILE_OVERHEAD = 4096
RECORD_OVERHEAD = 512
_IMPORTED = set()


class StorageCapacityError(ValueError):
    def __init__(self):
        super().__init__('Companion storage limit reached. Keep this message. Check storage on the computer before you try again.')


@contextlib.contextmanager
def file_lock(state):
    fd = os.open(state.directory / 'storage.lock', os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def initialize(state):
    with file_lock(state), state.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        db.execute('''CREATE TABLE IF NOT EXISTS upload_storage (
            path TEXT PRIMARY KEY, device_id TEXT NOT NULL, total INTEGER NOT NULL,
            complete INTEGER NOT NULL DEFAULT 0, touched REAL NOT NULL)''')
        # Reconcile once per process. A rollback can write files without this journal.
        cache_key = (os.getpid(), str(state.directory))
        if cache_key in _IMPORTED and db.execute("SELECT 1 FROM settings WHERE key='storage-import-v1'").fetchone():
            return
        owners = {hashlib.sha256(row['id'].encode()).hexdigest(): row['id']
                  for row in db.execute('SELECT id FROM devices')}
        root = state.directory / 'uploads'
        # Preserve all old files. Their consumers may still reference them.
        if root.is_dir() and not root.is_symlink():
            for parent, directories, files in os.walk(root, followlinks=False):
                for name in files:
                    path = Path(parent) / name
                    relative = path.relative_to(state.directory)
                    parts = relative.parts
                    owner = owners.get(parts[1], 'legacy/' + parts[1]) if len(parts) > 1 else 'legacy'
                    info = path.lstat()
                    db.execute('INSERT OR IGNORE INTO upload_storage VALUES(?,?,?,?,?)',
                               (str(relative), owner, info.st_size, 1, time.time()))
                    # An older process can finish or enlarge an existing reservation.
                    # Preserve its completed attachment and charge all current bytes.
                    completion = 'upload-complete/' + '/'.join(parts[1:])
                    completed = bool(db.execute('SELECT 1 FROM settings WHERE key=?',
                                                (completion,)).fetchone())
                    db.execute('''UPDATE upload_storage SET complete=MAX(complete, ?, total<=?),
                                  total=MAX(total, ?), touched=MAX(touched, ?) WHERE path=?''',
                               (int(completed), info.st_size, info.st_size, info.st_mtime, str(relative)))
                # Empty or linked old directories also consume an allocation.
                for name in directories:
                    path = Path(parent) / name
                    if path.is_symlink() or not any(path.iterdir()):
                        relative = path.relative_to(state.directory)
                        owner = owners.get(relative.parts[1], 'legacy/' + relative.parts[1])
                        db.execute('INSERT OR IGNORE INTO upload_storage VALUES(?,?,?,?,?)',
                                   (str(relative), owner, 0, 1, time.time()))
        db.execute("INSERT OR IGNORE INTO settings VALUES('storage-import-v1','true')")
        _IMPORTED.add(cache_key)


def limits(db):
    row = db.execute("SELECT value FROM settings WHERE key='storage_limits'").fetchone()
    overrides = json.loads(row[0]) if row else {}
    if not isinstance(overrides, dict) or set(overrides) - DEFAULTS.keys():
        raise ValueError('Invalid companion storage limits')
    result = {**DEFAULTS, **overrides}
    if any(type(value) is not int or value <= 0 for value in result.values()):
        raise ValueError('Invalid companion storage limits')
    return result


def disk_space(state, required, policy):
    if shutil.disk_usage(state.directory).free < required + policy['free_disk_bytes']:
        raise StorageCapacityError()


def require_device(db, device_id):
    row = db.execute('SELECT approved,revoked FROM devices WHERE id=?', (device_id,)).fetchone()
    if not row or not row['approved'] or row['revoked']:
        raise PermissionError('Device is not authorized')


def reserve_upload(state, db, device_id, path, total):
    require_device(db, device_id)
    policy = limits(db)
    for owner, byte_limit, count_limit in [(device_id, policy['upload_device_bytes'], policy['upload_device_count']),
                                          (None, policy['upload_host_bytes'], policy['upload_host_count'])]:
        where, params = (' WHERE device_id=?', (owner,)) if owner else ('', ())
        used, count = db.execute('SELECT COALESCE(SUM(total + ?),0),COUNT(*) FROM upload_storage' + where,
                                 (FILE_OVERHEAD, *params)).fetchone()
        if used + total + FILE_OVERHEAD > byte_limit or count + 1 > count_limit:
            raise StorageCapacityError()
    # Include all existing unfilled reservations in the free-space check.
    reserved = db.execute('SELECT COALESCE(SUM(total + ?),0) FROM upload_storage WHERE complete=0',
                          (FILE_OVERHEAD,)).fetchone()[0]
    disk_space(state, reserved + total + FILE_OVERHEAD, policy)
    db.execute('INSERT INTO upload_storage VALUES(?,?,?,0,?)', (path, device_id, total, time.time()))


def reserve_reply(state, db, device_id, key, value):
    require_device(db, device_id)
    policy = limits(db)
    required = len(key.encode()) + len(value.encode()) + RECORD_OVERHEAD
    for prefix, byte_limit, count_limit in [('bot-reply/' + device_id + '/', policy['reply_device_bytes'], policy['reply_device_count']),
                                           ('bot-reply/', policy['reply_host_bytes'], policy['reply_host_count'])]:
        used, count = db.execute('''SELECT COALESCE(SUM(length(CAST(key AS BLOB)) +
                                    length(CAST(value AS BLOB)) + ?),0),COUNT(*)
                                    FROM settings WHERE substr(key,1,?)=?''',
                                 (RECORD_OVERHEAD, len(prefix), prefix)).fetchone()
        if used + required > byte_limit or count + 1 > count_limit:
            raise StorageCapacityError()
    disk_space(state, required * 2, policy)  # Leave room for the database journal.


def sweep(state):
    with file_lock(state), state.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        rows = db.execute('''SELECT path FROM upload_storage WHERE complete=0 AND
                           (touched<? OR device_id IN (SELECT id FROM devices WHERE revoked=1))''',
                          (time.time() - PARTIAL_LIFETIME,)).fetchall()
        for row in rows:
            path = state.directory / row['path']
            try:
                # Files come only from our journal. Do not follow a replaced parent directory.
                if path.parent.is_symlink() or path.parent.parent.is_symlink():
                    continue
                path.unlink(missing_ok=True)
                if path.parent.exists():
                    try:
                        path.parent.rmdir()
                    except OSError as error:
                        prefix = str(path.parent.relative_to(state.directory)) + '/'
                        charged = db.execute('SELECT 1 FROM upload_storage WHERE path!=? AND substr(path,1,?)=? LIMIT 1',
                                             (row['path'], len(prefix), prefix)).fetchone()
                        if error.errno != errno.ENOTEMPTY or not charged:
                            raise
            except OSError:
                continue  # Do not refund a file that could not be removed.
            db.execute('DELETE FROM upload_storage WHERE path=?', (row['path'],))
            try:
                path.parent.parent.rmdir()  # Remove an empty device directory after its last partial file.
            except OSError:
                pass
