import contextlib
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
from hermes_jr import handoff as h


class HandoffTests(unittest.TestCase):
    def setUp(self):
        h._tickets.clear()
        self.owner = dict(pid=12345, process_start_time=10.0, surface='cli',
                          session_id='saved', lease_id='lease', metadata={'live_session_id': 'saved'})
        self.registry = Mock()
        self.registry.active_session_registry_snapshot.return_value = [self.owner]
        self.registry._read_entries.return_value = [self.owner]
        self.registry._FileLock.return_value = contextlib.nullcontext()
        self.proc = Mock()
        self.proc.create_time.return_value = 10.0
        self.proc.uids.return_value.real = os.getuid()
        self.proc.terminal.return_value = '/dev/ttys001'
        self.proc.cmdline.return_value = ['/venv/python', '/hermes/hermes']
        self.psutil = Mock(Error=RuntimeError, TimeoutExpired=TimeoutError)
        self.psutil.Process.return_value = self.proc
        self.patch = patch.object(h, '_runtime', return_value=(self.registry, self.psutil, Path('/profile'), Path('/hermes/hermes')))
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def preview(self):
        return h.preview('phone', 'default', 'saved')['ticket']

    def test_preview_never_signals(self):
        self.preview()
        self.proc.terminate.assert_not_called()

    def test_success_waits_for_exit_then_checks_owner(self):
        token = self.preview()
        self.registry.active_session_registry_snapshot.return_value = []
        self.assertTrue(h.commit('phone', 'default', 'saved', token)['ready'])
        self.proc.terminate.assert_called_once_with()
        self.proc.wait.assert_called_once_with(timeout=15)
        with self.assertRaises(h.HandoffUnavailable):
            h.commit('phone', 'default', 'saved', token)

    def test_ticket_is_device_profile_and_session_bound(self):
        for device, profile, session in [('other', 'default', 'saved'), ('phone', 'other', 'saved'), ('phone', 'default', 'other')]:
            with self.assertRaises(h.HandoffUnavailable):
                h.commit(device, profile, session, self.preview())
        self.proc.terminate.assert_not_called()

    def test_expired_confirmation_does_not_signal(self):
        token = self.preview()
        h._tickets[token]['expires'] = 0
        with self.assertRaises(h.HandoffUnavailable):
            h.commit('phone', 'default', 'saved', token)
        self.proc.terminate.assert_not_called()

    def test_changed_lease_or_reused_pid_does_not_signal(self):
        token = self.preview()
        self.registry._read_entries.return_value = [{**self.owner, 'lease_id': 'new'}]
        with self.assertRaises(h.HandoffUnavailable):
            h.commit('phone', 'default', 'saved', token)
        self.registry._read_entries.return_value = [self.owner]
        token = self.preview()
        self.proc.create_time.return_value = 11.0
        with self.assertRaises(h.HandoffUnavailable):
            h.commit('phone', 'default', 'saved', token)
        self.proc.terminate.assert_not_called()

    def test_shared_server_and_noninteractive_processes_are_excluded(self):
        self.registry.active_session_registry_snapshot.return_value = [{**self.owner, 'surface': 'desktop'}]
        with self.assertRaises(h.HandoffUnavailable): self.preview()
        self.registry.active_session_registry_snapshot.return_value = [self.owner]
        for args in [['/python', '/hermes/hermes', 'dashboard'], ['/python', '/hermes/hermes', '-q', 'task'], ['/python', '/other/script']]:
            self.proc.cmdline.return_value = args
            with self.assertRaises(h.HandoffUnavailable): self.preview()
        self.proc.terminate.assert_not_called()

    def test_shutdown_timeout_never_forces_kill_or_reports_ready(self):
        token = self.preview()
        self.proc.wait.side_effect = TimeoutError()
        with self.assertRaises(h.HandoffUnavailable):
            h.commit('phone', 'default', 'saved', token)
        self.proc.kill.assert_not_called()

    def test_new_owner_during_shutdown_prevents_resume(self):
        token = self.preview()
        self.registry.active_session_registry_snapshot.return_value = [{**self.owner, 'pid': 54321}]
        with self.assertRaises(h.HandoffUnavailable):
            h.commit('phone', 'default', 'saved', token)

    def test_no_owner_is_already_ready(self):
        self.registry.active_session_registry_snapshot.return_value = []
        self.assertEqual(h.preview('phone', 'default', 'saved'), {'ready': True})
        self.proc.terminate.assert_not_called()


if __name__ == '__main__': unittest.main()
