"""Explicit per-user launchd/systemd service management; no shell or root service."""
from __future__ import annotations
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

SECRET_ENV = ('HERMES_JR_DASHBOARD_TOKEN', 'HERMES_JR_DASHBOARD_SESSION_TOKEN')


def private_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def bridge_running(directory):
    path = Path(directory) / 'bridge.lock'
    if not path.exists():
        return False
    with path.open('a+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(stream, fcntl.LOCK_UN)
            return False
        except BlockingIOError:
            return True


def unit_quote(value, *, command=True):
    # Specifiers expand in both directives; dollar expansion is ExecStart-only.
    value = str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('\n', '\\n').replace('\r', '\\r')
    return '"' + (value.replace('$', '$$') if command else value) + '"'


class Supervisor:
    def __init__(self, state, *, home=None, platform=None):
        self.state = state
        self.directory = state.directory.resolve()
        self.home = Path(home) if home else Path.home()
        self.platform = platform or sys.platform
        if self.platform not in ('darwin', 'linux'):
            raise ValueError('Automatic startup supports macOS launchd and Linux systemd user services. Use hermes jr run on other systems.')
        suffix = hashlib.sha256(str(self.directory).encode()).hexdigest()[:12]
        self.label = 'com.cybercultured.hermes-jr.' + suffix
        self.domain = f'gui/{os.getuid()}'
        self.unit = self.label + '.service'
        self.path = (self.home / 'Library/LaunchAgents' / (self.label + '.plist') if self.platform == 'darwin'
                     else self.home / '.config/systemd/user' / self.unit)
        self.environment_path = self.directory / 'service-environment.json'

    def command(self, args, *, check=True):
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            raise ValueError('Service manager is unavailable. macOS needs a logged-in GUI session; Linux needs systemd --user.') from None
        if check and result.returncode:
            raise ValueError('Service manager operation failed. Run hermes jr service status and inspect the private service log.')
        return result

    def definition(self, python):
        # Keep the venv executable path: resolving its symlink loses the environment.
        args = [os.path.abspath(python), '-m', 'hermes_jr.daemon', str(self.directory)]
        if self.platform == 'darwin':
            return plistlib.dumps({'Label': self.label, 'ProgramArguments': args, 'RunAtLoad': True,
                                  'KeepAlive': True, 'ThrottleInterval': 10, 'ExitTimeOut': 20,
                                  'WorkingDirectory': str(self.directory), 'Umask': 0o077,
                                  'StandardOutPath': '/dev/null', 'StandardErrorPath': '/dev/null'})
        return ('[Unit]\nDescription=Hermes Jr companion\nStartLimitIntervalSec=0\n\n[Service]\nType=simple\n'
                + 'ExecStart=' + ' '.join(unit_quote(x) for x in args) + '\n'
                + 'WorkingDirectory=' + unit_quote(self.directory, command=False) + '\n'
                + 'Restart=always\nRestartSec=10\nTimeoutStopSec=20\nUMask=0077\n'
                + 'StandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=default.target\n').encode()

    def status(self):
        if self.platform == 'darwin':
            result = self.command(['launchctl', 'print', f'{self.domain}/{self.label}'], check=False)
            loaded = result.returncode == 0
        else:
            result = self.command(['systemctl', '--user', 'is-active', self.unit], check=False)
            loaded = result.returncode == 0
        return {'installed': self.path.is_file(), 'manager_active': loaded,
                'bridge_running': bridge_running(self.directory), 'definition': str(self.path),
                'log': str(self.directory / 'service.log'), 'startup': 'user login',
                'last_health': self.state.get('health'), 'updates': self.state.get('update_status')}

    def stop(self):
        if self.platform == 'darwin':
            current = self.command(['launchctl', 'print', f'{self.domain}/{self.label}'], check=False)
            if current.returncode == 0:
                self.command(['launchctl', 'bootout', f'{self.domain}/{self.label}'])
                # bootout can return while launchd is still removing the job.
                for _ in range(200):
                    gone = self.command(['launchctl', 'print', f'{self.domain}/{self.label}'], check=False).returncode != 0
                    if gone and not bridge_running(self.directory):
                        break
                    time.sleep(0.1)
                else:
                    raise ValueError('Service is still stopping; wait before restarting or uninstalling')
        elif self.path.exists():
            self.command(['systemctl', '--user', 'stop', self.unit])

    def start(self):
        if not self.path.is_file():
            raise ValueError('Run hermes jr service install first')
        if self.platform == 'darwin':
            result = self.command(['launchctl', 'print', f'{self.domain}/{self.label}'], check=False)
            if result.returncode:
                if bridge_running(self.directory):
                    raise ValueError('Stop the foreground bridge before starting the managed service')
                self.command(['launchctl', 'enable', f'{self.domain}/{self.label}'])
                self.command(['launchctl', 'bootstrap', self.domain, str(self.path)])
        else:
            self.command(['systemctl', '--user', 'start', self.unit])
        for _ in range(150):
            if bridge_running(self.directory):
                return
            time.sleep(0.1)
        raise ValueError('Service did not acquire its bridge lock. Run hermes jr service status; inspect service.log. The service may still be retrying.')

    def install(self):
        if not self.state.get('host_token'):
            raise ValueError('Run hermes jr setup first')
        if bridge_running(self.directory):
            raise ValueError('Stop the current bridge before installing its service; use hermes jr service stop for a managed bridge')
        # Verify importability without relying on a development PYTHONPATH or cwd.
        result = subprocess.run([sys.executable, '-I', '-c', 'import hermes_jr.daemon'], capture_output=True, timeout=15)
        if result.returncode:
            raise ValueError('Install the companion package into this Python environment before installing its service')
        self.stop()
        env = json.loads(self.environment_path.read_text()) if self.environment_path.exists() else {}
        for key in SECRET_ENV:
            if key in os.environ:
                env[key] = os.environ[key]
        try:
            from hermes_constants import get_hermes_home
            env['HERMES_HOME'] = str(get_hermes_home())
        except ImportError:
            env['HERMES_HOME'] = os.environ.get('HERMES_HOME', str(self.home / '.hermes'))
        private_write(self.environment_path, json.dumps(env).encode())
        private_write(self.path, self.definition(sys.executable))
        if self.platform == 'linux':
            self.command(['systemctl', '--user', 'daemon-reload'])
            self.command(['systemctl', '--user', 'enable', self.unit])
        self.start()

    def uninstall(self):
        self.stop()
        if self.platform == 'linux' and self.path.exists():
            self.command(['systemctl', '--user', 'disable', self.unit])
        self.path.unlink(missing_ok=True)
        self.environment_path.unlink(missing_ok=True)
        if self.platform == 'linux':
            self.command(['systemctl', '--user', 'daemon-reload'])
        # Pairings and private state survive; removing startup is not revocation.
