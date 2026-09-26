"""Hermes Jr. HPKE Auth framing. See Protocol/HPKE.md for the wire contract.

Instances are single-connection, ordered-use objects. Never persist or copy them.
The host caller MUST authorize device_public_key before calling finish().
"""
from __future__ import annotations

import os
import struct

from pyhpke import AEADId, CipherSuite, KDFId, KEMId
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, PublicFormat, NoEncryption

MAX_RECORD = 65_536
MAX_MESSAGE = 40 * 1024 * 1024
MAX_PLAINTEXT = 48 * 1024
CHUNK_SIZE = MAX_PLAINTEXT - 16
MAX_SEQUENCE = (1 << 32) - 1
PROTOCOL = b"hermes-jr/hpke/v1\x00"
RECORD = b"hermes-jr/record/v1\x00"
HOST_PROOF = b"hermes-jr/host-ready/v1"
READY_PROOF = b"hermes-jr/authorized/v1\x00"
HOST_PROOF_TYPE, AUTH_TYPE, READY_TYPE, DATA_TYPE = 16, 17, 18, 32


class SecureChannelError(ValueError):
    """Invalid, unauthenticated, out-of-order, or oversized protocol data."""


def generate_private_key() -> bytes:
    return X25519PrivateKey.generate().private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())


def public_key(private_key: bytes) -> bytes:
    return X25519PrivateKey.from_private_bytes(private_key).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def _suite():
    return CipherSuite.new(KEMId.DHKEM_X25519_HKDF_SHA256, KDFId.HKDF_SHA256, AEADId.CHACHA20_POLY1305)


class _Records:
    def __init__(self, context, transcript: bytes, direction: bytes, sequence: int = 0):
        self.context = context
        self.aad_prefix = RECORD + transcript + direction
        self.sequence = sequence

    def invalidate(self):
        self.context = None

    def seal(self, kind: int, plaintext: bytes) -> bytes:
        try:
            if self.context is None or self.sequence > MAX_SEQUENCE or len(plaintext) > MAX_PLAINTEXT:
                raise SecureChannelError("Encrypted connection is closed or its message limit was exceeded")
            header = struct.pack(">BQ", kind, self.sequence)
            ciphertext = self.context.seal(plaintext, self.aad_prefix + header)
            self.sequence += 1
            return header + ciphertext
        except Exception as exc:
            self.invalidate()
            raise SecureChannelError("Could not encrypt the connection record") from exc

    def open(self, kind: int, record: bytes) -> bytes:
        try:
            if self.context is None or self.sequence > MAX_SEQUENCE or not 25 <= len(record) <= MAX_RECORD:
                raise SecureChannelError("Invalid encrypted record size or closed connection")
            if struct.unpack(">BQ", record[:9]) != (kind, self.sequence):
                raise SecureChannelError("Unexpected encrypted record or sequence")
            plaintext = self.context.open(record[9:], self.aad_prefix + record[:9])
            if len(plaintext) > MAX_PLAINTEXT:
                raise SecureChannelError("Encrypted record plaintext is too large")
            self.sequence += 1
            return plaintext
        except Exception as exc:
            self.invalidate()
            raise SecureChannelError("Encrypted connection authentication failed") from exc


class SecureChannel:
    """Authenticated ordered channel. Caller serializes complete seal/send operations."""

    def __init__(self, sender: _Records, recipient: _Records):
        self._sender, self._recipient = sender, recipient
        self._send_id = self._receive_id = 0
        self._buffer = bytearray()
        self._total = None
        self._valid = True

    def invalidate(self):
        self._valid = False
        self._sender.invalidate()
        self._recipient.invalidate()
        self._buffer.clear()
        self._total = None

    def seal(self, message: bytes) -> list[bytes]:
        try:
            if not self._valid or len(message) > MAX_MESSAGE or self._send_id > MAX_SEQUENCE:
                raise SecureChannelError("Connection closed or message too large")
            frames = []
            for offset in range(0, max(1, len(message)), CHUNK_SIZE):
                plaintext = struct.pack(">QII", self._send_id, len(message), offset) + message[offset:offset + CHUNK_SIZE]
                frames.append(self._sender.seal(DATA_TYPE, plaintext))
            self._send_id += 1
            return frames
        except Exception:
            self.invalidate()
            raise

    def receive(self, record: bytes) -> bytes | None:
        try:
            if not self._valid:
                raise SecureChannelError("Connection closed")
            plaintext = self._recipient.open(DATA_TYPE, record)
            if len(plaintext) < 16:
                raise SecureChannelError("Missing encrypted message header")
            message_id, total, offset = struct.unpack(">QII", plaintext[:16])
            chunk = plaintext[16:]
            if (message_id != self._receive_id or total > MAX_MESSAGE or offset != len(self._buffer)
                    or offset + len(chunk) > total or (total > 0 and not chunk)):
                raise SecureChannelError("Invalid encrypted message fragment")
            if self._total is None:
                self._total = total
            if self._total != total:
                raise SecureChannelError("Encrypted message size changed")
            self._buffer.extend(chunk)
            if len(self._buffer) == total:
                result = bytes(self._buffer)
                self._buffer.clear()
                self._total = None
                self._receive_id += 1
                return result
            return None
        except Exception:
            self.invalidate()
            raise


class HostHandshake:
    """Host handshake; finish() is an explicit authorization boundary."""

    def __init__(self, host_private_key: bytes):
        self._private = host_private_key
        self._public = public_key(host_private_key)
        self._state = "new"
        self.device_public_key: bytes | None = None
        self._sender = self._recipient = None

    def invalidate(self):
        self._state = "closed"
        self._private = b""
        if self._sender is not None:
            self._sender.invalidate()
        if self._recipient is not None:
            self._recipient.invalidate()

    def receive_hello(self, hello: bytes) -> bytes:
        try:
            if self._state != "new" or len(hello) != 65 or hello[0] != 1:
                raise SecureChannelError("Invalid client hello")
            self.device_public_key = hello[1:33]
            host_nonce = os.urandom(32)
            self._transcript = PROTOCOL + self._public + self.device_public_key + hello[33:] + host_nonce
            suite = _suite()
            self._host_enc, context = suite.create_sender_context(
                suite.kem.deserialize_public_key(self.device_public_key),
                info=self._transcript + b"\x00h2c",
                sks=suite.kem.deserialize_private_key(self._private),
            )
            self._sender = _Records(context, self._transcript, b"h2c")
            proof = self._sender.seal(HOST_PROOF_TYPE, HOST_PROOF)
            self._state = "challenge"
            return bytes([2]) + host_nonce + self._host_enc + proof
        except Exception:
            self.invalidate()
            raise

    def receive_auth(self, record: bytes) -> bytes:
        try:
            if self._state != "challenge" or not 58 <= len(record) <= MAX_RECORD or record[0] != 3:
                raise SecureChannelError("Invalid client authentication")
            self._client_enc = record[1:33]
            suite = _suite()
            context = suite.create_recipient_context(
                self._client_enc, suite.kem.deserialize_private_key(self._private),
                info=self._transcript + b"\x00c2h" + self._host_enc,
                pks=suite.kem.deserialize_public_key(self.device_public_key),
            )
            self._recipient = _Records(context, self._transcript, b"c2h")
            authentication = self._recipient.open(AUTH_TYPE, record[33:])
            self._private = b""
            self._state = "authorization"
            return authentication
        except Exception:
            self.invalidate()
            raise

    def finish(self) -> tuple[bytes, SecureChannel]:
        """Call only after approving device_public_key using trusted host state."""
        try:
            if self._state != "authorization":
                raise SecureChannelError("Client has not authenticated")
            ready = self._sender.seal(READY_TYPE, READY_PROOF + self._client_enc)
            channel = SecureChannel(self._sender, self._recipient)
            self._state = "finished"
            self._sender = self._recipient = None
            return ready, channel
        except Exception:
            self.invalidate()
            raise
