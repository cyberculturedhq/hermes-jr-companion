"""Signed companion updates through Hermes' managed plugin environment."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

from .recovery import Snapshot, lock, write_json
from .supervisor import Supervisor, private_write
from .updates import REPOSITORY, version

PLUGIN_SOURCE = 'https://github.com/' + REPOSITORY + '.git#plugin'
POLICY = {'protocol_version': 1, 'state_schema': 1}


def managed_python():
    """Re-read the selected interpreter after each PM publication."""
    try:
        from hermes_cli.main import PROJECT_ROOT
        from pm.environments import project_python
        return str(project_python(PROJECT_ROOT))
    except ImportError:
        raise ValueError('This companion release requires Hermes package manager') from None


def run(args, *, home=None, log=None):
    env = os.environ.copy()
    env.pop('PYTHONPATH', None)
    env.pop('PYTHONHOME', None)
    if home is not None:
        env['HERMES_HOME'] = str(home)
    try:
        with open(log or os.devnull, 'ab') as output:
            result = subprocess.run(args, env=env, stdout=output, stderr=output, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        raise ValueError('An update command could not finish; see the private update log') from None
    if result.returncode:
        raise ValueError('An update command failed; see the private update log')


def hermes(home, log, *args):
    run([managed_python(), '-m', 'hermes_cli.main', *args], home=home, log=log)


def native_install(home, commit, log):
    hermes(home, log, 'plugins', 'install', PLUGIN_SOURCE,
           '--ref', commit, '--force', '--no-enable')


def installed_profiles():
    try:
        from pm.plugins_state import dependency_homes
    except ImportError:
        raise ValueError('This companion release requires Hermes package manager') from None
    found = []
    for home in dependency_homes():
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


def active_homes(profiles):
    from pm.workspace import enabled_plugin_dirs
    active = {path.resolve() for path in enabled_plugin_dirs()}
    known = {plugin.resolve() for _, plugin, _ in profiles}
    if any(path.name == 'hermes-jr' and path not in known for path in active):
        raise ValueError('An enabled Hermes Jr copy is outside the managed profile set')
    return [home for home, plugin, _ in profiles if plugin.resolve() in active]


def source_digest(path):
    from .recovery import digest
    with tempfile.TemporaryDirectory(prefix='jr-source-compare-') as temp:
        target = Path(temp) / 'source'
        shutil.copytree(path, target, symlinks=True, ignore=shutil.ignore_patterns(
            '__pycache__', '*.pyc', '*.pyo', '*.egg-info', 'build', 'dist', '.venv', '.git'))
        return digest(target)


def verify_profile_copies(profiles, work, log):
    baselines = {}
    for _, plugin, metadata in profiles:
        revision = json.loads(metadata.read_text())['hermes-jr']['revision']
        if revision not in baselines:
            home = work / ('baseline-' + revision)
            home.mkdir(mode=0o700)
            native_install(home, revision, log)
            baselines[revision] = source_digest(home / 'plugins/hermes-jr')
        if source_digest(plugin) != baselines[revision]:
            raise ValueError('An installed plugin contains local changes; preserve them and update manually')


def validate_candidate(candidate, expected_version):
    from .installation_health import manifest_version
    from pm.plugin_declarations import read_python_declaration
    if (candidate / 'pyproject.toml').exists() or manifest_version(candidate / 'plugin.yaml') != expected_version:
        raise ValueError('Release plugin layout or version does not match the signed release')
    if read_python_declaration(candidate).install_requirements != (f'hermes-jr-companion=={expected_version}',):
        raise ValueError('Release plugin does not pin its companion package')
    try:
        policy = json.loads((candidate / 'COMPATIBILITY.json').read_text())
    except (OSError, ValueError):
        raise ValueError('This release has no valid update compatibility declaration') from None
    if policy != POLICY:
        raise ValueError('This release needs a protocol or state migration; use its manual instructions')


def managed_version():
    try:
        result = subprocess.run(
            [managed_python(), '-I', '-c',
             'import importlib.metadata; print(importlib.metadata.version("hermes-jr-companion"))'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def verify_package(expected, profiles, commit, log):
    if managed_version() != expected:
        raise ValueError('Hermes did not select the expected companion package')
    run([managed_python(), '-I', '-c',
         'from hermes_jr import cli, daemon; import argparse; '
         'cli.configure_parser(argparse.ArgumentParser())'], log=log)
    from .installation_health import manifest_version
    for home, plugin, metadata in profiles:
        if manifest_version(plugin / 'plugin.yaml') != expected:
            raise ValueError('Installed plugin version does not match the package')
        if commit and json.loads(metadata.read_text()).get('hermes-jr', {}).get('revision') != commit:
            raise ValueError('Installed plugin commit does not match the signed release')
        hermes(home, log, 'plugins', 'doctor', str(plugin), '--ci')


def verify_connection(state):
    if not state.get('service_url'):
        return
    result = subprocess.run([managed_python(), '-m', 'hermes_jr.cli', 'doctor'],
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


def disable_active(profiles, log):
    for home in active_homes(profiles):
        hermes(home, log, 'plugins', 'disable', 'hermes-jr')


def enable_homes(homes, log):
    for home in homes:
        hermes(home, log, 'plugins', 'enable', 'hermes-jr')


def refresh_service(manager, *, restart):
    if not manager.path.is_file():
        return
    private_write(manager.path, manager.definition(managed_python()))
    if manager.platform == 'linux':
        manager.command(['systemctl', '--user', 'daemon-reload'])
    if restart:
        manager.start()


def install(state, release, *, receipt_id=None):
    from .release_signature import verify
    verify(release)
    if release.get('state') != 'available' or not re.fullmatch('[0-9a-f]{40}', release.get('commit', '')):
        raise ValueError('No verified newer stable release is available')
    current = managed_version()
    if current is None or version(release['latest']) <= version(current):
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
        active = active_homes(profiles)
        if not active:
            raise ValueError('No Hermes Jr profile is enabled; enable one profile through Hermes before updating')
        manager_state = manager.status()
        if manager_state['bridge_running'] and not manager_state['manager_active']:
            raise ValueError('Stop the foreground bridge before updating')
        backups = state.directory / 'update-backups'
        backups.mkdir(mode=0o700, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix='prepare-', dir=backups))
        log = work / 'update.log'
        log.touch(mode=0o600)
        verify_profile_copies(profiles, work, log)
        staging_home = work / 'profile'
        staging_home.mkdir(mode=0o700)
        native_install(staging_home, release['commit'], log)
        validate_candidate(staging_home / 'plugins/hermes-jr', release['latest'])
        resources = [path for _, plugin, metadata in profiles for path in (plugin, metadata)]
        snapshot = Snapshot.create(backups / uuid.uuid4().hex, resources,
                                   state_directory=str(state.directory.resolve()),
                                   previous_version=current, target_version=release['latest'],
                                   commit=release['commit'], update_request=receipt_id, log=str(log),
                                   enabled_homes=[str(home) for home in active],
                                   restart=bool(manager_state['manager_active']),
                                   stop_command=(['launchctl', 'bootout', f'{manager.domain}/{manager.label}']
                                                 if manager.platform == 'darwin' else ['systemctl', '--user', 'stop', manager.unit]))
        write_json(pointer, {'backup': str(snapshot.directory)})
        try:
            if manager_state['manager_active']:
                manager.stop()
            with lock(state.directory / 'bridge.lock'):
                snapshot.ensure_unchanged('before')
                snapshot.save(phase='applying')
                disable_active(profiles, log)
                for home, _, _ in profiles:
                    native_install(home, release['commit'], log)
                enable_homes(active, log)
                verify_package(release['latest'], profiles, release['commit'], log)
            refresh_service(manager, restart=bool(manager_state['manager_active']))
            if manager_state['manager_active']:
                verify_connection(state)
            snapshot.complete()
        except BaseException:
            try:
                manager.stop()
                with lock(state.directory / 'bridge.lock'):
                    disable_active(profiles, log)
                    snapshot.restore(check_current=False)
                    enable_homes(active, log)
                    verify_package(current, profiles, None, log)
                refresh_service(manager, restart=bool(manager_state['manager_active']))
                if previous_pointer:
                    write_json(pointer, previous_pointer)
                else:
                    pointer.unlink(missing_ok=True)
            except BaseException:
                raise ValueError('Update and automatic recovery could not finish. Keep the bridge stopped; inspect the saved update log and backup') from None
            raise ValueError('Update failed; the previous companion was restored. See the private update log') from None
    print('Companion updated. Pairings preserved. Restart loaded Hermes processes when idle, then run hermes jr doctor.')


def rollback(state):
    with lock(state.directory / 'update.lock'):
        pointer = state.directory / 'last-update.json'
        if not pointer.exists():
            raise ValueError('No managed update backup exists')
        snapshot = Snapshot(json.loads(pointer.read_text())['backup'])
        if snapshot.journal['phase'] != 'complete':
            raise ValueError('The previous update is not complete and cannot be rolled back automatically')
        profiles = installed_profiles()
        active = [Path(home) for home in snapshot.journal['enabled_homes']]
        if set(active_homes(profiles)) != set(active):
            raise ValueError('Profile enablement changed since the update; preserve those choices and roll back manually')
        snapshot.ensure_unchanged('after')
        manager = Supervisor(state)
        running = manager.status()['manager_active']
        manager.stop()
        try:
            with lock(state.directory / 'bridge.lock'):
                disable_active(profiles, snapshot.journal['log'])
                snapshot.restore(check_current=False)
                enable_homes(active, snapshot.journal['log'])
                verify_package(snapshot.journal['previous_version'], installed_profiles(), None, snapshot.journal['log'])
            refresh_service(manager, restart=running)
        except BaseException:
            raise ValueError('Rollback could not finish; keep the bridge stopped and inspect the saved update log and backup') from None
    print('Previous companion restored. Pairings preserved. Restart loaded Hermes processes when idle and run hermes jr doctor.')
