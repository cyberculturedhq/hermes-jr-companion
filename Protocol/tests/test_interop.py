"""Execute with Companion/.venv/bin/python Protocol/tests/test_interop.py.

Compiles the real Swift client and drives it against the real Python host.
No external service or credential is used. All generated keys are test-only.
"""
import base64
import json
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Companion/src"))
from hermes_jr.secure_channel import HostHandshake, SecureChannelError, generate_private_key, public_key, _suite, MAX_MESSAGE


def b64(value):
    return base64.b64encode(value).decode()


def raw(value):
    return base64.b64decode(value)


def tamper(value):
    result = bytearray(value)
    result[-1] ^= 1
    return bytes(result)


class Client:
    executable = None

    def __init__(self):
        self.process = subprocess.Popen([self.executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

    def call(self, op, **args):
        self.process.stdin.write(json.dumps({"op": op, **args}) + "\n")
        self.process.stdin.flush()
        return json.loads(self.process.stdout.readline())

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        self.process.stdout.close()


class InteropTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="hermes-jr-crypto-")
        Client.executable = str(Path(cls.temp.name) / "interop")
        arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        subprocess.run([
            "swiftc", "-target", f"{arch}-apple-macosx14.0", "-module-cache-path", str(Path(cls.temp.name) / "cache"),
            str(ROOT / "Hermes/Services/CompanionCrypto.swift"), str(ROOT / "Protocol/tests/InteropClient.swift"),
            "-o", Client.executable,
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def new_client(self):
        client = Client()
        self.addCleanup(client.close)
        return client

    def start(self, private=None):
        client = self.new_client()
        host_private = private or generate_private_key()
        host = HostHandshake(host_private)
        response = client.call("hello", host=b64(public_key(host_private)), private=b64(generate_private_key()))
        challenge = host.receive_hello(raw(response["record"]))
        return client, host, challenge

    def session(self, private=None):
        client, host, challenge = self.start(private)
        auth = b'{"pairing_secret":"test-only","device_name":"Interop"}'
        record = raw(client.call("challenge", record=b64(challenge), authentication=b64(auth))["record"])
        self.assertEqual(host.receive_auth(record), auth)
        ready, channel = host.finish()  # Test explicitly approves its generated device.
        self.assertEqual(client.call("ready", record=b64(ready)), {"ok": True})
        return client, channel

    def test_rfc9180_auth_vectors_both_implementations(self):
        vector = json.loads((ROOT / "Protocol/fixtures/rfc9180-auth-x25519-chacha.json").read_text())
        suite = _suite()
        recipient = suite.create_recipient_context(bytes.fromhex(vector["enc"]), suite.kem.deserialize_private_key(bytes.fromhex(vector["skR"])),
                                                  info=bytes.fromhex(vector["info"]), pks=suite.kem.deserialize_public_key(bytes.fromhex(vector["pkS"])))
        expected = bytes.fromhex(vector["plaintext"])
        for entry in vector["encryptions"]:
            self.assertEqual(recipient.open(bytes.fromhex(entry["ct"]), bytes.fromhex(entry["aad"])), expected)
        client = self.new_client()
        result = client.call("rfc", private=b64(bytes.fromhex(vector["skR"])), public=b64(bytes.fromhex(vector["pkS"])),
                             enc=b64(bytes.fromhex(vector["enc"])), info=b64(bytes.fromhex(vector["info"])),
                             encryptions=[{k: b64(bytes.fromhex(v)) for k, v in item.items()} for item in vector["encryptions"]])
        self.assertEqual(result["messages"], [b64(expected)] * 3)

    def test_roundtrip_empty_unicode_and_multiple_fragments(self):
        client, host = self.session()
        for message in (b"", "Hello Hermes — 你好 🚀".encode(), bytes(range(256)) * 1500):
            records = [raw(r) for r in client.call("seal", message=b64(message))["records"]]
            self.assertTrue(all(len(r) <= 65_536 for r in records))
            self.assertEqual([m for r in records if (m := host.receive(r)) is not None], [message])
            returned = [client.call("receive", record=b64(r))["message"] for r in host.seal(message)]
            self.assertEqual([raw(m) for m in returned if m is not None], [message])

    def test_modified_challenge_and_wrong_pinned_host(self):
        client, host, challenge = self.start()
        self.assertIn("error", client.call("challenge", record=b64(tamper(challenge)), authentication=b64(b"{}")))
        client = self.new_client()
        hello = raw(client.call("hello", host=b64(public_key(generate_private_key())), private=b64(generate_private_key()))["record"])
        challenge = HostHandshake(generate_private_key()).receive_hello(hello)
        self.assertIn("error", client.call("challenge", record=b64(challenge), authentication=b64(b"{}")))

    def test_modified_client_auth_and_authorization_boundary(self):
        client, host, challenge = self.start()
        with self.assertRaises(SecureChannelError):
            host.finish()
        client, host, challenge = self.start()
        auth = raw(client.call("challenge", record=b64(challenge), authentication=b64(b"{}"))["record"])
        with self.assertRaises(SecureChannelError):
            host.receive_auth(tamper(auth))
        with self.assertRaises(SecureChannelError):
            host.receive_auth(auth)

    def test_auth_replay_new_host_challenge(self):
        key = generate_private_key()
        client, host, challenge = self.start(key)
        auth = raw(client.call("challenge", record=b64(challenge), authentication=b64(b"{}"))["record"])
        self.assertEqual(host.receive_auth(auth), b"{}")
        # Reusing the same recorded hello is insufficient against a fresh host challenge.
        other = HostHandshake(key)
        other.receive_hello(bytes([1]) + host.device_public_key + host._transcript[-64:-32])
        with self.assertRaises(SecureChannelError):
            other.receive_auth(auth)

    def test_modified_ready(self):
        client, host, challenge = self.start()
        auth = raw(client.call("challenge", record=b64(challenge), authentication=b64(b"{}"))["record"])
        host.receive_auth(auth)
        ready, _ = host.finish()
        self.assertIn("error", client.call("ready", record=b64(tamper(ready))))

    def test_replay_reorder_tamper_invalidates_both_directions(self):
        for mode in ("replay", "reorder", "tamper"):
            client, host = self.session()
            records = [raw(r) for r in client.call("seal", message=b64(b"x" * 100_000))["records"]]
            bad = records[1] if mode == "reorder" else tamper(records[0]) if mode == "tamper" else records[0]
            if mode == "replay":
                host.receive(records[0])
            with self.assertRaises(SecureChannelError):
                host.receive(bad)
            with self.assertRaises(SecureChannelError):
                host.receive(records[-1])
            client, host = self.session()
            records = host.seal(b"x" * 100_000)
            bad = records[1] if mode == "reorder" else tamper(records[0]) if mode == "tamper" else records[0]
            if mode == "replay":
                client.call("receive", record=b64(records[0]))
            self.assertIn("error", client.call("receive", record=b64(bad)))
            self.assertIn("error", client.call("receive", record=b64(records[-1])))

    def test_reconnect_rejects_old_ciphertext(self):
        key = generate_private_key()
        client, old_host = self.session(key)
        old = raw(client.call("seal", message=b64(b"old"))["records"][0])
        _, new_host = self.session(key)
        with self.assertRaises(SecureChannelError):
            new_host.receive(old)

    def test_oversized_authenticated_reassembly_rejected(self):
        client, host = self.session()
        malformed = host._sender.seal(32, struct.pack(">QII", 0, MAX_MESSAGE + 1, 0) + b"x")
        self.assertIn("error", client.call("receive", record=b64(malformed)))
        with self.assertRaises(SecureChannelError):
            host.seal(b"x" * (MAX_MESSAGE + 1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
