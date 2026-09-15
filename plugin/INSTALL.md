## Pairing readiness and automatic completion (0.11.0)

Before creating a ticket pairing, the CLI verifies the actual authenticated loopback WebSocket with a bounded RPC probe. `hermes jr doctor` now includes `dashboard_rpc`; a readable page or running bridge alone is insufficient. The Hermes backend must have persistent supervision, not just a process started inside an agent terminal call. Preserve existing supervisors; when absent, configure a user launchd/systemd service for `hermes serve --host 127.0.0.1 --port PORT`. Do not expose a new public listener. Follow the backend supervisor recipe in STARTUP.md when none exists. Never launch `hermes serve` as a foreground terminal tool call, increase its timeout, or use shell backgrounding: setup will block and the backend will be killed when the tool exits.

The pending/ready JSON includes `completion_watch`. Wait for `ready`, **show the returned code in your visible assistant message FIRST**, then call `terminal` directly with `completion_watch.arguments` in that same turn. This is a separate, bounded foreground waiter: it runs after your code message is visible and returns immediately on connection or expiry. Do not add background/notify flags, look for a plugin tool, or route terminal through `tool_call`. Do not end your turn with a promise to poll or ask the user to report confirmation. The code comes from the earlier short command, never from streamed waiter output. This handoff is identical for fresh and existing installations.

Connected now requires successful Hermes profile discovery through the phone's encrypted connection, in addition to phone authentication. A dead backend must not produce a successful pairing status. The watcher returns failure/expiry rather than reporting success.

# Install and test with Hermes

This is a development prototype. Python 3.10+ and a recent Hermes with native plugin hooks, the `hermes plugins` CLI, and dashboard plugin APIs are required. Installation and configuration are per profile; private companion state is shared under the Hermes root. Automatic startup and crash recovery are provided by `hermes jr service install`. New profiles still need explicit plugin installation/activation; include that step when creating them.

## Prompt to give Hermes

> Install https://github.com/cyberculturedhq/hermes-jr-companion for Hermes Jr. Follow INSTALL.md, enable it across my existing profiles, set up automatic startup, and help me pair my iPhone. Preserve my current setup and don't interrupt running work.

## Phone-bound setup (when the prompt contains an HJ1 ticket)

Use companion **0.11.0 or newer**. The ticket is public and belongs to the iPhone that generated it. Preserve existing configuration and the configured service origin. Verify `hermes jr doctor` and `hermes jr service status`; restart an older running companion service after updating so it loads the new pairing worker.

Run `hermes jr pair --ticket 'HJ1.…'` with the exact ticket. This bounded command queues pairing in the companion service and waits up to eight seconds for the code, after a bounded ticket-verification request. It returns JSON and **exits before phone approval**. No streamed output is needed to obtain the code. Use the separate completion watcher handoff described above. The installed companion service keeps the pairing alive.

Handle the returned `status`:

- `pending`: the phone has not finished joining the exchange. Wait a few seconds and run `hermes jr pair --ticket 'HJ1.…' --status` with the same ticket. Do not create a duplicate attempt.
- `ready`: immediately show the returned `code` verbatim in chat: “Check that these three groups match in Hermes Jr., then tap **It’s correct**.” This is a comparison, not an OTP to type. Never invent a code or approve on the user's behalf. The separate completion watcher reports the outcome; do not ask the user to report confirmation.
- `connected`: the companion observed authenticated profile discovery from the phone. Only now say pairing completed.
- `expired` or `failed`: setup did not complete. Ask the user to create a fresh prompt in Jr.; preserve the installed companion. These results exit nonzero.
- `not_found`: no service-owned job exists for this ticket. Start it with the command without `--status`.

A terminal command exiting successfully is **not** proof of pairing; inspect the JSON status. The service persists its keys and progress across restarts. Code expiry remains five minutes, capped by the ticket's original twenty-minute lifetime. A push is only a readiness notification. Keep credentials out of chat and logs. Never silently switch an HJ1 attempt to QR pairing.

The remaining QR instructions apply only to legacy integrations without a setup ticket.

## Required fresh-install check

Read this guide before starting. A fresh install must install both the native plugin and its Python package from the same current stable release. A manifest saying “0.5.1” does not prove the running Python package was replaced. Confirm the imported `hermes_jr` version and path in the actual Hermes Python environment. Use a fresh command process for pairing so an older loaded module cannot select an obsolete output path.

For legacy QR pairing without an HJ1 ticket, produce a browser page and an explicit link. `pair`, `pair --browser`, and `pair --qr` all do this. There is no terminal QR renderer. If your output claims terminal QR art, you are executing old code: correct the package/environment before handing off to the user. `--json` and `--url` are machine-integration options and must not be used for this guided setup.

## Instructions for Hermes

Find the actual Hermes Python environment and profile homes. If the shell wrapper selects system Python, use that environment’s Python with `-m hermes_cli.main` for Hermes commands, or `-m hermes_jr.cli` for companion commands; neither `-m hermes` nor `-m hermes_jr` is an entry point. Ticket pairing already returns JSON: do not combine --ticket with --json. Always install the native plugin and Python package from the SAME immutable stable release commit. For existing coherent installations prefer `hermes jr update --install`; never treat a standalone pip upgrade as a complete plugin update. Do not use bare pip --force-reinstall or --upgrade: that can replace Hermes-pinned shared dependencies. If reinstalling a package whose dependencies are already satisfied, use --no-deps --force-reinstall only for the companion package. For fresh installation, install normally without force/upgrade and finish with pip check; preserve the installed Hermes dependency requirements. For first install or legacy mismatches: resolve the stable release commit, run `hermes plugins install 'https://github.com/cyberculturedhq/hermes-jr-companion.git#plugin' --ref COMMIT --force --no-enable` in each applicable profile, then install the Python package from one of those exact native plugin directories. Run doctor after enabling and restarting the service: `installation.status` must be `consistent`, every listed profile version must equal `package_version`, and `dashboard_rpc` must be `ok`. Pairing refuses missing/mismatched native files and an outdated running service. Do not invent a skill for installation; use this guide. Use native plugin commands to install and enable each existing profile, install the Python dependencies, and run plugin doctor. Preserve configuration, credentials, existing companion state, and pairings. Decline tool override permission. Arrange any required Hermes restarts after active work finishes. Inspect existing gateway/dashboard supervision, install the companion service, and verify `hermes jr doctor` and `hermes jr service status`. When the prompt contains an HJ1 ticket, use the phone-bound setup flow above and wait for numeric confirmation on the phone. Only use the private browser QR flow below when no setup ticket was supplied. Never ask the user to exchange fingerprints or approve the phone again. Keep technical verification in your working notes. Follow the user-facing handoff below.

For a new setup, use **https://hermes-jr-companion.cybercultured.com** with the local loopback dashboard and relay/push enabled. For an existing direct/Tailscale setup, enable only the features requested. Keep an existing paired installation's saved service address: the older workers.dev address remains supported and needs no migration.

The service above supports **sandbox APNs only**, for the Hermes Jr. iOS development build. It is a shared development endpoint with no availability guarantee. End users do not need a Cloudflare account or Apple signing key. Self-hosters can deploy the service in [RelayService](https://github.com/cyberculturedhq/hermes-jr-companion/blob/main/RelayService/README.md) and substitute its URL.

## Legacy QR user-facing handoff (no HJ1 ticket) — instructions for Hermes

You own setup through successful connection. Keep dependencies, process IDs, commands, and verification details in your working notes. Do not call setup complete before the phone connects.

1. Verify the dashboard and companion work and will return after login/restart. Preserve existing supervision; a background PID alone is insufficient.
2. Run `hermes jr pair --browser` with enough time for the user to scan (up to ten minutes). Keep the command alive using your tool’s background-process/session feature when needed, and poll that same process. Do not start another invitation merely because a tool yielded. Plain `pair` and `--qr` open the same browser page.
3. Include the exact page link in a short reply: “Open Hermes Jr. and scan the code on this page. You’ll connect automatically.” Do not say a QR is printed in the terminal.
4. Wait for the command to report the iPhone connected. It detects the authenticated claim itself. **Do not ask for a fingerprint, approval, ‘I paired’ reply, or any command from the user.** Scanning this private one-time QR is the authorization. If the code expires, generate and display a new one.
5. On success, continue verification yourself. Say “You’re connected. Your conversations are ready to open in Jr.” Offer notifications in simple language; do not claim a notification test passed until one was received.

If the VM has no visible browser, provide the generated page as a private attachment or use the environment’s private file-opening facility. It works locally without a tunnel. Never publish it or expose a public pairing server. If your interface cannot deliver/open it, explain that specific limitation. Do not silently call the handoff complete.

The page changes to “You’re connected” and removes the QR after the waiting command detects the phone. `--no-wait` is for integrations managing completion themselves; do not use it for the guided install. Keep the invitation private: someone who obtains it before it is claimed could connect their phone.

## Manual installation

First identify the Python executable that runs your Hermes installation. Do not substitute an unrelated system Python. Install without enabling first, so dependencies are available when Hermes loads the plugin:

```sh
hermes plugins install 'https://github.com/cyberculturedhq/hermes-jr-companion.git#plugin' --no-enable
/path/to/hermes/python -m pip install /path/to/profile-home/plugins/hermes-jr
hermes plugins doctor /path/to/profile-home/plugins/hermes-jr --ci
hermes plugins enable hermes-jr --no-allow-tool-override
```

Replace the two placeholder paths. For a standard default installation, the plugin directory is `~/.hermes/plugins/hermes-jr`. The manifest name is **hermes-jr**, even though the repository is named hermes-jr-companion. Decline tool override permission if Hermes asks.

For each named profile, use `hermes --profile PROFILE plugins install ... --no-enable`, then `hermes --profile PROFILE plugins doctor /path/to/that-profile/plugins/hermes-jr --ci` and `hermes --profile PROFILE plugins enable hermes-jr`. Discover profile homes from your Hermes configuration; do not assume changing the default profile enables other profiles. Install the Python package once per distinct Hermes Python environment. Add the plugin explicitly when creating future profiles.

Restart the relevant dashboard/gateway/CLI processes after their current work finishes so they load the new plugin. Ensure the dashboard is running and bound to loopback. This bridge does not launch the dashboard or Hermes.

## Start the bridge and pair

Use your actual dashboard port if it differs:

```sh
hermes jr setup --service https://hermes-jr-companion.cybercultured.com --dashboard http://127.0.0.1:9119 --relay --push
hermes jr service install
hermes jr doctor
```

The service starts now and after login, recovers from crashes, and shares one bridge across profiles. The computer must stay awake and Hermes’ dashboard must be running. See [STARTUP.md](https://github.com/cyberculturedhq/hermes-jr-companion/blob/main/STARTUP.md) for stop/restart/uninstall commands and Linux login requirements. For a direct/Tailscale connection that only needs notifications, use `--no-relay --push` in setup.

For manual setup (Hermes should run these steps when installing for a user):

```sh
hermes jr pair --browser
hermes jr status
```

Scan the QR with Hermes Jr. The phone connects automatically; the waiting command reports success and the page removes the QR. Invitations expire after ten minutes, are bound to the first authenticated phone to claim them, and are cleaned up if unused. Keep the page private. No fingerprint comparison or manual approval is part of this flow.

## Real notification test

1. Enable notifications in Jr. and allow iOS notification permission.
2. Open the conversation you want to test. Jr. follows opened conversations.
3. Start a real Hermes task in that conversation and return to the iPhone Home Screen before it completes. Foreground presence suppresses alerts; allow up to 45 seconds for a stale lease to expire.
4. Check for the Hermes Jr. alert and tap it to return to that conversation.

If chat works but notifications do not, verify the plugin loaded in that conversation's profile, the bridge is running, push is enabled, and the app is a sandbox development build. Older Hermes hooks may omit fields the companion needs and therefore skip notifications. The physical-device test used a fixture backend. The native Hermes hook dispatcher has also been verified to queue completion, approval, and clarification events in isolated state; a real task on your normal setup remains the final integration test.

## Updates and removal

Follow [UPDATES.md](https://github.com/cyberculturedhq/hermes-jr-companion/blob/main/UPDATES.md) for automatic checks and explicit, pinned installation across profiles.

To remove phone access, run `hermes jr revoke DEVICE_UUID`. Local access is removed immediately; the bridge retries remote removal if the service is offline. Run `hermes jr service uninstall` to stop the bridge and remove automatic startup. Disable/remove the plugin in every enabled profile with Hermes’ native plugin commands. Private state intentionally survives plugin replacement; do not delete it before revoking devices or while another profile still uses it.

## Complete removal for a clean reinstall

Revoke enrolled devices, stop/uninstall the companion service and any backend supervisor created solely for this companion, disable/remove native copies in every profile, then uninstall only the `hermes-jr-companion` Python distribution. Remove companion-specific state, downloaded companion sources, and companion-specific skills/references created during setup. Preserve Hermes conversations, its own pairing subsystem, model settings, and unrelated tools. Do not uninstall shared dependency packages by guessing who installed them: Hermes, MCP and voice features also depend on these libraries. Verify `pip check` in the actual Hermes environment afterwards.

Older already-loaded plugin callbacks can recreate state after removal. End that conversation before auditing leftover companion state and start the next test in a fresh Hermes process. Current hooks stop writing when their native plugin or installed Python module has been removed. A normal user reinstall must not need an ad-hoc cleanup skill.
