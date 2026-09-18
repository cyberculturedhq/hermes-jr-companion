# Mobile protocol v1 and compatibility monitoring

The phone negotiates a mobile API with its paired companion on every connection.
The companion owns the Hermes adapter. Normal Hermes compatibility fixes belong
in that adapter and can ship through the existing signed companion update path.
The phone needs this initial update to opt in; new UI features or a future
incompatible mobile protocol may still require another app update.

## Contract

- Authenticated encrypted GET `/api/plugins/hermes-jr/v1/mobile/capabilities`
  with `protocol=1` and optional `known_revision` returns `protocol`, `revision`,
  `unchanged`, and `features` when changed. The revision hashes the supported
  mobile operations, feature descriptor, and adapter revision.
- The descriptor describes this companion adapter's support, not a claim to
  discover arbitrary future Hermes APIs. Bump `ADAPTER_REVISION` when adapter
  behavior changes. Never advertise a feature the adapter cannot supply.
- iOS caches descriptors by installation ID and pinned host public key. It checks
  again on connection, including reconnect. No executable code is downloaded.
  An explicit 404 permits legacy companion mode; malformed descriptors, missing
  required features, and other failures do not silently downgrade.
- RPC names are frozen under `jr.v1.*`. Accepted parameter names are in
  `mobile.PARAMS`. Existing iOS result/event shapes remain the mobile v1 shapes.
  Requests and responses go through `MobileAdapter`; add known translations
  there when upstream changes. Unknown fields are rejected, never blindly removed.
- Versioned read routes are `/api/plugins/hermes-jr/v1/mobile/api/profiles`,
  `/api/sessions`, and the existing session history/descendant suffixes under
  that prefix. The allowlisted query and JSON response shapes remain unchanged.
- `complete.slash` translates to the portable text-only backend request. Profile
  filtering uses the command catalog. The phone can fall back to catalog names
  on a definitive unsupported completion response.
- Legacy approval/clarification events and newer server requests normalize to
  mobile events. Modern answers use `request.answer` or `clarify.lock`; approval
  acknowledgments retain the native approval ID. Pending requests replay after
  binding the resumed session. Cancellation invalidates the mobile card.
- Secret/sudo or unknown input requests direct the user to the Hermes dashboard.
  The adapter never invents an answer or grants approval automatically.
- A backend disconnect invalidates the phone connection. No uncertain write,
  prompt, or answer is retried automatically. Check history before repeating it.
- Direct dashboard connections and old companions retain legacy behavior and
  do not gain the versioned adapter's compatibility guarantees.

## Daily checks

`Hermes compatibility` runs at 03:17 UTC, on relevant pull requests/main changes,
and through **Run workflow**. Every target must pass independently:

| Target | Purpose |
| --- | --- |
| Pinned desktop contract 6 (`2ff55bc…`) | Prevent regressions for older installations |
| Pinned contract 7 (`784d5c3…`) | Cover the VM version that exposed the slash bug |
| Latest published release | Verify the currently released Hermes version |
| Upstream main | Early warning before a future release |

Every run records the exact upstream commit in its summary. Tests run in an
isolated checkout/home, with no model credentials and outbound socket connects
disabled during the compatibility check. Real Hermes handlers cover profiles,
completion, session creation/status and command catalogs. Typed upstream
contracts validate representative writes without executing them. Modern
approval and clarification replies exercise Hermes's real request registry.
Companion tests cover both interaction generations and invalid/stale answers.

This is not an exhaustive guarantee: actual model execution, all tools,
provider integrations, and every REST response are not exercised by the daily
upstream probe. The local encrypted integration test separately runs the real
Swift client through the relay and companion, including both interaction formats.

## When a check fails

Enable **Actions → Email → Only notify for failed workflows** in your GitHub
notification settings: <https://github.com/settings/notifications>.
Scheduled-run notifications go to the person who last changed the schedule
(or re-enabled it); GitHub controls delivery. Schedules run only after this
workflow is on the default branch, can be delayed, and public-repository
schedules may be disabled after 60 days without repository activity.

Open the failed run and send its link to Codex with: “Fix this compatibility
failure while preserving support for the older Hermes versions.” First separate
dependency/network/setup failures from an API change. Add a regression case,
update the adapter, run every target and the encrypted Swift fixture, then review
and publish a signed companion release. Never auto-update a user's Hermes,
merge code, publish a release, or call a paid AI API from this workflow.
