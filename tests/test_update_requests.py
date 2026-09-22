import asyncio
import base64
import fcntl
import json
from pathlib import Path
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch
from hermes_jr.state import State
from hermes_jr.api import handle
from hermes_jr import update_requests as updates
import signing_fixture


class UpdateRequestTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = State(Path(self.temp.name))
        self.device = str(uuid.uuid4())
        self.state.add_device(self.device, 'Phone', 'service-token', paired=True)
        self.state.set('push_enabled', True)
        self.state.set_push(self.device, True)
        self.receipt = dict(id=str(uuid.uuid4()), device_id=self.device, profile='default',
                            session_id='session-1', target='0.16.0', notify=True, created=time.time())
        self.release = dict(latest='0.16.0', commit='a'*40, state='available', signature=signing_fixture.signature('0.16.0'))
        self.signing = patch('hermes_jr.release_signature.PUBLIC_KEY', signing_fixture.PUBLIC)
        self.signing.start(); self.addCleanup(self.signing.stop)

    def encoded(self):
        return base64.urlsafe_b64encode(json.dumps(self.receipt).encode()).decode().rstrip('=')

    async def test_registration_is_authenticated_idempotent_and_never_installs(self):
        path = '/v1/update-requests/' + self.receipt['id']
        with patch('hermes_jr.installer.install') as install:
            for _ in range(2):
                result = await handle(self.state, self.device, 'PUT', path, self.receipt, {}, None)
                self.assertEqual(result['status'], 'queued')
            install.assert_not_called()
        other = str(uuid.uuid4()); self.state.add_device(other, 'Other', 'other', paired=True)
        with self.assertRaises(PermissionError):
            await handle(self.state, other, 'PUT', path, self.receipt, {}, None)
        with self.assertRaises(LookupError):
            await handle(self.state, other, 'GET', path, {}, {}, None)
        self.assertEqual(self.state.outbox(), [])

    def test_exactly_one_completion_and_no_duplicate_model_reply(self):
        updates.register(self.state, self.receipt)
        self.state.follow(self.device, 'default', 'session-1')
        self.state.enqueue('default', 'session-1', 'completed', 'turn-1')
        self.assertEqual(self.state.outbox(), [])
        self.assertFalse(updates.complete(self.state, self.receipt['id'], '0.15.0'))
        self.assertTrue(updates.complete(self.state, self.receipt['id'], '0.16.0'))
        self.assertFalse(updates.complete(self.state, self.receipt['id'], '0.16.0'))
        events = self.state.outbox()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['kind'], 'update_completed')
        self.assertEqual(self.state.notification(self.device, events[0]['reference'])['session_id'], 'session-1')
        # Continuing this conversation later must still produce ordinary reply notifications.
        with patch('hermes_jr.state.time.time', return_value=time.time() + 180):
            self.state.enqueue('default', 'session-1', 'completed', 'later-turn')
            self.assertEqual(len(self.state.outbox()), 2)

    def test_completion_respects_opt_out_and_revocation(self):
        for mode in ['receipt', 'host', 'device', 'revoked']:
            with self.subTest(mode=mode):
                self.receipt['id'] = str(uuid.uuid4())
                self.receipt['notify'] = mode != 'receipt'
                self.state.set('push_enabled', mode != 'host')
                self.state.set_push(self.device, mode != 'device')
                updates.register(self.state, self.receipt)
                if mode == 'revoked': self.state.revoke(self.device)
                updates.complete(self.state, self.receipt['id'], '0.16.0')
                self.assertEqual(self.state.outbox(), [])

    def test_invalid_and_expired_receipts_do_not_register(self):
        for change in [dict(created=time.time()-86401), dict(notify='true'), dict(target='main'), dict(profile='../default'), dict(session_id='a;sh'), dict(device_id='wrong')]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                updates.register(self.state, {**self.receipt, **change})

    def test_first_upgrade_registers_receipt_then_verifies_actual_install(self):
        with patch.object(updates, 'installed_version', side_effect=['0.14.0', '0.16.0']), \
             patch('hermes_jr.installer.install') as install, patch('hermes_jr.installer.verify_connection') as health:
            updates.run_tracked(self.state, self.release, self.encoded())
            install.assert_called_once_with(self.state, self.release, receipt_id=self.receipt['id'])
            health.assert_called_once_with(self.state)
        self.assertEqual(updates.status(self.state, self.device, self.receipt['id'])['status'], 'completed')
        self.assertEqual(len(self.state.outbox()), 1)

    def test_failed_health_never_sends_success(self):
        with patch.object(updates, 'installed_version', return_value='0.16.0'), \
             patch('hermes_jr.installer.verify_connection', side_effect=ValueError('offline')):
            with self.assertRaises(ValueError): updates.run_tracked(self.state, self.release, self.encoded())
        self.assertEqual(updates.status(self.state, self.device, self.receipt['id'])['status'], 'failed')
        self.assertEqual(self.state.outbox(), [])

    def test_duplicate_running_installer_does_not_poison_original_receipt(self):
        updates.register(self.state, self.receipt)
        with (self.state.directory/'guided-update.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ValueError, 'already running'):
                updates.run_tracked(self.state, self.release, self.encoded())
        self.assertEqual(updates.status(self.state, self.device, self.receipt['id'])['status'], 'queued')

    async def test_recovery_requires_committed_matching_journal_and_health(self):
        from types import SimpleNamespace
        updates.register(self.state, self.receipt)
        (self.state.directory/'last-update.json').write_text(json.dumps({'backup':'fixture'}))
        journal = dict(phase='complete', update_request=self.receipt['id'], target_version='0.16.0')
        with patch('hermes_jr.recovery.Snapshot', return_value=SimpleNamespace(journal=journal)), \
             patch.object(updates, 'installed_version', return_value='0.16.0'), \
             patch('hermes_jr.installer.verify_connection') as health:
            journal['phase'] = 'rolled_back'; await updates.recover(self.state)
            health.assert_not_called(); self.assertEqual(self.state.outbox(), [])
            journal['phase'] = 'complete'
            await updates.recover(self.state); await updates.recover(self.state)
            health.assert_called_once()
        self.assertEqual(len(self.state.outbox()), 1)
