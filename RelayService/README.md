# Hermes Jr. relay service

The service that connects Hermes Jr. to the companion and delivers iPhone notifications. No account, tunnel installation, or public port on the Hermes machine is required. Both peers initiate outbound WebSocket connections. The hosted service is configured for the maintainer's development and internal TestFlight builds; see [installation instructions](../INSTALL.md). The app remains in internal testing.

The Worker routes opaque binary records. End-to-end encryption, authenticated pairing, application admission, replay protection, and mapping requests to the local Hermes dashboard belong to the companion/iOS protocol. A routing token grants network access to one device lane; **it does not grant access to Hermes**. The host must complete encrypted pairing and authorize every device before forwarding any application request.

## Run locally

Requires Node.js 22.22+ and npm. Dependencies and the lockfile are local to this directory.

```sh
cd RelayService
npm ci
cp .dev.vars.example .dev.vars
npm run types
npm run typecheck
npm test
npm run build
npm run dev -- --port 8787
```

`build` runs `wrangler deploy --dry-run`; it does not deploy. Wrangler/Miniflare need permission to open localhost sockets. `.dev.vars` is optional for runtime operation; the empty example documents the four optional secret bindings and lets `wrangler types` generate their types. Do not overwrite an existing secret file when repeating setup.

The test suite runs inside workerd against real SQLite Durable Objects and hibernatable WebSockets. It tests credential isolation, device revocation, concurrent device limits, actual rate-limit bindings, opaque byte forwarding, hibernation, socket/record/rate limits, and mocked APNs delivery. Tests generate an ephemeral local signing key and mock outbound `fetch`; no notification reaches Apple.

## HTTP contract, version 1

Production requests use HTTPS/WSS. Local HTTP is accepted only for `localhost`, `127.0.0.1`, and `[::1]`. All authenticated endpoints use `Authorization: Bearer <token>`; tokens in URLs are rejected. JSON bodies require `Content-Type: application/json`, are limited to 4096 bytes including chunked requests, and reject unknown fields. This API serves native clients; requests carrying a browser `Origin` header are rejected and CORS is not enabled.

IDs are random canonical lowercase UUIDv4 strings. Tokens contain 32 cryptographically random bytes encoded as 43 unpadded base64url characters; only SHA-256 hashes are stored. Credentials are returned once. Losing the host token requires registering a new installation. Keep it on the Hermes machine. Give the phone only its device routing credential through the authenticated pairing flow.

| Method / path | Authority | Body | Success |
| --- | --- | --- | --- |
| `GET /health` | Public | — | `200 {"status":"ok"}` |
| `GET /v1/capabilities` | Public | — | `200 {"protocol_version":1,"push":false,"max_ciphertext_bytes":65536}`; `push` reflects server configuration |
| `POST /v1/installations` | Public, rate limited | `{}` | `201 {"installation_id":"UUID","host_token":"TOKEN"}` |
| `POST /v1/installations/:installation/devices` | Host | `{}` | `201 {"device_id":"UUID","device_token":"TOKEN"}` |
| `GET /v1/installations/:installation/devices` | Host | — | `200 {"devices":[{"device_id":"UUID","push_registered":false,"connected":false}]}` |
| `DELETE /v1/installations/:installation/devices/:device` | Host | — | `200 {"status":"revoked"}`; immediately closes that device and removes its push registration |
| `DELETE /v1/installations/:installation` | Host | — | `200 {"status":"deleted"}`; erases installation/device data and closes all sockets |
| `PUT /v1/installations/:installation/devices/:device/push` | That device | `{"apns_token":"HEX","environment":"sandbox"}` or `production` | `200 {"status":"registered"}` |
| `DELETE /v1/installations/:installation/devices/:device/push` | That device or host | — | `200 {"status":"unregistered"}` |
| `POST /v1/installations/:installation/devices/:device/push` | Host | `{"reference":"RANDOM_BASE64URL","encrypted":{"v":1,"kid":"KEY_ID","data":"CIPHERTEXT"}}` (`encrypted` optional) | `202 {"status":"accepted"}` |
| `GET /v1/installations/:installation/devices/:device/push/receipts/:reference` | Host | — | `200 {"status":"failed","stage":"apns","apns_status":400,"reason":"BadDeviceToken","expires_at":0}`; reads a receipt without sending again |

Mint a device routing credential before starting its encrypted pairing exchange. Pending offers count toward the device limit; revoke abandoned/expired offers from the companion. No pairing secret, public key, ciphertext, session identifier, transcript, or Hermes dashboard credential is sent in the HTTP management bodies.

Errors have shape `{"error":"code"}` with `Cache-Control: no-store`. `401 unauthorized` means missing/invalid credentials; `403 host_required`/`device_required` means the known credential has the wrong scope; `409 device_limit`, `host_offline`, `host_already_connected`, `device_already_connected`, or `push_not_registered` describes the conflict; `429 rate_limited` includes `Retry-After: 60`; `503 push_unavailable` or `rate_limiter_unavailable` fails closed. Unsupported routes return `404 not_found`. JSON syntax/field errors return 400; content type errors 415; oversized bodies 413. No raw exceptions or provider responses are reflected to clients.

## WebSocket contract

Send an authenticated GET with `Upgrade: websocket` to:

- Host: `/v1/installations/:installation/host`, using the host token.
- Device: `/v1/installations/:installation/devices/:device/connect`, using that device's token.

Exactly one host and one socket per admitted routing device may be open. A device upgrade requires a connected host. Connection replacement is explicit: close the old socket before reconnecting; duplicate live upgrades return 409. There is no offline relay queue. Host disconnection closes its devices; clients reconnect and perform a fresh end-to-end handshake. Hibernation preserves connection attachments and routing/limit state. Internal host generation identifiers prevent a late close callback from terminating a replacement host's sockets.

**Device → host:** the device sends one binary E2EE record of 1–65,536 bytes. The service prefixes that device's 16 raw UUID bytes before delivering it to the host. Bytes 0–15 are the unhyphenated UUID hex decoded in display/network order (not little-endian UUID fields). Bytes 16 onward are the exact opaque record.

**Host → device:** the host sends the 16-byte destination device UUID followed by a binary E2EE record of 1–65,536 bytes, at most 65,552 total bytes. The service removes the header and delivers the remaining bytes only to that connected device. Unknown/revoked destinations close the host connection; a late record for a known disconnected device is dropped. Records are never copied to another device, replayed, or stored. A device-supplied prefix is opaque payload, never routing authority.

The service sends these routing-only text controls to the host:

```json
{"type":"peer_connected","device_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}
{"type":"peer_disconnected","device_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}
```

Client text messages are rejected with WebSocket close 1003. Oversized/empty records use 1009; revoked/unknown devices 4003; limits 4008; loss of the host 4001. Standard WebSocket ping/pong is available for connection liveness. Text application heartbeat messages are not part of this protocol.

## Encrypted previews and generic push, independently optional

Push registration and dispatch use HTTP and work when no relay WebSocket is open. Set these secrets on the eventual deployment: `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_TOPIC` (the app's exact bundle identifier), and `APNS_PRIVATE_KEY` (the Apple `.p8` PKCS#8 PEM). Do not put an Apple signing key on a phone or Hermes user's machine. With any value missing, capabilities reports `push:false` and push registration/dispatch returns `503 push_unavailable`.

Set the non-secret `APNS_ENVIRONMENT` Wrangler variable to `sandbox` or `production` for a single environment. Use `both` when the base Apple key supports both environments, or when separate sandbox and production credentials are configured as described below. The service rejects incompatible registrations and existing registrations after a scope change with `409 push_environment_not_allowed`. `APNS_TOPIC` must also be allowed by each key's topic scope; this service supports one configured topic. It cannot extend an Apple key's capabilities. No actual Apple signing material is included here.

The host generates an unrelated random base64url reference, 32–64 characters, for each notification. It retains any mapping to local session/action state privately. The service cannot check entropy, so the companion must never substitute a session ID, command, or text for this reference. A legacy or generic-only APNs payload is:

```json
{
  "aps": {
    "alert": {
      "title": "Hermes Jr.",
      "body": "You have a new notification. Open the app for details."
    },
    "sound": "default"
  },
  "reference": "UNRELATED_RANDOM_REFERENCE"
}
```

Encrypted preview requests may additionally include `encrypted: {v: 1, kid, data}`. The Worker strictly bounds this envelope and forwards it with `mutable-content: 1`; it never accepts plaintext title/body fields or decryption keys. The phone replaces the fallback after authenticated decryption. See [the notification protocol](../Protocol/NOTIFICATIONS.md).

The topic and endpoint are server controlled; only Apple's production/sandbox endpoints can be used. Notifications expire after an hour and share a generic collapse identifier. Apple acceptance is not confirmed display or delivery. The app must reconnect and reconcile actual state when opened.

The same reference/device pair is sent to APNs at most once within 24 hours; repeats return `202 {"status":"accepted","duplicate":true}` or the stored `pending`/`failed`/`unregistered` state. APNs errors return `502 {"status":"failed"}` or `unregistered`. Status 410 clears the exact obsolete device token, without clearing a newer registration that arrived during the request. Ambiguous network failures are not automatically retried. Creating another reference can cause a duplicate user alert and should be a deliberate host decision.

The host can read a receipt to distinguish signing failures, transport failures,
and Apple's response. Only a fixed stage, HTTP status, and allowlisted Apple reason
are retained alongside the existing receipt expiry. Raw response text, request
URLs, device tokens, and signing credentials are never included in diagnostics.
Historical receipts have null diagnostic fields. Missing, expired, or revoked
receipts return 404. An unknown outcome must not be treated as confirmed rejection.

An internal `APNsProviderToken` Durable Object caches one derived provider JWT per Apple signing key for 30 minutes, including across hibernation. It is reachable only through a Worker binding, has no HTTP route, and never stores the `.p8` key. This shares signing tokens across installations and avoids a new provider token on every push.

## Bounds and operational scope

Each installation allows 16 device records including pending pairing offers and at most 17 sockets (one host plus one per device). SQLite fixed-window limits survive reconnects and hibernation:

| Resource | Limit |
| --- | --- |
| Installation management requests | 60/minute |
| WebSocket upgrade attempts | 30/minute |
| Binary records across installation | 6000/minute |
| Opaque bytes across installation, both directions combined | 128 MiB/minute, 256 MiB/day |
| Records/bytes per device, both directions combined | 3000/minute, 64 MiB/minute |
| Push attempts across installation | 30/minute, 300/day |
| Push attempts per device | 6/minute |

The public registration endpoint additionally uses Cloudflare's real rate-limit binding (5/minute per ingress IP); authenticated ingress has another binding at 120 requests/minute/IP. Missing bindings return 503 instead of bypassing limits. Local tests exercise the registration limit. These edge limits are approximate and per Cloudflare location, not a global spending cap; shared IPs may share a limit. Before public launch, use account budget alerts and edge abuse controls suitable for an account-free registration endpoint. The application never trusts a client-supplied forwarding address. `CF-Connecting-IP` must be supplied by Cloudflare ingress; do not place an untrusted proxy in front that permits spoofing it.

Cloudflare observes network metadata, random installation/device identifiers, record sizes/timing, and APNs device tokens/environment. The installation DO stores token hashes, device registrations, counters, and expiring opaque push references/statuses. It does not store relay records, host URLs, user names, or conversation data. Explicit deletion erases installation records; there is no general historical message store. Automatic invocation logging and preview URLs are disabled so paths/identifiers are not captured by default. Enable any future operational telemetry only with explicit field redaction and retention rules.

The maintained deployment uses `hermes-jr-companion.cybercultured.com`. Its custom domain is declared in `wrangler.staging.jsonc`; self-hosters should replace that hostname with their own. Workers development and preview hostnames are disabled.

`workers_dev:false` and the absence of a public route keep the default configuration from publishing a service accidentally. The explicit `wrangler.staging.jsonc` enables only the custom hostname with separate rate-limit namespace IDs. The IDs `71001`/`71002` in the default template must not collide with another application's rate-limit namespaces. `npm run build` performs a dry run; actual deployment uses an explicit Wrangler deploy or Cloudflare API request.

Cloudflare/API references used: [hibernatable WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/), [rate-limit bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/), [Workers tests](https://developers.cloudflare.com/workers/testing/vitest-integration/write-your-first-test/), [Apple token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns), and [APNs requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).

Hermes Jr. and this companion are independent projects, not affiliated with or endorsed by [Nous Research](https://github.com/nousresearch) or [Hermes Agent](https://github.com/nousresearch/hermes-agent).

See [Operations](OPERATIONS.md) for global admission limits, private counters, emergency controls and spending limitations.

## Phone-bound numeric pairing

The service now supports short-lived signed setup tickets and a `SetupIntent`
Durable Object per attempt. Configure the separate `SETUP_TICKET_PRIVATE_KEY`
secret (base64url Ed25519 PKCS#8 DER) and deploy the `v3-setup` migration before
shipping the matching app and companion. Generate it privately with
`Scripts/create-setup-signing-key.py`; do not reuse APNs or release-signing keys.
Without this secret, new pairing is unavailable; already-paired devices can still reconnect.

`POST /v1/pairing/intents` creates the ticket, a separate owner credential, and
`prompt`, the complete text iOS copies/shares. Edit `src/setup-prompt.ts` and deploy
the relay to change the wording for new attempts without another iOS release
(after users have installed the app version that consumes this field). Deploy
the relay before that app version. Existing pending attempts retain their saved
text; older clients continue using their bundled wording.
`GET /v1/pairing/key` exposes only the issuer's public key. Subsequent setup
requests carry the public ticket in `X-Hermes-Setup` and the appropriate private
credential in `Authorization`. Hosts need an admitted installation to claim;
the broker never authorizes Hermes access itself. Pending claims are bounded to
three, and selection is atomic. The service budgets 100 new intents/day as well
as IP and existing service-wide request/push limits. This is a deliberately
bounded initial rollout; App Attest is not yet implemented.

Read `Protocol/SETUP.md` for the complete construction, API roles, lifecycle,
limitations, signing-key rotation behavior, and validation.

### Separate APNs environment keys

`APNS_KEY_ID` and `APNS_PRIVATE_KEY` remain the base credentials (sandbox on the hosted service). To use a separate production-only, topic-specific Apple key, set both optional secrets `APNS_PRODUCTION_KEY_ID` and `APNS_PRODUCTION_PRIVATE_KEY`, then set `APNS_ENVIRONMENT` to `both`. The production key must allow `APNS_TOPIC` and belong to `APNS_TEAM_ID`. A partial production override fails closed; it never falls back to the sandbox key. Without either override, existing self-hosted dual-environment keys retain their current behavior. Provider tokens are cached separately by signing key, including across Durable Object restarts.
