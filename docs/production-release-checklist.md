# Production release checklist

Everything that must be set outside the code before the first production
release. Details for store purchases, account deletion and ads are in
[app-store-release.md](app-store-release.md).

## 1. Identity server (identity.specterint.com)

- [ ] `viewvee-app` and `viewvee-app-ext` clients are public (no secret). Done.
- [ ] Rotate the old secrets of those clients; they remain in git history.
- [ ] The app actually signs in with the `working-timer-app` client
      (`lib/auth/working_timer_auth.dart`), which still sends a hardcoded
      secret. Make that client public too, or switch `ViewveeAuthConfig` to
      `viewvee-app` and blank its secrets, then rotate them.
- [ ] Access tokens for the app include the `viewvee-api` scope and audience
      (purchases, entitlement and TURN all require it).
- [ ] Token endpoint has rate limiting / lockout (the password grant has no
      client authentication).

## 2. API server (viewvee.com, `api/`)

Environment:

```text
# Identity (issuer WITHOUT trailing slash - it must match discovery exactly)
TURN_IDENTITY_ISSUER=https://identity.specterint.com
TURN_IDENTITY_AUDIENCE=viewvee-api
TURN_REQUIRED_SCOPE=viewvee-api

# TURN relay
TURN_SHARED_SECRET=<32+ chars, same as coturn static-auth-secret>
TURN_URLS=turn:turn.viewvee.com:3478?transport=udp,turn:turn.viewvee.com:3478?transport=tcp,turns:turn.viewvee.com:443?transport=tcp
TURN_REQUIRE_PREMIUM=true

# Purchases
APPLE_PREMIUM_PRODUCT_ID=viewvee_premium
GOOGLE_PREMIUM_PRODUCT_ID=premium
PURCHASE_BUNDLE_ID=com.specterint.viewvee
APPLE_STORE_ISSUER_ID=49f17177-b00f-455e-88ab-d46ba7a9500f
APPLE_STORE_KEY_ID=GW82BWB989
APPLE_STORE_PRIVATE_KEY_FILE=/secrets/SubscriptionKey_GW82BWB989.p8
APPLE_STORE_ENVIRONMENT=Both
GOOGLE_PLAY_CREDENTIALS_FILE=/secrets/viewvee-a3881-868a3ffb2c44.json
ENTITLEMENT_STORE_FILE=/data/entitlements.json

# Email
SMTP_USERNAME=...
SMTP_PASSWORD=...
```

- [ ] Mount a **persistent volume at `/data`** and back it up. It holds which
      account owns each purchase; losing it means users must tap "Restore".
- [ ] Run **one API instance**. The purchase store is a local file; move it to
      a database (e.g. DynamoDB/Postgres) before scaling out.
- [ ] Mount the Apple `.p8` key and the Google service-account JSON as secrets,
      never in the image or the repo.
- [ ] After deploy, check logs for `identity verification unavailable`. If it
      appears, purchases and TURN answer 503.
- [ ] Smoke test: `GET /api/purchases/entitlement` without a token returns 401
      (503 means identity is misconfigured).

## 3. Google Play Console

- [ ] In-app product `premium`, one-time (non-consumable),
      active, priced.
- [ ] Service account with "View financial data, orders and cancellation
      survey responses" for this app, linked in Play Console → API access;
      its JSON key is `GOOGLE_PLAY_CREDENTIALS_FILE`.
- [ ] Licence testers added, and a test purchase completed end to end on an
      internal-testing build (guest buy → unlock → sign in claims it →
      second device unlocks after sign-in → refund revokes within 24 h).
- [ ] Foreground service declaration for camera, microphone and media
      playback, with the review video (`tool/record_play_review.sh`).
- [ ] Data safety form: purchase history, account info, audio/video
      (transmitted, not stored), advertising ID.
- [ ] Upload key: `android/key.properties` + `upload-keystore.jks` present on
      the build machine (not in git) and Play App Signing enabled.

## 4. App Store Connect

- [ ] Non-consumable `viewvee_premium` (Apple app ID `6801280302`), cleared for sale, with review
      screenshot.
- [ ] In-App Purchase API key (Users and Access → Integrations) for the API.
- [ ] Sandbox tester; complete a sandbox purchase on a TestFlight build.
- [ ] Review notes: Premium can be bought without an account (guideline
      5.1.1(v)); internet monitoring additionally needs a signed-in account
      because the relay is account-based. Provide a demo account.
- [ ] `PrivacyInfo.xcprivacy` added (required for AdMob, Firebase,
      shared_preferences).
- [ ] `viewvee://` URL scheme in `Info.plist` if the browser sign-in is used.

## 5. App configuration (Flutter)

- [ ] Replace Google's **test AdMob IDs** with real ones:
      `AndroidManifest.xml`, `ios/Runner/Info.plist`
      (`GADApplicationIdentifier`), `lib/ads/ad_free_reward_service.dart`.
- [ ] iOS ads: `SKAdNetworkItems`, `NSUserTrackingUsageDescription`, and the
      UMP consent message published in AdMob for EU/UK users.
- [ ] Build with `--dart-define=BASE_URL=...` (otherwise the sign-in redirect
      falls back to `http://localhost:43507/`).
- [ ] `ios/Runner/GoogleService-Info.plist` added, and Firebase initialized,
      if analytics is wanted.
- [ ] Pin `working_timer_core` to a tag/commit that contains the
      public-client change (empty secrets are omitted).
- [ ] Foreground-service notification text: mention the camera and add an
      English translation (`AudioMonitorForegroundService.kt`).
- [ ] Bump `version:` in `pubspec.yaml` for every store upload.

## 6. Final verification

- [ ] `flutter test` and `cd api && go test ./...` pass.
- [ ] Release builds: `flutter build appbundle` and `flutter build ipa`.
- [ ] On real devices: pairing over Wi-Fi, pairing over internet (Premium
      account), free account is refused TURN, background monitoring keeps
      streaming with the notification visible.
