#!/usr/bin/env python3
"""Explicit Hermes Jr installer. Run with Python; never source this file in a shell."""
import argparse
import base64
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import time
import urllib.request

REPO = 'cyberculturedhq/hermes-jr-companion'
SOURCE = 'https://github.com/' + REPO + '.git#plugin'
API = 'https://api.github.com/repos/' + REPO
PUBLIC_KEY = 'ac072d31db546d1f241ac1ace40cb0b474bd4e833d78385cb9f03499e44778af'
MINIMUM = (0, 12, 0)


def version(value):
    if not re.fullmatch(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', value):
        raise ValueError('Expected a stable release version.')
    return tuple(map(int, value.lstrip('v').split('.')))


def hermes_python():
    candidates = [os.environ.get('HERMES_PYTHON'), sys.executable]
    executable = shutil.which('hermes')
    if executable:
        candidates.append(str(Path(executable).parent / 'python'))
    candidates.append(str(Path.home() / '.hermes/hermes-agent/venv/bin/python'))
    for candidate in dict.fromkeys(p for p in candidates if p):
        try:
            result = subprocess.run([candidate, '-c', 'import hermes_cli, hermes_constants, cryptography'],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            if result.returncode == 0:
                return os.path.abspath(candidate)
        except (OSError, subprocess.TimeoutExpired):
            pass
    raise ValueError('Hermes Python was not found. Set HERMES_PYTHON to the Python executable that runs Hermes, then rerun this installer.')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def get_json(path):
    request = urllib.request.Request(API + path, headers={'User-Agent': 'hermes-jr-installer', 'Accept': 'application/vnd.github+json'})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
        raw = response.read(128001)
        if len(raw) > 128000:
            raise ValueError('Release response is too large.')
        return json.loads(raw)


def release():
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    data = get_json('/releases/latest')
    tag = data['tag_name']
    if data.get('draft') or data.get('prerelease') or version(tag) < MINIMUM:
        raise ValueError('The required stable release is not published yet. Keep the current installation.')
    obj = get_json('/git/ref/tags/' + tag)['object']
    for _ in range(4):
        commit = obj['sha']
        if not re.fullmatch('[0-9a-f]{40}', commit):
            raise ValueError('Invalid release commit.')
        if obj['type'] == 'commit':
            break
        if obj['type'] != 'tag':
            raise ValueError('Invalid release tag.')
        obj = get_json('/git/tags/' + commit)['object']
    else:
        raise ValueError('Too many release tag indirections.')
    signatures = re.findall(r'<!-- hermes-jr-release-v1: ([A-Za-z0-9+/]{86}==) -->', data.get('body') or '')
    if len(signatures) != 1:
        raise ValueError('Release signature is missing or ambiguous.')
    message = f'hermes-jr-release-v1\n{REPO}\n{tag.lstrip("v")}\n{commit}\n'.encode()
    Ed25519PublicKey.from_public_bytes(bytes.fromhex(PUBLIC_KEY)).verify(base64.b64decode(signatures[0], validate=True), message)
    return tag.lstrip('v'), commit


def profiles():
    from hermes_constants import get_default_hermes_root, get_hermes_home, named_profile_is_deleted
    root = get_default_hermes_root().resolve()
    homes = [root, get_hermes_home().resolve()]
    if (root / 'profiles').is_dir():
        homes += [p for p in sorted((root / 'profiles').iterdir())
                  if p.is_dir() and re.fullmatch('[a-z0-9][a-z0-9_.-]*', p.name) and not named_profile_is_deleted(p)]
    homes = list(dict.fromkeys(homes))
    if any(p.is_symlink() or (p / 'plugins/hermes-jr').is_symlink() for p in homes):
        raise ValueError('Linked profile/plugin directories require an explicit manual installation.')
    return homes


def install():
    target, commit = release()
    try:
        installed = importlib.metadata.version('hermes-jr-companion')
    except importlib.metadata.PackageNotFoundError:
        installed = None
    if installed and version(installed) > version(target):
        raise ValueError('Installed companion is newer than the stable release. No downgrade was made.')
    homes = profiles()
    from hermes_constants import get_default_hermes_root
    backups = get_default_hermes_root() / 'backups/hermes-jr-installer'
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    work = Path(tempfile.mkdtemp(prefix='install-', dir=backups))
    log = work / 'install.log'
    log.touch(mode=0o600)
    print('Installing Hermes Jr. ' + target + '. Private log: ' + str(log), flush=True)

    def run(args, home=None, capture=False):
        env = os.environ.copy()
        env.pop('PYTHONPATH', None); env.pop('PYTHONHOME', None)
        if home is not None:
            env['HERMES_HOME'] = str(home)
        with log.open('ab') as output:
            result = subprocess.run([sys.executable, *args], env=env, stdout=subprocess.PIPE if capture else output,
                                    stderr=output, timeout=300)
        if result.returncode:
            raise ValueError('Installation command failed. Inspect the private log: ' + str(log))
        return result.stdout.decode() if capture else None

    def native(home):
        run(['-m', 'hermes_cli.main', 'plugins', 'install', SOURCE, '--ref', commit, '--force', '--no-enable'], home)

    # Native scanning and wheel preparation happen before replacing any installed code.
    stage = work / 'stage'; stage.mkdir(mode=0o700)
    native(stage)
    candidate = stage / 'plugins/hermes-jr'
    manifest = (candidate / 'plugin.yaml').read_text()
    if not re.search(r'^version:\s*[\"\']?' + re.escape(target) + r'[\"\']?\s*$', manifest, re.M):
        raise ValueError('Native plugin version does not match the signed release.')
    wheels = work / 'wheels'
    constraints = work / 'constraints.txt'
    constraints.write_text('\n'.join(sorted({d.metadata['Name'] + '==' + d.version for d in importlib.metadata.distributions()
                                           if d.metadata['Name'] and d.metadata['Name'].lower().replace('_', '-') != 'hermes-jr-companion'})))
    run(['-m', 'pip', 'wheel', str(candidate), '--constraint', str(constraints), '--wheel-dir', str(wheels)])
    own = list(wheels.glob('hermes_jr_companion-*.whl'))
    if len(own) != 1 or not own[0].name.startswith('hermes_jr_companion-' + target + '-'):
        raise ValueError('Built package does not match the release.')
    # Recovery helper is from the native-scanned, signed candidate, and uses only stdlib.
    spec = importlib.util.spec_from_file_location('jr_recovery', candidate / 'src/hermes_jr/recovery.py')
    recovery = importlib.util.module_from_spec(spec); spec.loader.exec_module(recovery)
    site = Path(sysconfig.get_path('purelib'))
    resources = [site / 'hermes_jr', site / ('hermes_jr_companion-' + target + '.dist-info'),
                 Path(sysconfig.get_path('scripts')) / 'hermes-jr']
    if installed:
        distribution = importlib.metadata.distribution('hermes-jr-companion')
        direct = json.loads(distribution.read_text('direct_url.json') or '{}')
        if direct.get('dir_info', {}).get('editable'):
            raise ValueError('Editable companion installation requires a manual update.')
        resources += [Path(distribution.locate_file(f.parts[0])) for f in distribution.files or [] if f.parts[0].endswith('.dist-info')][:1]
    resources += [p for home in homes for p in (home / 'plugins/hermes-jr', home / 'plugins/.install-metadata.json')]
    prior_service = json.loads(run(['-m', 'hermes_jr.cli', 'service', 'status'], capture=True)) if installed else {}
    if prior_service.get('bridge_running') and not prior_service.get('manager_active'):
        raise ValueError('Stop the foreground companion bridge before running installation.')
    snapshot = recovery.Snapshot.create(work / 'before', resources)
    # Preserve all existing files (including locally changed/legacy layouts) in that private backup.
    try:
        snapshot.ensure_unchanged('before')
        if prior_service.get('manager_active'):
            run(['-m', 'hermes_jr.cli', 'service', 'stop'])
        for home in homes:
            native(home)
        run(['-m', 'pip', 'install', '--no-index', '--find-links', str(wheels), '--constraint', str(constraints), str(own[0])])
        run(['-m', 'pip', 'install', '--no-deps', '--force-reinstall', str(own[0])])
        run(['-m', 'pip', 'check'])
        for home in homes:
            run(['-m', 'hermes_cli.main', 'plugins', 'doctor', str(home / 'plugins/hermes-jr'), '--ci'], home)
        snapshot.complete()
    except BaseException:
        snapshot.restore(check_current=False)
        if prior_service.get('manager_active'):
            run(['-m', 'hermes_jr.cli', 'service', 'start'])
        raise
    for home in homes:
        run(['-m', 'hermes_cli.main', 'plugins', 'enable', 'hermes-jr', '--no-allow-tool-override'], home)
    # New subprocesses import the installed package, never the previous in-memory version.
    state = json.loads(run(['-m', 'hermes_jr.cli', 'status'], capture=True))
    if not state.get('service_url'):
        run(['-m', 'hermes_jr.cli', 'setup', '--service', 'https://hermes-jr-companion.cybercultured.com',
             '--dashboard', 'http://127.0.0.1:9119', '--relay', '--push'])
    elif not state.get('relay_enabled'):
        raise ValueError('Remote access is disabled in the existing configuration. Enable it explicitly before ticket pairing.')
    backend = json.loads(run(['-m', 'hermes_jr.cli', 'backend', 'status'], capture=True))
    if not backend['listening']:
        run(['-m', 'hermes_jr.cli', 'backend', 'install'])
    elif not backend['manager_active']:
        print('Existing backend listener retained. Verify its external supervisor before calling startup complete.', flush=True)
    manager = json.loads(run(['-m', 'hermes_jr.cli', 'service', 'status'], capture=True))
    run(['-m', 'hermes_jr.cli', 'service', 'restart' if manager['installed'] else 'install'])
    for _ in range(15):
        health = json.loads(run(['-m', 'hermes_jr.cli', 'doctor'], capture=True))
        if health.get('installation', {}).get('status') == 'consistent' and health.get('service') == 'ok' and health.get('dashboard_rpc') == 'ok':
            print(json.dumps({'status': 'ready', 'version': target, 'python': sys.executable,
                              'next_step': 'Run this Python with -m hermes_jr.cli pair --ticket and the phone ticket. Show the returned code, then run completion_watch.arguments in the same turn.'}), flush=True)
            return
        time.sleep(1)
    raise ValueError('Installed, but connection checks did not pass. Run hermes jr doctor; keep the installation and fix that specific failure.')


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    python = hermes_python()
    if os.path.abspath(sys.executable) != python:
        os.execv(python, [python, str(Path(__file__).resolve())])
    import fcntl
    from hermes_constants import get_default_hermes_root
    directory = get_default_hermes_root() / 'backups/hermes-jr-installer'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'install.lock').open('a') as handle:
        try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('Another Hermes Jr installer is running.') from None
        install()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Network exceptions can contain remote response bodies. Keep output bounded and local.
        print('Installer stopped: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__) + '. No pairing was started.', file=sys.stderr)
        sys.exit(1)
