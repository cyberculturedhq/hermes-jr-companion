# Connect an iPhone

This is the current setup guide. When the user supplies a setup ticket, follow it from terminal. Use the current repository files, not a cached web summary. If web extraction shows a different procedure, fetch this file directly from GitHub in terminal.

## 1. Prepare Hermes

Run these commands together in one terminal call with timeout 300:

```sh
jr_setup_dir=$(mktemp -d)
curl -fsSL https://raw.githubusercontent.com/cyberculturedhq/hermes-jr-companion/main/install.py -o "$jr_setup_dir/install.py"
python3 "$jr_setup_dir/install.py"
```

The script installs when missing and checks an existing installation without updating, re-enabling profiles, or restarting it. Follow the same process until it exits. `ready` returns the Hermes Python path. If a check fails, follow [STARTUP.md](STARTUP.md) to fix that specific problem; do not reinstall or upgrade as a generic repair. Updates require the user's explicit request and [UPDATES.md](UPDATES.md).

If the backend is externally managed, verify its persistent supervisor and current `doctor` checks before continuing. A listening port alone does not prove it will survive a terminal closing. Preserve existing services and profile choices.

## 2. Pair

Run `PYTHON -m hermes_jr.cli pair --ticket 'TICKET'`, using the returned Python path and exact ticket.

- `pending`: wait a few seconds and repeat with `--status`.
- `ready`: say “Check that **CODE** matches all three groups in Jr., then tap **It’s correct**.” Immediately call terminal with the returned `completion_watch.arguments` in the same turn. Wait for its result.
- `connected`: say **“Your iPhone is connected.”**
- `failed` or `expired`: explain the returned reason and recovery action. A new prompt does not repair a backend or internal error. Keep the installed companion.
- `not_found`: run the ticket command without `--status`.

Keep the user handoff short and nontechnical: code, phone action, then connection confirmation. Do not repeat Python paths, commands, package versions, process details, or JSON. The user confirms on the phone; never ask them to confirm back in chat. Only `connected` means success.

Tickets last twenty minutes; code comparison lasts up to five. If one expires, obtain a new prompt and reuse the installation. Notifications are optional; do not claim delivery works without a real backgrounded-phone test. Newly installed hooks load when existing Hermes sessions finish and restart.
