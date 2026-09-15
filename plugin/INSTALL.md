# Install and connect Hermes Jr.

Follow these steps when the user gives you a setup ticket. Preserve existing Hermes configuration, conversations, pairings, and active work.

## 1. Check the installation

Use the Python environment shown by `hermes --version`. In the commands below, `PYTHON` means that executable. Use `PYTHON -m hermes_jr.cli` for companion commands throughout setup; the `hermes jr` shortcut may not be registered in an existing session.

```sh
PYTHON -m hermes_jr.cli doctor
PYTHON -m hermes_jr.cli service status
```

If the module is absent, install it in step 2. Otherwise inspect `installation.package_version` and `installation.status` in doctor. A consistent installation of **0.11.0 or newer** can go directly to step 3.

## 2. Install one matching release

Read the [latest stable release](https://github.com/cyberculturedhq/hermes-jr-companion/releases/latest) and resolve its tag to an immutable commit. Use that same commit for the native plugin in every existing profile and its Python package.

**Stop if the stable release is older than 0.11.0 or older than an installed development version.** Report the unavailable release; do not downgrade or search other branches or package registries. Preserve any local source edits before replacing an installation.

Find the existing profiles with `hermes profile list`. For the default profile:

```sh
PYTHON -m hermes_cli.main plugins install 'https://github.com/cyberculturedhq/hermes-jr-companion.git#plugin' --ref COMMIT --force --no-enable
PYTHON -m pip install /path/to/profile/plugins/hermes-jr
PYTHON -m pip check
PYTHON -m hermes_cli.main plugins doctor /path/to/profile/plugins/hermes-jr --ci
PYTHON -m hermes_cli.main plugins enable hermes-jr --no-allow-tool-override
```

Replace `COMMIT` and the plugin path. The default path is `~/.hermes/plugins/hermes-jr`; named profiles use their own homes. Repeat the native install, doctor, and enable commands with `--profile NAME` before `plugins` for each existing profile. Install the Python package once per distinct Hermes environment.

Preserve Hermes's shared dependency versions. If replacing companion code at the same version, use `pip install --no-deps --force-reinstall` for the companion package only, then `pip check`. For an ordinary update of a consistent released installation, use [the managed updater](UPDATES.md).

## 3. Ensure startup and connectivity

For a new installation:

```sh
PYTHON -m hermes_jr.cli setup --service https://hermes-jr-companion.cybercultured.com --dashboard http://127.0.0.1:9119 --relay --push
```

Reuse saved settings for an existing installation. Use its configured dashboard port and service address.

The Hermes backend and companion each need a service supervisor. Reuse any existing backend supervisor. If none exists, run:

```sh
PYTHON -m hermes_jr.cli backend install
```

This registers a loopback backend with launchd on macOS or systemd on Linux and returns promptly. A gateway process alone does not prove that the dashboard is available. **Run servers through the supervisor, not as agent terminal jobs.** If another process owns the port, inspect its existing startup configuration instead of starting a duplicate. See [STARTUP.md](STARTUP.md) for diagnostics.

Install the companion service if absent, start it if stopped, or restart it once after a package update:

```sh
PYTHON -m hermes_jr.cli service install
PYTHON -m hermes_jr.cli doctor
```

Before pairing, doctor must show `installation.status=consistent`, `dashboard_rpc=ok`, and `service=ok`. Allow a few seconds for startup, then check again. If a check still fails, report that specific blocker rather than repeating installation or restarting unrelated Hermes processes. Loaded conversations pick up new notification hooks when restarted after their current work finishes.

## 4. Pair the iPhone

Run this with the exact ticket from the user's prompt:

```sh
PYTHON -m hermes_jr.cli pair --ticket 'TICKET'
```

Read the JSON result:

| Status | Next action |
| --- | --- |
| `pending` | Wait a few seconds, then repeat with `--status`. |
| `ready` | Show the returned `code` in a visible message: “Check that **CODE** matches all three groups in Jr., then tap **It’s correct**.” In the same turn, call `terminal` with the exact returned `completion_watch.arguments` and wait for its result. |
| `connected` | Tell the user their iPhone is connected. |
| `expired` or `failed` | Explain that setup did not finish and ask for a fresh prompt from Jr. Keep the installation. |
| `not_found` | Start this ticket using the command without `--status`. |

The code must be visible before running the completion watcher. Phone confirmation belongs to the user. Only `connected` confirms success; the watcher returns automatically when the phone connects or the attempt expires.

Tickets last twenty minutes and confirmation codes last up to five minutes. After a lengthy first install, the user may need a fresh ticket. Keep credentials out of messages and logs.

## After connection

The user can enable notifications in Jr. and allow iOS notification permission. Verify delivery with a real task while the app is in the background before claiming notifications work. The hosted service currently supports iOS development builds.

[Startup and troubleshooting](STARTUP.md) · [Updates and removal](UPDATES.md) · [Manual pairing](PAIRING.md)
