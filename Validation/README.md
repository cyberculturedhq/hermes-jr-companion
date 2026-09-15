# Integration checks

`python Validation/backend_smoke.py` runs in a real Hermes Python environment on a logged-in macOS desktop. It registers a temporary loopback backend on an unused port with isolated Hermes state, verifies authenticated RPC and repeated installation, then removes the service and verifies the listener stops. It does not change normal profiles or call a model. Linux service generation and preservation paths are covered by unit tests.

`python Validation/service_smoke.py` runs on a logged-in macOS desktop with this package installed. It creates a temporary offline launchd job, verifies startup, SIGKILL crash recovery, stop/start, uninstall, and state preservation, then removes the job. No real installation or APNs device is registered. It requires permission to control the current user's launchd manager. Unit tests additionally verify Linux unit generation; a real systemd user-service run still needs a Linux host.

`python Validation/native_hooks.py /path/to/hermes-agent` uses a Python environment containing Hermes' dependencies and this package. It loads the plugin through Hermes' actual discovery and lifecycle dispatcher against temporary profile/state directories. It verifies completion, approval, clarification, and deduplication. It does not run an LLM task, contact APNs, or change normal profiles.

The previous physical-iPhone test verified sandbox APNs acceptance, notification display, and tapping through to the correct conversation with a fixture backend. A real task on the user's normal Hermes setup is still needed to verify the whole installation together.
