import unittest
from hermes_jr.diagnostics import recovery_action

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
