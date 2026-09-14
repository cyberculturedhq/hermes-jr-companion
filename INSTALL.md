# Install and test with Hermes

This is a development prototype. Python 3.10+ and a recent Hermes with native plugin hooks, the `hermes plugins` CLI, and dashboard plugin APIs are required. Installation and configuration are per profile; private companion state is shared under the Hermes root. Automatic startup and crash recovery are provided by `hermes jr service install`. New profiles still need explicit plugin installation/activation; include that step when creating them.

## Prompt to give Hermes

> Install https://github.com/cyberculturedhq/hermes-jr-companion for Hermes Jr. Follow INSTALL.md, enable it across my existing profiles, set up automatic startup, and help me pair my iPhone. Preserve my current setup and don't interrupt running work.

## Required fresh-install check

Read this guide before starting. A fresh install must install both the native plugin and its Python package from the same current stable release. A manifest saying “0.5.1” does not prove the running Python package was replaced. Confirm the imported `hermes_jr` version and path in the actual Hermes Python environment. Use a fresh command process for pairing so an older loaded module cannot select an obsolete output path.

Normal pairing must produce a browser page and an explicit link. `pair`, `pair --browser`, and `pair --qr` all do this. There is no terminal QR renderer. If your output claims terminal QR art, you are executing old code: correct the package/environment before handing off to the user. `--json` and `--url` are machine-integration options and must not be used for this guided setup.

## Instructions for Hermes

Find the actual Hermes Python environment and profile homes. Use native plugin commands to install and enable each existing profile, install the Python dependencies, and run plugin doctor. Preserve configuration, credentials, existing companion state, and pairings. Decline tool override permission. Arrange any required Hermes restarts after active work finishes. Inspect existing gateway/dashboard supervision, install the companion service, and verify `hermes jr doctor` and `hermes jr service status`. Show the private browser QR and wait for automatic pairing. Never ask the user to exchange fingerprints or approve the phone again. Keep technical verification in your working notes. Follow the user-facing handoff below.

For a new setup, use **https://hermes-jr-companion.cybercultured.com** with the local loopback dashboard and relay/push enabled. For an existing direct/Tailscale setup, enable only the features requested.

The service above supports **sandbox APNs only**, for the Hermes Jr. iOS development build. It is a shared development endpoint with no availability guarantee. End users do not need a Cloudflare account or Apple signing key. Self-hosters can deploy the service in [RelayService](RelayService/README.md) and substitute its URL.

## User-facing handoff — instructions for Hermes

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

The service starts now and after login, recovers from crashes, and shares one bridge across profiles. The computer must stay awake and Hermes’ dashboard must be running. See [STARTUP.md](STARTUP.md) for stop/restart/uninstall commands and Linux login requirements. For a direct/Tailscale connection that only needs notifications, use `--no-relay --push` in setup.

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

Follow [UPDATES.md](UPDATES.md) for automatic checks and explicit, pinned installation across profiles.

To remove phone access, run `hermes jr revoke DEVICE_UUID`. Local access is removed immediately; the bridge retries remote removal if the service is offline. Run `hermes jr service uninstall` to stop the bridge and remove automatic startup. Disable/remove the plugin in every enabled profile with Hermes’ native plugin commands. Private state intentionally survives plugin replacement; do not delete it before revoking devices or while another profile still uses it.
