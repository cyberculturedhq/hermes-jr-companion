# Connect Hermes Jr.

When the user gives you a setup ticket, follow these two steps. Keep the ticket exact. Use terminal for these commands.

## 1. Install and check the companion

Run the installer once. It finds Hermes’s Python, verifies the latest stable release, installs the matching plugin and package across existing profiles, and checks startup and connectivity.

```sh
jr_setup_dir=$(mktemp -d)
curl -fsSL https://raw.githubusercontent.com/cyberculturedhq/hermes-jr-companion/main/install.py -o "$jr_setup_dir/install.py"
python3 "$jr_setup_dir/install.py"
```

Use a terminal timeout of 300 seconds. If your terminal returns a running process, follow that same process until it exits. Do not start another installer. The script prints a private log path and returns `status: ready` with the Hermes Python executable when checks pass.

If it stops, report the specific error. Inspect the private log when necessary, keeping credentials out of chat. Do not substitute a raw Git checkout, downgrade, delete configuration, or restart unrelated Hermes sessions. An existing backend listener is preserved; if the installer reports an external backend, verify its supervisor using [STARTUP.md](STARTUP.md). A temporary terminal server is not persistent startup.

## 2. Pair

Using the `python` path returned by the installer:

```sh
PYTHON -m hermes_jr.cli pair --ticket 'TICKET'
```

Replace `PYTHON` and `TICKET` with the actual values. Read the JSON result:

| Status | Action |
| --- | --- |
| `pending` | Wait a few seconds, then repeat with `--status`. |
| `ready` | Say: “Check that **CODE** matches all three groups in Jr., then tap **It’s correct**.” In the same turn, call terminal with the exact returned `completion_watch.arguments`. Wait for its result. |
| `connected` | Say: “Your iPhone is connected.” |
| `expired` or `failed` | Explain that setup did not finish and request a fresh prompt from Jr. Keep the installation. |
| `not_found` | Start this ticket without `--status`. |

Show the code before starting the watcher. Only `connected` confirms success. The user confirms on their iPhone; do not ask them to type a confirmation back into Hermes.

Tickets last twenty minutes; code comparison lasts up to five minutes. If installation outlasts the ticket, keep the installation and use a fresh prompt.

Notifications are optional in Jr. Verify delivery from a real task while the app is backgrounded before claiming they work. Loaded Hermes sessions pick up new plugin hooks after they finish and restart.

[Startup](STARTUP.md) · [Updates and removal](UPDATES.md)
