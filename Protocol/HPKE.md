# Hermes Jr. encrypted connection, version 1 (prototype)

This protocol uses RFC 9180 HPKE **Auth** with DHKEM(X25519, HKDF-SHA256),
HKDF-SHA256, and ChaCha20Poly1305 (mode 2; KEM 32; KDF 1; AEAD 3).
CryptoKit supplies the iOS implementation; PyHPKE 0.6.5 supplies Python's.
The application handshake, authorization boundary, framing, and reassembly
specified here are Hermes Jr. code. They have **not been independently audited**.

HPKE with static recipient keys does **not provide forward secrecy against
later recipient-key compromise**. Someone who records relay traffic and later
obtains the relevant recipient private key can decrypt that direction's past
traffic. Auth mode also has key-compromise impersonation limitations. Do not
describe this prototype as forward secret or independently reviewed. See
[RFC 9180 security considerations](https://www.rfc-editor.org/rfc/rfc9180.html#section-9).

The relay receives ciphertext and routing metadata, never the paired host or
phone private keys. It can see public handshake keys, nonces, timing, sizes,
and connection/routing identifiers; it can deny service. HPKE does not hide
plaintext lengths. TLS is still required between each endpoint and the relay.

## Caller contract

The phone must authenticate the host's 32-byte X25519 public key through the
explicit numeric comparison in [SETUP.md](SETUP.md).
Do not replace an established pinned key based on relay responses.
Store the phone's private key using the iOS Keychain. The host persists its
private key and authorized-device registry locally with restrictive permissions.
The crypto module does not implement secret storage or pairing-secret storage.

Enrollment secrets are random, single use, and expire. Numeric setup requires
explicit code comparison and binds enrollment to the phone’s expected public key.
The first encrypted authentication payload is caller-owned JSON,
for example `{"pairing_secret":"...","device_name":"...","device_id":"..."}`.
A registered device can omit the pairing secret. IDs and names do not authorize
anything: the caller binds them to the cryptographically authenticated phone key.

On the host:

```python
handshake = HostHandshake(host_private_key_bytes)
challenge = handshake.receive_hello(hello)
authentication_json_bytes = handshake.receive_auth(auth_record)
# Validate the invitation OR verify that this exact public key is already approved.
# Keep pending devices pending; do not forward APIs before approval.
authorize(handshake.device_public_key, authentication_json_bytes)
ready_record, channel = handshake.finish()
records = channel.seal(application_json_bytes)
message_or_none = channel.receive(record)
```

On iOS:

```swift
let handshake = try CompanionClientHandshake(
    hostPublicKey: pinnedHostKey, devicePrivateKey: keychainDeviceKey
)
let hello = try handshake.makeHello()
let auth = try handshake.receiveChallenge(challenge, authentication: authJSON)
let channel = try handshake.receiveReady(readyRecord)
let records = try channel.seal(applicationJSON)
let messageOrNil = try channel.receive(record)
```

Both `seal` and `receive` mutate connection state. The transport MUST serialize
complete seal/send operations, sending every resulting record in order before
starting the next message. Receive records in socket order. Never share a
channel between sockets or persist, copy, or resume an HPKE context. On any
failure or reconnect, discard the handshake/channel and create a fresh one.
`invalidate()` explicitly closes and drops references to cryptographic contexts
and partial messages; this is not a guarantee of memory zeroization in Swift or
Python. The transport must bound inactive handshakes/connections and apply idle
timeouts, including while waiting for manual approval.

Revocation must close a device's live channel and revoke its subscriptions and
relay credentials as well as remove its key from the approved registry. Check
continued authorization at each application operation. `finish()` is a caller
authorization boundary; cryptographic possession of a key alone does not mean
the host owner has approved that key.

## Binary wire format

All values below are raw bytes. Integers are unsigned big endian. `||` denotes
concatenation, `NUL` is one zero byte, strings are their exact UTF-8 bytes.
All keys, encapsulations, and random challenges are exactly 32 bytes. The relay's
device-routing envelope is outside this protocol and must not modify its bytes.
No JSON field order or Unicode normalization is used in cryptographic bindings.
The suite/version is fixed; unknown versions are rejected, not negotiated down.

1. Phone -> host, hello: `0x01 || phone_public_key || phone_nonce` (65 bytes).
   The phone generates a fresh cryptographically random nonce per handshake.
2. Host generates a fresh cryptographically random host nonce, constructs the
   transcript below, creates the host-to-phone HPKE Auth sender, and sends:
   `0x02 || host_nonce || host_enc || host_proof_record`.
3. Phone decrypts and checks the host proof using the public key verified by numeric comparison.
   Only after this check, it creates its phone-to-host HPKE Auth sender and sends:
   `0x03 || phone_enc || authentication_record`.
4. Host decrypts the authentication record using the phone public key from the
   hello. The caller validates pairing/approval using that authenticated key.
   Only after approval, host sends the encrypted ready record. Phone verifies it
   binds the exact phone encapsulation, then both sides may send application data.

The transcript is:

```text
T = "hermes-jr/hpke/v1" || NUL
    || host_public_key || phone_public_key || phone_nonce || host_nonce
info_h2c = T || NUL || "h2c"
info_c2h = T || NUL || "c2h" || host_enc
```

Each direction uses its own standard HPKE Auth sender/recipient context. The
host-to-phone context uses the phone key as recipient and host key as authenticator;
the phone-to-host context reverses these roles. HPKE manages its own AEAD keys and
nonces. Hermes Jr. does not implement a KDF or set HPKE's internal AEAD nonce.

Every encrypted record has this layout:

```text
kind:u8 || sequence:u64 || ciphertext_with_16_byte_tag
AAD = "hermes-jr/record/v1" || NUL || T || direction
      || kind:u8 || sequence:u64
```

Each direction starts its sequence at zero and increments once per sealed/opened
record. Only the exact expected sequence is accepted. Sequences are capped at
`2^32 - 1`, after which a fresh connection is required. The encrypted kinds are:

| Kind | Direction/sequence | Plaintext |
| --- | --- | --- |
| `0x10` | host-to-phone / 0 | exact `hermes-jr/host-ready/v1` |
| `0x11` | phone-to-host / 0 | caller-owned authentication JSON bytes |
| `0x12` | host-to-phone / 1 | `hermes-jr/authorized/v1` followed by NUL and `phone_enc` |
| `0x20` | phone-to-host / 1 onward; host-to-phone / 2 onward | application fragment below |

Fresh endpoint nonces bind every connection's contexts. The host-generated nonce
prevents replay of an old phone authentication into a new host connection, including
after restart. The phone nonce prevents accepting a recorded old host challenge.
The c2h context additionally binds the host encapsulation; the encrypted ready
binds the phone encapsulation. In-stream sequences reject duplicates/reordering.
These are application replay protections; HPKE alone does not supply them.

Malformed, unauthenticated, reordered, duplicate, oversized, or unexpected records
permanently invalidate that connection. Do not keep going after an authentication
error, retry decryption with another key, reset a sequence, or skip a record.

## Message fragmentation

One logical application message may be at most 40 MiB. The module splits it into
records containing no more than 48 KiB of HPKE plaintext, including a 16-byte header:

```text
message_id:u64 || total_message_bytes:u32 || offset_bytes:u32 || chunk
```

Thus each chunk is at most 49,136 bytes. The encrypted record is at most 49,177
bytes, below the 64 KiB relay payload limit. Authentication payloads are also
capped at 48 KiB; binary handshake envelopes remain below 64 KiB.

Message IDs start at zero independently in each direction and increment after
each complete logical message. Fragments must have the next message ID, consistent
total size, exact next offset, and must never exceed the declared total. No logical
message interleaving is permitted. Empty messages use one header-only fragment.
Nonempty messages cannot contain an empty fragment. The receiver returns data only
when the full message has been authenticated and assembled. The reassembly buffer
is bounded by 40 MiB, and all references are dropped on failure.

## Verification

The Swift/Python interoperability harness currently lives in the Hermes Jr. iOS development workspace. It is not included in this companion repository.

The harness compiles the production Swift crypto module into a tiny command-line client,
then exchanges real binary handshake and data records with the production Python
host module over local process pipes. Tests cover both directions, empty and Unicode
payloads, fragmentation, wrong host keys, altered handshake records, the authorization
boundary, ciphertext tampering, replay/reorder, reconnect replay, and reassembly caps.
The first three sequential Auth/X25519/ChaCha20Poly1305 ciphertexts from
[RFC 9180 Appendix A.2.3](https://www.rfc-editor.org/rfc/rfc9180.html#appendix-A.2.3)
are decrypted by both libraries. These checks establish interoperability and exercise
failure behavior; they are not a substitute for an independent protocol/code audit.

APIs: [Apple HPKE.Sender](https://developer.apple.com/documentation/cryptokit/hpke/sender),
[Apple HPKE.Recipient](https://developer.apple.com/documentation/cryptokit/hpke/recipient),
[PyHPKE](https://pyhpke.readthedocs.io/en/latest/api.html).

## Enrollment after numeric comparison

After the phone confirms the matching numbers, the host encrypts enrollment to the phone key bound in its signed ticket. The HPKE connection must prove possession of that same key and the single-use enrollment secret. Routing tokens alone cannot authorize. Expired/revoked enrollment and different phone keys are rejected. Already-approved phones reconnect using their pinned keys.
