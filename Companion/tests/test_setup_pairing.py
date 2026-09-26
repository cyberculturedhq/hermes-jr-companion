import base64
import hashlib
import hmac
import json
import tempfile
import time
import unittest
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from hermes_jr import setup_crypto as c
from hermes_jr.secure_channel import generate_private_key, public_key, _suite
from hermes_jr.state import State


class SetupPairingTests(unittest.TestCase):
    def setUp(self):
        self.phone = generate_private_key()
        self.host = generate_private_key()
        self.phone_ephemeral = generate_private_key()
        self.host_ephemeral = generate_private_key()
        self.claim = dict(claim_id="e7f734fb-a2eb-4fb5-9b92-a7eaa545eade",
            installation_id="e5a5a0d5-cbc8-4715-bf22-f2c0fd29b02e", host_public_key=c.encode(public_key(self.host)), host_name="Hermes Mac")
        self.context = c.context("HJ1.fixture.ticket", self.claim)
        self.transcript = c.transcript(self.context, public_key(self.host_ephemeral), public_key(self.phone_ephemeral))

    def test_codes_match_and_bind_both_identities_and_attempt(self):
        expected = c.comparison_code(self.host_ephemeral, public_key(self.phone_ephemeral), self.transcript)
        self.assertEqual(expected, c.comparison_code(self.phone_ephemeral, public_key(self.host_ephemeral), self.transcript))
        self.assertRegex(expected, r"\d{4} \d{4} \d{4}")
        for key in ["claim_id", "installation_id", "host_public_key", "host_name"]:
            modified = {**self.claim, key: "changed"}
            other = c.transcript(c.context("HJ1.fixture.ticket", modified), public_key(self.host_ephemeral), public_key(self.phone_ephemeral))
            self.assertNotEqual(c.confirmation(self.host_ephemeral, public_key(self.phone_ephemeral), other),
                                c.confirmation(self.phone_ephemeral, public_key(self.host_ephemeral), self.transcript))

    def test_commitment_changes_with_host_key_or_setup_context(self):
        expected = c.commitment(self.context, public_key(self.host_ephemeral))
        self.assertNotEqual(expected, c.commitment(self.context, public_key(generate_private_key())))
        self.assertNotEqual(expected, c.commitment(self.context + b"other", public_key(self.host_ephemeral)))

    def test_confirmation_is_session_specific_and_requires_ephemeral_private_key(self):
        phone = c.confirmation(self.phone_ephemeral, public_key(self.host_ephemeral), self.transcript)
        self.assertTrue(hmac.compare_digest(phone, c.confirmation(self.host_ephemeral, public_key(self.phone_ephemeral), self.transcript)))
        self.assertNotEqual(phone, c.confirmation(generate_private_key(), public_key(self.phone_ephemeral), self.transcript))
        with self.assertRaises(ValueError):
            c.comparison_code(self.phone_ephemeral, bytes(32), self.transcript)

    def test_enrollment_is_only_decryptable_by_ticket_phone_and_authenticates_host(self):
        payload = {"pairing_secret": "fixture-secret", "host_public_key": self.claim["host_public_key"]}
        encrypted = c.decode(c.encrypt_enrollment(self.host, public_key(self.phone), self.transcript, payload))
        suite = _suite()
        def decrypt(phone, host, transcript):
            recipient = suite.create_recipient_context(encrypted[:32], suite.kem.deserialize_private_key(phone),
                info=c.DOMAIN + b"enrollment\x00" + transcript, pks=suite.kem.deserialize_public_key(host))
            return json.loads(recipient.open(encrypted[32:], transcript))
        self.assertEqual(payload, decrypt(self.phone, public_key(self.host), self.transcript))
        for phone, host, transcript in [(generate_private_key(), public_key(self.host), self.transcript),
                (self.phone, public_key(generate_private_key()), self.transcript), (self.phone, public_key(self.host), bytes(32))]:
            with self.assertRaises(Exception): decrypt(phone, host, transcript)

    def test_ticket_verifies_exact_service_phone_expiry_and_signature(self):
        signer = Ed25519PrivateKey.generate()
        key = c.encode(signer.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))
        now = int(time.time())
        payload = c.encode(json.dumps([1, c.encode(bytes(range(32))), c.encode(public_key(self.phone)), now, now+1200, "https://relay.test"]).encode())
        unsigned = "HJ1." + payload
        ticket = unsigned + "." + c.encode(signer.sign(unsigned.encode()))
        self.assertEqual(c.verify_ticket(ticket, key, "https://relay.test")["phone_public_key"], c.encode(public_key(self.phone)))
        for value, origin, clock in [(ticket, "https://attacker.test", now), (ticket, "https://relay.test", now+1201),
                (ticket[:-10] + "a" * 10, "https://relay.test", now)]:
            with self.assertRaises(ValueError): c.verify_ticket(value, key, origin, now=clock)

    def test_stolen_invitation_secret_does_not_authorize_a_different_phone(self):
        with tempfile.TemporaryDirectory() as path:
            state = State(Path(path))
            state.add_device("device", "iPhone", "routing", secret="secret", expires=time.time()+300,
                             automatic=True, expected_key=public_key(self.phone))
            with self.assertRaises(PermissionError):
                state.accept_pair("device", public_key(generate_private_key()), "secret", "Attacker")
            self.assertFalse(state.device("device")["approved"])
            self.assertTrue(state.accept_pair("device", public_key(self.phone), "secret", "iPhone"))
            self.assertIsNone(state.device("device")["pair_digest"])
            with self.assertRaises(PermissionError):
                state.accept_pair("device", public_key(generate_private_key()), "secret", "Attacker")

    def test_sweep_removes_interrupted_setup_secrets_and_keeps_replay_tombstone(self):
        with tempfile.TemporaryDirectory() as path:
            state = State(Path(path))
            state.set("setup/expired", dict(private="secret", expires_at=time.time()-1))
            state.set("setup/abandoned", dict(private="secret", expires_at=time.time()+200, deadline=time.time()-1))
            state.expire_pending()
            self.assertIsNone(state.get("setup/expired"))
            self.assertTrue(state.get("setup/abandoned")["terminal"])
            self.assertNotIn("private", state.get("setup/abandoned"))


if __name__ == "__main__": unittest.main()
