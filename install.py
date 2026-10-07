#!/usr/bin/env python3
"""Explicit Hermes Jr installer. Run with Python; never source this file in a shell."""
import argparse
import base64
import hashlib
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

REPO = 'cyberculturedhq/hermes-jr-companion'
SOURCE = 'https://github.com/' + REPO + '.git#plugin'
API = 'https://api.github.com/repos/' + REPO
PUBLIC_KEY = 'ac072d31db546d1f241ac1ace40cb0b474bd4e833d78385cb9f03499e44778af'
RELEASE_MINIMUM = (0, 17, 0)


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
            result = subprocess.run([candidate, '-I', '-c', 'import hermes_cli, hermes_constants, cryptography'],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            if result.returncode == 0:
                return os.path.abspath(candidate)
        except (OSError, subprocess.TimeoutExpired):
            pass
    raise ValueError('Hermes Python was not found. Set HERMES_PYTHON to the Python executable that runs Hermes, then rerun this installer.')


def hermes_root(python):
    """Bind selected snapshot dependencies to their recorded owning checkout.

    PM copies Hermes into each generation. Its package paths therefore identify
    the snapshot, while the activation stamp identifies the stable installation
    whose facts must be reread after native plugin operations publish a new venv.
    """
    prefix = Path(python).absolute().parent.parent.resolve()
    for facts in sorted((Path.home() / '.hermes/installs').glob('*/facts.json')):
        try:
            recorded = json.loads(facts.read_text())['packages']['venv']['environment']
            environment = Path(recorded).resolve()
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if prefix != environment:
            continue
        if not environment.is_relative_to((facts.parent / 'environments').resolve()):
            raise ValueError('Hermes selected an environment outside its installation. Report the facts path: ' + str(facts))
        try:
            root = Path((facts.parent / 'inputs/.project-root').read_text().strip()).resolve()
        except OSError:
            raise ValueError('The Hermes installation identity stamp is missing. Report the facts path: ' + str(facts)) from None
        if hashlib.sha256(str(root).encode()).hexdigest()[:16] != facts.parent.name or not root.is_dir():
            raise ValueError('The Hermes installation identity stamp does not match its facts. Report the facts path: ' + str(facts))
        if not (environment.parent / 'workspace/pm/uv.lock').is_file():
            raise ValueError('The selected Hermes workspace is missing pm/uv.lock. Report the selected environment: ' + str(environment))
        return root
    if prefix.is_relative_to((Path.home() / '.hermes/installs').resolve()):
        raise ValueError('This Hermes Python is an older, unselected generation. Report HERMES_PYTHON and the current facts.json selection.')
    # A developer/external interpreter has no PM generation record.
    from pm.paths import repo_root
    return repo_root()


def python_command(python, args, root):
    """Ignore ambient imports and use the same checkout as the native launcher."""
    args = list(args)
    if args[:1] == ['-I']:
        args.pop(0)
    bootstrap = 'import sys,runpy; sys.path.insert(0,sys.argv.pop(1)); '
    if args[:1] == ['-c']:
        return [python, '-I', '-c', bootstrap + 'exec(sys.argv.pop(1))', str(root), *args[1:]]
    if args[:1] == ['-m']:
        return [python, '-I', '-c', bootstrap + "runpy.run_module(sys.argv.pop(1),run_name='__main__',alter_sys=True)", str(root), *args[1:]]
    raise ValueError('Unsupported installer Python command.')


def bind_installation(root):
    sys.path.insert(0, str(root))
    # Activation can put a leased generation's console scripts first on PATH.
    # Use the owning checkout's durable launcher in this installer and the
    # signed updater children, preserving the rest of PATH for PM tools.
    directory = root / '.hermes/bin'
    launcher = directory / 'hermes'
    if launcher.is_file() and os.access(launcher, os.X_OK):
        os.environ['PATH'] = str(directory) + os.pathsep + os.environ.get('PATH', '')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def get_json(path):
    request = urllib.request.Request(API + path, headers={'User-Agent': 'hermes-jr-installer', 'Accept': 'application/vnd.github+json'})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            raw = response.read(128001)
            if len(raw) > 128000:
                raise ValueError('Release response is too large.')
            return json.loads(raw)
    except urllib.error.HTTPError as error:
        if error.code == 429 or (error.code == 403 and (error.headers or {}).get('X-RateLimit-Remaining') == '0'):
            raise ValueError('GitHub release lookup is rate limited. Wait for the GitHub rate limit to reset; do not patch or repeatedly rerun the installer.') from None
        raise ValueError(f'GitHub release lookup failed with HTTP {error.code}. Keep the installation and report this error.') from None


def native_command(command, *, env, log, requirement, timeout=300, report_progress=False):
    """Provide the native consent gate a terminal and approve one verified requirement.

    The caller has verified the release signature and dependency declaration.
    No other question, security-scan override, or dependency list is approved.
    """
    import pty

    master, slave = pty.openpty()
    process = None
    pending = b''
    approved = False
    progress = b''
    prompt = b'Prepare these with Hermes through PM now? [y/N]:'
    environment = {**env, 'TERM': 'dumb', 'NO_COLOR': '1', 'COLUMNS': '160'}
    try:
        process = subprocess.Popen(command, env=environment, stdin=slave, stdout=slave,
                                   stderr=slave, start_new_session=True)
        os.close(slave); slave = None
        deadline = time.monotonic() + timeout
        with log.open('ab') as output:
            while True:
                if time.monotonic() >= deadline:
                    raise ValueError(f'Native Hermes command timed out after {timeout} seconds. Inspect the private log: {log}')
                readable, _, _ = select.select([master], [], [], min(0.1, max(0, deadline - time.monotonic())))
                if not readable:
                    continue
                try:
                    chunk = os.read(master, 8192)
                except OSError as error:
                    if error.errno != 5:  # PTYs report EIO when the child closes its side.
                        raise
                    chunk = b''
                if not chunk:
                    break
                output.write(chunk); output.flush()
                if report_progress:
                    progress += chunk
                    lines = progress.split(b'\n')
                    progress = lines.pop()[-4096:]
                    for line in lines:
                        line = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', line).strip()
                        if line.startswith(b'Hermes plugins '):
                            print(line.decode('utf-8', errors='replace'), flush=True)
                pending = (pending + chunk)[-65536:]
                clean = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', pending).replace(b'\r', b'')
                if prompt in clean:
                    section = clean.split(prompt, 1)[0].rsplit(b'hermes-jr declares Python dependencies:', 1)
                    if approved and len(section) == 1:
                        # Readline can redraw the same prompt after queued input.
                        # Discard the redraw; never send another approval.
                        pending = clean.split(prompt, 1)[1]
                        continue
                    dependencies = re.findall(rb'(?:^|\n)\s*-\s*([^\n]+)', section[-1]) if len(section) == 2 else []
                    if approved or [item.strip() for item in dependencies] != [requirement.encode()]:
                        raise ValueError(f'Native Hermes requested unexpected dependency consent. Inspect the private log: {log}')
                    os.write(master, b'y\n')
                    approved = True
                    pending = clean.split(prompt, 1)[1]
                elif b'[y/N]:' in clean or b'[Y/n]:' in clean:
                    raise ValueError(f'Native Hermes requested a separate review. Inspect the private log: {log}')
        return process.wait(timeout=max(0.1, deadline - time.monotonic()))
    finally:
        if process is not None:
            # Stop only this invocation and its PM workers, including on Ctrl+C.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        os.close(master)
        if slave is not None:
            os.close(slave)


def release():
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    data = get_json('/releases/latest')
    tag = data['tag_name']
    if data.get('draft') or data.get('prerelease') or version(tag) < RELEASE_MINIMUM:
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
    result = subprocess.run(python_command(sys.executable, ['-m', 'hermes_jr.cli', *command], hermes_root(sys.executable)),
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45)
    if result.returncode:
        raise ValueError('The installed companion could not be checked. Follow STARTUP.md to diagnose it; no code was changed.')
    return json.loads(result.stdout)


def reuse(installed):
    # No GitHub access, package replacement, profile activation or service restart.
    if version(installed) < (0, 15, 0):
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


def install(update=False, receipt=None, complete=False, setup_ticket=None):
    if complete and (update or receipt):
        raise ValueError('Use --update and --complete-install as separate steps.')
    if receipt and (not update or not re.fullmatch(r'[A-Za-z0-9_-]{1,2048}', receipt)):
        raise ValueError('An update receipt requires --update and must be a valid receipt from Jr.')
    try:
        installed = importlib.metadata.version('hermes-jr-companion')
    except importlib.metadata.PackageNotFoundError:
        installed = None
    if installed and not update and not complete:
        return reuse(installed)
    if update and not installed:
        raise ValueError('No companion is installed. Run without --update for first installation.')
    selected = release()
    target, commit = selected['latest'], selected['commit']
    if complete and installed and installed != target:
        raise ValueError('The partial installation differs from the latest signed release. Run this installer with --update first, then --complete-install.')
    if installed and version(installed) >= version(target) and not receipt and not complete:
        return reuse(installed)
    from pm.paths import repo_root
    from pm.environments import project_python
    from pm.plugin_declarations import read_python_declaration

    if not (repo_root() / 'pm/uv.lock').is_file():
        raise ValueError('Hermes PM loaded from ' + str(repo_root()) + ' is missing pm/uv.lock. Report this path and the current facts.json selection before retrying.')

    def current_python():
        return str(project_python(repo_root()))
    homes = profiles()
    from hermes_constants import get_default_hermes_root
    backups = get_default_hermes_root() / 'backups/hermes-jr-installer'
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    work = Path(tempfile.mkdtemp(prefix='install-', dir=backups))
    log = work / 'install.log'
    log.touch(mode=0o600)
    print('Installing Hermes Jr. ' + target + '. Private log: ' + str(log), flush=True)

    def run(args, home=None, capture=False, managed_update=False):
        env = os.environ.copy()
        env.pop('PYTHONPATH', None); env.pop('PYTHONHOME', None)
        if home is not None:
            env['HERMES_HOME'] = str(home)
        if managed_update:
            # An update spans multiple individually bounded native commands.
            # Keep its process group under the same cancellation authority.
            code = native_command(python_command(current_python(), args, repo_root()), env=env, log=log,
                                  requirement=f'hermes-jr-companion=={target}',
                                  timeout=3600, report_progress=True)
            if code:
                raise ValueError(f'Managed update exited {code}. Inspect the private log: {log}')
            return None
        if args[:2] == ['-m', 'hermes_cli.main']:
            executable = shutil.which('hermes')
            command = [executable, *args[2:]] if executable else python_command(current_python(), args, repo_root())
            print('Hermes ' + ' '.join(args[2:4]) + ': ' + str(home or 'current profile'), flush=True)
            try:
                code = native_command(command, env=env, log=log, requirement=f'hermes-jr-companion=={target}')
            except (OSError, subprocess.TimeoutExpired):
                raise ValueError(f'Native Hermes {" ".join(args[2:4])} could not finish. Inspect the private log: {log}') from None
            if code:
                raise ValueError(f'Native Hermes {" ".join(args[2:4])} exited {code}. Inspect the private log: {log}')
            return None
        with log.open('ab') as output:
            result = subprocess.run(python_command(current_python(), args, repo_root()), env=env, stdout=subprocess.PIPE if capture else output,
                                    stderr=output, timeout=300)
        if result.returncode:
            raise ValueError('Installation command failed. Inspect the private log: ' + str(log))
        return result.stdout.decode() if capture else None

    def native(home):
        flags = ['--no-deps'] if home == stage else []
        run(['-m', 'hermes_cli.main', 'plugins', 'install', SOURCE, '--ref', commit, '--force', *flags, '--no-enable'], home)

    # Scan the signed plugin before changing an installed profile.
    stage = work / 'stage'; stage.mkdir(mode=0o700)
    native(stage)
    candidate = stage / 'plugins/hermes-jr'
    manifest = (candidate / 'plugin.yaml').read_text()
    if not re.search(r'^version:\s*[\"\']?' + re.escape(target) + r'[\"\']?\s*$', manifest, re.M):
        raise ValueError('Native plugin version does not match the signed release.')
    if (candidate / 'pyproject.toml').exists() or read_python_declaration(candidate).install_requirements != (f'hermes-jr-companion=={target}',):
        raise ValueError('Native plugin does not pin the signed release package through Hermes PM.')
    if installed and not complete:
        # All explicit upgrades use the same managed updater and rollback record.
        # Load the verified candidate in a separate process so old updater versions
        # can also handle a release that only removes an unused dependency.
        if receipt:
            code = ('import sys,json; sys.path.insert(0,sys.argv[1]); '
                    'from hermes_jr.update_requests import run_tracked; from hermes_jr.state import State; '
                    'run_tracked(State(),json.loads(sys.argv[2]),sys.argv[3])')
            run(['-c', code, str(candidate / 'src'), json.dumps(selected), receipt], managed_update=True)
        else:
            code = ('import sys,json; sys.path.insert(0,sys.argv[1]); '
                    'from hermes_jr.installer import install; from hermes_jr.state import State; '
                    'install(State(),json.loads(sys.argv[2]))')
            run(['-c', code, str(candidate / 'src'), json.dumps(selected)], managed_update=True)
        print(json.dumps({'status': 'updated', 'version': target,
                          'message': 'The companion was updated. Existing profile choices and pairings were preserved.',
                          'next_step': 'Restart loaded Hermes sessions when idle, as described in UPDATES.md. Pairing is a separate action.'}), flush=True)
        return
    # Recovery helper is from the native-scanned, signed candidate, and uses only stdlib.
    spec = importlib.util.spec_from_file_location('jr_recovery', candidate / 'src/hermes_jr/recovery.py')
    recovery = importlib.util.module_from_spec(spec); spec.loader.exec_module(recovery)
    existing = set()
    if complete:
        def source_digest(path):
            with tempfile.TemporaryDirectory(prefix='jr-completion-compare-') as temp:
                tree = Path(temp) / 'source'
                shutil.copytree(path, tree, symlinks=True, ignore=shutil.ignore_patterns(
                    '__pycache__', '*.pyc', '*.pyo', '*.egg-info', 'build', 'dist', '.venv', '.git'))
                return recovery.digest(tree)
        expected = source_digest(candidate)
        for home in homes:
            plugin = home / 'plugins/hermes-jr'
            if not plugin.exists():
                continue
            try:
                entry = json.loads((home / 'plugins/.install-metadata.json').read_text())['hermes-jr']
            except (OSError, ValueError, KeyError, TypeError):
                raise ValueError('Cannot complete installation: existing plugin metadata is missing. Keep the copies and report the profile.') from None
            if entry.get('source') != SOURCE or entry.get('revision') != commit or source_digest(plugin) != expected:
                raise ValueError('Cannot complete installation: an existing copy differs from the signed release. Keep its files and report the profile.')
            existing.add(home)
    resources = [p for home in homes for p in (home / 'plugins/hermes-jr', home / 'plugins/.install-metadata.json', home / 'config.yaml')]
    snapshot = recovery.Snapshot.create(work / 'before', resources)
    # Preserve all existing files (including locally changed/legacy layouts) in that private backup.
    try:
        snapshot.ensure_unchanged('before')
        for home in homes:
            if home not in existing:
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
        # Restore the PM graph from the restored profile selections as well.
        try:
            run(['-c', 'import pm; pm.sync_venv(explicit=True)'])
        except BaseException:
            raise ValueError('Profile files and settings were restored, but Hermes dependency recovery failed. Keep setup stopped and inspect the private log: ' + str(log)) from None
        raise
    # New subprocesses import the installed package, never the previous in-memory version.
    state = json.loads(run(['-m', 'hermes_jr.cli', 'status'], capture=True))
    if not state.get('service_url') or not state.get('installation_id'):
        run(['-m', 'hermes_jr.cli', 'setup', '--service', 'https://hermes-jr-companion.cybercultured.com',
             '--dashboard', 'http://127.0.0.1:9119', '--relay', '--push',
             *(['--ticket', setup_ticket] if setup_ticket else [])])
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
    parser.add_argument('--setup-ticket', help="Use the phone's public setup ticket for first installation")
    parser.add_argument('--complete-install', action='store_true', help='Complete a stopped initial installation of the current signed release across profiles')
    args = parser.parse_args()
    python = hermes_python()
    if os.path.abspath(sys.executable) != python or not sys.flags.isolated:
        os.execv(python, [python, '-I', str(Path(__file__).resolve()), *sys.argv[1:]])
    root = hermes_root(python)
    bind_installation(root)
    import fcntl
    from hermes_constants import get_default_hermes_root
    directory = get_default_hermes_root() / 'backups/hermes-jr-installer'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory / 'install.lock').open('a') as handle:
        try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('Another Hermes Jr installer is running.') from None
        install(update=args.update, receipt=args.receipt, complete=args.complete_install, setup_ticket=args.setup_ticket)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Network exceptions can contain remote response bodies. Keep output bounded and local.
        print('Installer stopped: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__) + '. No pairing was started.', file=sys.stderr)
        sys.exit(1)
