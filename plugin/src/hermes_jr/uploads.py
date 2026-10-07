"""Bounded, device-scoped document uploads; no caller-selected host paths."""
import base64
import binascii
import hashlib
import os
import re
import uuid
import time
from .storage import file_lock, require_device, reserve_upload, disk_space, limits

MAX_BYTES = 25 * 1024 * 1024
CHUNK_BYTES = 512 * 1024


def upload(state, device_id, body):
    upload_id = body.get("upload_id")
    if not isinstance(upload_id, str):
        raise ValueError("Invalid upload ID")
    upload_id = str(uuid.UUID(upload_id))
    filename = body.get("filename")
    offset, total = body.get("offset"), body.get("total")
    if not isinstance(filename, str) or not filename or len(filename.encode()) > 200:
        raise ValueError("Invalid filename")
    if filename in {".", ".."} or re.search(r'[/\\\x00-\x1f\x7f]', filename):
        raise ValueError("Invalid filename")
    if type(offset) is not int or type(total) is not int or not 0 < total <= MAX_BYTES or not 0 <= offset < total:
        raise ValueError("Invalid upload size")
    encoded = body.get("content_base64")
    if not isinstance(encoded, str) or len(encoded) > 4 * ((CHUNK_BYTES + 2) // 3):
        raise ValueError("Invalid chunk")
    try:
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("Invalid chunk") from None
    if not 0 < len(data) <= CHUNK_BYTES or offset + len(data) > total:
        raise ValueError("Invalid chunk size")
    owner = hashlib.sha256(device_id.encode()).hexdigest()
    directory = state.directory / "uploads" / owner / upload_id
    target = directory / filename
    relative = str(target.relative_to(state.directory))
    with file_lock(state):
        # Commit the reservation first. A crash leaves an accounted journal entry.
        with state.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            require_device(db, device_id)
            entry = db.execute('SELECT * FROM upload_storage WHERE path=?', (relative,)).fetchone()
            if entry:
                if entry['device_id'] != device_id or entry['total'] != total:
                    raise ValueError('Upload does not match an unfinished file')
            elif offset == 0:
                reserve_upload(state, db, device_id, relative, total)
            else:
                raise ValueError('Upload does not match an unfinished file')
        with state.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            require_device(db, device_id)  # Revocation cannot interleave with the write.
            disk_space(state, len(data), limits(db))
            if directory.is_symlink() or directory.parent.is_symlink() or directory.parent.parent.is_symlink():
                raise ValueError('Upload directory is unavailable')
            if offset == 0:
                directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            if entry and entry['complete'] and not target.exists():
                raise ValueError('Completed upload is unavailable')
            flags = os.O_RDWR | os.O_NOFOLLOW | (os.O_CREAT | os.O_EXCL if offset == 0 and not target.exists() else 0)
            try:
                fd = os.open(target, flags, 0o600)
            except (FileExistsError, FileNotFoundError):
                raise ValueError('Upload does not match an unfinished file') from None
            with os.fdopen(fd, 'r+b') as output:
                output.seek(0, os.SEEK_END)
                size = output.tell()
                if size < offset or size > total:
                    raise ValueError('Upload offset mismatch')
                # An exact chunk retry can repair a file write whose acknowledgement was lost.
                overlap = min(size - offset, len(data))
                output.seek(offset)
                if output.read(overlap) != data[:overlap]:
                    raise ValueError('Upload retry does not match stored bytes')
                output.seek(size)
                output.write(data[overlap:])
                output.flush()
                os.fsync(output.fileno())
                next_offset = max(size, offset + len(data))
            complete = next_offset == total
            db.execute('UPDATE upload_storage SET complete=?,touched=? WHERE path=?',
                       (int(complete), time.time(), relative))
            if complete:
                db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',
                           ('upload-complete/' + owner + '/' + upload_id + '/' + filename,
                            '{"size":' + str(total) + '}'))
    return {"offset": next_offset, "complete": complete, "path": str(target) if complete else None}
