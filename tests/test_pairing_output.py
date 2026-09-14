"""Fixed public fixtures only; rendering never contacts a service or creates invitations."""
import argparse
import base64
import hashlib
import io
import json
import os
import unittest
from unittest.mock import patch

from hermes_jr.cli import configure_parser, encoded, print_pairing


class PairingOutputTests(unittest.TestCase):
    def setUp(self):
        self.payload = {
            'v':1,'relay_url':'https://relay.example',
            'installation_id':'00000000-0000-4000-8000-000000000001',
            'device_id':'00000000-0000-4000-8000-000000000002',
            'device_token':encoded(b'device admission test fixture!!!'),
            'host_public_key':encoded(bytes(range(32))),
            'pairing_secret':encoded(b'pairing secret test fixture!!!!!!'),
            'expires_at':2000000000,
        }

    def test_json_stdout_stays_machine_readable_and_host_fingerprint_is_separate(self):
        out, err = io.StringIO(), io.StringIO()
        print_pairing(self.payload, out=out, err=err)
        self.assertEqual(json.loads(out.getvalue()), self.payload)
        self.assertIn('Host fingerprint (SHA256): ' + hashlib.sha256(bytes(range(32))).hexdigest(), err.getvalue())
        self.assertNotIn(self.payload['pairing_secret'], err.getvalue())

    def test_url_output_preserves_the_same_invitation(self):
        out, err = io.StringIO(), io.StringIO()
        print_pairing(self.payload, as_url=True, out=out, err=err)
        url = out.getvalue().strip()
        self.assertTrue(url.startswith('hermes-jr://pair#'))
        data = url.split('#', 1)[1]
        self.assertEqual(json.loads(base64.urlsafe_b64decode(data + '=' * (-len(data) % 4))), self.payload)
        self.assertIn('Host fingerprint (SHA256): ', err.getvalue())

    def test_pair_qr_flag_is_additive(self):
        parser = argparse.ArgumentParser()
        configure_parser(parser)
        self.assertFalse(parser.parse_args(['pair']).qr)
        self.assertTrue(parser.parse_args(['pair','--url']).url)
        self.assertTrue(parser.parse_args(['pair','--qr']).qr)


if __name__ == '__main__':
    unittest.main()
