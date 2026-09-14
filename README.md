# Hermes Jr. Companion

The Hermes plugin for **Hermes Jr.**, our iPhone app.

Connect to your Hermes agent from your phone and get notified when a conversation you follow finishes or needs your attention. The companion runs in the background on your Hermes computer. **Your conversations and notification details are encrypted before they reach our relay.**

## Private by design

Your Hermes computer and paired iPhone handle the private content. Our relay delivers encrypted data.

- **Encrypted conversations:** remote access uses end-to-end encryption with a host identity pinned by the private QR you scan. A relay credential alone cannot unlock your agent.
- **Encrypted notification details:** profile names, conversation titles, and event types are encrypted on your Hermes computer and decrypted on your iPhone. Our relay and Apple’s push servers receive ciphertext and a generic fallback, not those details. Notification payloads are padded to a fixed size.
- **Keys stay with your devices:** notification keys are stored in the iPhone’s Keychain and the companion’s private local state, never sent to our relay. Phones receive separate keys.
- **Code you can inspect:** the companion and relay are open source. You can review them, fork them, or host the service yourself. The iOS source will also be published.

Encryption does not hide everything: the delivery services still see network/delivery metadata, random routing identifiers, and push tokens. Decrypted previews are visible to iOS and follow your lock-screen notification settings. Your Hermes model provider still processes the requests you send to it.

Rich push previews require the updated iOS app and companion, with key setup over the encrypted relay or HTTPS. Older versions and plain HTTP connections receive generic alerts. We have automated security tests, but **no independent security audit yet**.

Read [how notification encryption works](Protocol/NOTIFICATIONS.md) and the [relay encryption protocol](Protocol/HPKE.md).

## Set it up with Hermes

Give your Hermes agent this prompt:

> Install https://github.com/cyberculturedhq/hermes-jr-companion for Hermes Jr. Follow INSTALL.md, enable it across my existing profiles, set up automatic startup, and help me pair my iPhone. Preserve my current setup and don't interrupt running work.

Hermes handles the computer setup and opens a private pairing page in your browser. Scan the code in Jr.; your phone connects and Hermes continues automatically. Then allow notifications on your iPhone.

For new installations, our service address is **https://hermes-jr-companion.cybercultured.com**. You don't need your own Cloudflare account or Apple signing key.

## What it does

- **Connect from anywhere:** encrypted remote access without setting up Tailscale or opening a public port.
- **Notify you when needed:** updates from conversations you open or follow in Jr.
- **Keep working in the background:** automatic startup and recovery if the companion stops unexpectedly.

Already using Tailscale or a direct connection? You can enable notifications independently of remote access.

Your Hermes computer needs to be awake, with its Hermes dashboard running. The app and companion are currently in development; the hosted notification service supports iOS development builds.

## Make it your own

You're welcome to fork this companion, adapt it for your own app, and host your own service. We also plan to publish the Hermes Jr. iOS source so you can build or customize the app yourself.

Start with the [developer guide](docs/TECHNICAL.md) and [self-hosting instructions](RelayService/README.md). Your own iOS app needs its own push configuration; see the self-hosting guide.

## Help and details

[Installation](INSTALL.md) · [Startup and troubleshooting](STARTUP.md) · [Updates](UPDATES.md) · [Privacy and encryption](Protocol/HPKE.md) · [Roadmap](ROADMAP.md)

[MIT license](LICENSE).

Hermes Jr. and this companion are independent projects, not affiliated with or endorsed by [Nous Research](https://github.com/nousresearch) or [Hermes Agent](https://github.com/nousresearch/hermes-agent).

See [notification wording](docs/NOTIFICATIONS.md) for the alerts currently sent.

Updates are installed only when you ask. From 0.7.0, the companion verifies a release signature before installing an update. See [update security](UPDATES.md#release-signatures).
