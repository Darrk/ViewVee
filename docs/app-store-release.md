# Store purchases, account deletion, and privacy

The app and API changes are implemented locally. Creating store products, issuing
keys, configuring AdMob messages, deploying services, and signing an iOS archive
still require the corresponding developer accounts. No production service has
been changed by this implementation.

## Lifetime Premium

Create non-consumable products with ID `viewvee_premium` in App Store Connect
and `premium` in Google Play. The Apple app ID is `6801280302`; the bundle ID
is `com.specterint.viewvee`. The numeric app ID is not the App Store Server API
issuer ID or key ID. The app displays the store-provided price.

The app defaults to these product IDs. To override them, use Flutter build defines
`VIEWVEE_APPLE_PREMIUM_PRODUCT_ID` and `VIEWVEE_GOOGLE_PREMIUM_PRODUCT_ID` and
set the corresponding API environment variables. The legacy Flutter define
`VIEWVEE_PREMIUM_PRODUCT_ID` overrides both platform defaults.

Configure the Go API with:

```text
APPLE_PREMIUM_PRODUCT_ID=viewvee_premium
GOOGLE_PREMIUM_PRODUCT_ID=premium
PURCHASE_BUNDLE_ID=com.specterint.viewvee
APPLE_STORE_ISSUER_ID=49f17177-b00f-455e-88ab-d46ba7a9500f
APPLE_STORE_KEY_ID=GW82BWB989
APPLE_STORE_PRIVATE_KEY_FILE=/secrets/SubscriptionKey_GW82BWB989.p8
APPLE_STORE_ENVIRONMENT=Both
GOOGLE_PLAY_CREDENTIALS_FILE=/secrets/viewvee-a3881-868a3ffb2c44.json
```

Mount the keys as server secrets, never app assets or source files. The Play
service account needs permission to read purchases in this app. `Both` accepts
Apple production and sandbox receipts, since App Review purchases use sandbox.
`Production` rejects sandbox receipts; `Sandbox` allows sandbox testing as well
as production receipts. Verification uses the environment in the Apple-signed
receipt, never a client-selected API hostname. Missing server credentials return
503 and do not grant new entitlements. Guests can buy (App Store 5.1.1(v)); a
guest purchase unlocks only that device until the user signs in. With a token,
the API binds each verified transaction to the first account that redeems it
(409 for any other account, and for guests presenting an owned receipt), and `GET /api/purchases/entitlement` lets the
same account unlock its other devices. TURN credentials are issued only to
accounts with an active purchase (`TURN_REQUIRE_PREMIUM=true`). Purchases are
stored in `ENTITLEMENT_STORE_FILE` (default `/data/entitlements.json`) on a
persistent volume, and re-verified with the store every 24 hours.

`POST /api/purchases/verify` receives `platform` (`apple` or `google`), `productId`,
`transactionId`, and `verificationData`. Apple proof must be StoreKit 2 signed JWS;
legacy StoreKit 1 receipts and local Xcode unsigned StoreKit fixtures are rejected.
Responses are `{ "productId": "...", "active": true/false }`.

The app listens from startup, serializes transaction handling, delivers verified
entitlements before acknowledging the purchase, and leaves failed verification
unfinished for retry. Restore Purchases is available on the Premium screen.
Previously verified purchases remain usable when the verification service is
offline. Reopening the app rechecks saved guest proofs and account entitlements for refunds/revocations. The current entitlement
belongs to the store account/device and is restored on other devices with that
store account; it is not an account-to-account entitlement transfer service.

## Self-service account deletion

The companion identity repository is `/home/darrk/projects/manguru-identity`.
Deploy its new `DELETE /api/viewvee/account` endpoint before deploying the app.
The Go API exposes `DELETE /api/account` and forwards only the authenticated
caller's bearer token and confirmation to that fixed identity endpoint. It never
accepts a target account ID or forwards an administrative credential. Configure
`IDENTITY_ACCOUNT_DELETE_URL` only if the identity endpoint has a different HTTPS
address; redirects are refused.

ViewVee now uses its own `viewvee-app` / `viewvee-app-ext` public native OAuth
clients and signs up under the `viewvee` application, instead of Working Timer.
On the identity deployment, set `ViewVee__ProvisionClients=true` for one startup
to idempotently create the missing clients, `viewvee-api` scope/resource, and
ViewVee application record. Existing configurations are not overwritten. The
identity database schema must already be migrated. Existing sessions created
with Working Timer clients must sign out and sign in again.

For Apple token revocation, configure the **identity server** separately:

```text
ViewVee__AppleTeamId=<Apple developer team ID>
ViewVee__AppleKeyId=<Sign in with Apple key ID>
ViewVee__ApplePrivateKeyFile=/run/secrets/sign-in-with-apple.p8
```

This is a Sign in with Apple key, distinct from the App Store purchase API key.
Enable Sign in with Apple for `com.specterint.viewvee` in the Apple developer
account and regenerate the distribution provisioning profile. The Xcode target
includes the entitlement. The identity service exchanges a fresh authorization
code with Apple, binds the Apple subject to the authenticated account, revokes
Apple access, removes ViewVee grants/membership, and permanently deletes the
identity and associated personal records when no other app needs that identity.
Other Specter apps' memberships and necessary shared identity data are preserved.
Local recordings remain under the user's control, as described in the policy.

## Advertising and review prompts

UMP refreshes consent information once per app launch and presents required
forms before ad requests. Every ad load/show checks `canRequestAds`; cached ads
are invalidated after privacy-option changes. Required privacy controls appear
in About and Premium. Ad/consent failures do not block monitoring.

Configure real AdMob application/ad-unit IDs and publish applicable messages in
AdMob **Privacy & messaging** before enabling production advertising. The existing
sample IDs cannot serve as production consent configuration. Configure the iOS
ATT message there if advertising behavior requires tracking; permission strings
are included. Non-personalized requests do not replace regional consent or ATT.

The custom star rating screen is replaced with `InAppReview.requestReview()`.
StoreKit/Play decide whether a prompt appears; no local rating is presented as
an App Store review.

## iOS validation

Camera, microphone, local-network, and optional ATT purpose strings are bundled
in all 28 supported languages through the Xcode `InfoPlist.strings` variant group.
The default Info.plist text is English. Translated strings and resource wiring
are checked by `test/ios_permission_localization_test.dart`.

On a Mac, run `flutter pub get`, `pod install` in `ios`, and build/archive with
Xcode 26+ / iOS 26+ SDK. This Linux workspace cannot refresh CocoaPods' lockfile or
verify a signed iOS archive. Test a sandbox purchase, cancellation, restoration on
a second device, refund/revocation, offline startup, consent denial/withdrawal,
Apple/email account deletion, and account deletion retry after network failure.

The identity repository's normal NuGet restore currently reports existing
vulnerable dependencies as errors. Functional deletion tests can be isolated with
`dotnet test -p:NuGetAudit=false --filter FullyQualifiedName~ViewVeeAccountTest`;
this command does not change the repository's audit policy. Resolve the baseline
dependency advisories before deploying that service.
