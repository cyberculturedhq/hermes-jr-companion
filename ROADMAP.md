# Scope of the first real-installation test

The companion supports encrypted relay, independent push, existing-profile installation through Hermes' native plugin commands, QR pairing and owner approval, durable notification state, macOS/Linux startup management, connection diagnostics, and automatic stable-release checks, an iPhone update notice, explicit installation with code rollback, and expired invitation cleanup.

The normal-Hermes test is the next validation step, not a production-readiness claim. Local tests cannot establish real phone behavior on every network or real systemd service behavior without a Linux host.

Remaining work already discussed:

- Publish the iOS source and its independent build instructions under the same organization.
- Configure production APNs before TestFlight/App Store distribution. The current shared endpoint accepts sandbox builds only.
- New profiles need the same plugin installation/activation step as existing profiles. Hermes currently exposes no profile-created hook for this companion; a background config editor could race profile creation and override a user's choices. The installation prompt covers all existing profiles; creation workflows must explicitly include future profiles until an upstream lifecycle mechanism is available. A planned alternative is to detect new profiles and ask in Jr. whether to activate the companion, with a remembered “Not now” choice. Detection and that approval UI are not implemented yet.

Useful follow-ups before a broad public launch:

- Independent review of the encryption and pairing protocol, plus protocol-version compatibility tests between released app and companion versions.
- Broader Linux, reboot, offline/reconnect, and long-running workload coverage; production relay abuse controls and cost monitoring.
