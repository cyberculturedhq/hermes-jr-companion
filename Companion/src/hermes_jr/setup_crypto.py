"""Numeric comparison bootstrap. The full construction is in Protocol/SETUP.md.

Uses the ZRTP/Matrix SAS commit-before-reveal pattern with cryptography primitives.
This Hermes-specific protocol integration is not independently audited.
"""
from __future__ import annotations
import base64
import hashlib
import hmac
import json
import re
import time
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from .secure_channel import _suite, public_key

DOMAIN = b"hermes-jr/setup-sas/v1\x00"


def encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def decode(value: str, length: int | None = None) -> bytes:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value) or len(value) > 8192:
        raise ValueError("Invalid setup encoding")
    raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    if encode(raw) != value or (length is not None and len(raw) != length):
        raise ValueError("Invalid setup value")
    return raw


def verify_ticket(ticket: str, verification_key: str, service: str, now=None) -> dict:
    try:
        prefix, payload, signature = ticket.split(".")
        if prefix != "HJ1" or len(ticket) > 2048:
            raise ValueError()
        raw = decode(payload)
        Ed25519PublicKey.from_public_bytes(decode(verification_key, 32)).verify(decode(signature, 64), b"HJ1." + payload.encode())
        v, intent, phone_key, issued, expires, origin = json.loads(raw)
        now = time.time() if now is None else now
        if (v != 1 or type(issued) is not int or type(expires) is not int or issued > now + 30
                or not now < expires <= issued + 1200 or origin != service):
            raise ValueError()
        decode(intent, 32)
        decode(phone_key, 32)
        return dict(intent_id=intent, phone_public_key=phone_key, expires_at=expires, service=origin)
    except Exception as exc:
        raise ValueError("Invalid, expired, or wrong-service setup ticket") from exc


def context(ticket: str, claim: dict) -> bytes:
    fields = [ticket, claim["claim_id"], claim["installation_id"], claim["host_public_key"], claim["host_name"]]
    if any(not isinstance(x, str) or "\x00" in x for x in fields):
        raise ValueError("Invalid setup context")
    return DOMAIN + "\x00".join(fields).encode("utf-8")


def commitment(ctx: bytes, host_ephemeral: bytes) -> str:
    return encode(hashlib.sha256(DOMAIN + b"commit\x00" + ctx + host_ephemeral).digest())


def transcript(ctx: bytes, host_ephemeral: bytes, phone_ephemeral: bytes) -> bytes:
    if len(host_ephemeral) != 32 or len(phone_ephemeral) != 32:
        raise ValueError("Invalid ephemeral key")
    return hashlib.sha256(ctx + host_ephemeral + phone_ephemeral).digest()


def derive(private: bytes, peer: bytes, transcript_hash: bytes, label: bytes, count=32) -> bytes:
    shared = X25519PrivateKey.from_private_bytes(private).exchange(X25519PublicKey.from_public_bytes(peer))
    return HKDF(algorithm=hashes.SHA256(), length=count, salt=None,
                info=DOMAIN + label + b"\x00" + transcript_hash).derive(shared)


def comparison_code(private: bytes, peer: bytes, transcript_hash: bytes) -> str:
    # Matrix's decimal SAS representation: 3 x 13 bits, each rendered as 1000..9191.
    b = derive(private, peer, transcript_hash, b"sas", 5)
    values = [(b[0] << 5) | (b[1] >> 3), ((b[1] & 7) << 10) | (b[2] << 2) | (b[3] >> 6),
              ((b[3] & 63) << 7) | (b[4] >> 1)]
    return " ".join(str(x + 1000) for x in values)


def confirmation(private: bytes, peer: bytes, transcript_hash: bytes) -> str:
    key = derive(private, peer, transcript_hash, b"confirm")
    return encode(hmac.digest(key, DOMAIN + b"phone-confirm\x00" + transcript_hash, "sha256"))


def encrypt_enrollment(host_private: bytes, phone_public: bytes, transcript_hash: bytes, payload: dict) -> str:
    suite = _suite()
    enc, sender = suite.create_sender_context(suite.kem.deserialize_public_key(phone_public),
        DOMAIN + b"enrollment\x00" + transcript_hash, sks=suite.kem.deserialize_private_key(host_private))
    # Even a malicious SAS relay cannot decrypt this: recipient is the ticket's phone identity.
    return encode(enc + sender.seal(json.dumps(payload, separators=(",", ":")).encode(), transcript_hash))
