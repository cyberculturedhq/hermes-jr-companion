"""Hermes PM update publication and recovery across profile copies."""
from signing_fixture import PUBLIC, signature
import base64
import json
from pathlib import Path
import tempfile
import time
import unittest
import uuid
from unittest.mock import Mock, patch

from hermes_jr import installer, update_requests
from hermes_jr.recovery import Snapshot
from hermes_jr.state import State


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.state = State(self.root / 'state')
        self.homes = [self.root / 'default', self.root / 'profiles/other']
        self.profiles = []
        for home in self.homes:
            plugin = home / 'plugins/hermes-jr'
            plugin.mkdir(parents=True)
            (plugin / 'plugin.yaml').write_text('version: 0.3.0\n')
            metadata = home / 'plugins/.install-metadata.json'
            metadata.write_text(json.dumps({'hermes-jr': {
                'source': installer.PLUGIN_SOURCE, 'revision': 'b' * 40}}))
            self.profiles.append((home, plugin, metadata))
        self.active = [self.homes[0]]
        self.selected = '0.3.0'
        self.events = []
        self.failure = None
        self.manager = Mock(platform='darwin', domain='gui/123', label='fixture')
        self.manager.status.return_value = {'bridge_running': True, 'manager_active': True}
        self.release = {'signature': signature('0.4.0'), 'state': 'available',
                        'latest': '0.4.0', 'commit': 'a' * 40}
        for target, name, kwargs in [
            (installer, 'Supervisor', {'return_value': self.manager}),
            (installer, 'installed_profiles', {'return_value': self.profiles}),
            (installer, 'active_homes', {'side_effect': lambda _: list(self.active)}),
            (installer, 'verify_profile_copies', {}),
            (installer, 'validate_candidate', {}),
            (installer, 'managed_version', {'side_effect': lambda: self.selected}),
            (installer, 'native_install', {'side_effect': self.native}),
            (installer, 'hermes', {'side_effect': self.hermes}),
            (installer, 'verify_package', {'side_effect': self.verify}),
            (installer, 'refresh_service', {}),
            (installer, 'verify_connection', {}),
        ]:
            p = patch.object(target, name, **kwargs)
            p.start()
            self.addCleanup(p.stop)
        key = patch('hermes_jr.release_signature.PUBLIC_KEY', PUBLIC)
        key.start()
        self.addCleanup(key.stop)

    def native(self, home, commit, log):
        self.events.append(('install', home))
        if self.failure == 'install' and home == self.homes[1]:
            raise ValueError('injected install failure')
        plugin = home / 'plugins/hermes-jr'
        plugin.mkdir(parents=True, exist_ok=True)
        (plugin / 'plugin.yaml').write_text('version: 0.4.0\n')
        (plugin / 'COMPATIBILITY.json').write_text(json.dumps(installer.POLICY))
        (home / 'plugins/.install-metadata.json').write_text(json.dumps({'hermes-jr': {
            'source': installer.PLUGIN_SOURCE, 'revision': commit}}))

    def hermes(self, home, log, *args):
        action = args[1]
        self.events.append((action, home))
        if action == 'disable':
            self.active.remove(home)
            self.selected = None
        elif action == 'enable':
            self.active.append(home)
            self.selected = '0.4.0' if '0.4.0' in (home / 'plugins/hermes-jr/plugin.yaml').read_text() else '0.3.0'

    def verify(self, expected, profiles, commit, log):
        self.events.append(('verify', expected))
        if self.selected != expected or (self.failure == 'verify' and expected == '0.4.0'):
            raise ValueError('PM package mismatch')
        for _, plugin, _ in profiles:
            if expected not in (plugin / 'plugin.yaml').read_text():
                raise ValueError('plugin package mismatch')

    def assert_restored(self):
        self.assertEqual(self.active, [self.homes[0]])
        self.assertEqual(self.selected, '0.3.0')
        for _, plugin, metadata in self.profiles:
            self.assertEqual((plugin / 'plugin.yaml').read_text(), 'version: 0.3.0\n')
            self.assertEqual(json.loads(metadata.read_text())['hermes-jr']['revision'], 'b' * 40)

    def test_update_and_rollback_cover_all_profiles(self):
        installer.install(self.state, self.release)
        self.assertEqual(self.active, [self.homes[0]])
        self.assertEqual(self.selected, '0.4.0')
        self.assertEqual(self.events[1:5], [('disable', self.homes[0]),
                                           ('install', self.homes[0]),
                                           ('install', self.homes[1]),
                                           ('enable', self.homes[0])])
        installer.rollback(self.state)
        self.assert_restored()

    def test_failed_install_restores_profile_copies_and_pm_selection(self):
        self.failure = 'install'
        with self.assertRaisesRegex(ValueError, 'previous companion was restored'):
            installer.install(self.state, self.release)
        self.assert_restored()

    def test_failed_verification_restores_previous_selection(self):
        self.failure = 'verify'
        with self.assertRaisesRegex(ValueError, 'previous companion was restored'):
            installer.install(self.state, self.release)
        self.assert_restored()

    def test_all_disabled_copies_stop_before_source_replacement(self):
        self.active.clear()
        with self.assertRaisesRegex(ValueError, 'No Hermes Jr profile is enabled'):
            installer.install(self.state, self.release)
        self.assertFalse(self.events)

    def test_guided_receipt_completes_after_pm_verification(self):
        device = str(uuid.uuid4())
        self.state.add_device(device, 'Phone', 'fixture', paired=True)
        self.state.set('push_enabled', True)
        self.state.set_push(device, True)
        receipt = dict(id=str(uuid.uuid4()), device_id=device, profile='default',
                       session_id='update-chat', target='0.4.0', notify=True,
                       created=time.time())
        encoded = base64.urlsafe_b64encode(json.dumps(receipt).encode()).decode().rstrip('=')
        update_requests.run_tracked(self.state, self.release, encoded)
        journal = Snapshot(json.loads((self.state.directory / 'last-update.json').read_text())['backup']).journal
        self.assertEqual(journal['update_request'], receipt['id'])
        self.assertEqual(journal['phase'], 'complete')
        self.assertEqual(update_requests.status(self.state, device, receipt['id'])['status'], 'completed')
        self.assertEqual(len(self.state.outbox()), 1)
