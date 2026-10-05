import base64
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import time
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid

from hermes_jr.state import State
from hermes_jr.storage import (DEFAULTS, FILE_OVERHEAD, PARTIAL_LIFETIME,
                               StorageCapacityError, reserve_reply, sweep)
from hermes_jr.uploads import upload, MAX_BYTES


class StorageLimitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = State(Path(self.temp.name))
        self.state.add_device('phone', 'Phone', 'fixture', paired=True)
        self.state.add_device('other', 'Other', 'fixture', paired=True)

    def body(self, size=2):
        return dict(upload_id=str(uuid.uuid4()), filename='file.txt', offset=0,
                    total=size, content_base64=base64.b64encode(b'x').decode())

    def test_concurrent_reservations_cannot_exceed_count_or_bytes(self):
        self.state.set('storage_limits', {'upload_device_count': 2})
        def allocate(_):
            try:
                upload(self.state, 'phone', self.body())
                return True
            except StorageCapacityError:
                return False
        with ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(sum(pool.map(allocate, range(16))), 2)
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM upload_storage').fetchone()[0], 2)
        self.assertEqual(len(list((self.state.directory / 'uploads').rglob('file.txt'))), 2)
        upload(self.state, 'other', self.body())

    def test_supported_twenty_attachment_batch_and_resumes_at_capacity(self):
        bodies = [self.body(MAX_BYTES) for _ in range(20)]
        for body in bodies:
            upload(self.state, 'phone', body)
        with self.state.connect() as db:
            used = db.execute('SELECT SUM(total + ?) FROM upload_storage', (FILE_OVERHEAD,)).fetchone()[0]
        self.assertLess(used, DEFAULTS['upload_device_bytes'])
        self.state.set('storage_limits', {'upload_device_bytes': used, 'upload_device_count': 20})
        with self.assertRaises(StorageCapacityError):
            upload(self.state, 'phone', self.body())
        resumed = upload(self.state, 'phone', {**bodies[0], 'offset': 1})
        self.assertEqual(resumed['offset'], 2)

    def test_crash_reservation_is_charged_and_can_resume_before_file_creation(self):
        body = self.body()
        with patch('pathlib.Path.mkdir', side_effect=OSError('fixture')):
            with self.assertRaises(OSError):
                upload(self.state, 'phone', body)
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM upload_storage').fetchone()[0], 1)
        upload(self.state, 'phone', body)
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM upload_storage').fetchone()[0], 1)

    def test_lost_chunk_and_completion_responses_keep_one_file(self):
        body = self.body()
        first = upload(self.state, 'phone', body)
        self.assertEqual(upload(self.state, 'phone', body), first)
        last = {**body, 'offset': 1}
        complete = upload(self.state, 'phone', last)
        self.assertEqual(upload(self.state, 'phone', last), complete)
        with self.assertRaisesRegex(ValueError, 'does not match'):
            upload(self.state, 'phone', {**last, 'content_base64': base64.b64encode(b'y').decode()})
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM upload_storage').fetchone()[0], 1)

    def test_partial_cleanup_and_revocation_preserve_completed_files(self):
        partial, complete = self.body(), self.body(1)
        upload(self.state, 'phone', partial)
        result = upload(self.state, 'phone', complete)
        with self.state.connect() as db:
            db.execute('UPDATE upload_storage SET touched=? WHERE complete=0', (time.time() - PARTIAL_LIFETIME - 1,))
        sweep(self.state)
        self.assertTrue(Path(result['path']).exists())
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM upload_storage').fetchone()[0], 1)
        upload(self.state, 'phone', self.body())
        self.state.revoke('phone')
        sweep(self.state)
        self.assertTrue(Path(result['path']).exists())
        with self.assertRaises(PermissionError):
            upload(self.state, 'phone', self.body())

    def test_reply_bound_includes_old_payloads_and_keeps_replay_results(self):
        key = 'bot-reply/phone/' + str(uuid.uuid4())
        self.state.set(key, {'message': '\U0001f600' * 100})
        self.state.set('storage_limits', {'reply_device_count': 1})
        with self.state.connect() as db, self.assertRaises(StorageCapacityError):
            db.execute('BEGIN IMMEDIATE')
            reserve_reply(self.state, db, 'phone', key + 'new', '{}')
        self.assertEqual(self.state.get(key)['message'], '\U0001f600' * 100)
        self.state.revoke('phone')
        sweep(self.state)
        self.assertIsNotNone(self.state.get(key))

    def test_reply_byte_limit_counts_utf8_and_parallel_allocations(self):
        value = '{"text":"' + '\U0001f600' * 100 + '"}'
        key = 'bot-reply/phone/' + str(uuid.uuid4())
        with self.state.connect() as db:
            db.execute('INSERT INTO settings VALUES(?,?)', (key, value))
        self.state.set('storage_limits', {'reply_device_bytes': 1400})
        with self.state.connect() as db, self.assertRaises(StorageCapacityError):
            db.execute('BEGIN IMMEDIATE')
            reserve_reply(self.state, db, 'phone', key + 'new', '{}')
        self.state.set('storage_limits', {'reply_device_count': 3})
        def allocate(_):
            record = 'bot-reply/phone/' + str(uuid.uuid4())
            try:
                with self.state.connect() as db:
                    db.execute('BEGIN IMMEDIATE')
                    reserve_reply(self.state, db, 'phone', record, '{}')
                    db.execute('INSERT INTO settings VALUES(?,?)', (record, '{}'))
                return True
            except StorageCapacityError:
                return False
        with ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(sum(pool.map(allocate, range(16))), 2)

    def test_partial_cleanup_keeps_a_completed_sibling_and_failed_deletion_charged(self):
        partial = self.body()
        complete = {**partial, 'filename': 'saved.txt', 'total': 1}
        upload(self.state, 'phone', partial)
        saved = upload(self.state, 'phone', complete)
        self.state.revoke('phone')
        with patch('pathlib.Path.unlink', side_effect=OSError('fixture')):
            sweep(self.state)
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM upload_storage').fetchone()[0], 2)
        sweep(self.state)
        self.assertTrue(Path(saved['path']).exists())
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM upload_storage').fetchone()[0], 1)

    def test_low_disk_space_stops_new_allocation_before_files(self):
        with patch('hermes_jr.storage.shutil.disk_usage', return_value=type('Usage', (), {'free': 1})()):
            with self.assertRaises(StorageCapacityError):
                upload(self.state, 'phone', self.body())
        self.assertFalse((self.state.directory / 'uploads').exists())

    def test_restart_reconciles_legacy_writes_after_a_rollback(self):
        import hashlib
        root = self.state.directory / 'uploads' / hashlib.sha256(b'phone').hexdigest() / str(uuid.uuid4())
        root.mkdir(parents=True)
        (root / 'legacy.txt').write_bytes(b'completed history')
        self.state.set('storage_limits', {'upload_device_count': 1})
        code = ('from pathlib import Path; import sys; from hermes_jr.state import State; '
                's=State(Path(sys.argv[1])); '
                'assert (s.directory/"uploads").is_dir()')
        subprocess.run([sys.executable, '-c', code, str(self.state.directory)], check=True, capture_output=True)
        with self.state.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM upload_storage').fetchone()[0], 1)
        self.assertTrue((root / 'legacy.txt').exists())
        with self.assertRaises(StorageCapacityError):
            upload(self.state, 'phone', self.body())

    def test_restart_preserves_a_reservation_completed_by_an_older_version(self):
        body = self.body()
        upload(self.state, 'phone', body)
        with self.state.connect() as db:
            row = db.execute('SELECT path FROM upload_storage').fetchone()
            db.execute('UPDATE upload_storage SET touched=?',
                       (time.time() - PARTIAL_LIFETIME - 1,))
        path = self.state.directory / row['path']
        # The previous release can write bytes without updating the new journal.
        path.write_bytes(b'completed by previous release')
        self.state.set('upload-complete/' + '/'.join(Path(row['path']).parts[1:]),
                       {'size': path.stat().st_size})
        code = ('from pathlib import Path; import sys; from hermes_jr.state import State; '
                'from hermes_jr.storage import sweep; s=State(Path(sys.argv[1])); sweep(s)')
        subprocess.run([sys.executable, '-c', code, str(self.state.directory)],
                       check=True, capture_output=True)
        self.assertTrue(path.exists())
        with self.state.connect() as db:
            saved = db.execute('SELECT total,complete FROM upload_storage').fetchone()
        self.assertEqual(saved['total'], path.stat().st_size)
        self.assertEqual(saved['complete'], 1)
