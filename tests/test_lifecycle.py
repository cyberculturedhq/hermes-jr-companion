import argparse
import asyncio
import fcntl
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch
from hermes_jr.state import State
from hermes_jr.supervisor import Supervisor, bridge_running, private_write, unit_quote
from hermes_jr.updates import check, version
from hermes_jr.cli import configure_parser


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='jr service % $ ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = State(self.root / 'state')
        self.manager = Supervisor(self.state, home=self.root, platform='darwin')

    def test_launchd_uses_exact_venv_python_no_shell_and_no_secrets(self):
        value = plistlib.loads(self.manager.definition('/tmp/my venv/bin/python'))
        self.assertEqual(value['ProgramArguments'], ['/tmp/my venv/bin/python', '-m', 'hermes_jr.daemon', str(self.state.directory.resolve())])
        self.assertTrue(value['KeepAlive'])
        self.assertTrue(value['RunAtLoad'])
        self.assertEqual(value['ThrottleInterval'], 10)
        self.assertNotIn('EnvironmentVariables', value)
        self.assertEqual(value['Umask'], 0o077)

    def test_systemd_quotes_expansions_and_has_restart(self):
        manager = Supervisor(self.state, home=self.root, platform='linux')
        unit = manager.definition('/tmp/a % $ " \\ path/bin/python').decode()
        self.assertIn('Restart=always', unit)
        self.assertIn('RestartSec=10', unit)
        self.assertIn('%%', unit)
        self.assertIn('$$', unit)
        self.assertIn('UMask=0077', unit)
        self.assertNotIn('Environment=', unit)
        self.assertEqual(unit_quote('a\nb'), '"a\\nb"')

    def test_private_write_is_atomic_and_preserves_old_on_replace_failure(self):
        path = self.root / 'secret.json'
        private_write(path, b'old')
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with patch('hermes_jr.supervisor.os.replace', side_effect=OSError):
            with self.assertRaises(OSError):
                private_write(path, b'new')
        self.assertEqual(path.read_bytes(), b'old')
        self.assertEqual(list(self.root.glob('.secret.json*')), [])

    def test_lock_identifies_real_running_process_and_release(self):
        path = self.state.directory / 'bridge.lock'
        self.assertFalse(bridge_running(self.state.directory))
        with path.open('w') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            self.assertTrue(bridge_running(self.state.directory))
        self.assertFalse(bridge_running(self.state.directory))

    def test_unique_label_per_state(self):
        other = Supervisor(State(self.root / 'other'), home=self.root, platform='darwin')
        self.assertNotEqual(other.label, self.manager.label)

    def test_uninstall_stops_owned_service_and_preserves_pairing_state(self):
        self.state.settings({'host_token': 'test credential'})
        private_write(self.manager.path, self.manager.definition('/tmp/python'))
        private_write(self.manager.environment_path, b'{}')
        with patch.object(self.manager, 'stop') as stop:
            self.manager.uninstall()
        stop.assert_called_once()
        self.assertFalse(self.manager.path.exists())
        self.assertFalse(self.manager.environment_path.exists())
        self.assertEqual(self.state.get('host_token'), 'test credential')

    def test_install_requires_setup_before_any_manager_write(self):
        with self.assertRaisesRegex(ValueError, 'setup'):
            self.manager.install()
        self.assertFalse(self.manager.path.exists())

    def test_service_failure_does_not_echo_manager_output(self):
        with patch('hermes_jr.supervisor.subprocess.run', return_value=Mock(returncode=1, stderr='SECRET')):
            with self.assertRaises(ValueError) as exc:
                self.manager.command(['launchctl', 'test'])
        self.assertNotIn('SECRET', str(exc.exception))

    def test_parser_has_lifecycle_commands(self):
        parser = argparse.ArgumentParser()
        configure_parser(parser)
        self.assertEqual(parser.parse_args(['service', 'install']).service_action, 'install')
        self.assertEqual(parser.parse_args(['update', '--checks', 'off']).checks, 'off')
        self.assertEqual(parser.parse_args(['doctor']).jr_command, 'doctor')


class UpdateTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = State(Path(self.temp.name))
        self.version_patch = patch('hermes_jr.updates.installed_version', return_value='0.2.0')
        self.version_patch.start()
        self.addCleanup(self.version_patch.stop)

    async def test_new_release_uses_only_fixed_origin_and_commit(self):
        fetch = AsyncMock(side_effect=[{'tag_name': 'v0.3.0'}, {'object': {'type': 'commit', 'sha': 'a'*40}}])
        with patch('hermes_jr.updates.get_json', fetch):
            result = await check(self.state, None)
            again = await check(self.state, None)
        self.assertEqual(result['state'], 'available')
        self.assertEqual(result['commit'], 'a'*40)
        self.assertEqual(again, result)
        self.assertEqual(fetch.await_count, 2)
        self.assertTrue(all(call.args[1].startswith('https://api.github.com/repos/cyberculturedhq/hermes-jr-companion/') for call in fetch.await_args_list))

    async def test_missing_release_and_network_failure_do_not_crash_bridge(self):
        with patch('hermes_jr.updates.get_json', AsyncMock(return_value=None)):
            self.assertEqual((await check(self.state, None))['state'], 'no_stable_release')
        with patch('hermes_jr.updates.get_json', AsyncMock(side_effect=TimeoutError('SECRET'))):
            result = await check(self.state, None, force=True)
        self.assertEqual(result['state'], 'unavailable')
        self.assertNotIn('SECRET', json.dumps(result))

    async def test_malicious_tag_never_becomes_request_path(self):
        fetch = AsyncMock(return_value={'tag_name': '../../evil'})
        with patch('hermes_jr.updates.get_json', fetch):
            self.assertEqual((await check(self.state, None))['state'], 'unavailable')
        self.assertEqual(fetch.await_count, 1)

    async def test_annotated_release_tag_resolves_commit(self):
        fetch = AsyncMock(side_effect=[{'tag_name':'v0.3.0'}, {'object':{'type':'tag','sha':'b'*40}}, {'object':{'type':'commit','sha':'a'*40}}])
        with patch('hermes_jr.updates.get_json', fetch):
            self.assertEqual((await check(self.state, None))['commit'], 'a'*40)

    def test_prereleases_and_commands_are_not_versions(self):
        for text in ('v1.2.3-beta', '1.2', 'v1.2.3;sh', '01.2.3'):
            with self.assertRaises(ValueError):
                version(text)
