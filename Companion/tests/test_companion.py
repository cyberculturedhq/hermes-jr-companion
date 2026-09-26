import asyncio
import base64
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

from hermes_jr.api import handle
from hermes_jr.gateway import Gateway, dashboard_url, validate_rpc
from hermes_jr.plugin import register
from hermes_jr.service import validate_service_url
from hermes_jr.state import State


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(Path(self.temp.name))
        self.a, self.b = str(uuid.uuid4()), str(uuid.uuid4())
        self.a_token = self.state.add_device(self.a, "First", "service-a", paired=True)
        self.state.add_device(self.b, "Second", "service-b", paired=True)

    def tearDown(self):
        self.temp.cleanup()

    def test_pairing_is_single_use_and_requires_approval(self):
        device = str(uuid.uuid4())
        self.state.add_device(device, "New", "service", secret="one-time-secret", expires=time.time() + 60)
        self.assertFalse(self.state.accept_pair(device, b"a" * 32, "one-time-secret", "My phone"))
        self.assertIsNone(self.state.device(device)["pair_digest"])
        with self.assertRaises(PermissionError):
            self.state.accept_pair(device, b"b" * 32, "one-time-secret", "Other phone")
        self.assertFalse(self.state.accept_pair(device, b"a" * 32, "", "My phone"))
        self.state.approve(device)
        self.assertTrue(self.state.accept_pair(device, b"a" * 32, "", "My phone"))

    def test_expired_pairing_cannot_be_claimed(self):
        device = str(uuid.uuid4())
        self.state.add_device(device, "New", "service", secret="old", expires=time.time() - 1)
        with self.assertRaises(PermissionError):
            self.state.accept_pair(device, b"a" * 32, "old", "My phone")

    def test_local_credentials_and_revocation(self):
        self.assertEqual(self.state.authenticate(self.a, self.a_token)["id"], self.a)
        for device, credential in [(self.b, self.a_token), (self.a, "wrong")]:
            with self.assertRaises(PermissionError):
                self.state.authenticate(device, credential)
        self.state.follow(self.a, "default", "session")
        self.state.revoke(self.a)
        with self.assertRaises(PermissionError):
            self.state.authenticate(self.a, self.a_token)
        with self.state.connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM follows").fetchone()[0], 0)

    def test_notification_scope_dedup_presence_and_reference_privacy(self):
        self.state.set("push_enabled", True)
        self.state.set_push(self.a, True)
        self.state.set_push(self.b, True)
        self.state.follow(self.a, "default", "s1")
        self.state.follow(self.b, "other-profile", "s1")
        self.state.enqueue("default", "s1", "completed", "turn-1")
        self.state.enqueue("default", "s1", "completed", "turn-1")
        events = self.state.outbox()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["device_id"], self.a)
        self.assertEqual(len(events[0]["reference"]), 43)
        self.assertEqual(self.state.notification(self.a, events[0]["reference"])["session_id"], "s1")
        self.assertIsNone(self.state.notification(self.b, events[0]["reference"]))
        self.state.presence(self.a, "default", "s1", True)
        self.state.enqueue("default", "s1", "approval", "turn-2")
        self.assertEqual(len(self.state.outbox()), 1)
        self.state.presence(self.a, "default", "s1", False)
        self.state.enqueue("default", "s1", "approval", "turn-3")
        self.assertEqual(len(self.state.outbox()), 2)

    def test_all_sessions_scope_and_return_to_followed(self):
        self.state.set("push_enabled", True)
        for device in (self.a, self.b):
            self.state.set_push(device, True)
        self.assertFalse(self.state.all_session_notifications(self.a))
        self.state.follow(self.a, "default", "jr")
        self.state.set_all_session_notifications(self.a, True)
        self.state.enqueue("other", "cli", "completed", "cli-1")
        self.state.enqueue("default", "jr", "completed", "jr-1")
        self.state.enqueue("default", "jr", "completed", "jr-1")
        self.assertEqual([e["device_id"] for e in self.state.outbox()], [self.a, self.a])
        self.state.set_all_session_notifications(self.a, False)
        self.state.enqueue("other", "cli", "completed", "cli-2")
        self.state.enqueue("default", "jr", "completed", "jr-2")
        self.assertEqual(len(self.state.outbox()), 3)

    def test_all_sessions_presence_and_push_controls(self):
        self.state.set("push_enabled", True)
        self.state.set_push(self.a, True)
        self.state.set_all_session_notifications(self.a, True)
        self.state.presence(self.a, "other", "cli", True)
        self.state.enqueue("other", "child", "completed", "present", aliases=["cli"])
        self.assertEqual(self.state.outbox(), [])
        self.state.clear_presence(self.a)
        self.state.enqueue("other", "cli", "completed", "away")
        self.assertEqual(len(self.state.outbox()), 1)
        self.state.set_push(self.a, False)
        self.state.enqueue("other", "cli", "completed", "disabled")
        self.state.set_push(self.a, True)
        self.state.set("push_enabled", False)
        self.state.enqueue("other", "cli", "completed", "host-disabled")
        self.assertEqual(len(self.state.outbox()), 1)
        self.state.revoke(self.a)
        self.assertFalse(self.state.all_session_notifications(self.a))
        self.assertEqual(self.state.outbox(), [])

    def test_compression_alias_follows_old_session(self):
        self.state.settings({"push_enabled": True})
        self.state.set_push(self.a, True)
        self.state.follow(self.a, "default", "parent")
        self.state.enqueue("default", "continuation", "completed", "turn", aliases=["parent"])
        self.assertEqual(self.state.outbox()[0]["session_id"], "continuation")

    def test_storage_permissions(self):
        self.assertEqual(self.state.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.state.path.stat().st_mode & 0o777, 0o600)


class BoundaryTests(unittest.TestCase):
    def test_urls_cannot_turn_bridge_into_arbitrary_proxy(self):
        for url in ["http://evil.test", "http://127.0.0.1/a", "http://user:pass@127.0.0.1", "http://127.0.0.1?url=http://evil.test", "file:///etc/passwd"]:
            with self.assertRaises(ValueError):
                dashboard_url(url)
        for url in ["http://example.com", "https://relay.test/a", "https://user:pass@relay.test", "https://relay.test#key"]:
            with self.assertRaises(ValueError):
                validate_service_url(url)
        self.assertEqual(validate_service_url("http://127.0.0.1:8787", allow_local=True), "http://127.0.0.1:8787")

    def test_rpc_allowlist_and_session_retention(self):
        with self.assertRaises(ValueError):
            validate_rpc({"jsonrpc": "2.0", "method": "terminal.exec", "params": {}})
        with self.assertRaises(ValueError):
            validate_rpc({"jsonrpc": "2.0", "method": "config.get", "params": {"key": "api_key"}})
        with self.assertRaises(ValueError):
            validate_rpc({"jsonrpc": "2.0", "method": "config.set", "params": {"key": "plugins"}})
        frame = validate_rpc({"jsonrpc": "2.0", "method": "session.create", "params": {"close_on_disconnect": True}})
        self.assertFalse(frame["params"]["close_on_disconnect"])

    def test_registration_has_no_state_or_network_side_effects(self):
        class Context:
            def __init__(self): self.hooks = {}
            def register_hook(self, name, callback): self.hooks[name] = callback
            def register_cli_command(self, *args): self.command = args[0]
        ctx = Context()
        with patch("hermes_jr.plugin.State", side_effect=AssertionError("registration wrote state")):
            register(ctx)
        self.assertEqual(ctx.command, "jr")
        self.assertEqual(set(ctx.hooks), {"on_session_end", "pre_approval_request", "pre_tool_call"})


class APITests(unittest.IsolatedAsyncioTestCase):
    async def test_notification_scope_is_validated_and_device_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            state = State(Path(directory))
            first, second = str(uuid.uuid4()), str(uuid.uuid4())
            for device in (first, second):
                state.add_device(device, "Phone", "service", paired=True)
            path = "/v1/devices/self/notification-scope"
            self.assertEqual(await handle(state, first, "PUT", path, {"all_sessions": True}, {}, None), {"all_sessions": True})
            self.assertEqual(await handle(state, second, "GET", path, {}, {}, None), {"all_sessions": False})
            for body in ({}, {"all_sessions": "true"}, {"all_sessions": True, "device_id": second}):
                with self.assertRaises(ValueError):
                    await handle(state, first, "PUT", path, body, {}, None)
            state.revoke(first)
            with self.assertRaises(PermissionError):
                await handle(state, first, "PUT", path, {"all_sessions": True}, {}, None)

    async def test_upload_requires_approved_device_and_returns_saved_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            state = State(Path(directory))
            device = str(uuid.uuid4())
            body = {"upload_id": str(uuid.uuid4()), "filename": "notes.txt", "offset": 0,
                    "total": 5, "content_base64": base64.b64encode(b"hello").decode()}
            with self.assertRaises(PermissionError):
                await handle(state, device, "PUT", "/v1/uploads", body, {}, None)
            state.add_device(device, "Phone", "service", paired=True)
            result = await handle(state, device, "PUT", "/v1/uploads", body, {}, None)
            self.assertTrue(result["complete"])
            self.assertEqual(Path(result["path"]).read_bytes(), b"hello")
            state.revoke(device)
            with self.assertRaises(PermissionError):
                await handle(state, device, "PUT", "/v1/uploads", body, {}, None)

    async def test_background_presence_clears_without_coordinates(self):
        with tempfile.TemporaryDirectory() as directory:
            state = State(Path(directory))
            first, second = str(uuid.uuid4()), str(uuid.uuid4())
            for device in (first, second):
                state.add_device(device, "Phone", "service", paired=True)
                state.follow(device, "default", "s1")
                state.presence(device, "default", "s1", True)
            await handle(state, first, "PUT", "/v1/presence", {"active": False, "profile": "", "session_id": ""}, {}, None)
            with state.connect() as db:
                values = {row["device_id"]: row["present_until"] for row in db.execute("SELECT device_id,present_until FROM follows")}
            self.assertEqual(values[first], 0)
            self.assertGreater(values[second], time.time())

    async def test_follows_are_device_scoped_and_revoked_requests_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            state = State(Path(directory))
            first, second = str(uuid.uuid4()), str(uuid.uuid4())
            state.add_device(first, "One", "service", paired=True)
            state.add_device(second, "Two", "service", paired=True)
            await handle(state, first, "PUT", "/v1/follows", {"profile": "default", "session_id": "s1"}, {}, None)
            self.assertEqual((await handle(state, first, "GET", "/v1/follows", {}, {}, None))["follows"], [{"profile": "default", "session_id": "s1"}])
            self.assertEqual((await handle(state, second, "GET", "/v1/follows", {}, {}, None))["follows"], [])
            state.revoke(first)
            with self.assertRaises(PermissionError):
                await handle(state, first, "PUT", "/v1/follows", {"profile": "default", "session_id": "s2"}, {}, None)

    async def test_forbidden_http_never_reaches_network(self):
        with tempfile.TemporaryDirectory() as directory:
            state = State(Path(directory))
            gateway = Gateway(state, None)
            for path in ["https://evil.test", "/api/files", "/api/sessions/../../config", "/api/config"]:
                with self.assertRaises(PermissionError):
                    await gateway.http("device", {"method": "GET", "path": path})


if __name__ == "__main__":
    unittest.main()
