import argparse
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

from hermes_jr import cli
from hermes_jr.state import State


@contextlib.asynccontextmanager
async def client(**kwargs):
    yield None


class SecurityCliTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = State(Path(self.temp.name))

    async def execute(self, *args):
        parser = argparse.ArgumentParser()
        cli.configure_parser(parser)
        with patch.object(cli, 'State', return_value=self.state), \
             patch.object(cli, 'client_session', client), contextlib.redirect_stdout(io.StringIO()):
            await cli.execute(parser.parse_args(args))

    async def test_installed_update_preserves_receipt_and_uses_installed_verifier(self):
        release = {'state': 'available', 'latest': '0.19.0'}
        with patch('hermes_jr.update_requests.decode') as decode, \
             patch('hermes_jr.updates.check', new=AsyncMock(return_value=release)) as check, \
             patch('hermes_jr.update_requests.run_tracked') as tracked, \
             patch('hermes_jr.installer.install') as install:
            await self.execute('update', '--install', '--receipt', 'fixture')
            decode.assert_called_once_with('fixture')
            check.assert_awaited_once()
            tracked.assert_called_once_with(self.state, release, 'fixture')
            install.assert_not_called()
        with patch('hermes_jr.updates.check', new=AsyncMock()) as check:
            with self.assertRaises(ValueError):
                await self.execute('update', '--receipt', 'fixture')
            check.assert_not_awaited()

    async def test_lost_registration_response_reuses_the_private_host_token(self):
        requests = []
        installation = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        async def request(method, path, body=None):
            if path == '/v1/capabilities':
                return {'protocol_version': 1, 'registration_requires_ticket': True}
            if path == '/v1/pairing/key':
                return {'public_key': 'fixture'}
            requests.append(body)
            if len(requests) == 1:
                raise ValueError('Lost response')
            return {'installation_id': installation, 'host_token': body['host_token']}
        service = Mock(request=AsyncMock(side_effect=request))
        with patch.object(cli, 'Service', return_value=service), patch('hermes_jr.setup_crypto.verify_ticket'):
            with self.assertRaisesRegex(ValueError, 'Lost response'):
                await self.execute('setup', '--service', 'https://relay.test', '--ticket', 'fixture')
            self.assertIsNone(self.state.get('installation_id'))
            await self.execute('setup', '--service', 'https://relay.test', '--ticket', 'fixture')
        self.assertEqual(requests[0], requests[1])
        self.assertEqual(self.state.get('host_token'), requests[0]['host_token'])
        self.assertEqual(self.state.get('installation_id'), installation)

    async def test_prepare_checks_installed_services_without_starting_them(self):
        health = {'installation': {'status': 'consistent'}, 'service': 'ok', 'dashboard_rpc': 'ok'}
        with patch('hermes_jr.diagnostics.check', new=AsyncMock(return_value=health)), \
             patch('hermes_jr.supervisor.Supervisor') as supervisor, \
             patch('hermes_jr.backend.BackendSupervisor') as backend:
            supervisor.return_value.status.return_value = {'manager_active': True}
            backend.return_value.status.return_value = {'manager_active': True}
            with patch('importlib.metadata.version', return_value='0.18.1'):
                await self.execute('prepare')
            supervisor.return_value.install.assert_not_called()
            supervisor.return_value.start.assert_not_called()
            backend.return_value.install.assert_not_called()
