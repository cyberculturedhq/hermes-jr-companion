import asyncio
import base64
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

from hermes_jr import bot_replies as b
from hermes_jr.api import handle
from hermes_jr.state import State
from hermes_jr.uploads import upload


class BotReplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'profile'
        self.home.mkdir()
        self.state = State(Path(self.temp.name) / 'state')
        self.phone, self.other = str(uuid.uuid4()), str(uuid.uuid4())
        for device in (self.phone, self.other):
            self.state.add_device(device, 'Test phone', 'fixture-token', paired=True)
        self.id = str(uuid.uuid4())
        self.body = dict(profile='research', session_id='bot-tip', text='Testing', attachments=[])
        self.database = Mock()
        self.database.get_session_by_title.return_value = {'id': 'bot-root'}
        self.database.get_session.side_effect = lambda sid: {'id': sid} if sid in ('bot-root', 'bot-tip', 'old-tip') else None
        self.database.get_compression_tip.side_effect = lambda sid: 'bot-tip' if sid in ('bot-root', 'bot-tip', 'old-tip') else sid
        self.delivery = Mock()
        self.owner = dict(profile_home=str(self.home), session_id='bot-tip', lease_id='original-lease',
                          metadata={'live_session_id': 'desktop-runtime', 'bot_live_delivery_consumer': True})
        self.delivery.find_canonical_owner.return_value = self.owner
        self.delivery.owner_holds_delivery.return_value = True
        self.receipts = {}
        self.admissions = []
        def admit(home, owner, text, *, delivery_id, author):
            if delivery_id not in self.receipts:
                self.admissions.append((owner, text, author))
                self.receipts[delivery_id] = dict(status='queued', owner=owner, reply='', error='')
            return self.receipts[delivery_id]
        self.admit = admit
        self.delivery.deliver_to_live_owner.side_effect = admit
        self.delivery.read_delivery_result.side_effect = lambda home, did: self.receipts.get(did)
        def cancel(home, did, **kw):
            receipt = self.receipts[did]
            if receipt['status'] == 'queued': receipt.update(status='cancelled', error=kw['error'])
            return receipt
        self.delivery.cancel_queued_delivery.side_effect = cancel
        p = patch.object(b, 'runtime', return_value=(self.home, Mock(return_value=self.database), self.delivery))
        p.start()
        self.addCleanup(p.stop)

    def submit(self, body=None):
        return asyncio.run(handle(self.state, self.phone, 'PUT', '/v1/bot-replies/' + self.id,
                                  body or self.body, {}, None))

    def test_idle_or_busy_owner_receives_one_human_message(self):
        result = self.submit()
        self.assertEqual((result['route'], result['status']), ('owner', 'queued'))
        owner, text, author = self.admissions[0]
        self.assertEqual(owner['live_session_id'], 'desktop-runtime')
        self.assertEqual(text, 'Testing')
        self.assertIsNone(author)
        self.assertNotIn('lease_id', result)
        receipt = next(iter(self.receipts.values()))
        receipt.update(status='claimed')
        self.assertEqual(self.submit()['status'], 'claimed')
        receipt.update(status='settled', reply='Bot reply')
        self.assertEqual(self.submit()['reply'], 'Bot reply')
        self.assertEqual(len(self.admissions), 1)

    def test_receipt_survives_restart_and_lost_acknowledgement(self):
        self.submit()
        self.state = State(self.state.directory)
        self.assertEqual(b.result(self.state, self.phone, self.id)['status'], 'queued')
        self.submit()
        self.assertEqual(len(self.admissions), 1)

    def test_crash_before_admission_retries_only_the_reserved_owner(self):
        self.delivery.deliver_to_live_owner.side_effect = OSError('Admission interrupted')
        with self.assertRaises(OSError): self.submit()
        self.assertEqual(b.result(self.state, self.phone, self.id)['status'], 'preparing')
        self.delivery.find_canonical_owner.return_value = {**self.owner, 'lease_id': 'replacement'}
        self.delivery.deliver_to_live_owner.side_effect = self.admit
        self.submit()
        self.assertEqual(self.admissions[0][0]['lease_id'], 'original-lease')

    def test_changed_payload_cannot_reuse_a_receipt(self):
        self.submit()
        with self.assertRaises(ValueError): self.submit({**self.body, 'text': 'Different'})
        self.assertEqual(len(self.admissions), 1)

    def test_revocation_blocks_a_retry_before_mailbox_admission(self):
        self.delivery.deliver_to_live_owner.side_effect = OSError('Admission interrupted')
        with self.assertRaises(OSError): self.submit()
        self.state.revoke(self.phone)
        self.delivery.deliver_to_live_owner.side_effect = self.admit
        with self.assertRaises(PermissionError): self.submit()
        self.assertFalse(self.admissions)
        self.assertIsNotNone(self.state.get(b.key(self.phone, self.id)))

    def test_missing_owner_uses_the_same_session_without_mailbox_admission(self):
        self.delivery.find_canonical_owner.return_value = None
        result = self.submit()
        self.assertEqual(result['route'], 'session')
        self.assertEqual(result['session_id'], 'bot-tip')
        self.delivery.deliver_to_live_owner.assert_not_called()

    def test_an_old_compression_tip_still_targets_the_current_bot(self):
        result = self.submit({**self.body, 'session_id': 'old-tip'})
        self.assertEqual(result['session_id'], 'bot-tip')

    def test_an_ordinary_session_cannot_use_bot_delivery(self):
        with self.assertRaises(ValueError): self.submit({**self.body, 'session_id': 'separate-session'})
        self.assertFalse(self.admissions)

    def test_unsupported_owner_is_not_closed_or_replaced(self):
        self.delivery.find_canonical_owner.return_value = {**self.owner, 'metadata': {}}
        self.assertEqual(self.submit()['route'], 'unavailable')
        self.delivery.deliver_to_live_owner.assert_not_called()

    def test_device_authentication_and_receipt_scope(self):
        self.submit()
        with self.assertRaises(LookupError): b.result(self.state, self.other, self.id)
        self.state.revoke(self.phone)
        with self.assertRaises(PermissionError): self.submit()

    def test_owner_loss_cancels_only_unclaimed_messages(self):
        self.submit()
        self.delivery.owner_holds_delivery.return_value = False
        self.assertEqual(b.result(self.state, self.phone, self.id)['status'], 'cancelled')
        self.assertEqual(len(self.admissions), 1)

    def test_claimed_owner_loss_reports_unknown_without_resubmission(self):
        self.submit()
        next(iter(self.receipts.values()))['status'] = 'claimed'
        self.delivery.owner_holds_delivery.return_value = False
        self.assertEqual(b.result(self.state, self.phone, self.id)['status'], 'ambiguous')
        self.delivery.cancel_queued_delivery.assert_not_called()
        self.assertEqual(len(self.admissions), 1)

    def test_cancel_does_not_interrupt_a_claimed_turn(self):
        self.submit()
        next(iter(self.receipts.values()))['status'] = 'claimed'
        self.assertEqual(b.result(self.state, self.phone, self.id, cancel=True)['status'], 'claimed')
        self.delivery.cancel_queued_delivery.assert_not_called()

    def test_attachments_require_completed_uploads_from_this_device(self):
        uid = str(uuid.uuid4())
        data = base64.b64encode(b'image bytes').decode()
        reference = {'upload_id': uid, 'filename': 'photo.jpg'}
        upload(self.state, self.other, dict(**reference, content_base64=data, offset=0, total=11))
        with self.assertRaises(ValueError): self.submit({**self.body, 'attachments': [reference]})
        upload(self.state, self.phone, dict(**reference, content_base64=data, offset=0, total=12))
        with self.assertRaises(ValueError): self.submit({**self.body, 'attachments': [reference]})
        upload(self.state, self.phone, dict(**reference, content_base64=base64.b64encode(b'!').decode(), offset=11, total=12))
        result = self.submit({**self.body, 'attachments': [reference]})
        self.assertEqual(len(result['paths']), 1)
        self.assertIn('[User attached file: ', self.admissions[0][1])

    def test_client_cannot_choose_an_owner_or_bot_author(self):
        for field in ('owner', 'author', 'path'):
            with self.assertRaises(ValueError): self.submit({**self.body, field: 'forged'})
        self.assertFalse(self.admissions)

    def test_attachments_reject_file_and_directory_symlinks(self):
        outside = self.home / 'photo.jpg'
        outside.write_bytes(b'image bytes')
        for kind in ('file', 'directory'):
            with self.subTest(kind=kind):
                reference = {'upload_id': str(uuid.uuid4()), 'filename': 'photo.jpg'}
                result = upload(self.state, self.phone, dict(**reference,
                    content_base64=base64.b64encode(b'image bytes').decode(), offset=0, total=11))
                target = Path(result['path'])
                if kind == 'file':
                    target.unlink()
                    target.symlink_to(outside)
                else:
                    target.parent.rename(target.parent.with_name(reference['upload_id'] + '-original'))
                    target.parent.symlink_to(outside.parent, target_is_directory=True)
                with self.assertRaises(ValueError):
                    self.submit({**self.body, 'attachments': [reference]})
        self.assertFalse(self.admissions)
