# Operating the relay

The hosted service uses **https://hermes-jr-companion.cybercultured.com** only.
The Workers development hostname and preview URLs are disabled. The internal
Worker name still contains `staging`; this does not create a second public endpoint.

## Admission and usage limits

Before allocating installation storage, the Worker checks a bounded directory of
IDs issued by this service. Unknown IDs never create installation objects. Each
installation still authenticates host and device credentials independently.

The service admits at most 25 new installations in a rolling 24-hour period. It permits 250 active installations and 250 active app identities. Deleting an installation does not refund work already counted in that period. A cleanup journal keeps deleted objects charged until their stored data is erased. The historical creation count is a diagnostic, not a permanent allocation limit.

Public registration requires a verified phone setup ticket. One ticket reserves one installation. An exact retry uses the same installation and the host's private token. Provisional registrations expire with the ticket after at most 20 minutes. The relay erases abandoned object storage. The phone's numeric confirmation and the host's encrypted enrollment promote the registration. A lost final phone acknowledgement does not expire an established pairing.

The first verified phone anchors the installation's capacity identity. Additional companions with the same app key share one allowance. A later pairing cannot rotate an installation's allowance. Existing installations keep their credentials and become verified when they next complete phone setup. The fixed legacy directory keeps bounded reserved capacity during migration. A new public caller cannot create a legacy identity. Verification transfers an existing host's spent allowance. It does not reset that allowance. A full legacy directory can still verify an existing host. A new host needs a free installation slot. Public callers cannot create new legacy identities.

| Daily resource | Reserved capacity | Shared burst | Total ceiling |
| --- | --- | --- | --- |
| Installation HTTP requests | 250 per identity, at most 250 identities | 37,500 | 100,000 |
| Ordinary push attempts | 10 per identity, at most 250 identities | 300 | 2,800 |
| Setup push attempts | Separate pool | 200 | 200 |

The combined push ceiling is 3,000 attempts per UTC day. Attempts keep their cost when Apple rejects them. Terminal device-token errors remove only the matching registration. A concurrent replacement stays registered. Setup retries keep a bounded alarm and expiry. The relay marks a setup notification complete only after Apple accepts it.

Authentication, method checks, and body validation occur before protected request accounting. Public key reads, malformed requests, and invalid credentials cannot spend another identity's reserved share. Edge rate limits still apply. A valid identity can spend the shared burst. Guaranteed capacity does not remove network failures or limits on an honest caller's own shared IP.

WebSocket frames keep their existing per-installation limits. They do not cross the shared admission object. Keep the `service` admission key and existing object directory during deployment. Do not delete them to reset quotas.

## Apple verification and private secrets

Both hosted configuration files require production App Attest. See [Apple service configuration](../Protocol/APPLE-SETUP.md). New key admission uses a fresh signed Apple receipt and its approximate 30-day key count. The default maximum is five. This risk threshold needs physical-device and false-rejection checks before enforcement. App reinstallation can increase the count. Existing connections continue during an Apple outage.

Public challenge requests allocate no stored rows. A challenge has a server authentication tag and binds the origin, app key, and phone key. Verified requests consume a challenge once. Exact lost-response retries return the same ticket authority. Stored challenges expire within 20 minutes. At most three live verified attempts per key can exist. The key registry holds at most 250 public keys. Unused keys expire after a day. No message content, Apple private key, or long-term device fingerprint is stored there. The risk receipt is checked for admission and then discarded.

Set real credentials through `wrangler secret put APP_ATTEST_FRAUD_KEY_ID` and `wrangler secret put APP_ATTEST_FRAUD_PRIVATE_KEY` with the intended private deployment configuration. Wrangler reads the secret interactively. Keep `.dev.vars` private if local testing needs a key. The committed example contains empty values. Generated environment types contain binding names only. Tests generate temporary keys in memory.

Release the companion and signed iOS client before enforcing public registration. A pending ticket from before enforcement can require a fresh prompt. First test a separate private deployment. Check Apple capabilities, provisioning, TestFlight, reconnects, old clients, reinstall limits, outages, and Worker CPU use. The repository changes do not change the live Worker, Apple account, hostname, or account billing plan.

## Private monitoring

Set `OPERATOR_TOKEN` as a Worker secret to a random 32-byte base64url value (43
characters). It must never be given to a plugin or phone, put into a URL, or
committed. Authenticated `GET /v1/operator/status`, using an Authorization Bearer
header, returns only aggregate counts, limits and switch states. It contains no
installation IDs, IPs, device tokens, message text or conversation titles.
Counters use fixed storage keys and roll over at midnight UTC. `rejected` counts
admission/quota rejections only; it is not a complete edge attack log.

Use Cloudflare's built-in Worker request/error/CPU metrics alongside these
counters. Invocation logging remains disabled. Monitor unexpected growth in
registrations, rejected admissions, requests and push attempts; budget exhaustion
fails closed automatically. Billing budget alerts are separate from traffic
metrics and may arrive after usage has already accrued.

## Pause or stop

Set `REGISTRATIONS_ENABLED` to `"false"` and redeploy to pause onboarding while
existing installations continue working. Set `RELAY_ENABLED` to `"false"` and
redeploy to reject public operations and stop forwarding on the next WebSocket
message. The operator status endpoint remains accessible. Changing a dashboard
variable also requires updating the config before the next deployment.

The hosted zone has a disabled rule named “Emergency stop for Hermes Jr only”.
Enable that rule for an active attack to block this hostname at Cloudflare's zone WAF *before*
Worker execution. Do not enable a challenge on normal API traffic: native clients
cannot complete a browser challenge. Existing sockets may need to close; an
edge block is not a guarantee of instant termination of every open connection.

## Account plan

The hosted configuration omits a custom CPU limit. Confirm the current account plan and measure certificate-validation CPU use in private staging. The default no-route template has a 50 ms CPU setting. A deployment must fit its account plan. Changing the account plan requires a separate operator decision. These source changes do not upgrade billing.

## Spending limits

These are **usage controls, not a guaranteed dollar cap**. Rejected requests,
rate-limit checks, directory lookups and existing WebSocket events can still be
billable. Cloudflare's edge limiter is per location and approximate. A distributed
attack can exhaust onboarding allowances and deny service even without reading
any messages. Budget alerts do not stop traffic. Keep an account budget alert,
review usage, and use the edge block when necessary.
