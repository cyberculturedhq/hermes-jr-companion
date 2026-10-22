"""Read-only stable release checks. Downloaded metadata never executes code."""
from __future__ import annotations
import asyncio
import importlib.metadata
import json
import logging
import re
import time
import aiohttp
from .service import read_bounded
from .release_signature import verify

REPOSITORY = 'cyberculturedhq/hermes-jr-companion'
FEED = 'https://hermes-jr-companion.cybercultured.com/v1/companion-release'
INTERVAL = 24 * 60 * 60
from . import __version__ as VERSION


def version(value):
    match = re.fullmatch(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', value)
    if not match:
        raise ValueError('Release is not a stable semantic version')
    return tuple(map(int, match.groups()))


def installed_version():
    try:
        return importlib.metadata.version('hermes-jr-companion')
    except importlib.metadata.PackageNotFoundError:
        return VERSION


async def get_json(client, url):
    async with client.get(url, allow_redirects=False, timeout=aiohttp.ClientTimeout(total=15),
                          headers={'Accept': 'application/json', 'User-Agent': 'hermes-jr-companion'}) as response:
        if response.status == 404:
            return None
        if response.status != 200:
            raise ValueError('Release metadata unavailable')
        return json.loads(await read_bounded(response, 4096))


async def check(state, client, *, force=False):
    prior = state.get('update_status', {})
    if not force and prior.get('installed') == installed_version() and time.time() - prior.get('checked_at', 0) < INTERVAL:
        return prior
    result = {'checked_at': int(time.time()), 'installed': installed_version(), 'state': 'unavailable'}
    try:
        release = await get_json(client, FEED)
        if release is None:
            result['state'] = 'no_stable_release'
        else:
            if not isinstance(release, dict) or set(release) != {'schema', 'version', 'commit', 'signature'} or type(release['schema']) is not int or release['schema'] != 1:
                raise ValueError('Invalid release information')
            tag = release['version']
            if not isinstance(tag, str) or len(tag) > 32 or tag.startswith('v'):
                raise ValueError('Invalid release version')
            latest = version(tag)
            verified = {'latest': tag, 'commit': release['commit'], 'signature': release['signature']}
            verify(verified)
            result.update(verified, state='available' if latest > version(result['installed']) else 'current',
                          url='https://github.com/' + REPOSITORY + '/releases/tag/v' + tag)
    except (ValueError, TypeError, KeyError, aiohttp.ClientError, asyncio.TimeoutError, TimeoutError):
        pass  # Do not include raw network errors, metadata, credentials, or URLs in logs.
    state.settings({'update_status': result})
    return result


async def watch(state, client):
    while True:
        if state.get('update_checks_enabled', True):
            previous = state.get('update_status', {})
            result = await check(state, client)
            if result.get('state') == 'available' and result.get('latest') != previous.get('latest'):
                logging.getLogger('hermes_jr').info('A companion update is available; run hermes jr update')
        await asyncio.sleep(60)


def public_status(state):
    """Only validated version information crosses to the phone, never a remote URL."""
    current = installed_version()
    result = {'installed': current, 'available': False, 'tracking': 1,
              'checks_enabled': state.get('update_checks_enabled', True)}
    cached = state.get('update_status', {})
    if not state.get('update_checks_enabled', True) or cached.get('state') != 'available':
        return result
    try:
        latest = cached['latest']
        if version(latest) > version(current) and 0 <= time.time() - cached['checked_at'] <= 7 * INTERVAL:
            result.update(available=True, version=latest)
    except (ValueError, TypeError, KeyError):
        pass
    return result
