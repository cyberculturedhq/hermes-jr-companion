# Phone-bound setup and numeric comparison, version 1

The phone copies a public setup ticket into Hermes. Once installation and service
readiness checks finish, the companion registers a claim. The phone and companion
perform a short-authentication-string (SAS) exchange and independently display
three four-digit groups. The user checks **all three groups** and taps **Codes
match — Connect** on the phone. Only that exact claim can then enroll the phone.

This is a Hermes-specific integration of the commitment-before-reveal construction
described by [Matrix SAS](https://spec.matrix.org/latest/client-server-api/#short-authentication-string-sas-verification)
and [ZRTP §4.4.1.1](https://www.rfc-editor.org/rfc/rfc6189.html#section-4.4.1.1).
It uses the existing CryptoKit, cryptography, and PyHPKE implementations. It is not
a Matrix/ZRTP implementation or an independently audited protocol. Review this
bootstrap, its state machine, and the existing HPKE protocol before broad release.

## Trust and authorization

- The install prompt contains a signed ticket and the phone's public key, never a
  pairing secret, private key, APNs token, or owner API credential.
- A fresh X25519 phone identity is created for each setup attempt, before copying
  the prompt. The private key and pending exchange state live in ThisDeviceOnly
  Keychain. The successful identity becomes that host connection's phone key.
- A copied ticket cannot authorize an attacker's phone. The host's final HPKE
  handshake must prove possession of the exact phone key in that ticket, in
  addition to validating the single-use enrollment secret.
- A copied ticket can generate competing host claims. No first-claim-wins rule
  exists. The phone shows each candidate code separately. At most three claims
  and three ephemeral phone keys are accepted over the entire attempt, including
  restarts. A dishonest broker cannot reset the phone's local budget.
- A bare Connect button, a matching hostname, recent activity, push receipt, or
  Face ID is not host authentication. First contact always requires comparison.
- The code is a comparison value, not a password. Read-only access to the code
  does not grant access. The user must trust the surface displaying Hermes' code:
  an attacker who can replace the code/instructions in that surface can defeat
  human verification. An actively compromised agent, host, or phone is outside
  this protection boundary.
- The ticket issuer is trusted to issue setup parameters. Its verification key
  is obtained over TLS from the **already configured service origin**, never an
  origin supplied by an unverified ticket. This is service/TLS trust, not an
  embedded offline public-key pin. The phone checks the signed phone key against
  its locally generated key. The host checks the ticket service against its own
  configured service. Tickets cannot authorize changing that configuration.
- Even a malicious broker cannot decrypt enrollment: HPKE Auth encrypts directly
  to the original phone identity, authenticated by the claimed host identity.
  Host identity remains provisional until the human comparison; the existing
  HPKE connection also proves possession before any Hermes application traffic.

## Signed ticket

`HJ1.<payload>.<signature>`, using canonical unpadded base64url for both parts.
The Ed25519 signature covers the UTF-8 bytes `HJ1.<payload>`. The payload decodes to
this six-element JSON array (the signed bytes are verified before parsing):

```
[1, intent_id, phone_public_key, issued_at, expires_at, service_origin]
```

`intent_id` is 32 random bytes; the phone public key is exactly 32 bytes. Both are
base64url. Times are integer Unix seconds; issuance can be at most 30 seconds in
the future and expiry at most 20 minutes after issuance. The response separately
returns a random 32-byte `owner_token`. It never enters the ticket/prompt; only its
SHA-256 hash is stored by the service. It authorizes polling, submitting the phone
key/confirmation, associating push, and cancelling/completing this intent. It does
not by itself authorize Hermes access.

`POST /v1/pairing/intents` also returns `prompt`, the complete plain-text install
message including the issued ticket. Wording lives in
`RelayService/src/setup-prompt.ts`; deploy the relay to change it for new attempts.
iOS copies/shares this text verbatim and saves it with the pending attempt, so a
relaunch preserves the same prompt and ticket. The app accepts at most 8192 UTF-8
bytes, requires the verified ticket, and rejects text containing the owner token.
Older relay responses and saved attempts without `prompt` use the legacy local
wording. Deploy the relay first, then release the app that consumes `prompt`;
subsequent wording changes require only a relay deployment. Already-installed
older iOS versions continue using their local wording.

The service uses a separate Ed25519 signing secret, `SETUP_TICKET_PRIVATE_KEY`
(base64url PKCS#8 DER). Rotation deliberately invalidates outstanding tickets;
users create fresh prompts. Never reuse APNs or release-signing keys.

## Comparison transcript and ordering

All encodings below are raw bytes unless identified as strings. `||` concatenates;
NUL is one zero byte. Keys are X25519, SHA is SHA-256, and HKDF/HMAC use SHA-256.
The current version has fixed algorithms with no fallback negotiation.

```
D = UTF8("hermes-jr/setup-sas/v1") || NUL
C = D || UTF8(ticket || NUL || claim_id || NUL || installation_id || NUL
              || host_public_key || NUL || host_name)
```

The ticket is its exact original string; UUIDs are lowercase canonical UUIDs.
`host_public_key` is canonical base64url; `host_name` is 1–80 printable ASCII
characters with no NUL. The name is descriptive, never an identity assertion.

1. Host generates an ephemeral X25519 key `H`, persists its private state, and
   publishes `commitment = SHA(D || UTF8("commit") || NUL || C || H.public)`.
   This claim is immutable. The host does **not** publish `H.public` yet.
2. Phone stores the claim and commitment. Only then does it generate a fresh
   ephemeral X25519 key `P`. It persists the private key before publishing
   `P.public`. An already-revealed new claim is rejected.
3. Host accepts and persists exactly one `P.public`, and only then reveals
   `H.public`. It never accepts a replacement phone ephemeral key or re-rolls its
   host key for this claim. The phone verifies the original commitment before
   displaying any code. Changed keys/commitments/context fail closed.
4. Both calculate:

```
T = SHA(C || H.public || P.public)
Z = X25519(H.private, P.public) = X25519(P.private, H.public)
K(label, length) = HKDF-SHA256(Z, empty salt, D || UTF8(label) || NUL || T, length)
```

All-zero/invalid shared secrets are rejected by the underlying X25519 libraries.
The SAS is `K("sas", 5)`, represented using Matrix's decimal method: the leading
39 bits become three 13-bit integers, each plus 1000. Display all three four-digit
groups. There is no modulo reduction, abbreviated comparison, or automatic
retry after a mismatch. The commitment limits useful guesses per exchange;
local attempt limits, expiry, and rate limits remain necessary.

5. After an explicit tap for that displayed claim, the phone persists its selected
   claim and sends:

```
confirmation = HMAC(K("confirm", 32), D || UTF8("phone-confirm") || NUL || T)
```

The host verifies this proof locally; a broker state such as `selected` or
`complete` never substitutes for it. The service atomically selects only one
claim, rejects competing confirmations, and accepts identical message retries.

## Enrollment and existing connection

After authenticating confirmation, the host creates an enrollment with the
expected phone identity in its local registry. It persists the chosen device ID,
routing token, and one-time secret before provisioning the relay device through
an idempotent PUT. Retrying never rotates a token or allocates another device.

The normal invitation JSON is encrypted with RFC 9180 HPKE Auth:

- Recipient: the original phone public key from the ticket.
- Authenticated sender: host's long-term key from the compared claim.
- Suite: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305.
- Info: `D || UTF8("enrollment") || NUL || T`; AAD: `T`.
- Envelope: base64url of `encapsulated_key || ciphertext`.

The envelope contains no SAS secret material. It cannot be transplanted between
attempts. The phone only decrypts after its **local persisted** human decision;
it checks the invitation's host key, installation ID, origin, and expiry against
the selected claim. It uses its original phone private key in the existing HPKE
handshake. The host additionally checks the expected phone key before accepting
the one-time invitation. No application data is released until this succeeds.

Normal reconnections use the saved identity and existing revocation checks.
This bootstrap does not add forward secrecy to the existing static-key traffic
protocol. See [HPKE.md](HPKE.md) for its remaining limitations.

## Lifecycle, service bounds, and notifications

- Ticket lifetime: 20 minutes. Comparison/enrollment lifetime: five minutes from
  phone key submission, capped by the ticket. Both endpoints enforce local
  deadlines; service-side clocks are not the only expiry check.
- Phone state persists in Keychain; host state persists in the private companion
  SQLite database. The companion service owns one active pairing job, protected by the host process lock. The CLI subprocess returns bounded, status-only JSON; the plugin execution middleware owns the native pairing panel and waits for the service. Codes are read locally by that panel, never returned to the model.
  Restarting the companion service resumes the same keys/claim; it does not reset limits. Cancelling or interrupting the native pairing panel cancels that unfinished host attempt.
- Both sides erase temporary keys after success. Phone cancellation revokes pending
  local enrollment and clears phone state. Host-panel cancellation revokes only
  its unfinished enrollment; cancel the old setup in Jr. before creating a new ticket. Host background cleanup removes
  abandoned setup secrets on expiry. Service completion/cancellation removes
  push destinations and exchange payloads immediately, retaining small replay
  tombstones until the ticket expires. Alarms then erase the remaining records.
- All setup HTTP requests have bounded bodies/responses, disallow redirects and
  credential-bearing URLs, and carry credentials in headers. No setup payloads,
  APNs tokens, or credentials are logged by the service.
- Signed tickets are verified before routing to an intent Durable Object. New
  host claims also require an admitted installation's host credential. The
  service permits at most 100 new intents/day, applies per-IP creation/request
  limits and the existing global request/push budgets, and sends at most one
  setup notification per intent. These are abuse controls, not proof of a
  legitimate app; App Attest is not implemented in this version.
- APNs contains only a fixed readiness message and `pairing_ready: intent_id`.
  It never contains codes, enrollment, or approval. Notification permission is
  optional. The app polls while foregrounded and fetches again on reopening.
  Stale pushes cannot authorize or resurrect an expired setup.

## Setup and verification

Generate a signing key into a private file with
`python3 Scripts/create-setup-signing-key.py /private/path/setup-key.txt`.
Configure its contents as the service's `SETUP_TICKET_PRIVATE_KEY` secret using
Wrangler; use `.dev.vars` only for local development. Deploy the `v3-setup`
Durable Object migration alongside the service. The iOS app and updated companion
must be released together with service support. The companion service owns the exchange. From companion 0.15.0, `pair --ticket` requires a loaded native question integration. Its subprocess hands off to the plugin, which displays the code in the originating CLI/TUI or desktop conversation and waits for authenticated connection. The panel dismisses automatically; a local response cancels this unfinished attempt and never approves. A short-lived, process-bound lease associates the subprocess with its panel. It is not pairing authority; only the phone can confirm. Restart loaded Hermes processes after installation or update. Existing phone connections remain compatible. Only `connected` indicates success; expiry and failure exit nonzero. Numeric comparison is the only supported new pairing flow.

In the `hermes-ios` development workspace, run the Python tests, relay tests/typecheck, iOS tests with simulator signing
enabled (Keychain requires entitlements), and
`Companion/.venv/bin/python Validation/setup_fixture.py`.
The fixture uses real Swift/Python crypto and the local Worker, compares both
codes through the panel’s local state after checking that CLI output contains no code, restarts the service, completes HPKE, reads only fixture messages,
and checks cleanup. It uses no production keys or notifications.

Real notification delivery and background/cold-launch behavior still require a
signed build on a physical iPhone. Local tests and test vectors are not an
independent security audit.
