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

Run `PYTHON -m hermes_jr.cli pair --ticket 'TICKET'` in the normal foreground terminal tool, using the returned Python path and exact ticket. The loaded Hermes Jr. plugin opens a native question panel in the originating CLI/TUI or desktop conversation. The panel displays the comparison code and closes automatically after authenticated connection. Confirmation remains on the iPhone; answering the panel cancels, never approves.

- The plugin owns waiting and code display. Do not start a background process, call `clarify`, repeat the code in chat/reasoning, or ask for a chat reply.
- `connected`: say **“Your iPhone is connected.”**
- `failed` or `expired`: explain the returned reason and recovery action. A new prompt does not repair a backend or internal error. Keep the installed companion.
- `not_found`: use the ticket command without `--status`.
- **Panel not active:** the plugin is not loaded in this conversation, the Python environment differs, or this Hermes version has no compatible native question interface. After installing/updating the companion, close and reopen the interactive Hermes session before retrying. Do not restart the messaging gateway as a substitute. Desktop may require quitting/reopening the app to refresh its backend. Preserve existing conversations and connections. If still unavailable, check the Hermes version; do not fall back to tool-output codes.

Keep the user handoff short and nontechnical. The native panel supplies the code and phone action. Do not repeat Python paths, commands, package versions, process details, or JSON. Only `connected` means success. Cancelling in Hermes revokes this unfinished attempt; cancel the old setup on the iPhone before creating a new ticket.

Tickets last twenty minutes; code comparison lasts up to five. If one expires, obtain a new prompt and reuse the installation. Notifications are optional; do not claim delivery works without a real backgrounded-phone test. Newly installed hooks load when existing Hermes sessions finish and restart.
