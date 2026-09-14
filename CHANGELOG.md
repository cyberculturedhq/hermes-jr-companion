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
