## 0.17.0

- Publish the companion Python package from the repository root to PyPI; keep the installed directory plugin free of `pyproject.toml` and declare an exact package version in `plugin.yaml`.
- Install and update through Hermes' package manager, including guided updates, profile-preserving rollback, and standalone recovery.
- Require removal of the pre-0.17 plugin from all profiles before a fresh install on the updated Hermes Agent.

## 0.16.0

- Track explicitly requested iPhone updates through the signed installer, including the first upgrade from older companions.
- Send one encrypted update-completion notification to the requesting phone after installed-version and connection checks pass. Respect notification settings and revocation; recover committed results after a bridge restart.
- Publish signed release metadata for faster foreground update notices in Hermes Jr. No update check starts a model conversation or installs code.
- Keep existing Hermes-process restarts explicit. Package installation success does not claim that already-loaded hooks were reloaded.

## 0.15.0

- Display pairing codes directly in Hermes' native CLI/TUI and desktop question interfaces. The plugin owns waiting and dismissal; code display no longer depends on model output or reasoning visibility.
- Keep confirmation on the iPhone. Cancelling the native panel stops only the unfinished attempt; completion and cancellation are serialized with enrollment.
- Refuse pairing before a native panel is available. Newly installed or updated plugins require reopening the interactive Hermes session. Existing connections and profile choices remain intact.

## 0.14.0

- Correct Linux systemd working-directory syntax and repair the exact older backend definition; validate generated units with systemd itself.
- Support separate topic-restricted production and sandbox APNs keys with isolated durable signing-token caches.

- Negotiate a stable mobile protocol and run compatibility checks against supported older Hermes versions, the latest release, and upstream main.
- Upload documents in bounded, device-scoped chunks for use in phone conversations.
- Offer an explicit, verified handoff from a standalone local Hermes CLI session to the phone; shared server sessions are never terminated.
- Let each phone receive notifications from all sessions while preserving followed-only defaults and foreground suppression.
- Return the current setup prompt from the hosted service so future wording fixes can reach new pairing attempts without an iOS update.

Protocol and state compatibility remain at version 1. Existing pairings and profile activation choices are preserved; the new features need the matching iOS app. Updates remain explicit and signed.

## 0.13.3

- Recognize identical copied Python executables in the same environment when checking backend ownership; continue rejecting changed binaries and definitions.

## 0.13.2

- Put the phone action and immediate completion watcher at the top of pairing results.
- Recognize Python aliases in the same environment when managing the backend.
- Remove the overlooked QR dependency from the native plugin manifest.

## 0.13.1

- Point missing-backend diagnostics to persistent backend startup, distinguishing it from the messaging gateway.
- Report a completed explicit update separately from pairing readiness.

## 0.13.0

- Reuse a healthy installed companion during setup; updates remain explicit.
- Preserve profile activation choices and share the managed update/rollback path, including removed dependencies.
- Check the updated connection before committing an update; restore prior code on failure.
- Carry sanitized pairing failure reasons and recovery actions to Hermes.
- Restore the minimal phone prompt and concise user handoff; remove the remaining bundled QR guide.

# 0.12.0

- Numeric comparison is the only new pairing path. Remove browser/scanner pairing, manual fingerprint commands, and the QR dependency.
- Add a signed-release installer that uses native Hermes installation across profiles, preserves dependency versions, backs up replaced code, and checks services.
- Consolidate setup instructions around the installer and the existing bounded pairing/watch commands.

Earlier entries below describe historical releases, not current setup instructions.

## 0.11.0

- Show the pairing code before a separate bounded foreground waiter, so Hermes resumes automatically after phone confirmation without model-generated notification flags or custom tool availability.
- Refuse new pairing when native plugin versions differ from the Python package or the running service is outdated.
- Validate native files and package identity before completing managed updates; roll back inconsistent updates.
- Stop stale plugin callbacks from recreating companion state after uninstall.
- Clarify fresh-install backend supervision and preserve shared dependencies during complete removal.

## 0.10.0

- Verify authenticated dashboard RPC before ticket pairing and expose its health in doctor.
- Require successful phone-side profile discovery before reporting connected.
- Add a read-only completion watcher for Hermes background notifications.
- Replace misleading session-retry errors with the actual companion/backend boundary.

# 0.9.0

- Move numeric pairing into the companion service so terminal commands return the code before phone approval.
- Add bounded JSON results and a short `pair --ticket … --status` command; only authenticated completion reports connected.
- Preserve setup across service restarts and distinguish expiry from success.
- Correct relay responses for missing installations versus temporary service capacity.

# 0.8.0

- Add public, phone-bound setup tickets and a resumable numeric-comparison pairing flow.
- Display the same three-group verification code in Hermes and Jr.; enrollment requires the phone's explicit confirmation.
- Add bounded temporary setup state, a generic readiness notification, and idempotent enrollment; preserve QR pairing as an explicit fallback.
- Document the new protocol and validate key substitution, replay, competing claims, expiry, and Swift/Python interoperability.


# 0.7.0

- Verify release signatures before checking or installing updates.
- Reject unknown installations before allocating storage; add service-wide registration, HTTP and push budgets.
- Add private aggregate monitoring and emergency pause controls.
- Disable the old Workers development hostname.

# Changelog

## 0.6.0

- Scan a private, one-time QR to authorize and connect the phone automatically. No fingerprint exchange or manual approval for new invitations.
- Wait for pairing in the installer command so Hermes resumes without asking the user to confirm; update the browser page and remove its QR on success.
- Simplify the matching iOS pairing screen to scan, connecting, and automatic entry into conversations.

QR possession now grants pairing authority. Protect it like a temporary sign-in link; only the first authenticated phone can claim it. Old invitations retain their previous approval policy. No relay protocol change; an additive local table records automatic-pairing intent. Update the companion and iOS app together for the simplified UX.

## 0.5.1

- Remove terminal QR rendering entirely. The legacy `pair --qr` flag now opens the same private browser page as normal pairing.
- Always return an explicit pairing-page link and concise agent handoff instructions.
- Bundle the complete installation guide inside the native plugin, with a fresh-install package/version check.
- Preserve machine-only `--json` and `--url` modes. No iOS update or protocol migration is needed.

## 0.5.0

- Open a private, branded browser pairing page by default, with a scannable QR, computer fingerprint, and expiry countdown.
- Keep explicit `pair --json`, `--url`, and `--qr` output for automation and terminal use.
- Guide installing agents to finish pairing themselves, request only the phone identity check from the user, and give a short nontechnical handoff.
- Explain how to deliver the self-contained page privately when Hermes runs on a remote or headless VM.

No protocol or state migration. Scripts that consumed the default JSON from `pair` should now use `pair --json`.

## 0.4.0

- Encrypt profile names, conversation titles, and event types for each iPhone before sending push notifications.
- Add profile-only notification titles and event-specific bodies in the matching iOS notification extension.
- Pad encrypted notification data to a fixed size; keep a generic fallback for older apps, missing keys, and plain HTTP setups.
- Explain key management, delivery metadata, and security limits prominently in the README.

Relay protocol 1 remains unchanged. Two additive local tables store per-phone notification keys and private queued details. Managed updates from 0.3.0 are supported. Update the relay before the companion, then reconnect the updated iOS app with notifications enabled.

## 0.3.0

- Show companion update availability in Hermes Jr., with a copyable update prompt and per-version dismissal.
- Expire unapproved pairing invitations locally and retry their removal from the relay while offline.
- Add explicit `hermes jr update --install`, automatic recovery after failed updates, and `hermes jr rollback`.
- Preserve pairings and live state during rollback; refuse managed updates that change dependencies, protocol, or state compatibility.
- Package the installable plugin under `plugin/`, separate from the relay service and developer tests, for Hermes’ native source scanner.
- Add direct upstream links and a small non-affiliation notice.

Protocol version 1 remains unchanged. The private state adds a remote-removal retry queue. See UPDATES.md for the one-time manual migration from 0.2.0.

## 0.2.0

- Add explicit per-user launchd and systemd service installation, start, stop, restart, status, and removal.
- Preserve pairings when removing startup; keep saved dashboard credentials out of service definitions and logs.
- Add private bounded logs and read-only dashboard/relay diagnostics.
- Check stable GitHub releases daily without downloading or installing executable code; provide explicit pinned-update instructions.
- Add lifecycle/update tests, reproducible launchd/native-hook checks, and continuous Python/Worker tests.

Protocol version 1 and the private SQLite schema are unchanged. Install the updated Python package, then use `hermes jr service install` after stopping any foreground bridge. Existing phones do not need to pair again. See STARTUP.md and UPDATES.md.

## 0.1.0

Initial public companion, HPKE encrypted relay protocol, independent generic APNs push, pairing, and foreground bridge.
