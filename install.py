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
import tempfile
import time
import urllib.request

REPO = 'cyberculturedhq/hermes-jr-companion'
SOURCE = 'https://github.com/' + REPO + '.git#plugin'
API = 'https://api.github.com/repos/' + REPO
PUBLIC_KEY = 'ac072d31db546d1f241ac1ace40cb0b474bd4e833d78385cb9f03499e44778af'
MINIMUM = (0, 15, 0)


def version(value):
    if not re.fullmatch(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', value):
        raise ValueError('Expected a stable release version.')
    return tuple(map(int, value.lstrip('v').split('.')))


def hermes_python():
    candidates = [os.environ.get('HERMES_PYTHON')]
    # Hermes PM retires the in-tree venv after selecting an isolated generation.
    # Its facts file is the authoritative pointer for an installed checkout.
    for facts in sorted((Path.home() / '.hermes/installs').glob('*/facts.json')):
        try:
            environment = json.loads(facts.read_text())['packages']['venv']['environment']
            path = Path(environment).resolve()
            if path.is_relative_to((facts.parent / 'environments').resolve()):
                candidates.append(str(path / 'bin/python'))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    candidates.append(sys.executable)
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
    return {'latest': tag.lstrip('v'), 'commit': commit, 'signature': signatures[0], 'state': 'available'}


def profiles():
    from pm.plugins_state import dependency_homes
    homes = list(dict.fromkeys(home.resolve() for home in dependency_homes()))
    if any(p.is_symlink() or (p / 'plugins/hermes-jr').is_symlink() for p in homes):
        raise ValueError('Linked profile/plugin directories require an explicit manual installation.')
    return homes


HANDOFF = ('Follow INSTALL.md step 2 with the phone ticket. The native Hermes pairing panel displays the code '
           'and waits for confirmation on the iPhone. Do not display the code yourself or start a watcher. '
           'After installing or updating, restart the Hermes CLI process or quit and reopen Hermes Desktop to load the plugin. '
           'After connected, say only: Your iPhone is connected.')


def inspect(command):
    result = subprocess.run([sys.executable, '-m', 'hermes_jr.cli', *command],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45)
    if result.returncode:
        raise ValueError('The installed companion could not be checked. Follow STARTUP.md to diagnose it; no code was changed.')
    return json.loads(result.stdout)


def reuse(installed):
    # No GitHub access, package replacement, profile activation or service restart.
    if version(installed) < MINIMUM:
        raise ValueError('Native pairing panels require companion 0.15.0 or newer. Follow UPDATES.md for an explicit update, then reopen the interactive Hermes session. Existing connections are unchanged; do not reinstall as a generic repair.')
    health = inspect(['doctor'])
    manager = inspect(['service', 'status'])
    backend = inspect(['backend', 'status'])
    if health.get('installation', {}).get('status') != 'consistent':
        raise ValueError('The installed companion copies do not match. Follow STARTUP.md to repair the reported installation; no update was performed.')
    if not manager.get('manager_active') or not backend.get('listening'):
        raise ValueError('The companion or backend is stopped. Follow STARTUP.md to restore startup; no reinstall or update was performed.')
    if not backend.get('manager_active'):
        raise ValueError('The backend is externally managed. Verify its supervisor using STARTUP.md before pairing; no service was changed.')
    if health.get('service') != 'ok' or health.get('dashboard_rpc') != 'ok':
        raise ValueError('Connection checks failed. Run hermes jr doctor and fix the reported connection problem; no reinstall or update was performed.')
    print(json.dumps({'status': 'ready', 'version': installed, 'python': sys.executable,
                      'reused': True, 'next_step': HANDOFF}), flush=True)


def install(update=False, receipt=None):
    if receipt and (not update or not re.fullmatch(r'[A-Za-z0-9_-]{1,2048}', receipt)):
        raise ValueError('An update receipt requires --update and must be a valid receipt from Jr.')
    try:
        installed = importlib.metadata.version('hermes-jr-companion')
    except importlib.metadata.PackageNotFoundError:
        installed = None
    if installed and not update:
        return reuse(installed)
    if update and not installed:
        raise ValueError('No companion is installed. Run without --update for first installation.')
    selected = release()
    target, commit = selected['latest'], selected['commit']
    if installed and version(installed) >= version(target) and not receipt:
        return reuse(installed)
    from hermes_cli.main import PROJECT_ROOT
    from pm.environments import project_python
    from pm.plugin_declarations import read_python_declaration

    def current_python():
        return str(project_python(PROJECT_ROOT))
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
            result = subprocess.run([current_python(), *args], env=env, stdout=subprocess.PIPE if capture else output,
                                    stderr=output, timeout=300)
        if result.returncode:
            raise ValueError('Installation command failed. Inspect the private log: ' + str(log))
        return result.stdout.decode() if capture else None

    def native(home):
        run(['-m', 'hermes_cli.main', 'plugins', 'install', SOURCE, '--ref', commit, '--force', '--no-enable'], home)

    # Scan the signed plugin before changing an installed profile.
    stage = work / 'stage'; stage.mkdir(mode=0o700)
    native(stage)
    candidate = stage / 'plugins/hermes-jr'
    manifest = (candidate / 'plugin.yaml').read_text()
    if not re.search(r'^version:\s*[\"\']?' + re.escape(target) + r'[\"\']?\s*$', manifest, re.M):
        raise ValueError('Native plugin version does not match the signed release.')
    if (candidate / 'pyproject.toml').exists() or read_python_declaration(candidate).install_requirements != (f'hermes-jr-companion=={target}',):
        raise ValueError('Native plugin does not pin the signed release package through Hermes PM.')
    if installed:
        # All explicit upgrades use the same managed updater and rollback record.
        # Load the verified candidate in a separate process so old updater versions
        # can also handle a release that only removes an unused dependency.
        if receipt:
            code = ('import sys,json; sys.path.insert(0,sys.argv[1]); '
                    'from hermes_jr.update_requests import run_tracked; from hermes_jr.state import State; '
                    'run_tracked(State(),json.loads(sys.argv[2]),sys.argv[3])')
            run(['-c', code, str(candidate / 'src'), json.dumps(selected), receipt])
        else:
            code = ('import sys,json; sys.path.insert(0,sys.argv[1]); '
                    'from hermes_jr.installer import install; from hermes_jr.state import State; '
                    'install(State(),json.loads(sys.argv[2]))')
            run(['-c', code, str(candidate / 'src'), json.dumps(selected)])
        print(json.dumps({'status': 'updated', 'version': target,
                          'message': 'The companion was updated. Existing profile choices and pairings were preserved.',
                          'next_step': 'Restart loaded Hermes sessions when idle, as described in UPDATES.md. Pairing is a separate action.'}), flush=True)
        return
    # Recovery helper is from the native-scanned, signed candidate, and uses only stdlib.
    spec = importlib.util.spec_from_file_location('jr_recovery', candidate / 'src/hermes_jr/recovery.py')
    recovery = importlib.util.module_from_spec(spec); spec.loader.exec_module(recovery)
    resources = [p for home in homes for p in (home / 'plugins/hermes-jr', home / 'plugins/.install-metadata.json')]
    snapshot = recovery.Snapshot.create(work / 'before', resources)
    # Preserve all existing files (including locally changed/legacy layouts) in that private backup.
    try:
        snapshot.ensure_unchanged('before')
        for home in homes:
            native(home)
        for home in homes:
            run(['-m', 'hermes_cli.main', 'plugins', 'enable', 'hermes-jr'], home)
        selected_version = run(['-I', '-c', 'import importlib.metadata; print(importlib.metadata.version("hermes-jr-companion"))'], capture=True).strip()
        if selected_version != target:
            raise ValueError('Hermes PM did not select the signed companion version.')
        for home in homes:
            run(['-m', 'hermes_cli.main', 'plugins', 'doctor', str(home / 'plugins/hermes-jr'), '--ci'], home)
        snapshot.complete()
    except BaseException:
        for home in homes:
            try:
                run(['-m', 'hermes_cli.main', 'plugins', 'disable', 'hermes-jr'], home)
            except BaseException:
                pass
        snapshot.restore(check_current=False)
        raise
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
        raise ValueError('An existing backend is listening, but its startup supervisor is not verified. Follow STARTUP.md to verify it; no existing backend was changed.')
    manager = json.loads(run(['-m', 'hermes_jr.cli', 'service', 'status'], capture=True))
    run(['-m', 'hermes_jr.cli', 'service', 'restart' if manager['installed'] else 'install'])
    for _ in range(15):
        health = json.loads(run(['-m', 'hermes_jr.cli', 'doctor'], capture=True))
        if health.get('installation', {}).get('status') == 'consistent' and health.get('service') == 'ok' and health.get('dashboard_rpc') == 'ok':
            print(json.dumps({'status': 'ready', 'version': target, 'python': current_python(),
                              'next_step': HANDOFF}), flush=True)
            return
        time.sleep(1)
    raise ValueError('Installed, but connection checks did not pass. Run hermes jr doctor; keep the installation and fix that specific failure.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--update', action='store_true', help='Install an explicitly requested update when Hermes work is idle')
    parser.add_argument('--receipt', help='Opaque Hermes Jr. update receipt; requires --update')
    args = parser.parse_args()
    python = hermes_python()
    if os.path.abspath(sys.executable) != python:
        os.execv(python, [python, str(Path(__file__).resolve()), *sys.argv[1:]])
    import fcntl
    from hermes_constants import get_default_hermes_root
    directory = get_default_hermes_root() / 'backups/hermes-jr-installer'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'install.lock').open('a') as handle:
        try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('Another Hermes Jr installer is running.') from None
        install(update=args.update, receipt=args.receipt)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Network exceptions can contain remote response bodies. Keep output bounded and local.
        print('Installer stopped: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__) + '. No pairing was started.', file=sys.stderr)
        sys.exit(1)
