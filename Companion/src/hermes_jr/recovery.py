"""Standard-library-only code snapshots; also copied beside backups for emergency recovery."""
from __future__ import annotations
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import subprocess
import time
import tempfile
import uuid


def write_json(path, value):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def ignored(path):
    return '__pycache__' in path.parts or path.suffix in ('.pyc', '.pyo')


def digest(path):
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        return None
    result = hashlib.sha256()
    entries = [path] if not path.is_dir() or path.is_symlink() else sorted(path.rglob('*'))
    for item in entries:
        if ignored(item.relative_to(path) if item != path else Path(item.name)):
            continue
        result.update(str(item.relative_to(path)).encode())
        if item.is_symlink():
            result.update(b'link' + os.readlink(item).encode())
        elif item.is_file():
            result.update(b'file')
            with item.open('rb') as stream:
                for chunk in iter(lambda: stream.read(65536), b''):
                    result.update(chunk)
        else:
            result.update(b'dir')
    return result.hexdigest()


def copy(source, target):
    source, target = Path(source), Path(target)
    if source.is_dir():
        shutil.copytree(source, target, symlinks=True, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '*.pyo'))
    else:
        shutil.copy2(source, target, follow_symlinks=False)


def remove(path):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


class Snapshot:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.journal_path = self.directory / 'journal.json'
        self.journal = json.loads(self.journal_path.read_text())

    @classmethod
    def create(cls, directory, resources, **details):
        directory = Path(directory)
        directory.mkdir(parents=True, mode=0o700)
        records = []
        paths = list(dict.fromkeys(Path(x).absolute() for x in resources))
        if any(p.is_symlink() for p in paths):
            raise ValueError('Update targets must not be symlinks')
        if any(p != q and p in q.parents for p in paths for q in paths):
            raise ValueError('Overlapping update targets')
        for i, path in enumerate(paths):
            before = digest(path)
            if before is not None:
                copy(path, directory / str(i))
                if digest(directory / str(i)) != before:
                    raise ValueError('An update target changed while creating its backup')
            records.append({'path': str(path), 'backup': str(i), 'before': before})
        write_json(directory / 'journal.json', {'phase': 'prepared', 'resources': records, **details})
        # Recovery must not depend on the package remaining importable after a failed pip run.
        shutil.copy2(__file__, directory / 'recover.py')
        return cls(directory)

    def save(self, **values):
        self.journal.update(values)
        write_json(self.journal_path, self.journal)

    def ensure_unchanged(self, field):
        if any(digest(Path(r['path'])) != r.get(field) for r in self.journal['resources']):
            raise ValueError('Installed files changed outside this update; refusing to overwrite them')

    def complete(self):
        for item in self.journal['resources']:
            item['after'] = digest(Path(item['path']))
        self.save(phase='complete')

    def restore(self, *, check_current=True):
        if check_current:
            self.ensure_unchanged('after')
        for item in self.journal['resources']:
            if item['before'] is not None and digest(self.directory / item['backup']) != item['before']:
                raise ValueError('Rollback backup failed its integrity check')
        self.save(phase='restoring')
        for item in self.journal['resources']:
            target = Path(item['path'])
            staged = target.parent / ('.hermes-jr-restore-' + uuid.uuid4().hex)
            displaced = target.parent / ('.hermes-jr-old-' + uuid.uuid4().hex)
            try:
                if item['before'] is not None:
                    copy(self.directory / item['backup'], staged)
                if target.exists() or target.is_symlink():
                    os.replace(target, displaced)
                try:
                    if item['before'] is not None:
                        os.replace(staged, target)
                except BaseException:
                    if displaced.exists() or displaced.is_symlink():
                        os.replace(displaced, target)
                    raise
            finally:
                remove(staged)
                remove(displaced)
        self.save(phase='rolled_back')


@contextlib.contextmanager
def lock(path):
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, 'a+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another update or bridge process is running') from None
        yield


def emergency_recover():
    snapshot = Snapshot(Path(__file__).resolve().parent)
    state = Path(snapshot.journal['state_directory'])
    command = snapshot.journal.get('stop_command')
    if command:
        subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        time.sleep(1)
    with lock(state / 'update.lock'), lock(state / 'bridge.lock'):
        phase = snapshot.journal['phase']
        if phase == 'prepared':
            raise ValueError('This update never replaced installed files')
        if phase == 'rolled_back':
            print('This backup has already been restored.')
            return
        snapshot.restore(check_current=phase == 'complete')
    print('Previous companion restored. Start its service and run hermes jr doctor. Pairings and private state were preserved.')


if __name__ == '__main__':
    try:
        emergency_recover()
    except Exception:
        raise SystemExit('Recovery could not finish. Keep the service stopped and inspect this private backup before retrying.') from None
