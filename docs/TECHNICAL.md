# Companion technical guide

The companion connects Hermes Jr. to Hermes and delivers notifications. Remote access and Apple notifications have separate switches. Direct LAN/Tailscale connections continue to work without the bridge's remote-access switch.

This is an integration prototype. The relay only carries ciphertext and opaque routing/notification references; it still sees IP addresses, connection timing, sizes, and APNs device tokens. The phone pins the host key from pairing, and the host approves each phone key. See [the protocol](../Protocol/HPKE.md) for the exact cryptography and its limits, including lack of forward secrecy against later recipient-key compromise. This project has not received an independent security audit.

## Install with Hermes

Give Hermes the prompt in [INSTALL.md](../INSTALL.md), using https://github.com/cyberculturedhq/hermes-jr-companion. This prototype requires a running bridge and loopback Hermes dashboard; run `hermes jr service install` once to enable automatic startup and crash recovery. See [STARTUP.md](../STARTUP.md) and [UPDATES.md](../UPDATES.md).

## Local development

Run these commands from the repository root.

Python 3.10+, macOS or Linux, and a Hermes version providing native plugin hooks and dashboard plugin APIs are required. Dependency versions belong to this package; Hermes does not automatically install `python_dependencies` from a plugin manifest.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e ./plugin
.venv/bin/python -m unittest discover -s tests -v
```

For a real Hermes installation, follow [INSTALL.md](../INSTALL.md). It includes a prompt you can give Hermes, native plugin installation, dependencies, all-profile activation, and pairing.

No command in this repository automatically changes the user's Hermes installation or enables a plugin. `register(ctx)` only registers hooks and the `hermes jr` CLI command; it never opens sockets or starts daemons. The standalone `hermes-jr` command has the same subcommands when testing outside Hermes.

## Numeric pairing and revocation

Follow [INSTALL.md](../INSTALL.md) with the setup ticket from Jr. The phone and host compute comparison codes independently. The user checks all three groups and confirms on the phone; enrollment then completes over the encrypted connection. Success is reported after profile discovery.

```sh
hermes jr devices
hermes jr revoke DEVICE_UUID
hermes jr status
```

Revocation immediately removes local authorization, follows, and notification references. The bridge retries remote removal if the service is unavailable. Already-approved phones reconnect using their pinned keys.

## Notifications independently of relay

After APNs is configured in the service, enable notifications with the same setup command:

```sh
hermes jr setup --service https://your-relay.example --push
```

Omitting `--relay` preserves its current value. Use `--no-relay` or `--no-push` to explicitly disable either feature. For a Tailscale-only user, initial setup with `--push` leaves remote access disabled. The bridge still runs to deliver the notification outbox. The iOS app registers its APNs token through the dashboard plugin API; host setup never asks users for Apple signing credentials.

Only opened/followed conversations notify. The plugin queues completion, failure, human approval, and `clarify` tool events from durable session/profile identities. It excludes interrupted cleanup and smart auto-approval events, deduplicates each event, follows compression ancestry when Hermes exposes it, and suppresses alerts during a 45-second foreground presence lease renewed by the phone. Notification details are encrypted for the phone, with a generic fallback and random reference; opening one fetches its local profile/session mapping after authentication. References expire after seven days. Failed service delivery retries from the private SQLite outbox.

Hermes exposes no dedicated clarification-request observer, so this version observes `pre_tool_call` for `clarify`. If another policy subsequently blocks the tool, the attempted clarification can still trigger an alert. Hooks never transmit question/command/prompt text. Hook delivery follows the profiles where this plugin is enabled; older Hermes builds may omit correlation fields, in which case the plugin safely skips the event.

Remote phone disconnects discard their cryptographic contexts while preserving the companion's local Hermes WebSocket. Reconnection reads durable history instead of an unlimited in-memory event backlog. Direct clients continue to use `close_on_disconnect=false`; Hermes decides whether inactive detached work is healthy enough to continue. The companion does not resume every historical followed conversation just to keep it alive.

## Configuration and private state

Private data lives under `<Hermes root>/plugin-data/hermes-jr/` (directory mode 0700, SQLite mode 0600), outside the replaceable plugin installation. It includes the host encryption key and relay token, device admission tokens, hashed local credentials, public phone keys, subscriptions, and notification references. Restrict filesystem access and protect backups. `HERMES_JR_STATE_DIR` selects isolated fixture state for tests or an explicitly shared installation location; never point tests at real state.

The bridge accepts only a loopback dashboard origin and never follows redirects. It bootstraps Hermes' loopback token from the documented dashboard script. Authenticated dashboards instead use `HERMES_JR_DASHBOARD_TOKEN` (dashboard bearer access token), or `HERMES_JR_DASHBOARD_SESSION_TOKEN` for an explicit local session token. Supply secrets through the supervisor's protected environment, not CLI flags. They never travel through the relay.

REST forwarding is limited to profiles/session reads and the companion's own endpoints. RPC forwarding has a fixed allowlist for Jr.'s session, approval, clarification, image, model, and command functions; it cannot request arbitrary URLs, filesystem endpoints, configuration keys, or raw terminal RPCs. Existing Hermes RPC semantics and authorization still apply.

## HTTP interface

Routes mount at `/api/plugins/hermes-jr`; Hermes' normal dashboard authentication applies first. `GET /v1/capabilities` and `POST /v1/enroll {device_name}` work before device enrollment. Enrollment returns `{device_id,device_token,installation_id}`; this token is a local device credential, separate from cloud relay admission. Subsequent direct requests use `X-Hermes-Jr-Device` and `X-Hermes-Jr-Token`. Encrypted relay requests inherit their approved channel's device identity.

| Operation | Request |
| --- | --- |
| Capabilities | `GET /v1/capabilities` → `{protocol_version,relay_enabled,push_enabled,installation_id}` |
| Follow | `PUT /v1/follows {profile,session_id}` |
| Unfollow | `DELETE /v1/follows?profile=…&session_id=…` |
| List follows | `GET /v1/follows` → `{follows:[{profile,session_id}]}` |
| Foreground presence | `PUT /v1/presence {profile,session_id,active}` |
| Register Apple token | `PUT /v1/devices/self/push {apns_token,environment:"sandbox"|"production"}` |
| Disable Apple token | `DELETE /v1/devices/self/push` |
| Resolve notification | `GET /v1/notifications/:reference` → `{profile,session_id,kind}` |

Application envelopes are `{type:"rpc",body:<existing JSON-RPC frame>}` and `{id,type:"http",method,path,query,body}`. HTTP responses are `{id,type:"http",status,body}`. RPC responses/events retain their original body. HPKE framing fragments these application messages into bounded encrypted records; the relay's host socket prefixes each record with the 16-byte routing device UUID.
