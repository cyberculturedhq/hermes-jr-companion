"""Run with a real Hermes Python environment on a logged-in macOS desktop."""
import asyncio
import json
from pathlib import Path
import socket
import tempfile
import time
import aiohttp
from hermes_jr.backend import BackendSupervisor
from hermes_jr.gateway import Gateway
from hermes_jr.state import State

async def main():
    with tempfile.TemporaryDirectory(prefix='hermes-jr-backend-check-') as temp:
        root = Path(temp)
        profile = root / 'hermes'
        profile.mkdir()
        (profile / 'config.yaml').write_text('terminal:\n  backend: local\n')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        state = State(root / 'companion')
        state.settings({'dashboard_url': f'http://127.0.0.1:{port}'})
        manager = BackendSupervisor(state, home=root / 'service-files', hermes_home=profile)
        checks = {}
        try:
            started = time.monotonic()
            manager.install()
            checks['bounded_registration'] = time.monotonic() - started < 20
            deadline = time.monotonic() + 40
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=3)) as client:
                while time.monotonic() < deadline:
                    try:
                        await Gateway(state, client).probe()
                        checks['authenticated_rpc'] = True
                        break
                    except (OSError, ValueError, aiohttp.ClientError, asyncio.TimeoutError):
                        await asyncio.sleep(1)
            checks.setdefault('authenticated_rpc', False)
            before = manager.path.read_bytes()
            manager.install()
            checks['repeat_preserves_definition'] = manager.path.read_bytes() == before
        finally:
            manager.uninstall()
            deadline = time.monotonic() + 10
            while manager.listening() and time.monotonic() < deadline:
                await asyncio.sleep(.2)
            checks['removed_service'] = not manager.path.exists() and not manager.active()
            checks['stopped_listener'] = not manager.listening()
            checks['preserved_state'] = state.get('dashboard_url') == f'http://127.0.0.1:{port}'
        print(json.dumps(checks))
        assert all(checks.values()), checks

asyncio.run(main())
