# Connect an iPhone

This is the current setup guide. When the user supplies a setup ticket, follow it from terminal. Use the current repository files, not a cached web summary. If web extraction shows a different procedure, fetch this file directly from GitHub in terminal.

## 1. Prepare Hermes

For an installed companion, run the installed check:

```sh
hermes jr prepare
```

`ready` returns the Hermes Python path. This command keeps services, code, and profile choices. If an older companion has no `prepare` command, use its installed `doctor`, `service status`, and `backend status` commands. Check that installed copies are consistent, the service and dashboard checks are `ok`, and the backend has a persistent supervisor. Use Hermes' selected Python for the pairing command. Stop on an error. Read [STARTUP.md](STARTUP.md) from the installed plugin. Do not download `install.py` to check, update, or repair an installed companion.

For the **first installation only**, use the repository requested by the user. This step trusts executable code from that repository. The later release signature check does not verify the bootstrap script itself. Run these commands together in one terminal call with timeout 300. Replace `TICKET` with the phone's exact setup ticket:

```sh
jr_setup_dir=$(mktemp -d)
curl -fsSL https://raw.githubusercontent.com/cyberculturedhq/hermes-jr-companion/main/install.py -o "$jr_setup_dir/install.py"
python3 "$jr_setup_dir/install.py" --setup-ticket 'TICKET'
```

Wait for this invocation to exit. `ready` returns the Hermes Python path. If it fails or times out, stop and report the error and private log path. Keep the downloaded file for diagnosis. Do not replace or patch it as a repair. Updates require the user's explicit request and [UPDATES.md](UPDATES.md).

If the backend is externally managed, verify its persistent supervisor and current `doctor` checks before continuing. A listening port alone does not prove it will survive a terminal closing. Preserve existing services and profile choices.

### A stopped first installation

Use the private recovery files saved by the original installer or the installed updater. Keep the current phone state. The original, explicitly trusted first-install file supports `--complete-install --setup-ticket 'TICKET'` for a partial installation at the same signed release. Do not download a replacement bootstrap to repair it. If the trusted files are unavailable, stop and request a supported manual migration. Pair only after health checks pass and the interactive Hermes session has reopened.

## 2. Pair

Run `PYTHON -m hermes_jr.cli pair --ticket 'TICKET'` in the normal foreground terminal tool, using the returned Python path and exact ticket. The loaded Hermes Jr. plugin opens a native question panel in the originating CLI/TUI or desktop conversation. The panel displays the comparison code and closes automatically after authenticated connection. Confirmation remains on the iPhone; answering the panel cancels, never approves.

- The plugin owns waiting and code display. Do not start a background process, call `clarify`, repeat the code in chat/reasoning, or ask for a chat reply.
- `connected`: say **“Your iPhone is connected.”**
- `failed` or `expired`: explain the returned reason and recovery action. A new prompt does not repair a backend or internal error. Keep the installed companion.
- `not_found`: use the ticket command without `--status`.
- **Panel not active:** the plugin is not loaded in this conversation, the Python environment differs, or this Hermes version has no compatible native question interface. After installing/updating the companion, close and reopen the interactive Hermes session before retrying. Do not restart the messaging gateway as a substitute. Desktop may require quitting/reopening the app to refresh its backend. Preserve existing conversations and connections. If still unavailable, check the Hermes version; do not fall back to tool-output codes.

Keep the user handoff short and nontechnical. The native panel supplies the code and phone action. Do not repeat Python paths, commands, package versions, process details, or JSON. Only `connected` means success. Cancelling in Hermes revokes this unfinished attempt; cancel the old setup on the iPhone before creating a new ticket.

Tickets last twenty minutes; code comparison lasts up to five. If one expires, obtain a new prompt and reuse the installation. Notifications are optional; do not claim delivery works without a real backgrounded-phone test. Newly installed hooks load when existing Hermes sessions finish and restart.
