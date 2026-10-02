"""Device-bound replies to the canonical Bot Chat's existing writer.

Reserve the exact owner before mailbox admission. Repeated requests use the
same durable delivery ID. A lost acknowledgement never selects another writer.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import stat
import uuid


def runtime(profile):
    from hermes_cli.profiles import resolve_profile_env
    from hermes_state import SessionDB
    from tools import bot_live_delivery as delivery
    return Path(resolve_profile_env(profile)).resolve(), SessionDB, delivery


def supported():
    try:
        from hermes_cli.profiles import resolve_profile_env
        from hermes_state import SessionDB
        from tools.bot_live_delivery import (find_canonical_owner, deliver_to_live_owner,
                                            read_delivery_result, cancel_queued_delivery, owner_holds_delivery)
        return 1
    except ImportError:
        return 0


def canonical(home, database, session_id):
    db = database(db_path=home / 'state.db', read_only=True)
    try:
        root = db.get_session_by_title('Bot Chat')
        tip = db.get_compression_tip(root['id']) if root else None
        if not tip or not db.get_session(session_id) or db.get_compression_tip(session_id) != tip:
            raise ValueError('This conversation is not the profile\'s Bot Chat. Refresh Bots and try again.')
        return tip
    finally:
        db.close()


def attachments(state, device_id, values):
    if not isinstance(values, list) or len(values) > 20:
        raise ValueError('Invalid bot attachments')
    root = (state.directory / 'uploads' / hashlib.sha256(device_id.encode()).hexdigest()).resolve()
    paths = []
    for value in values:
        if not isinstance(value, dict) or set(value) != {'upload_id', 'filename'}:
            raise ValueError('Invalid bot attachment')
        if not isinstance(value['upload_id'], str):
            raise ValueError('Invalid upload ID')
        upload_id = str(uuid.UUID(value['upload_id']))
        filename = value['filename']
        if (not isinstance(filename, str) or not filename or len(filename.encode()) > 200
                or filename in {'.', '..'} or re.search(r'[/\\\x00-\x1f\x7f]', filename)):
            raise ValueError('Invalid attachment filename')
        target = root / upload_id / filename
        resolved = target.resolve()
        if not resolved.is_relative_to(root) or target.is_symlink():
            raise ValueError('Attachment is unavailable')
        try:
            info = target.stat()
        except FileNotFoundError:
            raise ValueError('Attachment is unavailable') from None
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 25 * 1024 * 1024:
            raise ValueError('Attachment is unavailable')
        # Upload completion is recorded by the uploader. Partial files cannot enter a turn.
        complete = state.get('upload-complete/' + hashlib.sha256(device_id.encode()).hexdigest() + '/' + upload_id + '/' + filename)
        if not isinstance(complete, dict) or complete.get('size') != info.st_size:
            raise ValueError('Attachment upload is incomplete')
        paths.append(str(resolved))
    return paths


def key(device_id, request_id):
    return 'bot-reply/' + device_id + '/' + str(uuid.UUID(request_id))


def submit(state, device_id, request_id, profile, session_id, body):
    if set(body) - {'profile', 'session_id', 'text', 'attachments'}:
        raise ValueError('Invalid bot reply fields')
    text = body.get('text')
    values = body.get('attachments', [])
    if not isinstance(text, str) or len(text) > 200_000 or not (text.strip() or values):
        raise ValueError('Enter a bot message')
    normalized = {'profile': profile, 'session_id': session_id, 'text': text, 'attachments': values}
    fingerprint = hashlib.sha256(json.dumps(normalized, sort_keys=True).encode()).hexdigest()
    record_key = key(device_id, request_id)
    # The mapping commits before admission. A crash between these steps can
    # only retry the same pinned owner and mailbox ID.
    with state.connect() as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute('SELECT value FROM settings WHERE key=?', (record_key,)).fetchone()
        if row:
            record = json.loads(row[0])
            if record['fingerprint'] != fingerprint:
                raise ValueError('This reply ID belongs to a different message')
        else:
            home, database, delivery = runtime(profile)
            tip = canonical(home, database, session_id)
            paths = attachments(state, device_id, values)
            owner = delivery.find_canonical_owner(home)
            if owner:
                meta = owner.get('metadata') or {}
                if meta.get('bot_live_delivery_consumer') is not True or not meta.get('live_session_id'):
                    return {'route': 'unavailable', 'message': 'Update Hermes on your computer. This Bot Chat owner cannot receive iPhone replies.'}
                pinned = {name: owner[name] for name in ('profile_home', 'session_id', 'lease_id')}
                pinned['live_session_id'] = meta['live_session_id']
            else:
                pinned = None
            message = '\n'.join([text] + ['[User attached file: ' + path + ']' for path in paths]).strip()
            record = dict(fingerprint=fingerprint, home=str(home), profile=profile, session_id=tip,
                          owner=pinned, route='owner' if pinned else 'session', message=message, paths=paths,
                          delivery_id=hashlib.sha256(record_key.encode()).hexdigest())
            db.execute('INSERT INTO settings VALUES (?,?)', (record_key, json.dumps(record)))
    if record['route'] == 'owner':
        _, _, delivery = runtime(record['profile'])
        # No bot attribution: this is the person's message, not an agent DM.
        delivery.deliver_to_live_owner(record['home'], record['owner'], record['message'],
                                       delivery_id=record['delivery_id'], author=None)
    return result(state, device_id, request_id)


def result(state, device_id, request_id, cancel=False):
    record = state.get(key(device_id, request_id))
    if record is None:
        raise LookupError('Bot reply not found')
    public = {'route': record['route'], 'session_id': record['session_id'], 'paths': record['paths']}
    if record['route'] == 'session':
        public['text'] = record['message']
        return public
    _, _, delivery = runtime(record['profile'])
    receipt = delivery.read_delivery_result(record['home'], record['delivery_id'])
    if receipt is None:
        return {**public, 'status': 'preparing'}
    if receipt['status'] == 'queued' and (cancel or not delivery.owner_holds_delivery(record['home'], receipt)):
        receipt = delivery.cancel_queued_delivery(record['home'], record['delivery_id'],
            error='Bot reply cancelled before it started.', reason='cancelled') or receipt
    status = receipt['status']
    if status == 'claimed' and not delivery.owner_holds_delivery(record['home'], receipt):
        return {**public, 'status': 'ambiguous', 'error': 'The bot stopped before it confirmed this reply. Check the conversation before sending again.'}
    # Return the current compression tip so the app loads the same conversation's newest history.
    try:
        home, database, _ = runtime(record['profile'])
        public['session_id'] = canonical(home, database, record['session_id'])
    except Exception:
        pass
    return {**public, 'status': status, 'reply': receipt.get('reply', ''), 'error': receipt.get('error', '')}
