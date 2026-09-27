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
        signature = base64.b64encode(key.sign(f'hermes-jr-release-v1\n{bootstrap.REPO}\n0.17.0\n{commit}\n'.encode())).decode()
        release = {'tag_name': 'v0.17.0', 'body': '<!-- hermes-jr-release-v1: ' + signature + ' -->'}
        def fetch(path):
            return release if path == '/releases/latest' else {'object': {'sha': commit, 'type': 'commit'}}
        with patch.object(bootstrap, 'get_json', side_effect=fetch), patch.object(bootstrap, 'PUBLIC_KEY', key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()):
            self.assertEqual(bootstrap.release()['commit'], commit)
            commit = 'b' * 40
            with self.assertRaises(Exception): bootstrap.release()

    def test_unpublished_or_prerelease_does_not_install(self):
        for data in [{'tag_name':'v0.16.0'}, {'tag_name':'v0.17.0','prerelease':True}]:
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

    def test_python_discovery_reads_selected_pm_generation(self):
        import json, tempfile
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            facts = root / '.hermes/installs/fixture/facts.json'
            facts.parent.mkdir(parents=True)
            selected = facts.parent / 'environments/generation/venv'
            python = selected / 'bin/python'
            python.parent.mkdir(parents=True)
            python.touch()
            facts.write_text(json.dumps({'packages': {'venv': {'environment': str(selected)}}}))
            with patch.object(bootstrap.Path, 'home', return_value=root), \
                 patch.object(bootstrap.subprocess, 'run') as run:
                run.return_value.returncode = 0
                self.assertEqual(bootstrap.hermes_python(), str(python.resolve()))

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
            (root / 'pm').mkdir()
            (root / 'pm/uv.lock').touch()
            pm = types.ModuleType('pm')
            envs = types.ModuleType('pm.environments')
            envs.project_python = lambda _: Path(sys.executable)
            declarations = types.ModuleType('pm.plugin_declarations')
            declarations.read_python_declaration = lambda _: types.SimpleNamespace(install_requirements=('hermes-jr-companion==0.15.0',))
            paths = types.ModuleType('pm.paths')
            paths.repo_root = lambda: root
            def command(args, **kwargs):
                if 'plugins' in args and 'install' in args:
                    candidate = Path(kwargs['env']['HERMES_HOME']) / 'plugins/hermes-jr'
                    candidate.mkdir(parents=True)
                    (candidate/'plugin.yaml').write_text('version: 0.15.0\n')
                return types.SimpleNamespace(returncode=0, stdout=b'')
            constants = types.SimpleNamespace(get_default_hermes_root=lambda:root)
            output=io.StringIO()
            native_calls=[]
            def native(args, **kwargs):
                native_calls.append((args, kwargs))
                return command(args, env=kwargs['env']).returncode
            with patch.dict(sys.modules, {'hermes_constants':constants, 'hermes_cli.main':None, 'pm.paths':paths,
                                          'pm':pm, 'pm.environments':envs, 'pm.plugin_declarations':declarations}), \
                 patch.object(bootstrap.importlib.metadata,'version',return_value='0.14.0'), \
                 patch.object(bootstrap,'release',return_value={'latest':'0.15.0','commit':'a'*40,'signature':'fixture','state':'available'}), \
                 patch.object(bootstrap,'profiles',return_value=[]), \
                 patch.object(bootstrap.subprocess,'run',side_effect=command) as run, \
                 patch.object(bootstrap,'native_command',side_effect=native), \
                 patch.object(bootstrap,'reuse') as reuse, contextlib.redirect_stdout(output):
                bootstrap.install(update=True, receipt=receipt)
                reuse.assert_not_called()
                self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['status'],'updated')
                calls=[args for args, _ in native_calls]
                imported = 'from hermes_jr.update_requests import run_tracked' if receipt else 'from hermes_jr.installer import install'
                self.assertTrue(any(imported in str(c) and (not receipt or c[-1] == receipt) for c in calls))
                self.assertTrue(any(kwargs.get('timeout') == 3600 and kwargs.get('report_progress')
                                    for _, kwargs in native_calls))
                self.assertFalse(any('enable' in c for c in calls))

    def test_fresh_install_reaches_supervised_startup_and_ready(self):
        self.check_initial_install()

    def test_completion_keeps_verified_copies_and_installs_missing_profiles(self):
        self.check_initial_install(complete=True)

    def test_completion_restores_files_and_settings_after_a_failure(self):
        self.check_initial_install(complete=True, failure=True)

    def test_completion_refuses_local_source_changes(self):
        self.check_initial_install(complete=True, changed=True)

    def test_completion_and_update_are_separate_actions(self):
        with self.assertRaisesRegex(ValueError, 'separate steps'):
            bootstrap.install(update=True, complete=True)

    def test_completion_of_an_older_package_requires_an_explicit_update(self):
        with patch.object(bootstrap.importlib.metadata, 'version', return_value='0.17.0'), \
             patch.object(bootstrap, 'release', return_value={'latest': '0.17.1', 'commit': 'a' * 40}), \
             patch.object(bootstrap, 'native_command') as commands:
            with self.assertRaisesRegex(ValueError, '--update first'):
                bootstrap.install(complete=True)
            commands.assert_not_called()

    def test_missing_pm_lock_stops_before_publication(self):
        import sys, tempfile, types
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = types.ModuleType('pm.paths'); paths.repo_root = lambda: root
            environments = types.ModuleType('pm.environments'); environments.project_python = lambda _: Path(sys.executable)
            declarations = types.ModuleType('pm.plugin_declarations'); declarations.read_python_declaration = lambda _: None
            with patch.dict(sys.modules, {'pm': types.ModuleType('pm'), 'pm.paths': paths,
                                          'pm.environments': environments, 'pm.plugin_declarations': declarations}), \
                 patch.object(bootstrap.importlib.metadata, 'version', side_effect=bootstrap.importlib.metadata.PackageNotFoundError), \
                 patch.object(bootstrap, 'release', return_value={'latest': '0.17.1', 'commit': 'a' * 40}), \
                 patch.object(bootstrap, 'native_command') as commands:
                with self.assertRaisesRegex(ValueError, 'missing pm/uv.lock'):
                    bootstrap.install()
                commands.assert_not_called()

    def test_rate_limited_release_lookup_reports_the_cause(self):
        import urllib.error
        error = urllib.error.HTTPError(bootstrap.API, 403, 'Forbidden', {'X-RateLimit-Remaining': '0'}, None)
        with patch.object(bootstrap.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = error
            with self.assertRaisesRegex(ValueError, 'rate limited'):
                bootstrap.get_json('/releases/latest')

    def check_initial_install(self, complete=False, failure=False, changed=False):
        import contextlib,io,json,shutil,sys,tempfile,types
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);home=root/'home';home.mkdir()
            (root / 'pm').mkdir()
            (root / 'pm/uv.lock').touch()
            pm = types.ModuleType('pm')
            envs = types.ModuleType('pm.environments')
            envs.project_python = lambda _: Path(sys.executable)
            declarations = types.ModuleType('pm.plugin_declarations')
            declarations.read_python_declaration = lambda _: types.SimpleNamespace(install_requirements=('hermes-jr-companion==0.15.0',))
            paths = types.ModuleType('pm.paths')
            paths.repo_root = lambda: root
            recovery_source=repo/'plugin/src/hermes_jr/recovery.py' if (repo/'plugin').exists() else repo/'src/hermes_jr/recovery.py'
            homes = [home, root / 'other'] if complete else [home]
            native_homes = []
            if complete:
                plugin = home / 'plugins/hermes-jr'
                (plugin / 'src/hermes_jr').mkdir(parents=True)
                (plugin / 'plugin.yaml').write_text('version: 0.15.0\n' + ('description: local edit\n' if changed else ''))
                shutil.copy2(recovery_source, plugin / 'src/hermes_jr/recovery.py')
                (home / 'plugins/.install-metadata.json').write_text(json.dumps({'hermes-jr': {'source': bootstrap.SOURCE, 'revision': 'a' * 40}}))
                (home / 'config.yaml').write_text('original settings\n')
            def command(args, **kwargs):
                output=b''
                if 'plugins' in args and 'install' in args:
                    native_home = Path(kwargs['env']['HERMES_HOME'])
                    native_homes.append(native_home)
                    if failure and native_home == homes[-1]:
                        (home / 'config.yaml').write_text('installation changed settings\n')
                        raise ValueError('injected installation failure')
                    candidate=native_home/'plugins/hermes-jr';candidate.mkdir(parents=True,exist_ok=True)
                    (candidate/'plugin.yaml').write_text('version: 0.15.0\n')
                    (candidate/'src/hermes_jr').mkdir(parents=True,exist_ok=True)
                    shutil.copy2(recovery_source,candidate/'src/hermes_jr/recovery.py')
                elif args[1:3]==['-I','-c']:
                    output=b'0.15.0\n'
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
            installed = {'return_value': '0.15.0'} if complete else {'side_effect': bootstrap.importlib.metadata.PackageNotFoundError}
            with patch.dict(sys.modules,{'hermes_constants':constants, 'hermes_cli.main':None, 'pm.paths':paths,
                                         'pm':pm, 'pm.environments':envs, 'pm.plugin_declarations':declarations}), \
                 patch.object(bootstrap.importlib.metadata,'version',**installed), \
                 patch.object(bootstrap,'release',return_value={'latest':'0.15.0','commit':'a'*40,'signature':'fixture','state':'available'}), \
                 patch.object(bootstrap,'profiles',return_value=homes), \
                 patch.object(bootstrap.subprocess,'run',side_effect=command) as run, contextlib.redirect_stdout(output):
                with patch.object(bootstrap,'native_command',side_effect=lambda args, **kwargs: command(args, env=kwargs['env']).returncode):
                    if failure or changed:
                        message = 'differs from the signed release' if changed else 'injected installation failure'
                        with self.assertRaisesRegex(ValueError, message):
                            bootstrap.install(complete=complete)
                        self.assertEqual((home / 'config.yaml').read_text(), 'original settings\n')
                        self.assertFalse((homes[-1] / 'plugins/hermes-jr').exists())
                        return
                    bootstrap.install(complete=complete)
            self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['status'],'ready')
            if complete:
                self.assertNotIn(home, native_homes)
                self.assertIn(homes[-1], native_homes)
            calls=[c.args[0] for c in run.call_args_list]
            self.assertTrue(any(c[-2:]==['backend','install'] for c in calls))
            self.assertTrue(any(c[-2:]==['service','install'] for c in calls))
