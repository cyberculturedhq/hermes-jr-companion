"""Private durable device registry and notification outbox shared by Hermes processes."""
from __future__ import annotations
import base64
import contextlib
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import sqlite3
import time
import uuid


def token() -> str:
    return secrets.token_urlsafe(32)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def state_dir() -> Path:
    override = os.environ.get("HERMES_JR_STATE_DIR")
    if override:
        return Path(override).expanduser().resolve()
    try:
        from hermes_constants import get_default_hermes_root
        root = get_default_hermes_root()
    except ImportError:
        root = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
        if root.parent.name == "profiles":
            root = root.parent.parent
    return root / "plugin-data" / "hermes-jr"


class State:
    def __init__(self, directory: Path | None = None):
        self.directory = directory or state_dir()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.directory.chmod(0o700)
        self.path = self.directory / "companion.sqlite3"
        # Pre-create privately; do not expose the DB between sqlite creation and chmod.
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        self.path.chmod(0o600)
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, local_digest TEXT,
                    service_token TEXT, public_key TEXT, pair_digest TEXT, pair_expires REAL,
                    approved INTEGER NOT NULL DEFAULT 0, revoked INTEGER NOT NULL DEFAULT 0,
                    push_enabled INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS automatic_pairing (device_id TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS expected_pairing_keys (device_id TEXT PRIMARY KEY, public_key TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS notification_keys (
                    device_id TEXT PRIMARY KEY, key_id TEXT NOT NULL, secret TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS notification_details (
                    reference TEXT PRIMARY KEY, profile_name TEXT NOT NULL, session_title TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS remote_deletions (
                    device_id TEXT PRIMARY KEY, attempts INTEGER NOT NULL DEFAULT 0,
                    next_attempt REAL NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS follows (
                    device_id TEXT NOT NULL, profile TEXT NOT NULL, session_id TEXT NOT NULL,
                    present_until REAL NOT NULL DEFAULT 0,
                    PRIMARY KEY(device_id, profile, session_id));
                CREATE TABLE IF NOT EXISTS notifications (
                    reference TEXT PRIMARY KEY, device_id TEXT NOT NULL, profile TEXT NOT NULL,
                    session_id TEXT NOT NULL, kind TEXT NOT NULL, event_key TEXT NOT NULL,
                    created REAL NOT NULL, delivered INTEGER NOT NULL DEFAULT 0,
                    attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
                    UNIQUE(device_id, event_key));
            """)

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=0.2)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def get(self, key, default=None):
        with self.connect() as db:
            row = db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set(self, key, value):
        self.settings({key: value})

    def settings(self, values):
        with self.connect() as db:
            db.executemany("INSERT OR REPLACE INTO settings VALUES (?,?)", ((key, json.dumps(value)) for key, value in values.items()))

    def device(self, device_id):
        with self.connect() as db:
            row = db.execute("SELECT * FROM devices WHERE id=? AND revoked=0", (device_id,)).fetchone()
        return dict(row) if row else None

    def devices(self):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM devices WHERE revoked=0 ORDER BY created")]

    def add_device(self, device_id, name, service_token, *, paired=False, secret=None, expires=0, automatic=False, expected_key=None):
        local = token()
        with self.connect() as db:
            db.execute("INSERT INTO devices(id,name,local_digest,service_token,pair_digest,pair_expires,approved,created) VALUES(?,?,?,?,?,?,?,?)",
                       (device_id, name[:80], digest(local), service_token, digest(secret) if secret else None,
                        expires, int(paired), time.time()))
            if automatic:
                if not secret or paired or expires <= time.time():
                    raise ValueError("Automatic pairing requires a live one-time invitation")
                db.execute("INSERT INTO automatic_pairing(device_id) VALUES(?)", (device_id,))
            if expected_key is not None:
                if len(expected_key) != 32 or not automatic:
                    raise ValueError("Phone-bound pairing requires a 32-byte key and a live invitation")
                db.execute("INSERT INTO expected_pairing_keys VALUES(?,?)",
                           (device_id, base64.urlsafe_b64encode(expected_key).decode().rstrip("=")))
        return local

    def authenticate(self, device_id, credential):
        device = self.device(device_id)
        if not device or not device["approved"] or not credential or not device["local_digest"] or not hmac.compare_digest(device["local_digest"], digest(credential)):
            raise PermissionError("Device is not authorized")
        return device

    def accept_pair(self, device_id, key: bytes, secret: str, name: str):
        encoded = base64.urlsafe_b64encode(key).decode().rstrip("=")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM devices WHERE id=? AND revoked=0", (device_id,)).fetchone()
            if not row:
                raise PermissionError("Unknown device")
            expected = db.execute("SELECT public_key FROM expected_pairing_keys WHERE device_id=?", (device_id,)).fetchone()
            if expected and not hmac.compare_digest(expected[0], encoded):
                raise PermissionError("This setup belongs to a different phone")
            if row["public_key"]:
                if not hmac.compare_digest(row["public_key"], encoded):
                    raise PermissionError("Device key does not match")
                if not row["approved"] and row["pair_expires"] < time.time():
                    raise PermissionError("Pairing invitation has expired")
                return bool(row["approved"])
            if not row["pair_digest"] or row["pair_expires"] < time.time() or not hmac.compare_digest(row["pair_digest"], digest(secret)):
                raise PermissionError("Pairing invitation is invalid or expired")
            automatic = bool(db.execute("SELECT 1 FROM automatic_pairing WHERE device_id=?", (device_id,)).fetchone())
            db.execute("UPDATE devices SET public_key=?,name=?,pair_digest=NULL,approved=? WHERE id=?",
                       (encoded, name[:80] or "iPhone", int(automatic), device_id))
            db.execute("DELETE FROM automatic_pairing WHERE device_id=?", (device_id,))
        return automatic

    def approve(self, device_id):
        with self.connect() as db:
            changed = db.execute("UPDATE devices SET approved=1 WHERE id=? AND revoked=0 AND public_key IS NOT NULL AND pair_expires>?", (device_id, time.time())).rowcount
            if not changed:
                raise ValueError("No phone has claimed that invitation")

    @staticmethod
    def _revoke_in(db, device_id):
        changed = db.execute("UPDATE devices SET revoked=1,approved=0,service_token=NULL,local_digest=NULL,pair_digest=NULL,push_enabled=0 WHERE id=?", (device_id,)).rowcount
        db.execute("DELETE FROM follows WHERE device_id=?", (device_id,))
        db.execute("DELETE FROM automatic_pairing WHERE device_id=?", (device_id,))
        db.execute("DELETE FROM notification_keys WHERE device_id=?", (device_id,))
        db.execute("DELETE FROM notification_details WHERE reference IN (SELECT reference FROM notifications WHERE device_id=?)", (device_id,))
        db.execute("DELETE FROM notifications WHERE device_id=?", (device_id,))
        if changed:
            db.execute("INSERT OR IGNORE INTO remote_deletions(device_id) VALUES(?)", (device_id,))

    def revoke(self, device_id):
        with self.connect() as db:
            self._revoke_in(db, device_id)

    def expire_pending(self):
        with self.connect() as db:
            # Serialize expiry with owner approval; never revoke an approved device.
            db.execute("BEGIN IMMEDIATE")
            rows = db.execute("SELECT id FROM devices WHERE revoked=0 AND approved=0 AND pair_expires>0 AND pair_expires<=?", (time.time(),)).fetchall()
            for row in rows:
                self._revoke_in(db, row[0])
            # Setup keys are private, short-lived state, including after an interrupted CLI.
            for row in db.execute("SELECT key,value FROM settings WHERE key LIKE 'setup/%'").fetchall():
                value = json.loads(row["value"])
                if value.get("expires_at", 0) <= time.time():
                    db.execute("DELETE FROM settings WHERE key=?", (row["key"],))
                elif value.get("deadline", float("inf")) <= time.time():
                    db.execute("UPDATE settings SET value=? WHERE key=?", (json.dumps({"terminal": True, "expires_at": value["expires_at"]}), row["key"]))
            return len(rows)

    def pending_deletions(self):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM remote_deletions WHERE next_attempt<=? ORDER BY next_attempt LIMIT 8", (time.time(),))]

    def deleted_remotely(self, device_id):
        with self.connect() as db:
            db.execute("DELETE FROM remote_deletions WHERE device_id=?", (device_id,))

    def retry_deletion(self, device_id, attempts):
        with self.connect() as db:
            db.execute("UPDATE remote_deletions SET attempts=attempts+1,next_attempt=? WHERE device_id=?", (time.time() + min(3600, 30 * 2 ** min(attempts, 7)), device_id))

    def follow(self, device_id, profile, session_id, enabled=True):
        if not self.device(device_id):
            raise PermissionError("Unknown device")
        with self.connect() as db:
            if enabled:
                count = db.execute("SELECT COUNT(*) FROM follows WHERE device_id=?", (device_id,)).fetchone()[0]
                if count >= 1000 and not db.execute("SELECT 1 FROM follows WHERE device_id=? AND profile=? AND session_id=?", (device_id, profile, session_id)).fetchone():
                    raise ValueError("At most 1,000 followed conversations per device")
                db.execute("INSERT OR IGNORE INTO follows(device_id,profile,session_id) VALUES(?,?,?)", (device_id, profile, session_id))
            else:
                db.execute("DELETE FROM follows WHERE device_id=? AND profile=? AND session_id=?", (device_id, profile, session_id))

    def presence(self, device_id, profile, session_id, active):
        with self.connect() as db:
            db.execute("UPDATE follows SET present_until=? WHERE device_id=? AND profile=? AND session_id=?",
                       (time.time() + 45 if active else 0, device_id, profile, session_id))

    def clear_presence(self, device_id):
        with self.connect() as db:
            db.execute("UPDATE follows SET present_until=0 WHERE device_id=?", (device_id,))

    def set_push(self, device_id, enabled):
        with self.connect() as db:
            db.execute("UPDATE devices SET push_enabled=? WHERE id=? AND revoked=0", (int(enabled), device_id))

    def notification_key(self, device_id):
        with self.connect() as db:
            row = db.execute("SELECT k.key_id,k.secret FROM notification_keys k JOIN devices d ON d.id=k.device_id WHERE k.device_id=? AND d.revoked=0 AND d.approved=1", (device_id,)).fetchone()
            return dict(row) if row else None

    def set_notification_key(self, device_id, key):
        with self.connect() as db:
            if key is None:
                db.execute("DELETE FROM notification_keys WHERE device_id=?", (device_id,))
            else:
                db.execute("INSERT OR REPLACE INTO notification_keys(device_id,key_id,secret) SELECT id,?,? FROM devices WHERE id=? AND revoked=0 AND approved=1", (key["key_id"], key["secret"], device_id))

    def notification_detail(self, reference):
        with self.connect() as db:
            row = db.execute("SELECT profile_name,session_title FROM notification_details WHERE reference=?", (reference,)).fetchone()
            return dict(row) if row else {}

    def enqueue(self, profile, session_id, kind, event_key, aliases=(), session_title="", profile_name=""):
        if not self.get("push_enabled", False):
            return
        aliases = tuple(set((session_id, *aliases)))
        with self.connect() as db:
            placeholders = ",".join("?" for _ in aliases)
            rows = db.execute(f"SELECT DISTINCT f.device_id FROM follows f JOIN devices d ON d.id=f.device_id WHERE f.profile=? AND f.session_id IN ({placeholders}) AND f.present_until<? AND d.revoked=0 AND d.approved=1 AND d.push_enabled=1",
                              (profile, *aliases, time.time())).fetchall()
            for row in rows:
                db.execute("INSERT OR IGNORE INTO notifications(reference,device_id,profile,session_id,kind,event_key,created) VALUES(?,?,?,?,?,?,?)",
                           (token(), row[0], profile, session_id, kind, event_key, time.time()))
                db.execute("INSERT OR IGNORE INTO notification_details(reference,profile_name,session_title) SELECT reference,?,? FROM notifications WHERE device_id=? AND event_key=?", (profile_name or ("Hermes" if profile == "default" else profile.capitalize()), session_title, row[0], event_key))
            db.execute("DELETE FROM notification_details WHERE reference IN (SELECT reference FROM notifications WHERE created<?)", (time.time() - 7 * 86400,))
            db.execute("DELETE FROM notifications WHERE created<?", (time.time() - 7 * 86400,))

    def outbox(self):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT n.* FROM notifications n JOIN devices d ON d.id=n.device_id WHERE n.delivered=0 AND n.next_attempt<? AND n.created>? AND d.revoked=0 AND d.push_enabled=1 ORDER BY n.created LIMIT 100", (time.time(), time.time() - 7 * 86400))]

    def sent(self, reference, ok):
        with self.connect() as db:
            db.execute("UPDATE notifications SET delivered=?,attempts=attempts+1,next_attempt=? WHERE reference=?",
                       (int(ok), time.time() + 60, reference))

    def notification(self, device_id, reference):
        with self.connect() as db:
            row = db.execute("SELECT profile,session_id,kind FROM notifications WHERE reference=? AND device_id=? AND created>?", (reference, device_id, time.time() - 7 * 86400)).fetchone()
        return dict(row) if row else None
