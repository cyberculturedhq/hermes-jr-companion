import asyncio
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch
from hermes_jr.state import State
from hermes_jr import setup_jobs as jobs


class SetupJobTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = State(Path(self.temp.name))
        self.state.settings({'relay_enabled': True, 'host_private_key': 'fixture', 'service_url': 'https://relay.test',
                             'setup_worker': {'version': 1, 'at': time.time()}})
        jobs.initialize(self.state)
        self.service = AsyncMock()
        self.service.request.return_value = {'public_key': 'fixture'}
        self.ticket = 'fixture-public-ticket'
        self.verification = patch.object(jobs.setup_crypto, 'verify_ticket', return_value={'expires_at': time.time()+600})
        self.verification.start()

    async def asyncTearDown(self):
        self.verification.stop()
        self.temp.cleanup()

    async def test_pending_returns_bounded_and_retry_does_not_duplicate_job(self):
        start = time.monotonic()
        self.assertEqual((await jobs.command(self.state,self.service,self.ticket,'iPhone',wait_seconds=.01))['status'],'pending')
        self.assertLess(time.monotonic()-start,1)
        await jobs.command(self.state,self.service,self.ticket,'iPhone',wait_seconds=0)
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM setup_jobs').fetchone()[0],1)

    async def test_ready_result_is_available_before_confirmation_and_hides_ticket(self):
        await jobs.command(self.state,self.service,self.ticket,'iPhone',wait_seconds=0)
        jobs.publish(self.state,jobs.identity(self.ticket),'ready',code='1234 5678 9012',expires_at=time.time()+300)
        value=await jobs.command(self.state,self.service,self.ticket,'iPhone',status_only=True)
        self.assertEqual(value['status'],'ready')
        self.assertEqual(value['code'],'1234 5678 9012')
        self.assertNotIn(self.ticket,json.dumps(value))
        self.assertNotEqual(value['status'],'connected')

    async def test_expiry_never_reports_completion_and_hides_old_code(self):
        await jobs.command(self.state,self.service,self.ticket,'iPhone',wait_seconds=0)
        jobs.publish(self.state,jobs.identity(self.ticket),'ready',code='1234 5678 9012',expires_at=time.time()-1)
        value=jobs.result(self.state,jobs.identity(self.ticket))
        self.assertEqual(value['status'],'expired')
        self.assertNotIn('code',value)

    async def test_connected_scrubs_ticket_and_code(self):
        await jobs.command(self.state,self.service,self.ticket,'iPhone',wait_seconds=0)
        jobs.publish(self.state,jobs.identity(self.ticket),'connected')
        with self.state.connect() as db:
            row=db.execute('SELECT ticket,code,status FROM setup_jobs').fetchone()
        self.assertIsNone(row['ticket']); self.assertIsNone(row['code'])
        self.assertEqual(row['status'],'connected')

    async def test_status_does_not_create_or_contact_service(self):
        self.assertEqual((await jobs.command(self.state,self.service,self.ticket,'iPhone',status_only=True))['status'],'not_found')
        self.service.request.assert_not_awaited()

    async def test_second_active_ticket_is_rejected(self):
        await jobs.command(self.state,self.service,self.ticket,'iPhone',wait_seconds=0)
        with self.assertRaisesRegex(ValueError,'Another pairing'):
            await jobs.command(self.state,self.service,'another-ticket','iPhone',wait_seconds=0)

    async def test_outdated_service_cannot_silently_accept_setup(self):
        self.state.set('setup_worker',{'version':1,'at':time.time()-30})
        with self.assertRaisesRegex(ValueError,'Restart'):
            await jobs.command(self.state,self.service,self.ticket,'iPhone',wait_seconds=0)
        self.service.request.assert_not_awaited()
