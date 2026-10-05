# Apple service configuration

The official bundle identifier is `com.hermesjr.app`. The public Team ID is `56MTG87283`. These identifiers are public configuration. They cannot sign requests or builds.

Keep Apple `.p8` keys, signing certificates, provisioning profiles, account credentials, and local deployment records outside this repository. The public repository contains only identifiers, entitlement names, public verification certificates, and empty secret examples.

## App verification

The app uses the `com.apple.developer.devicecheck.appattest-environment` entitlement. Debug uses `development`. Release uses `production`. Enable App Attest for the App ID in the Apple Developer account. Refresh the provisioning profile after this capability change.

The hosted relay uses `APP_ATTEST_MODE=required`. Set `APP_ATTEST_APP_ID` to the Team ID followed by the bundle identifier. The hosted configuration accepts the production environment. Use a separate private development deployment for development attestations. Do not open development admission on the public hostname.

Create an Apple server key with DeviceCheck enabled. Store its key ID in `APP_ATTEST_FRAUD_KEY_ID`. Store its private `.p8` content in `APP_ATTEST_FRAUD_PRIVATE_KEY`. Use the private Worker secret store. Do not put either real value in Wrangler configuration, an example file, a build setting, the iOS app, or the companion package.

The relay validates Apple's certificate chain, app identity, environment, challenge, phone key, and assertion counter. A new key also needs a signed Apple risk receipt. The default `APP_ATTEST_MAX_KEYS=5` limits the approximate count of new app keys on a device in 30 days. Reinstalls and device restores can increase this count. Check false rejections in private staging before public enforcement. Existing connections do not need a fresh Apple request for every operation.

Apple verification runs automatically before the app creates a setup ticket. The user keeps the existing numeric comparison. An unsupported device cannot start new public setup. An Apple outage leaves existing connections available. New setup stops and can retry.

If Apple reports `invalidKey`, the app replaces the saved key and retries once. A repeated key error stops setup. A temporary `serverUnavailable` error keeps the same key and challenge digest. This avoids unnecessary key creation during an outage. See [Apple app integrity guidance](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity).

## Push notifications

Set `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_TOPIC`, and `APNS_PRIVATE_KEY` as private Worker secrets. A restricted production key can use `APNS_PRODUCTION_KEY_ID` and `APNS_PRODUCTION_PRIVATE_KEY`. Set `APNS_ENVIRONMENT` to the allowed environment. App Attest and APNs keys can have different capabilities. A push key alone does not establish DeviceCheck access.

Apple permits one private-key download. Keep a protected backup outside the repository. Do not record actual key IDs, private file paths, account details, or device deployment records in public setup documentation.

## Release checks

Release the companion ticket support and the signed iOS app before enforcing verified registration. Keep the existing admission directory and established pairings. Test development and TestFlight builds on physical devices. Check certificate validation, lost responses, reinstall limits, Apple outages, pairing, and actual background push delivery. Simulator tests cannot prove Apple's physical-device service.

The code and local tests do not deploy a Worker or change Apple account capabilities. See [relay operations](../RelayService/OPERATIONS.md) for capacity and secret settings.

References: [App Attest preparation](https://developer.apple.com/documentation/devicecheck/preparing-to-use-the-app-attest-service), [server validation](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server), and [risk receipts](https://developer.apple.com/documentation/devicecheck/assessing-fraud-risk).
