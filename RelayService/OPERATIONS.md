# Operating the relay

The hosted service uses **https://hermes-jr-companion.cybercultured.com** only.
The Workers development hostname and preview URLs are disabled. The internal
Worker name still contains `staging`; this does not create a second public endpoint.

## Admission and usage limits

Before allocating installation storage, the Worker checks a bounded directory of
IDs issued by this service. Unknown IDs never create installation objects. Each
installation still authenticates host and device credentials independently.

The service admits at most 25 new installations per UTC day and 250 over the
lifetime of the admission directory. Deleting an installation does not refund
this lifetime allowance. Failed initialization also consumes an allowance. These
conservative launch limits require an intentional code change to increase.

The shared budget permits 100,000 installation HTTP requests and 3,000 push
attempts per UTC day, in addition to the existing per-IP, per-installation,
per-device, connection, frame and byte limits. WebSocket frames do not traverse
the shared admission object. Its role is low-volume admission and quota
coordination, not routing conversation traffic.

Do not delete the admission object or rename its `service` key to reset quotas.
That would lose the directory and break existing installations. This initial
rollout intentionally does not import pre-launch test installations.

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

The hosted configuration omits a custom CPU limit because the current account uses Workers Free. Cloudflare enforces that plan's CPU and request limits; a custom `limits.cpu_ms` requires Workers Standard. Changing the account plan is a separate operator decision. This configuration does not upgrade billing.

## Spending limits

These are **usage controls, not a guaranteed dollar cap**. Rejected requests,
rate-limit checks, directory lookups and existing WebSocket events can still be
billable. Cloudflare's edge limiter is per location and approximate. A distributed
attack can exhaust onboarding allowances and deny service even without reading
any messages. Budget alerts do not stop traffic. Keep an account budget alert,
review usage, and use the edge block when necessary.
