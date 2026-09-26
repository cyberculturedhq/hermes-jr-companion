import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from hermes_jr import installation_health as health


class InstallationHealthTests(unittest.TestCase):
    def test_every_installed_profile_must_match_package(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(health, 'installed_version', return_value='0.11.0'):
            root=Path(temp)
            for home, version in [(root,'0.11.0'),(root/'profiles/work','0.10.0')]:
                path=home/'plugins/hermes-jr';path.mkdir(parents=True)
                (path/'plugin.yaml').write_text('name: hermes-jr\nversion: '+version+'\n')
            self.assertEqual(health.check(root)['status'],'mismatch')
            (root/'profiles/work/plugins/hermes-jr/plugin.yaml').write_text('version: 0.11.0\n')
            self.assertEqual(health.check(root)['status'],'consistent')

    def test_missing_manifest_and_corrupt_version_fail(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(health, 'installed_version', return_value='0.11.0'):
            root=Path(temp)
            self.assertEqual(health.check(root)['status'],'missing')
            path=root/'plugins/hermes-jr';path.mkdir(parents=True)
            (path/'plugin.yaml').write_text('version: unexpected\n')
            self.assertEqual(health.check(root)['status'],'mismatch')

    def test_pairing_gate_rejects_inconsistency(self):
        with patch.object(health,'check',return_value={'status':'mismatch'}):
            with self.assertRaisesRegex(ValueError,'no pairing attempt'):health.require_consistent()


class UninstallHookTests(unittest.TestCase):
    def test_loaded_hooks_do_not_recreate_state_after_native_removal(self):
        from hermes_jr.plugin import register
        with tempfile.TemporaryDirectory() as temp:
            native=Path(temp)/'plugin';native.mkdir()
            ctx=Mock();ctx.manifest.path=str(native)
            hooks={}
            ctx.register_hook.side_effect=lambda name, callback: hooks.__setitem__(name,callback)
            register(ctx)
            native.rmdir()
            with patch('hermes_jr.plugin.State',side_effect=AssertionError('recreated removed state')):
                hooks['on_session_end'](session_id='test',completed=True,turn_id='turn')
