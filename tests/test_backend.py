from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from hermes_jr.backend import BackendSupervisor
from hermes_jr.state import State


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.state = State(self.home / 'companion')
        self.state.settings({'dashboard_url': 'http://127.0.0.1:19119'})
        self.profile = self.home / 'Hermes profile'
        self.profile.mkdir()

    def manager(self, platform='darwin'):
        return BackendSupervisor(self.state, home=self.home, platform=platform, hermes_home=self.profile)

    def test_service_uses_loopback_and_selected_profile_without_shell(self):
        value = plistlib.loads(self.manager().definition())
        self.assertEqual(value['ProgramArguments'][-5:], ['serve', '--host', '127.0.0.1', '--port', '19119'])
        self.assertEqual(value['EnvironmentVariables'], {'HERMES_HOME': str(self.profile.resolve())})
        self.assertTrue(value['KeepAlive'])
        self.assertNotIn('sh', value['ProgramArguments'])

    @patch('hermes_jr.backend.importlib.util.find_spec', return_value=object())
    def test_install_preserves_existing_listener(self, spec):
        manager = self.manager()
        with patch.object(manager, 'active', return_value=False), patch.object(manager, 'listening', return_value=True), patch.object(manager, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'already has a listener'):
                manager.install()
            command.assert_not_called()
        self.assertFalse(manager.path.exists())

    @patch('hermes_jr.backend.importlib.util.find_spec', return_value=object())
    def test_install_preserves_changed_definition_and_uninstall_refuses_it(self, spec):
        manager = self.manager()
        manager.path.parent.mkdir(parents=True)
        manager.path.write_bytes(b'existing owner configuration')
        with self.assertRaisesRegex(ValueError, 'not overwritten'):
            manager.install()
        with self.assertRaisesRegex(ValueError, 'changed'):
            manager.uninstall()
        self.assertEqual(manager.path.read_bytes(), b'existing owner configuration')

    @patch('hermes_jr.backend.importlib.util.find_spec', return_value=object())
    def test_registration_is_bounded_and_repeated_install_is_idempotent(self, spec):
        for platform in ('darwin', 'linux'):
            with self.subTest(platform=platform):
                manager = self.manager(platform)
                with patch.object(manager, 'active', return_value=False), patch.object(manager, 'listening', return_value=False), patch('hermes_jr.backend.subprocess.run', return_value=subprocess.CompletedProcess([], 0)) as run:
                    manager.install()
                    self.assertEqual(manager.path.stat().st_mode & 0o777, 0o600)
                    self.assertTrue(all(call.kwargs['timeout'] == 15 for call in run.call_args_list))
                    self.assertTrue(all(call.args[0][0] in ('launchctl', 'systemctl') for call in run.call_args_list))
                before = manager.path.read_bytes()
                with patch.object(manager, 'active', return_value=True), patch.object(manager, 'command') as command:
                    manager.install()
                    command.assert_not_called()
                self.assertEqual(manager.path.read_bytes(), before)

    def test_status_does_not_claim_rpc_health_from_an_open_port(self):
        manager = self.manager()
        with patch.object(manager, 'active', return_value=True), patch.object(manager, 'listening', return_value=True):
            status = manager.status()
        self.assertNotIn('dashboard_rpc', status)
        self.assertIn('doctor', status['next_step'])

    @patch('hermes_jr.backend.importlib.util.find_spec', return_value=object())
    def test_unavailable_manager_fails_promptly(self, spec):
        manager = self.manager()
        with patch('hermes_jr.backend.subprocess.run', side_effect=subprocess.TimeoutExpired('launchctl', 15)):
            with self.assertRaisesRegex(ValueError, 'manager unavailable'):
                manager.install()

    def test_rejects_public_or_custom_tls_backends(self):
        for origin in ('http://example.com:9119', 'https://127.0.0.1:9119', 'http://127.0.0.1:0'):
            self.state.settings({'dashboard_url': origin})
            with self.assertRaises(ValueError):
                self.manager()

    def test_systemd_escapes_profile_path_and_has_no_shell(self):
        manager = BackendSupervisor(self.state, home=self.home, platform='linux', hermes_home=self.home / 'profile % $ name')
        text = manager.definition().decode()
        self.assertIn('%%', text)
        self.assertIn('Restart=always', text)
        self.assertIn('WantedBy=default.target', text)
        self.assertNotIn('/bin/sh', text)

    @patch('hermes_jr.backend.importlib.util.find_spec', return_value=object())
    def test_repairs_only_exact_legacy_systemd_definition(self, spec):
        manager = self.manager('linux')
        manager.path.parent.mkdir(parents=True)
        legacy = manager.definition(legacy_workdir=True)
        manager.path.write_bytes(legacy)
        with patch.object(manager, 'active', return_value=False), patch.object(manager, 'listening', return_value=False), patch.object(manager, 'command'):
            manager.install()
        self.assertEqual(manager.path.read_bytes(), manager.definition())
        manager.path.write_bytes(legacy + b'Environment=OWNER_SETTING=1\n')
        with self.assertRaisesRegex(ValueError, 'not overwritten'):
            manager.install()
        self.assertEqual(manager.path.read_bytes(), legacy + b'Environment=OWNER_SETTING=1\n')

    def test_uninstall_only_removes_its_own_service(self):
        manager = self.manager()
        manager.path.parent.mkdir(parents=True)
        manager.path.write_bytes(manager.definition())
        unrelated = manager.path.parent / 'ai.hermes.gateway.plist'
        unrelated.write_bytes(b'gateway')
        with patch.object(manager, 'active', return_value=True), patch.object(manager, 'command') as command:
            manager.uninstall()
            command.assert_called_once_with(['launchctl', 'bootout', f'{manager.domain}/{manager.label}'])
        self.assertFalse(manager.path.exists())
        self.assertEqual(unrelated.read_bytes(), b'gateway')

    def test_python_alias_in_same_venv_preserves_service_ownership(self):
        executable = self.home / 'venv/bin/python'
        executable.parent.mkdir(parents=True)
        executable.write_text('interpreter')
        alias = executable.with_name('python3')
        alias.symlink_to(executable)
        other = self.home / 'other-venv/bin/python'
        other.parent.mkdir(parents=True)
        other.symlink_to(executable)
        for platform in ('darwin', 'linux'):
            manager = self.manager(platform)
            manager.path.parent.mkdir(parents=True, exist_ok=True)
            manager.path.write_bytes(manager.definition(executable))
            with patch('hermes_jr.backend.sys.executable', str(alias)):
                self.assertTrue(manager.owns_definition())
                manager.path.write_bytes(manager.definition(other))
                self.assertFalse(manager.owns_definition())
                manager.path.write_bytes(manager.definition(executable) + b'changed')
                self.assertFalse(manager.owns_definition())

    def test_identical_copied_python_in_same_venv_is_an_alias(self):
        executable = self.home / 'venv/bin/python'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'interpreter binary')
        copied = executable.with_name('python3')
        shutil.copyfile(executable, copied)
        self.assertFalse(copied.samefile(executable))
        for platform in ('darwin', 'linux'):
            manager = self.manager(platform)
            manager.path.parent.mkdir(parents=True, exist_ok=True)
            manager.path.write_bytes(manager.definition(copied))
            with patch('hermes_jr.backend.sys.executable', str(executable)):
                self.assertTrue(manager.owns_definition())
                copied.write_bytes(b'different interpreter')
                self.assertFalse(manager.owns_definition())
                copied.write_bytes(executable.read_bytes())
