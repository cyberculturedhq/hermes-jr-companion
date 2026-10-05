# Integration checks

`python Validation/backend_smoke.py` runs in a real Hermes Python environment on a logged-in macOS desktop. It registers a temporary loopback backend on an unused port with isolated Hermes state, verifies authenticated RPC and repeated installation, then removes the service and verifies the listener stops. It does not change normal profiles or call a model. Linux service generation and preservation paths are covered by unit tests.

`python Validation/service_smoke.py` runs on a logged-in macOS desktop with this package installed. It creates a temporary offline launchd job, verifies startup, SIGKILL crash recovery, stop/start, uninstall, and state preservation, then removes the job. No real installation or APNs device is registered. It requires permission to control the current user's launchd manager. Unit tests additionally verify Linux unit generation; a real systemd user-service run still needs a Linux host.

`python Validation/native_hooks.py /path/to/hermes-agent` uses a Python environment containing Hermes' dependencies and this package. It loads the plugin through Hermes' actual discovery and lifecycle dispatcher against temporary profile/state directories. It verifies completion, approval, clarification, and deduplication. It does not run an LLM task, contact APNs, or change normal profiles.

The previous physical-iPhone test verified sandbox APNs acceptance, notification display, and tapping through to the correct conversation with a fixture backend. A real task on the user's normal Hermes setup is still needed to verify the whole installation together.

## App and companion integration

Create the development environment at the repository root. Install the root package with `.venv/bin/python -m pip install -e .`. The maintained Python source is in `plugin/src`. There is no second companion source tree.

On macOS, run these checks from the repository root:

```sh
.venv/bin/python Protocol/tests/test_interop.py
.venv/bin/python Validation/companion_fixture.py
.venv/bin/python -m unittest discover -s Validation -p 'test_real_push_fixture.py'
```

The protocol check compiles the Swift client and verifies its encrypted records against the maintained Python companion. The companion fixture runs a local Worker, a local Python bridge, a fixture dashboard, and the Swift client. These checks use temporary state and keys. They do not deploy the service or change real conversations.

See [COMPANION.md](COMPANION.md) for pairing and recovery checks. See [REAL_PUSH.md](REAL_PUSH.md) for the separate physical-device push procedure. Open `Hermes.xcodeproj` for the app and its unit tests. Keep simulator signing enabled for Keychain tests. Public CI uses ad hoc simulator signing and does not need the maintainer's Apple certificates.
