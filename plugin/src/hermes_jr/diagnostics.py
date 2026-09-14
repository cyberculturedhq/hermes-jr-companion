"""Bounded, read-only connection checks without transcript or credential output."""
import asyncio
import time
import aiohttp
from .gateway import Gateway
from .service import Service, read_bounded


async def check(state, client):
    result = {'checked_at': int(time.time()), 'configured': bool(state.get('host_token')),
              'service': 'unconfigured', 'dashboard': 'unavailable', 'dashboard_plugin': 'unavailable',
              'dashboard_rpc': 'unavailable'}
    if result['configured']:
        try:
            value = await asyncio.wait_for(Service(state, client).request('GET', '/v1/capabilities'), 10)
            result['service'] = 'ok' if isinstance(value, dict) and value.get('protocol_version') == 1 else 'incompatible'
            result['service_push'] = isinstance(value, dict) and value.get('push') is True
        except (aiohttp.ClientError, ValueError, KeyError, TimeoutError):
            result['service'] = 'unavailable'
    try:
        gateway = Gateway(state, client)
        await asyncio.wait_for(gateway.authenticate(), 10)
        result['dashboard'] = 'authenticated'
        headers = dict(gateway.headers)
        # HTTP uses the same local session header as Gateway.http.
        if gateway.local_token:
            headers['X-Hermes-Session-Token'] = gateway.local_token
        async with client.get(gateway.origin + '/api/plugins/hermes-jr/v1/capabilities',
                              headers=headers, allow_redirects=False, timeout=aiohttp.ClientTimeout(total=10)) as response:
            import json
            if response.status == 200:
                data = json.loads(await read_bounded(response, 4096))
                result['dashboard_plugin'] = 'ok' if isinstance(data, dict) and data.get('protocol_version') == 1 else 'incompatible'
            else:
                result['dashboard_plugin'] = 'not_loaded_or_unauthorized'
    except (aiohttp.ClientError, ValueError, KeyError, TimeoutError):
        pass
    try:
        await Gateway(state, client).probe()
        result['dashboard_rpc'] = 'ok'
    except aiohttp.WSServerHandshakeError as exc:
        result['dashboard_rpc'] = 'upgrade_rejected'
        result['dashboard_rpc_http_status'] = exc.status
    except aiohttp.ClientConnectorError:
        result['dashboard_rpc'] = 'not_listening'
    except TimeoutError:
        result['dashboard_rpc'] = 'timeout'
    except (aiohttp.ClientError, ValueError, KeyError, PermissionError, ConnectionError):
        result['dashboard_rpc'] = 'authentication_or_protocol_failed'
    state.settings({'health': result})
    return result


async def watch(state, client):
    while True:
        await check(state, client)
        await asyncio.sleep(60)
