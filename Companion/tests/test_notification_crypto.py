import json
import time
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from hermes_jr.notification_crypto import encrypt, decode, encode, validate_key, PREFIX
from hermes_jr.state import State, token
from hermes_jr.service import Service
from hermes_jr.api import handle

class NotificationCryptoTests(unittest.TestCase):
    def setUp(self):
        self.key={'key_id':encode(bytes(range(16))), 'secret':encode(bytes(range(32)))}
        self.event={'reference':token(),'profile':'research','kind':'approval'}

    def decrypt(self, envelope, reference=None):
        raw=decode(envelope['data'],1052)
        aad=PREFIX+envelope['kid'].encode()+b'\0'+(reference or self.event['reference']).encode()
        padded=ChaCha20Poly1305(decode(self.key['secret'],32)).decrypt(raw[:12],raw[12:],aad)
        length=int.from_bytes(padded[:2],'big')
        self.assertEqual(len(padded),1024)
        self.assertEqual(padded[2+length:],bytes(1024-2-length))
        return json.loads(padded[2:2+length])

    def test_private_details_encrypted_and_all_events_roundtrip(self):
        for kind in ['completed','error','approval','clarification']:
            self.event['kind']=kind
            encrypted=encrypt(self.key,self.event,{'profile_name':'Research','session_title':'Weekend trip'})
            self.assertEqual(len(encrypted['data']),1403)
            self.assertEqual(self.decrypt(encrypted)['conversation'],'Weekend trip')
            self.assertEqual(self.decrypt(encrypted)['kind'],kind)
            self.assertNotIn('Research',json.dumps(encrypted))

    def test_random_nonce_tamper_and_reference_binding(self):
        one=encrypt(self.key,self.event,{})
        self.assertNotEqual(one['data'],encrypt(self.key,self.event,{})['data'])
        with self.assertRaises(Exception):self.decrypt(one,token())
        raw=bytearray(decode(one['data'],1052));raw[50]^=1;one['data']=encode(raw)
        with self.assertRaises(Exception):self.decrypt(one)

    def test_limits_and_key_validation(self):
        data=self.decrypt(encrypt(self.key,self.event,{'profile_name':'a'*10000,'session_title':'😎'*10000}))
        self.assertLessEqual(len(data['profile'].encode()),120)
        self.assertLessEqual(len(data['conversation'].encode()),240)
        for invalid in [None,{},dict(self.key,secret='a'),dict(self.key,key_id='a'*22),dict(self.key,extra=1)]:
            with self.assertRaises(ValueError):validate_key(invalid)

class NotificationDeliveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.state=State(Path(self.temp.name));self.state.settings({'push_enabled':True,'host_token':'fixture','installation_id':'fixture'})
        self.state.add_device('phone','iPhone','service-only-token',paired=True)
        self.key={'key_id':encode(bytes(range(16))),'secret':encode(bytes(range(32)))}

    async def test_registration_never_forwards_secret_to_service(self):
        with patch.object(Service,'push_registration',new_callable=AsyncMock) as register:
            await handle(self.state,'phone','PUT','/v1/devices/self/push',{'apns_token':'a'*64,'environment':'sandbox','notification_key':self.key},{},None)
            self.assertEqual(register.call_args.args[1],{'apns_token':'a'*64,'environment':'sandbox'})
        self.assertEqual(self.state.notification_key('phone'),self.key)
        self.state.follow('phone','research','session')
        self.state.enqueue('research','session','completed','one',session_title='Secret title')
        event=self.state.outbox()[0]
        with patch.object(Service,'request',new_callable=AsyncMock) as request:
            await Service(self.state,None).send_push(event)
            payload=request.call_args.args[2]
            self.assertEqual(set(payload),{'reference','encrypted'})
            self.assertNotIn('Secret title',json.dumps(payload))
        self.state.revoke('phone')
        self.assertIsNone(self.state.notification_key('phone'))
        self.assertEqual(self.state.notification_detail(event['reference']),{})

    async def test_legacy_registration_stays_generic_and_disable_clears_key(self):
        self.state.set_notification_key('phone',self.key)
        with patch.object(Service,'push_registration',new_callable=AsyncMock):
            await handle(self.state,'phone','PUT','/v1/devices/self/push',{'apns_token':'a'*64,'environment':'sandbox'},{},None)
            self.assertIsNone(self.state.notification_key('phone'))
            self.state.set_notification_key('phone',self.key)
            await handle(self.state,'phone','DELETE','/v1/devices/self/push',{}, {},None)
            self.assertIsNone(self.state.notification_key('phone'))
