"""Exercise the real pair command and private state for every user-facing flag."""
import argparse
import base64
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
from hermes_jr.cli import configure_parser, execute
from hermes_jr.state import State

class PairingEntrypointsTests(unittest.IsolatedAsyncioTestCase):
    async def test_default_browser_and_legacy_qr_all_return_a_page_not_terminal_art(self):
        for flags in [[], ['--browser'], ['--qr']]:
            with tempfile.TemporaryDirectory() as directory:
                state=State(Path(directory))
                state.settings({'relay_enabled':True,'service_url':'https://example.com','installation_id':'11111111-1111-4111-8111-111111111111','host_private_key':base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('=')})
                parser=argparse.ArgumentParser();configure_parser(parser)
                output=io.StringIO()
                with patch('hermes_jr.cli.State',return_value=state), patch('hermes_jr.service.Service.add_device',new_callable=AsyncMock,return_value={'device_id':'22222222-2222-4222-8222-222222222222','device_token':'A'*43}), patch('hermes_jr.pairing_page.sys.platform','darwin'), patch('hermes_jr.pairing_page.webbrowser.open',return_value=True) as browser, contextlib.redirect_stdout(output):
                    await execute(parser.parse_args(['pair','--no-wait',*flags]))
                browser.assert_called_once()
                page=list((Path(directory)/'pairing-pages').glob('*.html'))
                self.assertEqual(len(page),1)
                text=output.getvalue()
                self.assertIn('[Open your pairing page]('+page[0].resolve().as_uri()+')',text)
                self.assertNotIn('█',text)
                self.assertNotIn('hermes-jr://pair#',text)
                self.assertIn('<svg',page[0].read_text())
                self.assertIn('Do not request fingerprints or approval',text)
