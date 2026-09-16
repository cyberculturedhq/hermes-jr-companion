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
from .release_signature import verify, signature_from_body

REPOSITORY = 'cyberculturedhq/hermes-jr-companion'
API = 'https://api.github.com/repos/' + REPOSITORY
INTERVAL = 24 * 60 * 60
VERSION = '0.13.1'


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
                          headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'hermes-jr-companion'}) as response:
        if response.status == 404:
            return None
        if response.status != 200:
            raise ValueError('Release metadata unavailable')
        return json.loads(await read_bounded(response, 128_000))


async def check(state, client, *, force=False):
    prior = state.get('update_status', {})
    if not force and prior.get('installed') == installed_version() and time.time() - prior.get('checked_at', 0) < INTERVAL:
        return prior
    result = {'checked_at': int(time.time()), 'installed': installed_version(), 'state': 'unavailable'}
    try:
        release = await get_json(client, API + '/releases/latest')
        if release is None:
            result['state'] = 'no_stable_release'
        else:
            tag = release['tag_name']
            latest = version(tag)
            if release.get('draft') or release.get('prerelease'):
                raise ValueError('Not a stable release')
            # Resolve a tag to a commit, including annotated tags. Never follow arbitrary URLs.
            ref = await get_json(client, API + '/git/ref/tags/' + tag)
            obj = ref['object']
            for _ in range(3):
                sha = obj['sha']
                if not re.fullmatch('[0-9a-f]{40}', sha):
                    raise ValueError('Invalid commit')
                if obj['type'] == 'commit':
                    break
                if obj['type'] != 'tag':
                    raise ValueError('Invalid tag')
                annotated = await get_json(client, API + '/git/tags/' + sha)
                obj = annotated['object']
            else:
                raise ValueError('Too many tag indirections')
            signature = signature_from_body(release.get('body'))
            verify({'latest': tag.lstrip('v'), 'commit': sha, 'signature': signature})
            result.update(signature=signature, state='available' if latest > version(result['installed']) else 'current',
                          latest=tag.lstrip('v'), commit=sha,
                          url='https://github.com/' + REPOSITORY + '/releases/tag/' + tag)
    except (ValueError, TypeError, KeyError, aiohttp.ClientError, TimeoutError):
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
    result = {'installed': current, 'available': False}
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
