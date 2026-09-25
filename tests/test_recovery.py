from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from hermes_jr import recovery
from hermes_jr.recovery import Snapshot, digest


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / 'hermes_jr'
        self.package.mkdir()
        (self.package/'code.py').write_text('old code')
        self.new_meta = self.root/'new.dist-info'
        self.profile = self.root/'plugin'
        self.profile.mkdir()
        (self.profile/'plugin.yaml').write_text('old manifest')
        self.state = self.root/'private.sqlite3'
        self.state.write_text('pairings and live state')

    def snapshot(self):
        return Snapshot.create(self.root/'backup', [self.package,self.new_meta,self.profile], state_directory=str(self.root))

    def test_failed_update_restores_all_code_without_restoring_live_data(self):
        snapshot = self.snapshot()
        snapshot.save(phase='applying')
        (self.package/'code.py').write_text('broken code')
        (self.package/'new.py').write_text('new code')
        self.new_meta.mkdir()
        (self.new_meta/'METADATA').write_text('new metadata')
        (self.profile/'plugin.yaml').write_text('new manifest')
        self.state.write_text('a newly revoked phone must stay revoked')
        snapshot.restore(check_current=False)
        self.assertEqual((self.package/'code.py').read_text(),'old code')
        self.assertFalse((self.package/'new.py').exists())
        self.assertFalse(self.new_meta.exists())
        self.assertEqual((self.profile/'plugin.yaml').read_text(),'old manifest')
        self.assertEqual(self.state.read_text(),'a newly revoked phone must stay revoked')

    def test_manual_rollback_refuses_local_edits_after_update(self):
        snapshot=self.snapshot()
        (self.package/'code.py').write_text('new code')
        snapshot.complete()
        (self.profile/'plugin.yaml').write_text('user edit')
        with self.assertRaises(ValueError): snapshot.restore()
        self.assertEqual((self.profile/'plugin.yaml').read_text(),'user edit')
        self.assertEqual((self.package/'code.py').read_text(),'new code')

    def test_corrupt_backup_rejected_before_any_replacement(self):
        snapshot=self.snapshot()
        (self.package/'code.py').write_text('new code')
        snapshot.complete()
        (self.root/'backup/0/code.py').write_text('tampered')
        with self.assertRaises(ValueError): snapshot.restore()
        self.assertEqual((self.package/'code.py').read_text(),'new code')

    def test_compiled_caches_do_not_prevent_rollback(self):
        snapshot=self.snapshot()
        snapshot.complete()
        (self.package/'__pycache__').mkdir()
        (self.package/'__pycache__/x.pyc').write_bytes(b'cache')
        snapshot.restore()
        self.assertFalse((self.package/'__pycache__').exists())

    def test_snapshot_rejects_links_and_overlapping_targets(self):
        link=self.root/'link';link.symlink_to(self.package)
        with self.assertRaises(ValueError):Snapshot.create(self.root/'backup1',[link])
        with self.assertRaises(ValueError):Snapshot.create(self.root/'backup2',[self.package,self.package/'code.py'])

    def test_interrupted_restore_can_be_repeated(self):
        snapshot=self.snapshot()
        snapshot.save(phase='restoring')
        (self.package/'code.py').write_text('partial')
        Snapshot(self.root/'backup').restore(check_current=False)
        self.assertEqual((self.package/'code.py').read_text(),'old code')

    def test_emergency_recovery_reselects_previous_pm_package(self):
        snapshot = Snapshot.create(self.root/'backup', [self.profile],
                                   state_directory=str(self.root),
                                   enabled_homes=[str(self.root)])
        (self.profile/'plugin.yaml').write_text('new manifest')
        snapshot.complete()
        envs = types.ModuleType('pm.environments')
        envs.project_python = lambda _: Path('/hermes/python')
        main = types.ModuleType('hermes_cli.main')
        main.PROJECT_ROOT = self.root
        with patch.object(recovery, '__file__', str(snapshot.directory/'recover.py')), \
             patch.object(recovery.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)) as run, \
             patch.dict(sys.modules, {'pm': types.ModuleType('pm'), 'pm.environments': envs,
                                      'hermes_cli': types.ModuleType('hermes_cli'), 'hermes_cli.main': main}):
            recovery.emergency_recover()
        self.assertEqual((self.profile/'plugin.yaml').read_text(), 'old manifest')
        self.assertEqual([call.args[0][4] for call in run.call_args_list], ['disable', 'enable'])
