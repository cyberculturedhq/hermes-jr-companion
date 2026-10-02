# Hermes Jr. for iOS

A native SwiftUI companion for your existing [Nous Research Hermes Agent](https://github.com/NousResearch/hermes-agent) installation.

Connect, then select **Profiles** or **Bots** on the home screen. **Profiles** opens a profile’s session list. You can resume a conversation or start a new session. **Bots** opens that profile’s existing **Bot Chat**, including its latest continuation after history compression. Create a missing Bot Chat in Hermes first. Bot Chat keeps its fixed title and continuous conversation. Use `/compress` to reduce its context. Conversations use the profile’s existing model account, tools, skills, memory, and session history.

The app, [Hermes companion plugin](Companion/README.md), and [Cloudflare relay/push service](RelayService/README.md) are original code licensed under the [MIT license](LICENSE). This private repository contains the iOS app and its supporting source; the [companion/service repository](https://github.com/cyberculturedhq/hermes-jr-companion) is public. The remote-access and notification integration is a prototype validated locally, through Cloudflare staging, and on a physical iPhone.

## Remote access and notifications

One companion plugin provides two independent features:

| Your connection | What to install |
| --- | --- |
| Existing LAN, Tailscale, or HTTPS dashboard | Nothing extra for chat |
| Existing direct connection plus notifications | Companion with push enabled |
| No externally reachable dashboard | Companion with relay enabled; push is optional |

For relay access, the host keeps Hermes on loopback and opens an outbound connection to the configured service. In Jr., copy the phone-bound setup prompt into Hermes. When setup is ready, compare all three code groups on both devices and tap **It’s correct** on the phone. No Tailscale installation, relay account, or inbound port is required. Setup and managed startup are documented in [Companion/README.md](Companion/README.md).

Enable notifications in the connection details. Conversations opened in Jr. are followed automatically, and their context menu can follow or mute future alerts. Completion, approval, clarification, and failure events notify when the conversation is not actively viewed. Profile names, conversation titles, and event details are encrypted for the phone; a generic alert is the fallback. Tapping a notification opens its conversation. The host must stay awake with Hermes and the companion running. Apple delivery is best effort.

Relay traffic is encrypted between the phone and companion using CryptoKit/PyHPKE. The service can observe routing identifiers, IP addresses, sizes/timing, and push tokens; it cannot read conversation payloads. The [versioned protocol and threat model](Protocol/HPKE.md) document authenticated pairing, replay handling, and the prototype's limitations: static recipient keys do not provide forward secrecy, and the protocol has not had an independent security audit.

Self hosting is supported by selecting your own relay URL. A self-built app can use direct access and relay with its own Apple signing identity. Real push also requires an APNs provider configured for that build's exact bundle ID and environment; our Apple signing key is never distributed with the app or plugin.

## Run the app

Open **Hermes.xcodeproj**, select the **Hermes** scheme and an iPhone simulator, then Run. Requires Xcode 26 or newer and iOS 18 or newer. There are no third-party iOS dependencies. For a physical iPhone, choose your Apple development team in Signing & Capabilities.

The welcome screen creates a short-lived setup prompt bound to a new iPhone key. Users copy or share it with Hermes, receive a readiness notification when permitted, then compare codes and confirm. Foreground polling and persisted setup state let the flow resume without push delivery. An existing reachable Hermes dashboard can instead be connected using the separate address screen.


## Connect your installation

This app uses the **Hermes dashboard/headless backend**, normally port **9119**. The OpenAI-compatible API server on port 8642 is a separate service; its `API_SERVER_KEY` cannot authenticate this app.

### Simulator on the same Mac

Start the backend if it is not already running:

```sh
hermes serve
```

Connect to `http://localhost:9119`. Leave authentication empty for Hermes’s default loopback mode. The app obtains the dashboard’s local session token through Hermes’s own bootstrap mechanism.

### Physical iPhone, LAN, VPN, or hosted installation

`localhost` on a physical phone means the phone itself. Use the Mac’s network address, such as `http://your-mac.local:9119`, or your hosted HTTPS URL. The backend must listen on a reachable interface and have dashboard authentication configured.

If you already use Tailscale, keep Hermes on loopback behind Tailscale Serve with HTTPS when practical, or bind `hermes serve` only to the machine’s Tailscale IP. Hermes still requires a dashboard authentication provider for either non-loopback binding or a non-loopback public URL. Hermes Jr. accepts direct Tailscale IPv4 addresses in `100.64.0.0/10` over HTTP as well as Tailscale Serve HTTPS hostnames. The companion relay above is the alternative for users without a direct network path.

Follow the official [Hermes remote-backend setup](https://hermes-agent.nousresearch.com/docs/user-guide/desktop). With dashboard login credentials configured, the server command is:

```sh
hermes serve --host 0.0.0.0 --port 9119
```

Enter that dashboard username/password under **Authentication** in the app. A dashboard access token is also supported. The app keeps saved credentials in the iOS Keychain; it never copies your model-provider credentials to the phone. Disconnect removes the saved connection credentials.

Use HTTPS for public hosts. Local HTTP is accepted only for private IPs and `.local` names. URL redirects and invalid certificates are not bypassed. Give the app Local Network access when iOS requests it. Your Mac must remain awake and the backend must remain running.

Browser-based OAuth sign-in is not implemented in this first version; OAuth installations need a dashboard access token. Tokens can expire and then require reconnection. Password-backed sessions use Hermes’s cookie refresh mechanism while the app is running and sign in again from Keychain on launch.

## Included

- Real profile discovery, profile names/descriptions, and Hermes avatar images.
- Paginated session and transcript loading, searchable native conversation lists, and message timestamps.
- New sessions and existing-session continuation with the correct profile and server identity.
- Streaming text, Markdown/code display, copy, tool activity, stop, and native tool approvals and clarification answers.
- One animated three-dot typing bubble before the first response text, with a still indicator when Reduce Motion is enabled.
- A native photo picker with local previews and removal. Photos upload through Hermes only when you tap Send; photo-only prompts are supported.
- Type `/` in a session to browse Hermes controls, with descriptions and argument completions in a native list. Selecting a suggestion edits the draft; Send runs it. Control output opens in a native sheet, and session titles refresh after renaming.
- Restored connections, explicit loading/errors, and draft retention after delivery failures. Failed prompts are never automatically retried.
- Standard iOS lists, forms, navigation, alerts, and sheets, with Messages-style blue/gray conversation bubbles. Bubble insets, tight body-font leading, grouping, and composer spacing were compared directly with Messages in the iOS 26.5 Simulator. System light/dark appearance, Dynamic Type, VoiceOver labels, and iPhone and iPad layouts.

Hermes remains the source of truth. The app reloads persisted history after each turn. Sessions that have undergone compression follow Hermes’s existing lineage handling. A profile’s messaging gateway does not need to be running for dashboard chat.

Command availability comes from the connected Hermes catalog and the controls supported by this client. Terminal and desktop interface commands are omitted. Unknown commands and failed control requests are never silently submitted as chat prompts or automatically retried.

The tested Hermes version discovers custom commands in the gateway's launch profile. The app verifies that profile before offering those commands; other profiles retain the supported session controls. Model choices and reasoning changes are scoped to the open session.

## Verification

The integration was checked against local Hermes **0.21.1** (commit `4a39a3ff8b`, September 9, 2026). The read-only live check authenticated, discovered five profiles, paginated the first profile’s sessions, and read a transcript. No model credential or transcript contents were printed.

A user-approved simulator test also created **Test Hermes iOS connection**, received the real reply **“Hermes iOS connected.”**, and reopened the saved conversation successfully. That test session remains available in the default profile.

Build and run unit tests:

```sh
xcodebuild -project Hermes.xcodeproj -scheme Hermes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath /tmp/hermes-ios-build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

Adjust the simulator name to one installed in Xcode. Keep ad-hoc signing enabled for Simulator so Keychain has an application identity. The tests cover address/authentication boundaries, secure credential storage, and demo session continuity.

`Validation/fixture_server.py` and `Validation/ProtocolSmoke.swift` exercise the actual Swift transport against an isolated local protocol fixture: invalid credentials, URL prefixes, profile isolation, pagination, create/resume identities, streaming, approvals, and cancellation. The fixture requires Python with `aiohttp` (already included in a normal Hermes virtual environment). Run:

```sh
./Validation/run-checks.sh
```

The fixture also checks photo staging, photo-only prompts, cleanup after rejection, and protection against duplicate uploads after uncertain acknowledgements. It never calls a model or touches real Hermes sessions.

The direct-transport suite passes 27 protocol cases. Command coverage includes scoped discovery, canonical autocomplete, model/provider choices, reasoning levels, confirmation, title/new-session behavior, and rejection or uncertain outcomes without duplicate execution. Simulator checks also loaded live model suggestions and ran the read-only `/status` control against the saved connection-test session.

The companion validation adds iOS unit tests, Python hook/API/state tests, RFC 9180 crypto vectors and Swift/Python interoperability, and real workerd tests for the relay. [Validation/COMPANION.md](Validation/COMPANION.md) runs the production Swift client through a local Worker and Python bridge against an isolated Hermes fixture. It covers first-time pairing and host approval, history, streaming, multi-record photo uploads, concurrency, cancellation, and revocation. These fixtures do not access real conversations or call models.

The [physical iPhone push test](Validation/REAL_PUSH.md) also passed against staging:
real sandbox registration, automatic conversation following, Apple acceptance
(HTTP 200), visible notification, and a tap opening the correct conversation.
The temporary installation was deleted afterward. Apple configuration and
deployment details are in [APPLE-SETUP.md](Protocol/APPLE-SETUP.md) and
[STAGING.md](RelayService/STAGING.md).

## Scope of this version

This is a client for managing existing profiles and their conversations. Profile creation/configuration, secret/password prompts, and scheduled-bot administration remain in Hermes. The app can display a request to continue a secret or sudo prompt in the dashboard, but does not collect those secrets itself. iOS background execution is not guaranteed; when returning after a broken connection, reopen the session to reconnect and load persisted history.

Just-sent photo previews are retained on this device during transcript refresh. Older or reopened photo history currently displays Hermes’s attachment references; downloading historical media is not implemented. Attachment transport is verified with isolated fixtures; the live account test covered text only.

Protocol references: [dashboard WebSocket routes](https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/web_routers/chat_ws.py), [session RPC](https://github.com/NousResearch/hermes-agent/blob/main/tui_gateway/methods_session.py), [prompt RPC](https://github.com/NousResearch/hermes-agent/blob/main/tui_gateway/methods_prompt.py), and [dashboard authentication](https://github.com/NousResearch/hermes-agent/tree/main/hermes_cli/dashboard_auth).

Hermes Jr. is an independent project, not affiliated with or endorsed by [Nous Research](https://github.com/nousresearch) or [Hermes Agent](https://github.com/nousresearch/hermes-agent).

The new setup bootstrap and its service configuration, trust boundaries, and validation are documented in [Protocol/SETUP.md](Protocol/SETUP.md).
