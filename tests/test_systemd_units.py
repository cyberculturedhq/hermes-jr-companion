"""Use systemd's parser, not a string mirror, to validate generated Linux units."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from hermes_jr.backend import BackendSupervisor
from hermes_jr.state import State
from hermes_jr.supervisor import Supervisor, unit_working_directory


class SystemdUnitTests(unittest.TestCase):
    def test_rejects_directive_injection_and_ambiguous_paths(self):
        for path in ['relative', '/tmp/line\nRestart=no', '/tmp/carriage\rreturn', '/tmp/trailing ']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                unit_working_directory(path)

    @unittest.skipUnless(sys.platform == 'linux' and shutil.which('systemd-analyze'), 'Requires systemd parser')
    def test_real_systemd_parser_accepts_both_generated_units(self):
        with tempfile.TemporaryDirectory(prefix='jr systemd % ') as temp:
            root = Path(temp)
            state = State(root / 'companion state')
            profile = root / 'Hermes profile'
            profile.mkdir()
            managers = [BackendSupervisor(state, home=root, platform='linux', hermes_home=profile),
                        Supervisor(state, home=root, platform='linux')]
            for manager in managers:
                unit = root / manager.unit
                data = manager.definition(sys.executable)
                unit.write_bytes(data)
                result = subprocess.run(['systemd-analyze', 'verify', str(unit)], capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                # Prove the parser would detect the exact bug this test guards.
                line = next(line for line in data.decode().splitlines() if line.startswith('WorkingDirectory='))
                unit.write_text(data.decode().replace(line, 'WorkingDirectory="' + line.split('=', 1)[1] + '"'))
                rejected = subprocess.run(['systemd-analyze', 'verify', str(unit)], capture_output=True, text=True, timeout=15)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn('WorkingDirectory=', rejected.stderr)
