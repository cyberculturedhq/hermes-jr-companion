"""Explicit stable-release installation with code-only rollback and native Hermes scanning."""
from __future__ import annotations
import configparser
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import uuid
import zipfile
from email.parser import BytesParser
from .recovery import Snapshot, lock, write_json
from .supervisor import Supervisor, bridge_running
from .updates import REPOSITORY, installed_version, version

SOURCE = 'https://github.com/' + REPOSITORY
PLUGIN_SOURCE = SOURCE + '.git#plugin'
POLICY = {'protocol_version': 1, 'state_schema': 1}


def run(args, *, home=None, log=None, cwd=None):
    env = os.environ.copy()
    env.pop('PYTHONPATH', None)
    env.pop('PYTHONHOME', None)
    if home is not None:
        env['HERMES_HOME'] = str(home)
    try:
        with open(log or os.devnull, 'ab') as output:
            result = subprocess.run(args, cwd=cwd, env=env, stdout=output, stderr=output, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('An update command could not finish; see the private update log') from None
    if result.returncode:
        raise ValueError('An update command failed; see the private update log')


def native_install(home, commit, log):
    run([sys.executable, '-m', 'hermes_cli.main', 'plugins', 'install', PLUGIN_SOURCE,
         '--ref', commit, '--force', '--no-enable'], home=home, log=log)


def installed_profiles():
    try:
        from hermes_constants import get_default_hermes_root, named_profile_is_deleted
    except ImportError:
        raise ValueError('Run this command using the Python environment that runs Hermes') from None
    root = get_default_hermes_root().resolve()
    homes = [root]
    if (root / 'profiles').is_dir():
        homes += sorted(p for p in (root / 'profiles').iterdir()
                        if p.is_dir() and re.fullmatch(r'[a-z0-9][a-z0-9_.-]*', p.name)
                        and not named_profile_is_deleted(p))
    found = []
    for home in homes:
        plugin = home / 'plugins/hermes-jr'
        if not plugin.exists():
            continue
        if home.is_symlink() or plugin.is_symlink():
            raise ValueError('Linked profile or plugin directories need a manual update')
        metadata = home / 'plugins/.install-metadata.json'
        try:
            entry = json.loads(metadata.read_text())['hermes-jr']
        except (OSError, ValueError, KeyError, TypeError):
            raise ValueError('Native plugin installation metadata is missing; update manually') from None
        if entry.get('source') != PLUGIN_SOURCE or not re.fullmatch('[0-9a-f]{40}', entry.get('revision', '')):
            raise ValueError('This plugin uses a legacy layout or another source; follow the manual upgrade instructions')
        found.append((home, plugin, metadata))
    if not found:
        raise ValueError('No native Hermes Jr plugin installations found')
    return found


def source_digest(path):
    from .recovery import digest
    # Build artifacts are not installed source and must not hide actual source edits.
    with tempfile.TemporaryDirectory(prefix='jr-source-compare-') as temp:
        target = Path(temp) / 'source'
        shutil.copytree(path, target, symlinks=True, ignore=shutil.ignore_patterns(
            '__pycache__', '*.pyc', '*.pyo', '*.egg-info', 'build', 'dist', '.venv', '.git'))
        return digest(target)


def verify_profile_copies(profiles, work, log):
    baselines = {}
    for _, plugin, metadata in profiles:
        entry = json.loads(metadata.read_text())['hermes-jr']
        revision = entry['revision']
        if revision not in baselines:
            home = work / ('baseline-' + revision)
            home.mkdir(mode=0o700)
            native_install(home, revision, log)
            baselines[revision] = source_digest(home / 'plugins/hermes-jr')
        if source_digest(plugin) != baselines[revision]:
            raise ValueError('An installed plugin contains local changes; preserve them and update manually')


def package_layout():
    dist = importlib.metadata.distribution('hermes-jr-companion')
    direct = json.loads(dist.read_text('direct_url.json') or '{}')
    if direct.get('dir_info', {}).get('editable'):
        raise ValueError('Editable development installs need a manual update')
    site = Path(dist.locate_file('')).resolve()
    metadata = next((site / f.parts[0] for f in dist.files or [] if f.parts[0].endswith('.dist-info')), None)
    if not metadata or not (site / 'hermes_jr').is_dir():
        raise ValueError('Cannot safely identify the installed companion package')
    return dist, site, metadata


def validate_wheel(wheel, expected_version, installed):
    with zipfile.ZipFile(wheel) as archive:
        infos = [n for n in archive.namelist() if n.endswith('.dist-info/METADATA')]
        if len(infos) != 1:
            raise ValueError('Invalid update package')
        dirname = infos[0].split('/')[0]
        if dirname != 'hermes_jr_companion-' + expected_version + '.dist-info':
            raise ValueError('Update package does not match the selected release')
        for name in archive.namelist():
            if '..' in Path(name).parts or not name.startswith(('hermes_jr/', dirname + '/')):
                raise ValueError('Update package contains files outside the companion')
        entries = configparser.ConfigParser()
        entries.read_string(archive.read(dirname + '/entry_points.txt').decode())
        if entries.sections() != ['console_scripts'] or dict(entries['console_scripts']) != {'hermes-jr': 'hermes_jr.cli:main'}:
            raise ValueError('Update package changes executable ownership; use a manual update')
        wheel_info = BytesParser().parsebytes(archive.read(dirname + '/WHEEL'))
        if wheel_info['Root-Is-Purelib'] != 'true':
            raise ValueError('Update package changes installation layout')
        metadata = BytesParser().parsebytes(archive.read(infos[0]))
        if metadata['Name'] != 'hermes-jr-companion' or metadata['Version'] != expected_version:
            raise ValueError('Unexpected package identity')
        if not set(metadata.get_all('Requires-Dist') or []).issubset(set(installed.metadata.get_all('Requires-Dist') or [])):
            raise ValueError('This release adds or changes dependency requirements; no installed files were changed')
        return dirname


def verify_connection(state):
    """Check the newly imported code and live connection before committing an update."""
    if not state.get('service_url'):
        return  # An unconfigured installation has no live connection to validate.
    result = subprocess.run([sys.executable, '-m', 'hermes_jr.cli', 'doctor'],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45)
    try:
        health = json.loads(result.stdout)
        valid = (result.returncode == 0 and health.get('service') == 'ok'
                 and health.get('dashboard_rpc') == 'ok'
                 and health.get('installation', {}).get('status') == 'consistent')
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise ValueError('Updated companion failed its connection checks')


def install(state, release):
    from .release_signature import verify
    verify(release)
    if release.get('state') != 'available' or not re.fullmatch('[0-9a-f]{40}', release.get('commit', '')):
        raise ValueError('No verified newer stable release is available')
    if version(release['latest']) <= version(installed_version()):
        raise ValueError('The release is not newer than the installed companion')
    manager = Supervisor(state)
    with lock(state.directory / 'update.lock'):
        pointer = state.directory / 'last-update.json'
        previous_pointer = json.loads(pointer.read_text()) if pointer.exists() else None
        if previous_pointer:
            prior = Snapshot(previous_pointer['backup'])
            if prior.journal['phase'] not in ('complete', 'rolled_back', 'prepared'):
                raise ValueError('An interrupted update needs recovery first; run hermes jr rollback')
        profiles = installed_profiles()
        dist, site, old_metadata = package_layout()
        manager_state = manager.status()
        if manager_state['bridge_running'] and not manager_state['manager_active']:
            raise ValueError('Stop the foreground bridge before updating')
        backups = state.directory / 'update-backups'
        backups.mkdir(mode=0o700, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix='prepare-', dir=backups))
        log = work / 'update.log'
        log.touch(mode=0o600)
        # The native installer scans the exact commit in isolated profile state before it is built.
        verify_profile_copies(profiles, work, log)
        staging_home = work / 'profile'
        staging_home.mkdir(mode=0o700)
        native_install(staging_home, release['commit'], log)
        candidate = staging_home / 'plugins/hermes-jr'
        try:
            policy = json.loads((candidate / 'COMPATIBILITY.json').read_text())
        except (OSError, ValueError):
            raise ValueError('This release has no valid update compatibility declaration; use its manual instructions') from None
        if policy != POLICY:
            raise ValueError('This release needs a protocol or state migration; use its manual instructions')
        wheel_dir = work / 'wheels'
        run([sys.executable, '-m', 'pip', 'wheel', '--no-deps', str(candidate), '--wheel-dir', str(wheel_dir)], log=log)
        wheels = list(wheel_dir.glob('*.whl'))
        if len(wheels) != 1:
            raise ValueError('Could not build one unambiguous update package')
        metadata_name = validate_wheel(wheels[0], release['latest'], dist)
        resources = [site / 'hermes_jr', old_metadata, site / metadata_name,
                     Path(sysconfig.get_path('scripts')) / 'hermes-jr']
        resources += [path for _, plugin, metadata in profiles for path in (plugin, metadata)]
        snapshot = Snapshot.create(backups / uuid.uuid4().hex, resources,
                                   state_directory=str(state.directory.resolve()), python=sys.executable,
                                   previous_version=installed_version(), target_version=release['latest'],
                                   commit=release['commit'], log=str(log), restart=bool(manager_state['bridge_running']),
                                   stop_command=(['launchctl', 'bootout', f'{manager.domain}/{manager.label}'] if manager.platform == 'darwin' else ['systemctl', '--user', 'stop', manager.unit]))
        write_json(pointer, {'backup': str(snapshot.directory)})
        try:
            if manager_state['manager_active']:
                manager.stop()
            with lock(state.directory / 'bridge.lock'):
                snapshot.ensure_unchanged('before')
                snapshot.save(phase='applying')
                for home, _, _ in profiles:
                    native_install(home, release['commit'], log)
                run([sys.executable, '-m', 'pip', 'install', '--no-deps', '--force-reinstall', str(wheels[0])], log=log)
                run([sys.executable, '-m', 'pip', 'check'], log=log)
                run([sys.executable, '-I', '-c', 'from hermes_jr import cli, daemon; from hermes_jr.updates import installed_version; import argparse; assert installed_version() == ' + repr(release['latest']) + '; cli.configure_parser(argparse.ArgumentParser())'], log=log)
                from .installation_health import manifest_version
                for home, plugin, metadata in profiles:
                    if manifest_version(plugin / 'plugin.yaml') != release['latest'] or json.loads(metadata.read_text()).get('hermes-jr', {}).get('revision') != release['commit']:
                        raise ValueError('Updated native plugin does not match the verified package release')
                    run([sys.executable, '-m', 'hermes_cli.main', 'plugins', 'doctor', str(plugin), '--ci'], home=home, log=log)
            if snapshot.journal['restart']:
                manager.start()
                verify_connection(state)
            snapshot.complete()
        except BaseException:
            if snapshot.journal['phase'] == 'prepared':
                if previous_pointer:
                    write_json(pointer, previous_pointer)
                else:
                    pointer.unlink(missing_ok=True)
                if snapshot.journal['restart']:
                    manager.start()
                raise ValueError('Update stopped before replacing files; installed code was left unchanged') from None
            # Stop only this bridge, restore code, and leave live Hermes processes alone.
            try:
                manager.stop()
                with lock(state.directory / 'bridge.lock'):
                    snapshot.restore(check_current=False)
                if snapshot.journal['restart']:
                    manager.start()
            except BaseException:
                raise ValueError('Update and automatic recovery could not finish. Keep the service stopped; run hermes jr rollback or the recover.py saved in update-backups') from None
            raise ValueError('Update failed; the previous companion was restored. See the private update log') from None
    print('Companion updated. Pairings preserved. Restart loaded Hermes processes when their work is idle, then run hermes jr doctor.')


def rollback(state):
    with lock(state.directory / 'update.lock'):
        pointer = state.directory / 'last-update.json'
        if not pointer.exists():
            raise ValueError('No managed update backup exists')
        snapshot = Snapshot(json.loads(pointer.read_text())['backup'])
        if snapshot.journal['phase'] == 'rolled_back':
            raise ValueError('The previous companion has already been restored')
        if snapshot.journal['phase'] == 'prepared':
            raise ValueError('This update never replaced installed files; there is nothing to roll back')
        if snapshot.journal['phase'] == 'complete':
            snapshot.ensure_unchanged('after')
        manager = Supervisor(state)
        running = manager.status()['bridge_running']
        manager.stop()
        with lock(state.directory / 'bridge.lock'):
            snapshot.restore(check_current=snapshot.journal['phase'] == 'complete')
        if running or snapshot.journal.get('restart'):
            manager.start()
    print('Previous companion restored. Pairings preserved. Restart loaded Hermes processes when idle and run hermes jr doctor.')
