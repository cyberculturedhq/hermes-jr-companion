"""Compatibility harness helpers that can be tested without loading Hermes."""
import inspect


def bind_request_sinks(requests, write, emit):
    kwargs = {}
    if "answerable" in inspect.signature(requests.bind_sinks).parameters:
        kwargs["answerable"] = lambda _: True
    requests.bind_sinks(write, emit, **kwargs)
