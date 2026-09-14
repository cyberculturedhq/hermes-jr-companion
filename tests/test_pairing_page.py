import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import tempfile
import time
import unittest
from unittest.mock import patch
from hermes_jr.pairing_page import render, create_page, open_page
from hermes_jr.cli import configure_parser

class PairingPageTests(unittest.TestCase):
    def setUp(self):
        self.payload={'v':1,'relay_url':'https://example.com','installation_id':'11111111-1111-4111-8111-111111111111',
         'device_id':'22222222-2222-4222-8222-222222222222','device_token':'A'*43,'host_public_key':'A'*43,
         'pairing_secret':'B'*43,'expires_at':int(time.time())+600}

    def test_self_contained_qr_identity_and_expiry(self):
        page=render(self.payload)
        self.assertIn('<svg',page)
        self.assertIn('Hermes Jr.',page)
        self.assertIn('Your phone will connect automatically.',page)
        self.assertNotIn('fingerprint',page)
        self.assertNotIn('<img',page)
        self.assertNotIn('src=',page)
        self.assertNotIn('https://example.com',page)
        script=re.search(r'<script>(.*?)</script>',page,re.S).group(1)
        expected=base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
        self.assertIn("script-src 'sha256-"+expected+"'",page)
        self.assertIn(str(self.payload['expires_at']),script)
        self.assertIn('replaceChildren()',script)

    def test_private_unique_files_and_expired_page_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            one=create_page(self.payload,temp)
            self.assertEqual(one.stat().st_mode & 0o777,0o600)
            self.assertEqual(one.parent.stat().st_mode & 0o777,0o700)
            keep=one.parent/'notes.html';keep.write_text('keep')
            os.utime(one,(time.time()-700,time.time()-700))
            two=create_page(self.payload,temp)
            self.assertNotEqual(one,two)
            self.assertFalse(one.exists());self.assertTrue(keep.exists())

    def test_headless_fallback_keeps_downloadable_page(self):
        with tempfile.TemporaryDirectory() as temp, patch('hermes_jr.pairing_page.sys.platform', 'darwin'), patch('hermes_jr.pairing_page.webbrowser.open',return_value=False) as browser, patch('builtins.print') as output:
            path=open_page(self.payload,temp)
            browser.assert_called_once_with(path.as_uri(),new=2)
            self.assertTrue(path.exists())
            self.assertTrue(any('could not be opened' in str(call) for call in output.call_args_list))

    def test_headless_linux_never_launches_a_text_browser(self):
        with tempfile.TemporaryDirectory() as temp, patch('hermes_jr.pairing_page.sys.platform', 'linux'), patch.dict(os.environ, {}, clear=True), patch('hermes_jr.pairing_page.webbrowser.open') as browser, patch('builtins.print'):
            self.assertTrue(open_page(self.payload,temp).exists())
            browser.assert_not_called()

    def test_explicit_machine_formats_do_not_mix(self):
        parser=argparse.ArgumentParser();configure_parser(parser)
        self.assertTrue(parser.parse_args(['pair','--browser']).browser)
        self.assertTrue(parser.parse_args(['pair','--json']).json)
        with self.assertRaises(SystemExit):parser.parse_args(['pair','--json','--browser'])
