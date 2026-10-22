import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).resolve().parents[1] / 'tools/publish_release_feed.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
RELEASE = {'schema': 1, 'version': '0.19.1', 'commit': '3f14aa702d9f726fa7947daa8670256e0df42bfa',
           'signature': 'mW9tweQnSw84m7LdsFLtzYQWqyKhD2/C1V0AvkLriMdSttNabCkfCBdEezBPCJ9H1bywze6CnApsvxtUpq0eDA=='}
PACKAGE = {'info': {'version': '0.19.1'}, 'urls': [{'packagetype': 'bdist_wheel', 'yanked': False}]}

class ReleasePublisherTests(unittest.TestCase):
    def test_published_package_precedes_feed_write_and_public_verification(self):
        with patch.object(publisher, 'request_json', side_effect=[PACKAGE, {}, RELEASE]) as request:
            self.assertEqual(publisher.publish(RELEASE, 't' * 43), '0.19.1')
        self.assertTrue(request.call_args_list[0].args[0].startswith('https://pypi.org/pypi/'))
        self.assertEqual(request.call_args_list[1].args[0], publisher.FEED + '/publish')
        self.assertEqual(request.call_args_list[2].args[0], publisher.FEED)
        self.assertNotIn('token', request.call_args_list[0].kwargs)
        self.assertNotIn('token', request.call_args_list[2].kwargs)

    def test_unsigned_manifest_or_missing_package_never_reaches_feed_write(self):
        with patch.object(publisher, 'request_json') as request:
            with self.assertRaises(ValueError):
                publisher.publish({**RELEASE, 'version': '9.0.0'}, 't' * 43)
            request.assert_not_called()
        for package in [{}, {**PACKAGE, 'urls': []}, {**PACKAGE, 'urls': [{'packagetype': 'bdist_wheel', 'yanked': True}]}]:
            with patch.object(publisher, 'request_json', return_value=package) as request:
                with self.assertRaises(ValueError): publisher.publish(RELEASE, 't' * 43)
                self.assertEqual(request.call_count, 1)

    def test_redirect_is_not_followed_with_publication_token(self):
        handler = publisher.NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, None, None, None, None))
        redirect = urllib.error.HTTPError(publisher.FEED, 302, 'Redirect', {}, None)
        with patch.object(publisher, 'request_json', side_effect=[PACKAGE, redirect]) as request:
            with self.assertRaises(urllib.error.HTTPError): publisher.publish(RELEASE, 't' * 43)
            self.assertEqual(request.call_count, 2)

    def test_public_response_must_pass_the_signature_check(self):
        with patch.object(publisher, 'request_json', side_effect=[PACKAGE, {}, {**RELEASE, 'commit': 'a' * 40}]):
            with self.assertRaises(ValueError): publisher.publish(RELEASE, 't' * 43)
