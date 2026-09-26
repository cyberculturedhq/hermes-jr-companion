"""Bounded, device-scoped document uploads; no caller-selected host paths."""
import base64
import binascii
import hashlib
import os
import re
import uuid

MAX_BYTES = 25 * 1024 * 1024
CHUNK_BYTES = 512 * 1024


def upload(state, device_id, body):
    upload_id = str(uuid.UUID(body.get("upload_id", "")))
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
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = directory / filename
    # Exclusive creation and exact offsets prevent retries from duplicating bytes.
    flags = os.O_WRONLY | os.O_NOFOLLOW | (os.O_CREAT | os.O_EXCL if offset == 0 else 0)
    fd = os.open(target, flags, 0o600)
    with os.fdopen(fd, "r+b") as output:
        output.seek(0, os.SEEK_END)
        if output.tell() != offset:
            raise ValueError("Upload offset mismatch")
        output.write(data)
    complete = offset + len(data) == total
    return {"offset": offset + len(data), "complete": complete, "path": str(target) if complete else None}
