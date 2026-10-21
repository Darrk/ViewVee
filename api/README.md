# ViewVee web and authenticated TURN API

This Go service serves the ViewVee website and `GET /api/turn/credentials`.
Deploy it behind HTTPS on `viewvee.com`, forwarding `/api/turn/credentials`
to this service (not the signaling or Coturn container).

## Server configuration

Set these environment variables on the **ViewVee web/API container**:

```text
TURN_SHARED_SECRET=<same value as Coturn static-auth-secret>
TURN_IDENTITY_ISSUER=https://identity.specterint.com/
TURN_IDENTITY_AUDIENCE=viewvee-api
TURN_REQUIRED_SCOPE=viewvee-api
TURN_URLS=turn:turn.viewvee.com:3478?transport=udp,turn:turn.viewvee.com:3478?transport=tcp,turns:turn.viewvee.com:443?transport=tcp
TURN_CREDENTIAL_TTL_SECONDS=86400
```

The issuer must exactly match the `issuer` in IdentityServer's discovery document.
The service discovers signing keys at startup, caches them, and refreshes them
when needed. It validates JWT signatures, issuer, audience, expiration, `nbf`,
subject, and the required scope. Opaque/reference tokens are not supported; configure
IdentityServer to issue JWT access tokens for this API.

Register/enable the API resource audience and scope `viewvee-api` in IdentityServer,
and allow the mobile app's OAuth clients to request that scope. Existing app
sessions with only `working-timer-api` must sign out and back in to obtain the new
scope. Login still happens through IdentityServer, not through Coturn.

Without `TURN_SHARED_SECRET`, the endpoint returns 503 and the rest of the website
continues working. With TURN enabled, invalid configuration or failed IdentityServer
discovery prevents startup. Keep this secret out of source control and app builds.
The credential TTL defaults to 24 hours and can be configured from 300 to 86400 seconds.
`TURN_URLS` accepts comma-separated TURN URLs.

Native mobile apps do not need CORS. For a browser app on another origin, set exact
origins (no wildcard or paths), for example:

```text
TURN_ALLOWED_ORIGINS=https://app.viewvee.com,http://localhost:43507
```

## Request and response

```http
GET /api/turn/credentials
Authorization: Bearer <IdentityServer access token>
```

```json
{
  "urls": ["turns:turn.viewvee.com:443?transport=tcp"],
  "username": "<expiry-unix-seconds>:<hashed-user-id>",
  "credential": "<base64-HMAC-SHA1-of-username>",
  "expiresAt": "2026-10-13T12:00:00Z"
}
```

Responses use `Cache-Control: no-store`. Missing/invalid tokens return 401, missing
scope returns 403, disabled TURN returns 503, and issuance is limited to 60 requests
per authenticated subject per hour per API process (429). Multiple API replicas
have separate limits; apply shared edge limits if required. No client-supplied user
ID or secret is accepted. Coturn validates the generated credentials independently.

## Flutter integration

The app defaults to `https://viewvee.com/api/turn/credentials`. Override with:

```sh
flutter run \
  --dart-define=VIEWVEE_TURN_CREDENTIALS_URL=https://viewvee.com/api/turn/credentials \
  --dart-define=VIEWVEE_AUTH_SCOPES="openid email profile offline_access viewvee-api"
```

The credential endpoint must use HTTPS; redirects are not followed with the bearer
token. The app reads its access token from the shared secure Identity client,
silently refreshes expired tokens, and retries once after a 401. It validates
`expiresAt` and obtains fresh TURN credentials for each new internet peer connection,
including reconnects. Active sessions are left running; WebRTC refreshes their
allocations automatically. A backend failure is surfaced instead of silently
removing TURN for signed-in users. Local Wi-Fi connections do not call the endpoint.
Guest/signed-out sessions cannot obtain TURN credentials and retain only direct/STUN
connectivity. Legacy build-time TURN usernames/passwords are no longer used.

## Validation

```sh
go test -race ./...
go vet ./...
```

Tests cover a local IdentityServer discovery/JWKS fixture with signed tokens,
incorrect signatures/issuers/audiences, expired and future tokens, required scopes,
Coturn credential generation, CORS, disabled configuration, and rate limiting.
