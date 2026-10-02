import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch
from hermes_jr.diagnostics import check, recovery_action
from hermes_jr.state import State

class DiagnosticActions(unittest.TestCase):
    def test_missing_backend_points_to_dedicated_startup_not_gateway(self):
        value = recovery_action({'dashboard_rpc':'not_listening','service':'ok'})
        self.assertIn('hermes jr backend install',value['action'])
        self.assertIn('different service',value['problem'])

    def test_authentication_failure_does_not_start_another_server(self):
        value=recovery_action({'dashboard_rpc':'authentication_or_protocol_failed','service':'ok'})
        self.assertNotIn('backend install',value['action'])

    def test_healthy_connection_needs_no_repair(self):
        self.assertIsNone(recovery_action({'dashboard_rpc':'ok','service':'ok'}))


class DiagnosticTimeoutTests(unittest.IsolatedAsyncioTestCase):
    async def test_python310_async_timeouts_are_reported_without_crashing(self):
        class AsyncTimeout(Exception):
            pass
        with tempfile.TemporaryDirectory() as temp:
            state = State(Path(temp))
            state.set('host_token', 'fixture')
            gateway = AsyncMock()
            gateway.authenticate.side_effect = AsyncTimeout()
            gateway.probe.side_effect = AsyncTimeout()
            with patch('hermes_jr.diagnostics.asyncio.TimeoutError', AsyncTimeout), \
                 patch('hermes_jr.diagnostics.Service.request', AsyncMock(side_effect=AsyncTimeout())), \
                 patch('hermes_jr.diagnostics.Gateway', return_value=gateway), \
                 patch('hermes_jr.installation_health.check', return_value={'status': 'standalone'}):
                result = await check(state, None)
            self.assertEqual(result['service'], 'unavailable')
            self.assertEqual(result['dashboard'], 'unavailable')
            self.assertEqual(result['dashboard_rpc'], 'timeout')
