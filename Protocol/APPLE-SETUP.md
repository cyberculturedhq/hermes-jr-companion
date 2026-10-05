# Apple signing and push setup

Hermes Jr. has an explicit App ID with Push Notifications enabled:

- Bundle ID: `com.hermesjr.app`
- Apple Developer team: `56MTG87283`
- Display name: Hermes Jr.

These identifiers are public configuration, not secrets. The project uses this team
for the owner's build. People building from source select their own development
team and a unique bundle ID in Xcode. Direct chat and encrypted relay access do not
depend on our Apple account. Push additionally needs a provider configured for that
build's topic and environment.

## Provider configuration

The server needs `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_TOPIC`, and
`APNS_PRIVATE_KEY` as Cloudflare Worker secrets. The last value is the full `.p8`
PKCS#8 PEM private key. It must stay outside source control, the iOS app, and the
companion distributed to users. The non-secret `APNS_ENVIRONMENT` setting restricts
which device tokens the service accepts.

The staging key `RSZM54525C` is restricted to **Sandbox**, **Topic Specific**, and
only `com.hermesjr.app`. Its validated P-256 private key is stored outside this
repository at `~/.local/share/hermes-jr/keys/AuthKey_RSZM54525C.p8` (directory 0700,
file 0600). Cloudflare staging has the team ID, replacement key ID, topic, and
private key configured as Worker secrets. The authorized private-key upload
succeeded, and `/v1/capabilities` reports `push: true`. The unusable first key
`VH72YT5F94` was revoked after its browser download failed. Storos uses its existing
Expo provider key, which is unchanged and not required by Hermes Jr.

The separate production key `BS75TM7M28` is restricted to **Production**, **Topic
Specific**, and `com.hermesjr.app`. Its private file is stored outside the repository
at `~/.local/share/hermes-jr/keys/AuthKey_BS75TM7M28.p8` (0600). The hosted relay uses
`APNS_PRODUCTION_KEY_ID` and `APNS_PRODUCTION_PRIVATE_KEY` for production, retains
the original sandbox secrets, and sets `APNS_ENVIRONMENT=both`. Signing-token caches
are isolated by key. Actual delivery to the first TestFlight build remains an
on-device acceptance check; configured credentials alone do not establish delivery.

Once an APNs key has been created, Apple allows its private portion to be downloaded
only once. Keep a protected backup outside this repository.
An app ID alone does not sign a physical-device build: Xcode must have a valid
development identity and provisioning profile for the registered device.

The development Mac has a valid Apple Development signing identity for this
account. Xcode successfully produced a signed Debug iPhone build with a managed
provisioning profile at `/tmp/hermes-jr-device/Build/Products/Debug-iphoneos/Hermes.app`.
The build is installed on the paired iPhone. Real sandbox token registration,
following the opened fixture conversation, and APNs acceptance (HTTP 200) have
been verified through staging. The owner confirmed that the notification appeared
and tapping it opened **Research → Session 0**. The fixture also recorded the app
resolving the opaque notification reference over the encrypted connection.

Debug builds request the APNs sandbox using the `development` entitlement.
Release builds use `production`. Changing an entitlement without a matching
provisioning profile does not confer that capability.

On 22 September 2026, the 0.1.0 (1) archive exported and uploaded successfully to
App Store Connect app `6814586816` for internal TestFlight only. The exported app's
signature and profile both have production APNs entitlement, debugging is disabled,
and the profile permits beta reports. The package includes the UserDefaults privacy
manifest and declares no non-exempt encryption: cryptography uses Apple's system
CryptoKit and networking APIs. Apple processing and real-device delivery are separate
checks from a successful upload.

For the real device check, build and run Hermes Jr. with the registered identifier,
connect to the companion, and enable notifications in connection details. Open a
conversation to follow it, put the app in the background, and complete a turn or
trigger a human approval. Verify the generic alert opens the correct conversation.
Fixtures and simulator-injected notifications cannot establish actual Apple
acceptance or delivery.

## Individual to organization membership

The current individual membership can be used for development and push testing.
Conversion can happen later through Apple's membership update process. Apple asks
the founder/cofounder to submit an organization request with its D-U-N-S number and
may request verification documents. Re-check team membership, signing assets, and
APNs credentials when Apple completes the change; do not assume it behaves like
creating a new account or transferring an app.

Primary references: [Apple membership updates](https://developer.apple.com/help/account/membership/updating-your-account-information/),
[creating service keys](https://developer.apple.com/help/account/keys/create-a-private-key/),
and [APNs registration](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).
