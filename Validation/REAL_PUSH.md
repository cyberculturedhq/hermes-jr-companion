# Real iPhone sandbox push fixture

This harness uses the existing app, its real APNs registration flow, the production
encrypted companion bridge, and a staging relay. Its Hermes dashboard and host
registry are isolated fixtures. It does not operate or install anything on the
phone, invoke a model, or change a real Hermes configuration. The APNs token stays
inside the normal registration path; the harness neither extracts nor prints it.

The signed app must have the `development` APNs entitlement. Configure staging for
sandbox APNs with topic `com.hermesjr.app` first. Public `/v1/capabilities` must
report `push: true` before the fixture creates its own installation.

Create a fresh setup prompt in Jr. Save just its HJ1 ticket in a private file, then run this fixture instead of giving that ticket to a real Hermes installation:

```sh
Companion/.venv/bin/python Validation/real_push_fixture.py start \
  --relay-url https://hermes-jr-companion.cybercultured.com \
  --ticket-file /private/path/ticket.txt \
  --workdir /tmp/hermes-jr-real-push-UNIQUE
```

The fixture runs the production numeric comparison exchange. Compare its displayed code with all three groups on the phone, then confirm there. It prints the status path after the phone connects. Private recovery credentials stay in the mode-0700 work directory. The fixture stops and deletes its installation after thirty minutes by default.

1. Complete numeric comparison as described above.

2. Open **Research → Session 0**, enable **Notify me** in connection settings, and
   grant notification permission. `status.json` must show `approved`,
   `push_registered`, and `followed_fixture_session` all true. The push flag is set
   only after registration reaches staging successfully.

3. Background the app, then explicitly request the one generic notification:

   ```sh
   Companion/.venv/bin/python Validation/real_push_fixture.py control \
     --workdir /tmp/hermes-jr-real-push-UNIQUE notify
   ```

   It waits up to 60 seconds for that conversation's presence lease to clear or
   expire. To deliberately test a foreground banner, the same command accepts
   `--clear-presence`, which clears only this isolated fixture's presence. The
   fixture permits exactly one HTTP push attempt, even if its outcome is unknown.
   Automatic outbox dispatch/retry is disabled in this harness. This isolates
   the real device check; production retry logic is covered separately.

4. Check `push_status`. `accepted_by_apns` requires the service's explicit
   `status: accepted`, which means APNs returned HTTP 200. A generic successful
   service response or the local outbox's `delivered` flag is insufficient by
   itself. APNs acceptance does **not** prove the phone displayed a banner.
   Observe the generic **Hermes Jr.** alert on the phone, then tap it. A non-null
   `notification_reference_resolved_at` proves the app fetched the notification's
   destination over the encrypted connection. Visually confirm it opens
   **Research → Session 0**; this timestamp alone does not prove screen rendering.

5. Stop and delete the fixture installation:

   ```sh
   Companion/.venv/bin/python Validation/real_push_fixture.py control \
     --workdir /tmp/hermes-jr-real-push-UNIQUE stop
   ```

   Wait for `installation_deleted: true` in status and the cleanup confirmation
   (second DELETE returns 404). Ctrl-C/SIGTERM also performs cleanup. Remove this
   test connection from the phone afterward. A hard process kill cannot run
   cleanup; its private `cleanup.json` contains only this fixture's deletion
   credential. An external cleanup failure reports a private recovery-file path.

The harness's no-network safeguards can be checked with:

```sh
Companion/.venv/bin/python -m unittest discover -s Validation -p test_real_push_fixture.py
```

## Inspecting a failed attempt without restarting the paired phone

After the staging service supports safe diagnostic receipts, this separate
command attaches to the running fixture's private registry. It performs only a
host-authenticated receipt GET, prints enumerated diagnostics, and writes
`receipt-status.json`. It does not restart the bridge, send a notification,
change the pairing, or change the cleanup deadline.

```sh
Companion/.venv/bin/python Validation/real_push_fixture.py receipt \
  --workdir /tmp/hermes-jr-real-push-UNIQUE
```

Only `stage: apns` with a numeric non-200 `apns_status` and a failed/unregistered
receipt establishes a rejection. A legacy `failed` receipt without diagnostics,
`pending`, a signing error, and a transport error do not qualify. Existing legacy
receipts cannot retroactively acquire the discarded Apple error details.

If the receipt **confirms rejection**, the cause has been corrected, and another
phone notification is explicitly authorized, this command permits one retry:

```sh
Companion/.venv/bin/python Validation/real_push_fixture.py retry-confirmed-rejection \
  --workdir /tmp/hermes-jr-real-push-UNIQUE
```

This command requires the existing approved phone, a staging push registration,
the fixture conversation follow, cleared presence, and at least 60 seconds before
cleanup. It adds a fresh opaque reference to the same registry so a notification
tap still resolves through the running bridge. An atomic `retry-status.json`
latch permits one extra attempt across concurrent invocations and crashes; an
unknown outcome never rearms it. The original running loop remains limited to
its first attempt. Inspect `retry-status.json` for the separate attempt result,
and `status.json` for notification-reference resolution after a tap. Stop the
original fixture as above to clean up the same installation and registration.
