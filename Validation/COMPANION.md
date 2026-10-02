# Local companion verification

## Bot Chat replies

`Validation/run-checks.sh` verifies replies to an existing Bot Chat owner, lost acknowledgements, failed turns, queued cancellation, attachments, old companion detection and an unowned canonical conversation. The tests do not call a model.

`Validation/prepare-notification-ui.py --bot-home` creates an isolated UI test project. The project has ten tests. They check the bottom Profiles/Bots tabs, Search, and the saved tab choice. They also check Close and Back without a header search field. The session search field stays at the bottom before and after Close and Back.

The conversation checks cover navigation, loading in the detail title, and cancellation during navigation. The tests also check canonical previews and replies without the session-transfer alert. Run the tests with `Validation/fixture_server.py` on the iPhone simulator.

The public companion's `tools/compatibility/bot_replies.py` checks the real Hermes database, writer registry and mailbox with temporary state. The compatibility workflow runs it across the supported Hermes versions. Older versions report bot replies as unavailable.

## Encrypted connection

Run from the project root after installing the companion's Python dependencies
and `npm ci` in `RelayService`:

```sh
Companion/.venv/bin/python Protocol/tests/test_interop.py
Companion/.venv/bin/python Validation/companion_fixture.py
```

The first command tests the production CryptoKit and PyHPKE implementations
against one another and RFC 9180 Auth vectors. It also checks tampering, replay,
reordering, reconnects, and fragment limits.

The second command starts an isolated Wrangler local Worker, a production Python
companion bridge, and the existing fake Hermes fixture. It compiles and runs the
production Swift transport and Hermes client against that complete connection.
The local fixture checks:

- A first-time invitation is claimed by the expected phone key, its secret is
  consumed, and the handshake waits for explicit fixture host approval.
- Profiles, session/history pagination, companion capabilities, and chat streaming
  traverse the encrypted connection.
- A 600 KB fixture photo is transmitted across multiple encrypted records.
- Concurrent HTTP requests retain ciphertext order and response correlation.
- Cancelled RPC/HTTP mutations do not reach Hermes or alter subscriptions; a late
  reply to an already-cancelled request leaves the connection healthy.
- Revoking the device closes its live connection.

Only loopback listeners, generated test keys, and a temporary state directory are
used. The fixture never connects to a real Hermes installation or sends an Apple
notification. It does not deploy a Worker or require Cloudflare account access.
Wrangler dependencies must already be installed. Xcode command-line tools are
required to compile Swift; the script supports Apple Silicon and Intel Macs.

The fixture removes its temporary keys, logs, SQLite state, and Worker storage on
exit and stops its listeners. In a sandbox, permission to run local server
processes may be required. All network operations exercised are local.

The iOS test target also contains `CompanionTests.swift`, covering invitation
validation, relay-origin restrictions, credential isolation by pinned identity,
Keychain persistence, and buffering notification taps during cold launch.
Real APNs delivery, iPhone camera scanning, and background-to-foreground routing
still require testing a signed build on an actual device.

To exercise an existing staging deployment, supply its HTTPS origin:

```sh
Companion/.venv/bin/python Validation/companion_fixture.py --relay-url https://your-staging-relay.example
```

This mode skips Wrangler, verifies the deployed service's capabilities over HTTPS,
and creates one temporary fixture installation/device. The real Swift client and
local Python bridge communicate through that deployment; fake Hermes and all
conversation content remain fixture-only. The script deletes its fixture
installation in `finally` and verifies that subsequent access returns404. It does
not list, modify, or delete any preexisting installation. If an external outage
prevents cleanup after three attempts, it reports a private recovery-file path
without printing the fixture credentials.

## Numeric comparison setup

Run `Companion/.venv/bin/python Validation/setup_fixture.py` for the new phone-bound
flow. It creates a signed setup intent, runs the real Python pairing command,
compares the independent Swift and Python SAS values, interrupts/resumes the
host, confirms, decrypts enrollment with HPKE, and opens the encrypted fixture
connection. All service keys and state are temporary; no Apple calls or deployment
occur. `HermesTests/SetupPairingTests.swift` exercises persisted phone state and
requires simulator signing for Keychain access. See `Protocol/SETUP.md`.

## Mobile protocol compatibility

`Validation/approval_runtime.py` runs the production companion socket against a
clean Hermes checkout's real approval registry over disposable loopback
WebSockets. Run it with Hermes' Python and the checkout path. It reproduces
refusal before capability registration, then checks explicit Allow once/Deny,
registration after reconnect, and rejection of unsupported input requests. No
model or shell command runs, and no existing Hermes service or pairing is used.

The app negotiates the companion's versioned mobile API on each connection and
caches its feature descriptor by pinned installation identity. The companion's
adapter normalizes old/new Hermes requests; the phone continues using v1.

Run `Companion/.venv/bin/python Validation/companion_fixture.py` to exercise the
real Swift client over the encrypted relay with both legacy and modern approval
and clarification formats. Run
`JR_FIXTURE_LEGACY_COMPANION=1 Companion/.venv/bin/python Validation/companion_fixture.py`
to verify explicit-404 fallback to an older companion.

The public companion PR contains daily real-Hermes compatibility checks and the
protocol contract in `docs/mobile-protocol.md`. The workflow is active only after
merge to the default branch. This initial iOS protocol update must be installed;
subsequent Hermes translations can normally ship as companion updates.
