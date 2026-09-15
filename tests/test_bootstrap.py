import base64
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

repo = Path(__file__).resolve().parents[1]
script = repo / 'install.py' if (repo / 'install.py').exists() else repo.parent / 'Scripts/install-companion.py'
spec = importlib.util.spec_from_file_location('bootstrap', script)
bootstrap = importlib.util.module_from_spec(spec); spec.loader.exec_module(bootstrap)

class BootstrapTests(unittest.TestCase):
    def test_release_binds_commit_and_rejects_tampering(self):
        key = Ed25519PrivateKey.generate()
        commit = 'a' * 40
        signature = base64.b64encode(key.sign(f'hermes-jr-release-v1\n{bootstrap.REPO}\n0.12.0\n{commit}\n'.encode())).decode()
        release = {'tag_name': 'v0.12.0', 'body': '<!-- hermes-jr-release-v1: ' + signature + ' -->'}
        def fetch(path):
            return release if path == '/releases/latest' else {'object': {'sha': commit, 'type': 'commit'}}
        with patch.object(bootstrap, 'get_json', side_effect=fetch), patch.object(bootstrap, 'PUBLIC_KEY', key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()):
            self.assertEqual(bootstrap.release(), ('0.12.0', commit))
            commit = 'b' * 40
            with self.assertRaises(Exception): bootstrap.release()

    def test_unpublished_or_prerelease_does_not_install(self):
        for data in [{'tag_name':'v0.11.0'}, {'tag_name':'v0.12.0','prerelease':True}]:
            with patch.object(bootstrap, 'get_json', return_value=data), self.assertRaises(ValueError):
                bootstrap.release()

    def test_invalid_version_never_becomes_git_argument(self):
        for version in ['main', '../main', 'v0.12.0;echo x']:
            with self.assertRaises(ValueError): bootstrap.version(version)

    def test_python_discovery_checks_hermes_imports(self):
        with patch.object(bootstrap.subprocess, 'run') as run:
            run.return_value.returncode = 0
            path = bootstrap.hermes_python()
            self.assertTrue(Path(path).is_absolute())
            self.assertIn('import hermes_cli', run.call_args.args[0][-1])
