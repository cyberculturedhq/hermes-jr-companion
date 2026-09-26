import unittest
from unittest.mock import patch
from signing_fixture import PUBLIC, signature
from hermes_jr.release_signature import verify, signature_from_body
from hermes_jr import installer

class ReleaseSignatureTests(unittest.TestCase):
    def test_signature_binds_version_and_commit(self):
        release = {'latest': '0.3.0', 'commit': 'a'*40, 'signature': signature()}
        with patch('hermes_jr.release_signature.PUBLIC_KEY', PUBLIC):
            verify(release)
            for key, value in [('latest','0.4.0'), ('commit','b'*40), ('signature','A'*88)]:
                with self.assertRaises(ValueError): verify({**release, key:value})
        with self.assertRaises(ValueError): verify(release)  # untrusted signing key

    def test_missing_signature_stops_before_installer_actions(self):
        with patch.object(installer, 'Supervisor') as manager:
            with self.assertRaises(ValueError):
                installer.install(None, {'state':'available','latest':'99.0.0','commit':'a'*40})
            manager.assert_not_called()

    def test_ambiguous_and_missing_markers_rejected(self):
        marker=f'<!-- hermes-jr-release-v1: {signature()} -->'
        self.assertEqual(signature_from_body(marker), signature())
        for body in [None, '', marker+marker]:
            with self.assertRaises(ValueError): signature_from_body(body)
