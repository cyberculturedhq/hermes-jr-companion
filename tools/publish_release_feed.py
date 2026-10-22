#!/usr/bin/env python3
"""Publish signed metadata only after its companion package is on PyPI."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'plugin/src'))
from hermes_jr.release_signature import verify

FEED = 'https://hermes-jr-companion.cybercultured.com/v1/companion-release'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request_json(url, *, body=None, token=None, limit=4096):
    headers = {'Accept': 'application/json', 'User-Agent': 'hermes-jr-release-publisher'}
    if body is not None:
        headers['Content-Type'] = 'application/json'
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
        if response.status != 200:
            raise ValueError('Unexpected publication response')
        raw = response.read(limit + 1)
        if len(raw) > limit:
            raise ValueError('Publication response is too large')
        return json.loads(raw)


def validate(value):
    if not isinstance(value, dict) or set(value) != {'schema', 'version', 'commit', 'signature'} or type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Invalid release manifest')
    verify({'latest': value['version'], 'commit': value['commit'], 'signature': value['signature']})
    return value


def components(version):
    return tuple(map(int, version.split('.')))


def publish(manifest, token):
    validate(manifest)
    if not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
        raise ValueError('Release publication credential is missing or invalid')
    version = manifest['version']
    package = request_json('https://pypi.org/pypi/hermes-jr-companion/' + version + '/json', limit=262144)
    files = package.get('urls', [])
    if package.get('info', {}).get('version') != version or not files or not any(f.get('packagetype') == 'bdist_wheel' and not f.get('yanked') for f in files):
        raise ValueError('The release package is not available on PyPI')
    payload = json.dumps(manifest).encode()
    for attempt in range(3):
        try:
            request_json(FEED + '/publish', body=payload, token=token)
            break
        except urllib.error.HTTPError as error:
            if error.code != 409 or attempt == 2:
                raise
            time.sleep(1)
    current = validate(request_json(FEED))
    if components(current['version']) < components(version) or (current['version'] == version and current != manifest):
        raise ValueError('The public feed does not match the signed release')
    return current['version']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=Path, required=True)
    args = parser.parse_args()
    try:
        raw = args.manifest.read_bytes()
        if len(raw) > 4096:
            raise ValueError('Release manifest is too large')
        version = publish(json.loads(raw), os.environ.get('RELEASE_FEED_PUBLISH_TOKEN', ''))
    except Exception:
        # Network exception strings can include credentials or response bodies.
        sys.exit('Release feed publication failed. Check the signed manifest, PyPI package, and publisher access.')
    print('Signed release feed verified at version ' + version)

if __name__ == '__main__':
    main()
