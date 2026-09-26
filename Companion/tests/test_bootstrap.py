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
        signature = base64.b64encode(key.sign(f'hermes-jr-release-v1\n{bootstrap.REPO}\n0.15.0\n{commit}\n'.encode())).decode()
        release = {'tag_name': 'v0.15.0', 'body': '<!-- hermes-jr-release-v1: ' + signature + ' -->'}
        def fetch(path):
            return release if path == '/releases/latest' else {'object': {'sha': commit, 'type': 'commit'}}
        with patch.object(bootstrap, 'get_json', side_effect=fetch), patch.object(bootstrap, 'PUBLIC_KEY', key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()):
            self.assertEqual(bootstrap.release()['commit'], commit)
            commit = 'b' * 40
            with self.assertRaises(Exception): bootstrap.release()

    def test_unpublished_or_prerelease_does_not_install(self):
        for data in [{'tag_name':'v0.11.0'}, {'tag_name':'v0.15.0','prerelease':True}]:
            with patch.object(bootstrap, 'get_json', return_value=data), self.assertRaises(ValueError):
                bootstrap.release()

    def test_invalid_version_never_becomes_git_argument(self):
        for version in ['main', '../main', 'v0.15.0;echo x']:
            with self.assertRaises(ValueError): bootstrap.version(version)

    def test_python_discovery_checks_hermes_imports(self):
        with patch.object(bootstrap.subprocess, 'run') as run:
            run.return_value.returncode = 0
            path = bootstrap.hermes_python()
            self.assertTrue(Path(path).is_absolute())
            self.assertIn('import hermes_cli', run.call_args.args[0][-1])

    def test_repair_or_pairing_never_downloads_or_changes_existing_code(self):
        health = {'installation': {'status': 'consistent'}, 'service': 'ok', 'dashboard_rpc': 'ok'}
        with patch.object(bootstrap.importlib.metadata, 'version', return_value='0.15.0'), \
             patch.object(bootstrap, 'inspect', side_effect=[health, {'manager_active': True}, {'listening': True, 'manager_active': True}]), \
             patch.object(bootstrap, 'release') as release, patch.object(bootstrap, 'profiles') as profiles, \
             patch.object(bootstrap.subprocess, 'run') as commands:
            bootstrap.install()
            release.assert_not_called(); profiles.assert_not_called(); commands.assert_not_called()

    def test_unhealthy_existing_install_stops_without_mutation(self):
        with patch.object(bootstrap.importlib.metadata, 'version', return_value='0.15.0'), \
             patch.object(bootstrap, 'inspect', side_effect=[{'installation': {'status': 'mismatch'}}, {}, {}]), \
             patch.object(bootstrap, 'release') as release, patch.object(bootstrap.subprocess, 'run') as commands:
            with self.assertRaisesRegex(ValueError, 'do not match'): bootstrap.install()
            release.assert_not_called(); commands.assert_not_called()

    def test_external_listener_is_not_claimed_as_persistent_startup(self):
        health = {'installation': {'status': 'consistent'}, 'service': 'ok', 'dashboard_rpc': 'ok'}
        with patch.object(bootstrap, 'inspect', side_effect=[health, {'manager_active': True}, {'listening': True, 'manager_active': False}]):
            with self.assertRaisesRegex(ValueError, 'externally managed'): bootstrap.reuse('0.15.0')

    def test_explicit_update_delegates_and_reports_update_without_pairing_checks(self):
        self.check_explicit_update(None)

    def test_first_guided_update_forwards_receipt_to_verified_candidate(self):
        self.check_explicit_update('eyJmaXh0dXJlIjp0cnVlfQ')

    def check_explicit_update(self, receipt):
        import contextlib,io,json,sys,tempfile,types
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def command(args, **kwargs):
                if 'plugins' in args and 'install' in args:
                    candidate = Path(kwargs['env']['HERMES_HOME']) / 'plugins/hermes-jr'
                    candidate.mkdir(parents=True)
                    (candidate/'plugin.yaml').write_text('version: 0.15.0\n')
                return types.SimpleNamespace(returncode=0, stdout=b'')
            constants = types.SimpleNamespace(get_default_hermes_root=lambda:root)
            output=io.StringIO()
            with patch.dict(sys.modules, {'hermes_constants':constants}), \
                 patch.object(bootstrap.importlib.metadata,'version',return_value='0.14.0'), \
                 patch.object(bootstrap,'release',return_value={'latest':'0.15.0','commit':'a'*40,'signature':'fixture','state':'available'}), \
                 patch.object(bootstrap,'profiles',return_value=[]), \
                 patch.object(bootstrap.subprocess,'run',side_effect=command) as run, \
                 patch.object(bootstrap,'reuse') as reuse, contextlib.redirect_stdout(output):
                bootstrap.install(update=True, receipt=receipt)
                reuse.assert_not_called()
                self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['status'],'updated')
                calls=[c.args[0] for c in run.call_args_list]
                imported = 'from hermes_jr.update_requests import run_tracked' if receipt else 'from hermes_jr.installer import install'
                self.assertTrue(any(imported in str(c) and (not receipt or c[-1] == receipt) for c in calls))
                self.assertFalse(any('enable' in c for c in calls))

    def test_fresh_install_reaches_supervised_startup_and_ready(self):
        import contextlib,io,json,shutil,sys,tempfile,types
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);home=root/'home';home.mkdir();site=root/'site';site.mkdir();scripts=root/'bin';scripts.mkdir()
            recovery_source=repo/'plugin/src/hermes_jr/recovery.py' if (repo/'plugin').exists() else repo/'src/hermes_jr/recovery.py'
            def command(args, **kwargs):
                output=b''
                if 'plugins' in args and 'install' in args:
                    candidate=Path(kwargs['env']['HERMES_HOME'])/'plugins/hermes-jr';candidate.mkdir(parents=True,exist_ok=True)
                    (candidate/'plugin.yaml').write_text('version: 0.15.0\n')
                    (candidate/'src/hermes_jr').mkdir(parents=True,exist_ok=True)
                    shutil.copy2(recovery_source,candidate/'src/hermes_jr/recovery.py')
                elif 'wheel' in args:
                    wheels=Path(args[-1]);wheels.mkdir();(wheels/'hermes_jr_companion-0.15.0-py3-none-any.whl').touch()
                elif args[1:3]==['-m','hermes_jr.cli']:
                    action=args[3:]
                    values={('status',):{'service_url':'https://fixture.test','relay_enabled':True},
                            ('backend','status'):{'listening':False,'manager_active':False},
                            ('service','status'):{'installed':False},
                            ('doctor',):{'installation':{'status':'consistent'},'service':'ok','dashboard_rpc':'ok'}}
                    output=json.dumps(values.get(tuple(action),{})).encode()
                return types.SimpleNamespace(returncode=0,stdout=output)
            constants=types.SimpleNamespace(get_default_hermes_root=lambda:root)
            output=io.StringIO()
            with patch.dict(sys.modules,{'hermes_constants':constants}), \
                 patch.object(bootstrap.importlib.metadata,'version',side_effect=bootstrap.importlib.metadata.PackageNotFoundError), \
                 patch.object(bootstrap.importlib.metadata,'distributions',return_value=[]), \
                 patch.object(bootstrap,'release',return_value={'latest':'0.15.0','commit':'a'*40,'signature':'fixture','state':'available'}), \
                 patch.object(bootstrap,'profiles',return_value=[home]), \
                 patch.object(bootstrap.sysconfig,'get_path',side_effect=lambda kind:str(site if kind=='purelib' else scripts)), \
                 patch.object(bootstrap.subprocess,'run',side_effect=command) as run, contextlib.redirect_stdout(output):
                bootstrap.install()
            self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['status'],'ready')
            calls=[c.args[0] for c in run.call_args_list]
            self.assertTrue(any(c[-2:]==['backend','install'] for c in calls))
            self.assertTrue(any(c[-2:]==['service','install'] for c in calls))
