from types import SimpleNamespace
import unittest

from tools.compatibility.support import bind_request_sinks


class RequestSinkTests(unittest.TestCase):
    def test_old_required_and_extended_sink_signatures(self):
        seen = []
        write, emit = object(), object()

        def old(write_json, emit):
            seen.append((write_json, emit))

        def current(write_json, emit, answerable):
            self.assertTrue(answerable('fixture'))
            seen.append((write_json, emit))

        def extended(write_json, emit, answerable, clients=None):
            self.assertTrue(answerable('fixture'))
            self.assertIsNone(clients)
            seen.append((write_json, emit))

        def keyword_only(write_json, emit, *, answerable, clients=None):
            extended(write_json, emit, answerable, clients)

        for bind in (old, current, extended, keyword_only):
            with self.subTest(signature=bind.__name__):
                bind_request_sinks(SimpleNamespace(bind_sinks=bind), write, emit)
                self.assertEqual(seen[-1], (write, emit))
        self.assertEqual(len(seen), 4)

    def test_sink_failure_is_propagated_without_retry(self):
        calls = []
        def bind(write_json, emit, answerable, clients=None):
            calls.append(answerable('fixture'))
            raise TypeError('sink failed')
        with self.assertRaisesRegex(TypeError, 'sink failed'):
            bind_request_sinks(SimpleNamespace(bind_sinks=bind), object(), object())
        self.assertEqual(calls, [True])
