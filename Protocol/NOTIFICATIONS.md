# Encrypted notification previews, version 1

The host encrypts the profile name, conversation title, event category, and expiry before submitting a push. The iOS Notification Service Extension authenticates and decrypts the payload locally, then formats the title and body. It performs no network fetch. The title is the profile name alone; no conversation excerpts are included.

## Keys and trust boundary

The iPhone creates an independent random 256-bit key and random 128-bit key identifier per enrolled connection. Registration sends `notification_key: {key_id, secret}` to the authenticated **local companion** alongside the APNs registration. The app enables this only over its authenticated encrypted relay session or HTTPS. The companion strips the key before forwarding APNs registration to the delivery service. Plain HTTP, including HTTP addresses that may be protected externally by Tailscale, retains generic notifications because the app cannot verify that external protection.

The key is separate from relay stream keys. The iPhone stores it in a Keychain access group shared only with its notification extension, using `AfterFirstUnlockThisDeviceOnly`. The host stores it in its private companion SQLite state (directory 0700, database 0600). The app's Hermes credentials remain in its original private Keychain group. The shared group contains only notification keys and opaque account mappings.

Disabling notifications removes the phone’s preview key and clears the host key; forgetting the connection removes its local preview key. Host revocation deletes its key and queued details. Already delivered previews cannot be recalled. Keys do not provide forward secrecy: compromise of a notification key can reveal retained ciphertext from that key’s lifetime. Before the first unlock after reboot, or when a key is unavailable, only the generic fallback is shown.

## Wire format

The existing host-authorized push request accepts an optional object:

```json
{"reference":"RANDOM_REFERENCE","encrypted":{"v":1,"kid":"KEY_ID","data":"BASE64URL_NONCE_CIPHERTEXT_TAG"}}
```

All encodings are unpadded canonical base64url. `reference` is 32 random bytes, `kid` is 16 random bytes. Each notification uses a fresh random 12-byte nonce with ChaCha20-Poly1305 (RFC 8439), implemented by Python cryptography and Apple CryptoKit. No stream context or sequence is reused.

Authenticated additional data is UTF-8 `hermes-jr/notification/v1` followed by NUL, the encoded key ID, NUL, and the encoded reference. This binds details to the destination key and tap reference. Plaintext is a two-byte big-endian JSON length, followed by UTF-8 JSON and zero padding to exactly 1024 bytes:

```json
{"kind":"approval","profile":"Research","conversation":"Weekend trip","expires":1800003600}
```

The encrypted `data` contains nonce (12), ciphertext (1024), and tag (16): 1052 bytes, or 1403 base64url characters. The host strips control/format characters and bounds profile names to 120 UTF-8 bytes and conversation titles to 240 bytes. Missing titles produce useful generic body text with the profile still shown.

The relay accepts only bounded envelope fields, never plaintext titles/bodies. It forwards the envelope with `mutable-content: 1`, generic alert text, and the existing opaque tap reference. Total APNs JSON remains below 4096 bytes. Old clients without a registered preview key receive the generic payload without an encrypted envelope.

Guided updates add the encrypted event kind `update_completed`. Its opaque reference resolves to the update conversation. Only the signed installer or recovery of its committed journal may queue this event, after verifying the installed version and host connection; notification settings and revocation still apply. The delivery service sees no additional plaintext.

The extension validates the envelope, authentication tag, lengths, padding, supported event, and expiry before displaying details. Expiry is one hour after encryption, with five minutes of future clock tolerance. Wrong keys, tampering, missing keys, or expiry fall back to a generic alert. Server-side reference deduplication limits repeated submissions; expiry bounds replay, but the extension does not maintain a persistent replay ledger, so a malicious delivery service could repeat a valid notification within that window. A push never approves an action; opening the app reconciles the authenticated host state.

## What the services can see

Cloudflare sees installation/device identifiers, network addresses, timing, delivery counters, push tokens/environment, key IDs, fixed-length ciphertext, and opaque references. APNs sees its delivery token/topic, timing, generic text, ciphertext, key ID, and reference. Neither is given the notification decryption key. The relay does not persist the ciphertext; delivery receipts retain opaque references and fixed status fields. APNs delivery and retention are controlled by Apple.

Once decrypted, preview text belongs to the device’s notification UI and may appear on the lock screen according to iOS settings. This design protects delivery confidentiality; it does not hide metadata, protect a compromised endpoint, or change Hermes’ model-provider data handling.

## Validation and deployment

Tests cover Python-to-CryptoKit interoperability for all four events, ciphertext/reference tampering, wrong keys, expiry, size bounds, shared Keychain persistence/removal, per-device key storage, and stripping keys from service-bound registration. Worker tests check strict envelope limits, generic fallback, and APNs payload size. This is not an independent cryptographic audit.

Deploy the backward-compatible relay first, then update the companion and iOS app. Reconnecting with notifications enabled registers the preview key. Self-builders must embed the notification service extension and configure a shared Keychain access group for the app and extension; neither target needs an APNs signing key embedded in it.
