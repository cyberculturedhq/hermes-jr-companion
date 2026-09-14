"""Notification v1: per-phone ChaCha20-Poly1305, provisioned over authenticated transport.

Keys never go to the delivery service. This format is independent of relay stream keys.
See Protocol/NOTIFICATIONS.md. Each payload uses a fresh random 96-bit nonce.
"""
import base64
import json
import os
import re
import time
import unicodedata
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

PADDED_SIZE = 1024
PREFIX = b"hermes-jr/notification/v1\x00"


def encode(value):
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def decode(value, size):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ValueError("Invalid notification key")
    raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    if len(raw) != size or encode(raw) != value:
        raise ValueError("Invalid notification key")
    return raw


def validate_key(value):
    if not isinstance(value, dict) or set(value) != {"key_id", "secret"}:
        raise ValueError("Invalid notification key")
    decode(value["key_id"], 16)
    decode(value["secret"], 32)
    return value


def clean(value, limit):
    if not isinstance(value, str):
        return ""
    value = " ".join("".join(c for c in value if unicodedata.category(c) not in {"Cc", "Cf"}).split())
    return value.encode()[:limit].decode("utf-8", errors="ignore")


def encrypt(key, event, details):
    validate_key(key)
    reference = event["reference"]
    decode(reference, 32)
    if event["kind"] not in {"completed", "error", "approval", "clarification"}:
        raise ValueError("Unknown notification event")
    content = {"kind": event["kind"], "profile": clean(details.get("profile_name") or event["profile"], 120) or "Hermes",
               "conversation": clean(details.get("session_title"), 240), "expires": int(time.time()) + 3600}
    raw = json.dumps(content, ensure_ascii=False, separators=(",", ":")).encode()
    if len(raw) > PADDED_SIZE - 2:
        raise ValueError("Notification details exceed the limit")
    padded = len(raw).to_bytes(2, "big") + raw + bytes(PADDED_SIZE - 2 - len(raw))
    nonce = os.urandom(12)
    aad = PREFIX + key["key_id"].encode() + b"\x00" + reference.encode()
    ciphertext = ChaCha20Poly1305(decode(key["secret"], 32)).encrypt(nonce, padded, aad)
    return {"v": 1, "kid": key["key_id"], "data": encode(nonce + ciphertext)}
