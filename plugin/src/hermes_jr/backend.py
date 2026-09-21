"""Bounded registration of a dedicated loopback backend with the user's service manager."""
from __future__ import annotations
import filecmp
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
from urllib.parse import urlsplit
from .gateway import dashboard_url
from .supervisor import private_write, unit_quote, unit_working_directory


class BackendSupervisor:
    def __init__(self, state, *, home=None, platform=None, hermes_home=None):
        self.home = Path(home) if home else Path.home()
        self.platform = platform or sys.platform
        if self.platform not in ('darwin', 'linux'):
            raise ValueError('Backend startup requires macOS launchd or Linux systemd --user.')
        self.origin = dashboard_url(state.get('dashboard_url', 'http://127.0.0.1:9119'))
        parts = urlsplit(self.origin)
        if parts.scheme != 'http' or parts.hostname not in ('localhost', '127.0.0.1'):
            raise ValueError('Automatic backend setup supports HTTP on 127.0.0.1. Reuse your existing supervisor for other loopback configurations.')
        self.port = parts.port if parts.port is not None else 80
        if not 1 <= self.port <= 65535:
            raise ValueError('Invalid backend port')
        if hermes_home is None:
            try:
                from hermes_constants import get_hermes_home
            except ImportError:
                raise ValueError('Run backend setup with the Python environment that runs Hermes.') from None
            hermes_home = get_hermes_home()
        self.hermes_home = Path(hermes_home).resolve()
        suffix = hashlib.sha256(f'{self.hermes_home}:{self.port}'.encode()).hexdigest()[:12]
        self.label = 'com.cybercultured.hermes-jr-backend.' + suffix
        self.domain = f'gui/{os.getuid()}'
        self.unit = self.label + '.service'
        self.path = (self.home / 'Library/LaunchAgents' / (self.label + '.plist') if self.platform == 'darwin'
                     else self.home / '.config/systemd/user' / self.unit)

    def command(self, args, *, check=True):
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            raise ValueError('Backend service manager unavailable. macOS needs a GUI login; Linux needs systemd --user.') from None
        if check and result.returncode:
            raise ValueError('Backend service registration failed. Inspect hermes jr backend status and the user service manager.')
        return result

    def active(self):
        args = (['launchctl', 'print', f'{self.domain}/{self.label}'] if self.platform == 'darwin'
                else ['systemctl', '--user', 'is-active', self.unit])
        return self.command(args, check=False).returncode == 0

    def listening(self):
        try:
            with socket.create_connection(('127.0.0.1', self.port), timeout=1):
                return True
        except OSError:
            return False

    def definition(self, executable=None, *, legacy_workdir=False):
        # Preserve the venv path rather than resolving it to the base interpreter.
        args = [os.path.abspath(executable or sys.executable), '-m', 'hermes_cli.main', 'serve',
                '--host', '127.0.0.1', '--port', str(self.port)]
        if self.platform == 'darwin':
            return plistlib.dumps({'Label': self.label, 'ProgramArguments': args,
                                  'EnvironmentVariables': {'HERMES_HOME': str(self.hermes_home)},
                                  'WorkingDirectory': str(self.hermes_home), 'RunAtLoad': True,
                                  'KeepAlive': True, 'ThrottleInterval': 10, 'Umask': 0o077,
                                  'StandardOutPath': '/dev/null', 'StandardErrorPath': '/dev/null'})
        return ('[Unit]\nDescription=Hermes Jr loopback backend\nStartLimitIntervalSec=0\n\n'
                '[Service]\nType=simple\nExecStart=' + ' '.join(unit_quote(x) for x in args)
                + '\nEnvironment=' + unit_quote('HERMES_HOME=' + str(self.hermes_home), command=False)
                + '\nWorkingDirectory=' + (unit_quote(self.hermes_home, command=False) if legacy_workdir else unit_working_directory(self.hermes_home))
                + '\nRestart=always\nRestartSec=10\nUMask=0077\nStandardOutput=null\nStandardError=null\n\n'
                '[Install]\nWantedBy=default.target\n').encode()

    def owns_definition(self):
        if self.path.is_symlink():
            return False
        if not self.path.exists():
            return True
        actual = self.path.read_bytes()
        if actual in (self.definition(), self.definition(legacy_workdir=True)):
            return True
        # Python aliases in one venv retain that venv; resolving to the base
        # interpreter would lose it. Accept only an otherwise identical file.
        executable = Path(os.path.abspath(sys.executable))
        for alias in executable.parent.glob('python*'):
            try:
                if alias.is_file() and (alias.samefile(executable) or filecmp.cmp(alias, executable, shallow=False)) and actual in (self.definition(alias), self.definition(alias, legacy_workdir=True)):
                    return True
            except OSError:
                continue
        return False

    def install(self):
        if importlib.util.find_spec('hermes_cli') is None:
            raise ValueError('Run backend install with the Python environment that runs Hermes.')
        definition = self.definition()
        if not self.owns_definition():
            raise ValueError('An existing backend definition differs. Inspect and reuse it; it was not overwritten.')
        if self.active():
            if not self.path.is_file():
                raise ValueError('A backend service is loaded without its definition. Inspect the service manager before proceeding.')
            return
        if self.listening():
            raise ValueError('The backend port already has a listener. Reuse its supervisor; no new service was installed.')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            # Exclusive creation also prevents overwriting a definition created concurrently.
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(definition)
        elif self.path.read_bytes() != definition:
            # owns_definition accepted only our exact legacy definition (including
            # a same-environment Python alias). Repair its invalid scalar quoting.
            if not self.owns_definition():
                raise ValueError('The backend definition changed; it was not overwritten.')
            private_write(self.path, definition)
        if self.platform == 'darwin':
            self.command(['launchctl', 'enable', f'{self.domain}/{self.label}'])
            self.command(['launchctl', 'bootstrap', self.domain, str(self.path)])
        else:
            self.command(['systemctl', '--user', 'daemon-reload'])
            self.command(['systemctl', '--user', 'enable', '--now', self.unit])

    def status(self):
        return {'installed': self.path.is_file(), 'manager_active': self.active(),
                'listening': self.listening(), 'dashboard_url': self.origin,
                'definition': str(self.path), 'startup': 'user login',
                'next_step': 'Run hermes jr doctor; dashboard_rpc must be ok before pairing.'}

    def uninstall(self):
        if not self.owns_definition():
            raise ValueError('Backend definition was changed. Inspect it before removing its service.')
        if self.platform == 'darwin':
            if self.active():
                self.command(['launchctl', 'bootout', f'{self.domain}/{self.label}'])
        elif self.path.exists():
            self.command(['systemctl', '--user', 'disable', '--now', self.unit])
        self.path.unlink(missing_ok=True)
        if self.platform == 'linux':
            self.command(['systemctl', '--user', 'daemon-reload'])
