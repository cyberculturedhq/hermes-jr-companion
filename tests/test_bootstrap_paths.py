"""Keep installer imports and PM publication bound to the selected installation."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import venv

from test_bootstrap import bootstrap


class BootstrapPathTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name).resolve()
        self.checkout = self.home / 'hermes-checkout'
        (self.checkout / 'pm').mkdir(parents=True)
        (self.checkout / 'pm/__init__.py').touch()
        key = hashlib.sha256(str(self.checkout).encode()).hexdigest()[:16]
        self.install = self.home / '.hermes/installs' / key
        self.environment = self.install / 'environments/current/venv'
        self.environment.mkdir(parents=True)
        self.workspace = self.environment.parent / 'workspace'
        (self.workspace / 'pm').mkdir(parents=True)
        (self.workspace / 'pm/uv.lock').touch()
        (self.install / 'inputs').mkdir()
        (self.install / 'inputs/.project-root').write_text(str(self.checkout))
        self.facts = self.install / 'facts.json'
        self.select(self.environment)

    def select(self, environment):
        self.facts.write_text(json.dumps({'packages': {'venv': {'environment': str(environment)}}}))

    def make_python(self):
        venv.EnvBuilder(with_pip=False, symlinks=True).create(self.environment)
        site = next((self.environment / 'lib').glob('python*/site-packages'))
        (site / 'workspace.pth').write_text(str(self.workspace) + '\n')
        return str(self.environment / 'bin/python')

    def test_discovery_ignores_a_stale_inherited_pythonpath(self):
        python = self.make_python()
        stale = self.home / 'old-workspace'
        stale.mkdir()
        for name in ('hermes_cli', 'hermes_constants', 'cryptography'):
            (self.workspace / (name + '.py')).touch()
            (stale / (name + '.py')).write_text("raise RuntimeError('stale import')\n")
        with patch.object(bootstrap.Path, 'home', return_value=self.home), \
             patch.dict(os.environ, {'HERMES_PYTHON': python, 'PYTHONPATH': str(stale)}):
            self.assertEqual(bootstrap.hermes_python(), python)

    def test_snapshot_interpreter_binds_to_its_owning_checkout(self):
        with patch.object(bootstrap.Path, 'home', return_value=self.home):
            self.assertEqual(bootstrap.hermes_root(str(self.environment / 'bin/python')), self.checkout)

    def test_unselected_generations_are_refused(self):
        old = self.install / 'environments/older/venv/bin/python'
        with patch.object(bootstrap.Path, 'home', return_value=self.home), \
             self.assertRaisesRegex(ValueError, 'unselected generation'):
            bootstrap.hermes_root(str(old))

    def test_an_altered_installation_stamp_is_refused(self):
        (self.install / 'inputs/.project-root').write_text(str(self.home))
        with patch.object(bootstrap.Path, 'home', return_value=self.home), \
             self.assertRaisesRegex(ValueError, 'identity stamp does not match'):
            bootstrap.hermes_root(str(self.environment / 'bin/python'))

    def test_python_children_use_the_checkout_and_preserve_arguments(self):
        python = self.make_python()
        stale = self.home / 'old-workspace'
        (stale / 'pm').mkdir(parents=True)
        (stale / 'pm/__init__.py').touch()
        (self.workspace / 'pm/__init__.py').touch()
        package = self.workspace / 'hermes_jr'
        package.mkdir()
        (package / '__init__.py').touch()
        code = 'import json,pm,sys; print(json.dumps({"pm":pm.__file__,"args":sys.argv[1:]}))'
        (package / 'cli.py').write_text(code)
        for arguments in (['-c', code, 'one', 'two'], ['-m', 'hermes_jr.cli', 'one', 'two']):
            with self.subTest(arguments=arguments):
                command = bootstrap.python_command(python, arguments, self.checkout)
                result = subprocess.run(command, env=dict(os.environ, PYTHONPATH=str(stale)),
                                        capture_output=True, text=True, check=True)
                report = json.loads(result.stdout)
                self.assertEqual(Path(report['pm']).parent, self.checkout / 'pm')
                self.assertEqual(report['args'], ['one', 'two'])

    def test_same_interpreter_still_reexecs_into_isolated_mode(self):
        class Relaunch(Exception):
            pass
        with patch.object(bootstrap, 'hermes_python', return_value=os.path.abspath(sys.executable)), \
             patch.object(bootstrap.sys, 'argv', ['install.py', '--update']), \
             patch.object(bootstrap.sys, 'flags', types.SimpleNamespace(isolated=False)), \
             patch.object(bootstrap.os, 'execv', side_effect=Relaunch) as reexec:
            with self.assertRaises(Relaunch):
                bootstrap.main()
        self.assertEqual(reexec.call_args.args[1][:2], [os.path.abspath(sys.executable), '-I'])
        self.assertEqual(reexec.call_args.args[1][-1], '--update')

    def test_old_snapshot_interpreter_follows_new_pm_selections(self):
        python = self.make_python()
        # Model PM's stable-root facts lookup and its snapshot-venv fallback.
        environments = ('import hashlib,json,sys\nfrom pathlib import Path\n'
            'def project_python(root):\n'
            ' key=hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:16]\n'
            f' facts=Path({str(self.home / ".hermes/installs")!r})/key/"facts.json"\n'
            ' if not facts.exists(): return Path(sys.executable)\n'
            ' return Path(json.loads(facts.read_text())["packages"]["venv"]["environment"])/"bin/python"\n')
        for root in (self.checkout, self.workspace):
            (root / 'pm/__init__.py').touch()
            (root / 'pm/paths.py').write_text('from pathlib import Path\ndef repo_root(): return Path(__file__).resolve().parent.parent\n')
            (root / 'pm/environments.py').write_text(environments)
        code = 'from pm.paths import repo_root; from pm.environments import project_python; print(project_python(repo_root()))'
        command = bootstrap.python_command(python, ['-c', code], self.checkout)
        for environment in (self.environment, self.install / 'environments/new/venv'):
            self.select(environment)
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), str(environment / 'bin/python'))
