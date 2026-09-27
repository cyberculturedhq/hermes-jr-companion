"""Exercise native dependency consent and cancellation with real subprocesses."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

from test_bootstrap import bootstrap


class NativeConsentTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.log = self.root / 'install.log'

    def run_native(self, code, timeout=5):
        return bootstrap.native_command([sys.executable, '-u', '-c', code],
                                        env=os.environ.copy(), log=self.log,
                                        requirement='hermes-jr-companion==0.17.0', timeout=timeout)

    def question(self, dependencies):
        return ("import sys; assert sys.stdin.isatty() and sys.stdout.isatty(); "
                "print('hermes-jr declares Python dependencies:'); "
                + ''.join(f"print('  - {item}'); " for item in dependencies)
                + "answer = input('  Prepare these with Hermes through PM now? [y/N]: '); "
                "print('response=' + answer); sys.exit(0 if answer == 'y' else 9)")

    def test_exact_requirement_gets_a_terminal_and_consent(self):
        self.assertEqual(self.run_native(self.question(['hermes-jr-companion==0.17.0'])), 0)
        self.assertIn(b'response=y', self.log.read_bytes())

    def test_other_version_or_extra_dependency_is_not_approved(self):
        for dependencies in [['hermes-jr-companion==0.18.0'],
                             ['hermes-jr-companion==0.17.0', 'another-package==1.0']]:
            with self.subTest(dependencies=dependencies), self.assertRaisesRegex(ValueError, 'unexpected dependency'):
                self.run_native(self.question(dependencies))
        self.assertNotIn(b'response=y', self.log.read_bytes())

    def test_scan_override_is_not_approved(self):
        with self.assertRaisesRegex(ValueError, 'separate review'):
            self.run_native("input('Install flagged plugin anyway? [y/N]: ')")

    def test_partial_prompt_reads_do_not_look_like_another_question(self):
        code = ("import sys,time; print('hermes-jr declares Python dependencies:'); "
                "print('  - hermes-jr-companion==0.17.0'); "
                "prompt='Prepare these with Hermes through PM now? [y/N]: '; "
                "exec('for character in prompt:\\n sys.stdout.write(character); sys.stdout.flush(); time.sleep(.001)'); "
                "sys.exit(0 if input() == 'y' else 9)")
        self.assertEqual(self.run_native(code), 0)

    def test_timeout_reaps_the_invocation(self):
        pidfile = self.root / 'pid'
        code = f"import os,time; from pathlib import Path; Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)"
        with self.assertRaisesRegex(ValueError, 'timed out'):
            self.run_native(code, timeout=1)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)

    def test_nonzero_exit_is_returned_with_diagnostics_in_the_log(self):
        self.assertEqual(self.run_native("import sys; print('native failure'); sys.exit(7)"), 7)
        self.assertIn(b'native failure', self.log.read_bytes())
