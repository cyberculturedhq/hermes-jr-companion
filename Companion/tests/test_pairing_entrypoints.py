import argparse
import contextlib
import io
import unittest
from hermes_jr.cli import configure_parser

class PairingEntrypointsTests(unittest.TestCase):
    def test_only_ticket_or_watch_can_start_pair_command(self):
        parser = argparse.ArgumentParser(); configure_parser(parser)
        for args in [[], ['--qr'], ['--browser'], ['--json'], ['--url'], ['--no-wait'], ['--status']]:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                parser.parse_args(['pair', *args])
        self.assertEqual(parser.parse_args(['pair', '--ticket', 'HJ1.fixture']).ticket, 'HJ1.fixture')
        self.assertTrue(parser.parse_args(['pair', '--ticket', 'HJ1.fixture', '--status']).status)
        self.assertEqual(parser.parse_args(['pair', '--watch', 'a'*64]).watch, 'a'*64)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(['approve', 'phone', '--fingerprint', 'a'*64])
