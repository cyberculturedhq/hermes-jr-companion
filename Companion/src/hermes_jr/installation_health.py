"""Check native plugin and imported package identity before enrollment."""
import os
from pathlib import Path
import re
from .updates import installed_version


def manifest_version(path):
    try:
        text = Path(path).read_text()
    except OSError:
        return None
    match = re.search(r'^version:\s*[\"\']?(\d+\.\d+\.\d+)[\"\']?\s*$', text, re.M)
    return match.group(1) if match else None


def check(root=None):
    if root is None:
        try:
            from hermes_constants import get_default_hermes_root
            root = get_default_hermes_root()
        except ImportError:
            return {'status': 'standalone', 'package_version': installed_version(), 'profiles': []}
    root = Path(root)
    homes = [root]
    if (root / 'profiles').is_dir():
        homes += sorted(p for p in (root / 'profiles').iterdir() if p.is_dir() and re.fullmatch('[a-z0-9][a-z0-9_.-]*', p.name))
    active = Path(os.environ.get('HERMES_HOME', str(root)))
    if active not in homes: homes.append(active)
    expected = installed_version()
    profiles = []
    for home in homes:
        plugin = home / 'plugins/hermes-jr'
        if plugin.exists():
            actual = manifest_version(plugin / 'plugin.yaml')
            profiles.append({'profile': 'default' if home == root else home.name, 'version': actual, 'matches': actual == expected})
    return {'status': 'consistent' if profiles and all(p['matches'] for p in profiles) else ('mismatch' if profiles else 'missing'),
            'package_version': expected, 'profiles': profiles}


def require_consistent():
    value = check()
    if value['status'] not in {'consistent', 'standalone'}:
        raise ValueError('Companion package and native plugin installation are missing or inconsistent. Install both from the same verified release in every installed profile, then restart the companion. Run hermes jr doctor to verify; no pairing attempt was created.')
