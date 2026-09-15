from signing_fixture import PUBLIC, signature
from email.message import Message
import json
from pathlib import Path
import shutil
import tempfile
import types
import unittest
from unittest.mock import Mock, patch
import zipfile
from hermes_jr import installer
from hermes_jr.recovery import Snapshot
from hermes_jr.state import State


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.state=State(self.root/'state')
        self.site=self.root/'site';self.site.mkdir()
        self.package=self.site/'hermes_jr';self.package.mkdir()
        (self.package/'code.py').write_text('old')
        self.old_meta=self.site/'hermes_jr_companion-0.3.0.dist-info';self.old_meta.mkdir()
        (self.old_meta/'METADATA').write_text('old metadata')
        self.bin=self.root/'bin';self.bin.mkdir();(self.bin/'hermes-jr').write_text('old executable')
        self.home=self.root/'home';self.plugin=self.home/'plugins/hermes-jr';self.plugin.mkdir(parents=True)
        (self.plugin/'plugin.yaml').write_text('old plugin')
        self.metadata=self.home/'plugins/.install-metadata.json';self.metadata.write_text('original metadata')
        (self.home/'config.yaml').write_text('user config')
        meta=Message();meta['Requires-Dist']='aiohttp<4,>=3.12'
        self.dist=types.SimpleNamespace(metadata=meta)
        self.manager=Mock(platform='darwin',domain='gui/123',label='fixture')
        self.manager.status.return_value={'bridge_running':True,'manager_active':True}
        key_patch=patch('hermes_jr.release_signature.PUBLIC_KEY',PUBLIC)
        key_patch.start();self.addCleanup(key_patch.stop)
        self.release={'signature':signature('0.4.0'),'state':'available','latest':'0.4.0','commit':'a'*40}
        self.stage_fail=None
        patches=[patch.object(installer,'Supervisor',return_value=self.manager),
                 patch.object(installer,'installed_profiles',return_value=[(self.home,self.plugin,self.metadata)]),
                 patch.object(installer,'verify_profile_copies'),
                 patch.object(installer,'package_layout',return_value=(self.dist,self.site,self.old_meta)),
                 patch.object(installer,'installed_version',return_value='0.3.0'),
                 patch.object(installer.sysconfig,'get_path',return_value=str(self.bin)),
                 patch.object(installer,'native_install',side_effect=self.native),
                 patch.object(installer,'run',side_effect=self.run_command)]
        for p in patches:p.start();self.addCleanup(p.stop)

    def native(self, home, commit, log):
        if home==self.home:
            (self.plugin/'plugin.yaml').write_text('name: hermes-jr\nversion: 0.4.0\n')
            self.metadata.write_text(json.dumps({'hermes-jr': {'revision': commit}}))
        else:
            candidate=home/'plugins/hermes-jr';candidate.mkdir(parents=True)
            (candidate/'COMPATIBILITY.json').write_text(json.dumps(installer.POLICY))

    def run_command(self, args, **kwargs):
        if 'wheel' in args:
            directory=Path(args[-1]);directory.mkdir()
            prefix='hermes_jr_companion-0.4.0.dist-info'
            with zipfile.ZipFile(directory/'candidate.whl','w') as z:
                z.writestr(prefix+'/METADATA','Name: hermes-jr-companion\nVersion: 0.4.0\nRequires-Dist: aiohttp<4,>=3.12\n')
                z.writestr(prefix+'/WHEEL','Root-Is-Purelib: true\n')
                z.writestr(prefix+'/entry_points.txt','[console_scripts]\nhermes-jr = hermes_jr.cli:main\n')
                z.writestr('hermes_jr/__init__.py','')
        elif 'pip' in args and 'install' in args:
            (self.package/'code.py').write_text('new')
            shutil.rmtree(self.old_meta)
            new=self.site/'hermes_jr_companion-0.4.0.dist-info';new.mkdir()
            (new/'METADATA').write_text('new metadata')
            (self.bin/'hermes-jr').write_text('new executable')
            if self.stage_fail=='pip':raise ValueError('injected pip failure')
        elif 'doctor' in args and self.stage_fail=='doctor':
            raise ValueError('injected doctor failure')

    def assert_old(self):
        self.assertEqual((self.package/'code.py').read_text(),'old')
        self.assertTrue(self.old_meta.exists())
        self.assertFalse((self.site/'hermes_jr_companion-0.4.0.dist-info').exists())
        self.assertEqual((self.bin/'hermes-jr').read_text(),'old executable')
        self.assertEqual((self.plugin/'plugin.yaml').read_text(),'old plugin')
        self.assertEqual(self.metadata.read_text(),'original metadata')
        self.assertEqual((self.home/'config.yaml').read_text(),'user config')

    def test_success_then_explicit_rollback(self):
        installer.install(self.state,self.release)
        self.assertEqual((self.package/'code.py').read_text(),'new')
        installer.rollback(self.state)
        self.assert_old()
        self.assertEqual(self.manager.start.call_count,2)

    def test_pip_failure_restores_all_installation_surfaces(self):
        self.stage_fail='pip'
        with self.assertRaisesRegex(ValueError,'previous companion was restored'):
            installer.install(self.state,self.release)
        self.assert_old()

    def test_validation_failure_restores_previous_package(self):
        self.stage_fail='doctor'
        with self.assertRaisesRegex(ValueError,'previous companion was restored'):
            installer.install(self.state,self.release)
        self.assert_old()

    def test_native_version_mismatch_rolls_back_package_and_profiles(self):
        native = self.native
        def wrong_version(home, commit, log):
            native(home, commit, log)
            if home == self.home:
                (self.plugin/'plugin.yaml').write_text('version: 0.3.0\n')
        with patch.object(installer, 'native_install', side_effect=wrong_version):
            with self.assertRaisesRegex(ValueError, 'previous companion was restored'):
                installer.install(self.state, self.release)
        self.assert_old()

    def test_startup_failure_restores_and_restarts_previous_service(self):
        self.manager.start.side_effect=[ValueError('new version failed startup'),None]
        with self.assertRaisesRegex(ValueError,'previous companion was restored'):
            installer.install(self.state,self.release)
        self.assert_old()
        self.assertEqual(self.manager.start.call_count,2)

    def test_preflight_race_never_overwrites_new_user_edits(self):
        def stop(): (self.plugin/'plugin.yaml').write_text('user edited while preparing')
        self.manager.stop.side_effect=stop
        with self.assertRaisesRegex(ValueError,'left unchanged'):
            installer.install(self.state,self.release)
        self.assertEqual((self.plugin/'plugin.yaml').read_text(),'user edited while preparing')
        self.assertEqual((self.package/'code.py').read_text(),'old')
        self.assertFalse((self.state.directory/'last-update.json').exists())

    def test_interrupted_apply_uses_saved_recovery(self):
        installer.install(self.state,self.release)
        snap=Snapshot(json.loads((self.state.directory/'last-update.json').read_text())['backup'])
        snap.save(phase='applying')
        (self.package/'code.py').write_text('partially replaced')
        installer.rollback(self.state)
        self.assert_old()
