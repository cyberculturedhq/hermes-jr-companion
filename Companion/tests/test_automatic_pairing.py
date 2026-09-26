import asyncio
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from hermes_jr.state import State

class AutomaticPairingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.state=State(Path(self.temp.name))
        self.state.add_device('phone','iPhone','routing-token',secret='private-enrollment-secret',expires=time.time()+600,automatic=True)

    async def test_claim_authorizes_only_phone_with_secret_and_binds_its_key(self):
        with self.assertRaises(PermissionError):self.state.accept_pair('phone',b'a'*32,'routing-token','Wrong phone')
        self.assertFalse(self.state.device('phone')['approved'])
        self.assertTrue(self.state.accept_pair('phone',b'b'*32,'private-enrollment-secret','My phone'))
        self.assertTrue(self.state.device('phone')['approved'])
        self.assertIsNone(self.state.device('phone')['pair_digest'])
        with self.assertRaises(PermissionError):self.state.accept_pair('phone',b'c'*32,'private-enrollment-secret','Second phone')
        self.assertTrue(self.state.accept_pair('phone',b'b'*32,'','My phone'))

    async def test_expired_and_revoked_codes_never_authorize(self):
        with self.state.connect() as db:db.execute('UPDATE devices SET pair_expires=?',(time.time()-1,))
        with self.assertRaises(PermissionError):self.state.accept_pair('phone',b'b'*32,'private-enrollment-secret','Phone')
        self.state.revoke('phone')
        with self.assertRaises(PermissionError):self.state.accept_pair('phone',b'b'*32,'private-enrollment-secret','Phone')
