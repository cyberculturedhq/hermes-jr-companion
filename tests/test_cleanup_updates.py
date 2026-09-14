import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import AsyncMock, patch
import uuid
from hermes_jr.state import State
from hermes_jr.cleanup import sweep
from hermes_jr.updates import public_status
from hermes_jr.service import Service, ServiceError


class CleanupTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = State(Path(self.temp.name))

    def device(self, *, approved=False, expiry=-1):
        device = str(uuid.uuid4())
        self.state.add_device(device, 'fixture', 'private service token', paired=approved,
                              secret='private invitation', expires=time.time()+expiry)
        return device

    async def test_expired_offers_revoked_but_approved_and_live_devices_survive(self):
        expired = self.device()
        approved = self.device(approved=True)
        live = self.device(expiry=600)
        service = AsyncMock()
        await sweep(self.state, service)
        self.assertIsNone(self.state.device(expired))
        self.assertIsNotNone(self.state.device(approved))
        self.assertIsNotNone(self.state.device(live))
        service.delete_device.assert_awaited_once_with(expired)
        self.assertEqual(self.state.pending_deletions(), [])
        with self.state.connect() as db:
            row = db.execute('SELECT * FROM devices WHERE id=?', (expired,)).fetchone()
        self.assertIsNone(row['service_token'])
        self.assertIsNone(row['pair_digest'])
        self.assertIsNone(row['local_digest'])

    async def test_failed_remote_cleanup_survives_restart_and_obeys_backoff(self):
        expired = self.device()
        service = AsyncMock()
        service.delete_device.side_effect = ServiceError(503)
        await sweep(self.state, service)
        self.assertIsNone(self.state.device(expired))
        self.assertEqual(self.state.pending_deletions(), [])
        reopened = State(self.state.directory)
        service.delete_device.side_effect = None
        with patch('hermes_jr.state.time.time', return_value=time.time()+3601):
            await sweep(reopened, service)
        self.assertEqual(service.delete_device.await_count, 2)
        self.assertEqual(reopened.pending_deletions(), [])

    async def test_404_is_idempotent_success_but_unauthorized_is_not(self):
        service = Service(self.state, None)
        service.request = AsyncMock(side_effect=ServiceError(404))
        await service.delete_device(str(uuid.uuid4()))
        service.request.side_effect = ServiceError(401)
        with self.assertRaises(ServiceError):
            await service.delete_device(str(uuid.uuid4()))

    async def test_manual_revocation_is_retried_without_expiring_approved_phones(self):
        device = self.device(approved=True)
        self.state.revoke(device)
        self.assertEqual(self.state.pending_deletions()[0]['device_id'], device)
        await sweep(self.state, AsyncMock())
        self.assertEqual(self.state.pending_deletions(), [])

    def test_owner_approval_and_expiry_do_not_race(self):
        device = self.device(expiry=600)
        self.state.accept_pair(device, b'a'*32, 'private invitation', 'fixture')
        self.state.approve(device)
        with patch('hermes_jr.state.time.time', return_value=time.time()+1000):
            self.state.expire_pending()
        self.assertTrue(self.state.device(device)['approved'])
        expired = self.device()
        self.state.expire_pending()
        with self.assertRaises(ValueError):
            self.state.approve(expired)

    def test_phone_update_payload_is_bounded_and_has_no_remote_url(self):
        with patch('hermes_jr.updates.installed_version', return_value='0.3.0'):
            self.state.settings({'update_status': {'state':'available','latest':'0.4.0', 'checked_at':time.time(), 'url':'https://evil.test', 'credential':'SECRET'}})
            self.assertEqual(public_status(self.state), {'installed':'0.3.0','available':True,'version':'0.4.0'})
            self.state.settings({'update_checks_enabled':False})
            self.assertFalse(public_status(self.state)['available'])
            self.state.settings({'update_checks_enabled':True,'update_status': {'state':'available','latest':'../../evil','checked_at':time.time()}})
            self.assertFalse(public_status(self.state)['available'])
            self.state.settings({'update_status': {'state':'available','latest':'0.4.0','checked_at':0}})
            self.assertFalse(public_status(self.state)['available'])
