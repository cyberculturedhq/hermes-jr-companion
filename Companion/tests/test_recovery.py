from email.message import Message
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch
import zipfile
from hermes_jr.recovery import Snapshot, digest
from hermes_jr.installer import validate_wheel


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

    def wheel(self, *, requirement='aiohttp<4,>=3.12', extra=None, entry='hermes-jr = hermes_jr.cli:main'):
        wheel=self.root/'candidate.whl';prefix='hermes_jr_companion-0.4.0.dist-info'
        with zipfile.ZipFile(wheel,'w') as z:
            z.writestr(prefix+'/METADATA',f'Name: hermes-jr-companion\nVersion: 0.4.0\nRequires-Dist: {requirement}\n')
            z.writestr(prefix+'/WHEEL','Root-Is-Purelib: true\n')
            z.writestr(prefix+'/entry_points.txt','[console_scripts]\n'+entry+'\n')
            z.writestr('hermes_jr/__init__.py','')
            if extra:z.writestr(extra,'unexpected')
        metadata=Message();metadata['Requires-Dist']='aiohttp<4,>=3.12'
        return wheel,types.SimpleNamespace(metadata=metadata)

    def test_wheel_guards_package_and_dependency_ownership(self):
        wheel,dist=self.wheel()
        self.assertEqual(validate_wheel(wheel,'0.4.0',dist),'hermes_jr_companion-0.4.0.dist-info')
        for changes in ({'extra':'other_package/a.py'},{'extra':'hermes_jr/../../bad'},{'requirement':'aiohttp>=99'},{'entry':'other-command = hermes_jr.cli:main'}):
            wheel,dist=self.wheel(**changes)
            with self.assertRaises(ValueError):validate_wheel(wheel,'0.4.0',dist)
