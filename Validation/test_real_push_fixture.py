"""No-network safeguards for the interactive real-device notification harness."""
import asyncio
import hashlib
import json
from pathlib import Path
import stat
import struct
import tempfile
import time
import unittest

from real_push_fixture import (
    Controller, ManualPushState, PROFILE, SESSION, confirmed_rejection,
    private_write, retry_confirmed_rejection, safe_receipt,
)


class ServiceStub:
    def __init__(self, response=None):
        self.response = response or {"status": "accepted"}
        self.calls = []
        self.registered = True
        self.failure = None

    async def send_push(self, event):
        self.calls.append(event)
        if self.failure:
            raise self.failure
        return self.response

    async def receipt(self, event):
        return {"status": "accepted", "stage": "apns", "apns_status": 200}

    async def is_registered(self, device_id):
        return self.registered


class RealPushFixtureTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = ManualPushState(Path(self.temp.name) / "state")
        self.state.set("push_enabled", True)
        self.state.add_device("fixture-phone", "fixture", "test-service-token", secret="test-secret", expires=time.time() + 600)
        self.phone_key = bytes(range(32))
        self.state.accept_pair("fixture-phone", self.phone_key, "test-secret", "fixture")
        self.service = ServiceStub()
        self.controller = Controller(self.state, self.service, "fixture-phone")

    def prepare(self):
        self.state.approve("fixture-phone")
        self.state.set_push("fixture-phone", True)
        self.state.follow("fixture-phone", PROFILE, SESSION)

    async def test_snapshot_omits_secrets(self):
        self.prepare()
        snapshot = json.dumps(self.controller.snapshot())
        for secret in ("test-secret", "test-service-token", "pair_digest", "public_key", "local_digest"):
            self.assertNotIn(secret, snapshot)

    async def test_no_automatic_dispatch_and_one_explicit_send_only(self):
        self.prepare()
        self.assertEqual(self.state.outbox(), [])
        await self.controller.tick()
        self.assertEqual(self.service.calls, [])
        self.controller.command({"action": "notify"})
        await self.controller.tick()
        self.controller.command({"action": "notify"})
        await self.controller.tick()
        self.assertEqual(len(self.service.calls), 1)
        self.assertEqual(self.controller.push_status, "accepted_by_apns")
        self.assertTrue(self.controller.snapshot()["outbox_delivered"])
        self.assertEqual(self.controller.snapshot()["outbox_attempts"], 1)
        self.assertIsNone(self.controller.snapshot()["notification_reference_resolved_at"])
        event = self.service.calls[0]
        self.assertEqual(self.state.notification("fixture-phone", event["reference"])["session_id"], SESSION)
        self.assertIsNotNone(self.controller.snapshot()["notification_reference_resolved_at"])

    async def test_presence_and_registration_gate_delivery(self):
        self.controller.command({"action": "notify"})
        await self.controller.tick()
        self.assertEqual(self.service.calls, [])
        self.prepare()
        self.state.presence("fixture-phone", PROFILE, SESSION, True)
        self.controller.command({"action": "notify"})
        await self.controller.tick()
        self.assertEqual(self.service.calls, [])
        self.state.clear_presence("fixture-phone")
        await self.controller.tick()
        self.assertEqual(len(self.service.calls), 1)

    async def test_pending_http_success_is_not_apns_acceptance(self):
        self.prepare()
        self.service.response = {"status": "pending", "duplicate": True}
        self.controller.command({"action": "notify", "clear_presence": True})
        await self.controller.tick()
        self.assertEqual(self.controller.push_status, "not_confirmed_by_apns")
        self.assertFalse(self.controller.snapshot()["outbox_delivered"])
        self.assertEqual(self.state.outbox(), [])

    async def test_private_files_have_no_public_read_bits(self):
        destination = Path(self.temp.name) / "private.txt"
        private_write(destination, "private fixture payload")
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        private_write(destination, "replacement")
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        self.assertEqual(destination.read_text(), "replacement")

    async def test_stop_cancels_pending_notification(self):
        self.prepare()
        self.controller.command({"action": "notify"})
        self.assertTrue(self.controller.command({"action": "stop"}))
        await self.controller.tick()
        self.assertEqual(self.service.calls, [])

    async def test_receipt_diagnostics_cannot_reflect_secret_strings(self):
        result = safe_receipt({"status": "failed", "stage": "transport", "apns_status": None,
                               "reason": "https://provider/device/secret-token", "token": "secret-token"})
        self.assertNotIn("secret-token", json.dumps(result))
        self.assertIsNone(result["reason"])
        self.assertIsNone(safe_receipt({"status": {}, "stage": [], "reason": {}})["reason"])
        self.assertFalse(confirmed_rejection({"status": "failed", "stage": "apns", "apns_status": True}))

    async def test_retry_refuses_unknown_transport_signing_pending_accepted(self):
        self.prepare()
        for receipt in (
            None, {"status": "failed"}, {"status": "pending"},
            {"status": "failed", "stage": "transport"}, {"status": "failed", "stage": "signing"},
            {"status": "accepted", "stage": "apns", "apns_status": 200},
        ):
            with self.assertRaisesRegex(RuntimeError, "no confirmed APNs rejection"):
                await retry_confirmed_rejection(Path(self.temp.name), self.state, self.service,
                                                {"device_id": "fixture-phone"}, receipt)
        self.assertEqual(self.service.calls, [])
        self.assertFalse((Path(self.temp.name) / "retry-status.json").exists())

    async def test_one_guarded_retry_preserves_existing_registry(self):
        self.prepare()
        rejection = {"status": "failed", "stage": "apns", "apns_status": 403, "reason": "InvalidProviderToken"}
        event = {"device_id": "fixture-phone"}
        result = await retry_confirmed_rejection(Path(self.temp.name), self.state, self.service, event, rejection)
        self.assertEqual(result["push_status"], "accepted_by_apns")
        self.assertEqual(len(self.service.calls), 1)
        self.assertTrue(self.state.device("fixture-phone")["approved"])
        with self.assertRaisesRegex(RuntimeError, "already reserved"):
            await retry_confirmed_rejection(Path(self.temp.name), self.state, self.service, event, rejection)
        self.assertEqual(len(self.service.calls), 1)

    async def test_lost_retry_response_consumes_latch_without_leaking_url(self):
        self.prepare()
        self.service.failure = ValueError("secret-token-in-network-url")
        event = {"device_id": "fixture-phone"}
        rejection = {"status": "failed", "stage": "apns", "apns_status": 403}
        result = await retry_confirmed_rejection(Path(self.temp.name), self.state, self.service, event, rejection)
        self.assertNotIn("secret-token", json.dumps(result))
        self.assertEqual(result["request_error"], {"kind": "request_error"})
        with self.assertRaisesRegex(RuntimeError, "already reserved"):
            await retry_confirmed_rejection(Path(self.temp.name), self.state, self.service, event, rejection)
        self.assertEqual(len(self.service.calls), 1)

    async def test_retry_obeys_presence_registration_and_cleanup_deadline(self):
        self.prepare()
        event = {"device_id": "fixture-phone"}
        rejection = {"status": "failed", "stage": "apns", "apns_status": 403}
        with self.assertRaisesRegex(RuntimeError, "deadline"):
            await retry_confirmed_rejection(Path(self.temp.name), self.state, self.service, event, rejection, deadline=time.time() + 10)
        self.service.registered = False
        with self.assertRaisesRegex(RuntimeError, "no longer has an APNs registration"):
            await retry_confirmed_rejection(Path(self.temp.name), self.state, self.service, event, rejection)
        self.service.registered = True
        self.state.presence("fixture-phone", PROFILE, SESSION, True)
        with self.assertRaisesRegex(RuntimeError, "presence"):
            await retry_confirmed_rejection(Path(self.temp.name), self.state, self.service, event, rejection)
        self.assertEqual(self.service.calls, [])


if __name__ == "__main__":
    unittest.main()
