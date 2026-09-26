import base64
from pathlib import Path
import tempfile
import unittest
import uuid
from hermes_jr.state import State
from hermes_jr.uploads import upload, MAX_BYTES, CHUNK_BYTES

class UploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = State(Path(self.temp.name))
        self.body = dict(upload_id=str(uuid.uuid4()), filename='report.pdf', offset=0,
                         total=6, content_base64=base64.b64encode(b'abc').decode())

    def test_chunks_and_device_isolation(self):
        first = upload(self.state, 'a', self.body)
        self.assertEqual(first, {'offset': 3, 'complete': False, 'path': None})
        with self.assertRaises(FileNotFoundError):
            upload(self.state, 'b', dict(self.body, offset=3))
        second = upload(self.state, 'a', dict(self.body, offset=3))
        self.assertTrue(second['complete'])
        self.assertEqual(Path(second['path']).read_bytes(), b'abcabc')
        self.assertEqual(Path(second['path']).stat().st_mode & 0o777, 0o600)

    def test_retries_do_not_append_or_overwrite(self):
        upload(self.state, 'a', self.body)
        with self.assertRaises(FileExistsError):
            upload(self.state, 'a', self.body)
        with self.assertRaises(ValueError):
            upload(self.state, 'a', dict(self.body, offset=2))
        result = upload(self.state, 'a', dict(self.body, offset=3))
        self.assertEqual(Path(result['path']).read_bytes(), b'abcabc')

    def test_invalid_paths_sizes_and_data(self):
        for changes in [dict(filename='../x'), dict(filename='/tmp/x'), dict(filename='..'),
                        dict(filename='a\nb'), dict(upload_id='../x'), dict(offset=-1),
                        dict(total=MAX_BYTES+1), dict(total=0), dict(total=2),
                        dict(content_base64='!'), dict(content_base64=''),
                        dict(content_base64=base64.b64encode(b'x'*(CHUNK_BYTES+1)).decode())]:
            with self.subTest(changes=list(changes)):
                with self.assertRaises(ValueError):
                    upload(self.state, 'a', dict(self.body, **changes))
        self.assertFalse((self.state.directory / 'uploads').exists())

if __name__ == '__main__': unittest.main()
